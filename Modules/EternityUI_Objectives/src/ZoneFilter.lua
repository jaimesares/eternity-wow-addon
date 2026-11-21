-- EternityUI_Objectives: "This zone only", a button left of the tracker's collapse button (where
-- Blizzard's own unused FilterButton would sit). While it's on, the tracker watches only the quests
-- of the zone you're in, and follows you from zone to zone.
--   * It changes what's watched with C_QuestLog.AddQuestWatch / RemoveQuestWatch, as Blizzard's
--     tracker does (not protected). The tracker itself isn't touched.
--   * A quest is of the zone when its quest log header is the zone's name (GetRealZoneText) or the
--     game puts it on the current map (C_QuestLog.IsOnMap).
--   * What it took out and put in is remembered per character (EternityUIObjectivesDB), so turning
--     it off, disabling the module or the option gives your own choice back, also after /reload.
--     Quests you track by hand meanwhile are left alone until the next zone change.
--   * Quests under a header collapsed in the quest log aren't listed by the game: those can only
--     be taken out (when watched), not added.

---@type string, EternityUIObjectivesNamespace
local _, ns = ...
local Core, L = ns.Core, ns.L
local W, Theme = ns.Ui.W, ns.Ui.Theme

local ICON = "Interface\\Icons\\INV_Misc_Map_01"

---@class EternityUIObjectivesZoneFilter
---@field button table? the header button, once made
---@field events table?
---@field active boolean? enabled module and option
local ZoneFilter = {}
ns.ZoneFilter = ZoneFilter

local function maxWatches()
    -- Blizzard's Constants table (from the client's API, used by Blizzard_ObjectiveTracker).
    local consts = _G.Constants and _G.Constants.QuestWatchConsts
    return consts and consts.MAX_QUEST_WATCHES or 25
end

local function watched(questID)
    return C_QuestLog.GetQuestWatchType(questID) ~= nil
end

-- This character's state: { on, removed = { [questID] = true }, added = { [questID] = true } }.
function ZoneFilter.State()
    local db = _G.EternityUIObjectivesDB
    if type(db) ~= "table" or type(db.chars) ~= "table" then
        db = { chars = {} }
        _G.EternityUIObjectivesDB = db
    end
    -- The realm from the core: Forever's GetRealmName can answer "".
    local name, realm = UnitName("player"), EternityUI.RealmName()
    local key = (not Core.Secret(name) and name or "?") .. "-" .. (realm or "?")
    local state = db.chars[key]
    if type(state) ~= "table" then
        state = {}
        db.chars[key] = state
    end
    state.removed = type(state.removed) == "table" and state.removed or {}
    state.added = type(state.added) == "table" and state.added or {}
    return state
end

--- Whether "This zone only" is on for this character.
function ZoneFilter.IsOn()
    return ZoneFilter.State().on == true
end

--- Every quest the log lists, with the header it sits under: { [questID] = header }. Watched
--- quests the log doesn't list (collapsed header) are added with header false.
function ZoneFilter.Quests()
    local quests, header = {}, false
    local count = C_QuestLog.GetNumQuestLogEntries() or 0
    for index = 1, count do
        local info = C_QuestLog.GetInfo(index)
        if info then
            if info.isHeader then
                header = info.title or false
            elseif info.questID and not info.isHidden then
                quests[info.questID] = header
            end
        end
    end
    for index = 1, C_QuestLog.GetNumQuestWatches() or 0 do
        local questID = C_QuestLog.GetQuestIDForQuestWatchIndex(index)
        if questID and quests[questID] == nil then
            quests[questID] = false
        end
    end
    return quests
end

--- Whether a quest belongs to the zone.
---@param questID number
---@param header string|false its quest log header
---@param zone string GetRealZoneText()
function ZoneFilter.InZone(questID, header, zone)
    if header and header == zone then
        return true
    end
    local ok, onMap = pcall(C_QuestLog.IsOnMap, questID)
    return ok and onMap == true
end

