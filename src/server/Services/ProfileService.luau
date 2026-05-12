--!strict

-- ProfileService: authoritative DataStore abstraction.
--
-- Responsibilities:
--   • Load player data with schema migration on join.
--   • Session lock — prevents concurrent server corruption via a separate
--     lock DataStore key that expires if the server crashes.
--   • Budget-aware DataStore calls with exponential-backoff retries.
--   • Autosave (driven by the server bootstrap loop).
--   • BindToClose — flush all dirty profiles before the server shuts down.
--   • Graceful ephemeral fallback if a lock cannot be acquired.
--
-- Callers must treat the returned ProfileState as server-only; the public
-- snapshot sent to clients is built by the bootstrap's GetProfile handler.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local GameConfig = require(Shared.Config.GameConfig)
local Logger = require(Shared.Util.Logger)

local log = Logger.new("ProfileService")

-- ─── Constants ────────────────────────────────────────────────────────────────

local SCHEMA_VERSION = GameConfig.SCHEMA_VERSION
local MAX_RETRIES = GameConfig.MAX_DATASTORE_RETRIES
local BASE_DELAY = GameConfig.DATASTORE_RETRY_BASE_DELAY
local MAX_DELAY = GameConfig.DATASTORE_RETRY_MAX_DELAY
local LOCK_EXPIRY = GameConfig.SESSION_LOCK_EXPIRY
local LOCK_REFRESH = LOCK_EXPIRY / GameConfig.SESSION_LOCK_REFRESH_DIVISOR

-- ─── Default data & migrations ────────────────────────────────────────────────

local function defaultData(): Types.PlayerData
	return {
		schemaVersion = SCHEMA_VERSION,
		coins = 0,
		ownedVehicles = {},
		ownedHouses = {},
		role = "civilian",
		settings = {
			musicEnabled = true,
			notificationsEnabled = true,
		},
	}
end

-- Migration functions indexed by the version they migrate *to*.
-- Each receives the raw saved table and must return the updated table.
-- Add an entry here whenever SCHEMA_VERSION is incremented.
type MigrationFn = (raw: { [string]: any }) -> { [string]: any }
local MIGRATIONS: { [number]: MigrationFn } = {
	-- Example (version 1 already is the baseline, no migration needed):
	-- [2] = function(raw)
	--     raw.newField = raw.newField or "default"
	--     return raw
	-- end,
}

local function applyMigrations(raw: { [string]: any }): Types.PlayerData
	local version = tonumber(raw.schemaVersion) or 0

	while version < SCHEMA_VERSION do
		version += 1
		local fn = MIGRATIONS[version]
		if fn then
			raw = fn(raw)
			log:info("Schema migration applied", { toVersion = version })
		end
	end

	raw.schemaVersion = SCHEMA_VERSION

	-- Back-fill any fields missing from partial saves or newly added keys.
	local defaults = defaultData()
	for key, value in defaults do
		if (raw :: any)[key] == nil then
			(raw :: any)[key] = value
		end
	end

	return raw :: Types.PlayerData
end

-- ─── DataStore handles ────────────────────────────────────────────────────────

local dataStore: DataStore
local lockStore: DataStore

-- ─── Budget-aware retry wrapper ───────────────────────────────────────────────

local function waitBudget(reqType: Enum.DataStoreRequestType)
	local waited = 0
	while DataStoreService:GetRequestBudgetForRequestType(reqType) < 1 do
		task.wait(1)
		waited += 1
		if waited >= 30 then
			log:warn("DataStore budget depleted; continuing anyway", { reqType = tostring(reqType) })
			return
		end
	end
end

-- Returns (success, result|nil).
-- `fn` must be a zero-argument function that calls a DataStore method.
local function withRetry<T>(fn: () -> T, label: string): (boolean, T?)
	local delay = BASE_DELAY
	for attempt = 1, MAX_RETRIES do
		local ok, result = pcall(fn)
		if ok then
			return true, result :: T
		end
		log:warn("DataStore call failed", { label = label, attempt = attempt, err = tostring(result) })
		if attempt < MAX_RETRIES then
			task.wait(delay)
			delay = math.min(delay * 2, MAX_DELAY)
		end
	end
	log:error("DataStore retries exhausted", { label = label })
	return false, nil
end

