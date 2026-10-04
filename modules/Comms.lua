--[[
    HeroHelper - Comms Module

    Manual multi-shaman coordination over the addon-message channel.

    Design (user-controlled, no automation):

      * Every HeroHelper user broadcasts HELLO when the group roster
        changes. Each client maintains a live roster of the other
        HeroHelper-using shamans in the group and their role priorities.
      * **Without an active lock, every shaman gets their own reminder.**
        No election, no suppression. AmIElectedWinner returns true.
      * The raid leader (or any user) types `/hh roster lock` when they
        want to freeze the hero order. That:
            - Snapshots the live roster into a locked roster.
            - Runs the election once (lowest priority alive, alphabetical
              tiebreak) to pick the primary fire-er.
            - Announces the resolved order to raid/party chat once.
            - From now on, only the elected-winner's HeroHelper fires;
              every other HeroHelper-using shaman suppresses its
              reminder for the rest of the run.
      * Alive-aware fallback: the election is re-evaluated against the
        locked roster every time a reminder is about to fire, so if
        the primary dies mid-fight the secondary's HeroHelper takes
        over, and if the secondary also dies the backup fires. Order
        is determined by role priority, not by the current
        HEROHELPER_TRIGGER event.
      * `/hh roster unlock` drops the lock — everyone goes back to
        firing their own reminder.

    Protocol (CHAT_MSG_ADDON, prefix "HEROHELPER"):

        HELLO:<priority>
            "I'm a HeroHelper user. My role priority is <priority>.
             My player name is implicit from the addon-message sender."
        LOCK:<id>:<count>
        SYNC:<id>:<count>:<owner>
        MEMBER:<id>:<name>:<priority>  (one per roster entry)
        LOCKED:<id>                  (commit the complete snapshot)
        UNLOCK:<id>

    A lock is applied only after all its members arrive. HELLO also requests
    the current lock; peers can relay it to a reloading lock owner via SYNC.
    Concurrent locks prefer the group leader, then assistants, then names.

    Priority numbers:
       1 = Primary    (elected when alive)
       2 = Secondary  (elected if Primary is dead)
       3 = Backup     (elected if Primary and Secondary are dead)
      99 = Auto       (no explicit role; alphabetical fallback)
]]

local ADDON_NAME, HH = ...

HH.Comms = {}
local C = HH.Comms

local ADDON_PREFIX = "HEROHELPER"

local PRIORITY_AUTO = 99

-- Live roster: HELLO-discovered HeroHelper users currently in the group.
-- Maintained continuously so `/hh roster lock` has an up-to-date snapshot.
local roster = {}                  -- name -> priority

-- Locked roster: snapshot of `roster` taken by C:Lock(). nil when no
-- lock is active. When non-nil, the election runs against this fixed
-- snapshot — late joiners are not added until the next manual lock.
local lockedRoster = nil           -- name -> priority OR nil
local lockOwner, lockID
local lockSequence = 0
local incomingLocks = {}
local outgoingLock, resendLock
local LOCK_TIMEOUT = 10
local MAX_ROSTER = 40

local function ClearLock()
    lockedRoster, lockOwner, lockID = nil, nil, nil
    incomingLocks = {}
    outgoingLock, resendLock = nil, nil
end

-- Debounce flag so a flurry of GROUP_ROSTER_UPDATE events coalesces
-- into one HELLO broadcast.
local pendingHello = false

-- ============================================================================
-- Helpers
-- ============================================================================

local function GetGroupChannel()
    if IsInRaid and IsInRaid() then return "RAID" end
    if (GetNumRaidMembers and GetNumRaidMembers() or 0) > 0 then return "RAID" end
    if IsInGroup and IsInGroup() then return "PARTY" end
    if (GetNumPartyMembers and GetNumPartyMembers() or 0) > 0 then return "PARTY" end
    return nil
end

local function BareName(name)
    if not name then return nil end
    return name:match("^([^-]+)") or name
end

