--!strict
--[[
	StateMachine.luau

	A reusable, declarative round state machine shared by every minigame.

	The lifecycle of a round is identical across all ten games:
	waiting -> voting -> countdown -> playing -> results -> cleanup.
	Only the *rules* differ. Ten hand-rolled state machines is ten places for a
	disconnect, an early return, or a double-payout bug to hide -- and for a
	three-person team, the fourth minigame is where those bugs start shipping.

	States are declared with optional auto-advance:

		local machine = StateMachine.new({
			Waiting   = { next = "Voting" },
			Voting    = { duration = 15, next = "Countdown" },
			Countdown = { duration = 5,  next = "Playing" },
			Playing   = { next = "Results" },   -- waits for :Transition()
			Results   = { duration = 12, next = "Cleanup" },
			Cleanup   = { next = "Waiting" },
		})

	Timed transitions use a generation counter rather than holding a thread
	reference. Without it, a manual :Transition() during the countdown would
	leave the countdown's timer armed, and it would fire mid-round and drag
	the machine into the wrong state. That class of bug is intermittent and
	miserable to reproduce, so it is designed out here.
]]

local StateMachine = {}
StateMachine.__index = StateMachine

export type StateDefinition = {
	-- Seconds before auto-advancing. nil means the state waits for an
	-- explicit :Transition() -- used for Playing, which ends when the game
	-- says it ends, not when a timer says so.
	duration: number?,
	-- State to auto-advance to once `duration` elapses.
	next: string?,
}

export type Listener = (current: string, previous: string?) -> ()

export type StateMachine = typeof(setmetatable(
	{} :: {
		_states: { [string]: StateDefinition },
		_current: string,
		_previous: string?,
		_enteredAt: number,
		_generation: number,
		_destroyed: boolean,
		_listeners: { Listener },
		_entering: { [string]: { (previous: string?) -> () } },
		_exiting: { [string]: { (next: string?) -> () } },
	},
	StateMachine
))

--[[
	Creates a machine. The first key in `states` is the initial state, so
	declaration order is meaningful -- which also makes the flow readable at
	the call site.
]]
function StateMachine.new(states: { [string]: StateDefinition }): StateMachine
	local initial: string? = nil
	for name in states do
		initial = name
		break
	end

	assert(initial ~= nil, "[StateMachine] Cannot create a machine with no states")

	-- Every `next` must resolve, or the round hangs in a state forever with
	-- no error. Failing loudly here is far better than a silent stuck lobby.
	for name, definition in states do
		if definition.next ~= nil then
			assert(
				states[definition.next] ~= nil,
				string.format(
					"[StateMachine] State %q advances to %q, which is not a declared state",
					name,
					definition.next
				)
			)
			assert(
				definition.duration ~= nil,
				string.format(
					"[StateMachine] State %q declares next=%q but no duration, so it would never advance",
					name,
					definition.next
				)
			)
		end
	end

	return setmetatable({
		_states = states,
		_current = initial,
		_previous = nil,
		_enteredAt = os.clock(),
		_generation = 0,
		_destroyed = false,
		_listeners = {},
		_entering = {},
		_exiting = {},
	}, StateMachine :: any) :: any
end

--[[
	Registers an enter callback for `state`, creating the state's list if
	needed so callers do not have to pre-declare them.
]]
function StateMachine.OnEnter(self: StateMachine, state: string, callback: (previous: string?) -> ()): ()
	local list = self._entering[state]
	if not list then
		list = {}
		self._entering[state] = list
	end
	table.insert(list, callback)
end

function StateMachine.OnExit(self: StateMachine, state: string, callback: (next: string?) -> ()): ()
	local list = self._exiting[state]
	if not list then
		list = {}
		self._exiting[state] = list
	end
	table.insert(list, callback)
end

--[[
	Fires on every transition, after exit callbacks and before enter ones.
	Returns a disconnect function.
]]
function StateMachine.OnChanged(self: StateMachine, listener: Listener): () -> ()
	table.insert(self._listeners, listener)

	return function()
		local index = table.find(self._listeners, listener)
		if index then
			table.remove(self._listeners, index)
		end
	end
end

function StateMachine.GetState(self: StateMachine): string
	return self._current
end

function StateMachine.GetPreviousState(self: StateMachine): string?
	return self._previous
end

