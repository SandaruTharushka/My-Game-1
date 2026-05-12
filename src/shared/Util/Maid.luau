--!strict

-- Maid: accumulates cleanup tasks and runs them all on destroy().
-- Accepted task types:
--   () -> ()              plain cleanup function
--   RBXScriptConnection   auto-disconnected
--   Instance              auto-destroyed
--   thread                cancelled via task.cancel

-- Named "CleanupTask" to avoid shadowing the Roblox `task` global.
type CleanupTask = (() -> ()) | RBXScriptConnection | Instance | thread

local Maid = {}
Maid.__index = Maid

export type Maid = typeof(setmetatable(
	{} :: {
		_tasks: { CleanupTask },
		_destroyed: boolean,
	},
	Maid
))

function Maid.new(): Maid
	return setmetatable({ _tasks = {}, _destroyed = false }, Maid)
end

-- Registers a cleanup task and returns it for convenience chaining.
function Maid:add<T>(item: T & CleanupTask): T
	if self._destroyed then
		-- Immediately clean up items added after destroy to avoid leaks.
		local kind = typeof(item)
		if kind == "function" then
			(item :: any)()
		elseif kind == "RBXScriptConnection" then
			(item :: RBXScriptConnection):Disconnect()
		elseif kind == "Instance" then
			(item :: Instance):Destroy()
		elseif kind == "thread" then
			task.cancel(item :: thread)
		end
		return item
	end
	table.insert(self._tasks, item :: CleanupTask)
	return item
end

-- Shorthand: connect a signal, register the connection, and return it.
function Maid:connect(signal: RBXScriptSignal, fn: (...unknown) -> ()): RBXScriptConnection
	local conn = signal:Connect(fn)
	self:add(conn)
	return conn
end

-- Shorthand: spawn a task thread and register it for cancellation.
function Maid:spawn(fn: () -> ()): thread
	local t = task.spawn(fn)
	self:add(t)
	return t
end

-- Runs all registered cleanup tasks in LIFO order, then marks self destroyed.
-- Idempotent — safe to call multiple times.
function Maid:destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true

	local tasks = self._tasks
	self._tasks = {}

	for i = #tasks, 1, -1 do
		local item = tasks[i]
		local kind = typeof(item)
		local ok, err = pcall(function()
			if kind == "function" then
				(item :: () -> ())()
			elseif kind == "RBXScriptConnection" then
				(item :: RBXScriptConnection):Disconnect()
			elseif kind == "Instance" then
				(item :: Instance):Destroy()
			elseif kind == "thread" then
				task.cancel(item :: thread)
			end
		end)
		if not ok then
			warn("[Maid] Cleanup task errored: " .. tostring(err))
		end
	end
end

return Maid