local function NameLessThan(a, b)
    return (a:lower()) < (b:lower())
end

local function FindGroupUnit(name)
    if not GetGroupChannel() or not name then return nil end
    if BareName(UnitName("player")) == name then return "player" end
    for _, prefix in ipairs({ "raid", "party" }) do
        for i = 1, prefix == "raid" and 40 or 4 do
            local unit = prefix .. i
            if UnitExists(unit) and BareName(UnitName(unit)) == name then return unit end
        end
    end
end

local function Rank(name)
    local unit = FindGroupUnit(name)
    if not unit then return -1 end
    if UnitIsGroupLeader and UnitIsGroupLeader(unit) then return 2 end
    if UnitIsGroupAssistant and UnitIsGroupAssistant(unit) then return 1 end
    return 0
end

local function CanControlLock(name)
    if not FindGroupUnit(name) then return false end
    if not lockOwner or name == lockOwner then return true end
    local theirs, ours = Rank(name), Rank(lockOwner)
    return theirs > ours or (theirs == ours and NameLessThan(name, lockOwner))
end

local function CanUnlock(name)
    return FindGroupUnit(name)
        and (name == lockOwner or Rank(name) > 0 or not FindGroupUnit(lockOwner))
end

-- Returns true if the named player is currently alive in the group.
-- Scans player + raid + party slots. Returns false on miss so a player
-- who left the group is implicitly excluded from the election.
local function IsPlayerAlive(name)
    if not name then return false end

    local me = BareName(UnitName("player"))
    if name == me then
        return not UnitIsDeadOrGhost("player")
    end

    local raidN = (GetNumRaidMembers and GetNumRaidMembers() or 0)
    if (IsInRaid and IsInRaid()) or raidN > 0 then
        local n = math.max(raidN, (GetNumGroupMembers and GetNumGroupMembers()) or 0)
        for i = 1, n do
            local unit = "raid" .. i
            if UnitExists(unit) and BareName(UnitName(unit)) == name then
                return not UnitIsDeadOrGhost(unit)
            end
        end
    else
        local partyN = (GetNumSubgroupMembers and GetNumSubgroupMembers())
            or (GetNumPartyMembers and GetNumPartyMembers()) or 0
        for i = 1, partyN do
            local unit = "party" .. i
            if UnitExists(unit) and BareName(UnitName(unit)) == name then
                return not UnitIsDeadOrGhost(unit)
            end
        end
    end

    return false
end

local function SendAddonMsg(message, channel)
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        return pcall(C_ChatInfo.SendAddonMessage, ADDON_PREFIX, message, channel)
    end
    if SendAddonMessage then
        return pcall(SendAddonMessage, ADDON_PREFIX, message, channel)
    end
    return false
end

-- ============================================================================
-- Roster maintenance
-- ============================================================================

-- Removes live-roster entries for players no longer in the group. The
-- locked roster is intentionally NOT pruned — the order stands until
-- /hh roster unlock.
local function PruneLiveRoster()
    if not GetGroupChannel() then
        ClearLock()
    end
    local me = BareName(UnitName("player"))
    local inGroup = {}
    if me then inGroup[me] = true end

    local raidN = (GetNumRaidMembers and GetNumRaidMembers() or 0)
    if (IsInRaid and IsInRaid()) or raidN > 0 then
        local n = math.max(raidN, (GetNumGroupMembers and GetNumGroupMembers()) or 0)
        for i = 1, n do
            local unit = "raid" .. i
            if UnitExists(unit) then
                local n2 = BareName(UnitName(unit))
                if n2 then inGroup[n2] = true end
            end
        end
    else
        local partyN = (GetNumSubgroupMembers and GetNumSubgroupMembers())
            or (GetNumPartyMembers and GetNumPartyMembers()) or 0
        for i = 1, partyN do
            local unit = "party" .. i
            if UnitExists(unit) then
                local n2 = BareName(UnitName(unit))
                if n2 then inGroup[n2] = true end
            end
        end
    end

    for name in pairs(roster) do
        if not inGroup[name] then roster[name] = nil end
    end
