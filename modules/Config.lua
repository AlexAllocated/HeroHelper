--[[
    HeroHelper - Config Module

    Settings panel accessible via /hh or the minimap button. Two tabs:

        General  - enable/disable, minimap toggle, sound selection, button
                   size slider, lock toggle, button reset
        Bosses   - scrollable list grouped by raid, each row shows:
                       [boss name]  [trigger type dropdown]  [value field]
                   Changes are written into HH.chardb.bosses[id].

    The styling mirrors FishingKit's Config.lua (flat dark backdrop, thin
    1-px borders, muted section headers, compact layout). This is a
    self-contained implementation — no Ace or Blizzard interface options API
    is used, matching FishingKit's conventions.
]]

local ADDON_NAME, HH = ...

HH.Config = {}
local Config = HH.Config

-- Dropdowns are built from scratch (see MakeDropdown below). We used to
-- depend on LibUIDropDownMenu-4.0 as a tainted-template workaround, but
-- its shared global list frame caused stale-button contamination across
-- dropdowns (Bosses-tab type items leaking into the General-tab role
-- dropdown). The custom widget each has its own popup with zero shared
-- state and zero sharing with any other addon's dropdowns.

-- UI constants
local FRAME_WIDTH  = 460
local FRAME_HEIGHT = 560
local PADDING      = 14
local ROW_HEIGHT   = 26

-- Design palette
local D = {
    bg      = {0.04, 0.04, 0.06},  bgA  = 0.93,
    border  = {0.18, 0.18, 0.23},  borA = 0.80,
    divider = {0.14, 0.14, 0.18},  divA = 0.90,
    accent  = {1.00, 0.49, 0.10},           -- Heroism/BL orange
    label   = {0.40, 0.40, 0.45},
    value   = {0.82, 0.84, 0.88},
    success = {0.26, 0.76, 0.42},
}

-- ============================================================================
-- Generic widget helpers (mirrors FishingKit's AddThinBorder / buttons)
-- ============================================================================

local function AddThinBorder(f, r, g, b, a)
    local t  = f:CreateTexture(nil,"OVERLAY"); t:SetPoint("TOPLEFT");     t:SetPoint("TOPRIGHT");    t:SetHeight(1); t:SetColorTexture(r,g,b,a)
    local bb = f:CreateTexture(nil,"OVERLAY"); bb:SetPoint("BOTTOMLEFT"); bb:SetPoint("BOTTOMRIGHT"); bb:SetHeight(1); bb:SetColorTexture(r,g,b,a)
    local l  = f:CreateTexture(nil,"OVERLAY"); l:SetPoint("TOPLEFT");     l:SetPoint("BOTTOMLEFT");  l:SetWidth(1);  l:SetColorTexture(r,g,b,a)
    local rr = f:CreateTexture(nil,"OVERLAY"); rr:SetPoint("TOPRIGHT");   rr:SetPoint("BOTTOMRIGHT"); rr:SetWidth(1); rr:SetColorTexture(r,g,b,a)
end

local function MakeFlatButton(parent, text, width, height)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(width or 110, height or 22)

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.10, 0.10, 0.13, 1)
    btn.bg = bg

    AddThinBorder(btn, D.border[1], D.border[2], D.border[3], D.borA)

    local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetAllPoints()
    lbl:SetJustifyH("CENTER")
    lbl:SetText(text)
    lbl:SetTextColor(D.value[1], D.value[2], D.value[3])
    btn.label = lbl

    btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    btn:GetHighlightTexture():SetBlendMode("ADD")

    return btn
end

-- Hand-rolled flat checkbox (14x14 square + accent fill when checked).
-- Returns a container Frame with :SetChecked(bool), :GetChecked(), and
-- :HookClick(fn) methods. Matches the FishingKit visual style.
local function MakeCheckbox(parent, label)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(260, 22)

    local box = CreateFrame("Button", nil, container)
    box:SetSize(14, 14)
    box:SetPoint("LEFT", container, "LEFT", 0, 0)

    local boxBg = box:CreateTexture(nil, "BACKGROUND")
    boxBg:SetAllPoints()
    boxBg:SetColorTexture(0.07, 0.07, 0.09, 1)
    AddThinBorder(box, D.border[1], D.border[2], D.border[3], 0.85)

    local fill = box:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT",     2, -2)
    fill:SetPoint("BOTTOMRIGHT", -2, 2)
    fill:SetColorTexture(D.accent[1], D.accent[2], D.accent[3], 1)
    fill:Hide()

    box:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    box:GetHighlightTexture():SetBlendMode("ADD")

    local txt = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    txt:SetPoint("LEFT", box, "RIGHT", 8, 0)
    txt:SetText(label)
    txt:SetTextColor(D.value[1], D.value[2], D.value[3])

    local checked = false
    function container:SetChecked(v)
        checked = v and true or false
        if checked then fill:Show() else fill:Hide() end
    end
    function container:GetChecked() return checked end
    function container:HookClick(fn)
        box:SetScript("OnClick", function()
            container:SetChecked(not checked)
            if fn then fn(checked) end
        end)
    end

    return container
end

