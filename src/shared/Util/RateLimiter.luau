--!strict

-- Sliding-window rate limiter. One instance per logical action.
-- All state is per-userId; call clearPlayer on disconnect to prevent leaks.
-- Call sweep() periodically to purge idle records.

local Types = require(script.Parent.Parent.Types)

type WindowRecord = {
	count: number,
	windowStart: number, -- os.clock() timestamp
}

local RateLimiter = {}
RateLimiter.__index = RateLimiter

export type RateLimiter = typeof(setmetatable(
	{} :: {
		_max: number,
		_window: number,
		_records: { [number]: WindowRecord },
	},
	RateLimiter
))

function RateLimiter.new(maxRequests: number, windowSeconds: number): RateLimiter
	assert(maxRequests > 0, "maxRequests must be positive")
	assert(windowSeconds > 0, "windowSeconds must be positive")
	return setmetatable({
		_max = maxRequests,
		_window = windowSeconds,
		_records = {},
	}, RateLimiter)
end

-- Returns the result and increments the counter if allowed.
function RateLimiter:check(userId: number): Types.RateLimitResult
	local now = os.clock()
	local rec = self._records[userId]

	if rec == nil or (now - rec.windowStart) >= self._window then
		-- No record, or previous window expired — open a fresh window.
		self._records[userId] = { count = 1, windowStart = now }
		return { allowed = true, retryAfter = nil }
	end

	if rec.count < self._max then
		rec.count += 1
		return { allowed = true, retryAfter = nil }
	end

	local retryAfter = self._window - (now - rec.windowStart)
	return { allowed = false, retryAfter = retryAfter }
end

-- Must be called when a player leaves to reclaim memory.
function RateLimiter:clearPlayer(userId: number)
	self._records[userId] = nil
end

-- Purges all records whose window has already expired.
-- Call from a periodic server task to prevent unbounded growth in large servers.
function RateLimiter:sweep()
	local now = os.clock()
	for userId, rec in self._records do
		if (now - rec.windowStart) >= self._window then
			self._records[userId] = nil
		end
	end
end

-- For diagnostics — returns current request count within the active window, or 0.
function RateLimiter:peekCount(userId: number): number
	local now = os.clock()
	local rec = self._records[userId]
	if rec == nil or (now - rec.windowStart) >= self._window then
		return 0
	end
	return rec.count
end

return RateLimiter
