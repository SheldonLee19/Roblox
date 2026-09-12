--!strict
--[[
	Types.luau

	Shared type definitions for Tropical Archipelago.

	Every network payload and the persisted profile schema are declared here
	so the server and client can never drift apart. If a field is added to the
	profile, it is added here first and the compiler finds every consumer.

	Schema changes MUST bump ProfileData.SchemaVersion and be accompanied by a
	migration in DataService -- otherwise live players load a profile that is
	missing fields and the game errors on join.
]]

-- Three currencies, deliberately separated (see plan):
--   Stars - skill/prestige. Earned by placing well. NEVER purchasable.
--   Coins - casual/flex. Earned by playing at all.
--   Gems  - premium. Bought with Robux. COSMETIC ONLY -- never touches Stars.
export type Currency = "Stars" | "Coins" | "Gems"

export type CurrencyMap = {
	Stars: number,
	Coins: number,
	Gems: number,
}

export type Progression = {
	XP: number,
	Level: number,
}

export type Housing = {
	-- 0 == bare plot, 1 == beach tent, ... Highest tier == luxury villa.
	Tier: number,
	-- Which of the 8 island plots this player owns. Assigned on first join.
	PlotIndex: number?,
	Decor: { string },
}

export type Vehicles = {
	Owned: { string },
	Equipped: string?,
}

-- Cosmetics are keyed by slot so equipping a new hat cannot unequip a trail.
export type Cosmetics = {
	Owned: { string },
	Equipped: { [string]: string },
}

export type Stats = {
	GamesPlayed: number,
	GamesWon: number,
	Podiums: number,
	StarsEarned: number,
	CoinsEarned: number,
	-- Consecutive games finished outside the podium. Drives the catch-up
	-- bonus that keeps casual players from churning (see Economy config).
	LoserStreak: number,
}

export type DailyState = {
	-- os.time() day number (floor(now / 86400)), not a calendar date.
	LastLoginDay: number,
	LoginStreak: number,
	-- questId -> progress toward that quest's goal.
	Quests: { [string]: number },
	QuestsClaimed: { [string]: boolean },
}

export type ProfileData = {
	SchemaVersion: number,

	Currencies: CurrencyMap,
	Progression: Progression,
	Housing: Housing,
	Vehicles: Vehicles,
	Cosmetics: Cosmetics,
	Stats: Stats,
	Daily: DailyState,

	CreatedAt: number,
	LastSaved: number,
}

--[[
	Result of a single minigame round, as reported by a minigame implementation
	back to MinigameService. `Placement` is 1-based; a player who was eliminated
	early still receives a placement (they are ranked by elimination order).
]]
export type RoundResult = {
	Player: Player,
	Placement: number,
	-- False when the player was eliminated rather than surviving to the end.
	Finished: boolean,
	-- Optional per-game scoreboard detail for the results screen.
	Score: number?,
}

export type RoundOutcome = {
	MinigameId: string,
	TotalPlayers: number,
	Results: { RoundResult },
}

--[[
	Reward breakdown handed to the client for the post-game results screen.
	Sent as explicit components rather than one total so the UI can show the
	player *why* they earned what they earned -- the reward explanation is a
	big part of the retention loop.
]]
export type RewardBreakdown = {
	StarsBase: number,
	StarsPlacement: number,
	StarsCatchup: number,
	CoinsBase: number,
	CoinsPlacement: number,
	XP: number,
	StarsTotal: number,
	CoinsTotal: number,
	NewLevel: number?,
}

return {}
