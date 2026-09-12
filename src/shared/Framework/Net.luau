--!strict
--[[
	Net.luau

	Single source of truth for every remote in the game.

	A remote that exists on the server but not the client -- or that has a
	typo'd name at one call site -- is a silent bug that only shows up on a
	live server under specific timing. Declaring all of them in one table means
	both sides build from the same list, and an undeclared name is a loud error
	at the call site instead of a hang.

	Client -> Server events are rate limited per player. Every C2S handler is
	still responsible for validating its own arguments: rate limiting blunts
	spam, it does not make a handler safe. The server never trusts a client
	about anything it can derive itself.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local IS_SERVER = RunService:IsServer()

local FOLDER_NAME = "Net"

--[[
	Every remote, declared once.

	Adding a remote means adding a string here. Never call
	Instance.new("RemoteEvent") at a call site.
]]
local C2S_EVENTS = {
	"RequestProfile",
	"SetReady",
	"RequestQueue",
	"LeaveQueue",
	"CastVote",
	"PurchaseItem",
	"OpenCase",
	"EquipItem",
	"UpgradeHousing",
}

local S2C_EVENTS = {
	"ProfileUpdated",
	"CurrencyChanged",
	"RoundStateChanged",
	"Notification",
	"MatchFound",
	"MatchResults",
}

--[[
	Calls per second allowed per player, per event. Overridable per event for
	chatty UI (like a vote slider) or for events that should be near-rare.
]]
local C2S_RATE_LIMIT: { [string]: number } = {
	RequestProfile = 2,
	SetReady = 5,
	RequestQueue = 2,
	LeaveQueue = 2,
	CastVote = 4,
	PurchaseItem = 5,
	OpenCase = 2,
	EquipItem = 5,
	UpgradeHousing = 3,
}

local DEFAULT_RATE_LIMIT = 5

local declared: { [string]: boolean } = {}
for _, name in C2S_EVENTS do
	declared[name] = true
end
for _, name in S2C_EVENTS do
	declared[name] = true
end

local Net = {}

local folder: Folder? = nil
local remoteCache: { [string]: RemoteEvent } = {}

-- Fixed-window rate limit counters: player -> event name -> bucket.
local rateBuckets: { [Player]: { [string]: { count: number, windowStart: number } } } = {}

local function getFolder(): Folder
	local cached = folder
	if cached then
		return cached
	end

	if IS_SERVER then
		local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
		if existing and existing:IsA("Folder") then
			folder = existing
		else
			local created = Instance.new("Folder")
			created.Name = FOLDER_NAME
			created.Parent = ReplicatedStorage
			folder = created
		end
	else
		-- The client can be running before the server has created the folder.
		local found = ReplicatedStorage:WaitForChild(FOLDER_NAME, 30)
		if not found then
			error("[Net] Timed out waiting for ReplicatedStorage." .. FOLDER_NAME, 2)
		end
		folder = found :: Folder
	end

	return folder :: Folder
end

local function getRemote(name: string): RemoteEvent
	local cached = remoteCache[name]
	if cached then
		return cached
	end

	if not declared[name] then
		error(
			string.format(
				"[Net] Remote %q was never declared. Add it to C2S_EVENTS or S2C_EVENTS in Net.luau.",
				name
			),
			2
		)
	end

	local parent = getFolder()
	local existing = parent:FindFirstChild(name)
	local remote: RemoteEvent

	if existing and existing:IsA("RemoteEvent") then
		remote = existing
	elseif IS_SERVER then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = parent
	else
		local found = parent:WaitForChild(name, 30)
		if not found then
			error(string.format("[Net] Timed out waiting for remote %q", name), 2)
		end
		remote = found :: RemoteEvent
	end

	remoteCache[name] = remote
	return remote
end

local function allow(player: Player, name: string): boolean
	local limit = C2S_RATE_LIMIT[name] or DEFAULT_RATE_LIMIT
	local now = os.clock()

	local perPlayer = rateBuckets[player]
	if not perPlayer then
		perPlayer = {}
		rateBuckets[player] = perPlayer
	end

	local bucket = perPlayer[name]
	if not bucket or now - bucket.windowStart >= 1 then
		perPlayer[name] = { count = 1, windowStart = now }
		return true
	end

	bucket.count += 1
	return bucket.count <= limit
end

--[[
	Server: listen for a client -> server event.

	The handler runs inside a pcall so an error in one call cannot take down
	the listener for every other player, and it is already rate limited.
]]
function Net.OnServerEvent(name: string, handler: (player: Player, ...any) -> ()): RBXScriptConnection
	assert(IS_SERVER, "[Net] OnServerEvent is server-only")

	local remote = getRemote(name)

	return remote.OnServerEvent:Connect(function(player: Player, ...: any)
		if not allow(player, name) then
			-- Silently drop. Warning here would let an exploiter spam the log.
			return
		end

		local ok, err = pcall(handler, player, ...)
		if not ok then
			warn(string.format("[Net] Error in %s handler: %s", name, tostring(err)))
		end
	end)
end

--[[
	Client: listen for a server -> client event.
]]
function Net.OnClientEvent(name: string, handler: (...any) -> ()): RBXScriptConnection
	assert(not IS_SERVER, "[Net] OnClientEvent is client-only")

	return getRemote(name).OnClientEvent:Connect(handler)
end

function Net.FireClient(name: string, player: Player, ...: any): ()
	assert(IS_SERVER, "[Net] FireClient is server-only")
	getRemote(name):FireClient(player, ...)
end

function Net.FireAllClients(name: string, ...: any): ()
	assert(IS_SERVER, "[Net] FireAllClients is server-only")
	getRemote(name):FireAllClients(...)
end

--[[
	Broadcasts to everyone except the listed players -- used for round events
	that the eliminated players should not receive.
]]
function Net.FireAllClientsExcept(name: string, excluded: { Player }, ...: any): ()
	assert(IS_SERVER, "[Net] FireAllClientsExcept is server-only")

	local remote = getRemote(name)
	for _, player in Players:GetPlayers() do
		if not table.find(excluded, player) then
			remote:FireClient(player, ...)
		end
	end
end

function Net.FireServer(name: string, ...: any): ()
	assert(not IS_SERVER, "[Net] FireServer is client-only")
	getRemote(name):FireServer(...)
end

--[[
	Releases a departing player's rate-limit bucket. Without this the table
	grows for the lifetime of the server -- a slow leak that only shows up on
	long-running, high-churn servers.
]]
function Net.ClearPlayer(player: Player): ()
	rateBuckets[player] = nil
end

--[[
	Releases every bucket. Called on server shutdown.
]]
function Net.ClearAll(): ()
	table.clear(rateBuckets)
end

return Net
