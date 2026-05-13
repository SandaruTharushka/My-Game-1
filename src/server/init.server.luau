--!strict

-- Server bootstrap.
--
-- Boot order matters:
--   1. Remotes       — creates the ReplicatedStorage folder before clients arrive.
--   2. MapService    — generates city geometry (idempotent).
--   3. ProfileService — connects to DataStore.
--   4. RoleService   — wires remote handlers that depend on ProfileService.
--   5. PlayerAdded / PlayerRemoving hooks.
--   6. Salary loop   — server-authoritative coin payments.
--   7. Autosave loop.
--   8. BindToClose flush.
--
-- Nothing in this file should contain game logic — delegate to services.

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local GameConfig = require(Shared.Config.GameConfig)
local RoleConfig = require(Shared.Config.RoleConfig)
local Logger     = require(Shared.Util.Logger)
local Remotes    = require(Shared.Network.Remotes)
local Types      = require(Shared.Types)

local MapService     = require(script.Services.MapService)
local ProfileService = require(script.Services.ProfileService)
local RoleService    = require(script.Services.RoleService)

local log = Logger.new("Bootstrap")

-- Tracks players whose ProfileReady has already been fired.
-- Prevents double-firing in edge cases (e.g. rapid Studio test runs).
local readyPlayers: { [number]: boolean } = {}

-- ─── 1. Remotes ───────────────────────────────────────────────────────────────

local remotes = Remotes.server()
log:info("Remotes initialised")

-- ─── 2. MapService ────────────────────────────────────────────────────────────

MapService.init()
log:info("MapService initialised")

-- ─── 3. ProfileService ────────────────────────────────────────────────────────

ProfileService.init()

-- ─── 4. RoleService ───────────────────────────────────────────────────────────

RoleService.init(ProfileService, remotes)

-- ─── 5. Remote: GetProfile ────────────────────────────────────────────────────

remotes.GetProfile.OnServerInvoke = function(player: Player): Types.PublicProfile?
	-- Return a serialisable snapshot — never the mutable server state.
	return ProfileService.toPublic(player.UserId)
end

-- ─── 6. Remote: DebugEcho (dev builds only) ───────────────────────────────────

if GameConfig.DEBUG_MODE then
	remotes.DebugEcho.OnServerInvoke = function(player: Player, msg: unknown): string
		log:debug("DebugEcho", { userId = player.UserId, msg = tostring(msg) })
		return "echo:" .. tostring(msg)
	end
end

-- ─── 7. Player lifecycle ──────────────────────────────────────────────────────

local function onPlayerAdded(player: Player)
	log:info("Player joining", { userId = player.UserId, name = player.Name })

	local state = ProfileService.load(player)
	if not state then
		-- Load returned nil only when something truly unexpected occurred.
		log:error("Profile load returned nil; kicking player", { userId = player.UserId })
		player:Kick("Your data could not be loaded. Please rejoin in a moment.")
		return
	end

	-- Guard: if the player left while the DataStore was loading, abort silently.
	-- player.Parent is nil once the player has been removed from the game.
	if player.Parent == nil then
		log:warn("Player left during profile load; skipping ProfileReady", { userId = player.UserId })
		return
	end

	-- Duplicate-fire guard — should never trigger in production, but Studio fast-
	-- restart can cause PlayerAdded to fire more than once per UserId.
	if readyPlayers[player.UserId] then
		log:warn("ProfileReady already fired for player; skipping duplicate", { userId = player.UserId })
		return
	end
	readyPlayers[player.UserId] = true

	-- Register the player's saved role into the occupancy tracker.
	RoleService.registerPlayer(player, state.data.role)

	-- Push the initial role to the client HUD.
	remotes.RoleChanged:FireClient(player, { role = state.data.role } :: Types.RoleChangedPayload)

	-- Signal the client that the profile is fully loaded and safe to fetch.
	-- The client waits for this event before calling GetProfile:InvokeServer().
	remotes.ProfileReady:FireClient(player, { userId = player.UserId } :: Types.ProfileReadyPayload)

	log:info("Player ready", {
		userId = player.UserId,
		role = state.data.role,
		coins = state.data.coins,
	})
end

local function onPlayerRemoving(player: Player)
	log:info("Player leaving", { userId = player.UserId })
	readyPlayers[player.UserId] = nil
	-- RoleService.onPlayerLeave is called inside RoleService via its own
	-- PlayerRemoving connection (registered in RoleService.init).
	ProfileService.release(player.UserId)
end

-- Handle players who joined before PlayerAdded fired (rare in Studio).
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- ─── 8. Salary loop ───────────────────────────────────────────────────────────
--
-- Server-authoritative: the client never touches coin values directly.
-- Pays each online player according to their current role's payRatePerMinute.

task.spawn(function()
	while true do
		task.wait(GameConfig.SALARY_INTERVAL)

		for _, player in Players:GetPlayers() do
			local userId = player.UserId
			local roleId = RoleService.currentRole(userId)
			if not roleId then
				continue
			end

			local def = RoleConfig[roleId]
			if not def then
				continue
			end

			local pay = def.payRatePerMinute
			if pay <= 0 then
				continue
			end

			local newBalance = ProfileService.adjustCoins(userId, pay)
			if newBalance == nil then
				continue
			end

			-- Notify client so the HUD can update.
			remotes.RoleChanged:FireClient(player, { role = roleId } :: Types.RoleChangedPayload)

			remotes.SendNotification:FireClient(player, {
				kind = "success",
				message = string.format("Salary paid: +%d coins (balance: %d)", pay, newBalance),
			} :: Types.NotificationPayload)

			log:info("Salary paid", { userId = userId, role = roleId, pay = pay, balance = newBalance })
		end
	end
end)

-- ─── 9. Autosave loop ─────────────────────────────────────────────────────────

task.spawn(function()
	while true do
		task.wait(GameConfig.AUTOSAVE_INTERVAL)
		log:debug("Autosave tick")
		ProfileService.autosaveAll()
	end
end)

-- ─── 10. Rate-limiter sweep (prevents unbounded memory growth in long sessions) ─

-- RoleLimiter sweep is driven by RoleService internally.
-- Add sweeps for other limiters here as Phase 2+ services are introduced.
task.spawn(function()
	while true do
		task.wait(GameConfig.RATELIMIT_SWEEP_INTERVAL)
		-- Future: iterate all registered RateLimiter instances and call :sweep()
	end
end)

-- ─── 11. BindToClose ──────────────────────────────────────────────────────────

game:BindToClose(function()
	log:info("Server closing — flushing all profiles")
	ProfileService.saveAll()
	log:info("BindToClose complete")
end)

log:info("Server bootstrap complete")
