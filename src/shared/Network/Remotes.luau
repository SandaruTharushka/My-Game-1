--!strict

-- Single source of truth for all RemoteEvents and RemoteFunctions.
--
-- Server calls Remotes.server() once during bootstrap — this creates the
-- folder and all remote instances in ReplicatedStorage.
--
-- Client calls Remotes.client() — this waits for the folder and returns
-- typed references to the same instances.
--
-- Never fire or invoke a remote from the wrong context; the handler on the
-- other side validates every payload before acting.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FOLDER_NAME = "GameRemotes"
local WAIT_TIMEOUT = 15 -- seconds before client errors

-- ─── Remote name registry ─────────────────────────────────────────────────────

local EVENT_NAMES: { string } = {
	"RequestRoleChange", -- C → S
	"RoleChanged", --       S → C
	"SendNotification", --  S → C
	"AdminResponse", --     S → C
}

local FUNCTION_NAMES: { string } = {
	"GetProfile", -- C → S
	"DebugEcho", --  C → S (dev only)
}

-- ─── Typed map ────────────────────────────────────────────────────────────────

export type RemoteMap = {
	RequestRoleChange: RemoteEvent,
	RoleChanged: RemoteEvent,
	SendNotification: RemoteEvent,
	AdminResponse: RemoteEvent,
	GetProfile: RemoteFunction,
	DebugEcho: RemoteFunction,
}

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function createRemote(parent: Folder, className: "RemoteEvent" | "RemoteFunction", name: string): Instance
	local r = Instance.new(className)
	r.Name = name
	r.Parent = parent
	return r
end

local function waitForRemote(parent: Instance, name: string): Instance
	local obj = parent:WaitForChild(name, WAIT_TIMEOUT)
	if not obj then
		error(string.format("[Remotes] '%s' not found within %ds — is the server running?", name, WAIT_TIMEOUT), 2)
	end
	return obj
end

-- ─── Public API ───────────────────────────────────────────────────────────────

local Remotes = {}

-- Called once by the server bootstrap. Creates every remote instance fresh.
-- Clears any stale folder from a previous Studio test run.
function Remotes.server(): RemoteMap
	local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = ReplicatedStorage

	local map: { [string]: Instance } = {}
	for _, name in EVENT_NAMES do
		map[name] = createRemote(folder, "RemoteEvent", name)
	end
	for _, name in FUNCTION_NAMES do
		map[name] = createRemote(folder, "RemoteFunction", name)
	end

	return map :: any
end

-- Called once by the client bootstrap. Blocks until the server has populated
-- the folder (typical wait is sub-frame after server start).
function Remotes.client(): RemoteMap
	local folder = ReplicatedStorage:WaitForChild(FOLDER_NAME, WAIT_TIMEOUT)
	if not folder then
		error(string.format("[Remotes] '%s' folder absent after %ds.", FOLDER_NAME, WAIT_TIMEOUT), 2)
	end

	local map: { [string]: Instance } = {}
	for _, name in EVENT_NAMES do
		map[name] = waitForRemote(folder, name)
	end
	for _, name in FUNCTION_NAMES do
		map[name] = waitForRemote(folder, name)
	end

	return map :: any
end

-- ─── Payload validators (used by all server-side remote handlers) ─────────────

-- Non-empty string within an optional length cap.
function Remotes.isSafeString(value: unknown, maxLen: number?): boolean
	if typeof(value) ~= "string" then
		return false
	end
	local s = value :: string
	if #s == 0 then
		return false
	end
	if maxLen ~= nil and #s > maxLen then
		return false
	end
	return true
end

-- Finite number within an inclusive range.
function Remotes.isNumberInRange(value: unknown, lo: number, hi: number): boolean
	if typeof(value) ~= "number" then
		return false
	end
	local n = value :: number
	return n == n and n >= lo and n <= hi -- n == n rejects NaN
end

return Remotes
