--!strict
--[[
	World.luau

	Layout data for the archipelago. WorldService builds geometry from these
	numbers, so moving the arena ring outward or adding a ninth island is a
	config edit rather than a rewrite.

	Coordinate convention: the water surface sits at Y = 0. Land discs are
	centred slightly below it so their tops read as beaches a few studs above
	the waterline. Everything is laid out on concentric rings around the hub
	at the origin, which keeps the map readable from any angle and makes
	"which island is that" answerable by looking at the compass.
]]

local World = {}

World.WaterLevel = 0
World.SeabedY = -70

-- Water is filled as a block rather than a plane so players can actually
-- swim down into it instead of hitting an invisible floor.
World.WaterExtent = 2400

--[[
	Central hub.

	Deliberately two offset circles rather than one plaza: the original spec's
	instinct to split commerce from matchmaking is right, and encoding the
	split in the geometry means players learn the layout by walking it rather
	than by reading a sign.
]]
World.Hub = {
	Radius = 150,
	Thickness = 10,
	Y = -5,

	-- The two activity circles, offset left and right along X.
	CircleRadius = 46,
	CircleOffset = 58,
	CommerceColor = Color3.fromRGB(255, 176, 59),
	MatchmakingColor = Color3.fromRGB(64, 196, 255),
}

--[[
	The ring of private housing islands.

	NOTE: PlotCount (8) is the number of *plots*, not the number of players who
	can be in the hub. See HousingService for the contention this creates --
	it is a real design problem, not an implementation detail.
]]
World.Islands = {
	PlotCount = 8,
	RingRadius = 480,
	Radius = 68,
	Thickness = 8,
	Y = -4,
	-- Offset so no island sits exactly on the +X axis, which keeps the ring
	-- reading as a ring rather than as "the one straight ahead".
	AngleOffset = 22.5,
}

--[[
	Minigame arena pads.

	Flat platforms in the outer ring, one per minigame, purely so the team can
	see the intended footprint of each arena and walk its scale. Real arenas
	will be built inside these pads (or in dedicated places) later.
]]
World.Arenas = {
	RingRadius = 1000,
	Radius = 110,
	Thickness = 6,
	Y = -3,
}

World.Palette = {
	Sand = Color3.fromRGB(240, 219, 168),
	SandDark = Color3.fromRGB(214, 186, 136),
	ArenaPad = Color3.fromRGB(126, 200, 152),
	PlotMarker = Color3.fromRGB(255, 255, 255),
}

--[[
	Returns a position on a ring, at `angleDegrees` measured counter-clockwise
	from +X.
]]
function World.RingPosition(radius: number, angleDegrees: number, y: number): Vector3
	local radians = math.rad(angleDegrees)
	return Vector3.new(math.cos(radians) * radius, y, math.sin(radians) * radius)
end

--[[
	Angle of the Nth item in a ring of `count`. Shared by islands and arenas so
	both rings stay evenly spaced if either count changes.
]]
function World.RingAngle(index: number, count: number, offsetDegrees: number): number
	return offsetDegrees + ((index - 1) / count) * 360
end

return World
