--[[
    HeroHelper - Database Module

    Static database of every TBC raid boss for which HeroHelper knows when to
    remind the player to cast Heroism / Bloodlust. Each entry is keyed by an
    addon-internal ID (stable across versions) and provides:

        npcIds      -- list of NPC creature IDs for this encounter (from GUID).
                       Primary, locale-independent detection path.
        name        -- English boss name (fallback detection + config UI label)
        aliases     -- optional list of extra name strings that can match (e.g.
                       boss mod display names, combined encounters)
        raidKey     -- stable key identifying the raid (used by the UI tabs)
        instanceId  -- optional numeric instance/map ID, used to disambiguate
                       bosses that share a name across instances (e.g.
                       Kael'thas in TK 550 vs MgT 585). Obtained at runtime
                       via select(8, GetInstanceInfo()) — locale-independent.
        default     -- default trigger config for this boss:
                         { type = "pull"  }                     -> cast on pull
                         { type = "hp",  hp = 35 }              -> cast at <= 35% HP
                         { type = "time", seconds = 30 }        -> cast N seconds in
                         { type = "any", conditions = { ... } } -> fire on the first
                                                                   of multiple sub-conditions

    The per-character saved variables store *overrides* (HH.chardb.bosses[id]).
    Any missing key falls back to this table's defaults.

    (Phase-yell detection used to exist as a trigger type but was removed —
    Detection couldn't reliably catch the relevant yell before the boss was
    identified, especially on Magtheridon. HP-based thresholds and time
    triggers replace it.)
]]

local ADDON_NAME, HH = ...

HH.Database = {}
local DB = HH.Database

-- ============================================================================
-- Raid groupings (used by the config panel tabs / dropdowns)
-- ============================================================================

DB.RAIDS = {
    -- Raids
    { key = "kara",    name = "Karazhan",              order = 1 },
    { key = "gruul",   name = "Gruul's Lair",          order = 2 },
    { key = "mag",     name = "Magtheridon's Lair",    order = 3 },
    { key = "ssc",     name = "Serpentshrine Cavern",  order = 4 },
    { key = "tk",      name = "Tempest Keep",          order = 5 },
    { key = "za",      name = "Zul'Aman",              order = 6 },
    { key = "hyjal",   name = "Hyjal Summit",          order = 7 },
    { key = "bt",      name = "Black Temple",          order = 8 },
    { key = "swp",     name = "Sunwell Plateau",       order = 9 },

    -- 5-man dungeons. Gated on HH.db.settings.dungeonPullAlerts via the
    -- isDungeon flag, which GetTriggerConfig checks when resolving.
    { key = "hfr",     name = "D: Hellfire Ramparts",  order = 100, isDungeon = true },
    { key = "bf",      name = "D: Blood Furnace",      order = 101, isDungeon = true },
    { key = "sh",      name = "D: Shattered Halls",    order = 102, isDungeon = true },
    { key = "sp",      name = "D: Slave Pens",         order = 110, isDungeon = true },
    { key = "ub",      name = "D: Underbog",           order = 111, isDungeon = true },
    { key = "sv",      name = "D: Steamvault",         order = 112, isDungeon = true },
    { key = "mt",      name = "D: Mana-Tombs",         order = 120, isDungeon = true },
    { key = "ac",      name = "D: Auchenai Crypts",    order = 121, isDungeon = true },
    { key = "seth",    name = "D: Sethekk Halls",      order = 122, isDungeon = true },
    { key = "slab",    name = "D: Shadow Labyrinth",   order = 123, isDungeon = true },
    { key = "ohf",     name = "D: Old Hillsbrad",      order = 130, isDungeon = true },
    { key = "bm",      name = "D: The Black Morass",   order = 131, isDungeon = true },
    { key = "mech",    name = "D: The Mechanar",       order = 140, isDungeon = true },
    { key = "bot",     name = "D: The Botanica",       order = 141, isDungeon = true },
    { key = "arc",     name = "D: The Arcatraz",       order = 142, isDungeon = true },
    { key = "mgt",     name = "D: Magisters' Terrace", order = 150, isDungeon = true },
}

-- ============================================================================
-- Kill order (used by IterRaid to list bosses in encounter order)
-- ============================================================================

DB.KILL_ORDER = {
    -- Raids
    kara  = { "kara_attumen", "kara_moroes", "kara_maiden", "kara_opera", "kara_curator", "kara_terestian", "kara_shade", "kara_netherspite", "kara_chess", "kara_prince", "kara_nightbane" },
    gruul = { "gruul_maulgar", "gruul_gruul" },
    mag   = { "mag_magtheridon" },
    ssc   = { "ssc_hydross", "ssc_lurker", "ssc_leotheras", "ssc_flk", "ssc_morogrim", "ssc_vashj" },
    tk    = { "tk_alar", "tk_vr", "tk_solarian", "tk_kaelthas" },
    za    = { "za_akilzon", "za_nalorakk", "za_jan", "za_halazzi", "za_hexlord", "za_zuljin" },
    hyjal = { "hyjal_rage", "hyjal_anetheron", "hyjal_kazrogal", "hyjal_azgalor", "hyjal_archimonde" },
    bt    = { "bt_njentus", "bt_supremus", "bt_akama", "bt_bloodboil", "bt_ros", "bt_teron", "bt_mother", "bt_council", "bt_illidan" },
    swp   = { "swp_kalecgos", "swp_brutallus", "swp_felmyst", "swp_eredar", "swp_muru", "swp_kiljaeden" },

    -- 5-man dungeons
    hfr  = { "hfr_gargolmar", "hfr_omor", "hfr_vazruden" },
    bf   = { "bf_maker", "bf_broggok", "bf_kelidan" },
    sh   = { "sh_nethekurse", "sh_omrogg", "sh_kargath" },
    sp   = { "sp_mennu", "sp_rokmar", "sp_quagmirran" },
    ub   = { "ub_hungarfen", "ub_ghazan", "ub_muselek", "ub_blackstalker" },
    sv   = { "sv_thespia", "sv_steamrigger", "sv_kalithresh" },
    mt   = { "mt_pandemonius", "mt_tavarok", "mt_shaffar" },
    ac   = { "ac_shirrak", "ac_maladaar" },
    seth = { "seth_syth", "seth_ikiss" },
    slab = { "slab_hellmaw", "slab_blackheart", "slab_vorpil", "slab_murmur" },
    ohf  = { "ohf_drake", "ohf_skarloc", "ohf_epoch" },
    bm   = { "bm_deja", "bm_temporus", "bm_aeonus" },
    mech = { "mech_gyro", "mech_ironhand", "mech_capacitus", "mech_sepethrea", "mech_pathaleon" },
    bot  = { "bot_sarannis", "bot_freywinn", "bot_thorngrin", "bot_laj", "bot_warpsplinter" },
    arc  = { "arc_zereketh", "arc_dalliah", "arc_soccothrates", "arc_skyriss" },
    mgt  = { "mgt_selin", "mgt_vexallus", "mgt_delrissa", "mgt_kaelthas" },
}

-- ============================================================================
-- Boss table
-- ============================================================================
-- Default triggers are picked from common Shaman raid practice:
--   * trash-adjacent DPS checks / short execute fights -> "pull"
--   * long progression bosses                          -> "hp" at a value where
--                                                         the burn phase starts
--   * fights with a known sweet spot N seconds in      -> "time", seconds = N
--
-- Compound (any-of) triggers are also supported via:
--
--     default = {
--         type = "any",
--         conditions = {
--             { type = "hp",   hp = 25 },
--             { type = "time", seconds = 90 },
--         },
--     },
--
-- The first condition that fires wins (HH.State.triggered latches the
-- whole reminder so the others silently no-op). Useful for phased fights
-- where HP alone isn't a clean signal: pair an HP threshold with a time
-- safety-net so you never miss the burn window.

DB.BOSSES = {
    -- ==================== KARAZHAN ====================
    ["kara_attumen"]    = { raidKey = "kara", npcIds = { 16152, 16151 }, name = "Attumen the Huntsman",                           default = { type = "pull" } },
    ["kara_moroes"]     = { raidKey = "kara", npcIds = { 15687 },        name = "Moroes",                                          default = { type = "pull" } },
    ["kara_maiden"]     = { raidKey = "kara", npcIds = { 16457 },        name = "Maiden of Virtue",                                default = { type = "pull" } },
    ["kara_opera"]      = { raidKey = "kara", npcIds = { 17521, 17534, 17533, 18168 }, name = "Opera Event", aliases = { "Romulo", "Julianne", "Romulo and Julianne", "Dorothee", "Strawman", "Tinhead", "Roar", "The Crone", "The Big Bad Wolf", "Wizard of Oz" }, default = { type = "pull" } },
    -- Curator Evocates at 20% HP for ~20s, during which the raid freecasts.
    -- Popping BL just as Evocation starts lines the 30s haste window up with
    -- the biggest uninterrupted DPS window of the fight and kills him before
    -- his post-Evocate enrage matters.
    ["kara_curator"]    = { raidKey = "kara", npcIds = { 15691 },        name = "The Curator",                                     default = { type = "hp", hp = 30 } },
    ["kara_terestian"]  = { raidKey = "kara", npcIds = { 15688 },        name = "Terestian Illhoof",                               default = { type = "pull" } },
    ["kara_shade"]      = { raidKey = "kara", npcIds = { 16524 },        name = "Shade of Aran",                                   default = { type = "hp", hp = 35 } },
    ["kara_netherspite"]= { raidKey = "kara", npcIds = { 15689 },        name = "Netherspite",                                     default = { type = "pull" } },
    ["kara_chess"]      = { raidKey = "kara", npcIds = { 21752, 21684 }, name = "Chess Event",                                     default = { type = "pull" } },
    ["kara_prince"]     = { raidKey = "kara", npcIds = { 15690 },        name = "Prince Malchezaar",
        default = { type = "hp", hp = 30 },
    },
    -- Nightbane phase cycling (ground / air) is not HP-driven, so HP 50
    -- is the closest safe approximation: lands on the second ground
    -- phase for most pulls, which is the standard BL window.
    ["kara_nightbane"]  = { raidKey = "kara", npcIds = { 17225 },        name = "Nightbane", aliases = { "Nightbane (Raid)" },
        default = { type = "hp", hp = 50 },
    },

    -- ==================== GRUUL'S LAIR ====================
    ["gruul_maulgar"]   = { raidKey = "gruul", npcIds = { 18831 },       name = "High King Maulgar",                              default = { type = "pull" } },
    ["gruul_gruul"]     = { raidKey = "gruul", npcIds = { 19044 },       name = "Gruul the Dragonkiller",                         default = { type = "hp", hp = 30 } },

    -- ==================== MAGTHERIDON'S LAIR ====================
    -- Magtheridon's break-free is on a fixed ~2 minute timer, not HP, but
    -- the raid engages him at 100% after the channelers die. HP 30 hits
    -- the canonical burn window after the first Blast Nova cycle.
    ["mag_magtheridon"] = { raidKey = "mag",  npcIds = { 17257 },        name = "Magtheridon",
        default = { type = "hp", hp = 30 },
    },

    -- ==================== SERPENTSHRINE CAVERN ====================
    ["ssc_hydross"]     = { raidKey = "ssc", npcIds = { 21216 },        name = "Hydross the Unstable",                             default = { type = "pull" } },
    ["ssc_lurker"]      = { raidKey = "ssc", npcIds = { 21217 },        name = "The Lurker Below",                                 default = { type = "pull" } },
    -- Leotheras's demon-form cycle is time-based, not HP. Inner Demons
    -- trigger at 15%; HP 15 catches the execute burn after the last
    -- demon-phase split.
    ["ssc_leotheras"]   = { raidKey = "ssc", npcIds = { 21215 },        name = "Leotheras the Blind",                              default = { type = "hp", hp = 15 } },
    ["ssc_flk"]         = { raidKey = "ssc", npcIds = { 21214 },        name = "Fathom-Lord Karathress",                           default = { type = "hp", hp = 35 } },
    -- Morogrim spawns murloc adds at 50% and 25%. Popping BL at 25% after
    -- the second wave is handled lets the raid burn him down before another
    -- add set spawns.
    ["ssc_morogrim"]    = { raidKey = "ssc", npcIds = { 21213 },        name = "Morogrim Tidewalker",                              default = { type = "hp", hp = 25 } },
    -- Lady Vashj's P3 starts at 70% but BL is almost always saved for the
    -- final burn after the striders / naga pressure eases.
    ["ssc_vashj"]       = { raidKey = "ssc", npcIds = { 21212 },        name = "Lady Vashj",
        default = { type = "hp", hp = 30 },
    },

    -- ==================== TEMPEST KEEP (THE EYE) ====================
    -- Al'ar P2 starts when the raid finishes P1 (separate HP pool), so
    -- tracking by P2 HP is the right call. HP 20 is the final burn.
    ["tk_alar"]         = { raidKey = "tk", npcIds = { 19514 },          name = "Al'ar",
        default = { type = "hp", hp = 20 },
    },
    ["tk_vr"]           = { raidKey = "tk", npcIds = { 19516 },          name = "Void Reaver",                                       default = { type = "pull" } },
    ["tk_solarian"]     = { raidKey = "tk", npcIds = { 18805 },          name = "High Astromancer Solarian",                         default = { type = "hp", hp = 20 } },
    -- Tagged with instanceId so the name-index disambiguator can tell
    -- raid Kael apart from Magister's Terrace Kael (same name, different
    -- instance). The MgT entry below carries the matching tag.
    -- Kael'thas P5 is his own HP-based final phase (he resurrects at
    -- 100% after advisors). HP 50 is the standard BL window on P5 burn.
    ["tk_kaelthas"]     = { raidKey = "tk", npcIds = { 19622 },          name = "Kael'thas Sunstrider",
        instanceId = 550,
        default = { type = "hp", hp = 50 },
    },

    -- ==================== ZUL'AMAN ====================
    ["za_akilzon"]      = { raidKey = "za", npcIds = { 23574 },          name = "Akil'zon",                                          default = { type = "pull" } },
    ["za_nalorakk"]     = { raidKey = "za", npcIds = { 23576 },          name = "Nalorakk",                                          default = { type = "pull" } },
    ["za_jan"]          = { raidKey = "za", npcIds = { 23578 },          name = "Jan'alai",                                          default = { type = "hp", hp = 35 } },
    -- Halazzi merges into the single-boss phase at 50%, then the burn
    -- window is HP 20.
    ["za_halazzi"]      = { raidKey = "za", npcIds = { 23577 },          name = "Halazzi",                                           default = { type = "hp", hp = 20 } },
    -- Hex Lord's abilities (Spirit Bolts, Drain Power) only get nastier as
    -- the fight drags on. Pulling with BL skips an entire Spirit Bolts cycle
    -- and is the standard community call for the timed-chest run.
    ["za_hexlord"]      = { raidKey = "za", npcIds = { 24239 },          name = "Hex Lord Malacrass",                                default = { type = "pull" } },
    -- Zul'jin transitions every 20% (bear 80, eagle 60, lynx 40,
    -- dragonhawk 20). Dragonhawk is the burn phase — HP 20.
    ["za_zuljin"]       = { raidKey = "za", npcIds = { 23863 },          name = "Zul'jin",
        default = { type = "hp", hp = 20 },
    },

    -- ==================== HYJAL SUMMIT ====================
    ["hyjal_rage"]      = { raidKey = "hyjal", npcIds = { 17767 },      name = "Rage Winterchill",                               default = { type = "pull" } },
    ["hyjal_anetheron"] = { raidKey = "hyjal", npcIds = { 17808 },      name = "Anetheron",                                      default = { type = "pull" } },
    ["hyjal_kazrogal"]  = { raidKey = "hyjal", npcIds = { 17888 },      name = "Kaz'rogal",                                      default = { type = "pull" } },
    ["hyjal_azgalor"]   = { raidKey = "hyjal", npcIds = { 17842 },      name = "Azgalor",                                        default = { type = "pull" } },
    ["hyjal_archimonde"]= { raidKey = "hyjal", npcIds = { 17968 },      name = "Archimonde",                                     default = { type = "hp", hp = 20 } },

    -- ==================== BLACK TEMPLE ====================
    ["bt_njentus"]      = { raidKey = "bt", npcIds = { 22887 },          name = "High Warlord Naj'entus",                            default = { type = "pull" } },
    ["bt_supremus"]     = { raidKey = "bt", npcIds = { 22898 },          name = "Supremus",                                          default = { type = "pull" } },
    -- The Shade is unattackable for most of the fight while channeling.
    -- Once freed by Akama it becomes active and drops fast — hp 35 lines
    -- up with the burn window after it first takes damage so the reminder
    -- fires during the actual DPS phase rather than the channeling setup.
    ["bt_akama"]        = { raidKey = "bt", npcIds = { 22841 },          name = "Shade of Akama",                                    default = { type = "hp", hp = 35 } },
    ["bt_bloodboil"]    = { raidKey = "bt", npcIds = { 22948 },          name = "Gurtogg Bloodboil",                                 default = { type = "hp", hp = 25 } },
    -- ROS phase 3 (Essence of Anger) has its own HP pool; HP 50 on
    -- that pool hits the Spite-burst burn window.
    ["bt_ros"]          = { raidKey = "bt", npcIds = { 23420 },          name = "Reliquary of Souls", aliases = { "Essence of Souls" }, default = { type = "hp", hp = 50 } },
    ["bt_teron"]        = { raidKey = "bt", npcIds = { 22871 },          name = "Teron Gorefiend",                                   default = { type = "pull" } },
    ["bt_mother"]       = { raidKey = "bt", npcIds = { 22947 },          name = "Mother Shahraz",                                    default = { type = "pull" } },
    ["bt_council"]      = { raidKey = "bt", npcIds = { 22949, 22950, 22951, 22952 }, name = "Illidari Council",                      default = { type = "pull" } },
    -- Illidan's final phase (P5) is the "You are not prepared" burn
    -- at 30%. Earlier phases are HP-gated (P2 at 65%, P3 demon at 30%,
    -- P4 at 30% again after demon ends), so HP 30 fires on the
    -- P5 transition out of demon form.
    ["bt_illidan"]      = { raidKey = "bt", npcIds = { 22917 },          name = "Illidan Stormrage",
        default = { type = "hp", hp = 30 },
    },

    -- ==================== SUNWELL PLATEAU ====================
    ["swp_kalecgos"]    = { raidKey = "swp", npcIds = { 24850 },         name = "Kalecgos",                                         default = { type = "pull" } },
    ["swp_brutallus"]   = { raidKey = "swp", npcIds = { 24882 },         name = "Brutallus",                                        default = { type = "pull" } },
    -- Felmyst P2 (ground phase) starts at 60% and has separate HP pool.
    -- HP 30 catches the execute window after Encapsulate.
    ["swp_felmyst"]     = { raidKey = "swp", npcIds = { 25038 },         name = "Felmyst",                                          default = { type = "hp", hp = 30 } },
    ["swp_eredar"]      = { raidKey = "swp", npcIds = { 25165, 25166 },  name = "Eredar Twins", aliases = { "Grand Warlock Alythess", "Lady Sacrolash" }, default = { type = "hp", hp = 25 } },
    -- M'uru P2 is Entropius with his own 100% HP pool. BL on Entropius
    -- spawn is the raid standard.
    ["swp_muru"]        = { raidKey = "swp", npcIds = { 25741 },         name = "M'uru",                                            default = { type = "pull" } },
    -- Kil'jaeden P4 is the final 25% burn. Earlier phases are time-gated.
    ["swp_kiljaeden"]   = { raidKey = "swp", npcIds = { 25315 },         name = "Kil'jaeden",
        default = { type = "hp", hp = 25 },
    },

    -- ============================================================================
    -- 5-MAN DUNGEONS
    -- ============================================================================
    -- Dungeon fights are short — "pull" is the right default for every boss;
    -- the execute / phase windows that matter in raids don't apply here.
    -- Every entry is flagged isDungeon = true so GetTriggerConfig can gate
    -- them behind the dungeonPullAlerts setting as a single on/off switch.
    -- Bosses whose name collides with a raid encounter (currently only
    -- Magister's Terrace's Kael'thas Sunstrider vs Tempest Keep's) carry
    -- an explicit `zone` field so DB:LookupByName can disambiguate via
    -- GetRealZoneText().

    -- ==================== HELLFIRE CITADEL ====================
    ["hfr_gargolmar"]   = { raidKey = "hfr",  isDungeon = true, npcIds = { 17306 },  name = "Watchkeeper Gargolmar",  default = { type = "pull" } },
    ["hfr_omor"]        = { raidKey = "hfr",  isDungeon = true, npcIds = { 17308 },  name = "Omor the Unscarred",     default = { type = "pull" } },
    ["hfr_vazruden"]    = { raidKey = "hfr",  isDungeon = true, npcIds = { 17307, 17537, 17536 }, name = "Vazruden the Herald", aliases = { "Vazruden", "Nazan" }, default = { type = "pull" } },

    ["bf_maker"]        = { raidKey = "bf",   isDungeon = true, npcIds = { 17381 },  name = "The Maker",               default = { type = "pull" } },
    ["bf_broggok"]      = { raidKey = "bf",   isDungeon = true, npcIds = { 17380 },  name = "Broggok",                 default = { type = "pull" } },
    ["bf_kelidan"]      = { raidKey = "bf",   isDungeon = true, npcIds = { 17377 },  name = "Keli'dan the Breaker",    default = { type = "pull" } },

    -- Nethekurse heals himself off the dying Shadow Cleft adds; at 20% he
    -- stops healing and the real burn window opens. BL on the execute, not
    -- on the pull, otherwise haste is wasted on regenerated HP.
    ["sh_nethekurse"]   = { raidKey = "sh",   isDungeon = true, npcIds = { 16807 },  name = "Grand Warlock Nethekurse", default = { type = "hp", hp = 20 } },
    ["sh_omrogg"]       = { raidKey = "sh",   isDungeon = true, npcIds = { 16809 },  name = "Warbringer O'mrogg",       default = { type = "pull" } },
    ["sh_kargath"]      = { raidKey = "sh",   isDungeon = true, npcIds = { 16808 },  name = "Warchief Kargath Bladefist", default = { type = "pull" } },

    -- ==================== COILFANG RESERVOIR ====================
    ["sp_mennu"]        = { raidKey = "sp",   isDungeon = true, npcIds = { 17941 },  name = "Mennu the Betrayer",      default = { type = "pull" } },
    ["sp_rokmar"]       = { raidKey = "sp",   isDungeon = true, npcIds = { 17991 },  name = "Rokmar the Crackler",     default = { type = "pull" } },
    ["sp_quagmirran"]   = { raidKey = "sp",   isDungeon = true, npcIds = { 17942 },  name = "Quagmirran",              default = { type = "pull" } },

    ["ub_hungarfen"]    = { raidKey = "ub",   isDungeon = true, npcIds = { 17770 },  name = "Hungarfen",               default = { type = "pull" } },
    ["ub_ghazan"]       = { raidKey = "ub",   isDungeon = true, npcIds = { 18105 },  name = "Ghaz'an",                 default = { type = "pull" } },
    ["ub_muselek"]      = { raidKey = "ub",   isDungeon = true, npcIds = { 17826 },  name = "Swamplord Musel'ek",      default = { type = "pull" } },
    ["ub_blackstalker"] = { raidKey = "ub",   isDungeon = true, npcIds = { 17882 },  name = "The Black Stalker",       default = { type = "pull" } },

    ["sv_thespia"]      = { raidKey = "sv",   isDungeon = true, npcIds = { 17797 },  name = "Hydromancer Thespia",     default = { type = "pull" } },
    ["sv_steamrigger"]  = { raidKey = "sv",   isDungeon = true, npcIds = { 17796 },  name = "Mekgineer Steamrigger",   default = { type = "pull" } },
    ["sv_kalithresh"]   = { raidKey = "sv",   isDungeon = true, npcIds = { 17798 },  name = "Warlord Kalithresh",      default = { type = "pull" } },

    -- ==================== AUCHINDOUN ====================
    ["mt_pandemonius"]  = { raidKey = "mt",   isDungeon = true, npcIds = { 18341 },  name = "Pandemonius",             default = { type = "pull" } },
    ["mt_tavarok"]      = { raidKey = "mt",   isDungeon = true, npcIds = { 18343 },  name = "Tavarok",                 default = { type = "pull" } },
    ["mt_shaffar"]      = { raidKey = "mt",   isDungeon = true, npcIds = { 18344 },  name = "Nexus-Prince Shaffar",    default = { type = "pull" } },

    ["ac_shirrak"]      = { raidKey = "ac",   isDungeon = true, npcIds = { 18371 },  name = "Shirrak the Dead Watcher", default = { type = "pull" } },
    ["ac_maladaar"]     = { raidKey = "ac",   isDungeon = true, npcIds = { 18373 },  name = "Exarch Maladaar",         default = { type = "pull" } },

    ["seth_syth"]       = { raidKey = "seth", isDungeon = true, npcIds = { 18472 },  name = "Darkweaver Syth",         default = { type = "pull" } },
    -- Ikiss casts Arcane Explosion repeatedly under 25% — the iconic burn
    -- window that beats kiting through the explosion phase.
    ["seth_ikiss"]      = { raidKey = "seth", isDungeon = true, npcIds = { 18473 },  name = "Talon King Ikiss",        default = { type = "hp", hp = 25 } },

    ["slab_hellmaw"]    = { raidKey = "slab", isDungeon = true, npcIds = { 18731 },  name = "Ambassador Hellmaw",      default = { type = "pull" } },
    ["slab_blackheart"] = { raidKey = "slab", isDungeon = true, npcIds = { 18667 },  name = "Blackheart the Inciter",  default = { type = "pull" } },
    ["slab_vorpil"]     = { raidKey = "slab", isDungeon = true, npcIds = { 18732 },  name = "Grandmaster Vorpil",      default = { type = "pull" } },
    -- The classic heroic Murmur call: BL after the first Sonic Boom to
    -- skip the second one entirely. ~40% HP lines up with the post-boom
    -- burn window for a normal-paced group.
    ["slab_murmur"]     = { raidKey = "slab", isDungeon = true, npcIds = { 18708 },  name = "Murmur",                  default = { type = "hp", hp = 40 } },

    -- ==================== CAVERNS OF TIME ====================
    ["ohf_drake"]       = { raidKey = "ohf",  isDungeon = true, npcIds = { 17848 },  name = "Lieutenant Drake",        default = { type = "pull" } },
    ["ohf_skarloc"]     = { raidKey = "ohf",  isDungeon = true, npcIds = { 17862 },  name = "Captain Skarloc",         default = { type = "pull" } },
    ["ohf_epoch"]       = { raidKey = "ohf",  isDungeon = true, npcIds = { 18096 },  name = "Epoch Hunter",            default = { type = "pull" } },

    ["bm_deja"]         = { raidKey = "bm",   isDungeon = true, npcIds = { 17879 },  name = "Chrono Lord Deja",        default = { type = "pull" } },
    ["bm_temporus"]     = { raidKey = "bm",   isDungeon = true, npcIds = { 17880 },  name = "Temporus",                default = { type = "pull" } },
    ["bm_aeonus"]       = { raidKey = "bm",   isDungeon = true, npcIds = { 17881 },  name = "Aeonus",                  default = { type = "pull" } },

    -- ==================== TEMPEST KEEP 5-MANS ====================
    ["mech_gyro"]       = { raidKey = "mech", isDungeon = true, npcIds = { 19218 },  name = "Gatewatcher Gyro-Kill",   default = { type = "pull" } },
    ["mech_ironhand"]   = { raidKey = "mech", isDungeon = true, npcIds = { 19710 },  name = "Gatewatcher Iron-Hand",   default = { type = "pull" } },
    ["mech_capacitus"]  = { raidKey = "mech", isDungeon = true, npcIds = { 19219 },  name = "Mechano-Lord Capacitus",  default = { type = "pull" } },
    ["mech_sepethrea"]  = { raidKey = "mech", isDungeon = true, npcIds = { 19221 },  name = "Nethermancer Sepethrea",  default = { type = "pull" } },
    -- Pathaleon enrages at 20% — the canonical execute window for the
    -- final Mechanar boss.
    ["mech_pathaleon"]  = { raidKey = "mech", isDungeon = true, npcIds = { 19220 },  name = "Pathaleon the Calculator", default = { type = "hp", hp = 20 } },

    ["bot_sarannis"]    = { raidKey = "bot",  isDungeon = true, npcIds = { 17976 },  name = "Commander Sarannis",      default = { type = "pull" } },
    ["bot_freywinn"]    = { raidKey = "bot",  isDungeon = true, npcIds = { 17975 },  name = "High Botanist Freywinn",  default = { type = "pull" } },
    ["bot_thorngrin"]   = { raidKey = "bot",  isDungeon = true, npcIds = { 17978 },  name = "Thorngrin the Tender",    default = { type = "pull" } },
    ["bot_laj"]         = { raidKey = "bot",  isDungeon = true, npcIds = { 17980 },  name = "Laj",                     default = { type = "skip" } },
    ["bot_warpsplinter"]= { raidKey = "bot",  isDungeon = true, npcIds = { 17977 },  name = "Warp Splinter",           default = { type = "pull" } },

    ["arc_zereketh"]    = { raidKey = "arc",  isDungeon = true, npcIds = { 20870 },  name = "Zereketh the Unbound",    default = { type = "pull" } },
    ["arc_dalliah"]     = { raidKey = "arc",  isDungeon = true, npcIds = { 20885 },  name = "Dalliah the Doomsayer",   default = { type = "pull" } },
    ["arc_soccothrates"]= { raidKey = "arc",  isDungeon = true, npcIds = { 20886 },  name = "Wrath-Scryer Soccothrates", default = { type = "pull" } },
    -- Skyriss splits at 66% and 33%. Popping BL just before the 66%
    -- split burns Skyriss + illusions before the second split makes
    -- it chaotic.
    ["arc_skyriss"]     = { raidKey = "arc",  isDungeon = true, npcIds = { 20912 },  name = "Harbinger Skyriss",
        default = { type = "hp", hp = 70 },
    },

    -- ==================== MAGISTERS' TERRACE ====================
    -- The Kael'thas entry collides with Tempest Keep's Kael'thas. Both
    -- carry an instanceId tag so the name-index disambiguator can
    -- distinguish them via select(8, GetInstanceInfo()) at lookup time.
    -- NPC ID lookup is unambiguous (different creature IDs) so the
    -- instanceId is only needed for the name-based fallback path.
    ["mgt_selin"]       = { raidKey = "mgt",  isDungeon = true, npcIds = { 24723 },  name = "Selin Fireheart",         instanceId = 585, default = { type = "pull" } },
    ["mgt_vexallus"]    = { raidKey = "mgt",  isDungeon = true, npcIds = { 24744 },  name = "Vexallus",                instanceId = 585, default = { type = "pull" } },
    ["mgt_delrissa"]    = { raidKey = "mgt",  isDungeon = true, npcIds = { 24560 },  name = "Priestess Delrissa",      instanceId = 585, default = { type = "pull" } },
    ["mgt_kaelthas"]    = { raidKey = "mgt",  isDungeon = true, npcIds = { 24664 },  name = "Kael'thas Sunstrider",    instanceId = 585, default = { type = "pull" } },
}