-- Slider using a simple manual implementation (native Slider is unreliable in
-- TBC Anniversary — FishingKit reports the same and uses a hand-rolled one).
local function MakeSlider(parent, label, min, max, step, initial, onChange)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(220, 26)

    local lbl = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
    lbl:SetText(label)
    lbl:SetTextColor(D.label[1], D.label[2], D.label[3])

    local value = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    value:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, 0)
    value:SetText(tostring(initial))
    value:SetTextColor(D.value[1], D.value[2], D.value[3])

    local track = CreateFrame("Frame", nil, container)
    track:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, 2)
    track:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 2)
    track:SetHeight(6)
    local trackBg = track:CreateTexture(nil, "BACKGROUND")
    trackBg:SetAllPoints()
    trackBg:SetColorTexture(0.10, 0.10, 0.13, 1)

    local fill = track:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("LEFT", track, "LEFT")
    fill:SetHeight(6)
    fill:SetColorTexture(D.accent[1], D.accent[2], D.accent[3], 0.9)

    -- Redraw the fill bar from the current container.value. Split out so
    -- OnSizeChanged can rerun it after the caller resizes the slider (the
    -- track width is only known once the slider has been laid out by its
    -- parent, so we cannot bake the fill width in at construction time).
    local function RedrawFill()
        local v = container.value
        if not v then return end
        local pct = (v - min) / (max - min)
        local width = track:GetWidth() * pct
        if width < 1 then width = 1 end
        fill:SetWidth(width)
    end

    local function SetValue(v, fireChange)
        v = math.max(min, math.min(max, v))
        v = math.floor(v / step + 0.5) * step
        container.value = v
        value:SetText(tostring(v))
        RedrawFill()
        if fireChange and onChange then onChange(v) end
    end

    -- Rerun layout when the track width changes (caller usually calls
    -- :SetWidth after MakeSlider returns).
    track:SetScript("OnSizeChanged", RedrawFill)

    track:EnableMouse(true)
    track:SetScript("OnMouseDown", function(self)
        self:SetScript("OnUpdate", function(self)
            local x = GetCursorPosition() / self:GetEffectiveScale()
            local left = self:GetLeft()
            if left then
                local pct = (x - left) / self:GetWidth()
                pct = math.max(0, math.min(1, pct))
                SetValue(min + pct * (max - min), true)
            end
            if not IsMouseButtonDown("LeftButton") then
                self:SetScript("OnUpdate", nil)
            end
        end)
    end)

    container.SetValue = SetValue
    -- Set the initial value without firing onChange, so opening the config
    -- panel doesn't overwrite the saved value with its own current value.
    SetValue(initial, false)
    return container
end

-- Custom dropdown widget. We deliberately do NOT use LibUIDropDownMenu-4.0
-- here: LibDD uses a SHARED global list frame (L_DropDownList1) across
-- every dropdown in the UI, and stale buttons from one dropdown leak into
-- another (e.g. opening the Bosses-tab type dropdown with 7 items, then
-- opening the General-tab role dropdown with 4 items, left "Skip"/"Multi"/
-- "Off" from typeItems visible in the role popup). Every workaround
-- (clearing, post-add clamp, SetHeight(0), text-blank, etc.) fought the
-- symptom but didn't stop LibDD from re-rendering leaked state.
--
-- Custom widget = self-contained: one popup frame per dropdown, no shared
-- global state. No cross-contamination is possible. Minimal features:
-- arrow-on-right control showing current selection, click to open a
-- scrollable popup list, click item to select + close.

local dropdownCounter = 0

-- Tracks currently-open dropdown popup so a new open closes the old one
-- (matches native Blizzard single-popup behavior).
local activeDropdownPopup = nil

local function ClosePopup(popup)
    if popup and popup:IsShown() then popup:Hide() end
end

-- `debugTag` is accepted but unused — kept in the signature for any
-- future instrumentation.
-- `onPreview`, if passed, makes each row render a speaker icon that calls
-- onPreview(entry.value) without selecting the entry. Used by the sound
-- dropdown so players can audition each sound before committing.
local function MakeDropdown(parent, width, items, onSelect, initialText, debugTag, onPreview)
    dropdownCounter = dropdownCounter + 1
    local name = "HeroHelperDropdown" .. dropdownCounter

    -- The main control: a single Button showing current selection +
    -- dropdown arrow on the right.
    local dd = CreateFrame("Button", name, parent)
    dd:SetSize(width, 22)

    -- Dark background + thin border (FishingKit-aligned style).
    local bg = dd:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.08, 0.08, 0.08, 0.9)
    AddThinBorder(dd, D.border[1], D.border[2], D.border[3], D.borA)

    -- Text (left-aligned, leaves room on the right for the arrow).
    local text = dd:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("LEFT", dd, "LEFT", 6, 0)
    text:SetPoint("RIGHT", dd, "RIGHT", -22, 0)
    text:SetJustifyH("LEFT")
    text:SetText(initialText or "")
    text:SetTextColor(D.value[1], D.value[2], D.value[3])
    dd.text = text

    -- Dropdown arrow (right side).
    local arrow = dd:CreateTexture(nil, "OVERLAY")
    arrow:SetSize(12, 12)
    arrow:SetPoint("RIGHT", dd, "RIGHT", -4, 0)
    arrow:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")
    dd.arrow = arrow

    dd:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    -- Popup frame — one per dropdown, parented to UIParent so it can anchor
    -- above/below the control without being clipped by the config panel.
    -- TOOLTIP strata sits above FULLSCREEN_DIALOG, so clicks on popup rows
    -- beat any click-catcher we place below. See clickCatcher below.
    local popup = CreateFrame("Frame", name .. "Popup", UIParent)
    popup:SetFrameStrata("TOOLTIP")
    popup:SetFrameLevel(dd:GetFrameLevel() + 20)
    popup:Hide()
    popup:EnableMouse(true)

    local popupBg = popup:CreateTexture(nil, "BACKGROUND")
    popupBg:SetAllPoints()
    popupBg:SetColorTexture(0.05, 0.05, 0.05, 0.95)
    AddThinBorder(popup, D.border[1], D.border[2], D.border[3], D.borA)

    -- Full-screen invisible click-catcher shown while the popup is open.
    -- Sits at FULLSCREEN_DIALOG strata — below the popup, above normal UI.
    -- Any click reaching it is (by elimination) outside the popup, so we
    -- close. Avoids relying on GetMouseFocus(), which doesn't exist on
    -- TBC 2.5.5.
    local clickCatcher = CreateFrame("Frame", nil, UIParent)
    clickCatcher:SetAllPoints(UIParent)
    clickCatcher:SetFrameStrata("FULLSCREEN_DIALOG")
    clickCatcher:EnableMouse(true)
    clickCatcher:Hide()
    -- Stash the catcher on the popup so the "close previous popup" path
    -- in dd.OnClick below can find it regardless of which dropdown it was.
    popup._hhCatcher = clickCatcher

    -- Rows. At most MAX_VISIBLE_ROWS visible; if there are more items, the
    -- popup gets a scrollbar.
    local ROW_H = 18
    local MAX_VISIBLE_ROWS = 12
    local numItems = #items
    local viewportRows = math.min(numItems, MAX_VISIBLE_ROWS)
    local needsScroll = numItems > MAX_VISIBLE_ROWS

    local popupWidth = width + (needsScroll and 22 or 0)
    popup:SetSize(popupWidth, viewportRows * ROW_H + 4)

    local function HidePopupAndCatcher()
        ClosePopup(popup)
        clickCatcher:Hide()
        if activeDropdownPopup == popup then activeDropdownPopup = nil end
    end

    local function SelectEntry(entry)
        dd.text:SetText(entry.label)
        HidePopupAndCatcher()
        if onSelect then onSelect(entry.value, entry.label) end
    end

    clickCatcher:SetScript("OnMouseDown", function()
        HidePopupAndCatcher()
    end)

    -- Build rows inside either a ScrollFrame (if list is long) or directly
    -- on the popup.
    local listParent = popup
    if needsScroll then
        local scroll = CreateFrame("ScrollFrame", nil, popup, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", popup, "TOPLEFT", 2, -2)
        scroll:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -22, 2)
        local scrollChild = CreateFrame("Frame", nil, scroll)
        scrollChild:SetSize(width - 4, numItems * ROW_H)
        scroll:SetScrollChild(scrollChild)
        listParent = scrollChild
    end

    for i, entry in ipairs(items) do
        local row = CreateFrame("Button", nil, listParent)
        if needsScroll then
            row:SetSize(width - 4, ROW_H)
            row:SetPoint("TOPLEFT", listParent, "TOPLEFT", 0, -(i - 1) * ROW_H)
        else
            row:SetSize(popupWidth - 4, ROW_H)
            row:SetPoint("TOPLEFT", popup, "TOPLEFT", 2, -2 - (i - 1) * ROW_H)
        end

        local hi = row:CreateTexture(nil, "HIGHLIGHT")
        hi:SetAllPoints()
        hi:SetColorTexture(D.accent[1], D.accent[2], D.accent[3], 0.25)

        local rowText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        rowText:SetPoint("LEFT", row, "LEFT", 6, 0)
        rowText:SetJustifyH("LEFT")
        rowText:SetText(entry.label)
        rowText:SetTextColor(D.value[1], D.value[2], D.value[3])

        -- Optional per-row preview button (speaker icon on the right).
        -- Clicking it plays the entry's value through onPreview WITHOUT
        -- selecting the entry or closing the popup — matches ShamanPower's
        -- audition behavior.
        if onPreview then
            local speaker = CreateFrame("Button", nil, row)
            speaker:SetSize(14, 14)
            speaker:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            local tex = speaker:CreateTexture(nil, "ARTWORK")
            tex:SetAllPoints()
            tex:SetTexture("Interface\\Common\\VoiceChat-Speaker")
            speaker:SetHighlightTexture("Interface\\Common\\VoiceChat-On")
            speaker:SetScript("OnClick", function()
                onPreview(entry.value, entry.label)
            end)
            rowText:SetPoint("RIGHT", speaker, "LEFT", -4, 0)
        else
            rowText:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        end

        row:SetScript("OnClick", function()
            SelectEntry(entry)
        end)
    end

    -- Open/close on main-control click.
    dd:SetScript("OnClick", function(self)
        if popup:IsShown() then
            HidePopupAndCatcher()
            return
        end
        -- Close any other open dropdown first (and its click-catcher).
        if activeDropdownPopup and activeDropdownPopup ~= popup then
            if activeDropdownPopup._hhCatcher then
                activeDropdownPopup._hhCatcher:Hide()
            end
            ClosePopup(activeDropdownPopup)
        end
        popup:ClearAllPoints()
        popup:SetPoint("TOPLEFT", dd, "BOTTOMLEFT", 0, -2)
        popup:Show()
        clickCatcher:Show()
        activeDropdownPopup = popup
    end)

    function dd:RefreshText(newText)
        text:SetText(newText or "")
    end

    return dd
