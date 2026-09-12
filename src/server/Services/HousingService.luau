--!strict
--[[
	HousingService.luau

	Owns the ring of housing plots: who is standing on which one, what villa is
	rendered there, and what an upgrade costs.

	############################################################################
	# DESIGN PROBLEM -- READ BEFORE BUILDING ON THIS                               #
	#                                                                            #
	# There are 8 housing plots but the hub holds up to 24 players. At any moment #
	# at least 16 players in the hub have nowhere to put their villa, and it is   #
	# the players who joined last -- the newest, most easily-lost players -- who  #
	# get nothing. Their island simply does not appear.                           #
	#                                                                            #
	# This is not an implementation detail. It is the direct consequence of       #
	# combining "8 fixed in-world plots" with "public matchmaking needs more than #
	# 8 players in the hub". The two decisions are in tension and one has to give.#
	#                                                                            #
	# The options, none of them free:                                            #
	#   a) 1 plot per hub player -- drop the hub to 8, and public matchmaking     #
	#      gets much harder to fill.                                              #
	#   b) Many more plots -- 24 plots makes the ring enormous and dilutes the    #
	#      flex, since everyone has one.                                          #
	#   c) Plots are a rotating showcase -- only 8 visible, assigned to whoever   #
	#      is currently in the hub, everyone else sees their villa only when they #
	#      get a slot.                                                            #
	#   d) Villas render on a *per-player* basis (instanced), which contradicts   #
	#      the in-world shared decision but removes the cap entirely.             #
	#                                                                            #
	# Current behaviour is (c): first-come, first-served, freed on leave. It is   #
	# playable and honest, but it needs a real decision before launch.            #
	############################################################################

	Plot count is a config value (Config/World.Islands.PlotCount), so changing
	the answer is a one-line change plus a layout re-tune.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Housing = require(Shared.Config.Housing)
local Net = require(Shared.Framework.Net)

local DataService = require(script.Parent.DataService)
local EconomyService = require(script.Parent.EconomyService)
local WorldService = require(script.Parent.WorldService)

local HousingService = {}

-- plotIndex -> player currently occupying it.
local plotOwners: { [number]: Player } = {}

--------------------------------------------------------------------------
-- Plot assignment
--------------------------------------------------------------------------

local function claimPlot(player: Player, profile: any): number?
	local saved = profile.Data.Housing.PlotIndex

	-- Prefer the plot they had last time. If they rejoined quickly they get
	-- their own island back, which matters for the flex -- landing on someone
	-- else's plot would be jarring.
	if saved ~= nil and plotOwners[saved] == nil then
		plotOwners[saved] = player
		return saved
	end

	for index = 1, WorldService.GetPlotCount() do
		if plotOwners[index] == nil then
			plotOwners[index] = player
			return index
		end
	end

	return nil
end

local function releasePlot(player: Player): ()
	for index, owner in plotOwners do
		if owner == player then
			plotOwners[index] = nil
			HousingService.ClearVilla(index)
		end
	end
end

--------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------

--[[
	Removes whatever villa is currently on a plot.

	Clears the dedicated "Villa" folder rather than the whole plot model, so
	the island and its pad survive -- the terrain is the world's, only the
	building is the player's.
]]
function HousingService.ClearVilla(plotIndex: number): ()
	local plot = WorldService.GetPlot(plotIndex)
	if not plot then
		return
	end

	local holder = plot:FindFirstChild("Villa")
	if not holder then
		return
	end

	holder:ClearAllChildren()
end

--[[
	Sends the owning client everything it needs to render the island panel.

	Single definition rather than scattered FireClient calls: the client's
	panel has to be correct after a fresh join, after an upgrade, and after a
	re-request, and three copies of this payload is how those three cases drift
	apart.
]]
local function pushHousingState(player: Player, profile: any): ()
	local plotIndex = profile.Data.Housing.PlotIndex
	local tier = profile.Data.Housing.Tier
	local tierInfo = Housing.GetTier(tier)
	local nextInfo = Housing.GetTier(tier + 1)

	-- Without a plot there is nothing to upgrade, so no cost is offered even
	-- if the player is at a tier they could otherwise afford.
	local hasPlot = plotIndex ~= nil

	Net.FireClient("HousingUpdated", player, {
		HasPlot = hasPlot,
		PlotIndex = plotIndex,
		Tier = tier,
		TierName = tierInfo and tierInfo.Name or "Unknown",
		NextTierName = nextInfo and nextInfo.Name or nil,
		UpgradeCost = if hasPlot then Housing.GetUpgradeCost(tier) else nil,
	})
end

--[[
	Renders the player's villa on their plot at their current tier.

	Looks for an artist-authored model first and falls back to generated
	placeholder geometry. That fallback is the entire art pipeline: drop
	"Villa_Tier3" into ReplicatedStorage.Assets.Villas and tier 3 upgrades
	themselves everywhere, with no code change and no rebuild.
]]
function HousingService.RenderVilla(player: Player, profile: any): ()
	local plotIndex = profile.Data.Housing.PlotIndex
	if plotIndex == nil then
		return
	end

	local plot = WorldService.GetPlot(plotIndex)
	if not plot then
		return
	end

	local holder = plot:FindFirstChild("Villa")
	if not holder then
		return
	end

	holder:ClearAllChildren()

	local tier = profile.Data.Housing.Tier
	local tierInfo = Housing.GetTier(tier)
	if not tierInfo then
		return
	end

	local position, topY = WorldService.GetPlotPlacement(plotIndex)
	if not position then
		return
	end

	local asset = WorldService.FindAsset("Villas", tierInfo.AssetName)
	local villa: Model

	if asset then
		villa = asset:Clone()
		-- Put the model's own origin on the pad rather than guessing at its
		-- internal offsets. A model authored with its base at its pivot drops
		-- in correctly; artists should keep that convention.
		villa:PivotTo(CFrame.new(position.X, topY, position.Z))
	else
		villa = WorldService.BuildVillaPlaceholder(tier, position, topY)
	end

	villa.Name = string.format("Tier%d", tier)
	-- Tag it so the owner can be identified in-game (nameplate flair, and for
	-- debugging conflicts).
	villa:SetAttribute("OwnerUserId", player.UserId)
	villa:SetAttribute("OwnerName", player.Name)
	villa:SetAttribute("Tier", tier)
	villa.Parent = holder

	-- Tell the owning client what they are looking at. The client renders the
	-- upgrade button from this; it never decides the price or whether an
	-- upgrade is allowed, it just displays what the server reports.
	pushHousingState(player, profile)
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

local function onProfileLoaded(player: Player, profile: any): ()
	local plotIndex = claimPlot(player, profile)

	profile.Data.Housing.PlotIndex = plotIndex

	if plotIndex == nil then
		-- All plots taken. Tell the player rather than silently rendering
		-- nothing -- an unexplained missing island reads as a bug.
		pushHousingState(player, profile)

		Net.FireClient(
			"Notification",
			player,
			"All island plots are taken right now. You'll get one when a plot frees up."
		)
		return
	end

	HousingService.RenderVilla(player, profile)
end

--------------------------------------------------------------------------
-- Upgrades
--------------------------------------------------------------------------

local function handleUpgrade(player: Player)
	local profile = DataService.GetProfile(player)
	if not profile then
		return
	end

	local currentTier = profile.Data.Housing.Tier
	local cost = Housing.GetUpgradeCost(currentTier)

	if cost == nil then
		Net.FireClient("Notification", player, "Your island is already fully upgraded.")
		return
	end

	--[[
		Note there is no yield between the balance check inside TrySpend and
		the tier increment below. That is what makes this safe against a
		double-fire: Luau coroutines only interleave at yield points, so two
		rapid UpgradeHousing calls cannot both observe the old tier. If anyone
		ever adds a yield in here (a web call, a wait), this becomes a
		double-upgrade bug and needs an explicit lock.
	]]
	local ok, err = EconomyService.TrySpend(player, "Stars", cost)
	if not ok then
		Net.FireClient(
			"Notification",
			player,
			string.format(
				"%s You need %d Stars and have %d.",
				tostring(err),
				cost,
				profile.Data.Currencies.Stars
			)
		)
		return
	end

	profile.Data.Housing.Tier = currentTier + 1
	HousingService.RenderVilla(player, profile)

	local newTierInfo = Housing.GetTier(currentTier + 1)
	Net.FireClient(
		"Notification",
		player,
		string.format("Upgraded to %s!", newTierInfo and newTierInfo.Name or "the next tier")
	)
end

local started = false

function HousingService.Start(): ()
	if started then
		return
	end
	started = true

	DataService.ProfileLoaded:Connect(onProfileLoaded)

	Players.PlayerRemoving:Connect(function(player: Player)
		releasePlot(player)
	end)

	Net.OnServerEvent("UpgradeHousing", handleUpgrade)

	--[[
		Answer a client re-request. Net permits several listeners on one event,
		and EconomyService already listens for this to resend the balance --
		this is the same handshake for housing state.

		It is not redundant: the client can start after the server has already
		fired ProfileLoaded, in which case the initial HousingUpdated went out
		before anyone was listening and the island panel would stay empty
		forever. Re-rendering here also re-asserts the villa, which doubles as
		a repair path if a plot was cleared for any reason.
	]]
	Net.OnServerEvent("RequestProfile", function(player: Player)
		local profile = DataService.GetProfile(player)
		if not profile then
			return
		end

		if profile.Data.Housing.PlotIndex ~= nil then
			HousingService.RenderVilla(player, profile)
		else
			pushHousingState(player, profile)
		end
	end)
end

return HousingService
