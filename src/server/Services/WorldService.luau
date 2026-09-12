--!strict
--[[
	WorldService.luau

	Generates the archipelago: ocean, central hub, the ring of 8 housing
	islands, and the outer ring of minigame arena pads.

	Everything here is placeholder geometry. The point is not that it looks
	good -- it is that the team can walk the map, feel the scale of an arena,
	and design minigames against real space today rather than waiting on art.

	Art swap path: every generated structure first looks for a Model by name in
	ReplicatedStorage.Assets, and only falls back to generated geometry when
	that model is absent. An artist drops "Villa_Tier3" into Assets.Villas and
	that plot renders their model instead, with no code change. That is the
	whole reason the lookups exist -- so art can land incrementally instead of
	being a rewrite.

	Everything is anchored and built once at server start. Nothing here runs
	per-frame, so the cost is a single spike on boot.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local World = require(Shared.Config.World)
local Housing = require(Shared.Config.Housing)
local Game = require(Shared.Config.Game)

local WorldService = {}

local worldRoot: Folder
local plots: { [number]: Model } = {}
local arenaPads: { [string]: Part } = {}

--------------------------------------------------------------------------
-- Asset lookup
--------------------------------------------------------------------------

--[[
	Looks for an artist-authored model. Returns nil when absent, which is the
	normal case until art exists -- callers must always handle nil.
]]
function WorldService.FindAsset(category: string, name: string): Model?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if not assets then
		return nil
	end

	local folder = assets:FindFirstChild(category)
	if not folder then
		return nil
	end

	local model = folder:FindFirstChild(name)
	if model and model:IsA("Model") then
		return model
	end

	return nil
end

--------------------------------------------------------------------------
-- Geometry primitives
--------------------------------------------------------------------------

local function makeDisc(
	parent: Instance,
	name: string,
	position: Vector3,
	radius: number,
	thickness: number,
	color: Color3,
	material: Enum.Material?
): Part
	local disc = Instance.new("Part")
	disc.Name = name
	disc.Shape = Enum.PartType.Cylinder
	-- A Cylinder part's axis runs along X, so its Size.X is the *height* and
	-- Y/Z are the diameter. Rotating 90 degrees about Z stands it upright to
	-- make a disc.
	disc.Size = Vector3.new(thickness, radius * 2, radius * 2)
	disc.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	disc.Anchored = true
	disc.Locked = true
	disc.Color = color
	disc.Material = material or Enum.Material.Sand
	disc.TopSurface = Enum.SurfaceType.Smooth
	disc.BottomSurface = Enum.SurfaceType.Smooth
	disc.Parent = parent
	return disc
end

local function makeBox(
	parent: Instance,
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material?
): Part
	local box = Instance.new("Part")
	box.Name = name
	box.Size = size
	box.CFrame = cframe
	box.Anchored = true
	box.Locked = true
	box.Color = color
	box.Material = material or Enum.Material.SmoothPlastic
	box.TopSurface = Enum.SurfaceType.Smooth
	box.BottomSurface = Enum.SurfaceType.Smooth
	box.Parent = parent
	return box
end

local function makeLabel(parent: Instance, text: string, height: number): BillboardGui
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Label"
	billboard.Size = UDim2.fromScale(18, 4)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, height, 0)
	billboard.AlwaysOnTop = false
	billboard.MaxDistance = 900
	billboard.Parent = parent

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.Text = text
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.4
	label.TextScaled = true
	label.Parent = billboard

	return billboard
end

--------------------------------------------------------------------------
-- Ocean
--------------------------------------------------------------------------

--[[
	Terrain water rather than a big Part.

	The first pass used a single 2400-stud part with Enum.Material.Water and
	Transparency 0.25. That part is the entire cause of the "transparent
	triangular cuts and tearing around the hub": transparent geometry is
	depth-sorted per-part, and one transparent part spanning the whole map
	intersects every island, so the renderer drew it over land in patches and
	ripped it apart as StreamingEnabled streamed chunks in and out. Terrain
	water is a dedicated continuous surface with correct depth, so it neither
	z-fights with the islands nor tears under streaming, and it gives real
	swimming for free.

	The fill is coarse (resolution 4) and done once at boot; the surface is
	flat regardless of resolution, so there is no visual cost to being coarse.
]]
local function buildOcean(): ()
	local terrain = workspace.Terrain
	local extent = World.WaterExtent
	local halfExtent = extent / 2

	-- Terrain's default voxel grid is far smaller than this map (islands sit
	-- at radius 480, arenas at 1000). Expand the grid first or the fill below
	-- is clipped to the default bounds and the ocean stops short of the arena
	-- ring. MaxExtents is measured in 4-stud voxels.
	local halfVoxels = math.ceil(halfExtent / 4) + 8
	terrain.MaxExtents = Region3int16.new(
		Vector3int16.new(-halfVoxels, -32, -halfVoxels),
		Vector3int16.new(halfVoxels, 32, halfVoxels)
	)

	local region = Region3.new(
		Vector3.new(-halfExtent, World.WaterLevel - World.WaterDepth, -halfExtent),
		Vector3.new(halfExtent, World.WaterLevel, halfExtent)
	)
	terrain:FillRegion(region, 4, Enum.Material.Water)

	-- Surface tuning lives on Terrain, not on a part.
	terrain.WaterColor = Color3.fromRGB(28, 138, 184)
	terrain.WaterWaveSize = 0.15
	terrain.WaterWaveSpeed = 12
	terrain.WaterReflectance = 0.05
	terrain.WaterTransparency = 0.2
