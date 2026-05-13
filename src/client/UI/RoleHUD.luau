--!strict

-- RoleHUD: client-side heads-up display.
--
-- Shows the player's current role and coin balance.
-- Provides role-selection buttons that fire RequestRoleChange.
-- Renders toast notifications from SendNotification.
--
-- Public API:
--   RoleHUD.init(remotes)           — build the UI; returns self
--   RoleHUD:updateRole(roleId)      — refresh the role label
--   RoleHUD:updateCoins(coins)      — refresh the coins label
--   RoleHUD:showNotification(payload) — queue a toast

local Players      = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)

local localPlayer = Players.LocalPlayer

-- Role button definitions (order determines left-to-right layout).
local ROLE_BUTTONS: { { id: string, label: string } } = {
	{ id = "civilian", label = "Civilian" },
	{ id = "police",   label = "Police"   },
	{ id = "medic",    label = "Medic"    },
	{ id = "retail",   label = "Retail"   },
	{ id = "mechanic", label = "Mechanic" },
}

local TOAST_KIND_COLOURS: { [string]: Color3 } = {
	success = Color3.fromRGB(60,  180, 75),
	error   = Color3.fromRGB(220, 60,  60),
	warning = Color3.fromRGB(220, 160, 30),
	info    = Color3.fromRGB(60,  140, 210),
}

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function makeLabel(parent: Instance, text: string, props: { [string]: any }): TextLabel
	local tl = Instance.new("TextLabel")
	tl.Text = text
	tl.BackgroundTransparency = 1
	tl.TextColor3 = Color3.new(1, 1, 1)
	tl.Font = Enum.Font.GothamBold
	tl.TextScaled = true
	for k, v in props do
		(tl :: any)[k] = v
	end
	tl.Parent = parent
	return tl
end

local function makeFrame(parent: Instance, props: { [string]: any }): Frame
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	for k, v in props do
		(f :: any)[k] = v
	end
	f.Parent = parent
	return f
end

local function makeButton(parent: Instance, text: string, props: { [string]: any }): TextButton
	local btn = Instance.new("TextButton")
	btn.Text = text
	btn.Font = Enum.Font.GothamBold
	btn.TextColor3 = Color3.new(1, 1, 1)
	btn.TextScaled = true
	btn.BorderSizePixel = 0
	for k, v in props do
		(btn :: any)[k] = v
	end
	btn.Parent = parent
	return btn
end

-- ─── RoleHUD class ────────────────────────────────────────────────────────────

local RoleHUD = {}
RoleHUD.__index = RoleHUD

export type RoleHUD = typeof(setmetatable(
	{} :: {
		_roleLabel:  TextLabel,
		_coinsLabel: TextLabel,
		_toastFrame: Frame,
		_toastQueue: { Types.NotificationPayload },
		_toastActive: boolean,
	},
	RoleHUD
))