-- ─── Session lock ─────────────────────────────────────────────────────────────

type LockRecord = {
	jobId: string,
	expires: number, -- os.time()
}

local function lockKey(userId: number): string
	return "lock_" .. tostring(userId)
end

-- Returns true when this server successfully holds the lock afterwards.
local function acquireLock(userId: number): boolean
	local key = lockKey(userId)
	local jobId = game.JobId
	local acquired = false

	waitBudget(Enum.DataStoreRequestType.UpdateAsync)

	local ok, _ = withRetry(function()
		lockStore:UpdateAsync(key, function(current: any): LockRecord?
			if current ~= nil then
				local rec = current :: LockRecord
				local ours = rec.jobId == jobId
				local stale = os.time() >= rec.expires
				if not ours and not stale then
					-- Another live server holds this lock — abort UpdateAsync.
					return nil
				end
			end
			acquired = true
			return { jobId = jobId, expires = os.time() + LOCK_EXPIRY } :: LockRecord
		end)
	end, "acquireLock:" .. userId)

	if not ok then
		log:error("acquireLock errored", { userId = userId })
	end

	return acquired
end

local function releaseLock(userId: number)
	local key = lockKey(userId)
	waitBudget(Enum.DataStoreRequestType.UpdateAsync)
	pcall(function()
		lockStore:UpdateAsync(key, function(current: any): LockRecord?
			if current == nil then
				return nil
			end
			local rec = current :: LockRecord
			-- Only clear the lock if this server still owns it.
			if rec.jobId == game.JobId then
				return nil
			end
			return current
		end)
	end)
end

local function refreshLock(userId: number)
	local key = lockKey(userId)
	pcall(function()
		lockStore:UpdateAsync(key, function(current: any): LockRecord?
			if current == nil then
				return nil
			end
			local rec = current :: LockRecord
			if rec.jobId == game.JobId then
				return { jobId = game.JobId, expires = os.time() + LOCK_EXPIRY } :: LockRecord
			end
			return current
		end)
	end)
end

-- ─── Profile state ────────────────────────────────────────────────────────────

type ProfileState = {
	data: Types.PlayerData,
	isDirty: boolean,
	-- When true the profile was loaded without a session lock (another server
	-- was active). Saves are skipped to avoid data corruption.
	isEphemeral: boolean,
	userId: number,
	-- The thread that periodically refreshes the session lock.
	lockRefreshThread: thread?,
}

local profiles: { [number]: ProfileState } = {}

-- ─── Internal save (no lock check — callers must ensure order) ───────────────

local function performSave(state: ProfileState)
	if state.isEphemeral then
		return -- Never persist ephemeral sessions.
	end

	local key = tostring(state.userId)
	-- Snapshot the data table so a mid-save mutation cannot corrupt the write.
	local snapshot = table.clone(state.data)

	waitBudget(Enum.DataStoreRequestType.SetIncrementAsync)

	local ok, _ = withRetry(function()
		dataStore:SetAsync(key, snapshot)
	end, "save:" .. state.userId)

	if ok then
		state.isDirty = false
		log:debug("Profile saved", { userId = state.userId })
	else
		log:error("Profile save failed", { userId = state.userId })
	end
end

-- ─── Public API ───────────────────────────────────────────────────────────────

local ProfileService = {}

function ProfileService.init()
	dataStore = DataStoreService:GetDataStore(GameConfig.DATASTORE_NAME, GameConfig.DATASTORE_SCOPE)
	-- Keep locks in a separate store so their budget doesn't crowd out profile reads/writes.
	lockStore =
		DataStoreService:GetDataStore(GameConfig.DATASTORE_NAME .. "_locks", GameConfig.DATASTORE_SCOPE)
	log:info("ProfileService initialised", {
		store = GameConfig.DATASTORE_NAME,
		schema = SCHEMA_VERSION,
	})
end