--[[
	Seconds since the current state was entered. Server-authoritative: clients
	derive their countdown from this rather than accumulating their own timer,
	which would drift on a laggy connection.
]]
function StateMachine.GetTimeInState(self: StateMachine): number
	return os.clock() - self._enteredAt
end

--[[
	Seconds remaining in a timed state, or nil for an untimed one.
]]
function StateMachine.GetTimeRemaining(self: StateMachine): number?
	local definition = self._states[self._current]
	if not definition or definition.duration == nil then
		return nil
	end

	return math.max(0, definition.duration - self:GetTimeInState())
end

function StateMachine.Is(self: StateMachine, state: string): boolean
	return self._current == state
end

--[[
	Manually advances to `nextState`.

	Returns false if the machine is destroyed or already in that state. Bumping
	the generation first invalidates any pending auto-advance timer, which is
	what makes it safe to call this from inside a state's own enter callback.
]]
function StateMachine.Transition(self: StateMachine, nextState: string): boolean
	if self._destroyed then
		return false
	end

	if not self._states[nextState] then
		warn(string.format("[StateMachine] Ignoring transition to undeclared state %q", nextState))
		return false
	end

	if self._current == nextState then
		return false
	end

	-- Invalidate any armed timer for the state we are leaving.
	self._generation += 1

	local previous = self._current
	self._previous = previous
	self._current = nextState
	self._enteredAt = os.clock()

	-- Exit callbacks for the state we are leaving.
	local exitCallbacks = self._exiting[previous]
	if exitCallbacks then
		for _, callback in table.clone(exitCallbacks) do
			local ok, err = pcall(callback, nextState)
			if not ok then
				warn(string.format("[StateMachine] Error exiting %q: %s", previous, tostring(err)))
			end
		end
	end

	-- Global listeners.
	for _, listener in table.clone(self._listeners) do
		local ok, err = pcall(listener, nextState, previous)
		if not ok then
			warn(string.format("[StateMachine] Error in listener: %s", tostring(err)))
		end
	end

	-- Enter callbacks for the state we are entering.
	local enterCallbacks = self._entering[nextState]
	if enterCallbacks then
		for _, callback in table.clone(enterCallbacks) do
			local ok, err = pcall(callback, previous)
			if not ok then
				warn(string.format("[StateMachine] Error entering %q: %s", nextState, tostring(err)))
			end
		end
	end

	self:_armTimer(nextState)

	return true
end

--[[
	Arms the auto-advance timer for a timed state, if it has one.

	The captured generation is compared when the timer fires: if anything has
	transitioned in the meantime the generation has moved on and the timer
	becomes a no-op instead of yanking the machine into a stale state.
]]
function StateMachine._armTimer(self: StateMachine, state: string): ()
	local definition = self._states[state]
	if not definition or definition.duration == nil or definition.next == nil then
		return
	end

	local generation = self._generation
	local target = definition.next

	task.delay(definition.duration, function()
		if self._destroyed or self._generation ~= generation then
			return
		end

		-- The generation check alone is not sufficient. Arm-time capture
		-- happens *after* the state's enter callbacks have run, so a callback
		-- that transitions (a round ending instantly because everyone left,
		-- say) leaves us arming a timer for a state we already left. Checking
		-- we are still in `state` closes that window.
		if self._current ~= state then
			return
		end

		self:Transition(target)
	end)
end

--[[
	Starts the machine. Callbacks registered before this point are honoured,
	but the initial state's OnEnter has not run yet -- so the machine exposes
	:Start() separately from :new() and callers wire everything up first.
]]
function StateMachine.Start(self: StateMachine): ()
	if self._destroyed then
		return
	end

	local current = self._current

	local enterCallbacks = self._entering[current]
	if enterCallbacks then
		for _, callback in table.clone(enterCallbacks) do
			local ok, err = pcall(callback, nil)
			if not ok then
				warn(string.format("[StateMachine] Error entering %q: %s", current, tostring(err)))
			end
		end
	end

	self._enteredAt = os.clock()
	self:_armTimer(current)
end

--[[
	Tears the machine down. Bumping the generation is what stops a timer that
	is already in flight from firing into a destroyed machine.
]]
function StateMachine.Destroy(self: StateMachine): ()
	self._destroyed = true
	self._generation += 1
	table.clear(self._listeners)
	table.clear(self._entering)
	table.clear(self._exiting)
end

return StateMachine
