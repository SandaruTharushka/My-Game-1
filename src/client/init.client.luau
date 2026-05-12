--!strict

-- Client bootstrap — Phase 1.
--
-- Phase 1 scope: receive authoritative data from the server and hold it in
-- local state. No UI is rendered yet (Phase 2).
--
-- Rules:
--   • Never mutate game state locally — always request via a RemoteEvent.
--   • Validate all server payloads before using them.
--   • Keep this file thin; delegate to client-side modules as they are added.

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Logger = require(Shared.Util.Logger)
local Remotes = require(Shared.Network.Remotes)
local Types = require(Shared.Types)

local log = Logger.new("Client")
local localPlayer = Players.LocalPlayer

-- ─── Remotes ──────────────────────────────────────────────────────────────────

-- Blocks until the server has created all remote instances.
local remotes = Remotes.client()

-- ─── Local state (presentation layer only — server is authoritative) ──────────

local currentRole: string = "civilian"
local currentCoins: number = 0

-- ─── RoleChanged ──────────────────────────────────────────────────────────────

remotes.RoleChanged.OnClientEvent:Connect(function(rawPayload: unknown)
	if typeof(rawPayload) ~= "table" then
		log:warn("RoleChanged: unexpected payload type", { got = typeof(rawPayload) })
		return
	end
	local payload = rawPayload :: Types.RoleChangedPayload
	if typeof(payload.role) ~= "string" or #payload.role == 0 then
		log:warn("RoleChanged: invalid role field")
		return
	end
	currentRole = payload.role
	log:info("Role updated", { role = currentRole })
	-- Phase 2: RoleHUD:update(currentRole)
end)

-- ─── SendNotification ─────────────────────────────────────────────────────────

remotes.SendNotification.OnClientEvent:Connect(function(rawPayload: unknown)
	if typeof(rawPayload) ~= "table" then
		return
	end
	local payload = rawPayload :: Types.NotificationPayload
	if typeof(payload.message) ~= "string" then
		return
	end
	-- Phase 2: ToastSystem:show(payload)
	log:info("Notification", { kind = payload.kind, message = payload.message })
end)

-- ─── Initial profile fetch ────────────────────────────────────────────────────

-- InvokeServer is safe here: the server's OnServerInvoke returns a read-only
-- snapshot and never changes state based on this call.
local profile = remotes.GetProfile:InvokeServer()
if profile ~= nil then
	local p = profile :: Types.PublicProfile
	currentRole = p.role
	currentCoins = p.coins
	log:info("Profile received", { role = currentRole, coins = currentCoins })
else
	log:warn("GetProfile returned nil — profile may still be loading")
end

log:info("Client bootstrap complete", { userId = localPlayer.UserId })
