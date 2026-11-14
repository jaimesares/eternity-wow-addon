-- A module's page, built from its schema: the Enabled switch and General, Appearance and module
-- tabs. A group's "tab" field places it; a module tab with `groups` lists them in a picker and
-- shows one at a time, with an optional live preview above (the picker goes on the left, or on
-- top with `picker = "top"`). A tab that draws itself (`build`) may name in `paths` the options
-- it sets, which then leave General and Appearance. Rows only exist for tabs that open.
---@type string, table
local _, ns = ...
local L = ns.L
local E = EternityUI
local Widgets = E.Widgets

local ModulePage = {}
ns.ModulePage = ModulePage

local ROW = 44
local CAPTION = 30

-- visibleWhen = { [path] = value } or { [path] = { value, value } }: every path must match (one of
-- its values when there is a list).
local function matches(value, wanted)
    if type(wanted) ~= "table" then
        return value == wanted
    end
    for _, candidate in ipairs(wanted) do
        if value == candidate then
            return true
        end
    end
    return false
end

local function isVisible(module, option)
    for path, wanted in pairs(option.visibleWhen or {}) do
        if not matches(E.store:Get(module.name, path), wanted) then
            return false
        end
    end
    return true
end

local function format(option)
    local digits = option.step < 1 and (option.step < 0.1 and 2 or 1) or 0
    return function(value)
        return string.format("%." .. digits .. "f", value)
    end
end

local function newControl(parent, option, onChange)
    if option.type == "toggle" then
        return Widgets.Toggle(parent, onChange)
    elseif option.type == "range" then
        return Widgets.Slider(parent, option.min, option.max, option.step, format(option), onChange)
    elseif option.type == "select" then
        local choices = {}
        for i, entry in ipairs(option.values) do
            choices[i] = { entry.value, E.Localize(entry.label) }
        end
        return Widgets.Dropdown(parent, choices, onChange)
    elseif option.type == "color" then
        return Widgets.Color(parent, onChange)
    end
    local box = Widgets.Input(parent, onChange)
    box:SetWidth(240)
    return box
end

