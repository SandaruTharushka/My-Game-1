--!strict

-- Canonical type definitions shared between server and client.
-- Import this module anywhere you need cross-boundary data shapes.

export type PlayerSettings = {
	musicEnabled: boolean,
	notificationsEnabled: boolean,
}

export type PlayerData = {
	schemaVersion: number,
	coins: number,
	ownedVehicles: { string },
	ownedHouses: { string },
	role: string,
	settings: PlayerSettings,
}

export type RolePermissions = {
	canArrest: boolean,
	canHeal: boolean,
	canAccessShop: boolean,
	canRepairVehicles: boolean,
	maxActiveVehicles: number,
}

export type RoleDefinition = {
	id: string,
	displayName: string,
	description: string,
	permissions: RolePermissions,
	payRatePerMinute: number,
	maxConcurrentPlayers: number?, -- nil = unlimited
}

export type LogLevel = "DEBUG" | "INFO" | "WARN" | "ERROR" | "FATAL"

export type LogEntry = {
	level: LogLevel,
	tag: string,
	message: string,
	timestamp: number,
	context: { [string]: unknown }?,
}

export type RateLimitResult = {
	allowed: boolean,
	retryAfter: number?, -- seconds until next allowed request
}

-- Opaque shape sent to the client via GetProfile; never includes server-only fields.
export type PublicProfile = {
	coins: number,
	role: string,
	ownedVehicles: { string },
	ownedHouses: { string },
	settings: PlayerSettings,
}

-- Notification payload fired from server → client.
export type NotificationPayload = {
	kind: "success" | "error" | "info" | "warning",
	message: string,
	duration: number?, -- seconds; nil = default
}

-- RoleChanged payload fired from server → client.
export type RoleChangedPayload = {
	role: string,
}

return {}
