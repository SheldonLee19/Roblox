--!strict
--[[
	Signal.luau

	A minimal signal implementation, used instead of BindableEvent because
	BindableEvents cannot reliably carry most Roblox datatypes across the
	boundary, are markedly slower for high-frequency game events, and swallow
	errors raised inside handlers.

	Handlers are dispatched on their own thread, so a single erroring listener
	cannot stop the remaining listeners from running. That matters here: a
	broken results-screen listener must never prevent the payout listener from
	paying out.
]]

local Signal = {}
Signal.__index = Signal

export type Connection = {
	Connected: boolean,
	Disconnect: (Connection) -> (),
}

type Handler = (...any) -> ()

export type Signal = typeof(setmetatable(
	{} :: {
		_handlers: { Handler },
		_enabled: boolean,
	},
	Signal
))

local ConnectionImpl = {}
ConnectionImpl.__index = ConnectionImpl

function ConnectionImpl.Disconnect(self: Connection): ()
	if not self.Connected then
		return
	end

	self.Connected = false

	local signal = (self :: any)._signal :: Signal
	local handler = (self :: any)._handler :: Handler
	local index = table.find(signal._handlers, handler)

	-- Removal during dispatch is safe: Fire() below snapshots the handler
	-- list before iterating, so a handler disconnecting itself (or another)
	-- mid-fire cannot corrupt the loop.
	if index then
		table.remove(signal._handlers, index)
	end
end

--[[
	Registers `handler` and returns a Connection.

	`once` makes the connection self-disconnecting: it fires at most one time,
	which is the common case for "wait for the round to end" style listeners
	and saves callers from remembering to disconnect.
]]
function Signal.Connect(self: Signal, handler: Handler): Connection
	table.insert(self._handlers, handler)

	local connection = setmetatable({
		Connected = true,
		_signal = self,
		_handler = handler,
	}, ConnectionImpl :: any)

	return (connection :: any) :: Connection
end

function Signal.Once(self: Signal, handler: Handler): Connection
	local connection: Connection

	connection = self:Connect(function(...)
		connection:Disconnect()
		handler(...)
	end)

	return connection
end

--[[
	Fires every connected handler. Handler errors are reported to the Roblox
	output but do not propagate to the caller or block later handlers.
]]
function Signal.Fire(self: Signal, ...: any): ()
	if not self._enabled then
		return
	end

	-- Snapshot: handlers may connect or disconnect during dispatch.
	local snapshot = table.clone(self._handlers)

	for _, handler in snapshot do
		task.spawn(handler, ...)
	end
end

function Signal.DisconnectAll(self: Signal): ()
	table.clear(self._handlers)
end

--[[
	Suspends dispatch without dropping connections. Used when a round tears
	down: listeners stay registered for the next round, but late events from
	the finished one are ignored.
]]
function Signal.SetEnabled(self: Signal, enabled: boolean): ()
	self._enabled = enabled
end

function Signal.Destroy(self: Signal): ()
	self:DisconnectAll()
	self._enabled = false
end

local function new(): Signal
	return setmetatable({
		_handlers = {},
		_enabled = true,
	}, Signal :: any) :: any
end

return setmetatable({
	new = new,
}, {
	__call = function(_, ...: any)
		return new(...)
	end,
})