-- The options of a group as { path, option } entries.
local function entriesOf(group)
    local entries = {}
    for _, option in ipairs(group.options) do
        entries[#entries + 1] = { path = group.id .. "." .. option.id, option = option }
    end
    return entries
end

-- One list of sections in a scroll area. A section is { label, entries }.
local function newList(parent, page, sections)
    local scroll = Widgets.Scroll(parent)
    local list = { scroll = scroll, items = {} }
    local child = scroll.child
    for _, section in ipairs(sections) do
        local caption = Widgets.Text(child, 13, "muted")
        caption:SetText(E.Localize(section.label):upper())
        table.insert(list.items, { caption = caption })
        for _, entry in ipairs(section.entries) do
            local path, option = entry.path, entry.option
            local control = newControl(child, option, function(value)
                E.store:Set(page.module.name, path, value)
                if option.type ~= "range" then
                    page.Refresh()
                end
            end)
            local label = E.Localize(option.label)
            if option.requiresReload then
                label = label .. " (/reload)"
            end
            local row = Widgets.Row(child, label, control)
            row:SetHeight(ROW)
            -- The option's description, in the "i" beside its label.
            local description = option.description and E.Localize(option.description)
            if description and description ~= "" then
                row.info = Widgets.Info(row, E.Localize(option.label), description)
                row.info:SetPoint("LEFT", row.label, "RIGHT", 6, 0)
            end
            table.insert(list.items, { row = row, control = control, option = option, path = path })
        end
    end
    page.lists[#page.lists + 1] = list
    return list
end

local function refreshList(list, module)
    local y = 0
    for _, item in ipairs(list.items) do
        if item.caption then
            item.caption:ClearAllPoints()
            item.caption:SetPoint("TOPLEFT", 0, y - 12)
            y = y - CAPTION
        else
            local shown = isVisible(module, item.option)
            item.row:SetShown(shown)
            if shown then
                local value = E.store:Get(module.name, item.path)
                if item.control.SetValue then
                    item.control:SetValue(value)
                elseif not item.control:HasFocus() then
                    item.control:SetText(value)
                end
                item.row:ClearAllPoints()
                item.row:SetPoint("TOPLEFT", 0, y)
                item.row:SetPoint("TOPRIGHT", 0, y)
                item.y = -y
                y = y - ROW
            end
        end
    end
    list.scroll:SetContentHeight(-y + 8)
end

-- A tab with a picker: buttons on the left, the chosen view on the right; or, with
-- tab.picker = "top", a row of choices on top and the view under it, full width. views = { { id,
-- text, sections } }. tab.onPick(id) is told when another view is chosen.
local TOP_PICKER = 30 + 14

local function buildPicked(tab, frame, page, views)
    local top = 0
    if tab.preview then
        page.preview = tab.preview(frame)
        page.preview:SetPoint("TOPLEFT")
        page.preview:SetPoint("TOPRIGHT")
        top = -page.preview:GetHeight() - 12
    end
    page.pickButtons = {}
    page.pickLists = {}
    local onTop = tab.picker == "top"
    local holder = CreateFrame("Frame", nil, frame)
    holder:SetPoint("TOPLEFT", onTop and 0 or 186, onTop and top - TOP_PICKER or top)
    holder:SetPoint("BOTTOMRIGHT")
    local byView = {}
    for _, view in ipairs(views) do
        byView[view.id] = view
    end

    local segmented
    function page.Pick(id)
        page.picked = id
        for key, button in pairs(page.pickButtons) do
            button:SetActive(key == id)
        end
        if segmented then
            segmented:SetValue(id)
        end
        if not page.pickLists[id] then
            local list = newList(holder, page, byView[id].sections)
            list.scroll:SetAllPoints()
            page.pickLists[id] = list
        end
        for key, list in pairs(page.pickLists) do
            list.scroll:SetShown(key == id)
        end
        page.Refresh()
        if tab.onPick then
            tab.onPick(id)
        end
    end

    if onTop then
        local choices = {}
        for _, view in ipairs(views) do
            choices[#choices + 1] = { view.id, view.text }
        end
        segmented = Widgets.Segmented(frame, choices, page.Pick)
        segmented:SetPoint("TOPLEFT", 0, top)
        page.Pick(views[1].id)
        return
    end

    for i, view in ipairs(views) do
        local button = Widgets.Button(frame, view.text, "nav", function()
            page.Pick(view.id)
        end)
        button:SetSize(84, 32)
        local column, row = (i - 1) % 2, math.floor((i - 1) / 2)
        button:SetPoint("TOPLEFT", column * 90, top - row * 36)
        page.pickButtons[view.id] = button
    end
    page.Pick(views[1].id)
end

-- The views of a picker tab. `groups` shows whole schema groups, one per view. `views` gathers
-- options of several groups: { id, text, sections = { { label, paths } or { group } } }. Stored
-- paths don't change. Options used here are marked in `used` and leave General and Appearance.
local function viewsOf(tab, byId, byPath, used)
    local views = {}
    for _, id in ipairs(tab.groups or {}) do
        local group = byId[id]
        views[#views + 1] = {
            id = id,
            text = tab.short and tab.short[id] or E.Localize(group.label),
            sections = { { label = group.label, entries = entriesOf(group) } },
        }
        for _, entry in ipairs(views[#views].sections[1].entries) do
            used[entry.path] = true
        end
    end
    for _, view in ipairs(tab.views or {}) do
        local sections = {}
        for _, section in ipairs(view.sections) do
            local group = section.group and byId[section.group]
            local entries = group and entriesOf(group) or {}
            for _, path in ipairs(section.paths or {}) do
                entries[#entries + 1] = byPath[path]
            end
            for _, entry in ipairs(entries) do
                used[entry.path] = true
            end
            sections[#sections + 1] = { label = section.label or group.label, entries = entries }
        end
        views[#views + 1] = { id = view.id, text = view.text, sections = sections }
    end
    return views
end

-- Where the module's options go: General, Appearance (lists of sections) and the tabs' views.
local function placeOptions(module)
    local byId, byPath, used = {}, {}, {}
    for _, group in ipairs(module.schema.groups) do
        byId[group.id] = group
        for _, entry in ipairs(entriesOf(group)) do
            byPath[entry.path] = entry
        end
    end
    local tabViews = {}
    for _, tab in ipairs(module.tabs or {}) do
        for _, path in ipairs(tab.paths or {}) do
            used[path] = true
        end
        if tab.groups or tab.views then
            tabViews[tab] = viewsOf(tab, byId, byPath, used)
        end
    end
    -- What's left goes to General and Appearance, by group.
    local general, appearance = {}, {}
    for _, group in ipairs(module.schema.groups) do
        local entries = {}
        for _, entry in ipairs(entriesOf(group)) do
            if not used[entry.path] then
                entries[#entries + 1] = entry
            end
        end
        if #entries > 0 then
            local section = { label = group.label, entries = entries }
            table.insert(group.tab == "appearance" and appearance or general, section)
        end
    end
    return general, appearance, tabViews
end

local function build(page, frame)
    local module = page.module
    local general, appearance, tabViews = placeOptions(module)

    page.lists = {}
    page.views = {}
    page.tabs = {}
    local choices = {}
    local function addTab(key, text, fill)
        choices[#choices + 1] = { key, text }
        local tabFrame = CreateFrame("Frame", nil, frame)
        tabFrame:SetPoint("TOPLEFT", 0, -42)
        tabFrame:SetPoint("BOTTOMRIGHT")
        tabFrame:Hide()
        page.tabs[key] = { frame = tabFrame, fill = fill }
    end
    local function addList(groups)
        return function(tabFrame)
            newList(tabFrame, page, groups).scroll:SetAllPoints()
        end
    end
    if #general > 0 then
        addTab("general", L.TAB_GENERAL, addList(general))
    end
    if #appearance > 0 then
        addTab("appearance", L.TAB_APPEARANCE, addList(appearance))
    end
    for _, tab in ipairs(module.tabs or {}) do
        addTab(tab.key, tab.text, function(tabFrame)
            if tab.build then
                -- A tab that draws itself: build(parent, setHeight) returns its view.
                local scroll = Widgets.Scroll(tabFrame)
                scroll:SetAllPoints()
                page.views[#page.views + 1] = tab.build(scroll.child, function(height)
                    scroll:SetContentHeight(height)
                end)
            else
                buildPicked(tab, tabFrame, page, tabViews[tab])
            end
        end)
    end

    function page.ShowTab(key)
        page.current = key
        for name, entry in pairs(page.tabs) do
            if name == key and entry.fill then
                entry.fill(entry.frame)
                entry.fill = nil
            end
            entry.frame:SetShown(name == key)
        end
        page.selector:SetValue(key)
        page.Refresh()
        if ns.Window.current == page then
            ns.Window.RefreshHeader()
        end
    end

    page.selector = Widgets.Segmented(frame, choices, page.ShowTab)
    page.selector:SetPoint("TOPLEFT")

    page.enabled = Widgets.Toggle(frame, function(value)
        E.store:SetModuleEnabled(module.name, value)
    end)
    page.enabled:SetPoint("TOPRIGHT", 0, -5)
    local label = Widgets.Text(frame, 14, "muted")
    label:SetPoint("RIGHT", page.enabled, "LEFT", -10, 0)
    label:SetText(L.ENABLED)

    -- Mover with only this module's elements, while it has some (the usual Mover isn't touched).
    page.mover = Widgets.Button(frame, L.MOVER_THIS, "ghost", function()
        ns.MoverSession.OpenFor(module.name)
    end)
    page.mover:SetPoint("RIGHT", label, "LEFT", -14, 0)
    Widgets.AttachTooltip(page.mover, function(tip)
        tip:SetTitle(L.MOVER_THIS)
        tip:AddLine(L.MOVER_THIS_HINT, "textMuted")
    end)

    -- Buttons the module adds beside the switch: { text, onClick }.
    local anchor = page.mover
    for _, action in ipairs(module.actions or {}) do
        local button = Widgets.Button(frame, action.text, "ghost", action.onClick)
        button:SetPoint("RIGHT", anchor, "LEFT", -14, 0)
        anchor = button
    end

    -- The module's chosen tab first, or the last one.
    local first = choices[#choices][1]
    if module.defaultTab and page.tabs[module.defaultTab] then
        first = module.defaultTab
    end
    page.ShowTab(first)
end

-- What a search should find in an option besides its label.
local function extraText(option, section)
    local parts = { E.Localize(section.label) }
    if option.description then
        parts[#parts + 1] = E.Localize(option.description)
    end
    for _, entry in ipairs(option.values or {}) do
        parts[#parts + 1] = E.Localize(entry.label)
    end
    return table.concat(parts, " ")
end

-- The search entries of a module's page: every option, and the tabs that draw themselves.
local function entriesOfPage(page)
    local module = page.module
    local general, appearance, tabViews = placeOptions(module)
    local entries = {}
    local function addSections(sections, tab, where, view)
        for _, section in ipairs(sections) do
            for _, entry in ipairs(section.entries) do
                entries[#entries + 1] = {
                    label = E.Localize(entry.option.label),
                    extra = extraText(entry.option, section),
                    path = entry.path,
                    tab = tab,
                    view = view,
                    where = where,
                }
            end
        end
    end
    addSections(general, "general", L.TAB_GENERAL)
    addSections(appearance, "appearance", L.TAB_APPEARANCE)
    for _, tab in ipairs(module.tabs or {}) do
        if tab.build then
            entries[#entries + 1] = { label = tab.text, tab = tab.key }
        end
        for _, view in ipairs(tabViews[tab] or {}) do
            addSections(view.sections, tab.key, tab.text .. " > " .. view.text, view.id)
        end
    end
    return entries
end

--- Adds a page per registered module with options, once.
function ModulePage.AddAll()
    for _, module in ipairs(E:ListModules()) do
        if module.schema then
            local page = {
                key = module.name,
                module = module,
                title = E.Localize(module.schema.title),
                note = E.Localize(module.schema.description),
            }
            function page.Build(frame)
                build(page, frame)
            end
            function page.Refresh()
                if not page.lists then
                    return
                end
                page.enabled:SetValue(E.store:IsModuleEnabled(module.name))
                page.mover:SetShown(ns.MoverSession.HasElements(module.name))
                for _, list in ipairs(page.lists) do
                    refreshList(list, module)
                end
                if page.preview and page.picked then
                    page.preview:Refresh(page.picked)
                end
                for _, view in ipairs(page.views) do
                    if view:IsVisible() then
                        view:Refresh()
                    end
                end
            end
            -- The open tab's description (a tab that draws itself may have one, or a function
            -- that returns it), under the module's own in the "i" beside the title.
            function page.Sections()
                for _, tab in ipairs(module.tabs or {}) do
                    if tab.key == page.current and tab.description then
                        local text = tab.description
                        if type(text) == "function" then
                            text = text()
                        end
                        return { { tab.text, text } }
                    end
                end
            end
            function page.Select(tab, group)
                if tab and page.tabs[tab] then
                    page.ShowTab(tab)
                end
                if group and page.Pick then
                    page.Pick(group)
                end
            end
            function page.Entries()
                return entriesOfPage(page)
            end
            -- An option hidden by visibleWhen has no row to show: its tab stays open.
            function page.Reveal(path)
                for _, list in ipairs(page.lists) do
                    for _, item in ipairs(list.items) do
                        if item.path == path and item.row:IsVisible() then
                            list.scroll:ScrollTo(item.y - ROW)
                            ns.Search.Flash(item.row)
                            return
                        end
                    end
                end
            end
            ns.Window.AddPage(page)
        end
    end
end
