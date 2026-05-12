--!strict

-- Game-wide configuration. Edit values here; no code changes required elsewhere.
-- All tunable constants live in this one file for easy ops adjustment.

export type RateLimitEntry = {
	maxRequests: number,
	windowSeconds: number,
}

export type GameConfigType = {
	-- DataStore
	DATASTORE_NAME: string,
	DATASTORE_SCOPE: string,
	MAX_DATASTORE_RETRIES: number,
	DATASTORE_RETRY_BASE_DELAY: number, -- seconds; doubles each attempt
	DATASTORE_RETRY_MAX_DELAY: number,

	-- Session lock
	SESSION_LOCK_EXPIRY: number, -- seconds before a lock is considered stale
	SESSION_LOCK_REFRESH_DIVISOR: number, -- refresh at EXPIRY / DIVISOR

	-- Schema
	SCHEMA_VERSION: number,

	-- Autosave
	AUTOSAVE_INTERVAL: number, -- seconds

	-- Economy
	MAX_COINS: number,

	-- Debugging
	DEBUG_MODE: boolean,

	-- Per-remote rate limits
	RATE_LIMIT: { [string]: RateLimitEntry },

	-- Maintenance sweep interval for in-memory rate-limit records
	RATELIMIT_SWEEP_INTERVAL: number,
}

local GameConfig: GameConfigType = {
	DATASTORE_NAME = "PlayerProfiles_v1",
	DATASTORE_SCOPE = "global",
	MAX_DATASTORE_RETRIES = 5,
	DATASTORE_RETRY_BASE_DELAY = 2,
	DATASTORE_RETRY_MAX_DELAY = 30,

	SESSION_LOCK_EXPIRY = 60, -- seconds; keep well above typical save time
	SESSION_LOCK_REFRESH_DIVISOR = 2, -- refresh every 30 s when EXPIRY = 60

	SCHEMA_VERSION = 1,

	AUTOSAVE_INTERVAL = 60,

	MAX_COINS = 9_999_999,

	-- Set to true in Studio for verbose DEBUG-level output.
	-- Never ship with DEBUG_MODE = true.
	DEBUG_MODE = false,

	RATE_LIMIT = {
		SetRole = { maxRequests = 3, windowSeconds = 10 },
		ClaimHouse = { maxRequests = 2, windowSeconds = 10 },
		SpawnVehicle = { maxRequests = 3, windowSeconds = 15 },
		Interact = { maxRequests = 10, windowSeconds = 5 },
		AdminCommand = { maxRequests = 5, windowSeconds = 10 },
	},

	RATELIMIT_SWEEP_INTERVAL = 300, -- seconds (5 min)
}

return GameConfig
