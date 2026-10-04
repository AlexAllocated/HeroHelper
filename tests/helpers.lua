local H = { passed = 0 }
function H.noop() end
function H.bus()
    local bus = { listeners = {} }
    function bus:On(name, callback)
        self.listeners[name] = self.listeners[name] or {}
        table.insert(self.listeners[name], callback)
    end
    function bus:Fire(name, ...)
        for _, callback in ipairs(self.listeners[name] or {}) do
            callback(...)
        end
    end
    return bus
end
function H.clock()
    local clock = { now = 0, timers = {} }
    GetTime = function()
        return clock.now
    end
    local function schedule(delay, callback, interval)
        local timer = { at = clock.now + delay, callback = callback, interval = interval }
        function timer:Cancel()
            self.cancelled = true
        end
        table.insert(clock.timers, timer)
        return timer
    end
    C_Timer = {
        NewTimer = function(delay, callback)
            return schedule(delay, callback)
        end,
        NewTicker = function(delay, callback)
            return schedule(delay, callback, delay)
        end,
    }
    C_Timer.After = C_Timer.NewTimer
    function clock:advance(to)
        assert(to >= self.now)
        while true do
            local nextTimer
            for _, timer in ipairs(self.timers) do
                if not timer.cancelled and timer.at <= to and (not nextTimer or timer.at < nextTimer.at) then
                    nextTimer = timer
                end
            end
            if not nextTimer then
                break
            end
            self.now = nextTimer.at
            if nextTimer.interval then
                nextTimer.at = self.now + nextTimer.interval
            else
                nextTimer.cancelled = true
            end
            nextTimer.callback()
        end
        self.now = to
    end
    function clock:active()
        local count = 0
        for _, timer in ipairs(self.timers) do
            if not timer.cancelled then
                count = count + 1
            end
        end
        return count
    end
    return clock
end
function H.test(name, callback)
    if arg[2] and arg[2] ~= name then
        return
    end
    callback()
    H.passed = H.passed + 1
    print("PASS " .. name)
end
return H
