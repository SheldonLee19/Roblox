--!strict
--[[
	Client bootstrap and placeholder HUD.

	The client is a view layer. It renders state the server owns and sends
	intents; it never decides an outcome. The upgrade button below does not
	know the price of anything -- it displays the number the server sent and
	asks to upgrade. Whether that succeeds, and what it costs, is decided
	server-side.

	This HUD is deliberately code-built and ugly-but-legible. It exists so the
	housing and economy systems can be exercised in-game today. The real hub
	UI replaces it wholesale.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Framework.Net)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local THEME = {
	Panel = Color3.fromRGB(16, 24, 32),
	Accent = Color3.fromRGB(64, 196, 255),
	Warm = Color3.fromRGB(255, 176, 59),
	Text = Color3.fromRGB(240, 245, 250),
	Muted = Color3.fromRGB(150, 165, 180),
}

--------------------------------------------------------------------------
-- UI helpers
--------------------------------------------------------------------------

local function addCorner(parent: Instance, radius: number): UICorner
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
	return corner
end

local function addPadding(parent: Instance, px: number): UIPadding
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, px)
	padding.PaddingBottom = UDim.new(0, px)
	padding.PaddingLeft = UDim.new(0, px)
	padding.PaddingRight = UDim.new(0, px)
	padding.Parent = parent
	return padding
end

local function makePanel(parent: Instance, name: string, size: UDim2, position: UDim2): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Size = size
	frame.Position = position
	frame.BackgroundColor3 = THEME.Panel
	frame.BackgroundTransparency = 0.15
	frame.BorderSizePixel = 0
	frame.Parent = parent
	addCorner(frame, 10)
	return frame
end

local function makeLabel(parent: Instance, name: string, text: string, size: UDim2, position: UDim2): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.Size = size
	label.Position = position
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamMedium
	label.Text = text
	label.TextColor3 = THEME.Text
	label.TextSize = 16
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = parent
	return label
end

--------------------------------------------------------------------------
-- HUD
--------------------------------------------------------------------------

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "TropicalHUD"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.Parent = playerGui

-- Currency readout ------------------------------------------------------

local currencyPanel = makePanel(screenGui, "Currency", UDim2.fromOffset(230, 108), UDim2.fromOffset(16, 16))
addPadding(currencyPanel, 12)

local currencyTitle = makeLabel(currencyPanel, "Title", "TROPICAL ARCHIPELAGO", UDim2.new(1, 0, 0, 16), UDim2.new(0, 0, 0, 0))
currencyTitle.Font = Enum.Font.GothamBold
currencyTitle.TextSize = 12
currencyTitle.TextColor3 = THEME.Muted

local starsLabel = makeLabel(currencyPanel, "Stars", "★  0 Stars", UDim2.new(1, 0, 0, 22), UDim2.new(0, 0, 0, 24))
starsLabel.TextColor3 = THEME.Warm
starsLabel.TextSize = 18
starsLabel.Font = Enum.Font.GothamBold

local coinsLabel = makeLabel(currencyPanel, "Coins", "●  0 Coins", UDim2.new(1, 0, 0, 20), UDim2.new(0, 0, 0, 50))
local gemsLabel = makeLabel(currencyPanel, "Gems", "◆  0 Gems", UDim2.new(1, 0, 0, 20), UDim2.new(0, 0, 0, 72))
gemsLabel.TextColor3 = Color3.fromRGB(190, 140, 255)

-- Island panel ----------------------------------------------------------

local islandPanel = makePanel(screenGui, "Island", UDim2.fromOffset(260, 116), UDim2.new(0, 16, 0, 140))
addPadding(islandPanel, 12)

local islandTitle = makeLabel(islandPanel, "Title", "YOUR ISLAND", UDim2.new(1, 0, 0, 16), UDim2.new(0, 0, 0, 0))
islandTitle.Font = Enum.Font.GothamBold
islandTitle.TextSize = 12
islandTitle.TextColor3 = THEME.Muted

local tierLabel = makeLabel(islandPanel, "Tier", "—", UDim2.new(1, 0, 0, 24), UDim2.new(0, 0, 0, 22))
tierLabel.Font = Enum.Font.GothamBold
tierLabel.TextSize = 18
tierLabel.TextColor3 = THEME.Accent

