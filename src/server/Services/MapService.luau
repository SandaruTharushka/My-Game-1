--!strict

-- MapService: procedurally generates a small city map on server start.
--
-- All geometry uses Roblox Parts only (no external assets).
-- Every object lives under Workspace/GeneratedMap.
-- Generation is idempotent: any existing GeneratedMap is destroyed first.

local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Logger = require(Shared.Util.Logger)

local log = Logger.new("MapService")

local MAP_FOLDER = "GeneratedMap"

-- ─── Colour palette ───────────────────────────────────────────────────────────

local COLOURS = {
	road        = Color3.fromRGB(50,  50,  50),
	sidewalk    = Color3.fromRGB(180, 180, 175),
	grass       = Color3.fromRGB(106, 127, 63),
	wall        = Color3.fromRGB(200, 190, 170),
	roof        = Color3.fromRGB(160, 60,  40),
	roofPolice  = Color3.fromRGB(30,  50,  180),
	roofHospital= Color3.fromRGB(220, 220, 220),
	roofMechanic= Color3.fromRGB(100, 60,  20),
	roofShop    = Color3.fromRGB(200, 120, 30),
	roofPlaza   = Color3.fromRGB(60,  140, 80),
	door        = Color3.fromRGB(90,  60,  30),
	window      = Color3.fromRGB(150, 210, 240),
	sign        = Color3.fromRGB(240, 240, 60),
}

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function part(
	parent: Instance,
	name: string,
	size: Vector3,
	position: Vector3,
	colour: Color3,
	material: Enum.Material?
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = true
	p.Size = size
	p.Position = position
	p.Color = colour
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- Label a part with a SurfaceGui + TextLabel on its front face.
local function label(p: Part, text: string, textColour: Color3?)
	local sg = Instance.new("SurfaceGui")
	sg.Face = Enum.NormalId.Front
	sg.AlwaysOnTop = false
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.PixelsPerStud = 50
	sg.Parent = p

	local tl = Instance.new("TextLabel")
	tl.Size = UDim2.fromScale(1, 1)
	tl.BackgroundTransparency = 1
	tl.Text = text
	tl.TextColor3 = textColour or Color3.new(1, 1, 1)
	tl.TextScaled = true
	tl.Font = Enum.Font.GothamBold
	tl.Parent = sg
end

-- ─── Building generator ───────────────────────────────────────────────────────

type BuildingDef = {
	name: string,
	cx: number,      -- centre X
	cz: number,      -- centre Z
	w: number,       -- width  (X)
	d: number,       -- depth  (Z)
	h: number,       -- wall height
	roofColour: Color3,
	signText: string,
}

local function buildBuilding(parent: Instance, def: BuildingDef)
	local folder = Instance.new("Folder")
	folder.Name = def.name
	folder.Parent = parent

	local wallY  = def.h / 2          -- centre of walls
	local roofY  = def.h + 0.5        -- top of roof slab
	local groundY = 0                  -- top surface of baseplate is at Y=0

	-- Floor slab (thin)
	part(folder, "Floor",
		Vector3.new(def.w, 0.4, def.d),
		Vector3.new(def.cx, groundY + 0.2, def.cz),
		COLOURS.sidewalk, Enum.Material.Concrete)

	-- Four walls
	-- Front (−Z face)
	part(folder, "WallFront",
		Vector3.new(def.w, def.h, 0.6),
		Vector3.new(def.cx, wallY, def.cz - def.d / 2),
		COLOURS.wall, Enum.Material.Brick)

	-- Back (+Z face)
	part(folder, "WallBack",
		Vector3.new(def.w, def.h, 0.6),
		Vector3.new(def.cx, wallY, def.cz + def.d / 2),
		COLOURS.wall, Enum.Material.Brick)

	-- Left (−X face)
	part(folder, "WallLeft",
		Vector3.new(0.6, def.h, def.d),
		Vector3.new(def.cx - def.w / 2, wallY, def.cz),
		COLOURS.wall, Enum.Material.Brick)

	-- Right (+X face)
	part(folder, "WallRight",
		Vector3.new(0.6, def.h, def.d),
		Vector3.new(def.cx + def.w / 2, wallY, def.cz),
		COLOURS.wall, Enum.Material.Brick)

	-- Roof
	part(folder, "Roof",
		Vector3.new(def.w + 1, 1, def.d + 1),
		Vector3.new(def.cx, roofY, def.cz),
		def.roofColour, Enum.Material.SmoothPlastic)

	-- Door (centred on front wall, bottom-aligned)
	part(folder, "Door",
		Vector3.new(2, 3, 0.7),
		Vector3.new(def.cx, 1.5, def.cz - def.d / 2),
		COLOURS.door, Enum.Material.Wood)

	-- Two windows on front wall
	part(folder, "WindowL",
		Vector3.new(2, 2, 0.4),
		Vector3.new(def.cx - def.w / 4, wallY + 1, def.cz - def.d / 2),
		COLOURS.window, Enum.Material.Glass)

	part(folder, "WindowR",
		Vector3.new(2, 2, 0.4),
		Vector3.new(def.cx + def.w / 4, wallY + 1, def.cz - def.d / 2),
		COLOURS.window, Enum.Material.Glass)

	-- Sign above door
	local signPart = part(folder, "Sign",
		Vector3.new(def.w * 0.6, 1.2, 0.3),
		Vector3.new(def.cx, def.h - 1, def.cz - def.d / 2 - 0.1),
		COLOURS.sign, Enum.Material.Neon)
	label(signPart, def.signText, Color3.new(0, 0, 0))

	return folder
end

-- ─── Road & sidewalk tiles ────────────────────────────────────────────────────

local function buildRoads(parent: Instance)
	-- Main horizontal road (runs along Z axis through centre)
	part(parent, "RoadH",
		Vector3.new(200, 0.3, 16),
		Vector3.new(0, 0.15, 0),
		COLOURS.road, Enum.Material.Concrete)

	-- Main vertical road (runs along X axis through centre)
	part(parent, "RoadV",
		Vector3.new(16, 0.3, 200),
		Vector3.new(0, 0.15, 0),
		COLOURS.road, Enum.Material.Concrete)

	-- Sidewalks alongside horizontal road
	part(parent, "SidewalkH_N",
		Vector3.new(200, 0.5, 4),
		Vector3.new(0, 0.25, -10),
		COLOURS.sidewalk, Enum.Material.Concrete)

	part(parent, "SidewalkH_S",
		Vector3.new(200, 0.5, 4),
		Vector3.new(0, 0.25, 10),
		COLOURS.sidewalk, Enum.Material.Concrete)

	-- Sidewalks alongside vertical road
	part(parent, "SidewalkV_W",
		Vector3.new(4, 0.5, 200),
		Vector3.new(-10, 0.25, 0),
		COLOURS.sidewalk, Enum.Material.Concrete)

	part(parent, "SidewalkV_E",
		Vector3.new(4, 0.5, 200),
		Vector3.new(10, 0.25, 0),
		COLOURS.sidewalk, Enum.Material.Concrete)
end

-- ─── Spawn plaza ──────────────────────────────────────────────────────────────

local function buildPlaza(parent: Instance)
	-- Open paved area in the centre of the map
	part(parent, "PlazaFloor",
		Vector3.new(20, 0.5, 20),
		Vector3.new(0, 0.25, 0),
		COLOURS.sidewalk, Enum.Material.SmoothPlastic)

	-- Decorative fountain base
	part(parent, "FountainBase",
		Vector3.new(4, 1, 4),
		Vector3.new(0, 0.75, 0),
		Color3.fromRGB(200, 200, 200), Enum.Material.Marble)

	part(parent, "FountainTop",
		Vector3.new(1.5, 3, 1.5),
		Vector3.new(0, 2.25, 0),
		Color3.fromRGB(210, 210, 220), Enum.Material.Marble)

	-- Surrounding grass patches
	for _, offset in {
		Vector3.new(-60, 0, -60),
		Vector3.new( 60, 0, -60),
		Vector3.new(-60, 0,  60),
		Vector3.new( 60, 0,  60),
	} do
		part(parent, "GrassPatch",
			Vector3.new(60, 0.3, 60),
			Vector3.new(offset.X, 0.15, offset.Z),
			COLOURS.grass, Enum.Material.Grass)
	end
end

-- ─── Public API ───────────────────────────────────────────────────────────────

local MapService = {}

function MapService.init()
	-- Idempotent: destroy any previous GeneratedMap first.
	local existing = Workspace:FindFirstChild(MAP_FOLDER)
	if existing then
		existing:Destroy()
		log:info("Removed old GeneratedMap")
	end

	local root = Instance.new("Folder")
	root.Name = MAP_FOLDER
	root.Parent = Workspace

	-- Roads and sidewalks
	buildRoads(root)

	-- Spawn plaza
	buildPlaza(root)

	-- Building definitions — 10 buildings across 4 quadrants.
	-- Positions chosen to sit on the grass areas beside the roads.
	local buildings: { BuildingDef } = {
		-- ── Police Station (north-west) ──────────────────────────────────────
		{
			name = "PoliceStation",
			cx = -50, cz = -50,
			w = 22, d = 14, h = 12,
			roofColour = COLOURS.roofPolice,
			signText = "POLICE",
		},
		-- ── Hospital (north-east) ────────────────────────────────────────────
		{
			name = "Hospital",
			cx = 50, cz = -50,
			w = 24, d = 16, h = 14,
			roofColour = COLOURS.roofHospital,
			signText = "HOSPITAL",
		},
		-- ── Mechanic Garage (south-west) ─────────────────────────────────────
		{
			name = "MechanicGarage",
			cx = -50, cz = 50,
			w = 20, d = 14, h = 10,
			roofColour = COLOURS.roofMechanic,
			signText = "GARAGE",
		},
		-- ── Shop / Retail (south-east) ───────────────────────────────────────
		{
			name = "RetailShop",
			cx = 50, cz = 50,
			w = 18, d = 12, h = 9,
			roofColour = COLOURS.roofShop,
			signText = "SHOP",
		},
		-- ── Residential block 1 (north-west quadrant) ────────────────────────
		{
			name = "House_NW1",
			cx = -70, cz = -25,
			w = 12, d = 10, h = 8,
			roofColour = COLOURS.roof,
			signText = "HOME",
		},
		-- ── Residential block 2 ──────────────────────────────────────────────
		{
			name = "House_NW2",
			cx = -25, cz = -70,
			w = 12, d = 10, h = 8,
			roofColour = COLOURS.roof,
			signText = "HOME",
		},
		-- ── Residential block 3 (north-east quadrant) ────────────────────────
		{
			name = "House_NE1",
			cx = 70, cz = -25,
			w = 12, d = 10, h = 8,
			roofColour = COLOURS.roof,
			signText = "HOME",
		},
		-- ── Residential block 4 ──────────────────────────────────────────────
		{
			name = "House_NE2",
			cx = 25, cz = -70,
			w = 12, d = 10, h = 8,
			roofColour = COLOURS.roof,
			signText = "HOME",
		},
		-- ── Office / Bank (south-east quadrant) ──────────────────────────────
		{
			name = "Office_SE",
			cx = 70, cz = 30,
			w = 16, d = 12, h = 16,
			roofColour = Color3.fromRGB(70, 70, 90),
			signText = "BANK",
		},
		-- ── Diner (south-west quadrant) ───────────────────────────────────────
		{
			name = "Diner_SW",
			cx = -25, cz = 70,
			w = 14, d = 10, h = 7,
			roofColour = Color3.fromRGB(200, 80, 80),
			signText = "DINER",
		},
	}

	for _, def in buildings do
		buildBuilding(root, def)
	end

	log:info("MapService: city generated", { buildings = #buildings })
end

return MapService
