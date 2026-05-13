--!strict

-- Client bootstrap — Phase 2.
--
-- Receives authoritative data from the server, renders the RoleHUD,
-- and routes server events to the HUD for display.
--
-- Rules:
--   • Never mutate game state locally — always request via a RemoteEvent.
--   • Validate all server payloads before using them.
--   • Keep this file thin; delegate to client-side modules.

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local GameConfig = require(Shared.Config.GameConfig)
local Logger     = require(Shared.Util.Logger)
local Remotes    = require(Shared.Network.Remotes)
local Types      = require(Shared.Types)

local RoleHUD = require(script.UI.RoleHUD)

local log         = Logger.new("Client")
local localPlayer = Players.LocalPlayer

-- ─── Remotes ──────────────────────────────────────────────────────────────────

-- Blocks until the server has created all remote instances.
local remotes = Remotes.client()

-- ─── HUD ─────────────────────────────────────────────────────────────────────

local hud = RoleHUD.init(remotes)

-- ─── Local state (presentation layer only — server is authoritative) ──────────

local currentRole: string  = "civilian"
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
	hud:updateRole(currentRole)
	log:info("Role updated", { role = currentRole })
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

	-- Also refresh coin label when a salary notification arrives.
	-- The authoritative balance is fetched via GetProfile; this is best-effort.
	local msg = payload.message
	local paid = msg:match("balance: (%d+)")
	if paid then
		currentCoins = tonumber(paid) or currentCoins
		hud:updateCoins(currentCoins)
	end

	hud:showNotification(payload)
	log:info("Notification", { kind = payload.kind, message = payload.message })
end)

-- ─── Initial profile fetch ────────────────────────────────────────────────────
--
-- The server fires ProfileReady only after the DataStore profile has fully
-- loaded, the session lock has been acquired, and the data has been validated.
-- We wait for that signal before calling GetProfile to guarantee a non-nil
-- response and eliminate the loading race condition.

-- Invokes GetProfile with up to PROFILE_FETCH_RETRIES attempts.
-- Returns true on success, false if all attempts fail.
local function fetchProfile(): boolean
	for attempt = 1, GameConfig.PROFILE_FETCH_RETRIES do
		local ok, result = pcall(function()
			return remotes.GetProfile:InvokeServer()
		end)

		if not ok then
			-- RemoteFunction threw (e.g. server-side error or player kicked).
			log:warn("GetProfile invocation error", { attempt = attempt, err = tostring(result) })
			break
		end

		if result ~= nil then
			local p = result :: Types.PublicProfile
			currentRole  = p.role
			currentCoins = p.coins
			hud:updateRole(currentRole)
			hud:updateCoins(currentCoins)
			log:info("Profile received", {
				role   = currentRole,
				coins  = currentCoins,
				attempt = attempt,
			})
			return true
		end

		-- nil result: profile briefly unavailable between ProfileReady and the
		-- server handler running. Retry after a short delay.
		if attempt < GameConfig.PROFILE_FETCH_RETRIES then
			log:debug("GetProfile returned nil; retrying", { attempt = attempt })
			task.wait(GameConfig.PROFILE_FETCH_RETRY_DELAY)
		end
	end

	log:error("GetProfile failed after all retries — profile unavailable", {
		maxAttempts = GameConfig.PROFILE_FETCH_RETRIES,
	})
	return false
end

-- Wait for ProfileReady with a timeout fallback.
do
	local connection: RBXScriptConnection? = nil
	local timeoutThread: thread? = nil
	local handled = false

	local function onReady()
		if handled then
			return
		end
		handled = true

		if connection then
			connection:Disconnect()
			connection = nil
		end
		if timeoutThread then
			task.cancel(timeoutThread)
			timeoutThread = nil
		end

		fetchProfile()
	end

	connection = remotes.ProfileReady.OnClientEvent:Connect(function()
		log:debug("ProfileReady received — fetching profile")
		onReady()
	end)

	timeoutThread = task.delay(GameConfig.PROFILE_READY_TIMEOUT, function()
		if not handled then
			log:warn("ProfileReady not received within timeout; attempting fetch anyway", {
				timeoutSecs = GameConfig.PROFILE_READY_TIMEOUT,
			})
			onReady()
		end
	end)
end

log:info("Client bootstrap complete", { userId = localPlayer.UserId })
