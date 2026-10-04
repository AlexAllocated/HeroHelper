return function(H)
    -- Separate namespaces share a delayed message transport. Timers retain their
    -- originating client, and a reload discards that client's old callbacks.
    local function network(names)
        local net = {
            clock = H.clock(),
            clients = {},
            members = names or { "Alice", "Bob" },
            dead = {},
            messages = {},
        }
        local current
        function net:as(name, callback)
            local previous = current
            current = name
            local result, reason = callback(self.clients[name])
            current = previous
            return result, reason
        end
        local function unitName(unit)
            if unit == "player" then
                return current
            end
            local raid = tonumber(unit:match("^raid(%d+)$"))
            if raid then
                return net.members[raid]
            end
            local party = tonumber(unit:match("^party(%d+)$"))
            if party then
                local index = 0
                for _, name in ipairs(net.members) do
                    if name ~= current then
                        index = index + 1
                        if index == party then
                            return name
                        end
                    end
                end
            end
        end
        UnitName = unitName
        UnitExists = function(unit)
            return unitName(unit) ~= nil
        end
        UnitIsDeadOrGhost = function(unit)
            return net.dead[unitName(unit)] or false
        end
        IsInGroup = function()
            return #net.members > 1
        end
        IsInRaid = function()
            return #net.members > 5
        end
        GetNumSubgroupMembers = function()
            return math.max(0, #net.members - 1)
        end
        GetNumGroupMembers = function()
            return #net.members
        end
        UnitIsGroupLeader = function(unit)
            return unitName(unit) == net.members[1]
        end
        UnitIsGroupAssistant = function()
            return false
        end
        local deliverLater = C_Timer.After
        for key, original in pairs(C_Timer) do
            C_Timer[key] = function(delay, callback)
                local owner, client = current, net.clients[current]
                local timer
                timer = original(delay, function()
                    if net.clients[owner] ~= client then
                        timer:Cancel()
                        return
                    end
                    net:as(owner, callback)
                end)
                return timer
            end
        end
        function net:send(sender, message, channel)
            channel = channel or (#self.members > 5 and "RAID" or "PARTY")
            assert(#message <= 255, "addon messages must fit the transport limit")
            self.messages[#self.messages + 1] = { sender = sender, message = message }
            for _, name in ipairs(self.members) do
                local recipient = name
                if recipient ~= sender and (not self.drop or not self.drop(sender, recipient, message)) then
                    deliverLater(0.01, function()
                        if self.clients[recipient] then
                            self:as(recipient, function(client)
                                client.Events:Fire("CHAT_MSG_ADDON", "HEROHELPER", message, channel, sender)
                            end)
                        end
                    end)
                end
            end
        end
        C_ChatInfo = {
            RegisterAddonMessagePrefix = H.noop,
            SendAddonMessage = function(_, message, channel)
                net:send(current, message, channel)
            end,
        }
        SendChatMessage = H.noop
        function net:add(name, priority)
            local client = {
                Events = H.bus(),
                State = { isShaman = true },
                db = { settings = { shamanPriority = priority } },
                Debug = H.noop,
                IsActive = function()
                    return true
                end,
                IsSpellOnCooldown = function()
                    return false
                end,
                HasExhaustionDebuff = function()
                    return false
                end,
                Database = {
                    GetTriggerConfig = function()
                        return { type = "hp", hp = 30 }
                    end,
                },
                Detection = {
                    GetCurrentBossHPPct = function()
                        return 20
                    end,
                },
                count = 0,
            }
            self.clients[name] = client
            self:as(name, function()
                assert(loadfile("modules/Comms.lua"))("HeroHelper", client)
                assert(loadfile("modules/Triggers.lua"))("HeroHelper", client)
                client.Comms:Initialize()
                client.Triggers:Initialize()
                client.Events:On("HEROHELPER_TRIGGER", function()
                    client.count = client.count + 1
                end)
                client.Events:Fire("PLAYER_ENTERING_WORLD")
            end)
            return client
        end
        function net:lock(name)
            assert(self:as(name or "Alice", function(client)
                return client.Comms:Lock()
            end))
        end
        function net:unlock(name)
            assert(self:as(name or "Alice", function(client)
                return client.Comms:Unlock()
            end))
        end
        function net:winner(name)
            return self:as(name, function(client)
                return client.Comms:GetElectedWinner()
            end)
        end
        function net:pull()
            for name in pairs(self.clients) do
                self:as(name, function(client)
                    client.State.currentBossID, client.State.inCombat = "boss", true
                    client.Events:Fire("BOSS_PULL", "boss")
                end)
            end
        end
        for i, name in ipairs(net.members) do
            net:add(name, i)
        end
        net.clock:advance(1)
        return net
    end

    H.test("locks-and-failover", function()
        local net = network()
        net:lock()
        net.clock:advance(2)
        assert(net.clients.Bob.Comms:IsLocked(), "one command must lock the other client")
        assert(net:winner("Alice") == "Alice" and net:winner("Bob") == "Alice")
        net:pull()
        net.clock:advance(2.5)
        assert(net.clients.Alice.count == 1 and net.clients.Bob.count == 0)
        net.dead.Alice = true
        net.clock:advance(3)
        assert(net.clients.Bob.count == 1, "the backup must fire after the primary dies before casting")
    end)
    H.test("cast-stops-backup", function()
        local net = network()
        net:lock()
        net.clock:advance(2)
        net:pull()
        net.clock:advance(2.5)
        for name in pairs(net.clients) do
            net:as(name, function(client)
                client.Events:Fire(
                    "CLEU",
                    2.5,
                    "SPELL_CAST_SUCCESS",
                    nil,
                    nil,
                    "Alice",
                    nil,
                    nil,
                    nil,
                    nil,
                    nil,
                    nil,
                    32182
                )
            end)
        end
        net.dead.Alice = true
        net.clock:advance(3)
        assert(net.clients.Bob.count == 0, "a cast must stop the backup even if the primary later dies")
    end)
    H.test("unlock-and-leave", function()
        local net = network()
        net:lock()
        net.clock:advance(2)
        assert(not net:as("Bob", function(client)
            return client.Comms:Unlock()
        end), "a non-owner member cannot unlock")
        net:unlock()
        net.clock:advance(2.1)
        assert(not net.clients.Bob.Comms:IsLocked(), "unlock must reach the other client")
        net:lock()
        net.clock:advance(3)
        net.members = {}
        for name in pairs(net.clients) do
            net:as(name, function(client)
                client.Events:Fire("GROUP_ROSTER_UPDATE")
                assert(not client.Comms:IsLocked(), "leaving must clear the lock")
            end)
        end
    end)
    H.test("reload-sync", function()
        local net = network()
        net:lock()
        net.clock:advance(2)
        net:add("Bob", 2)
        net.clock:advance(3)
        assert(net.clients.Bob.Comms:IsLocked(), "a reloaded peer must recover the lock")
        net:add("Alice", 1)
        net.clock:advance(4)
        assert(net.clients.Alice.Comms:IsLocked(), "the reloaded owner must recover the lock from a peer")
        assert(net:winner("Alice") == "Alice" and net:winner("Bob") == "Alice")
        net:unlock()
        net.clock:advance(4.1)
        assert(not net.clients.Bob.Comms:IsLocked(), "recovery must preserve the original owner")
    end)
    H.test("join-during-transfer", function()
        local net = network()
        net:lock()
        net.clock:advance(1.05)
        net:add("Bob", 2) -- The new instance missed LOCK, but will see its remaining chunks.
        net:as("Bob", function(client)
            client.Events:Fire("CHAT_MSG_ADDON", "HEROHELPER", "HELLO:1", "PARTY", "Alice")
        end)
        net:send("Bob", "HELLO:2")
        net.clock:advance(2)
        assert(net.clients.Bob.Comms:IsLocked(), "retry the snapshot when HELLO arrives during a transfer")
    end)
    H.test("incomplete-and-invalid-snapshots", function()
        local net = network()
        net.drop = function(_, recipient, message)
            return recipient == "Bob" and message:match("^MEMBER:")
        end
        net:lock()
        net.clock:advance(2)
        assert(not net.clients.Bob.Comms:IsLocked(), "a partial snapshot must not be applied")
        net.drop = nil
        net:unlock()
        net.clock:advance(2.1)
        net:send("Alice", "LOCK:5:2")
        net:send("Alice", "MEMBER:5:Alice:1")
        net:send("Alice", "MEMBER:5:Alice:1")
        net:send("Alice", "LOCKED:5")
        net.clock:advance(2.2)
        assert(not net.clients.Bob.Comms:IsLocked(), "duplicate members must not complete a snapshot")
        net:send("Alice", "LOCK:6:1")
        net:send("Alice", "MEMBER:6:Alice:1")
        net.clock:advance(13)
        net:send("Alice", "LOCKED:6")
        net.clock:advance(13.1)
        assert(not net.clients.Bob.Comms:IsLocked(), "expired snapshots must be ignored")
        for _, sender in ipairs({ "Outsider", "Alice" }) do
            net:send(sender, "LOCK:7:1", "WHISPER")
            net:send(sender, "MEMBER:7:Alice:1", "WHISPER")
            net:send(sender, "LOCKED:7", "WHISPER")
        end
        net.clock:advance(13.2)
        assert(not net.clients.Bob.Comms:IsLocked(), "only current group messages may change the lock")
    end)
    H.test("unlock-during-transfer", function()
        local net = network()
        net:lock()
        net.clock:advance(1.05)
        net:unlock()
        net.clock:advance(2)
        assert(not net.clients.Alice.Comms:IsLocked() and not net.clients.Bob.Comms:IsLocked())
    end)
    H.test("simultaneous-locks", function()
        local net = network()
        net:lock("Bob")
        net:lock("Alice")
        net.clock:advance(2)
        assert(not net:as("Bob", function(client)
            return client.Comms:Unlock()
        end), "the leader wins simultaneous locks")
        net:unlock("Alice")
        net.clock:advance(2.1)
        assert(not net.clients.Bob.Comms:IsLocked(), "both clients must agree on the lock owner")
    end)
    H.test("departed-member-sync", function()
        local net = network()
        net:lock()
        net.clock:advance(2)
        net.members, net.clients.Bob = { "Alice", "Cara" }, nil
        net:add("Cara", 3)
        net.clock:advance(3)
        assert(net.clients.Cara.Comms:IsLocked(), "a departed snapshot member must not break synchronization")
        assert(net:winner("Cara") == "Alice")
        net.members, net.clients.Alice = { "Cara", "Dana" }, nil
        net:add("Dana", 4)
        net.clock:advance(4)
        -- Cara joined after the frozen snapshot, but still holds its state.
        assert(net.clients.Dana.Comms:IsLocked(), "a remaining peer must relay after the owner leaves")
    end)
    H.test("full-raid-snapshot", function()
        local names = {}
        for i = 1, 40 do
            names[i] = "Shaman" .. i
        end
        local net = network(names)
        net:lock("Shaman1")
        net.clock:advance(6)
        for _, name in ipairs(names) do
            assert(net.clients[name].Comms:IsLocked(), "all raid clients must receive the complete roster")
            assert(net:winner(name) == "Shaman1")
        end
    end)
end