end

-- ============================================================================
-- Frame creation
-- ============================================================================

local configState = {
    frame   = nil,
    visible = false,
    tab     = "general",
}

function Config:Initialize()
    self:CreateFrame()
end

function Config:CreateFrame()
    if configState.frame then return end

    local frame = CreateFrame("Frame", "HeroHelperConfigFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:Hide()

    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

    -- ESC closes the panel. WoW's UIParent handles any frame listed in the
    -- global UISpecialFrames table — it calls :Hide() on each when the player
    -- presses Escape and no higher-priority frame captures the key.
    table.insert(UISpecialFrames, "HeroHelperConfigFrame")

    -- Keep our visibility flag in sync when the frame is hidden via ESC or
    -- via any other external mechanism.
    frame:SetScript("OnHide", function() configState.visible = false end)
    frame:SetScript("OnShow", function() configState.visible = true end)

    if frame.SetBackdrop then
        frame:SetBackdrop({
            bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 8,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        frame:SetBackdropColor(D.bg[1], D.bg[2], D.bg[3], D.bgA)
        frame:SetBackdropBorderColor(D.border[1], D.border[2], D.border[3], D.borA)
    else
        local bg = frame:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(D.bg[1], D.bg[2], D.bg[3], D.bgA)
    end

    -- Title
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -PADDING)
    title:SetText("|cFFFF7D1AHeroHelper|r  |cFF66666BSettings|r")

    -- Close button
    local closeBtn = CreateFrame("Button", nil, frame)
    closeBtn:SetSize(20, 20)
    closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING + 4, -PADDING + 2)
    local closeX = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    closeX:SetAllPoints()
    closeX:SetJustifyH("CENTER")
    closeX:SetText("|cFF66666BX|r")
    closeBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    closeBtn:GetHighlightTexture():SetBlendMode("ADD")
    closeBtn:SetScript("OnClick", function() Config:Hide() end)

    -- Title divider
    local titleDiv = frame:CreateTexture(nil, "ARTWORK")
    titleDiv:SetHeight(1)
    titleDiv:SetPoint("TOPLEFT",  frame, "TOPLEFT",  PADDING, -(PADDING + 20))
    titleDiv:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PADDING, -(PADDING + 20))
    titleDiv:SetColorTexture(D.divider[1], D.divider[2], D.divider[3], D.divA)

    -- Tabs
    local tabGeneral = MakeFlatButton(frame, "General", 80, 22)
    tabGeneral:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -(PADDING + 26))
    tabGeneral:SetScript("OnClick", function() Config:SwitchTab("general") end)

    local tabBosses = MakeFlatButton(frame, "Bosses", 80, 22)
    tabBosses:SetPoint("LEFT", tabGeneral, "RIGHT", 4, 0)
    tabBosses:SetScript("OnClick", function() Config:SwitchTab("bosses") end)

    frame.tabGeneral = tabGeneral
    frame.tabBosses  = tabBosses

    -- Content panels.
    --
    -- configState.frame has to be set *before* BuildBossesTab runs — that
    -- function calls RefreshBossList at the end of setup, and RefreshBossList
    -- reads the panel via configState.frame.bossPanel. Without this ordering
    -- the initial refresh no-ops silently and the Bosses tab appears empty
    -- until the player clicks the raid dropdown once.
    configState.frame = frame

    local generalPanel = CreateFrame("Frame", nil, frame)
    generalPanel:SetPoint("TOPLEFT",  frame, "TOPLEFT",  PADDING, -(PADDING + 54))
    generalPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PADDING, PADDING)
    frame.generalPanel = generalPanel
    self:BuildGeneralTab(generalPanel)

    local bossPanel = CreateFrame("Frame", nil, frame)
    bossPanel:SetPoint("TOPLEFT",  frame, "TOPLEFT",  PADDING, -(PADDING + 54))
    bossPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PADDING, PADDING)
    bossPanel:Hide()
    frame.bossPanel = bossPanel
    self:BuildBossesTab(bossPanel)

    self:SwitchTab("general")
