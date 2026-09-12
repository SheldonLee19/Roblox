--!strict
--[[
	Server bootstrap.

	Start order is load-bearing and is the one thing to be careful about when
	adding a service here:

	  DataService first, always. Every other service reads and writes player
	  profiles, and each assumes that by the time it sees a player, that
	  player's data is loaded and locked. DataService owns PlayerAdded, so
	  starting it first is what guarantees the ProfileLoaded signal fires
	  before anything else tries to touch a profile.

	  EconomyService next. It listens for ProfileLoaded to push the initial
	  balance to the client, and it is the writer every gameplay service
	  pays out through.

	Adding a service that depends on the economy therefore goes after both.
	There is no dependency graph here on purpose -- with a three-person team
	and a handful of services, an explicit ordered list is easier to read and
	debug than a container that resolves dependencies invisibly.
]]

local DataService = require(script.Services.DataService)
local EconomyService = require(script.Services.EconomyService)

DataService.Start()
EconomyService.Start()

print("[Tropical Archipelago] Server ready.")
