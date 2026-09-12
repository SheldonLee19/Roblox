--!strict
--[[
	Economy.luau

	Every number that governs reward pacing lives here, so balancing is a
	config change rather than a hunt through service code.

	Design rules encoded below (see the plan's critique section):

	1. Podium-only Stars would mean 5 of every 8 players earn nothing, every
	   round, while Stars gate housing -- the game's main flex. That is how you
	   demoralise the majority of every lobby. So: everyone who plays earns
	   participation Stars, and podium places earn a bonus ON TOP.

	2. Coins are the casual currency and pay out generously, because Coins are
	   what fund cosmetics -- and cosmetics are what players show off.

	3. Both currencies need sinks or they inflate into meaninglessness. Sinks
	   live in the Housing / Vehicles / Marketplace configs.

	4. Gems are cosmetic-only and NEVER convert to Stars. If Gems could buy
	   Stars, the skill currency would stop meaning anything and the whole
	   prestige loop would collapse.
]]

local Economy = {}

-- Lobby size payouts scale against. A game with fewer players still pays the
-- same for a given placement -- we do not want a 4-player game to be worth
-- half a full one, or players will dodge small lobbies.
Economy.MaxPlayers = 8

--[[
	Stars: participation floor + placement bonus, added together.
	Index 1 == 1st place. Payout for finishing 8th is 1 Star, not 0 --
	showing up still moves you toward your next housing tier.
]]
Economy.ParticipationStars = 1
Economy.PlacementStars = { 9, 6, 4, 2, 1, 1, 0, 0 }

--[[
	Coins: same structure but far more generous. This is the currency that
	funds cosmetics, and cosmetics are the reason a casual player comes back.
]]
Economy.ParticipationCoins = 50
Economy.PlacementCoins = { 100, 70, 50, 35, 25, 20, 15, 15 }

--[[
	Consolation for a player eliminated before the round ended (fell in the
	lava on tile three). They still spent a queue slot and a loading screen;
	paying them nothing is how you teach someone not to queue again.
]]
Economy.EliminatedCoins = 20
Economy.EliminatedStars = 1

--[[
	Catch-up bonus. Applied when a player is on a losing streak, and it decays
	back to zero the moment they place well so it cannot be farmed by
	deliberately throwing. This is the rubber-band that keeps the bottom half
	of every lobby engaged -- party games live or die on this.
]]
Economy.CatchupLoserStreakThreshold = 3
Economy.CatchupStarsPerGame = 1
Economy.CatchupMaxStars = 5

--[[
	Anti-AFK. A player who never moves, never votes and never interacts earns
	nothing. Without this, the participation payout is a farm, and a lobby full
	of AFK farmers is a dead lobby.
]]
Economy.MinActivityScore = 0.15

--[[
	XP and account level.

	XPForLevel is linear-with-growth rather than exponential: the level track
	exists to hand out titles and badges early and often, not to be a grind
	wall. The long-term progression lives in housing tiers and vehicles.
]]
Economy.BaseXP = 40
Economy.PlacementXP = { 60, 45, 35, 25, 20, 15, 10, 10 }
Economy.XPPerLevelBase = 500
Economy.XPPerLevelGrowth = 150

--[[
	Returns the XP required to advance FROM `level` to `level + 1`.
]]
function Economy.XPForLevel(level: number): number
	local safeLevel = math.max(1, math.floor(level))
	return Economy.XPPerLevelBase + (safeLevel - 1) * Economy.XPPerLevelGrowth
end

--[[
	Converts a lifetime XP total into (level, xpIntoLevel).

	Total XP is stored rather than "xp toward next level" because a stored
	remainder has to be rewritten on every level-up, and any bug there is a
	permanently corrupted player. Lifetime total is idempotent: recomputing
	the level from it always gives the same answer.
]]
function Economy.LevelFromXP(totalXP: number): (number, number)
	local level = 1
	local remaining = math.max(0, totalXP)

	while remaining >= Economy.XPForLevel(level) do
		remaining -= Economy.XPForLevel(level)
		level += 1
	end

	return level, remaining
end

--[[
	Stars for a single player's round result.

	`placement` is 1-based and clamped -- a minigame reporting a placement
	outside 1..MaxPlayers is a bug in that minigame, and clamping here means
	it corrupts one reward instead of erroring the whole payout pass.
]]
function Economy.StarsForPlacement(placement: number): number
	local index = math.clamp(math.floor(placement), 1, Economy.MaxPlayers)
	return Economy.ParticipationStars + Economy.PlacementStars[index]
end

function Economy.CoinsForPlacement(placement: number): number
	local index = math.clamp(math.floor(placement), 1, Economy.MaxPlayers)
	return Economy.ParticipationCoins + Economy.PlacementCoins[index]
end

--[[
	Catch-up Stars for a player currently on `loserStreak` consecutive
	non-podium finishes. Zero below the threshold.
]]
function Economy.CatchupStars(loserStreak: number): number
	if loserStreak < Economy.CatchupLoserStreakThreshold then
		return 0
	end

	local over = loserStreak - Economy.CatchupLoserStreakThreshold + 1
	return math.min(over * Economy.CatchupStarsPerGame, Economy.CatchupMaxStars)
end

return Economy