end

function Config:SwitchTab(tab)
    configState.tab = tab
    if not configState.frame then return end
    local f = configState.frame
    if tab == "general" then
        f.generalPanel:Show()
        f.bossPanel:Hide()
        f.tabGeneral.bg:SetColorTexture(D.accent[1]*0.3, D.accent[2]*0.3, D.accent[3]*0.3, 1)
        f.tabBosses.bg:SetColorTexture(0.10, 0.10, 0.13, 1)
    else
        f.generalPanel:Hide()
        f.bossPanel:Show()
        f.tabGeneral.bg:SetColorTexture(0.10, 0.10, 0.13, 1)
        f.tabBosses.bg:SetColorTexture(D.accent[1]*0.3, D.accent[2]*0.3, D.accent[3]*0.3, 1)
    end
end

-- ============================================================================
-- General tab
-- ============================================================================

function Config:BuildGeneralTab(panel)
    local y = 0

    local function SectionHeader(text)
        local lbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, y)
        lbl:SetText(text)
        lbl:SetTextColor(D.label[1], D.label[2], D.label[3])

        local line = panel:CreateTexture(nil, "ARTWORK")
        line:SetHeight(1)
        line:SetPoint("TOPLEFT",  panel, "TOPLEFT",  0, y - 14)
        line:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, y - 14)
        line:SetColorTexture(D.divider[1], D.divider[2], D.divider[3], D.divA)
        y = y - 22
    end

    SectionHeader("ADDON")

    -- Enabled checkbox
    local cbEnabled = MakeCheckbox(panel, "Enable HeroHelper")
    cbEnabled:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, y)
    cbEnabled:HookClick(function(checked) HH.db.settings.enabled = checked end)
    y = y - ROW_HEIGHT

    local cbMinimap = MakeCheckbox(panel, "Show minimap button")
    cbMinimap:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, y)
    cbMinimap:HookClick(function(checked)
        if checked then HH.Minimap:Show() else HH.Minimap:Hide() end
    end)
    y = y - ROW_HEIGHT

    -- Master toggle for 5-man dungeon boss alerts. When on, every TBC
    -- dungeon boss fires a "pull" trigger; see Database.lua dungeon block
    -- and the isDungeon gate in GetTriggerConfig.
    local cbDungeons = MakeCheckbox(panel, "Alert for dungeon bosses (5-man, on pull)")
    cbDungeons:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, y)
    cbDungeons:HookClick(function(checked)
        HH.db.settings.dungeonPullAlerts = checked
    end)
    y = y - ROW_HEIGHT

    -- Role picker. Only consulted when someone in the raid runs
    -- `/hh roster lock`; lower priority wins the lock's election,
    -- and the alive-check at fire time means Primary > Secondary >
    -- Backup as deaths happen mid-fight. "Auto" means alphabetical
    -- tiebreak. Without a lock, every HeroHelper-using shaman fires
    -- their own reminder independently.
    local roleLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    roleLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, y - 2)
    roleLabel:SetText("My role:")
    roleLabel:SetTextColor(D.label[1], D.label[2], D.label[3])

    local roleItems = {
        { label = "Auto (alphabetical)", value = 99 },
        { label = "Primary",             value = 1  },
        { label = "Secondary",           value = 2  },
        { label = "Backup",              value = 3  },
    }

    local function RoleLabelFor(p)
        for _, item in ipairs(roleItems) do
            if item.value == p then return item.label end
        end
        return "Auto (alphabetical)"
    end

    local roleDD = MakeDropdown(panel, 180, roleItems, function(value)
        HH.db.settings.shamanPriority = value
    end, RoleLabelFor(HH.db.settings.shamanPriority or 99), "shamanrole")
    roleDD:SetPoint("LEFT", roleLabel, "RIGHT", 4, -2)
    y = y - ROW_HEIGHT - 6

    -- Short hint pointing at the /hh roster lock workflow.
    local rosterHint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    rosterHint:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, y)
    rosterHint:SetWidth(FRAME_WIDTH - 36)
    rosterHint:SetJustifyH("LEFT")
    rosterHint:SetText("Use /hh roster lock in raid to freeze the hero order and announce it.")
    y = y - 18

    y = y - 8
    SectionHeader("REMINDER BUTTON")

    local cbLocked = MakeCheckbox(panel, "Lock reminder button in place")
    cbLocked:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, y)
    cbLocked:HookClick(function(checked)
        HH.chardb.settings.button.locked = checked
        if HH.ReminderButton then HH.ReminderButton:ApplyLock() end
    end)
    y = y - ROW_HEIGHT

    local sizeSlider = MakeSlider(panel, "Button size", 24, 96, 2, HH.chardb.settings.button.size or 40, function(v)
        HH.chardb.settings.button.size = v
        if HH.ReminderButton then HH.ReminderButton:ApplySize() end
    end)
    sizeSlider:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, y)
    sizeSlider:SetWidth(FRAME_WIDTH - 2*PADDING - 10)
    y = y - (ROW_HEIGHT + 4)

    local resetBtn = MakeFlatButton(panel, "Reset position", 120, 22)
    resetBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, y)
    resetBtn:SetScript("OnClick", function()
        local s = HH.chardb.settings.button
        s.point         = "CENTER"
        s.relativePoint = "CENTER"
        s.x             = 0
        s.y             = 0
        if HH.ReminderButton then HH.ReminderButton:ApplyPosition() end
        HH:Print("Reminder button position reset.", HH.Colors.success)
    end)
    y = y - ROW_HEIGHT

    -- Persistent test-mode toggle. While enabled the reminder is forced
    -- visible so the user can drag it to their desired position; uncheck
    -- when done.
    local cbTest = MakeCheckbox(panel, "Test mode (show reminder for positioning)")
    cbTest:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, y)
    cbTest:HookClick(function(checked)
        if HH.ReminderButton then
            HH.ReminderButton:SetTestMode(checked)
            -- If SetTestMode refused (in combat), revert the checkbox visual
            -- so it reflects reality.
            cbTest:SetChecked(HH.ReminderButton:IsTestMode())
        end
    end)
    y = y - ROW_HEIGHT

    y = y - 8
    SectionHeader("SOUND")

    local cbSoundEnabled = MakeCheckbox(panel, "Play sound on trigger")
    cbSoundEnabled:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, y)
    cbSoundEnabled:HookClick(function(checked)
        HH.chardb.settings.soundEnabled = checked
    end)
    y = y - ROW_HEIGHT

    -- Sound picker. Same dropdown widget as the "My role" picker above,
    -- populated from LSM:List("sound") so every sound any loaded addon
    -- has registered (BigWigs, ShamanPower, Details, ...) is available.
    -- A speaker button next to the dropdown plays the currently-selected
    -- sound so you can audition without closing the menu.
    local soundLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    soundLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, y - 2)
    soundLabel:SetText("Sound:")
    soundLabel:SetTextColor(D.label[1], D.label[2], D.label[3])

    local soundList = (HH.ReminderButton and HH.ReminderButton:GetSoundList())
        or { "Raid Warning" }
    local soundItems = {}
    for _, key in ipairs(soundList) do
        table.insert(soundItems, { label = key, value = key })
    end

    local currentSound = HH.chardb.settings.sound or "Raid Warning"

    -- Per-row speaker lets the player audition each sound before
    -- committing. The onPreview callback temporarily swaps the saved
    -- sound so PreviewSound plays *this* row's sound, then restores.
    local soundDD = MakeDropdown(panel, 200, soundItems, function(value)
        HH.chardb.settings.sound = value
        if HH.ReminderButton then HH.ReminderButton:PreviewSound() end
    end, currentSound, "sound", function(value)
        if not HH.ReminderButton then return end
        local prev = HH.chardb.settings.sound
        HH.chardb.settings.sound = value
        HH.ReminderButton:PreviewSound()
        HH.chardb.settings.sound = prev
    end)
    soundDD:SetPoint("LEFT", soundLabel, "RIGHT", 4, -2)

    y = y - ROW_HEIGHT - 6

    -- Sync checkbox visuals to live saved-variable state each time the panel
    -- is shown. The checkboxes are purely visual — HookClick handles writes,
    -- this handles reads.
    panel:SetScript("OnShow", function(self)
        cbEnabled:SetChecked(HH.db.settings.enabled)
        cbMinimap:SetChecked(HH.db.settings.showMinimap ~= false)
        cbDungeons:SetChecked(HH.db.settings.dungeonPullAlerts == true)
        if roleDD and roleDD.RefreshText then
            roleDD:RefreshText(RoleLabelFor(HH.db.settings.shamanPriority or 99))
        end
        cbLocked:SetChecked(HH.chardb.settings.button.locked)
        cbSoundEnabled:SetChecked(HH.chardb.settings.soundEnabled)
        cbTest:SetChecked(HH.ReminderButton and HH.ReminderButton:IsTestMode() or false)
        if soundDD and soundDD.RefreshText then
            soundDD:RefreshText(HH.chardb.settings.sound or "Raid Warning")
        end
    end)