end

--------------------------------------------------------------------------
-- Hub
--------------------------------------------------------------------------

local function buildHub(parent: Folder): BasePart
	local hub = Instance.new("Model")
	hub.Name = "Hub"
	hub.Parent = parent

	local config = World.Hub

	makeDisc(
		hub,
		"HubIsland",
		Vector3.new(0, config.Y, 0),
		config.Radius,
		config.Thickness,
		World.Palette.Sand
	)

	-- The two activity circles sit slightly proud of the sand so they read as
	-- destinations rather than as painted-on markings.
	local circleY = config.Y + config.Thickness / 2 + 1

	local commerce = makeDisc(
		hub,
		"CommerceCircle",
		Vector3.new(-config.CircleOffset, circleY, 0),
		config.CircleRadius,
		2,
		config.CommerceColor,
		Enum.Material.SmoothPlastic
	)
	commerce.CanCollide = false

	local matchmaking = makeDisc(
		hub,
		"MatchmakingCircle",
		Vector3.new(config.CircleOffset, circleY, 0),
		config.CircleRadius,
		2,
		config.MatchmakingColor,
		Enum.Material.SmoothPlastic
	)
	matchmaking.CanCollide = false

	makeLabel(commerce, "COMMERCE & SOCIAL", 14)
	makeLabel(matchmaking, "MATCHMAKING & VOTING", 14)

	-- Spawn in the neutral gap between the two circles, so a new player is
	-- not dropped into either activity before they have chosen one.
	local spawnLocation = Instance.new("SpawnLocation")
	spawnLocation.Name = "HubSpawn"
	spawnLocation.Size = Vector3.new(24, 2, 24)
	spawnLocation.CFrame = CFrame.new(0, config.Y + config.Thickness / 2 + 1, 0)
	spawnLocation.Anchored = true
	spawnLocation.Locked = true
	spawnLocation.Color = Color3.fromRGB(255, 255, 255)
	spawnLocation.Material = Enum.Material.SmoothPlastic
	spawnLocation.TopSurface = Enum.SurfaceType.Smooth
	spawnLocation.Neutral = true
	spawnLocation.Duration = 0
	spawnLocation.Parent = hub

	return spawnLocation
end

--------------------------------------------------------------------------
-- Housing islands
--------------------------------------------------------------------------

