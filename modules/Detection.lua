--[[
    HeroHelper - Detection Module

    Identifies the boss the player is currently fighting. TBC Classic has no
    ENCOUNTER_START / ENCOUNTER_END events, so we combine three sources:

    1. BigWigs (via the "BigWigs_OnBossEngage" / "BigWigs_OnBossDisable"
       messages broadcast through its callback handler)
    2. Deadly Boss Mods (via DBM's "DBM_Pull" callback on its event dispatcher)
    3. Fallback unit scanning: every time target/mouseover/focus/raid targets
       change, scan them for an NPC ID (from GUID) or name that matches the
       Database.

    The primary detection path uses NPC creature IDs extracted from UnitGUID.
    These are locale-independent so the addon works on any client language.
    Name-based matching is kept as a fallback for edge cases.

    Whichever source fires first sets HH.State.currentBossID and fires the
    "BOSS_PULL" event on the internal event bus.
]]

local ADDON_NAME, HH = ...

HH.Detection = {}
local Detection = HH.Detection

local CLASSIFICATION_BOSS = "worldboss"
local CLASSIFICATION_ELITE_PRIORITY = { "worldboss", "rareelite", "elite" }

-- Set of units we scan when no boss mod has already identified a boss.
-- "boss1..4" are included because BigWigs / DBM may populate them in TBC
-- Anniversary via their own shims even though Blizzard does not.
local SCAN_UNITS = {
    "target", "focus", "mouseover",
    "boss1", "boss2", "boss3", "boss4", "boss5",
}

-- ============================================================================
-- Shared unit-list builder
-- ============================================================================

-- Returns a fresh list of every unit token worth scanning: the static core
-- set (target, focus, mouseover, boss1..5) plus dynamic raid/party targets.
-- Supports both the modern (GetNumGroupMembers/IsInRaid) and legacy
-- (GetNumRaidMembers/GetNumPartyMembers) APIs so the code is robust across
-- TBC Anniversary client revisions.
--
-- Used by ScanUnits(), GetCurrentBossHPPct(), and Triggers:FindUnitByGUID().
function Detection:GetScanUnits()
    local units = {}
    for _, u in ipairs(SCAN_UNITS) do units[#units + 1] = u end

    local raidN = (GetNumRaidMembers and GetNumRaidMembers()) or 0
    if raidN > 0 or (IsInRaid and IsInRaid()) then
        local n = math.max(raidN, (GetNumGroupMembers and GetNumGroupMembers()) or 0)
        for i = 1, n do units[#units + 1] = "raid" .. i .. "target" end
        return units
    end

    local partyN = (GetNumPartyMembers and GetNumPartyMembers())
              or ((GetNumGroupMembers and GetNumGroupMembers()) or 0)
    for i = 1, partyN do units[#units + 1] = "party" .. i .. "target" end
    return units
end

-- ============================================================================
-- GUID → NPC ID helper
-- ============================================================================

-- TBC Classic GUIDs follow the format:
--     Creature-0-XXXX-XXXX-XXXX-NPCID-XXXXXXXX
-- Field 6 (1-indexed, dash-separated) is the NPC creature ID.
-- Returns a number, or nil if the GUID is not a Creature type.
local function NpcIdFromGUID(guid)
    if not guid then return nil end
    -- Quick prefix check before the heavier split.
    if guid:sub(1, 8) ~= "Creature" then return nil end
    local _, _, _, _, _, npcStr = strsplit("-", guid)
    return tonumber(npcStr)
end

-- Returns the numeric instance ID for the player's current instance.
-- Locale-independent; used for name-based disambiguation (Kael'thas).
local function GetCurrentInstanceId()
    if GetInstanceInfo then
        local _, _, _, _, _, _, _, instanceId = GetInstanceInfo()
        return instanceId
    end
    return nil
end

-- ============================================================================
-- Core scan
-- ============================================================================

function Detection:ScanUnits()
    if HH.State.currentBossID then return end -- already locked in

    local units = self:GetScanUnits()

    -- Captured once per scan for name-based fallback disambiguation.
    local instanceId = GetCurrentInstanceId()

    for _, unit in ipairs(units) do
        if UnitExists(unit) and not UnitIsDeadOrGhost(unit) and UnitCanAttack("player", unit) then
            -- Primary path: locale-independent NPC ID from GUID.
            local npcId = NpcIdFromGUID(UnitGUID(unit))
            local id = npcId and HH.Database:LookupByNpcId(npcId)

            -- Fallback: name-based lookup (works on English clients).
            if not id then
                local name = UnitName(unit)
                id = name and HH.Database:LookupByName(name, instanceId)
            end

            if id then
                -- An idle raid or dungeon boss may be targeted during a trash
                -- pull. Only lock in once the boss itself is engaged.
                if not UnitAffectingCombat(unit) then
                    -- Skip: boss is in the database but not yet engaged.
                else
                    local displayName = UnitName(unit)
                    self:SetCurrentBoss(id, displayName, unit)
                    return
                end
            end
        end
    end
end

function Detection:SetCurrentBoss(bossID, displayName, unit)
    if HH.State.currentBossID == bossID then return end

    HH.State.currentBossID   = bossID
    HH.State.currentBossName = displayName or HH.Database:Get(bossID).name
    HH.State.pullTime        = HH.State.pullTime or GetTime()

    HH:Debug("BOSS_PULL: " .. HH.State.currentBossName .. " (" .. bossID .. ")")
    HH.Events:Fire("BOSS_PULL", bossID, unit)
end

-- ============================================================================
-- BigWigs integration
-- ============================================================================

-- BigWigs broadcasts module-level "BigWigs_OnBossEngage" / "_OnBossDisable"
-- messages via a CallbackHandler-1.0 registry embedded on BigWigs (or the
-- loader). CallbackHandler's RegisterMessage signature is:
--
--     registry.RegisterMessage(subscriber, messageName, handler)
--
-- where `subscriber` is any unique identifier owned by the *subscriber*, not
-- the broadcaster. Calling it via method syntax (`BW:RegisterMessage(...)`)
-- passes BW itself as the subscriber and BigWigs refuses it with:
--
--   "attempted to register a function to BigWigsLoader, you might be using
--    : instead of . to register the callback."
--
-- We use dot syntax and pass our own addon namespace (HH) as the subscriber.
function Detection:HookBigWigs()
    local BW = _G.BigWigs or _G.BigWigsLoader
    if not BW or type(BW.RegisterMessage) ~= "function" then return false end

    local ok, err = pcall(function()
        BW.RegisterMessage(HH, "BigWigs_OnBossEngage", function(_, module, diff)
            -- Try creature ID first (locale-independent).
            local id
            if module and module.creatureId then
                id = HH.Database:LookupByNpcId(module.creatureId)
            end
            -- Fallback: name-based lookup.
            if not id then
                local bossName = module and (module.displayName or module.moduleName)
                local instanceId = GetCurrentInstanceId()
                id = bossName and HH.Database:LookupByName(bossName, instanceId)
            end
            if id then
                local displayName = module and (module.displayName or module.moduleName)
                Detection:SetCurrentBoss(id, displayName)
            end
        end)
        BW.RegisterMessage(HH, "BigWigs_OnBossDisable", function(_, module)
            HH.State.currentBossID   = nil
            HH.State.currentBossName = nil
        end)
    end)
    if ok then
        HH:Debug("BigWigs engage hook installed")
        return true
    end
    HH:Debug("BigWigs hook failed: " .. tostring(err))
    return false
end

-- ============================================================================
-- DBM integration
-- ============================================================================

function Detection:HookDBM()
    local dbm = _G.DBM
    if not dbm or type(dbm.RegisterCallback) ~= "function" then return false end

    local ok, err = pcall(function()
        -- DBM prefixes all callback event names with "DBM_". The callback
        -- function receives (event, mod, delay, synced, startHp).
        dbm:RegisterCallback("DBM_Pull", function(event, mod, delay, ...)
            -- Try creature ID first (locale-independent).
            local id
            local npcId = mod and mod.combatInfo and mod.combatInfo.mob
            if npcId then
                id = HH.Database:LookupByNpcId(npcId)
            end
            -- Fallback: name-based lookup.
            local bossName = mod and (mod.combatInfo and mod.combatInfo.name or mod.localization and mod.localization.general and mod.localization.general.name)
            if not bossName and mod then bossName = mod.id end
            if not id then
                local instanceId = GetCurrentInstanceId()
                id = bossName and HH.Database:LookupByName(bossName, instanceId)
            end
            if id then
                Detection:SetCurrentBoss(id, bossName)
            else
                HH:Debug("DBM_Pull: no DB match for npcId=" .. tostring(npcId) .. " name='" .. tostring(bossName) .. "'")
            end
        end)
        dbm:RegisterCallback("DBM_Kill", function() end)
        dbm:RegisterCallback("DBM_Wipe", function()
            HH.State.currentBossID   = nil
            HH.State.currentBossName = nil
        end)
    end)
    if ok then
        HH:Debug("DBM callbacks installed")
        return true
    else
        HH:Debug("DBM hook failed: " .. tostring(err))
    end
    return false
end

-- ============================================================================
-- HP polling (used by the Triggers module's HP% threshold logic)
-- ============================================================================

-- Returns the HP percentage of the current boss across all units we can see,
-- or nil if no valid unit is found. Uses NPC ID matching (locale-independent)
-- with a name fallback.
function Detection:GetCurrentBossHPPct()
    if not HH.State.currentBossID then return nil end
    local boss = HH.Database:Get(HH.State.currentBossID)
    local wantNpcIds = boss and boss.npcIds
    local wantName   = HH.State.currentBossName

    local units = self:GetScanUnits()

    for _, unit in ipairs(units) do
        if UnitExists(unit) and not UnitIsDeadOrGhost(unit) then
            local match = false
            -- Primary: match by NPC ID (locale-independent).
            if wantNpcIds then
                local npcId = NpcIdFromGUID(UnitGUID(unit))
                if npcId then
                    for _, wanted in ipairs(wantNpcIds) do
                        if npcId == wanted then match = true; break end
                    end
                end
            end
            -- Fallback: match by display name.
            if not match and wantName and UnitName(unit) == wantName then
                match = true
            end
            if match then
                local hp, max = UnitHealth(unit), UnitHealthMax(unit)
                if max and max > 0 then
                    return (hp / max) * 100
                end
            end
        end
    end
    return nil
end

-- ============================================================================
-- In-combat rescan ticker
-- ============================================================================
--
-- Covers the chained-pull scenario: the player is already in combat (from
-- trash) and engages a boss without generating a TARGET_CHANGED or
-- MOUSEOVER_CHANGED event. A lightweight periodic scan fills the gap until
-- a boss is identified or combat ends.

local RESCAN_INTERVAL = 0.5   -- seconds between scans
local rescanTicker

local function StartRescanTicker()
    if rescanTicker then return end
    rescanTicker = C_Timer.NewTicker(RESCAN_INTERVAL, function()
        if HH.State.currentBossID or not HH.State.inCombat then
            if rescanTicker then rescanTicker:Cancel(); rescanTicker = nil end
            return
        end
        Detection:ScanUnits()
    end)
end

local function StopRescanTicker()
    if rescanTicker then
        rescanTicker:Cancel()
        rescanTicker = nil
    end
end

-- ============================================================================
-- Initialization
-- ============================================================================

function Detection:Initialize()
    -- Unit scan fallback
    HH.Events:On("TARGET_CHANGED",    function() Detection:ScanUnits() end)
    HH.Events:On("MOUSEOVER_CHANGED", function() Detection:ScanUnits() end)
    HH.Events:On("COMBAT_START",      function()
        Detection:ScanUnits()
        if not HH.State.currentBossID then
            StartRescanTicker()
        end
    end)
    HH.Events:On("COMBAT_END", function() StopRescanTicker() end)

    -- Boss mod hookup is deferred: their addons may load after ours.
    HH.Events:On("PLAYER_ENTERING_WORLD", function()
        if not Detection._hookedBW  then Detection._hookedBW  = Detection:HookBigWigs() end
        if not Detection._hookedDBM then Detection._hookedDBM = Detection:HookDBM()     end
    end)
end
