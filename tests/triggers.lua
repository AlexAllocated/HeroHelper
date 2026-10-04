return function(H)
    local function fixture(config)
        local clock = H.clock()
        local h = {
            Events = H.bus(),
            State = { isShaman = true, inCombat = true, currentBossID = "boss" },
            IsActive = function()
                return true
            end,
            HasExhaustionDebuff = function(self)
                return self.exhausted
            end,
            IsSpellOnCooldown = function(self)
                return self.cooldown
            end,
            Debug = H.noop,
            Database = {
                GetTriggerConfig = function()
                    return config
                end,
            },
            Detection = {
                GetCurrentBossHPPct = function()
                    return 20
                end,
            },
            Comms = {
                AmIElectedWinner = function()
                    return true
                end,
            },
            count = 0,
        }
        UnitIsDeadOrGhost = function()
            return h.dead
        end
        h.Events:On("HEROHELPER_TRIGGER", function()
            h.count = h.count + 1
            h.firedAt = clock.now
        end)
        assert(loadfile("modules/Triggers.lua"))("HeroHelper", h)
        h.Triggers:Initialize()
        return h, clock
    end
    H.test("cooldown-retry", function()
        local h, clock = fixture({ type = "hp", hp = 30 })
        h.cooldown = true
        h.Events:Fire("BOSS_PULL", "boss")
        clock:advance(1)
        assert(h.count == 0)
        h.cooldown = false
        clock:advance(2)
        assert(h.count == 1, "retry an HP condition when cooldown ends")
        assert(clock:active() == 0, "stop retrying once the reminder fires")
    end)
    H.test("backup-retry", function()
        local h, clock = fixture({ type = "hp", hp = 30 })
        local elected = false
        h.Comms.AmIElectedWinner = function()
            return elected
        end
        h.Events:Fire("BOSS_PULL", "boss")
        clock:advance(1)
        assert(not h.State.triggered, "a suppressed backup has not used its reminder")
        elected = true
        clock:advance(2)
        assert(h.count == 1, "the backup must retry when elected")
    end)
    H.test("combat-timer", function()
        local h, clock = fixture({ type = "time", seconds = 30 })
        h.State.inCombat = false
        h.Events:Fire("BOSS_PULL", "boss")
        assert(clock:active() == 0, "targeting before combat must not arm timers")
        clock:advance(20)
        h.State.inCombat = true
        h.Events:Fire("COMBAT_START")
        h.Events:Fire("COMBAT_START")
        assert(clock:active() == 1, "arm only one timer for the pull")
        clock:advance(30)
        assert(h.count == 0)
        clock:advance(50)
        assert(h.count == 1 and h.firedAt == 50, "start the timer at combat entry")
    end)
    H.test("completed-cast", function()
        local h, clock = fixture({ type = "pull" })
        local elected = false
        h.Comms.AmIElectedWinner = function()
            return elected
        end
        h.Comms.IsLockedMember = function(_, name)
            return name == "Primary"
        end
        h.Events:Fire("BOSS_PULL", "boss")
        clock:advance(1)
        h.Events:Fire(
            "CLEU",
            clock.now,
            "SPELL_CAST_SUCCESS",
            nil,
            nil,
            "Primary",
            nil,
            nil,
            nil,
            nil,
            nil,
            nil,
            32182
        )
        elected = true
        clock:advance(2)
        assert(h.count == 0 and clock:active() == 0, "a completed group cast must stop failover")
        h.State.inCombat = false
        h.Events:Fire("COMBAT_END")
        h.State.inCombat = true
        h.Events:Fire("BOSS_PULL", "boss")
        assert(h.count == 1, "a new pull must reset the used-cast state")
    end)
    H.test("combat-end", function()
        local h, clock = fixture({
            type = "any",
            conditions = { { type = "hp", hp = 30 }, { type = "time", seconds = 10 } },
        })
        h.cooldown = true
        h.Events:Fire("BOSS_PULL", "boss")
        clock:advance(1)
        h.State.inCombat, h.State.currentBossID = false, nil
        h.Events:Fire("COMBAT_END")
        h.cooldown = false
        clock:advance(20)
        assert(h.count == 0 and clock:active() == 0, "combat end must cancel pending conditions")
    end)
    H.test("dead-player-and-compound", function()
        local h, clock =
            fixture({ type = "any", conditions = { { type = "pull" }, { type = "time", seconds = 5 } } })
        h.dead = true
        h.Events:Fire("BOSS_PULL", "boss")
        clock:advance(1)
        assert(h.count == 0, "do not remind a dead shaman")
        h.dead = false
        clock:advance(2)
        assert(h.count == 1 and clock:active() == 0, "a successful condition must cancel the others")
    end)
end