--- Leaves watched only the quests of the zone you're in.
function ZoneFilter.Filter()
    local zone = GetRealZoneText()
    if type(zone) ~= "string" or zone == "" or Core.Secret(zone) then
        return
    end
    local state = ZoneFilter.State()
    local quests = ZoneFilter.Quests()
    -- In order, so the same log gives the same result when the tracker is full.
    local ids = {}
    for questID in pairs(quests) do
        ids[#ids + 1] = questID
    end
    table.sort(ids)
    -- Out first, so there's room for the zone's quests.
    for _, questID in ipairs(ids) do
        if not ZoneFilter.InZone(questID, quests[questID], zone) and watched(questID) then
            C_QuestLog.RemoveQuestWatch(questID)
            if state.added[questID] then
                state.added[questID] = nil
            else
                state.removed[questID] = true
            end
        end
    end
    for _, questID in ipairs(ids) do
        if ZoneFilter.InZone(questID, quests[questID], zone) and not watched(questID) then
            if (C_QuestLog.GetNumQuestWatches() or 0) >= maxWatches() then
                break
            end
            C_QuestLog.AddQuestWatch(questID)
            if state.removed[questID] then
                state.removed[questID] = nil
            else
                state.added[questID] = true
            end
        end
    end
end

--- Gives your own choice back: what was taken out goes back in, what was put in comes out.
function ZoneFilter.Restore()
    local state = ZoneFilter.State()
    for questID in pairs(state.added) do
        if watched(questID) then
            C_QuestLog.RemoveQuestWatch(questID)
        end
    end
    for questID in pairs(state.removed) do
        if C_QuestLog.IsOnQuest(questID) and not watched(questID) then
            C_QuestLog.AddQuestWatch(questID)
        end
    end
    state.added, state.removed = {}, {}
end

--- Turns "This zone only" on or off for this character.
---@param on boolean
function ZoneFilter.Set(on)
    ZoneFilter.State().on = on and true or false
    if ZoneFilter.active then
        if on then
            ZoneFilter.Filter()
        else
            ZoneFilter.Restore()
        end
    end
    ZoneFilter.Paint()
end

-- Button ----------------------------------------------------------------------------------------------

--- Colors the button: accent while on, muted while off.
function ZoneFilter.Paint()
    local button = ZoneFilter.button
    if button then
        local r, g, b = Theme.Color(ZoneFilter.IsOn() and "accent" or "textMuted")
        button.icon:SetVertexColor(r, g, b, 1)
    end
end

local function makeButton(header)
    local button = CreateFrame("Button", nil, header)
    button:SetSize(16, 16)
    button:SetPoint("RIGHT", header.MinimizeButton, "LEFT", -2, 0)
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetPoint("CENTER")
    button.icon:SetSize(13, 13)
    button.icon:SetTexture(ICON)
    button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    button.icon:SetDesaturated(true)
    button:SetScript("OnClick", function()
        ZoneFilter.Set(not ZoneFilter.IsOn())
    end)
    W.AttachTooltip(button, function(tip)
        tip:SetTitle(L.ZONE_ONLY)
        tip:AddLine(ZoneFilter.IsOn() and L.ZONE_ONLY_ON or L.ZONE_ONLY_OFF, "textMuted")
    end)
    -- Blizzard hides its collapse button while a gamepad drives the UI: this one follows it.
    header.MinimizeButton:HookScript("OnShow", function()
        button:SetShown(ZoneFilter.active == true)
    end)
    header.MinimizeButton:HookScript("OnHide", function()
        button:Hide()
    end)
    return button
end

-- Lifecycle -------------------------------------------------------------------------------------------

local function onEvent(_, event)
    if not (ZoneFilter.active and ZoneFilter.IsOn()) then
        return
    end
    if event == "PLAYER_ENTERING_WORLD" then
        -- The quest log may still be loading right after a loading screen.
        C_Timer.After(1, function()
            if ZoneFilter.active and ZoneFilter.IsOn() then
                ZoneFilter.Filter()
            end
        end)
    else
        ZoneFilter.Filter()
    end
end

--- Applies the module's state and the option to the tracker: button, events and filter.
---@param tracker table
function ZoneFilter.Apply(tracker)
    local header = tracker and tracker.Header
    local wanted = Core.running and Core.Opt("info.zoneButton") and true or false
    if wanted and header and header.MinimizeButton and not ZoneFilter.button then
        ZoneFilter.button = makeButton(header)
    end
    if not ZoneFilter.events then
        ZoneFilter.events = CreateFrame("Frame")
        ZoneFilter.events:SetScript("OnEvent", onEvent)
    end
    local was = ZoneFilter.active
    ZoneFilter.active = wanted
    if wanted then
        ZoneFilter.events:RegisterEvent("ZONE_CHANGED_NEW_AREA")
        ZoneFilter.events:RegisterEvent("PLAYER_ENTERING_WORLD")
        if not was and ZoneFilter.IsOn() then
            ZoneFilter.Filter()
        end
    else
        ZoneFilter.events:UnregisterAllEvents()
        if was then
            ZoneFilter.Restore()
        end
    end
    if ZoneFilter.button then
        ZoneFilter.button:SetShown(wanted and header.MinimizeButton:IsShown())
        ZoneFilter.Paint()
    end
end

--- The module is off: your own choice back, button hidden. "On" stays saved for next time.
function ZoneFilter.Stop()
    if ZoneFilter.events then
        ZoneFilter.events:UnregisterAllEvents()
    end
    if ZoneFilter.active then
        ZoneFilter.Restore()
    end
    ZoneFilter.active = false
    if ZoneFilter.button then
        ZoneFilter.button:Hide()
    end
end