end

-- ============================================================================
-- Bosses tab
-- ============================================================================

function Config:BuildBossesTab(panel)
    -- Top row: raid selector dropdown
    local raidItems = {}
    for _, r in ipairs(HH.Database.RAIDS) do
        table.insert(raidItems, { label = r.name, value = r.key })
    end

    local selectedRaid = HH.Database.RAIDS[1].key
    local raidLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    raidLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
    raidLabel:SetText("Raid:")
    raidLabel:SetTextColor(D.label[1], D.label[2], D.label[3])

    -- Width trimmed from 200 to 140 so the top row can also fit the
    -- Reset / Export / Import buttons on the right without overlap.
    -- "Serpentshrine Cavern" still fits comfortably at this width.
    local raidDD = MakeDropdown(panel, 140, raidItems, function(value)
        selectedRaid = value
        Config:RefreshBossList()
    end, HH.Database.RAIDS[1].name, "raid")
    raidDD:SetPoint("LEFT", raidLabel, "RIGHT", 4, -2)

    -- Reset / Import / Export buttons (top-right of the bosses tab).
    --
    -- We wrap the click handlers in pcall so any error surfaces in chat
    -- instead of vanishing silently — a plain :SetScript("OnClick", ...)
    -- callback that raises will just produce a yellow error frame the
    -- player may have disabled. The pcall guarantees the addon at least
    -- tells you *something* happened.
    local function SafeClick(label, fn)
        local ok, err = pcall(fn)
        if not ok then
            HH:Print(label .. " failed: " .. tostring(err), HH.Colors.error)
        end
    end

    -- StaticPopup confirmation for Reset. Registered once; subsequent
    -- invocations of BuildBossesTab overwrite the same slot harmlessly.
    StaticPopupDialogs["HEROHELPER_RESET_BOSSES"] = {
        text         = "Reset all per-boss HeroHelper settings to defaults?\n\nThis clears every override (HP thresholds, timers, disabled flags) for every boss in every raid. The action cannot be undone.",
        button1      = YES or "Yes",
        button2      = NO  or "No",
        OnAccept     = function()
            HH.chardb.bosses = {}
            Config:RefreshBossList()
            HH:Print("All per-boss settings reset to database defaults.", HH.Colors.success)
        end,
        timeout      = 0,
        whileDead    = true,
        hideOnEscape = true,
        preferredIndex = 3, -- avoid taint issues with UIParent reparent
    }

    local resetBtn = MakeFlatButton(panel, "Reset", 55, 22)
    resetBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -156, 0)
    resetBtn:RegisterForClicks("LeftButtonUp")
    resetBtn:SetScript("OnClick", function()
        SafeClick("Reset", function() StaticPopup_Show("HEROHELPER_RESET_BOSSES") end)
    end)

    local exportBtn = MakeFlatButton(panel, "Export", 70, 22)
    exportBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -80, 0)
    exportBtn:RegisterForClicks("LeftButtonUp")
    exportBtn:SetScript("OnClick", function()
        SafeClick("Export", function() Config:ShowExportPopup() end)
    end)

    local importBtn = MakeFlatButton(panel, "Import", 70, 22)
    importBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -4, 0)
    importBtn:RegisterForClicks("LeftButtonUp")
    importBtn:SetScript("OnClick", function()
        SafeClick("Import", function() Config:ShowImportPopup() end)
    end)

    -- Scrollable list for boss rows
    local scrollFrame = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT",     panel, "TOPLEFT",     0, -34)
    scrollFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -24, 0)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(FRAME_WIDTH - 2*PADDING - 30, 1)
    scrollFrame:SetScrollChild(content)

    panel._scrollFrame = scrollFrame
    panel._scrollContent = content
    panel._rows = {}
    panel._getSelectedRaid = function() return selectedRaid end

    Config:RefreshBossList()