-- ============================================================================
-- NPC ID lookup cache (locale-independent, primary detection path)
-- ============================================================================

-- npcId (number) -> bossID (string). Built lazily on first lookup.
DB._npcIndex = nil

local function BuildNpcIndex()
    local index = {}
    for id, boss in pairs(DB.BOSSES) do
        if boss.npcIds then
            for _, npcId in ipairs(boss.npcIds) do
                index[npcId] = id
            end
        end
    end
    DB._npcIndex = index
end

-- Returns the bossID for a given NPC creature ID (from GUID), or nil.
-- This is the primary detection path — NPC IDs are locale-independent.
function DB:LookupByNpcId(npcId)
    if not npcId then return nil end
    if not DB._npcIndex then BuildNpcIndex() end
    return DB._npcIndex[npcId]
end

-- ============================================================================
-- Name lookup cache (fallback for English clients / boss mod names)
-- ============================================================================

-- name_lower -> bossID  (single match, common case)
--               -> { { id, instanceId }, ... }  (multi-match, when two
--                    bosses share a name — e.g. Kael'thas in TK vs MgT)
-- Built lazily on first lookup.
DB._nameIndex = nil

local function BuildNameIndex()
    local index = {}

    local function add(key, id, instId)
        local existing = index[key]
        if existing == nil then
            index[key] = id
        elseif type(existing) == "string" then
            local existingBoss = DB.BOSSES[existing]
            index[key] = {
                { id = existing, instanceId = existingBoss and existingBoss.instanceId },
                { id = id,       instanceId = instId },
            }
        else
            table.insert(existing, { id = id, instanceId = instId })
        end
    end

    for id, boss in pairs(DB.BOSSES) do
        add(boss.name:lower(), id, boss.instanceId)
        if boss.aliases then
            for _, alias in ipairs(boss.aliases) do
                add(alias:lower(), id, boss.instanceId)
            end
        end
    end

    DB._nameIndex = index
end

-- Returns the bossID for a given unit name string, or nil.
--
-- `currentInstanceId` (number, optional) lets the lookup disambiguate when
-- two bosses share a name (e.g. Kael'thas in TK instance 550 vs MgT
-- instance 585). Obtain it via `select(8, GetInstanceInfo())` — this
-- returns a numeric instance ID that is locale-independent.
--
-- The legacy `zoneName` parameter is also accepted: if `currentInstanceId`
-- is nil but `zoneName` is a string, name-based zone matching is attempted
-- as a last resort (works on English clients only).
function DB:LookupByName(unitName, currentInstanceId)
    if not unitName then return nil end
    if not DB._nameIndex then BuildNameIndex() end

    local entry = DB._nameIndex[unitName:lower()]
    if entry == nil then return nil end
    if type(entry) == "string" then
        return entry -- single match, no disambiguation needed
    end

    -- Disambiguate by instance ID (locale-independent).
    if type(currentInstanceId) == "number" then
        for _, m in ipairs(entry) do
            if m.instanceId and m.instanceId == currentInstanceId then
                return m.id
            end
        end
    end

    -- Fallback: return the first registered match.
    return entry[1].id
end

-- Returns the boss entry table for an ID.
function DB:Get(id)
    return DB.BOSSES[id]
end

-- Returns the effective trigger config for a boss (user override merged on top
-- of the database default). Returns nil if the boss is explicitly disabled,
-- or if it's a 5-man dungeon boss and the dungeon-pull-alerts master toggle
-- is off (the feature opts in as a whole via HH.db.settings.dungeonPullAlerts).
function DB:GetTriggerConfig(id)
    local boss = DB.BOSSES[id]
    if not boss then return nil end

    if boss.isDungeon
       and not (HH.db and HH.db.settings and HH.db.settings.dungeonPullAlerts) then
        return nil -- dungeon alerts master-disabled
    end

    local override = HH.chardb and HH.chardb.bosses and HH.chardb.bosses[id]
    if override and override.enabled == false then
        return nil -- explicitly disabled
    end

    local cfg = {}
    for k, v in pairs(boss.default) do cfg[k] = v end
    if override then
        -- Compound overrides REPLACE the default wholesale: merging
        -- single-type fields into a compound config (or vice versa)
        -- would produce a frankenconfig that none of the trigger
        -- handlers know how to interpret.
        if override.type == "any" and override.conditions then
            cfg = {
                type       = "any",
                conditions = override.conditions,
            }
        else
            if override.type    then cfg.type    = override.type    end
            if override.hp      then cfg.hp      = override.hp      end
            if override.seconds then cfg.seconds = override.seconds end
        end
    end
    return cfg
end

-- Iterator over all bosses in a raid, in kill order.
function DB:IterRaid(raidKey)
    local order = DB.KILL_ORDER[raidKey]
    if order then
        local i = 0
        return function()
            i = i + 1
            local id = order[i]
            if id then return id, DB.BOSSES[id] end
        end
    end
    -- Fallback for unknown raids: collect from BOSSES and sort by name.
    local list = {}
    for id, boss in pairs(DB.BOSSES) do
        if boss.raidKey == raidKey then
            table.insert(list, { id = id, boss = boss })
        end
    end
    table.sort(list, function(a, b) return a.boss.name < b.boss.name end)
    local i = 0
    return function()
        i = i + 1
        if list[i] then return list[i].id, list[i].boss end
    end
end

-- Debug: total boss count
function DB:Count()
    local n = 0
    for _ in pairs(DB.BOSSES) do n = n + 1 end
    return n
end

function DB:Initialize()
    BuildNpcIndex()
    BuildNameIndex()
    HH:Debug("Database loaded: " .. DB:Count() .. " bosses across " .. #DB.RAIDS .. " raids")
    return true
end

-- ============================================================================
-- Import / Export  (hash format)
-- ============================================================================
--
-- Wire format:
--
--     HH!<base64 payload>
--
-- The base64 payload decodes to plaintext:
--
--     HH2|<bossID>=<spec>|<bossID>=<spec>|...
--
-- Differences from the legacy HH1 plaintext format:
--   * HH2 emits **every boss in the database**, not just the user's
--     overrides. This makes the hash a complete snapshot: importing it
--     reproduces the sender's effective config exactly, regardless of how
--     the receiver's addon defaults happen to be tuned.
--   * The plaintext is wrapped in base64 and prefixed with `HH!` so the
--     final string is a short opaque "hash" that's safe to paste anywhere
--     and visually distinct from ordinary chat text.
--
-- <spec> is one of:
--     pull         -> trigger on pull
--     hp:<N>       -> trigger at HP% <= N
--     time:<N>     -> trigger N seconds after pull
--     skip         -> never fire
--     any(sub;..)  -> compound trigger; fires on the first sub to match
--     off          -> disabled for this boss
--
-- Backward compatibility: ImportHash also accepts a bare `HH1|...` or
-- `HH2|...` plaintext string (no HH!/base64 wrapper), so strings produced
-- by earlier builds keep working. Phase specs (`phase:N`) from pre-phase-
-- removal exports decode to an HP 30 fallback — see DecodeSubSpec.

local EXPORT_VERSION = "HH2"
local HASH_PREFIX    = "HH!"

-- -- Base64 ------------------------------------------------------------------
--
-- Tiny pure-Lua base64 so we don't drag in LibCompress. The payload is a
-- few hundred bytes at most, so math-based bit slicing is perfectly fast.

local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_INDEX = {}
for i = 1, #B64_CHARS do B64_INDEX[B64_CHARS:sub(i, i)] = i - 1 end

local function Base64Encode(str)
    local out = {}
    local len = #str
    local i   = 1
    while i <= len do
        local a = str:byte(i)     or 0
        local b = str:byte(i + 1) or 0
        local c = str:byte(i + 2) or 0
        local n = a * 65536 + b * 256 + c
        local c1 = math.floor(n / 262144)
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64)   % 64
        local c4 = n % 64
        out[#out + 1] = B64_CHARS:sub(c1 + 1, c1 + 1)
        out[#out + 1] = B64_CHARS:sub(c2 + 1, c2 + 1)
        if i + 1 <= len then
            out[#out + 1] = B64_CHARS:sub(c3 + 1, c3 + 1)
        else
            out[#out + 1] = "="
        end
        if i + 2 <= len then
            out[#out + 1] = B64_CHARS:sub(c4 + 1, c4 + 1)
        else
            out[#out + 1] = "="
        end
        i = i + 3
    end
    return table.concat(out)
end

local function Base64Decode(str)
    str = str:gsub("%s+", "")
    str = str:gsub("=+$", "")
    local out = {}
    local len = #str
    local i   = 1
    while i <= len do
        local a = B64_INDEX[str:sub(i,     i)]
        local b = B64_INDEX[str:sub(i + 1, i + 1)]
        local c = B64_INDEX[str:sub(i + 2, i + 2)]
        local d = B64_INDEX[str:sub(i + 3, i + 3)]
        if not a or not b then return nil, "invalid base64 character" end
        local n = a * 262144 + b * 4096 + (c or 0) * 64 + (d or 0)
        out[#out + 1] = string.char(math.floor(n / 65536))
        if c then out[#out + 1] = string.char(math.floor(n / 256) % 256) end
        if d then out[#out + 1] = string.char(n % 256) end
        i = i + 4
    end
    return table.concat(out)
end

-- -- Spec encoding -----------------------------------------------------------

local function EncodeSpec(cfg, enabled)
    if enabled == false then return "off" end
    if cfg.type == "pull"  then return "pull" end
    if cfg.type == "skip"  then return "skip" end
    if cfg.type == "hp"    and cfg.hp      then return "hp:"    .. tostring(cfg.hp)      end
    if cfg.type == "time"  and cfg.seconds then return "time:"  .. tostring(cfg.seconds) end
    if cfg.type == "any"   and cfg.conditions then
        -- Compound encoding: any(sub;sub;sub) where each sub is itself a
        -- single-type spec. Sub-encoding recurses into EncodeSpec; nested
        -- compounds are flattened to a single level (we never produce one).
        local parts = {}
        for _, sub in ipairs(cfg.conditions) do
            local s = EncodeSpec(sub, true)
            if s and s ~= "off" then parts[#parts + 1] = s end
        end
        if #parts > 0 then
            return "any(" .. table.concat(parts, ";") .. ")"
        end
    end
    return nil
end

-- Decodes a single sub-spec into a condition table for compound triggers.
-- Returns nil if the sub-spec is unrecognized.
local function DecodeSubSpec(sub)
    if sub == "pull" then
        return { type = "pull" }
    end
    local kind, val = sub:match("^(%a+):(%d+)$")
    val = tonumber(val)
    if kind == "hp" and val then
        return { type = "hp", hp = math.max(1, math.min(99, val)) }
    elseif kind == "phase" and val then
        -- Legacy phase sub-spec from pre-removal exports: degrade to HP 30.
        return { type = "hp", hp = 30 }
    elseif kind == "time" and val then
        return { type = "time", seconds = math.max(1, math.min(600, val)) }
    end
    return nil
end

-- Parses the payload after the `HHn|` header and writes entries into
-- HH.chardb.bosses. Returns (applied, skipped). Used by both HH1 and HH2.
local function ParseEntries(rest)
    HH.chardb.bosses = HH.chardb.bosses or {}
    local applied, skipped = 0, 0
    for entry in (rest .. "|"):gmatch("([^|]+)|") do
        local id, spec = entry:match("^([^=]+)=(.*)$")
        if id and spec and DB.BOSSES[id] then
            local o = { enabled = true }
            if spec == "pull" then
                o.type = "pull"
            elseif spec == "skip" then
                o.type = "skip"
            elseif spec == "off" then
                o.enabled = false
            else
                -- Compound: any(sub;sub;sub)
                local anyBody = spec:match("^any%((.+)%)$")
                if anyBody then
                    o.type       = "any"
                    o.conditions = {}
                    for sub in (anyBody .. ";"):gmatch("([^;]+);") do
                        local cond = DecodeSubSpec(sub)
                        if cond then
                            o.conditions[#o.conditions + 1] = cond
                        end
                    end
                    if #o.conditions == 0 then o = nil end
                else
                    local kind, val = spec:match("^(%a+):(%d+)$")
                    if kind == "hp" then
                        o.type = "hp"
                        o.hp   = math.max(1, math.min(99, tonumber(val) or 35))
                    elseif kind == "phase" then
                        -- Legacy phase spec: degrade to HP 30 fallback.
                        o.type = "hp"
                        o.hp   = 30
                    elseif kind == "time" then
                        o.type    = "time"
                        o.seconds = math.max(1, math.min(600, tonumber(val) or 30))
                    else
                        o = nil
                    end
                end
            end
            if o then
                HH.chardb.bosses[id] = o
                applied = applied + 1
            else
                skipped = skipped + 1
            end
        elseif id then
            skipped = skipped + 1
        end
    end
    return applied, skipped
end

-- -- Public API --------------------------------------------------------------

-- Builds a full snapshot of the player's effective per-boss configuration
-- and returns it wrapped as an opaque hash string.
function DB:ExportHash()
    local ids = {}
    for id in pairs(DB.BOSSES) do table.insert(ids, id) end
    table.sort(ids)

    local parts = { EXPORT_VERSION }
    for _, id in ipairs(ids) do
        local boss     = DB.BOSSES[id]
        local override = HH.chardb and HH.chardb.bosses and HH.chardb.bosses[id]

        -- Merge override on top of the database default, exactly the same
        -- way GetTriggerConfig does it.
        local cfg = {}
        for k, v in pairs(boss.default) do cfg[k] = v end
        if override then
            if override.type    then cfg.type    = override.type    end
            if override.hp      then cfg.hp      = override.hp      end
            if override.seconds then cfg.seconds = override.seconds end
            if override.conditions then cfg.conditions = override.conditions end
        end
        local enabled = not (override and override.enabled == false)

        local spec = EncodeSpec(cfg, enabled)
        if spec then
            parts[#parts + 1] = id .. "=" .. spec
        end
    end

    local plain = table.concat(parts, "|")
    return HASH_PREFIX .. Base64Encode(plain)
end

-- Parses an export hash. Returns (ok, applied, skipped, err). On success,
-- entries are written into HH.chardb.bosses — existing entries for boss IDs
-- not present in the hash are left untouched; entries for IDs in the hash
-- are replaced.
--
-- Accepts:
--   * HH!<base64> (new format)
--   * HH2|... plaintext (same payload, unwrapped)
--   * HH1|... plaintext (legacy overrides-only format)
function DB:ImportHash(str)
    if type(str) ~= "string" then return false, 0, 0, "not a string" end
    str = str:gsub("^%s+", ""):gsub("%s+$", "")
    if str == "" then return false, 0, 0, "empty input" end

    -- Unwrap the HH!<base64> envelope if present.
    local plain = str
    if str:sub(1, #HASH_PREFIX) == HASH_PREFIX then
        local decoded, err = Base64Decode(str:sub(#HASH_PREFIX + 1))
        if not decoded then
            return false, 0, 0, "invalid hash: " .. tostring(err)
        end
        plain = decoded
    end

    local version, rest = plain:match("^(HH%d+)|(.*)$")
    if not version then
        -- Allow a bare version marker (empty but valid).
        if plain == "HH1" or plain == "HH2" then
            return true, 0, 0, nil
        end
        return false, 0, 0, "missing or invalid version (expected HH!<hash>)"
    end
    if version ~= "HH1" and version ~= "HH2" then
        return false, 0, 0, "unsupported format version: " .. version
    end

    local applied, skipped = ParseEntries(rest)
    return true, applied, skipped, nil
end

-- Legacy aliases — kept so any external caller still using the pre-hash
-- names continues to work.
DB.ExportOverrides = DB.ExportHash
DB.ImportOverrides = DB.ImportHash
