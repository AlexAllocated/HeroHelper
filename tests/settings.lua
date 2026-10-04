return function(H)
    local function database(overrides)
        local h =
            { chardb = { bosses = overrides or {} }, db = { settings = {} }, Print = H.noop, Colors = {} }
        assert(loadfile("modules/Database.lua"))("HeroHelper", h)
        return h
    end
    H.test("compound-export", function()
        local h = database({
            kara_moroes = {
                type = "any",
                conditions = { { type = "hp", hp = 25 }, { type = "time", seconds = 90 } },
            },
        })
        local hash = h.Database:ExportHash()
        h.chardb.bosses = {}
        assert(h.Database:ImportHash(hash))
        local config = h.chardb.bosses.kara_moroes
        assert(config and config.conditions, "export must retain custom Multi triggers")
        assert(config.conditions[1].hp == 25 and config.conditions[2].seconds == 90)
    end)
    H.test("compound-default-export", function()
        local h = database({ kara_moroes = { type = "any", conditions = { { type = "hp", hp = 12 } } } })
        h.Database.BOSSES.kara_moroes.default =
            { type = "any", conditions = { { type = "time", seconds = 60 } } }
        local hash = h.Database:ExportHash()
        h.chardb.bosses = {}
        assert(h.Database:ImportHash(hash))
        local config = h.chardb.bosses.kara_moroes
        assert(config.conditions[1].hp == 12, "an edited Multi default must export its override")
    end)

    -- Replace rendering helpers while exercising the actual dropdown and popup callbacks.
    local function upvalue(fn, name, replacement)
        for i = 1, 100 do
            local key, value = debug.getupvalue(fn, i)
            if not key then
                break
            end
            if key == name then
                if replacement then
                    debug.setupvalue(fn, i, replacement)
                end
                return value
            end
        end
        error("missing upvalue " .. name)
    end
    local methods = {
        SetScript = function(self, key, callback)
            self.scripts[key] = callback
        end,
        SetText = function(self, text)
            self.text = text
        end,
        GetText = function(self)
            return self.text
        end,
        SetChecked = function(self, value)
            self.checked = value
        end,
        GetChecked = function(self)
            return self.checked
        end,
        GetWidth = function()
            return 400
        end,
        Show = function(self)
            self.shown = true
        end,
        Hide = function(self)
            if self.shown then
                self.shown = false
                if self.scripts.OnHide then
                    self.scripts.OnHide()
                end
            end
        end,
    }
    local function widget()
        return setmetatable({ scripts = {}, shown = false }, {
            __index = function(_, key)
                return methods[key] or H.noop
            end,
        })
    end
    methods.CreateTexture, methods.CreateFontString, CreateFrame = widget, widget, widget
    local function editor(override)
        local h = database({ kara_moroes = override })
        assert(loadfile("modules/Config.lua"))("HeroHelper", h)
        local ui = { popup = widget() }
        for _, key in ipairs({
            "cbPull",
            "cbHP",
            "cbTime",
            "editHP",
            "editTime",
            "title",
            "btnSave",
            "btnCancel",
        }) do
            ui.popup[key] = widget()
        end
        upvalue(h.Config.ShowCompoundPopup, "CreateCompoundPopup", function()
            return ui.popup
        end)
        upvalue(h.Config.RefreshBossList, "MakeFlatButton", widget)
        upvalue(h.Config.RefreshBossList, "MakeDropdown", function(_, _, _, select, label)
            ui.select, ui.label = select, label
            return widget()
        end)
        local state = upvalue(h.Config.RefreshBossList, "configState")
        state.frame = {
            bossPanel = {
                _scrollContent = widget(),
                _rows = {},
                _getSelectedRaid = function()
                    return "kara"
                end,
            },
        }
        local boss = h.Database:Get("kara_moroes")
        h.Database.IterRaid = function()
            local done = false
            return function()
                if not done then
                    done = true
                    return "kara_moroes", boss
                end
            end
        end
        h.Config:RefreshBossList()
        return h, ui
    end
    H.test("cancel-multi", function()
        local previous = { type = "hp", hp = 42, enabled = false }
        local h, ui = editor(previous)
        local previousLabel = ui.label
        ui.select("any")
        assert(
            h.chardb.bosses.kara_moroes == previous and previous.hp == 42 and not previous.enabled,
            "opening Multi must not change the saved override"
        )
        ui.popup.btnCancel.scripts.OnClick()
        assert(previous.type == "hp" and ui.label == previousLabel, "Cancel must restore the displayed setting")
    end)
    H.test("escape-multi", function()
        local previous = { type = "any", conditions = { { type = "hp", hp = 19 } } }
        local h, ui = editor(previous)
        ui.select("any")
        ui.popup.editHP:SetText("80")
        ui.popup:Hide() -- Escape hides the frame through UISpecialFrames.
        assert(h.chardb.bosses.kara_moroes == previous and previous.conditions[1].hp == 19)
        assert(ui.label == "Multi")
        h, ui = editor(nil)
        ui.select("any")
        ui.popup:Hide()
        assert(
            h.chardb.bosses.kara_moroes == nil and ui.label == "Pull",
            "cancel must not create an override"
        )
    end)
    H.test("save-multi", function()
        local h, ui = editor({ type = "hp", hp = 42, enabled = false })
        ui.select("any")
        ui.popup.cbHP:SetChecked(true)
        ui.popup.editHP:SetText("24")
        ui.popup.btnSave.scripts.OnClick()
        local saved = h.chardb.bosses.kara_moroes
        assert(saved.type == "any" and saved.conditions[1].hp == 24 and saved.enabled and not saved.hp)
        assert(ui.label == "Multi" and not ui.popup.shown)
    end)
end