end

function Config:RefreshBossList()
    local panel = configState.frame and configState.frame.bossPanel
    if not panel then return end
    local content = panel._scrollContent
    local raidKey = panel._getSelectedRaid()

    -- Release old rows
    for _, row in ipairs(panel._rows) do row:Hide() end
    panel._rows = {}

    local y = 0
    local rowHeight = 30

    for bossID, boss in HH.Database:IterRaid(raidKey) do
        local row = CreateFrame("Frame", nil, content)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
        row:SetSize(content:GetWidth(), rowHeight)

        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.08, 0.08, 0.10, 0.6)

        -- Boss name
        local name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        name:SetPoint("LEFT", row, "LEFT", 4, 0)
        name:SetWidth(150)
        name:SetJustifyH("LEFT")
        name:SetText(boss.name)
        name:SetTextColor(D.value[1], D.value[2], D.value[3])

        -- Current trigger config (merged default + override)
        local cfg = HH.Database:GetTriggerConfig(bossID) or boss.default

        local typeItems = {
            { label = "Pull",  value = "pull" },
            { label = "HP %",  value = "hp"   },
            { label = "Time",  value = "time" },
            { label = "Skip",  value = "skip" },
            { label = "Multi", value = "any"  },
            { label = "Off",   value = "off"  },
        }

        -- Unit suffix label swapped between "%" (HP) and "s" (time) so the
        -- player can tell what the value box means at a glance.
        local unitLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        unitLabel:SetPoint("RIGHT", row, "RIGHT", -8, 0)
        unitLabel:SetTextColor(D.label[1], D.label[2], D.label[3])
        unitLabel:Hide()

        -- HP / Time edit box (shared slot, switched based on type)
        local edit = CreateFrame("EditBox", nil, row)
        edit:SetSize(50, 20)
        edit:SetPoint("RIGHT", unitLabel, "LEFT", -3, 0)
        edit:SetAutoFocus(false)
        edit:SetFontObject("GameFontHighlightSmall")
        edit:SetJustifyH("CENTER")
        edit:SetMaxLetters(3)
        local editBg = edit:CreateTexture(nil, "BACKGROUND")
        editBg:SetAllPoints()
        editBg:SetColorTexture(0.10, 0.10, 0.13, 1)
        AddThinBorder(edit, D.border[1], D.border[2], D.border[3], D.borA)

        -- "Edit..." button shown in the value slot when type is "any".
        -- Opens the compound popup for this specific boss.
        local editCompoundBtn = MakeFlatButton(row, "Edit...", 70, 20)
        editCompoundBtn:SetPoint("RIGHT", row, "RIGHT", -8, 0)
        editCompoundBtn:Hide()
        editCompoundBtn:SetScript("OnClick", function()
            Config:ShowCompoundPopup(bossID)
        end)

        local function UpdateEdit()
            -- Read-only: pull the effective config (default + any existing
            -- override) without materializing a blank override row.
            local effective = HH.Database:GetTriggerConfig(bossID) or boss.default or {}
            if effective.type == "hp" then
                edit:Show()
                edit:SetText(tostring(effective.hp or 35))
                unitLabel:SetText("%")
                unitLabel:Show()
                editCompoundBtn:Hide()
            elseif effective.type == "time" then
                edit:Show()
                edit:SetText(tostring(effective.seconds or 30))
                unitLabel:SetText("s")
                unitLabel:Show()
                editCompoundBtn:Hide()
            elseif effective.type == "any" then
                -- Compound: hide the value editor entirely and surface
                -- the per-boss popup launcher in its place.
                edit:Hide()
                unitLabel:Hide()
                editCompoundBtn:Show()
            else
                edit:Hide()
                unitLabel:Hide()
                editCompoundBtn:Hide()
            end
        end

        edit:SetScript("OnEnterPressed", function(self)
            local v = tonumber(self:GetText())
            HH.chardb.bosses[bossID] = HH.chardb.bosses[bossID] or {}
            local override = HH.chardb.bosses[bossID]
            local effective = HH.Database:GetTriggerConfig(bossID) or boss.default or {}
            if effective.type == "hp" and v then
                override.hp = math.max(1, math.min(99, v))
            elseif effective.type == "time" and v then
                override.seconds = math.max(1, math.min(600, v))
            end
            self:ClearFocus()
            UpdateEdit()
        end)
        edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

        local initialLabel = "Pull"
        if cfg.type == "hp" then
            initialLabel = "HP %"
        elseif cfg.type == "time" then
            initialLabel = "Time"
        elseif cfg.type == "skip" then
            initialLabel = "Skip"
        elseif cfg.type == "any" then
            initialLabel = "Multi"
        elseif cfg.type == "off" then
            initialLabel = "Off"
        end

        local typeDD = MakeDropdown(row, 80, typeItems, function(value)
            if value == "any" then
                Config:ShowCompoundPopup(bossID)
                return
            end
            HH.chardb.bosses[bossID] = HH.chardb.bosses[bossID] or {}
            local override = HH.chardb.bosses[bossID]
            if value == "off" then
                override.enabled    = false
                override.type       = nil
                override.conditions = nil
            else
                override.enabled    = true
                override.type       = value
                override.conditions = nil  -- leaving compound clears the list
                if value == "hp"    and not override.hp      then override.hp      = boss.default.hp      or 35 end
                if value == "time"  and not override.seconds then override.seconds = boss.default.seconds or 30 end
            end
            UpdateEdit()
        end, initialLabel)
        typeDD:SetPoint("LEFT", name, "RIGHT", 0, -2)

        UpdateEdit()

        table.insert(panel._rows, row)
        y = y - rowHeight - 2
    end

    content:SetHeight(math.max(-y, 1))
