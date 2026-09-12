--!strict
--[[
	Game.luau

	Global game constants and the minigame roster.

	Note on server size: the original spec said "8 players per server", but the
	team chose public matchmaking alongside private parties and an in-world
	social hub. Those are incompatible with an 8-player hub -- a hub that only
	ever holds 8 people cannot feel social and cannot fill a queue. So the
	split is:

	  Hub place      : up to MaxHubPlayers, many parties + solo players
	  Minigame game  : up to MaxMinigamePlayers, one round at a time

	This is the standard Roblox party-game topology (hub server + game servers)
	and it is what makes "vote to play" actually fill.
]]

local Game = {}

Game.Title = "Tropical Archipelago"

Game.MaxHubPlayers = 24
Game.MaxMinigamePlayers = 8
Game.MinMinigamePlayers = 2

--[[
	Round phase timings, in seconds. Shared so the client can render an
	accurate countdown without the server streaming ticks.
]]
Game.Timings = {
	Voting = 15,
	Countdown = 5,
	Results = 12,
	Intermission = 8,
}

--[[
	Minigame roster.

	`Mode` drives which reusable framework module the game builds on:
	  Elimination - last player standing (shrinking arena / spleef)
	  Race        - first to the finish line
	  Survival    - outlast a timer or hazard
	  Score       - highest score when the clock ends

	Two of these carry a re-spec from the original proposal, flagged in
	`DesignNote` -- both were flagged as technical risks in the plan:

	  TikiFreeze  - Server-authoritative "freeze when the audio pauses" is not
	                fairly judgeable over Roblox's variable latency. Re-spec'd
	                to red-light/green-light with a visual signal and a
	                generous input window, which is latency-tolerant and,
	                frankly, more readable to a young audience anyway.

	  SharkAttack - Real-time voxel destruction of land chunks plus shark AI
	                plus 8 players is very expensive. Re-spec'd to a rising
	                tide line over a shrinking sandbar, which reuses the same
	                shrinking-arena module as Water Balloon Dodge.
]]
Game.Minigames = {
	-- Phase 1 -- MVP launch
	{
		Id = "VolcanoSpleef",
		Name = "Volcano Spleef",
		Phase = 1,
		Owner = "RoleA",
		Mode = "Elimination",
		MinPlayers = 2,
	},
	{
		Id = "WipeoutReef",
		Name = "Wipeout Reef",
		Phase = 1,
		Owner = "RoleB",
		Mode = "Race",
		MinPlayers = 2,
	},
	{
		Id = "TikiFreeze",
		Name = "Tiki Freeze",
		Phase = 1,
		Owner = "RoleC",
		Mode = "Survival",
		MinPlayers = 3,
		DesignNote = "Re-spec'd from audio-pause rhythm to latency-tolerant red-light/green-light.",
	},
	{
		Id = "WaterBalloonDodge",
		Name = "Water Balloon Dodge",
		Phase = 1,
		Owner = "RoleA",
		Mode = "Elimination",
		MinPlayers = 3,
	},

	-- Phase 2 -- post-launch content drops
	{
		Id = "JetSkiBlitz",
		Name = "Jet Ski Blitz",
		Phase = 2,
		Owner = "RoleB",
		Mode = "Race",
		MinPlayers = 2,
	},
	{
		Id = "SharkAttack",
		Name = "Shark Attack",
		Phase = 2,
		Owner = "RoleC",
		Mode = "Survival",
		MinPlayers = 3,
		DesignNote = "Re-spec'd from voxel land destruction to a rising tide over a shrinking sandbar.",
	},
	{
		Id = "CoconutClash",
		Name = "Coconut Clash",
		Phase = 2,
		Owner = "RoleA",
		Mode = "Score",
		MinPlayers = 4,
		TeamBased = true,
	},
	{
		Id = "TreasureHunt",
		Name = "Treasure Hunt",
		Phase = 2,
		Owner = "RoleB",
		Mode = "Race",
		MinPlayers = 2,
	},
	{
		Id = "PaddlePanic",
		Name = "Paddle Panic",
		Phase = 2,
		Owner = "RoleC",
		Mode = "Survival",
		MinPlayers = 2,
	},
	{
		Id = "VineSwingRace",
		Name = "Vine Swing Race",
		Phase = 2,
		Owner = "RoleA",
		Mode = "Race",
		MinPlayers = 2,
	},
}

-- Fast lookup by id, built once at require time.
Game.MinigameById = {} :: { [string]: any }
for _, minigame in Game.Minigames do
	Game.MinigameById[minigame.Id] = minigame
end

--[[
	Only Phase 1 games are selectable at launch. Keeping the Phase 2 entries
	in the roster above (rather than commenting them out) means the voting UI,
	the matchmaking service and the teleport payloads are all built against
	the real list from day one -- adding a Phase 2 game becomes a data change,
	not an architecture change.
]]
function Game.GetPlayableMinigames(): { any }
	local playable = {}
	for _, minigame in Game.Minigames do
		if minigame.Phase == 1 then
			table.insert(playable, minigame)
		end
	end
	return playable
end

return Game