-- Builds the ScreenGui and all child frames.
function RoleHUD.init(remotes: { RequestRoleChange: RemoteEvent, [string]: any }): RoleHUD
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	-- Destroy any previous HUD from an earlier session (Studio fast-restart).
	local existing = playerGui:FindFirstChild("RoleHUD")
	if existing then
		existing:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "RoleHUD"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui

	-- ── Status bar (top-left) ─────────────────────────────────────────────────
	local statusBar = makeFrame(gui, {
		Name = "StatusBar",
		Size = UDim2.new(0, 300, 0, 64),
		Position = UDim2.new(0, 12, 0, 12),
		BackgroundColor3 = Color3.fromRGB(20, 20, 30),
		BackgroundTransparency = 0.25,
	})
	local corner1 = Instance.new("UICorner")
	corner1.CornerRadius = UDim.new(0, 10)
	corner1.Parent = statusBar

	local roleLabel = makeLabel(statusBar, "Role: Civilian", {
		Name = "RoleLabel",
		Size = UDim2.new(1, -12, 0.5, 0),
		Position = UDim2.new(0, 6, 0, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 18,
		TextScaled = false,
	})

	local coinsLabel = makeLabel(statusBar, "Coins: 0", {
		Name = "CoinsLabel",
		Size = UDim2.new(1, -12, 0.5, 0),
		Position = UDim2.new(0, 6, 0.5, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 16,
		TextScaled = false,
		TextColor3 = Color3.fromRGB(255, 220, 60),
	})

	-- ── Role selector (bottom bar) ────────────────────────────────────────────
	local btnBarHeight = 54
	local btnW = 120
	local totalW = btnW * #ROLE_BUTTONS + 8 * (#ROLE_BUTTONS - 1) + 16
	local btnBar = makeFrame(gui, {
		Name = "RoleBar",
		Size = UDim2.new(0, totalW, 0, btnBarHeight),
		Position = UDim2.new(0.5, -totalW / 2, 1, -(btnBarHeight + 12)),
		BackgroundColor3 = Color3.fromRGB(20, 20, 30),
		BackgroundTransparency = 0.25,
	})
	local corner2 = Instance.new("UICorner")
	corner2.CornerRadius = UDim.new(0, 10)
	corner2.Parent = btnBar

	local listLayout = Instance.new("UIListLayout")
	listLayout.FillDirection = Enum.FillDirection.Horizontal
	listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	listLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	listLayout.Padding = UDim.new(0, 8)
	listLayout.Parent = btnBar

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.Parent = btnBar

	for _, def in ROLE_BUTTONS do
		local btn = makeButton(btnBar, def.label, {
			Name = "Btn_" .. def.id,
			Size = UDim2.new(0, btnW, 0, 38),
			BackgroundColor3 = Color3.fromRGB(50, 100, 200),
		})
		local btnCorner = Instance.new("UICorner")
		btnCorner.CornerRadius = UDim.new(0, 8)
		btnCorner.Parent = btn

		local roleId = def.id
		btn.Activated:Connect(function()
			remotes.RequestRoleChange:FireServer(roleId)
		end)
	end

	-- ── Toast / notification area (top-right) ─────────────────────────────────
	local toastFrame = makeFrame(gui, {
		Name = "ToastFrame",
		Size = UDim2.new(0, 320, 1, -24),
		Position = UDim2.new(1, -332, 0, 12),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
	})

	-- ─── Build the self table ─────────────────────────────────────────────────
	local self: RoleHUD = setmetatable({
		_roleLabel   = roleLabel,
		_coinsLabel  = coinsLabel,
		_toastFrame  = toastFrame,
		_toastQueue  = {},
		_toastActive = false,
	}, RoleHUD) :: any

	return self
end

function RoleHUD:updateRole(roleId: string)
	local displayName = roleId:sub(1, 1):upper() .. roleId:sub(2)
	self._roleLabel.Text = "Role: " .. displayName
end

function RoleHUD:updateCoins(coins: number)
	self._coinsLabel.Text = string.format("Coins: %d", math.floor(coins))
end

-- ─── Toast system ─────────────────────────────────────────────────────────────

local TOAST_H    = 56
local TOAST_GAP  = 8
local TOAST_LIFE = 3.5   -- seconds the toast stays fully visible
local TOAST_ANIM = 0.25  -- slide-in / slide-out duration

function RoleHUD:_processQueue()
	if self._toastActive or #self._toastQueue == 0 then
		return
	end
	self._toastActive = true

	local payload = table.remove(self._toastQueue, 1) :: Types.NotificationPayload
	local duration = payload.duration or TOAST_LIFE
	local colour   = TOAST_KIND_COLOURS[payload.kind] or TOAST_KIND_COLOURS.info

	-- Build toast
	local toast = makeFrame(self._toastFrame, {
		Name = "Toast",
		Size = UDim2.new(1, 0, 0, TOAST_H),
		Position = UDim2.new(0, 0, 1, TOAST_GAP),  -- starts below visible area
		BackgroundColor3 = colour,
		BackgroundTransparency = 0.1,
	})
	local tc = Instance.new("UICorner")
	tc.CornerRadius = UDim.new(0, 10)
	tc.Parent = toast

	makeLabel(toast, payload.message, {
		Size = UDim2.new(1, -12, 1, 0),
		Position = UDim2.new(0, 6, 0, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 15,
		TextScaled = false,
		TextWrapped = true,
	})

	-- Slide in
	local slideIn = TweenService:Create(toast,
		TweenInfo.new(TOAST_ANIM, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = UDim2.new(0, 0, 1, -(TOAST_H + TOAST_GAP)) })
	slideIn:Play()
	slideIn.Completed:Wait()

	task.wait(duration)

	-- Slide out
	local slideOut = TweenService:Create(toast,
		TweenInfo.new(TOAST_ANIM, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Position = UDim2.new(0, 0, 1, TOAST_GAP) })
	slideOut:Play()
	slideOut.Completed:Wait()

	toast:Destroy()
	self._toastActive = false

	-- Process next queued toast.
	self:_processQueue()
end

function RoleHUD:showNotification(payload: Types.NotificationPayload)
	table.insert(self._toastQueue, payload)
	task.spawn(function()
		self:_processQueue()
	end)
end

return RoleHUD
