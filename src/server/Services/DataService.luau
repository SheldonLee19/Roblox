--!strict
--[[
	DataService.luau

	Session-locked profile persistence for every player.

	The problem this solves: Roblox will happily run the same player's join
	code on two servers at once (a laggy server they left, plus the one they
	just joined). Both load the profile, both mutate it, both save -- and the
	slower write wins. The player loses whatever the other server did.

	The fix is a lock stored alongside the data. A server takes the lock on
	load and refuses to load a profile whose lock is held by a different,
	recently-active server. Because the read-modify-write happens inside a
	single UpdateAsync, the lock is taken atomically -- there is no window
	between "check the lock" and "take the lock" for a race to slip through.

	A server that dies without releasing leaves a stale lock; the timestamp
	expires it after LOCK_TIMEOUT seconds so the player is never permanently
	locked out of their own save. That is the trade: a crash costs the player
	up to LOCK_TIMEOUT seconds of waiting, never their items.

	This runs on the server only. Clients receive a redacted snapshot of their
	own profile and can ask for changes; they never write.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Types = require(Shared.Types)
local Signal = require(Shared.Framework.Signal)
local TableUtil = require(Shared.Util.TableUtil)

local ProfileTemplate = require(script.Parent.ProfileTemplate)

local DataService = {}

DataService.ProfileLoaded = Signal.new()
DataService.ProfileReleasing = Signal.new()

local STORE_NAME = "PlayerProfiles"

--[[
	How long another server's lock is honoured before we assume that server
	died and take the profile over. Too low and a brief network stall lets two
	servers write the same profile; too high and a player who crashed on join
	waits a long time to get back in.
]]
local LOCK_TIMEOUT_SECONDS = 60

local MAX_LOAD_ATTEMPTS = 6
local AUTOSAVE_INTERVAL_SECONDS = 90

--[[
	Identity for this server instance, used as the lock owner.

	game.JobId is an empty string in Studio and in local test servers, so we
	synthesise one. Without this every Studio session would share the empty
	JobId and consider itself the rightful owner of every lock -- meaning two
	Studio sessions would silently clobber each other, which is exactly the
	bug this service exists to prevent, reintroduced in the environment the
	team spends most of its time in.
]]
local JOB_ID = game.JobId
if JOB_ID == "" then
	JOB_ID = string.format("local-%d-%d", os.time(), math.random(1, 1_000_000))
end

local store = DataStoreService:GetDataStore(STORE_NAME)

-- player -> Profile
local profiles: { [Player]: any } = {}

local function profileKey(player: Player): string
	return "Player_" .. tostring(player.UserId)
end

--------------------------------------------------------------------------
-- Profile object
--------------------------------------------------------------------------

local Profile = {}
Profile.__index = Profile

function Profile.Get(self: any): Types.ProfileData
	return self.Data
end

--[[
	Persists the profile.

	`release` additionally hands the lock back, which is what we want on
	PlayerRemoving -- leaving with the lock still held would make the player
	wait out LOCK_TIMEOUT on their very next join.

	Returns success plus an error string. Callers that are mid-teardown can
	ignore the result, but a failed save must never be silent forever: the
	autosave loop warns, so a persistent DataStore outage shows up in the logs
	rather than presenting as "players randomly lose progress".
]]
function Profile.Save(self: any, release: boolean?): (boolean, string?)
	if self._closed and not release then
		return false, "Profile is closed"
	end

	-- Snapshot before yielding. UpdateAsync's transform must not yield, but
	-- the network round trip around it absolutely can, and a player mutating
	-- their inventory during that window would otherwise be serialised
	-- mid-write in a partially-applied state.
	local snapshot = TableUtil.deepCopy(self.Data)
	snapshot.LastSaved = os.time()

	local payload: any = { Data = snapshot }
	if not release then
		payload.Lock = { JobId = JOB_ID, Timestamp = os.time() }
	end

	local success, err = pcall(function()
		return store:UpdateAsync(profileKey(self.Player), function(existing: any)
			if existing ~= nil then
				local lock = existing.Lock
				if lock ~= nil and lock.JobId ~= JOB_ID then
					-- Someone else owns this profile now. Refuse the write
					-- rather than clobber them.
					return nil
				end
			end

			return payload
		end)
	end)

	if not success then
		return false, tostring(err)
	end

	if release then
		self._closed = true
	end

	return true, nil
end

function Profile.IsClosed(self: any): boolean
	return self._closed
end

local function newProfile(player: Player, data: Types.ProfileData): any
	return setmetatable({
		Player = player,
		Data = data,
		_closed = false,
	}, Profile)
end

--------------------------------------------------------------------------
-- Loading
--------------------------------------------------------------------------

--[[
	Loads a profile, taking the session lock.

	Prints a fresh profile the first time a player joins, and repairs an
	existing one through ProfileTemplate.migrate on every load.

	Returns (profile, nil) on success or (nil, reason) on failure. Failure
	kicks the player: letting someone play on an unsaved default profile means
	they earn rewards all session and lose every one of them, which is far
	worse than an honest "couldn't load your data, please rejoin".
]]
local function loadProfile(player: Player): (any?, string?)
	local key = profileKey(player)

	for attempt = 1, MAX_LOAD_ATTEMPTS do
		local success, resultOrErr = pcall(function()
			return store:UpdateAsync(key, function(existing: any)
				local now = os.time()

				if existing == nil then
					-- Brand new player.
					return {
						Data = ProfileTemplate.create(),
						Lock = { JobId = JOB_ID, Timestamp = now },
					}
				end

				local lock = existing.Lock
				if lock ~= nil and lock.JobId ~= JOB_ID then
					local age = now - (lock.Timestamp or 0)
					if age < LOCK_TIMEOUT_SECONDS then
						-- Held by a live server. Returning nil aborts the
						-- write entirely, so we cannot accidentally take a
						-- lock while merely trying to read.
						return nil
					end
				end

				existing.Data = ProfileTemplate.migrate(existing.Data or ProfileTemplate.create())
				existing.Lock = { JobId = JOB_ID, Timestamp = now }
				return existing
			end)
		end)

		if not success then
			warn(
				string.format(
					"[DataService] Load attempt %d/%d failed for %s: %s",
					attempt,
					MAX_LOAD_ATTEMPTS,
					player.Name,
					tostring(resultOrErr)
				)
			)
		elseif resultOrErr ~= nil then
			return newProfile(player, resultOrErr.Data), nil
		end

		-- Either the call errored or the write was aborted because another
		-- server holds the lock. Both are worth retrying, with a growing
		-- backoff so we do not hammer a throttled DataStore.
		if attempt < MAX_LOAD_ATTEMPTS then
			task.wait(attempt * 2)
		end
	end

	return nil, "Could not load profile (locked by another server or DataStore unavailable)"
end

--------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------

function DataService.GetProfile(player: Player): any?
	return profiles[player]
end

--[[
	Returns the profile or throws. Use in handlers that cannot meaningfully
	continue without one -- a silent nil here becomes a mysterious no-op three
	frames deeper.
]]
function DataService.GetProfileOrError(player: Player): any
	local profile = profiles[player]
	if not profile then
		error(string.format("[DataService] No profile for %s", player.Name), 2)
	end
	return profile
end

function DataService.IsLoaded(player: Player): boolean
	local profile = profiles[player]
	return profile ~= nil and not profile.IsClosed(profile)
end

--[[
	Saves every loaded profile. Called on shutdown and available for manual
	flushes during testing.
]]
function DataService.SaveAll(): ()
	for _, profile in profiles do
		if not profile.IsClosed(profile) then
			local ok, err = profile.Save(profile, false)
			if not ok then
				warn(string.format("[DataService] Save failed for %s: %s", profile.Player.Name, tostring(err)))
			end
		end
	end
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

local started = false

local function onPlayerAdded(player: Player)
	local profile, err = loadProfile(player)

	if not profile then
		warn(string.format("[DataService] Kicking %s: %s", player.Name, tostring(err)))
		player:Kick("Could not load your save data. Please rejoin.")
		return
	end

	-- The player may have left while we were loading (a slow DataStore plus
	-- an impatient player). Releasing the lock is essential: leaving it held
	-- would make them wait out LOCK_TIMEOUT on their very next join.
	if not player:IsDescendantOf(Players) then
		profile.Save(profile, true)
		return
	end

	profiles[player] = profile

	DataService.ProfileLoaded:Fire(player, profile)
end

local function onPlayerRemoving(player: Player)
	local profile = profiles[player]
	if not profile then
		return
	end

	-- Announce first so listeners can still mutate the profile (a final
	-- quest-progress flush, a stats commit) before it is written.
	DataService.ProfileReleasing:Fire(player, profile)

	profiles[player] = nil

	local ok, err = profile.Save(profile, true)
	if not ok then
		warn(string.format("[DataService] Final save failed for %s: %s", player.Name, tostring(err)))
	end
end

function DataService.Start(): ()
	if started then
		return
	end
	started = true

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	-- Players who joined before this service started (or during a hot reload)
	-- still need profiles. Without this pass they would sit in a hub with no
	-- data and no error to explain why.
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	--[[
		Autosave. Bounds worst-case progress loss for a server that dies
		without running BindToClose (a hard crash, or a Roblox-side outage),
		where PlayerRemoving never fires.
	]]
	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_INTERVAL_SECONDS)

			for _, profile in profiles do
				if not profile.IsClosed(profile) then
					local ok, err = profile.Save(profile, false)
					if not ok then
						warn(
							string.format(
								"[DataService] Autosave failed for %s: %s",
								profile.Player.Name,
								tostring(err)
							)
						)
					end
				end
			end
		end
	end)

	--[[
		BindToClose has a hard ~30 second budget before Roblox kills the
		server. Saving sequentially would exceed it with a full hub, so saves
		run in parallel and we wait on all of them together.
	]]
	game:BindToClose(function()
		if RunService:IsStudio() then
			-- Studio closes instantly and does not need the full ceremony.
			-- Saving here would just slow down every playtest iteration.
			return
		end

		local pending = 0
		local done = false

		for _, profile in profiles do
			if not profile.IsClosed(profile) then
				pending += 1

				task.spawn(function()
					profile.Save(profile, true)
					pending -= 1
					if pending == 0 then
						done = true
					end
				end)
			end
		end

		if pending == 0 then
			done = true
		end

		local deadline = os.clock() + 25
		while not done and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

return DataService
