--!strict

-- Structured, level-filtered logger.
-- Usage:
--   local log = Logger.new("MyService")
--   log:info("Player joined", { userId = player.UserId })

local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local Types = require(script.Parent.Parent.Types)

local LEVEL_PRIORITY: { [Types.LogLevel]: number } = {
	DEBUG = 1,
	INFO = 2,
	WARN = 3,
	ERROR = 4,
	FATAL = 5,
}

local MIN_LEVEL: Types.LogLevel = if GameConfig.DEBUG_MODE then "DEBUG" else "INFO"

-- ─── Formatting ───────────────────────────────────────────────────────────────

local function serializeContext(ctx: { [string]: unknown }?): string
	if not ctx then
		return ""
	end
	local parts: { string } = {}
	for k, v in ctx do
		table.insert(parts, k .. "=" .. tostring(v))
	end
	if #parts == 0 then
		return ""
	end
	return " | " .. table.concat(parts, ", ")
end

-- ─── Logger class ─────────────────────────────────────────────────────────────

local Logger = {}
Logger.__index = Logger

export type Logger = typeof(setmetatable(
	{} :: {
		_tag: string,
	},
	Logger
))

function Logger.new(tag: string): Logger
	return setmetatable({ _tag = tag }, Logger)
end

function Logger:_emit(level: Types.LogLevel, message: string, context: { [string]: unknown }?)
	if LEVEL_PRIORITY[level] < LEVEL_PRIORITY[MIN_LEVEL] then
		return
	end

	local line = string.format(
		"[%s][%s][%s] %s%s",
		os.date("%H:%M:%S"),
		level,
		self._tag,
		message,
		serializeContext(context)
	)

	if level == "DEBUG" or level == "INFO" then
		print(line)
	else
		-- WARN / ERROR / FATAL surface in the output with Roblox's yellow styling.
		warn(line)
	end
end

function Logger:debug(message: string, context: { [string]: unknown }?)
	self:_emit("DEBUG", message, context)
end

function Logger:info(message: string, context: { [string]: unknown }?)
	self:_emit("INFO", message, context)
end

function Logger:warn(message: string, context: { [string]: unknown }?)
	self:_emit("WARN", message, context)
end

function Logger:error(message: string, context: { [string]: unknown }?)
	self:_emit("ERROR", message, context)
end

function Logger:fatal(message: string, context: { [string]: unknown }?)
	self:_emit("FATAL", message, context)
end

return Logger