local upgradeButton = Instance.new("TextButton")
upgradeButton.Name = "Upgrade"
upgradeButton.Size = UDim2.new(1, 0, 0, 36)
upgradeButton.Position = UDim2.new(0, 0, 0, 56)
upgradeButton.BackgroundColor3 = THEME.Accent
upgradeButton.BorderSizePixel = 0
upgradeButton.Font = Enum.Font.GothamBold
upgradeButton.TextSize = 15
upgradeButton.TextColor3 = Color3.fromRGB(10, 20, 28)
upgradeButton.Text = "Upgrade"
upgradeButton.AutoButtonColor = true
upgradeButton.Parent = islandPanel
addCorner(upgradeButton, 8)

-- Notification toast ----------------------------------------------------

local toast = makePanel(screenGui, "Toast", UDim2.new(0, 460, 0, 44), UDim2.new(0.5, -230, 0, 24))
toast.BackgroundTransparency = 1

local toastLabel = Instance.new("TextLabel")
toastLabel.Size = UDim2.fromScale(1, 1)
toastLabel.BackgroundTransparency = 1
toastLabel.Font = Enum.Font.GothamBold
toastLabel.TextSize = 18
toastLabel.TextColor3 = THEME.Text
toastLabel.TextStrokeTransparency = 0.4
toastLabel.Text = ""
toastLabel.Parent = toast

local toastToken = 0

local function showToast(message: string): ()
	toastToken += 1
	local myToken = toastToken

	toastLabel.Text = message
	toastLabel.TextTransparency = 0
	toastLabel.TextStrokeTransparency = 0.4

	task.delay(4, function()
		-- A newer toast has already replaced this one; leave it alone.
		if toastToken ~= myToken then
			return
		end

		TweenService:Create(toastLabel, TweenInfo.new(0.6), {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
		}):Play()
	end)
end

--------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------

local balance = { Stars = 0, Coins = 0, Gems = 0 }
local upgradeCost: number? = nil

local function refreshCurrency()
	starsLabel.Text = string.format("★  %d Stars", balance.Stars)
	coinsLabel.Text = string.format("●  %d Coins", balance.Coins)
	gemsLabel.Text = string.format("◆  %d Gems", balance.Gems)

	-- Grey the button out when the player cannot afford the upgrade. Purely
	-- presentational -- the server re-checks affordability on click, so a
	-- client that lies about its balance still cannot buy anything.
	if upgradeCost then
		local affordable = balance.Stars >= upgradeCost
		upgradeButton.BackgroundColor3 = affordable and THEME.Accent or Color3.fromRGB(70, 84, 96)
		upgradeButton.TextColor3 = affordable and Color3.fromRGB(10, 20, 28) or THEME.Muted
	end
end

Net.OnClientEvent("CurrencyChanged", function(newBalance)
	balance.Stars = newBalance.Stars
	balance.Coins = newBalance.Coins
	balance.Gems = newBalance.Gems
	refreshCurrency()
end)

Net.OnClientEvent("HousingUpdated", function(state)
	if not state.HasPlot then
		tierLabel.Text = "No plot available"
		tierLabel.TextColor3 = THEME.Muted
		upgradeButton.Visible = false
		return
	end

	upgradeButton.Visible = true
	tierLabel.Text = string.format("%s  (Plot %d)", state.TierName, state.PlotIndex)
	tierLabel.TextColor3 = THEME.Accent

	upgradeCost = state.UpgradeCost

	if state.UpgradeCost then
		upgradeButton.Text = string.format("Upgrade to %s — %d★", state.NextTierName or "?", state.UpgradeCost)
	else
		upgradeButton.Text = "Fully upgraded"
		upgradeButton.BackgroundColor3 = Color3.fromRGB(70, 84, 96)
		upgradeButton.TextColor3 = THEME.Muted
	end

	refreshCurrency()
end)

Net.OnClientEvent("Notification", function(message)
	showToast(message)
end)

upgradeButton.Activated:Connect(function()
	if upgradeCost == nil then
		return
	end
	Net.FireServer("UpgradeHousing")
end)

--------------------------------------------------------------------------
-- Boot
--------------------------------------------------------------------------

refreshCurrency()

--[[
	Ask for state once on join. The server also pushes it on profile load;
	this covers the case where the profile loaded before this script ran
	(a slow client against a fast DataStore read).
]]
task.spawn(function()
	task.wait(2)
	Net.FireServer("RequestProfile")
end)
