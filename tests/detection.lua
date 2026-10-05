return function(H)
    local function fixture(dungeon)
        local clock = H.clock()
        local h = {
            Events = H.bus(), State = { isShaman = true, inCombat = false },
            Debug = H.noop, IsActive = function() return true end,
            HasExhaustionDebuff = function() return false end,
            IsSpellOnCooldown = function() return false end,
            targetBoss = true, engaged = false, reminders = 0,
            Database = {
                Get = function() return { name = "Boss", isDungeon = dungeon } end,
                LookupByNpcId = function(_, id) return id == 123 and "boss" or nil end,
                LookupByName = function() end,
                GetTriggerConfig = function() return { type = "pull" } end,
            },
        }
        UnitExists = function(unit) return unit == "target" end
        UnitIsDeadOrGhost = function() return false end
        UnitCanAttack = function() return true end
        UnitName = function() return h.targetBoss and "Boss" or "Trash" end
        UnitGUID = function()
            return h.targetBoss and "Creature-0-0-0-0-123-0" or "Creature-0-0-0-0-456-0"
        end
        UnitAffectingCombat = function() return h.engaged end
        strsplit = function(_, value)
            return value:match("^(%w+)%-(%d+)%-(%d+)%-(%d+)%-(%d+)%-(%d+)%-(%d+)$")
        end
        assert(loadfile("modules/Detection.lua"))("HeroHelper", h)
        assert(loadfile("modules/Triggers.lua"))("HeroHelper", h)
        h.Detection:Initialize()
        h.Triggers:Initialize()
        h.Events:On("HEROHELPER_TRIGGER", function() h.reminders = h.reminders + 1 end)
        return h, clock
    end
    for _, dungeon in ipairs({ false, true }) do
        H.test(dungeon and "idle-dungeon-boss" or "idle-raid-boss", function()
            local h, clock = fixture(dungeon)
            h.Events:Fire("TARGET_CHANGED")
            assert(not h.State.currentBossID, "an idle boss must not lock out later detection")
            h.targetBoss, h.State.inCombat = false, true
            h.Events:Fire("COMBAT_START")
            clock:advance(1)
            assert(h.reminders == 0, "trash must not trigger the previously targeted boss")
            h.targetBoss = true
            h.Events:Fire("TARGET_CHANGED")
            assert(h.reminders == 0, "targeting an idle boss during trash combat must not trigger it")
            h.engaged = true
            clock:advance(3)
            assert(h.State.currentBossID == "boss" and h.reminders == 1, "rescan must detect the real pull")
        end)
    end
    H.test("boss-mod-engage-without-target", function()
        local h = fixture(false)
        h.targetBoss, h.State.inCombat = false, true
        h.Detection:SetCurrentBoss("boss", "Boss")
        assert(h.reminders == 1, "authoritative boss-mod engagement must still work without a target")
    end)
end
