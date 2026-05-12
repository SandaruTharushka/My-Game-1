--!strict

-- RoleService: authoritative role/job management.
--
-- Responsibilities:
--   • Validate and apply role-change requests from the client.
--   • Enforce per-role concurrency caps.
--   • Rate-limit role-change remotes.
--   • Expose permission helpers used by other server systems.
--   • Track role occupancy counts and clean up on player leave.
--
-- Wired up by the server bootstrap, which passes the ProfileService and the
-- RemoteMap to avoid a circular require chain.

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local GameConfig = require(Shared.Config.GameConfig)
local RoleConfig = require(Shared.Config.RoleConfig)
local Logger = require(Shared.Util.Logger)
local RateLimiter = require(Shared.Util.RateLimiter)
local Remotes = require(Shared.Network.Remotes)

local log = Logger.new("RoleService")

-- ─── Rate limiter ─────────────────────────────────────────────────────────────

local rl = GameConfig.RATE_LIMIT.SetRole
local roleChangeLimiter = RateLimiter.new(rl.maxRequests, rl.windowSeconds)

-- ─── Occupancy tracking ───────────────────────────────────────────────────────

-- How many players currently hold each role.
local roleCounts: { [string]: number } = {}
for roleId in RoleConfig do
	roleCounts[roleId] = 0
end

-- Which role each connected player currently holds.
local playerRole: { [number]: string } = {}

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function decrementRole(userId: number)
	local current = playerRole[userId]
	if current then
		roleCounts[current] = math.max(0, (roleCounts[current] or 0) - 1)
		playerRole[userId] = nil
	end
end

local function incrementRole(userId: number, roleId: string)
	roleCounts[roleId] = (roleCounts[roleId] or 0) + 1
	playerRole[userId] = roleId
end

-- ─── ProfileService interface (passed in at init) ─────────────────────────────

type ProfileServiceInterface = {
	get: (userId: number) -> any,
	setRole: (userId: number, roleId: string) -> boolean,
	markDirty: (userId: number) -> (),
}

-- ─── Core role change logic ───────────────────────────────────────────────────

-- Returns (success, errorMessage|nil).
-- Does NOT fire any remotes — that is the caller's job.
local function applyRoleChange(
	player: Player,
	roleId: string,
	profileService: ProfileServiceInterface
): (boolean, string?)
	local def = RoleConfig[roleId]
	if not def then
		log:warn("Unknown role requested", { userId = player.UserId, role = roleId })
		return false, "Unknown role."
	end

	-- Concurrency cap.
	if def.maxConcurrentPlayers ~= nil then
		local occupied = roleCounts[roleId] or 0
		if occupied >= def.maxConcurrentPlayers then
			return false, def.displayName .. " is full. Try again later."
		end
	end

	local profile = profileService.get(player.UserId)
	if not profile then
		return false, "Your profile is not loaded. Please rejoin."
	end

	-- Don't update if already in this role.
	if playerRole[player.UserId] == roleId then
		return false, "You are already a " .. def.displayName .. "."
	end

	decrementRole(player.UserId)
	incrementRole(player.UserId, roleId)

	profileService.setRole(player.UserId, roleId)

	log:info("Role applied", { userId = player.UserId, role = roleId })
	return true, nil
end

-- ─── Public API ───────────────────────────────────────────────────────────────

local RoleService = {}

-- `profileService` and `remotes` are injected by the bootstrap to break the
-- potential circular require between services.
function RoleService.init(profileService: ProfileServiceInterface, remotes: Remotes.RemoteMap)
	-- ── RequestRoleChange handler ──────────────────────────────────────────
	remotes.RequestRoleChange.OnServerEvent:Connect(function(player: Player, rawPayload: unknown)
		-- Validate payload shape before doing anything.
		if not Remotes.isSafeString(rawPayload, 64) then
			log:warn("RequestRoleChange: bad payload", { userId = player.UserId, got = typeof(rawPayload) })
			return
		end
		local roleId = rawPayload :: string

		-- Rate limit.
		local result = roleChangeLimiter:check(player.UserId)
		if not result.allowed then
			log:warn("RequestRoleChange rate-limited", {
				userId = player.UserId,
				retryAfter = result.retryAfter,
			})
			remotes.SendNotification:FireClient(player, {
				kind = "warning",
				message = string.format(
					"Please wait %.0f second(s) before changing role again.",
					math.ceil(result.retryAfter or 0)
				),
			} :: Types.NotificationPayload)
			return
		end

		local ok, errMsg = applyRoleChange(player, roleId, profileService)

		if ok then
			local def = RoleConfig[roleId]
			remotes.RoleChanged:FireClient(player, { role = roleId } :: Types.RoleChangedPayload)
			remotes.SendNotification:FireClient(player, {
				kind = "success",
				message = "You are now a " .. (def and def.displayName or roleId) .. ".",
			} :: Types.NotificationPayload)
		else
			remotes.SendNotification:FireClient(player, {
				kind = "error",
				message = errMsg or "Could not change role.",
			} :: Types.NotificationPayload)
		end
	end)

	-- ── Player cleanup ────────────────────────────────────────────────────
	Players.PlayerRemoving:Connect(function(player: Player)
		RoleService.onPlayerLeave(player.UserId)
	end)

	local roleCount = 0
	for _ in RoleConfig do
		roleCount += 1
	end
	log:info("RoleService initialised", { roles = roleCount })
end

-- Called by the bootstrap when a player's profile is first loaded.
-- Sets the initial occupancy from their saved role.
function RoleService.registerPlayer(player: Player, savedRole: string)
	local def = RoleConfig[savedRole]
	if not def then
		-- Saved role no longer exists (e.g., role was removed from config).
		savedRole = "civilian"
		log:warn("Saved role not found; defaulting to civilian", { userId = player.UserId })
	end
	incrementRole(player.UserId, savedRole)
	log:debug("Player registered with role", { userId = player.UserId, role = savedRole })
end

-- Cleans up occupancy data on disconnect.
function RoleService.onPlayerLeave(userId: number)
	decrementRole(userId)
	roleChangeLimiter:clearPlayer(userId)
end

-- ── Permission helpers (used by other services, e.g. Vehicle, Property) ───────

function RoleService.getPermissions(roleId: string): Types.RolePermissions?
	local def = RoleConfig[roleId]
	return if def then def.permissions else nil
end

-- Generic boolean permission gate.
function RoleService.hasPermission(roleId: string, permission: string): boolean
	local perms = RoleService.getPermissions(roleId)
	if not perms then
		return false
	end
	return (perms :: { [string]: any })[permission] == true
end

-- Convenience wrappers for the most common checks.
function RoleService.canArrest(roleId: string): boolean
	return RoleService.hasPermission(roleId, "canArrest")
end

function RoleService.canHeal(roleId: string): boolean
	return RoleService.hasPermission(roleId, "canHeal")
end

function RoleService.canRepairVehicles(roleId: string): boolean
	return RoleService.hasPermission(roleId, "canRepairVehicles")
end

-- Returns the RoleDefinition, or nil for unknown role IDs.
function RoleService.getDef(roleId: string): Types.RoleDefinition?
	return RoleConfig[roleId]
end

-- Current occupancy count for a role.
function RoleService.getCount(roleId: string): number
	return roleCounts[roleId] or 0
end

-- The role ID currently held by this userId (nil if not registered yet).
function RoleService.currentRole(userId: number): string?
	return playerRole[userId]
end

return RoleService