end

-- ============================================================================
-- Show / hide / toggle
-- ============================================================================

function Config:Show()
    if not configState.frame then self:CreateFrame() end
    configState.frame:Show()
    configState.visible = true
end

function Config:Hide()
    if configState.frame then
        configState.frame:Hide()
    end
    configState.visible = false
end

function Config:Toggle()
    if configState.visible then self:Hide() else self:Show() end
end

-- ============================================================================
-- Import / Export popup
-- ============================================================================
--
-- A single shared popup frame used for both export and import. In export
-- mode, the edit box is read-only and pre-filled with the serialized config
-- string; the user clicks CTRL+A / CTRL+C to copy. In import mode, the edit
-- box is writable and the [Import] button parses the contents.

local popup

local function CreatePopup()
    if popup then return popup end

    local f = CreateFrame("Frame", "HeroHelperIOPopup", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    -- Sized to comfortably fit the full DB hash (~900 base64 chars, which
    -- wraps to ~7 lines at this width) plus headroom for the title,
    -- help line and action row.
    f:SetSize(520, 360)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:Hide()

    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 8,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        f:SetBackdropColor(D.bg[1], D.bg[2], D.bg[3], D.bgA)
        f:SetBackdropBorderColor(D.border[1], D.border[2], D.border[3], D.borA)
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", PADDING, -PADDING)
    f.title = title

    local help = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    help:SetPoint("TOPLEFT", f, "TOPLEFT", PADDING, -PADDING - 16)
    help:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PADDING, -PADDING - 16)
    help:SetJustifyH("LEFT")
    help:SetTextColor(D.label[1], D.label[2], D.label[3])
    f.help = help

    -- Multi-line-ish edit box (TBC Classic has a working ScrollingEditBox,
    -- but for our short single-line share strings a plain EditBox is enough;
    -- we just widen it and disable autofocus).
    --
    -- The background lives on a real Frame rather than a bare Texture so
    -- AddThinBorder can hang its four edge textures on it — textures have
    -- no CreateTexture method, which was the original silent crash.
    local editBox = CreateFrame("Frame", nil, f)
    editBox:SetPoint("TOPLEFT",     f, "TOPLEFT",     PADDING, -PADDING - 44)
    editBox:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PADDING,  PADDING + 28)
    local editBg = editBox:CreateTexture(nil, "BACKGROUND")
    editBg:SetAllPoints(editBox)
    editBg:SetColorTexture(0.07, 0.07, 0.09, 1)
    AddThinBorder(editBox, D.border[1], D.border[2], D.border[3], D.borA)

    local edit = CreateFrame("EditBox", nil, editBox)
    edit:SetPoint("TOPLEFT",     editBox, "TOPLEFT",     4,  -4)
    edit:SetPoint("BOTTOMRIGHT", editBox, "BOTTOMRIGHT", -4,  4)
    edit:SetFontObject("GameFontHighlightSmall")
    edit:SetAutoFocus(false)
    edit:SetMultiLine(true)
    edit:SetMaxLetters(4096)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus(); f:Hide() end)
    f.edit = edit

    -- Action button (changes label + behavior depending on mode)
    local actionBtn = MakeFlatButton(f, "OK", 110, 22)
    actionBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PADDING - 120, PADDING)
    f.actionBtn = actionBtn

    local closeBtn = MakeFlatButton(f, "Close", 110, 22)
    closeBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PADDING, PADDING)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- ESC closes
    table.insert(UISpecialFrames, "HeroHelperIOPopup")

    popup = f
    return f
end

function Config:ShowExportPopup()
    local f = CreatePopup()
    f.title:SetText("|cFFFF7D1AHeroHelper|r  |cFF66666BExport Hash|r")
    f.help:SetText("Copy this hash (Ctrl+A, Ctrl+C) and share it with your raid.")

    local str = HH.Database:ExportHash()
    f.edit:SetText(str)
    f.edit:HighlightText()
    f.edit:SetFocus()

    f.actionBtn.label:SetText("Select All")
    f.actionBtn:SetScript("OnClick", function()
        f.edit:SetFocus()
        f.edit:HighlightText()
    end)

    f:Show()
    f:Raise()
end

function Config:ShowImportPopup()
    local f = CreatePopup()
    f.title:SetText("|cFFFF7D1AHeroHelper|r  |cFF66666BImport Hash|r")
    f.help:SetText("Paste an import hash below, then click Apply. Existing per-boss settings will be overwritten.")
    f.edit:SetText("")
    f.edit:SetFocus()

    f.actionBtn.label:SetText("Apply")
    f.actionBtn:SetScript("OnClick", function()
        local str = f.edit:GetText()
        local ok, applied, skipped, err = HH.Database:ImportHash(str)
        if not ok then
            HH:Print("Import failed: " .. tostring(err), HH.Colors.error)
            return
        end
        HH:Print(string.format("Imported %d boss entries (%d skipped).", applied, skipped), HH.Colors.success)
        Config:RefreshBossList()
        f:Hide()
    end)

    f:Show()
    f:Raise()
end

-- ============================================================================
-- Compound trigger editor popup
-- ============================================================================
--
-- Lets the player build a compound (any-of) trigger for a single boss
-- via three checkboxes (Pull / HP / Time) with inline value editors.
-- Save writes a { type = "any", conditions = {...} } override into
-- HH.chardb.bosses[bossID]; Cancel reverts the dropdown change if the
-- boss didn't already have compound conditions.
--
-- The popup is a single shared frame; ShowCompoundPopup re-binds it to
-- whichever boss the player is editing.

local compoundPopup = nil

