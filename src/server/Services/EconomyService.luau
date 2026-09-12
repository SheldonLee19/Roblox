--!strict
--[[
	EconomyService.luau

	The single writer for currency balances and round payouts.

	Every currency mutation in the game goes through here. That is deliberate:
	when three people own ten minigames between them, the fastest way to end up
	with an economy that cannot be balanced is to let each game pay out on its
	own terms. A minigame reports *results* (who placed where); this service
	decides what those results are worth.

	Two rules are enforced here rather than documented and hoped for:

	  1. Gems never convert to Stars. Stars are the skill signal -- if they
	     could be bought, the prestige loop that the whole housing system rests
	     on would be meaningless.

	  2. Gems never convert to Coins. Coins are the casual-earn currency;
	     letting Gems buy Coins would make every Coin sink effectively
	     purchasable and collapse the two-track economy into one.

	Gems buy cosmetic items directly and nothing else.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Types = require(Shared.Types)
local Economy = require(Shared.Config.Economy)
local Net = require(Shared.Framework.Net)

local DataService = require(script.Parent.DataService)

local EconomyService = {}

-- How many top finishers count as "on the podium" and reset the loser streak.
local PODIUM_THRESHOLD = 3

local function placementIndex(placement: number): number
	return math.clamp(math.floor(placement), 1, Economy.MaxPlayers)
end

--------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------

function EconomyService.GetBalance(player: Player): Types.CurrencyMap?
	local profile = DataService.GetProfile(player)
	if not profile then
		return nil
	end
	return profile.Data.Currencies
end

function EconomyService.CanAfford(player: Player, currency: Types.Currency, amount: number): boolean
	local balance = EconomyService.GetBalance(player)
	if not balance then
		return false
	end
	return balance[currency] >= amount
end

--------------------------------------------------------------------------
-- Writing
--------------------------------------------------------------------------

local function pushBalance(player: Player, profile: any)
	Net.FireClient("CurrencyChanged", player, profile.Data.Currencies)
end

--[[
	Grants currency. Refuses negative and non-finite amounts -- a NaN that
	reaches a balance is a permanently corrupted save, because every
	comparison against NaN is false, so `balance >= cost` silently fails
	forever and the player can never buy anything again.
]]
function EconomyService.Grant(
	player: Player,
	currency: Types.Currency,
	amount: number
): boolean
	if amount <= 0 or amount ~= amount or amount == math.huge then
		warn(string.format("[EconomyService] Refusing to grant %s %s", tostring(amount), currency))
		return false
	end

	local profile = DataService.GetProfile(player)
	if not profile then
		return false
	end

	profile.Data.Currencies[currency] += amount
	pushBalance(player, profile)

	return true
end

--[[
	Attempts to spend currency. Returns (true) or (false, reason).

	The balance is re-checked here rather than trusting a caller's earlier
	CanAfford: between the check and the spend there is always a yield, and
	two rapid purchases can both pass a stale check. This is the only place
	that decides whether a purchase is affordable.
]]
function EconomyService.TrySpend(
	player: Player,
	currency: Types.Currency,
	amount: number
): (boolean, string?)
	if amount < 0 or amount ~= amount then
		return false, "Invalid amount"
	end

	local profile = DataService.GetProfile(player)
	if not profile then
		return false, "No profile loaded"
	end

	local balance = profile.Data.Currencies
	if balance[currency] < amount then
		return false, string.format("Not enough %s", currency)
	end

	balance[currency] -= amount
	pushBalance(player, profile)

	return true, nil
end

--[[
	Exchange between currencies.

	Deliberately supports exactly one direction: Gems -> nothing. Gems are a
	terminal currency. Purchases that consume Gems go through TrySpend; there
	is no path from Gems back into Stars or Coins, and adding one here would
	be the single change most likely to break the game's progression.
]]
function EconomyService.Convert(player: Player, from: Types.Currency, to: Types.Currency, amount: number): (boolean, string?)
	if from == "Gems" or to == "Gems" then
		return false, "Gems are a terminal currency and cannot be converted"
	end

	return false, string.format("Conversion from %s to %s is not supported", from, to)
end

--------------------------------------------------------------------------
-- Round payouts
--------------------------------------------------------------------------

--[[
	Computes what a single player's round is worth, without applying it.

	Separated from application so the results screen can display a breakdown,
	and so simulations can price an economy change without touching a live
	profile.
]]
function EconomyService.ComputeRewards(
	profile: any,
	placement: number,
	finished: boolean,
	activityScore: number
): Types.RewardBreakdown
	local data = profile.Data
	local index = placementIndex(placement)

	local starsBase: number
	local starsPlacement: number

	if finished then
		starsBase = Economy.ParticipationStars
		starsPlacement = Economy.PlacementStars[index]
	else
		-- Eliminated early. They still get a consolation, but no placement
		-- bonus -- otherwise deliberate early elimination becomes a viable
		-- farm for a player who wants out of a losing round quickly.
		starsBase = Economy.EliminatedStars
		starsPlacement = 0
	end

	local coinsBase: number
	local coinsPlacement: number

	if finished then
		coinsBase = Economy.ParticipationCoins
		coinsPlacement = Economy.PlacementCoins[index]
	else
		coinsBase = Economy.EliminatedCoins
		coinsPlacement = 0
	end

	local starsCatchup = Economy.CatchupStars(data.Stats.LoserStreak)

	--[[
		Anti-AFK gate. A player who never moved earns nothing this round.
		Applied to the whole payout rather than a fraction: a partial payout
		is still worth farming with an autoclicker, and a lobby of AFK
		farmers is a lobby nobody wants to be matched into.
	]]
	if activityScore < Economy.MinActivityScore then
		starsBase, starsPlacement, starsCatchup = 0, 0, 0
		coinsBase, coinsPlacement = 0, 0
	end

	local starsTotal = starsBase + starsPlacement + starsCatchup
	local coinsTotal = coinsBase + coinsPlacement
	local xp = Economy.BaseXP + Economy.PlacementXP[index]

	return {
		StarsBase = starsBase,
		StarsPlacement = starsPlacement,
		StarsCatchup = starsCatchup,
		CoinsBase = coinsBase,
		CoinsPlacement = coinsPlacement,
		XP = xp,
		StarsTotal = starsTotal,
		CoinsTotal = coinsTotal,
		NewLevel = nil,
	}
end

--[[
	Applies a computed reward to a profile: currencies, XP, level, stats and
	the loser streak. Returns the breakdown with NewLevel filled in when the
	payout pushed the player over a level boundary.
]]
function EconomyService.ApplyRewards(
	player: Player,
	profile: any,
	breakdown: Types.RewardBreakdown
): Types.RewardBreakdown
	local data = profile.Data
	local currencies = data.Currencies

	currencies.Stars += breakdown.StarsTotal
	currencies.Coins += breakdown.CoinsTotal

	-- Lifetime totals are tracked separately from the current balance, since
	-- the balance is spent down over time. These feed leaderboards.
	data.Stats.StarsEarned += breakdown.StarsTotal
	data.Stats.CoinsEarned += breakdown.CoinsTotal

	local previousLevel = data.Progression.Level
	data.Progression.XP += breakdown.XP
	local newLevel = Economy.LevelFromXP(data.Progression.XP)
	data.Progression.Level = newLevel

	if newLevel > previousLevel then
		breakdown.NewLevel = newLevel
	end

	pushBalance(player, profile)

	return breakdown
end

--[[
	Updates the stats that the catch-up system and leaderboards depend on.

	Called once per player per round, after the payout. Kept separate from
	ApplyRewards because a player's placement affects their *streak*, not
	their payout for this round -- the streak bonus they receive is the one
	they walked in with.
]]
function EconomyService.RecordPlacement(profile: any, placement: number, finished: boolean): ()
	local stats = profile.Data.Stats

	stats.GamesPlayed += 1

	if placement == 1 then
		stats.GamesWon += 1
	end

	--[[
		A podium only counts if the player actually finished. An eliminated
		player's placement is an elimination-order rank, not a result, so a
		player knocked out third must not have their losing streak reset --
		otherwise the catch-up bonus would trigger hardest for exactly the
		players it is meant to help, and never pay out at all.
	]]
	local onPodium = finished and placement <= PODIUM_THRESHOLD

	if onPodium then
		stats.Podiums += 1
		-- A podium finish resets the streak. Without this reset the bonus
		-- would accrue forever and stop being a catch-up mechanic at all.
		stats.LoserStreak = 0
	else
		stats.LoserStreak += 1
	end
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

local started = false

function EconomyService.Start(): ()
	if started then
		return
	end
	started = true

	--[[
		Push the balance as soon as a profile loads. The client renders
		currency in the hub immediately on join, and waiting for the first
		change event would leave it showing zeroes until the player earned
		something.
	]]
	DataService.ProfileLoaded:Connect(function(player: Player, profile: any)
		Net.FireClient("CurrencyChanged", player, profile.Data.Currencies)
	end)

	-- The client can ask again after a reconnect or a UI reload.
	Net.OnServerEvent("RequestProfile", function(player: Player)
		local profile = DataService.GetProfile(player)
		if not profile then
			return
		end
		Net.FireClient("CurrencyChanged", player, profile.Data.Currencies)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		Net.ClearPlayer(player)
	end)
end

return EconomyService