end

-- Picks the elected winner from the given roster, filtered by alive
-- status. Lowest priority wins; ties broken alphabetically. Returns
-- the bidder table { name, priority } or nil if everyone is dead.
local function ElectFrom(srcRoster)
    local chosen = nil
    for name, priority in pairs(srcRoster) do
        if IsPlayerAlive(name) then
            if not chosen
               or priority < chosen.priority
               or (priority == chosen.priority and NameLessThan(name, chosen.name)) then
                chosen = { name = name, priority = priority }
            end
        end
    end
    return chosen
end

-- Returns a roster sorted by priority (then alphabetical) — the order
-- in which ElectFrom walks. Used by the chat announcement and the
-- /hh roster diagnostic.
local function SortedRoster(srcRoster)
    local sorted = {}
    for name, priority in pairs(srcRoster) do
        sorted[#sorted + 1] = { name = name, priority = priority }
    end
    table.sort(sorted, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        return NameLessThan(a.name, b.name)
    end)
    return sorted
end

-- ============================================================================
-- Public API
-- ============================================================================

-- Returns true if THIS player should fire reminders.
--   * No lock in effect → everyone fires (return true).
--   * Lock in effect → only the currently-elected (alive) winner fires.
--     Election re-evaluates on every call, so alive-aware fallback is
--     automatic (primary dies → secondary fires → backup fires).
function C:AmIElectedWinner()
    if not lockedRoster then
        return true
    end

    local me = BareName(UnitName("player"))
    if not me then return true end

    local winner = ElectFrom(lockedRoster)
    if not winner then
        -- Everyone in the locked roster is dead. Fall through and fire
        -- as a last resort — IsReady's own checks will block it if the
        -- player is dead too.
        return true
    end
    return winner.name == me
end

function C:GetActiveRosterSorted()
    return SortedRoster(lockedRoster or roster)
end

function C:GetElectedWinner()
    if not lockedRoster then return nil end
    local w = ElectFrom(lockedRoster)
    return w and w.name or nil
end

function C:IsLocked()
    return lockedRoster ~= nil
end

function C:IsLockedMember(name)
    name = BareName(name)
    return lockedRoster and name and lockedRoster[name] ~= nil and FindGroupUnit(name) ~= nil
end

local function SendLock()
    if not lockedRoster then return end
    local channel, id = GetGroupChannel(), lockID
    if not channel then return end
    if outgoingLock then
        resendLock = true -- a client may have joined after the first chunk
        return
    end
    local transfer = { id = id, owner = lockOwner }
    outgoingLock = transfer
    local function StillCurrent()
        return outgoingLock == transfer and lockID == id and lockOwner == transfer.owner
            and GetGroupChannel() == channel
    end
    local ordered = SortedRoster(lockedRoster)
    if lockOwner == BareName(UnitName("player")) then
        SendAddonMsg("LOCK:" .. id .. ":" .. #ordered, channel)
    else
        SendAddonMsg("SYNC:" .. id .. ":" .. #ordered .. ":" .. lockOwner, channel)
    end
    for i, entry in ipairs(ordered) do
        local message = "MEMBER:" .. id .. ":" .. entry.name .. ":" .. entry.priority
        C_Timer.After(i * 0.1, function()
            if StillCurrent() then SendAddonMsg(message, channel) end
        end)
    end
    C_Timer.After((#ordered + 1) * 0.1, function()
        if StillCurrent() then SendAddonMsg("LOCKED:" .. id, channel) end
        if outgoingLock == transfer then
            outgoingLock = nil
            if resendLock then
                resendLock = nil
                SendLock()
            end
        end
    end)
end

-- ============================================================================
-- Chat announcement
-- ============================================================================

-- Posts the resolved Heroism order to raid/party chat using the locked
-- roster. Called exactly once by the player who ran /hh roster lock.
local function PostOrderToChat()
    local sorted = SortedRoster(lockedRoster or {})
    if #sorted == 0 then return end

    local channel = GetGroupChannel()
    if not channel then return end

    local spell = (HH.State and HH.State.spellName) or "Heroism"
    local chosen = sorted[1].name

    local msg
    if #sorted == 1 then
        msg = ("HeroHelper: %s will %s."):format(chosen, spell)
    else
        local names = {}
        for _, s in ipairs(sorted) do names[#names + 1] = s.name end
        msg = ("HeroHelper: %s will %s. Order: %s"):format(
            chosen, spell, table.concat(names, " > "))
    end

    if SendChatMessage then
        pcall(SendChatMessage, msg, channel)
    end
end

-- ============================================================================
-- Lock / unlock  (user-driven via /hh roster lock | unlock)
-- ============================================================================

-- Snapshots the current live roster, runs the election, and announces
-- the resolved order to chat. Returns (ok, reason) — false + reason
-- string on failure so the slash command can report to the player.
function C:Lock()
    if lockedRoster then
        return false, "already locked - run `/hh roster unlock` first"
    end
    if not GetGroupChannel() then
        return false, "not in a group"
    end

    PruneLiveRoster()

    local count = 0
    local snapshot = {}
    for name, p in pairs(roster) do
        snapshot[name] = p
        count = count + 1
    end
    if count == 0 then
        return false, "no HeroHelper users discovered yet - wait a moment and retry"
    end

    lockedRoster = snapshot
    lockOwner = BareName(UnitName("player"))
    lockSequence = lockSequence + 1
    lockID = math.floor(GetTime() * 1000) .. "-" .. lockSequence
    SendLock()
    HH:Debug(("Coordinate: election LOCKED with %d HeroHelper user(s)"):format(count))

    -- Only the user who ran /hh roster lock posts the order. The locking
    -- player's HELLO priority is irrelevant for announcement duty.
    PostOrderToChat()
    return true
end

function C:Unlock()
    if not lockedRoster then
        return false, "not currently locked"
    end
    local me = BareName(UnitName("player"))
    if not CanUnlock(me) then return false, "ask the player who locked the order or a group leader/assistant to unlock it" end
    SendAddonMsg("UNLOCK:" .. lockID, GetGroupChannel())
    ClearLock()
    HH:Debug("Coordinate: election UNLOCKED")
    return true
end

-- ============================================================================
-- HELLO broadcast
-- ============================================================================

local function BroadcastHello()
    if not HH.State.isShaman then return end

    local channel = GetGroupChannel()
    if not channel then return end

    local me = BareName(UnitName("player"))
    if not me then return end

    local p = (HH.db and HH.db.settings and HH.db.settings.shamanPriority) or PRIORITY_AUTO

    -- Self always lives in the live roster (the message we send won't
    -- loop back to us via CHAT_MSG_ADDON, so we add ourselves directly).
    roster[me] = p

    SendAddonMsg("HELLO:" .. tostring(p), channel)
    HH:Debug(("Coordinate: HELLO broadcast on %s (priority=%d)"):format(channel, p))
end

local function ScheduleHello()
    if pendingHello then return end
    pendingHello = true
    C_Timer.After(0.5, function()
        pendingHello = false
        BroadcastHello()
    end)
end

local function HandleHello(senderName, priority)
    local me = BareName(UnitName("player"))
    if not me or senderName == me then return end

    local prev = roster[senderName]
    roster[senderName] = priority
    if prev ~= priority then
        HH:Debug(("Coordinate: HELLO from %s (priority=%d)"):format(senderName, priority))
    end
    if lockOwner == me then
        SendLock()
    elseif lockedRoster and (senderName == lockOwner or not FindGroupUnit(lockOwner)) then
        -- One peer answers if the owner reloads or leaves. Having every
        -- shaman relay a full roster would flood the addon channel.
        for _, entry in ipairs(SortedRoster(roster)) do
            if entry.name ~= lockOwner and entry.name ~= senderName and FindGroupUnit(entry.name) then
                if entry.name == me then SendLock() end
                break
            end
        end
    end
end

-- ============================================================================
-- Lifecycle
-- ============================================================================

function C:Initialize()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        pcall(C_ChatInfo.RegisterAddonMessagePrefix, ADDON_PREFIX)
    elseif RegisterAddonMessagePrefix then
        pcall(RegisterAddonMessagePrefix, ADDON_PREFIX)
    end

    HH.Events:On("CHAT_MSG_ADDON", function(prefix, message, channel, sender)
        if prefix ~= ADDON_PREFIX or not message then return end

        local senderName = BareName(sender)
        if not senderName or senderName == BareName(UnitName("player")) then return end
        if channel ~= GetGroupChannel() or not FindGroupUnit(senderName) then return end

        local kind, payload = message:match("^(%a+):(.*)$")
        if kind == "HELLO" then
            local priority = tonumber(payload) or PRIORITY_AUTO
            if priority < 1 or priority > PRIORITY_AUTO or priority ~= math.floor(priority) then return end
            HandleHello(senderName, priority)
        elseif kind == "LOCK" or kind == "SYNC" then
            local id, count = payload:match("^([%d%-]+):(%d+)$")
            local owner = senderName
            if kind == "SYNC" then
                if lockedRoster then return end -- relays cannot replace an established lock
                id, count, owner = payload:match("^([%d%-]+):(%d+):([^:%s]+)$")
            end
            count = tonumber(count)
            if id and #id <= 32 and count and count >= 1 and count <= MAX_ROSTER
                and owner and #owner <= 64 and (kind == "SYNC" or CanControlLock(senderName)) then
                incomingLocks[senderName] = {
                    id = id, owner = owner, relay = kind == "SYNC",
                    count = count, members = {}, at = GetTime(),
                }
            end
        elseif kind == "MEMBER" then
            local id, name, priority = payload:match("^([%d%-]+):([^:]+):(%d+)$")
            priority = tonumber(priority)
            local pending = incomingLocks[senderName]
            if pending and pending.id == id and GetTime() - pending.at < LOCK_TIMEOUT then
                -- A frozen roster can include someone who has since left. The
                -- election checks current membership, so keep their place here.
                if not name or #name > 64 or name:find("%s")
                    or not priority or priority < 1 or priority > PRIORITY_AUTO
                    or pending.members[name] then
                    pending.invalid = true
                else
                    pending.members[name] = priority
                end
            end
        elseif kind == "LOCKED" then
            local pending = incomingLocks[senderName]
            incomingLocks[senderName] = nil
            local allowed = pending and ((pending.relay and not lockedRoster)
                or (not pending.relay and CanControlLock(senderName)))
            if allowed and pending.id == payload and not pending.invalid
                and GetTime() - pending.at < LOCK_TIMEOUT then
                local count = 0
                for _ in pairs(pending.members) do count = count + 1 end
                if count == pending.count then
                    lockedRoster, lockOwner, lockID = pending.members, pending.owner, pending.id
                    for name, priority in pairs(lockedRoster) do
                        if not roster[name] and FindGroupUnit(name) then roster[name] = priority end
                    end
                end
            end
        elseif kind == "UNLOCK" then
            -- Also discard an incomplete transfer if the owner unlocks before
            -- its final chunk reaches this client.
            for source, pending in pairs(incomingLocks) do
                if pending.id == payload and (pending.owner == senderName or Rank(senderName) > 0) then
                    incomingLocks[source] = nil
                end
            end
            if lockID == payload and CanUnlock(senderName) then ClearLock() end
        end
    end)

    HH.Events:On("PLAYER_ENTERING_WORLD", function()
        PruneLiveRoster()
        ScheduleHello()
    end)

    HH.Events:On("GROUP_ROSTER_UPDATE", function()
        PruneLiveRoster()
        ScheduleHello()
    end)
end