local function CreateCompoundPopup()
    if compoundPopup then return compoundPopup end

    local f = CreateFrame("Frame", "HeroHelperCompoundPopup", UIParent,
        BackdropTemplateMixin and "BackdropTemplate" or nil)
    -- Width: the checkbox helper produces a 260 px hit container, then
    -- we anchor the value editors to the popup's right edge (with their
    -- own padding). 420 leaves a comfortable gap between the longest
    -- checkbox label and the value column.
    f:SetSize(420, 230)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:Hide()

    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 8,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        f:SetBackdropColor(D.bg[1], D.bg[2], D.bg[3], D.bgA)
        f:SetBackdropBorderColor(D.border[1], D.border[2], D.border[3], D.borA)
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", PADDING, -PADDING)
    f.title = title

    local subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    subtitle:SetPoint("TOPLEFT", f, "TOPLEFT", PADDING, -PADDING - 18)
    subtitle:SetText("Trigger when ANY of the following conditions are met:")
    subtitle:SetTextColor(D.label[1], D.label[2], D.label[3])

    -- Helper to make a "checkbox + optional edit + suffix label" row.
    --
    -- The checkbox container from MakeCheckbox is fixed at 260 px wide,
    -- so we MUST NOT anchor the value editors to the checkbox's right
    -- edge — they'd overflow the popup. Instead pin the suffix label
    -- to the popup's right edge and chain the edit box from its left.
    --
    -- MakeCheckbox only installs its toggle OnClick handler when you
    -- call :HookClick(fn). We don't need a callback (the popup reads
    -- :GetChecked() at Save time), but we MUST call HookClick with a
    -- no-op so the visual toggle actually works on click.
    local function MakeRow(parent, labelText, withEdit, suffix, yOffset)
        local cb = MakeCheckbox(parent, labelText)
        cb:SetPoint("TOPLEFT", parent, "TOPLEFT", PADDING, yOffset)
        cb:HookClick(function() end) -- arm the toggle; no callback needed

        local edit, suffixLbl
        if withEdit then
            suffixLbl = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            -- yOffset - 11 vertically centers the fontstring on the
            -- 22 px-tall checkbox row.
            suffixLbl:SetPoint("RIGHT", parent, "TOPRIGHT", -PADDING, yOffset - 11)
            suffixLbl:SetText(suffix or "")
            suffixLbl:SetTextColor(D.label[1], D.label[2], D.label[3])

            edit = CreateFrame("EditBox", nil, parent)
            edit:SetSize(40, 20)
            edit:SetPoint("RIGHT", suffixLbl, "LEFT", -3, 0)
            edit:SetAutoFocus(false)
            edit:SetFontObject("GameFontHighlightSmall")
            edit:SetJustifyH("CENTER")
            edit:SetMaxLetters(3)
            local bg = edit:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(0.10, 0.10, 0.13, 1)
            AddThinBorder(edit, D.border[1], D.border[2], D.border[3], D.borA)
            edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
            edit:SetScript("OnEnterPressed",  function(self) self:ClearFocus() end)
        end
        return cb, edit, suffixLbl
    end

    f.cbPull,  _,         _          = MakeRow(f, "Pull (cast immediately on engage)", false, nil, -PADDING - 40)
    f.cbHP,    f.editHP,  f.suffixHP = MakeRow(f, "HP percent below",                  true,  "%", -PADDING - 64)
    f.cbTime,  f.editTime, f.suffixT = MakeRow(f, "Seconds after pull",                true,  "s", -PADDING - 88)

    -- Action buttons
    local btnSave = MakeFlatButton(f, "Save", 90, 22)
    btnSave:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PADDING - 100, PADDING)
    f.btnSave = btnSave

    local btnCancel = MakeFlatButton(f, "Cancel", 90, 22)
    btnCancel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PADDING, PADDING)
    f.btnCancel = btnCancel

    table.insert(UISpecialFrames, "HeroHelperCompoundPopup")

    compoundPopup = f
    return f
end

function Config:ShowCompoundPopup(bossID)
    local boss = HH.Database:Get(bossID)
    if not boss then return end

    local f = CreateCompoundPopup()
    f._bossID = bossID
    f:SetScript("OnHide", function() Config:RefreshBossList() end)

    -- Changes stay in the popup until Save; Cancel leaves the saved override alone.
    -- Pre-fill from current effective config (default or existing override).
    local cfg = HH.Database:GetTriggerConfig(bossID) or boss.default
    local existing = (cfg and cfg.type == "any" and cfg.conditions) or {}
    f.cbPull:SetChecked(false)
    f.cbHP:SetChecked(false)
    f.cbTime:SetChecked(false)
    f.editHP:SetText(tostring(boss.default.hp or 25))
    f.editTime:SetText(tostring(boss.default.seconds or 60))
    for _, cond in ipairs(existing) do
        if cond.type == "pull" then
            f.cbPull:SetChecked(true)
        elseif cond.type == "hp" then
            f.cbHP:SetChecked(true)
            f.editHP:SetText(tostring(cond.hp or 25))
        elseif cond.type == "time" then
            f.cbTime:SetChecked(true)
            f.editTime:SetText(tostring(cond.seconds or 60))
        end
    end

    f.title:SetText("|cFFFF7D1AHeroHelper|r  " .. boss.name)

    f.btnSave:SetScript("OnClick", function()
        local conditions = {}
        if f.cbPull:GetChecked() then
            conditions[#conditions + 1] = { type = "pull" }
        end
        if f.cbHP:GetChecked() then
            local v = tonumber(f.editHP:GetText()) or 25
            conditions[#conditions + 1] = { type = "hp", hp = math.max(1, math.min(99, v)) }
        end
        if f.cbTime:GetChecked() then
            local v = tonumber(f.editTime:GetText()) or 60
            conditions[#conditions + 1] = { type = "time", seconds = math.max(1, math.min(600, v)) }
        end

        if #conditions == 0 then
            HH:Print("Compound trigger needs at least one condition.", HH.Colors.warning)
            return
        end

        HH.chardb.bosses[bossID] = HH.chardb.bosses[bossID] or {}
        local o = HH.chardb.bosses[bossID]
        o.enabled    = true
        o.type       = "any"
        o.conditions = conditions
        -- Clear single-type fields so they don't bleed through.
        o.hp      = nil
        o.seconds = nil

        f:Hide()
    end)

    f.btnCancel:SetScript("OnClick", function()
        f:Hide()
    end)

    f:Show()
    f:Raise()
end