--[[
	Builds the ring of housing plots.

	Each plot is a Model containing the sand disc and a marker, so
	HousingService can clear and repopulate the villa without touching the
	terrain underneath it.
]]
local function buildIslands(parent: Folder): ()
	local config = World.Islands

	local ring = Instance.new("Folder")
	ring.Name = "HousingIslands"
	ring.Parent = parent

	for index = 1, config.PlotCount do
		local angle = World.RingAngle(index, config.PlotCount, config.AngleOffset)
		local position = World.RingPosition(config.RingRadius, angle, config.Y)

		local plot = Instance.new("Model")
		plot.Name = string.format("Plot_%d", index)
		plot:SetAttribute("PlotIndex", index)
		plot:SetAttribute("Angle", angle)
		plot.Parent = ring

		makeDisc(
			plot,
			"Island",
			position,
			config.Radius,
			config.Thickness,
			World.Palette.Sand
		)

		-- A shallow inner pad marking where the villa will sit, so an empty
		-- plot still reads as "someone's plot" rather than as bare sand.
		local padY = config.Y + config.Thickness / 2 + 1
		local pad = makeDisc(
			plot,
			"VillaPad",
			Vector3.new(position.X, padY, position.Z),
			Housing.FootprintRadius,
			2,
			World.Palette.SandDark,
			Enum.Material.Sand
		)
		pad.CanCollide = false

		-- The villa itself is parented here by HousingService.
		local villaHolder = Instance.new("Folder")
		villaHolder.Name = "Villa"
		villaHolder.Parent = plot

		makeLabel(plot, string.format("PLOT %d", index), 22)

		plots[index] = plot
	end
end

--------------------------------------------------------------------------
-- Arena pads
--------------------------------------------------------------------------

