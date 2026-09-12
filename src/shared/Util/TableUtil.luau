--!strict
--[[
	TableUtil.luau

	Table helpers used by the persistence layer.
]]

local TableUtil = {}

--[[
	Deep copy. `table.clone` is shallow, which is not good enough for profile
	data: a shallow clone would leave the copy sharing its nested Currencies
	and Stats tables with the template, so mutating one player's Coins would
	mutate the template for everyone.

	Handles cycles is NOT a goal here -- profile data is a tree by design, and
	a cycle in it would be a bug worth surfacing rather than papering over.
]]
function TableUtil.deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end

	local source = value :: any
	local copy: any = {}

	for key, entry in pairs(source) do
		copy[TableUtil.deepCopy(key)] = TableUtil.deepCopy(entry)
	end

	return copy :: T
end

--[[
	Merges any keys present in `template` but missing from `target` into
	`target`, recursing into nested tables.

	This is what makes adding a field to the profile safe. A player who saved
	before the field existed loads a profile without it; running them through
	reconcile against the current template fills in the default without
	touching anything they already own. Without this, shipping a new schema
	field either wipes live profiles or errors everyone who joins.

	Existing values always win -- reconcile only ever ADDS missing keys.
]]
function TableUtil.reconcile(target: any, template: any): any
	if type(target) ~= "table" or type(template) ~= "table" then
		return target
	end

	for key, defaultValue in pairs(template) do
		local existing = target[key]

		if existing == nil then
			target[key] = TableUtil.deepCopy(defaultValue)
		elseif type(existing) == "table" and type(defaultValue) == "table" then
			TableUtil.reconcile(existing, defaultValue)
		end
	end

	return target
end

--[[
	Recursively freezes a table. Used on config tables so a stray write from
	feature code fails loudly at the point of the bug instead of silently
	rebalancing the game economy for the rest of the server's uptime.
]]
function TableUtil.deepFreeze<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end

	local source = value :: any
	for _, entry in pairs(source) do
		TableUtil.deepFreeze(entry)
	end

	return table.freeze(source) :: T
end

--[[
	Counts entries. Useful for telemetry and for asserting an inventory has
	not silently grown unbounded.
]]
function TableUtil.count(source: { [any]: any }): number
	local total = 0
	for _ in pairs(source) do
		total += 1
	end
	return total
end

return TableUtil
