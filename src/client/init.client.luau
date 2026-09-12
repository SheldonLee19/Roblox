--!strict
--[[
	Client bootstrap.

	The client is a view layer. It renders state the server owns and sends
	intents; it never decides an outcome. Anything the client computes about
	currency, placement or ownership is a prediction to be displayed, not a
	value to be trusted -- the server re-derives all of it.

	Right now this wires up the currency readout, which is enough to prove the
	full round trip works end to end: DataStore -> DataService -> EconomyService
	-> Net -> client. Building the hub UI comes next.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Net = require(Shared.Framework.Net)

local player = Players.LocalPlayer

--[[
	Mirrors the server's authoritative balance so UI can read it without
	re-requesting. Written only from server events -- never mutated locally,
	or the displayed balance would drift from the real one and the player
	would see a purchase fail that their UI said they could afford.
]]
local balance = {
	Stars = 0,
	Coins = 0,
	Gems = 0,
}

Net.OnClientEvent("CurrencyChanged", function(newBalance)
	balance.Stars = newBalance.Stars
	balance.Coins = newBalance.Coins
	balance.Gems = newBalance.Gems

	print(
		string.format(
			"[Currency] Stars: %d  Coins: %d  Gems: %d",
			balance.Stars,
			balance.Coins,
			balance.Gems
		)
	)
end)

-- Ask for the balance once the server is listening. The server also pushes it
-- on profile load; this covers the case where the profile loaded before this
-- script ran (a slow client on a fast DataStore read).
task.spawn(function()
	task.wait(2)
	Net.FireServer("RequestProfile")
end)

return nil