local function buildArenaPads(parent: Folder): ()
	local config = World.Arenas

	local ring = Instance.new("Folder")
	ring.Name = "ArenaPads"
	ring.Parent = parent

	local minigames = Game.Minigames

	for index, minigame in minigames do
		local angle = World.RingAngle(index, #minigames, 0)
		local position = World.RingPosition(config.RingRadius, angle, config.Y)

		local pad = makeDisc(
			ring,
			minigame.Id,
			position,
			config.Radius,
			config.Thickness,
			World.Palette.ArenaPad,
			Enum.Material.Grass
		)

		-- Phase 2 games get a muted pad so it is obvious at a glance which
		-- arenas are actually shipping at launch.
		if minigame.Phase == 2 then
			pad.Color = Color3.fromRGB(120, 150, 136)
			pad.Transparency = 0.35
		end

		local label = string.format("%s  [P%d]", minigame.Name, minigame.Phase)
		makeLabel(pad, label, config.Thickness + 18)

		arenaPads[minigame.Id] = pad
	end
end

--------------------------------------------------------------------------
-- Villa placeholders
--------------------------------------------------------------------------

--[[
	Generates blocky stand-in geometry for a villa tier.

	Tiers are visually distinct in silhouette rather than in detail -- a tent
	is a wedge, a hut is a box, a villa is a stack of shrinking floors with
	pillars. Silhouette is what reads from across the water, which is where
	players will actually be judging each other's islands.
]]
function WorldService.BuildVillaPlaceholder(tier: number, plotPosition: Vector3, topY: number): Model
	local model = Instance.new("Model")
	model.Name = string.format("VillaPlaceholder_Tier%d", tier)

	local base = CFrame.new(plotPosition.X, topY, plotPosition.Z)

	local function box(name: string, size: Vector3, offset: Vector3, color: Color3)
		return makeBox(model, name, size, base * CFrame.new(offset), color)
	end

	if tier <= 0 then
		-- Empty plot. Nothing is built -- the absence is the statement.
		return model
	end

	local wallColor = Color3.fromRGB(248, 240, 222)
	local roofColor = Color3.fromRGB(198, 92, 70)

	if tier == 1 then
		-- Beach tent: an A-frame. Two slabs leaning against each other read as
		-- a tent from any angle, which is what matters from across the water.
		box("Floor", Vector3.new(22, 2, 22), Vector3.new(0, 1, 0), World.Palette.SandDark)

		-- Each slab is 17 deep, tilted 40 degrees, centred so its inner edge
		-- meets the other at the ridge (z = 0) and its outer edge lands on the
		-- sand. Rise over run works out to about ground -> 13 studs.
		makeBox(
			model,
			"RoofFront",
			Vector3.new(24, 2, 17),
			base * CFrame.new(0, 8, 6.5) * CFrame.Angles(math.rad(40), 0, 0),
			roofColor
		)
		makeBox(
			model,
			"RoofBack",
			Vector3.new(24, 2, 17),
			base * CFrame.new(0, 8, -6.5) * CFrame.Angles(math.rad(-40), 0, 0),
			roofColor
		)
	elseif tier == 2 then
		-- Beach hut: single box with a flat overhanging roof.
		box("Body", Vector3.new(26, 12, 24), Vector3.new(0, 6, 0), wallColor)
		box("Roof", Vector3.new(30, 2, 28), Vector3.new(0, 13, 0), roofColor)
	elseif tier == 3 then
		-- Bungalow: wider, with a porch and a pitched roof.
		box("Body", Vector3.new(38, 16, 32), Vector3.new(0, 8, 0), wallColor)
		box("Roof", Vector3.new(42, 3, 36), Vector3.new(0, 17, 0), roofColor)
		box("Porch", Vector3.new(38, 2, 12), Vector3.new(0, 3, 22), World.Palette.SandDark)
	elseif tier == 4 then
		-- Two-story house: stacked floors, second one inset.
		box("Floor1", Vector3.new(40, 16, 34), Vector3.new(0, 8, 0), wallColor)
		box("Floor2", Vector3.new(32, 14, 26), Vector3.new(0, 23, 0), wallColor)
		box("Roof", Vector3.new(36, 3, 30), Vector3.new(0, 31, 0), roofColor)
	else
		-- Luxury villa: three shrinking floors on pillars, with a deck.
		for _, offset in { Vector3.new(-14, 0, -12), Vector3.new(14, 0, -12), Vector3.new(-14, 0, 12), Vector3.new(14, 0, 12) } do
			box("Pillar", Vector3.new(3, 10, 3), offset + Vector3.new(0, 5, 0), roofColor)
		end
		box("Deck", Vector3.new(48, 2, 40), Vector3.new(0, 11, 0), World.Palette.SandDark)
		box("Floor1", Vector3.new(44, 16, 36), Vector3.new(0, 20, 0), wallColor)
		box("Floor2", Vector3.new(34, 14, 28), Vector3.new(0, 35, 0), wallColor)
		box("Floor3", Vector3.new(22, 12, 18), Vector3.new(0, 48, 0), wallColor)
		box("Roof", Vector3.new(26, 3, 22), Vector3.new(0, 55, 0), roofColor)
	end

	return model
end

--------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------

function WorldService.GetPlot(index: number): Model?
	return plots[index]
end

function WorldService.GetPlotCount(): number
	return World.Islands.PlotCount
end

--[[
	World-space centre of a plot, and the Y its villa should sit on. Exposed so
	HousingService does not have to re-derive the layout maths -- if the ring
	radius changes, this is the only place that knows.
]]
function WorldService.GetPlotPlacement(index: number): (Vector3?, number)
	local plot = plots[index]
	if not plot then
		return nil, 0
	end

	local island = plot:FindFirstChild("Island")
	if not island or not island:IsA("BasePart") then
		return nil, 0
	end

	local topY = island.Position.Y + island.Size.X / 2
	return Vector3.new(island.Position.X, topY, island.Position.Z), topY
end

function WorldService.GetArenaPad(minigameId: string): Part?
	return arenaPads[minigameId]
end

local started = false

function WorldService.Start(): ()
	if started then
		return
	end
	started = true

	worldRoot = Instance.new("Folder")
	worldRoot.Name = "World"
	worldRoot.Parent = workspace

	-- Rojo never deletes unmanaged instances, so a Baseplate left over from
	-- before the project.json rewrite survives re-serves and z-fights with the
	-- water surface. Remove it here so playtests are clean without a manual
	-- Studio step.
	local baseplate = workspace:FindFirstChild("Baseplate")
	if baseplate and baseplate:IsA("BasePart") then
		baseplate:Destroy()
		print("[WorldService] Removed leftover Studio Baseplate.")
	end

	buildOcean()
	buildHub(worldRoot)
	buildIslands(worldRoot)
	buildArenaPads(worldRoot)

	print(
		string.format(
			"[WorldService] Built hub, %d housing plots and %d arena pads.",
			World.Islands.PlotCount,
			#Game.Minigames
		)
	)
end

return WorldService
