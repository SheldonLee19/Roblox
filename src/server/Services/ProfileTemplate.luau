--!strict
--[[
	ProfileTemplate.luau

	The default profile for a brand-new player, plus the migration entry point
	for profiles written by older builds.

	Every field a player can own is declared here with a sensible default, so
	the rest of the codebase can assume the shape exists and never has to write
	`if profile.Data.Housing and profile.Data.Housing.Tier then`.

	Adding a field: add it to create() below AND bump CURRENT_SCHEMA_VERSION.
	Existing profiles are repaired automatically by migrate() via
	TableUtil.reconcile, so no bespoke migration code is needed for purely
	additive changes. Removing or renaming a field DOES need real migration
	code here -- reconcile only ever adds.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Types = require(Shared.Types)
local TableUtil = require(Shared.Util.TableUtil)

local ProfileTemplate = {}

ProfileTemplate.CURRENT_SCHEMA_VERSION = 1

--[[
	Starter grants.

	New players get a small Coin float and the basic wooden raft. Coins, not
	Stars: Stars are the skill signal and must be earned, never handed out.
	The raft matters because vehicles are how a player first feels ownership --
	and it is the thing the onboarding flow asks them to try first.
]]
ProfileTemplate.STARTER_COINS = 250
ProfileTemplate.STARTER_VEHICLE = "Raft"
ProfileTemplate.STARTER_HOUSING_TIER = 0

function ProfileTemplate.create(): Types.ProfileData
	local now = os.time()

	return {
		SchemaVersion = ProfileTemplate.CURRENT_SCHEMA_VERSION,

		Currencies = {
			Stars = 0,
			Coins = ProfileTemplate.STARTER_COINS,
			Gems = 0,
		},

		Progression = {
			XP = 0,
			Level = 1,
		},

		Housing = {
			Tier = ProfileTemplate.STARTER_HOUSING_TIER,
			PlotIndex = nil,
			Decor = {},
		},

		Vehicles = {
			Owned = { ProfileTemplate.STARTER_VEHICLE },
			Equipped = ProfileTemplate.STARTER_VEHICLE,
		},

		Cosmetics = {
			Owned = {},
			Equipped = {},
		},

		Stats = {
			GamesPlayed = 0,
			GamesWon = 0,
			Podiums = 0,
			StarsEarned = 0,
			CoinsEarned = 0,
			LoserStreak = 0,
		},

		Daily = {
			LastLoginDay = 0,
			LoginStreak = 0,
			Quests = {},
			QuestsClaimed = {},
		},

		CreatedAt = now,
		LastSaved = now,
	}
end

--[[
	Repairs a loaded profile against the current template.

	Called on every load rather than only when the schema version differs:
	reconcile is cheap, and running it unconditionally means a profile that was
	partially written by a crashed server (or hand-edited during testing) is
	repaired on next join instead of erroring deep inside a service.
]]
function ProfileTemplate.migrate(data: any): Types.ProfileData
	local template = ProfileTemplate.create()

	-- Preserve the original creation time -- reconcile would fill it with
	-- "now" if it were missing, but only if we let the template win, and we
	-- never want the template to win over real data.
	local createdAt = data.CreatedAt

	TableUtil.reconcile(data, template)

	if createdAt ~= nil then
		data.CreatedAt = createdAt
	end

	-- Clamp anything a previous build (or a bug) could have written out of
	-- range, so downstream code can trust these invariants.
	data.Currencies.Stars = math.max(0, math.floor(data.Currencies.Stars))
	data.Currencies.Coins = math.max(0, math.floor(data.Currencies.Coins))
	data.Currencies.Gems = math.max(0, math.floor(data.Currencies.Gems))
	data.Progression.XP = math.max(0, math.floor(data.Progression.XP))
	data.Housing.Tier = math.max(0, math.floor(data.Housing.Tier))
	data.Stats.LoserStreak = math.max(0, math.floor(data.Stats.LoserStreak))

	if data.Vehicles.Equipped == nil or not table.find(data.Vehicles.Owned, data.Vehicles.Equipped) then
		data.Vehicles.Equipped = data.Vehicles.Owned[1]
	end

	data.SchemaVersion = ProfileTemplate.CURRENT_SCHEMA_VERSION

	return data
end

return ProfileTemplate