-- Loads (or creates) the profile for `player`.
-- Returns the ProfileState, or nil if something went catastrophically wrong.
function ProfileService.load(player: Player): ProfileState?
	local userId = player.UserId

	if profiles[userId] then
		log:warn("load() called for already-loaded profile", { userId = userId })
		return profiles[userId]
	end

	-- Attempt to acquire the session lock before any read.
	local locked = acquireLock(userId)
	local isEphemeral = not locked
	if isEphemeral then
		log:warn("Session lock unavailable; profile is read-only for this session", { userId = userId })
	end

	-- Read saved data.
	local data: Types.PlayerData
	if not isEphemeral then
		waitBudget(Enum.DataStoreRequestType.GetAsync)
		local ok, raw = withRetry(function()
			return dataStore:GetAsync(tostring(userId))
		end, "load:" .. userId)

		if not ok then
			log:error("GetAsync failed; using default data", { userId = userId })
			data = defaultData()
		elseif raw == nil then
			data = defaultData()
		else
			data = applyMigrations(raw :: { [string]: any })
		end
	else
		data = defaultData()
	end

	local state: ProfileState = {
		data = data,
		isDirty = false,
		isEphemeral = isEphemeral,
		userId = userId,
		lockRefreshThread = nil,
	}

	-- Spawn the lock-refresh heartbeat only when we legitimately own the lock.
	if not isEphemeral then
		state.lockRefreshThread = task.spawn(function()
			while profiles[userId] ~= nil do
				task.wait(LOCK_REFRESH)
				if profiles[userId] ~= nil then
					refreshLock(userId)
				end
			end
		end)
	end

	profiles[userId] = state
	log:info("Profile loaded", { userId = userId, ephemeral = isEphemeral, role = data.role })
	return state
end

-- Returns the active ProfileState for the given userId, or nil if not loaded.
function ProfileService.get(userId: number): ProfileState?
	return profiles[userId]
end

-- Marks the profile dirty so the next autosave flushes it.
function ProfileService.markDirty(userId: number)
	local state = profiles[userId]
	if state and not state.isEphemeral then
		state.isDirty = true
	end
end

-- Atomically adjusts coins, clamped to [0, MAX_COINS].
-- Returns the new balance, or nil if the profile is not loaded.
function ProfileService.adjustCoins(userId: number, delta: number): number?
	local state = profiles[userId]
	if not state then
		return nil
	end
	local newBalance = math.clamp(state.data.coins + delta, 0, GameConfig.MAX_COINS)
	state.data.coins = newBalance
	state.isDirty = true
	return newBalance
end

-- Sets the player's role string.
function ProfileService.setRole(userId: number, roleId: string): boolean
	local state = profiles[userId]
	if not state then
		return false
	end
	state.data.role = roleId
	state.isDirty = true
	return true
end

-- Saves and releases the profile. Call on PlayerRemoving.
function ProfileService.release(userId: number)
	local state = profiles[userId]
	if not state then
		return
	end

	-- Stop the lock refresh before any async work.
	if state.lockRefreshThread then
		task.cancel(state.lockRefreshThread)
		state.lockRefreshThread = nil
	end

	-- Remove from the map first so concurrent autosave tasks skip this entry.
	profiles[userId] = nil

	-- Final save, then release the lock.
	performSave(state)

	if not state.isEphemeral then
		releaseLock(userId)
	end

	log:info("Profile released", { userId = userId })
end

-- Saves all dirty profiles. Intended for the server autosave loop.
function ProfileService.autosaveAll()
	for _, state in profiles do
		if state.isDirty then
			task.spawn(performSave, state)
		end
	end
end

-- Flush all profiles synchronously (within Roblox's 30 s BindToClose window).
-- Spawns saves in parallel and waits up to 25 s for them to finish.
function ProfileService.saveAll()
	local pending = 0

	for _, state in profiles do
		if not state.isEphemeral then
			pending += 1
			task.spawn(function()
				performSave(state)
				pending -= 1
			end)
		end
	end

	local deadline = os.clock() + 25
	while pending > 0 and os.clock() < deadline do
		task.wait(0.1)
	end

	if pending > 0 then
		log:warn("saveAll timed out; some profiles may not have been written", { remaining = pending })
	else
		log:info("saveAll complete")
	end
end

-- Read-only snapshot safe to transmit to the client.
function ProfileService.toPublic(userId: number): Types.PublicProfile?
	local state = profiles[userId]
	if not state then
		return nil
	end
	local d = state.data
	return {
		coins = d.coins,
		role = d.role,
		ownedVehicles = d.ownedVehicles,
		ownedHouses = d.ownedHouses,
		settings = d.settings,
	}
end

return ProfileService
