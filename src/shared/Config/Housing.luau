--!strict
--[[
	Housing.luau

	Villa tiers and their Star costs.

	Stars, not Coins. The whole point of the housing ladder is that a finished
	villa is an unfakeable statement of skill -- if Coins bought it, it would
	just be a statement of hours played, and Gems must never touch it at all.

	Costs are tuned against the payout in Config/Economy: a mid-table finish is
	worth roughly 2-3 Stars, so Tier 1 lands around ten games in, and the top
	tier is a genuine long-term goal rather than a weekend. Re-tune these
	together with the Economy numbers or not at all -- changing one without the
	other is how the ladder silently becomes either trivial or unreachable.
]]

local Housing = {}

Housing.MaxTier = 5

--[[
	Each tier names the Art asset that should be rendered for it. WorldService
	and HousingService look the model up by name in ReplicatedStorage.Assets.
	Villas; when it is missing they fall back to a generated placeholder, so
	the game is playable before any art exists and gains fidelity the moment
	an artist drops in a matching model -- with no code change.
]]
Housing.Tiers = {
	{ Tier = 0, Name = "Empty Plot", AssetName = "Villa_Tier0", StarCost = 0 },
	{ Tier = 1, Name = "Beach Tent", AssetName = "Villa_Tier1", StarCost = 25 },
	{ Tier = 2, Name = "Beach Hut", AssetName = "Villa_Tier2", StarCost = 75 },
	{ Tier = 3, Name = "Bungalow", AssetName = "Villa_Tier3", StarCost = 180 },
	{ Tier = 4, Name = "Two-Story House", AssetName = "Villa_Tier4", StarCost = 400 },
	{ Tier = 5, Name = "Luxury Villa", AssetName = "Villa_Tier5", StarCost = 800 },
}

--[[
	Approximate footprint of a villa, used to size the placeholder geometry and
	to place the plot marker. Kept generous so a real model has room to be
	bigger than the placeholder without clipping into the water.
]]
Housing.FootprintRadius = 34

function Housing.GetTier(tier: number): any?
	for _, entry in Housing.Tiers do
		if entry.Tier == tier then
			return entry
		end
	end
	return nil
end

--[[
	Star cost to go from `currentTier` to `currentTier + 1`, or nil when the
	player is already at the top. Returning nil rather than a sentinel number
	means a caller that forgets to check cannot accidentally charge a real
	price for a maxed-out plot.
]]
function Housing.GetUpgradeCost(currentTier: number): number?
	if currentTier >= Housing.MaxTier then
		return nil
	end

	local nextTier = Housing.GetTier(currentTier + 1)
	if not nextTier then
		return nil
	end

	return nextTier.StarCost
end

return Housing
