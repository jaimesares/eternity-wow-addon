-- EternityUI_Bags: bags and bank with the Eternity look.
--   * Bags: every bag in one window (one grid or one section per bag), with search, sort,
--     gold and free slots. Bank: the character tabs and the warband ones, with deposit.
--   * Saved view: the bags window can show another character's bags instead of this one's
--     ("Characters" in its footer), and a window built by the same code as the bank shows what
--     was saved of a bank (this character's from anywhere, another's, or the guild bank). Their
--     buttons are plain ItemButtons with the same look: nothing in them can be used.
--   * Sort: Eternity's (Locks.lua), which leaves locked slots alone, or Blizzard's
--     (windows.sortMode). Padlock (footer): while it's on, a click on an item locks its slot.
--     Blizzard's sort can't skip a slot, so with it the padlock is greyed out and the slots'
--     padlocks are hidden (the locks are kept); clicking it switches to Eternity's sort.
--   * The item buttons are Blizzard's (ContainerFrameItemButtonTemplate): clicks, drag, use,
--     sell, split and tooltips work exactly as in Blizzard's bags; only their look changes.
--   * Blizzard decides when bags open and close (vendor, mailbox, bank, keys...): its frames
--     keep working inside a hidden parent and our window mirrors whether any of them is shown.
--     The bank frame stays open (closing it ends the bank session) but invisible.
-- No taint: it replaces no Blizzard method (hooksecurefunc only) and touches no protected frame.
-- When disabled, Blizzard's frames go back to their parents, without /reload. Hooks can't be
-- removed: they're installed once and do nothing while `running` is false.

---@type string, EternityUIBagsNamespace
local addonName, ns = ...
local E = EternityUI
local Shape, Theme, Widgets = E.Shape, E.Theme, E.Widgets
local L, Inventory, Viewer, Locks = ns.L, ns.Inventory, ns.Viewer, ns.Locks
local LOCK_ICON = "Interface\\PetBattles\\PetBattle-LockIcon"

local QUALITY_FROM = { poor = 0, common = 1, uncommon = 2, rare = 3, epic = 4 }
local QUEST_COLOR = { 1, 0.82, 0.2, 1 }
local FOOTER_TEXT = 12 -- size of the gold and free slots texts
local SECTION_TITLE = 18
local ITEM_CLASS_WEAPON, ITEM_CLASS_ARMOR = 2, 4 -- Enum.ItemClass
local EVENTS = {
    "BAG_UPDATE_DELAYED",
    "BAG_CONTAINER_UPDATE",
    "ITEM_LOCK_CHANGED",
    "BAG_UPDATE_COOLDOWN",
    "INVENTORY_SEARCH_UPDATE",
    "BAG_NEW_ITEMS_UPDATED",
    "PLAYER_MONEY",
    "PLAYERBANKSLOTS_CHANGED",
    "BANK_TABS_CHANGED",
    "BANK_TAB_SETTINGS_UPDATED",
    "BANKFRAME_OPENED",
    "BANKFRAME_CLOSED",
    "GUILDBANKFRAME_OPENED",
    "GUILDBANKFRAME_CLOSED",
}
-- A bank that closes this soon after the player closed something (Esc, B, a close button)
-- was closed by them; later, it closed because they walked away.
local USER_CLOSE_WINDOW = 1
-- Events that change which slots there are (a bag or tab swapped or bought): the grid is laid
-- out again. The rest only change how the items look.
local RELAYOUT = {
    BAG_CONTAINER_UPDATE = true,
    BANK_TABS_CHANGED = true,
    BANK_TAB_SETTINGS_UPDATED = true,
}

---@class EternityUIBagsModule: EternityUIModuleDefinition
---@field running boolean?
---@field hooked boolean?
---@field bagsHidden table<table, table>? Blizzard bag frame -> its original parent
---@field bankHidden table? BankFrame's original parent while it's hidden
---@field bankOpen boolean?
---@field blizzardBank boolean? this bank visit uses Blizzard's window
---@field guildOpen boolean?
---@field bankBags boolean? the bags window is open because a bank opened it
---@field userClosedAt number? GetTime() of the player's last Esc, B or close button
---@field guildHooked boolean?
---@field bags EternityUIBagsGrid?
---@field bank EternityUIBagsGrid?
---@field inventory EternityUIBagsInventory
local Module = {
    schema = ns.OptionsSchema,
    inventory = Inventory, -- for the tests
    locks = Locks,
    viewer = ns.Viewer,
    supplies = ns.Supplies,
    L = L,
}

local function opt(path)
    return E.store:Get(addonName, path)
end

-- Whether Sort is Eternity's (it honours the locks) rather than Blizzard's.
local function ownSort()
    return opt("windows.sortMode") ~= "blizzard"
end

local function registerEvents(frame, events)
    for _, event in ipairs(events) do
        -- An event this client doesn't have errors on RegisterEvent: skip it.
        pcall(frame.RegisterEvent, frame, event)
    end
end

local function bankTypes()
    local types = Enum.BankType
    return types and types.Character, types and types.Account
end

local hider = CreateFrame("Frame")
hider:Hide()

-- Item buttons ------------------------------------------------------------------------------

--- Font file of the theme (the counts use their own size).
local function themeFontPath()
    return Theme.font
end

-- The slots' corner radius follows the theme, capped so small slots still read as squares.
local function slotRadius()
    return math.min(Theme.radius, 4)
end

local function paintSlot(shape, fill, border)
    Shape.Paint(shape, slotRadius(), fill and Theme.RGBA(fill) or nil, border and Theme.RGBA(border) or nil)
end

local function qualityColor(quality)
    if quality and C_Item.GetItemQualityColor then
        local r, g, b = C_Item.GetItemQualityColor(quality)
        if r then
            return { r, g, b, 1 }
        end
    end
end

local function itemLevel(info, bag, slot)
    if not info.itemID or not C_Item.GetItemInfoInstant then
        return nil
    end
    local _, _, _, equipLoc, _, classID = C_Item.GetItemInfoInstant(info.itemID)
    if (classID ~= ITEM_CLASS_WEAPON and classID ~= ITEM_CLASS_ARMOR) or not equipLoc or equipLoc == "" then
        return nil
    end
    if equipLoc == "INVTYPE_NON_EQUIP_IGNORE" or equipLoc == "INVTYPE_BAG" then
        return nil
    end
    local location = ItemLocation:CreateFromBagAndSlot(bag, slot)
    local level = location and location:IsValid() and C_Item.GetCurrentItemLevel(location)
    if level and level > 1 then
        return level
    end
end

--- Eternity look for a Blizzard item button (once per button).
local function skinButton(b)
    b.etBack = Shape.New(b, "BACKGROUND", -8)
    b.etBorder = Shape.New(b, "OVERLAY", 5)
    b.etLevel = b:CreateFontString(nil, "OVERLAY")
    b.etLevel:SetFont(Theme.font, 12, "OUTLINE")
    b.etLock = b:CreateTexture(nil, "OVERLAY", nil, 6)
    b.etLock:SetTexture(LOCK_ICON)
    b.etLock:SetSize(14, 14)
    b.etLock:Hide()
    local normal = b:GetNormalTexture()
    if normal then
        normal:SetAlpha(0)
    end
    b.etMask = b:CreateMaskTexture()
end

--- Rounds the icon (and the hover and pressed highlights) to the slot's corners with a fill-R
--- mask. The mask is stretched over the icon, so R is scaled from texture pixels to the icon size.
local function maskIcon(b, icon, size)
    local radius = slotRadius()
    local textures = { icon }
    for _, texture in ipairs({ b:GetHighlightTexture() or false, b:GetPushedTexture() or false }) do
        if texture then
            textures[#textures + 1] = texture
        end
    end
    if radius < 2 or size <= 2 then
        if b.etMasked then
            for _, texture in ipairs(textures) do
                texture:RemoveMaskTexture(b.etMask)
            end
            b.etMasked = false
        end
        return
    end
    local r = Shape.Nearest(math.max(4, math.min(16, math.floor((radius - 1) * 64 / (size - 2) + 0.5))))
    b.etMask:SetTexture(Theme.MEDIA .. "fill-" .. r .. ".tga", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    b.etMask:ClearAllPoints()
    b.etMask:SetAllPoints(icon)
    if not b.etMasked then
        for _, texture in ipairs(textures) do
            texture:AddMaskTexture(b.etMask)
        end
        b.etMasked = true
    end
end

--- Size, icon crop, texts and border of a button according to the options.
local function styleButton(b, size)
    b:SetSize(size, size)
    local icon = b.icon or b.Icon
    if icon then
        local crop = opt("slots.iconZoom") and 0.08 or 0
        icon:SetTexCoord(crop, 1 - crop, crop, 1 - crop)
        icon:ClearAllPoints()
        icon:SetPoint("TOPLEFT", 1, -1)
        icon:SetPoint("BOTTOMRIGHT", -1, 1)
        maskIcon(b, icon, size)
    end
    local path = themeFontPath()
    if b.Count then
        b.Count:SetFont(path, opt("slots.countSize"), "OUTLINE")
        b.Count:ClearAllPoints()
        b.Count:SetPoint("BOTTOMRIGHT", -2, 2)
    end
    b.etLevel:SetFont(path, opt("slots.itemLevelSize"), "OUTLINE")
    local corner = opt("slots.itemLevelPosition")
    local inset = corner == "CENTER" and 0 or 2
    b.etLevel:ClearAllPoints()
    b.etLevel:SetPoint(
        corner,
        corner:find("LEFT") and inset or (corner:find("RIGHT") and -inset or 0),
        corner:find("TOP") and -inset or (corner:find("BOTTOM") and inset or 0)
    )
    -- The padlock of a locked slot: bottom left, or top left when the item level is there.
    local lockCorner = corner == "BOTTOMLEFT" and "TOPLEFT" or "BOTTOMLEFT"
    b.etLock:ClearAllPoints()
    b.etLock:SetPoint(lockCorner, 1, lockCorner == "TOPLEFT" and -1 or 1)
    if b.IconBorder then
        b.IconBorder:SetAlpha(opt("quality.border") and 0 or 1)
    end
    -- The slot shape follows the theme's corners: the shapes of every button are repainted.
    paintSlot(b.etBack, "field", "border")
end

--- What Blizzard's ContainerFrameMixin:UpdateItems does for one button, plus our look.
--- Its tooltip refresh (CheckUpdateTooltip) is left out on purpose: run from here, on the bag
--- events that using an item fires while the mouse is still on it, Blizzard's UpdateTooltip runs
--- tainted and the client forbids it ("EternityUI_Bags was forbidden to call UNKNOWN()").
--- GameTooltip's own OnUpdate refreshes the owner's tooltip securely a moment later.
local function updateButton(b)
    local bag, slot = b:GetBagID(), b:GetID()
    local info = C_Container.GetContainerItemInfo(bag, slot)
    local texture = info and info.iconFileID
    local quality = info and info.quality
    local questInfo = C_Container.GetContainerItemQuestInfo and C_Container.GetContainerItemQuestInfo(bag, slot) or {}

    ClearItemButtonOverlay(b)
    b:SetHasItem(texture)
    b:SetItemButtonTexture(texture)
    SetItemButtonQuality(b, quality, info and info.hyperlink, false, info and info.isBound)
    SetItemButtonCount(b, info and info.stackCount)
    SetItemButtonDesaturated(b, info and info.isLocked)
    if b.UpdateExtended then
        b:UpdateExtended()
    end
    if b.UpdateQuestItem then
        b:UpdateQuestItem(questInfo.isQuestItem, questInfo.questID, questInfo.isActive)
    end
    b:UpdateNewItem(quality)
    b:UpdateJunkItem(quality, info and info.hasNoValue)
    if b.UpdateItemContextMatching then
        b:UpdateItemContextMatching()
    end
    b:UpdateCooldown(texture)
    if b.SetReadable then
        b:SetReadable(info and info.isReadable)
    end
    b:SetMatchesSearch(not (info and info.isFiltered))

    -- Our options on top of Blizzard's.
    if not opt("items.newItems") then
        for _, key in ipairs({ "NewItemTexture", "BattlepayItemTexture" }) do
            if b[key] then
                b[key]:Hide()
            end
        end
        for _, key in ipairs({ "flashAnim", "newitemglowAnim" }) do
            if b[key] then
                b[key]:Stop()
            end
        end
    end
    if b.JunkIcon and opt("items.junk") and info and quality == 0 and not info.hasNoValue then
        b.JunkIcon:Show()
    end

    local border
    if info and questInfo.isQuestItem and opt("quality.questBorder") then
        border = QUEST_COLOR
    elseif info and quality and opt("quality.border") and quality >= QUALITY_FROM[opt("quality.from")] then
        border = qualityColor(quality)
    end
    paintSlot(b.etBorder, nil, border)
    if border and opt("quality.glow") then
        paintSlot(b.etBack, { border[1], border[2], border[3], 0.18 }, "border")
    else
        paintSlot(b.etBack, "field", "border")
    end

    local level = info and opt("items.itemLevel") and itemLevel(info, bag, slot)
    if level then
        b.etLevel:SetText(level)
        local color = opt("items.itemLevelColor") and qualityColor(quality)
        if color then
            b.etLevel:SetTextColor(color[1], color[2], color[3])
        else
            b.etLevel:SetTextColor(1, 1, 1)
        end
    end
    b.etLevel:SetShown(level and true or false)
    b.etLock:SetShown(ownSort() and Locks.Is(bag, slot))
end

-- Grid: one window (bags or bank) -----------------------------------------------------------

---@class EternityUIBagsSection
---@field title string?
---@field bags integer[]

---@class EternityUIBagsGrid
---@field kind string "bags" | "bank" | "saved"
---@field place string? (saved view) bags, bank or guild
---@field realm string? (saved view) whose
---@field name string? (saved view) whose
---@field viewing boolean? (bags) showing another character's saved bags
---@field frame table the window
---@field content table
---@field holders table<integer, table> bagID -> frame with that ID (the buttons' parent)
---@field buttons table<integer, table[]> bagID -> slot -> item button
---@field titles table[] section title pool
---@field bankType integer? (bank) the tab shown
---@field dirty boolean? the slots must be laid out again on show
local Grid = {}
Grid.__index = Grid

function Grid:Holder(bag)
    local holder = self.holders[bag]
    if not holder then
        holder = CreateFrame("Frame", nil, self.content)
        holder:SetAllPoints()
        -- The button reads its bag from this ID (ContainerFrameItemButtonMixin:GetBagID).
        holder:SetID(bag)
        self.holders[bag] = holder
        self.buttons[bag] = {}
    end
    return holder
end

function Grid:Button(bag, slot)
    local holder = self:Holder(bag)
    local b = self.buttons[bag][slot]
    if not b then
        b = CreateFrame("ItemButton", nil, holder, "ContainerFrameItemButtonTemplate")
        skinButton(b)
        -- Not Initialize: it stores this addon's frame on the button, IsCombined then runs our
        -- code inside its click, and the taint blocks UseContainerItem.
        b:SetID(slot)
        self.buttons[bag][slot] = b
    end
    return b
end

--- Bag name for a section title.
local function bagTitle(bag)
    local index = Enum.BagIndex or {}
    if bag == index.Keyring then
        return L.KEYRING
    elseif bag == index.ReagentBag then
        return L.REAGENTS
    elseif bag == (index.Backpack or 0) then
        return L.BAGS
    end
    local name = C_Container.GetBagName and C_Container.GetBagName(bag)
    return name or L.BAG_N:format(bag)
end

-- Saved view: plain item buttons with the bank's look, filled from what was saved.

local function savedButton(self, index)
    local b = self.savedButtons[index]
    if not b then
        b = CreateFrame("ItemButton", nil, self.content)
        skinButton(b)
        b:SetScript("OnEnter", Viewer.OnEnter)
        b:SetScript("OnLeave", Viewer.OnLeave)
        b:SetScript("OnClick", Viewer.OnClick)
        self.savedButtons[index] = b
    end
    return b
end

local function savedMatches(b, needle)
    if not needle then
        return true
    end
    local _, _, name = Viewer.ItemData(b.itemID or 0)
    return b.itemID ~= nil and name ~= nil and name:lower():find(needle, 1, true) ~= nil
end

local function fillSaved(b, entry, needle)
    local id, count = entry and entry[1], entry and entry[2]
    b.itemID = id
    local icon, quality
    if id then
        icon, quality = Viewer.ItemData(id)
    end
    SetItemButtonTexture(b, icon)
    SetItemButtonCount(b, count)
    SetItemButtonQuality(b, quality, id)
    b.etLevel:Hide()
    b:SetMatchesSearch(savedMatches(b, needle))
    local border
    if id and quality and opt("quality.border") and quality >= QUALITY_FROM[opt("quality.from")] then
        border = qualityColor(quality)
    end
    paintSlot(b.etBorder, nil, border)
    if border and opt("quality.glow") then
        paintSlot(b.etBack, { border[1], border[2], border[3], 0.18 }, "border")
    else
        paintSlot(b.etBack, "field", "border")
    end
end

--- Whether this window shows saved contents (the saved bank, or the bags of another character).
function Grid:IsSaved()
    return self.kind == "saved" or self.viewing == true
end

--- The bags window shows another character's saved bags (nil, or this character: its own).
function Grid:ViewCharacter(realm, name)
    local myRealm, myName = Inventory.Me()
    if not realm or (realm == myRealm and name == myName) then
        self.viewing, self.place, self.realm, self.name = nil, nil, nil, nil
    else
        self.viewing, self.place, self.realm, self.name = true, "bags", realm, name
    end
    self:Layout()
end

function Grid:SavedNeedle()
    local text = self.search:GetText()
    return text ~= "" and text:lower() or nil
end

--- Places the saved slots like Layout does the real ones.
function Grid:LayoutSaved()
    local size, gap = opt("slots.size"), opt("slots.spacing")
    local columns = opt(self.kind == "bags" and "slots.columns" or "slots.bankColumns")
    local containers, updated, missing = Viewer.Containers(self.place, self.realm, self.name)
    if self.kind == "bags" and not opt("windows.keyring") then
        local shown = {}
        for _, container in ipairs(containers) do
            if container.kind ~= "keyring" then
                shown[#shown + 1] = container
            end
        end
        containers = shown
    end
    for _, list in pairs(self.buttons) do
        for _, b in pairs(list) do
            b:Hide()
        end
    end
    self.savedContainers, self.savedUpdated = containers, updated
    local needle = self:SavedNeedle()
    local split = opt("windows.layout") == "bags" or self.place == "guild"
    local showTitles = opt("window.sectionTitles")
    local y, used, titleIndex, i = 0, 0, 0, 0
    for index, container in ipairs(containers) do
        if split and index > 1 then
            local rows = math.ceil(i / columns)
            y = y + rows * size + math.max(rows - 1, 0) * gap + (rows > 0 and gap + 4 or 0)
            i = 0
        end
        if split and showTitles then
            titleIndex = titleIndex + 1
            local title = self:SectionTitle(titleIndex)
            title:SetText(Viewer.ContainerTitle(container, index))
            title:ClearAllPoints()
            title:SetPoint("TOPLEFT", self.content, "TOPLEFT", 0, -y)
            title:Show()
            y = y + SECTION_TITLE
        end
        for slot = 1, container.size or 0 do
            used = used + 1
            local b = savedButton(self, used)
            styleButton(b, size)
            fillSaved(b, container.slots and container.slots[slot], needle)
            local col, row = i % columns, math.floor(i / columns)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", self.content, "TOPLEFT", col * (size + gap), -(y + row * (size + gap)))
            b:Show()
            i = i + 1
        end
    end
    local rows = math.ceil(i / columns)
    y = y + rows * size + math.max(rows - 1, 0) * gap + (rows > 0 and gap + 4 or 0)
    for index = used + 1, #self.savedButtons do
        self.savedButtons[index]:Hide()
    end
    for index = titleIndex + 1, #self.titles do
        self.titles[index]:Hide()
    end
    self.empty:SetText(missing or L.NO_TABS)
    self.empty:SetShown(y == 0)
    local width = math.max(columns * size + (columns - 1) * gap, 260)
    local height = y == 0 and 40 or math.max(y - gap - 4, 0)
    self.content:SetSize(width, height)
    if self.kind == "saved" then
        self.tabs:SetValue(self.place)
    end
    self.sort:Hide()
    self:LayoutChrome(width, height)
    self.dirty = false
end

--- The sections of this window according to the layout.
---@return EternityUIBagsSection[]
function Grid:Sections()
    local split = opt("windows.layout") == "bags"
    local sections = {}
    if self.kind == "bank" then
        local tabs = C_Bank and C_Bank.FetchPurchasedBankTabData and C_Bank.FetchPurchasedBankTabData(self.bankType)
        if split then
            for i, tab in ipairs(tabs or {}) do
                sections[#sections + 1] =
                    { title = tab.name ~= "" and tab.name or L.TAB_N:format(i), bags = { tab.ID } }
            end
        else
            sections[1] = { bags = Inventory.BankBags(self.bankType) }
        end
        return sections
    end
    local index = Enum.BagIndex or {}
    local main = { bags = {} }
    sections[1] = main
    for _, bag in ipairs(Inventory.PlayerBags()) do
        local apart = bag == index.Keyring or (bag == index.ReagentBag and (split or opt("windows.reagents")))
        -- A hidden keyring leaves the window; the keys stay where they are.
        local shown = bag ~= index.Keyring or opt("windows.keyring")
        if shown and (split or apart) then
            if C_Container.GetContainerNumSlots(bag) > 0 then
                sections[#sections + 1] = { title = bagTitle(bag), bags = { bag } }
            end
        elseif shown then
            main.bags[#main.bags + 1] = bag
        end
    end
    if #main.bags == 0 then
        table.remove(sections, 1)
    end
    return sections
end

function Grid:SectionTitle(index)
    local title = self.titles[index]
    if not title then
        title = Widgets.Text(self.content, 12, "muted")
        self.titles[index] = title
    end
    return title
end

--- Places every slot and sizes the window.
function Grid:Layout()
    if self:IsSaved() then
        self:LayoutSaved()
        return
    end
    for _, b in ipairs(self.savedButtons) do
        b:Hide()
    end
    self.empty:SetText(L.NO_TABS)
    self.sort:Show()
    local size, gap = opt("slots.size"), opt("slots.spacing")
    local columns = opt(self.kind == "bank" and "slots.bankColumns" or "slots.columns")
    local used, y, titleIndex = {}, 0, 0
    local showTitles = opt("window.sectionTitles")
    for _, section in ipairs(self:Sections()) do
        if section.title and showTitles then
            titleIndex = titleIndex + 1
            local title = self:SectionTitle(titleIndex)
            title:SetText(section.title)
            title:ClearAllPoints()
            title:SetPoint("TOPLEFT", self.content, "TOPLEFT", 0, -y)
            title:Show()
            y = y + SECTION_TITLE
        end
        local i = 0
        for _, bag in ipairs(section.bags) do
            used[bag] = {}
            for slot = 1, C_Container.GetContainerNumSlots(bag) do
                local b = self:Button(bag, slot)
                styleButton(b, size)
                local col, row = i % columns, math.floor(i / columns)
                b:ClearAllPoints()
                b:SetPoint("TOPLEFT", self.content, "TOPLEFT", col * (size + gap), -(y + row * (size + gap)))
                b:Show()
                used[bag][slot] = true
                i = i + 1
            end
        end
        local rows = math.ceil(i / columns)
        y = y + rows * size + math.max(rows - 1, 0) * gap + (rows > 0 and gap + 4 or 0)
    end
    for index = titleIndex + 1, #self.titles do
        self.titles[index]:Hide()
    end
    for bag, list in pairs(self.buttons) do
        for slot, b in pairs(list) do
            if not (used[bag] and used[bag][slot]) then
                b:Hide()
            end
        end
    end
    self.empty:SetShown(y == 0)
    local width = math.max(columns * size + (columns - 1) * gap, 260)
    local height = math.max(y - gap - 4, 0)
    if y == 0 then
        height = 40
    end
    self.content:SetSize(width, height)
    self:LayoutChrome(width, height)
    self.dirty = false
    self.slots = self:CountSlots()
    self:Refresh()
end

--- Total slots of the bags shown: if it changes, the grid is laid out again.
function Grid:CountSlots()
    local total = 0
    for _, bag in ipairs(self:Bags()) do
        total = total + C_Container.GetContainerNumSlots(bag)
    end
    return total
end

--- Toolbar and footer around the content; the window's size. There is no header: the menu and
--- close buttons sit at the end of the toolbar.
function Grid:LayoutChrome(width, height)
    local w, pad, control = self.frame, opt("window.padding"), opt("window.toolbarHeight")
    local toolbar = self.toolbar
    toolbar:ClearAllPoints()
    toolbar:SetPoint("TOPLEFT", w.body, "TOPLEFT", pad, -pad)
    toolbar:SetSize(width, control)
    self.search:SetHeight(control)
    self.sort:SetHeight(control)
    self.menu:SetSize(control, control)
    w.close:SetSize(control, control)
    local left = 0
    if self.tabs then
        self.tabs.buttonHeight = control
        self.tabs:SetHeight(control)
        self.tabs:Paint()
        self.tabs:SetShown(self.tabs.count > 1)
        if self.tabs.count > 1 then
            left = self.tabs:GetWidth() + 8
        end
    end
    w.close:ClearAllPoints()
    w.close:SetPoint("RIGHT", toolbar, "RIGHT", 0, 0)
    self.menu:ClearAllPoints()
    self.menu:SetPoint("RIGHT", w.close, "LEFT", -4, 0)
    self.sort:ClearAllPoints()
    self.sort:SetPoint("RIGHT", self.menu, "LEFT", -8, 0)
    self.search:ClearAllPoints()
    self.search:SetPoint("LEFT", toolbar, "LEFT", left, 0)
    self.search:SetPoint("RIGHT", self.sort:IsShown() and self.sort or self.menu, "LEFT", -8, 0)
    self.content:ClearAllPoints()
    self.content:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -pad)
    -- Wide enough for everything in the footer.
    self:UpdateFooter()
    width = math.max(width, self:FooterWidth() - 2 * pad)
    toolbar:SetWidth(width)
    -- The footer's text is centered in it: the space up to that text sets the gap below the items.
    local footer = w.footer:GetHeight()
    local below = opt("window.footerSpace") - (footer - FOOTER_TEXT) / 2
    -- A saved view says when it was saved on a line of its own, under the slots.
    local note = 0
    if self.updated and self:IsSaved() then
        self.updated:ClearAllPoints()
        self.updated:SetPoint("TOPLEFT", self.content, "BOTTOMLEFT", 0, -pad)
        self.updated:SetPoint("TOPRIGHT", self.content, "BOTTOMRIGHT", 0, -pad)
        note = pad + FOOTER_TEXT + 2
    end
    w:SetSize(width + 2 * pad, control + height + 2 * pad + note + below + footer)
    self:UpdateFooter()
end

--- Item states (count, lock, cooldown, search, borders) without moving anything.
function Grid:Refresh()
    if not self.frame:IsShown() then
        return
    end
    if self:IsSaved() then
        if self.dirty then
            self:LayoutSaved()
        end
        return
    end
    if self.dirty or self.slots ~= self:CountSlots() then
        self:Layout()
        return
    end
    for _, list in pairs(self.buttons) do
        for _, b in pairs(list) do
            if b:IsShown() then
                updateButton(b)
            end
        end
    end
    self:UpdateFooter()
end

function Grid:Bags()
    local list = {}
    for _, section in ipairs(self:Sections()) do
        for _, bag in ipairs(section.bags) do
            list[#list + 1] = bag
        end
    end
    return list
end

--- Tooltip of the gold: every character's, richest first, and the total.
local function goldTooltip(tip)
    tip:SetTitle(L.GOLD_TITLE)
    local list, total = Inventory:MoneyList()
    local myRealm = Inventory.Me()
    for _, char in ipairs(list) do
        local text = char.realm == myRealm and char.name or (char.name .. "-" .. char.realm)
        local color = char.class and C_ClassColor and C_ClassColor.GetClassColor(char.class)
        tip:AddDoubleLine(color and color:WrapTextInColorCode(text) or text, GetMoneyString(char.money, true))
    end
    if #list > 1 then
        tip:AddDoubleLine(L.GOLD_TOTAL, GetMoneyString(total, true), "text", "text")
    end
    tip:AddHint(L.GOLD_HINT)
end
Grid.GoldTooltip = goldTooltip

--- Bags footer, left to right: gold (own bags only), Characters, Bank; "saved ..." on the right.
function Grid:PlaceBagsFooter()
    local footer = self.frame.footer
    local money = GetMoney()
    if self.viewing then
        local char = Inventory:Character(self.realm, self.name)
        money = char and char.money
    end
    self.money:SetText(money and GetMoneyString(money, true) or L.GOLD_UNKNOWN)
    self.money:SetShown(opt("windows.money"))
    self.moneyHit:SetShown(self.money:IsShown())
    self.others:ClearAllPoints()
    if self.money:IsShown() then
        self.others:SetPoint("LEFT", self.money, "RIGHT", 12, 0)
    else
        self.others:SetPoint("LEFT", footer, "LEFT", 12, 0)
    end
    self.savedBank:ClearAllPoints()
    self.savedBank:SetPoint("LEFT", self.others, "RIGHT", 4, 0)
    self.lock:ClearAllPoints()
    self.lock:SetPoint("LEFT", self.savedBank, "RIGHT", 4, 0)
end

--- The width the footer's shown pieces take, with their gaps and the edges.
function Grid:FooterWidth()
    local total = 24
    for _, piece in ipairs({ self.money, self.savedBank, self.lock, self.keyring, self.free, self.deposit, self.blizzard, self.guild, self.others, self.character }) do
        if piece and piece:IsShown() then
            local width = piece.GetStringWidth and piece:GetStringWidth() or piece:GetWidth()
            total = total + width + 12
        end
    end
    return total
end

function Grid:UpdateFooter()
    if self.kind == "bags" then
        self:PlaceBagsFooter()
    end
    if self.lock then
        -- Only this character's own bags and bank can be locked.
        self.lock:SetShown(not self:IsSaved())
        -- Blizzard's sort moves locked items too: the padlock is greyed out until it's Eternity's.
        self.lock:SetAlpha(ownSort() and 1 or 0.4)
        if not self.lock:IsShown() or not ownSort() then
            self:SetLockMode(false)
        end
    end
    if self:IsSaved() then
        local free, total = 0, 0
        for _, container in ipairs(self.savedContainers or {}) do
            if container.kind ~= "keyring" then
                total = total + (container.size or 0)
                for slot = 1, container.size or 0 do
                    if not (container.slots and container.slots[slot]) then
                        free = free + 1
                    end
                end
            end
        end
        self.free:SetText(L.FREE:format(free, total))
        self.free:SetShown(opt("windows.freeSlots") and total > 0)
        local text = self.name or ""
        local char = self.realm and Inventory:Character(self.realm, self.name)
        local color = char and char.class and C_ClassColor and C_ClassColor.GetClassColor(char.class)
        local button = self.character or self.others
        button.label:SetText(color and color:WrapTextInColorCode(text) or text)
        button:SetWidth(button.label:GetStringWidth() + 20)
        self.updated:Show()
        local ago = Viewer.Ago(self.savedUpdated)
        self.updated:SetText(ago and L.UPDATED:format(ago) or "")
        -- Right to left: free slots, the keyring box (bags).
        local anchor = self.free:IsShown() and self.free or nil
        local function after(piece)
            piece:ClearAllPoints()
            if anchor then
                piece:SetPoint("RIGHT", anchor, "LEFT", -14, 0)
            else
                piece:SetPoint("RIGHT", self.frame.footer, "RIGHT", -12, 0)
            end
            anchor = piece
        end
        if self.keyring then
            self.keyring:Show()
            self.keyring:SetValue(opt("windows.keyring"))
            after(self.keyring)
        end
        return
    end
    local free, total = 0, 0
    for _, bag in ipairs(self:Bags()) do
        if bag ~= (Enum.BagIndex or {}).Keyring then
            free = free + (C_Container.GetContainerNumFreeSlots(bag) or 0)
            total = total + C_Container.GetContainerNumSlots(bag)
        end
    end
    self.free:SetText(L.FREE:format(free, total))
    self.free:SetShown(opt("windows.freeSlots"))
    if self.keyring then
        local keyring = (Enum.BagIndex or {}).Keyring
        self.keyring:SetShown(keyring ~= nil and C_Container.GetContainerNumSlots(keyring) > 0)
        self.keyring:SetValue(opt("windows.keyring"))
        self.keyring:ClearAllPoints()
        if self.free:IsShown() then
            self.keyring:SetPoint("RIGHT", self.free, "LEFT", -14, 0)
        else
            self.keyring:SetPoint("RIGHT", self.frame.footer, "RIGHT", -12, 0)
        end
    end
    if self.money then
        self.others.label:SetText(L.OTHER_CHARACTERS)
        self.others:SetWidth(self.others.label:GetStringWidth() + 20)
        self.updated:Hide()
    end
    if self.deposit then
        self.deposit:SetShown(C_Bank ~= nil and C_Bank.AutoDepositItemsIntoBank ~= nil)
    end
end

function Grid:Sort()
    -- Eternity's sort (Locks.lua) by default; Blizzard's can't skip a locked slot.
    if ownSort() then
        Locks.Sort(self)
        return
    end
    if InCombatLockdown() then
        print("|cff8b5cf6Eternity Bags|r: " .. L.SORT_COMBAT)
        return
    end
    if self.kind == "bank" then
        if C_Container.SortBank and self.bankType then
            C_Container.SortBank(self.bankType)
        elseif C_Container.SortBankBags then
            C_Container.SortBankBags()
        else
            Locks.Sort(self)
        end
        return
    end
    if not C_Container.SortBags then
        Locks.Sort(self)
        return
    end
    -- Blizzard's direction setting just for this sort; the player's own is put back.
    local get, set = C_Container.GetSortBagsRightToLeft, C_Container.SetSortBagsRightToLeft
    local previous = get and get()
    if set then
        set(opt("windows.sortReverse"))
    end
    C_Container.SortBags()
    if set and previous ~= nil then
        set(previous)
    end
end

--- The item button under the mouse, or nil.
function Grid:HoveredButton()
    for _, list in pairs(self.buttons) do
        for _, b in pairs(list) do
            if b:IsVisible() and b:IsMouseOver() then
                return b
            end
        end
    end
    return nil
end

--- Lock mode: a layer over the items takes the clicks, so a click locks or unlocks a slot instead
--- of using the item (the item buttons are Blizzard's and aren't touched).
function Grid:SetLockMode(on)
    on = on and true or false
    if (self.lockMode or false) == on or not self.lock then
        return
    end
    self.lockMode = on
    local layer = self.lockLayer
    if not layer then
        layer = CreateFrame("Button", nil, self.frame.body)
        layer:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        layer.hover = layer:CreateTexture(nil, "OVERLAY")
        layer.hover:SetColorTexture(1, 1, 1, 0.18)
        layer.hover:Hide()
        layer:SetScript("OnClick", function(_, button)
            if button == "RightButton" then
                self:SetLockMode(false)
                return
            end
            local b = self:HoveredButton()
            if b then
                Locks.Toggle(b:GetBagID(), b:GetID())
                self:Refresh()
            end
        end)
        -- A padlock follows the mouse over the items, so it's clear clicks lock instead of use.
        local cursor = CreateFrame("Frame", nil, UIParent)
        cursor:SetFrameStrata("TOOLTIP")
        cursor:SetSize(20, 20)
        cursor:EnableMouse(false)
        cursor.icon = cursor:CreateTexture(nil, "OVERLAY")
        cursor.icon:SetAllPoints()
        cursor.icon:SetTexture(LOCK_ICON)
        cursor:Hide()
        layer.cursor = cursor
        layer:SetScript("OnUpdate", function()
            if layer:IsMouseOver() then
                local x, y = GetCursorPosition()
                local scale = UIParent:GetEffectiveScale()
                cursor:ClearAllPoints()
                cursor:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale + 14, y / scale - 10)
                cursor:Show()
            else
                cursor:Hide()
            end
            local b = self:HoveredButton()
            if b ~= layer.target then
                layer.target = b
                layer.hover:ClearAllPoints()
                if b then
                    layer.hover:SetAllPoints(b)
                end
                layer.hover:SetShown(b ~= nil)
            end
        end)
        layer:SetScript("OnHide", function()
            layer.target = nil
            layer.hover:Hide()
            cursor:Hide()
        end)
        self.lockLayer = layer
    end
    layer:SetAllPoints(self.content)
    layer:SetFrameLevel(self.content:GetFrameLevel() + 50)
    layer:SetShown(on)
    local accent = Theme.accent
    if on then
        self.lock.icon:SetVertexColor(accent[1], accent[2], accent[3], 1)
    else
        self.lock.icon:SetVertexColor(1, 1, 1, 1)
    end
    self.lock:SetActive(on)
end

--- Scale. The position belongs to the Mover: bags at the bottom right corner and bank at the top
--- left one by default; dragging the window saves it there too.
function Grid:Place()
    self.frame:SetScale(opt("window.scale"))
end

function Grid:Key()
    return addonName .. "." .. self.kind
end

function Grid:Register()
    local bank = self.kind == "bank"
    E.Mover.Register({
        key = self:Key(),
        owner = addonName,
        label = bank and L.BANK or L.BAGS,
        frame = self.frame,
        point = bank and "TOPLEFT" or "BOTTOMRIGHT",
        x = bank and 24 or -24,
        y = bank and -120 or 96,
        openOptions = function()
            E:OpenOptions(addonName, "general")
        end,
    })
end

function Grid:ClearSearch()
    if self.search:GetText() ~= "" then
        self.search:SetText("")
    end
    if not self:IsSaved() then
        C_Container.SetItemSearch("")
    end
end

-- Options page: Characters tab ---------------------------------------------------------------

local CHARACTER_ROW = 40

--- The Characters tab of the options: every remembered character but this one, each with a
--- button to forget it. build(parent, setHeight) as ModulePage wants it.
local function buildCharacters(parent, setHeight)
    local view = CreateFrame("Frame", nil, parent)
    view:SetPoint("TOPLEFT")
    view:SetPoint("TOPRIGHT")
    view.rows = {}
    view.empty = Widgets.Text(view, 14, "muted")
    view.empty:SetPoint("TOPLEFT", 0, -12)
    view.empty:SetText(L.NO_CHARACTERS)

    function view:Refresh()
        local others = Inventory:Others()
        for i, char in ipairs(others) do
            local row = self.rows[i]
            if not row then
                local forget = Widgets.Button(self, L.FORGET_BUTTON, "danger", function(button)
                    local target = button:GetParent().char
                    if target then
                        Inventory:Forget(target.realm, target.name)
                        self:Refresh()
                    end
                end)
                forget:SetWidth(math.max(90, forget.label:GetStringWidth() + 28))
                row = Widgets.Row(self, "", forget)
                row:SetHeight(CHARACTER_ROW)
                row:SetPoint("TOPLEFT", 0, -(i - 1) * CHARACTER_ROW)
                row:SetPoint("TOPRIGHT", 0, -(i - 1) * CHARACTER_ROW)
                row.forget = forget
                self.rows[i] = row
            end
            row.char = char
            local text = char.name .. "-" .. char.realm
            local color = char.class and C_ClassColor and C_ClassColor.GetClassColor(char.class)
            row.label:SetText(color and color:WrapTextInColorCode(text) or text)
            row:Show()
        end
        for i = #others + 1, #self.rows do
            self.rows[i].char = nil
            self.rows[i]:Hide()
        end
        self.empty:SetShown(#others == 0)
        local height = math.max(#others * CHARACTER_ROW, 40)
        self:SetHeight(height)
        setHeight(height)
    end

    view:SetScript("OnShow", view.Refresh)
    view:Refresh()
    return view
end

Module.tabs = { { key = "characters", text = L.CHARACTERS, build = buildCharacters, description = L.CHARACTERS_HINT } }
Module.defaultTab = "general"

--- A check box with a label at its right: onClick(value) after it changes.
local function newCheck(parent, text, onClick)
    local check = CreateFrame("Button", nil, parent)
    check.box = CreateFrame("Frame", nil, check)
    check.box:SetSize(14, 14)
    check.box:SetPoint("LEFT")
    check.box.shape = Shape.New(check.box)
    check.mark = CreateFrame("Frame", nil, check.box)
    check.mark:SetSize(6, 6)
    check.mark:SetPoint("CENTER")
    check.mark.shape = Shape.New(check.mark)
    check.label = Widgets.Text(check, FOOTER_TEXT, "muted")
    check.label:SetPoint("LEFT", check.box, "RIGHT", 6, 0)
    check.label:SetText(text)
    check:SetSize(14 + 6 + check.label:GetStringWidth(), 16)

    function check:SetValue(value)
        self.value = value and true or false
        self:Paint()
    end

    function check:Paint()
        Shape.Paint(self.box.shape, 3, self.value and Theme.accent or Theme.colors.hover, Theme.colors.line)
        Shape.Paint(self.mark.shape, 1, Theme.colors.onAccent, nil)
        self.mark:SetShown(self.value)
        self:SetWidth(14 + 6 + self.label:GetStringWidth())
    end

    check:SetScript("OnClick", function(self)
        self:SetValue(not self.value)
        onClick(self.value)
    end)
    return Widgets.Track(check)
end

local function hint(frame, title, text)
    Widgets.AttachTooltip(frame, function(tip)
        tip:SetTitle(title)
        tip:AddLine(text, "textMuted")
    end)
end

---@param module EternityUIBagsModule
---@param kind string "bags" | "bank"
---@return EternityUIBagsGrid
function Grid.New(module, kind)
    local self = setmetatable({ kind = kind, holders = {}, buttons = {}, titles = {}, savedButtons = {} }, Grid)
    local bank, saved = kind == "bank", kind == "saved"
    local names = { bags = "EternityUIBagsWindow", bank = "EternityUIBankWindow", saved = "EternityUISavedBankWindow" }
    local w = Widgets.Window(names[kind], kind == "bags" and L.BAGS or L.BANK, true)
    self.frame = w
    w:SetSize(480, 400)
    w:SetFrameStrata("HIGH")
    w:SetToplevel(true)
    -- Esc is left to Blizzard, as for its own bags: CloseAllWindows hides its bag frames
    -- (CloseAllBags) and BankFrame (a UI panel), and our windows follow them. Nothing of
    -- Blizzard's is called or written, it also works in combat and no key is ever held back.
    w:EnableKeyboard(false)
    w:SetScript("OnKeyDown", nil)
    w:SetScript("OnDragStart", function(frame)
        local entry = not saved and E.Mover.Entry(self:Key())
        if not (entry and entry.locked) then
            frame:StartMoving()
        end
    end)
    w:SetScript("OnDragStop", function(frame)
        frame:StopMovingOrSizing()
        frame:SetUserPlaced(false)
        if not saved then
            E.Mover.SaveFromFrame(self:Key())
        end
    end)
    w:HookScript("OnShow", function()
        self:Place()
        if self.dirty then
            self:Layout()
        else
            self:Refresh()
        end
    end)
    w:HookScript("OnHide", function()
        self:SetLockMode(false)
        if self.viewing then
            self.viewing, self.place, self.realm, self.name = nil, nil, nil, nil
            self.dirty = true
        end
        if opt("windows.clearSearch") then
            self:ClearSearch()
        end
        Widgets.CloseMenu()
        module:OnWindowHidden(self)
    end)
    -- Your own image behind the slots ("bags" wallpaper: Bags.tga, switched on in General >
    -- Appearance), as see-through as the window. Painted again when the window's size changes.
    w.wallpaper = Theme.NewWallpaper(w)
    local function paintWallpaper(frame)
        Theme.PaintWallpaper(frame.wallpaper, "bags", module.running)
        local alpha = module.running and opt("window.opacity") or 1
        frame.wallpaper.photo:SetAlpha(alpha)
        frame.wallpaper.veil:SetAlpha(alpha)
    end
    w:HookScript("OnSizeChanged", paintWallpaper)
    -- Window opacity and shadow on top of the theme's: applied after every repaint.
    function w.onPaint(frame)
        if module.running then
            frame.shape.fill:SetAlpha(opt("window.opacity"))
            frame.shadow:SetShown(opt("window.shadow"))
        end
        paintWallpaper(frame)
    end
    w:Paint()

    -- No header: the body starts at the top and the close button joins the toolbar.
    w.header:Hide()
    w.body:ClearAllPoints()
    w.body:SetPoint("TOPLEFT")
    w.body:SetPoint("BOTTOMRIGHT", w.footer, "TOPRIGHT")
    self.toolbar = CreateFrame("Frame", nil, w.body)
    w.close:SetParent(self.toolbar)

    -- The module's options (forgetting characters is in their Characters tab).
    self.menu = Widgets.Button(self.toolbar, "...", "ghost", function()
        E:OpenOptions(addonName, "general")
    end)
    hint(self.menu, L.OPTIONS, L.OPTIONS_HINT)

    self.search = Widgets.Input(self.toolbar, nil, L.SEARCH)
    self.search:SetMaxLetters(60)
    self.search:HookScript("OnTextChanged", function(box, userInput)
        if not userInput then
            return
        elseif self:IsSaved() then
            -- Only dims what doesn't match, as Blizzard's search does: nothing moves.
            local needle = self:SavedNeedle()
            for _, b in ipairs(self.savedButtons) do
                if b:IsShown() then
                    b:SetMatchesSearch(savedMatches(b, needle))
                end
            end
        else
            C_Container.SetItemSearch(box:GetText())
        end
    end)
    self.sort = Widgets.Button(self.toolbar, L.SORT, "ghost", function()
        self:Sort()
    end)
    self.sort:SetWidth(math.max(70, self.sort.label:GetStringWidth() + 24))
    Widgets.AttachTooltip(self.sort, function(tip)
        tip:SetTitle(L.SORT)
        tip:AddLine(ownSort() and L.SORT_HINT_ETERNITY or L.SORT_HINT, "textMuted")
    end)
    self.sort:SetShown(not saved)

    self.content = CreateFrame("Frame", nil, w.body)
    self.empty = Widgets.Text(self.content, 12, "muted")
    self.empty:SetText(L.NO_TABS)
    self.empty:SetPoint("CENTER")
    self.empty:Hide()

    local pad = 12
    self.free = Widgets.Text(w.footer, FOOTER_TEXT, "muted")
    self.free:SetPoint("RIGHT", w.footer, "RIGHT", -pad, 0)
    if bank then
        local character, account = bankTypes()
        self.bankType = character
        local items = { { "character", L.CHARACTER_BANK } }
        if account then
            items[2] = { "account", L.WARBAND_TAB }
        end
        self.tabs = Widgets.Segmented(self.toolbar, items, function(key)
            self.bankType = key == "account" and account or character
            self:Layout()
        end)
        self.tabs:SetPoint("LEFT", self.toolbar, "LEFT", 0, 0)
        self.tabs:SetValue("character")
        self.tabs.count = #items
        self.deposit = Widgets.Button(w.footer, L.DEPOSIT, "ghost", function()
            if self.bankType then
                C_Bank.AutoDepositItemsIntoBank(self.bankType)
            end
        end)
        self.deposit:SetPoint("LEFT", w.footer, "LEFT", pad, 0)
        hint(self.deposit, L.DEPOSIT, L.DEPOSIT_HINT)
        self.blizzard = Widgets.Button(w.footer, L.BLIZZARD_BANK, "ghost", function()
            module:UseBlizzardBank()
        end)
        self.blizzard:SetPoint("LEFT", self.deposit, "RIGHT", 4, 0)
        hint(self.blizzard, L.BLIZZARD_BANK, L.BLIZZARD_BANK_HINT)
        -- The saved view: the guild bank, and the bank of the other characters.
        self.guild = Widgets.Button(w.footer, L.GUILD, "ghost", function()
            Viewer.Open("guild", nil, nil, w)
        end)
        self.guild:SetHeight(26)
        self.guild:SetPoint("LEFT", self.blizzard, "RIGHT", 4, 0)
        hint(self.guild, L.GUILD_BANK, L.GUILD_HINT)
        self.others = Widgets.Button(w.footer, L.OTHER_CHARACTERS, "ghost", function(button)
            Viewer.CharacterMenu(button, function(realm, name)
                Viewer.Open("bank", realm, name, w)
            end)
        end)
        self.others:SetHeight(26)
        self.others:SetPoint("LEFT", self.guild, "RIGHT", 4, 0)
        hint(self.others, L.OTHER_CHARACTERS, L.OTHER_CHARACTERS_HINT)
    elseif saved then
        -- Like the bank's tabs: the bank or the guild bank, of the character in the footer.
        local items = {}
        for i, place in ipairs(Viewer.PLACES) do
            items[i] = { place, place == "guild" and L.GUILD or L.SAVED_BANK }
        end
        self.tabs = Widgets.Segmented(self.toolbar, items, function(place)
            self.place = place
            self:Layout()
        end)
        self.tabs:SetPoint("LEFT", self.toolbar, "LEFT", 0, 0)
        self.tabs.count = #items
        self.character = Widgets.Button(w.footer, "", "ghost", function(button)
            Viewer.CharacterMenu(button, function(realm, name)
                self.realm, self.name = realm, name
                self:Layout()
            end)
        end)
        self.character:SetHeight(26)
        self.character:SetPoint("LEFT", w.footer, "LEFT", pad, 0)
        hint(self.character, L.OTHER_CHARACTERS, L.OTHER_CHARACTERS_HINT)
        self.updated = Widgets.Text(w.body, FOOTER_TEXT, "muted")
        self.updated:SetJustifyH("LEFT")
    else
        self.money = Widgets.Text(w.footer, FOOTER_TEXT, "text")
        self.money:SetPoint("LEFT", w.footer, "LEFT", pad, 0)
        -- The text can't take the mouse: a frame over it shows every character's gold.
        self.moneyHit = CreateFrame("Frame", nil, w.footer)
        self.moneyHit:SetAllPoints(self.money)
        self.moneyHit:EnableMouse(true)
        Widgets.AttachTooltip(self.moneyHit, goldTooltip, "TOP")
        self.keyring = newCheck(w.footer, L.KEYRING, function(value)
            E.store:Set(addonName, "windows.keyring", value)
        end)
        hint(self.keyring, L.KEYRING, L.KEYRING_HINT)
        -- The saved view: another character's bags in this same window, and the bank of the
        -- character shown, from anywhere.
        self.others = Widgets.Button(w.footer, L.OTHER_CHARACTERS, "ghost", function(button)
            Viewer.CharacterMenu(button, function(realm, name)
                self:ViewCharacter(realm, name)
            end)
        end)
        self.others:SetHeight(26)
        hint(self.others, L.OTHER_CHARACTERS, L.BAGS_OF_HINT)
        self.updated = Widgets.Text(w.body, FOOTER_TEXT, "muted")
        self.updated:SetJustifyH("LEFT")
        self.savedBank = Widgets.Button(w.footer, L.SAVED_BANK, "ghost", function()
            Viewer.Open("bank", self.realm, self.name, w)
        end)
        self.savedBank:SetHeight(26)
        self.savedBank:SetWidth(self.savedBank.label:GetStringWidth() + 20)
        hint(self.savedBank, L.SAVED_BANK, L.SAVED_BANK_HINT)
    end
    if not saved then
        self.lock = Widgets.Button(w.footer, "", "ghost", function()
            if not ownSort() then
                -- Locking only makes sense with Eternity's sort: the padlock switches to it.
                E.store:Set(addonName, "windows.sortMode", "eternity")
                print("|cff8b5cf6Eternity Bags|r: " .. L.SORT_SWITCHED)
                self:UpdateFooter()
                self:Refresh()
            end
            self:SetLockMode(not self.lockMode)
        end)
        self.lock:SetSize(26, 26)
        self.lock.icon = self.lock:CreateTexture(nil, "ARTWORK")
        self.lock.icon:SetTexture(LOCK_ICON)
        self.lock.icon:SetSize(16, 16)
        self.lock.icon:SetPoint("CENTER")
        Widgets.AttachTooltip(self.lock, function(tip)
            tip:SetTitle(L.LOCK)
            tip:AddLine(ownSort() and L.LOCK_HINT or L.LOCK_OFF_HINT, "textMuted")
        end)
        if bank then
            self.lock:SetPoint("LEFT", self.others, "RIGHT", 4, 0)
        end
    end
    self.dirty = true
    return self
end

--- Shows the warband tab only when that bank can be seen.
function Grid:UpdateTabs()
    if not self.tabs then
        return
    end
    local character, account = bankTypes()
    local warband = self.tabs.buttons[2]
    local canWarband = warband ~= nil and Inventory.CanViewBank(account)
    if warband then
        warband:SetShown(canWarband)
    end
    self.tabs.count = canWarband and 2 or 1
    if not canWarband and self.bankType == account then
        self.bankType = character
        self.tabs:SetValue("character")
    end
end

-- Blizzard's bags ---------------------------------------------------------------------------

--- Blizzard's bag frames: the combined one (child of UIParent) and the container of the others.
local function blizzardBagParents()
    local list = {}
    if _G.ContainerFrameCombinedBags then
        list[#list + 1] = _G.ContainerFrameCombinedBags
    end
    if _G.ContainerFrameContainer then
        list[#list + 1] = _G.ContainerFrameContainer
    end
    return list
end

local function blizzardBagFrames()
    local list = {}
    if _G.ContainerFrameCombinedBags then
        list[#list + 1] = _G.ContainerFrameCombinedBags
    end
    local container = _G.ContainerFrameContainer
    for _, frame in ipairs(container and container.ContainerFrames or {}) do
        list[#list + 1] = frame
    end
    return list
end

--- Whether Blizzard has any bag open (they're shown even inside the hidden parent).
function Module:AnyBlizzardBagOpen()
    for _, frame in ipairs(blizzardBagFrames()) do
        if frame:IsShown() then
            return true
        end
    end
    return false
end

function Module:BagsReplaced()
    return self.bagsHidden ~= nil
end

--- Hides or restores Blizzard's bag frames according to the options.
function Module:ApplyBags()
    local want = self.running and opt("windows.replaceBags")
    if want and not self.bagsHidden then
        self.bagsHidden = {}
        for _, frame in ipairs(blizzardBagParents()) do
            self.bagsHidden[frame] = frame:GetParent()
            frame:SetParent(hider)
        end
        self:SyncBags()
    elseif not want and self.bagsHidden then
        local hidden = self.bagsHidden
        self.bagsHidden = nil
        for frame, parent in pairs(hidden) do
            frame:SetParent(parent)
        end
        if self.bags then
            self.syncing = true
            self.bags.frame:Hide()
            self.syncing = false
        end
    end
end

--- Our bag window follows Blizzard's open/closed state.
function Module:SyncBags()
    if not self.running or not self:BagsReplaced() then
        return
    end
    local open = self:AnyBlizzardBagOpen() or self.bankBags == true
    if open and not self.bags then
        self.bags = Grid.New(self, "bags")
    end
    if self.bags then
        self.syncing = true
        self.bags.frame:SetShown(open)
        self.syncing = false
    end
end

-- Blizzard's bank ---------------------------------------------------------------------------

local function bankFrame()
    return _G.BankFrame
end

--- Hides BankFrame inside our hidden parent (only while it's not visible: hiding it while
--- visible fires its OnHide, which ends the bank session) or gives it back.
function Module:ApplyBank()
    local frame = bankFrame()
    if not frame then
        return
    end
    local want = self.running and opt("windows.replaceBank") and not self.blizzardBank
    if want and not self.bankHidden and not frame:IsVisible() then
        self.bankHidden = frame:GetParent()
        frame:SetParent(hider)
    elseif not want and self.bankHidden then
        frame:SetParent(self.bankHidden)
        self.bankHidden = nil
    end
    self:SyncBank()
end

function Module:SyncBank()
    local show = self.running and self.bankOpen and self.bankHidden ~= nil
    if show and not self.bank then
        self.bank = Grid.New(self, "bank")
    end
    if self.bank then
        if show then
            self.bank:UpdateTabs()
            self.bank.dirty = true
        end
        self.syncing = true
        self.bank.frame:SetShown(show and true or false)
        self.syncing = false
    end
end

--- "Blizzard's bank" button: Blizzard's window for the rest of this visit.
function Module:UseBlizzardBank()
    self.blizzardBank = true
    self:ApplyBank()
end

--- The player closed one of our windows (close button). Escape goes through Blizzard, which
--- closes its frames first, so this finds nothing left to close.
function Module:OnWindowHidden(grid)
    if self.syncing or not self.running or grid.kind == "saved" then
        return
    end
    if grid.kind == "bags" then
        self.bankBags = false
        if self:AnyBlizzardBagOpen() then
            CloseAllBags()
        end
    elseif self.bankOpen and not self.blizzardBank then
        self.userClosedAt = GetTime()
        self:CloseBank()
    end
end

--- Ends the bank visit (personal or warband) and the guild bank one. The game closes Blizzard's
--- frames itself, as when the player walks away.
function Module:CloseBank()
    if self.bankOpen then
        if C_Bank and C_Bank.CloseBankFrame then
            C_Bank.CloseBankFrame()
        elseif _G.CloseBankFrame then
            _G.CloseBankFrame()
        end
    end
    if self.guildOpen and _G.CloseGuildBankFrame then
        _G.CloseGuildBankFrame()
    end
end

-- Bags opened by the bank -------------------------------------------------------------------
-- The bags open with the bank ("windows.bagsWithBank"): our window is held open apart from
-- Blizzard's bag frames, because BankFrame (hidden inside our parent) never runs the OnShow that
-- opens them, and the guild bank doesn't open them at all. Nothing of Blizzard's is called.

--- A bank opened: the bags open with it.
function Module:OnBankOpened()
    if self.running and opt("windows.bagsWithBank") then
        self.bankBags = true
        self:SyncBags()
    end
end

--- A bank closed: the bags it opened close too, unless the player walked away
--- ("windows.keepBagsAway").
function Module:OnBankClosed()
    if not self.bankBags or self.bankOpen or self.guildOpen then
        return
    end
    local byPlayer = self.userClosedAt ~= nil and GetTime() - self.userClosedAt < USER_CLOSE_WINDOW
    if byPlayer or not opt("windows.keepBagsAway") then
        self.bankBags = false
        self:SyncBags()
    end
end

--- B (or the backpack key) while the bank holds the bags open: it closes them, and the bank
--- too ("windows.bankWithBags"). Blizzard's toggle has just opened its own bags (ours looked
--- open, Blizzard's weren't), so they're closed again.
function Module:OnBagsToggled()
    if not (self.running and self.bankBags) then
        return
    end
    self.bankBags = false
    self.userClosedAt = GetTime()
    if self:AnyBlizzardBagOpen() then
        CloseAllBags()
    end
    self:SyncBags()
    if opt("windows.bankWithBags") then
        self:CloseBank()
    end
end

--- Esc (CloseAllWindows) closes every bag, these too.
function Module:OnCloseAllWindows()
    if not self.running then
        return
    end
    self.userClosedAt = GetTime()
    if self.bankBags then
        self.bankBags = false
        self:SyncBags()
    end
end

--- The guild bank's close button is a close by the player (it's Blizzard's frame, loaded
--- on demand).
function Module:HookGuildBank()
    local frame = _G.GuildBankFrame
    if self.guildHooked or not (frame and frame.CloseButton) then
        return
    end
    self.guildHooked = true
    frame.CloseButton:HookScript("OnClick", function()
        self.userClosedAt = GetTime()
    end)
end

-- Saved bank --------------------------------------------------------------------------------

--- Opens the saved bank window on a place of a character (this one by default). It opens where
--- the bank window goes, or beside `beside` when that's open (the real bank). It's laid out
--- before it shows, so it appears already drawn.
---@param place string bank or guild
---@param realm string?
---@param name string?
---@param beside table?
function Module:OpenSaved(place, realm, name, beside)
    if not self.running then
        return
    end
    self.saved = self.saved or Grid.New(self, "saved")
    local grid = self.saved
    local myRealm, myName = Inventory.Me()
    grid.place = place or "bank"
    grid.realm, grid.name = realm or myRealm, name or myName
    grid:Place()
    local w = grid.frame
    if not w:IsShown() then
        w:ClearAllPoints()
        local bank = self.bank and self.bank.frame
        if beside and beside:IsShown() and beside:GetLeft() and beside ~= (self.bags and self.bags.frame) then
            -- Beside the real bank: to its right, or to its left when there's no room.
            local right = (beside:GetRight() or 0) * beside:GetEffectiveScale()
            if right + 520 * w:GetEffectiveScale() < UIParent:GetRight() * UIParent:GetEffectiveScale() then
                w:SetPoint("TOPLEFT", beside, "TOPRIGHT", 12, 0)
            else
                w:SetPoint("TOPRIGHT", beside, "TOPLEFT", -12, 0)
            end
        elseif bank and bank:GetNumPoints() > 0 then
            -- Where the real bank opens (the Mover's place for it).
            for i = 1, bank:GetNumPoints() do
                w:SetPoint(bank:GetPoint(i))
            end
        else
            w:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 24, -120)
        end
    end
    w:Paint()
    grid:Layout()
    w:Show()
end

function Viewer.Open(place, realm, name, beside)
    Module:OpenSaved(place, realm, name, beside)
end

-- Events ------------------------------------------------------------------------------------

function Module:OnEvent(event)
    if event == "BANKFRAME_OPENED" then
        self.bankOpen = true
        -- The real bank takes the saved one's place.
        if self.saved and self.saved.frame:IsShown() then
            self.saved.frame:Hide()
        end
        self:ApplyBank()
        self:OnBankOpened()
        return
    elseif event == "BANKFRAME_CLOSED" then
        self.bankOpen = false
        self.blizzardBank = false
        self:ApplyBank()
        self:OnBankClosed()
        return
    elseif event == "GUILDBANKFRAME_OPENED" then
        self.guildOpen = true
        self:HookGuildBank()
        self:OnBankOpened()
        return
    elseif event == "GUILDBANKFRAME_CLOSED" then
        self.guildOpen = false
        self:OnBankClosed()
        return
    end
    if not self.running then
        return
    end
    if event == "PLAYER_MONEY" then
        if self.bags then
            self.bags:UpdateFooter()
        end
        return
    end
    for _, grid in ipairs({ self.bags, self.bank }) do
        if grid then
            if RELAYOUT[event] then
                grid.dirty = true
            end
            if event == "BANK_TABS_CHANGED" then
                grid:UpdateTabs()
            end
            grid:Refresh()
        end
    end
end

-- Lifecycle ---------------------------------------------------------------------------------

function Module:InstallHooks()
    self.hooked = true
    for _, frame in ipairs(blizzardBagFrames()) do
        for _, method in ipairs({ "Show", "Hide", "SetShown" }) do
            hooksecurefunc(frame, method, function()
                self:SyncBags()
            end)
        end
    end
    local frame = bankFrame()
    if frame then
        -- If it was visible on enable, it's hidden as soon as Blizzard closes it.
        frame:HookScript("OnHide", function()
            if self.running and not self.bankHidden then
                self:ApplyBank()
            end
        end)
    end
    for _, name in ipairs({ "ToggleAllBags", "ToggleBackpack" }) do
        if _G[name] then
            hooksecurefunc(name, function()
                self:OnBagsToggled()
            end)
        end
    end
    if _G.CloseAllWindows then
        hooksecurefunc("CloseAllWindows", function()
            self:OnCloseAllWindows()
        end)
    end
    local events = CreateFrame("Frame")
    registerEvents(events, EVENTS)
    events:SetScript("OnEvent", function(_, event)
        self:OnEvent(event)
    end)
end

--- Applies every option (or undoes everything if the module isn't running).
function Module:ApplyAll()
    for _, grid in ipairs({ self.bags, self.bank, self.saved }) do
        if grid then
            grid.dirty = true
            grid.frame:Paint()
            if grid.frame:IsShown() then
                grid:Place()
                grid:Layout()
            end
        end
    end
    self:ApplyBags()
    self:ApplyBank()
    self:RegisterWindows()
end

--- The windows in use are Mover elements (created hidden, so they can be placed before they
--- first open); the ones not in use leave it.
function Module:RegisterWindows()
    for _, kind in ipairs({ "bags", "bank" }) do
        local wanted = self.running and opt(kind == "bags" and "windows.replaceBags" or "windows.replaceBank")
        local grid = self[kind]
        if wanted then
            grid = grid or Grid.New(self, kind)
            self[kind] = grid
            grid:Place()
            grid:Register()
        elseif grid then
            E.Mover.Unregister(grid:Key())
        end
    end
end

function Module:OnEnable()
    self.running = true
    if not self.hooked then
        self:InstallHooks()
    end
    -- If the bank is already open (enabled from the options), the bank window shows on the next visit.
    self.bankOpen = bankFrame() ~= nil and bankFrame():IsShown()
    -- A theme change repaints the slot shapes and fonts. The core releases this on disable.
    E.Events.Listen(Theme.CHANGED, self, function()
        for _, grid in ipairs({ self.bags, self.bank, self.saved }) do
            if grid then
                grid.dirty = true
                grid:Refresh()
            end
        end
    end)
    Inventory:Start()
    self:ApplyAll()
end

function Module:OnDisable()
    self.running = false
    self.bankBags = false
    Inventory:Stop()
    self:ApplyAll()
    for _, grid in ipairs({ self.bags, self.bank, self.saved }) do
        if grid then
            self.syncing = true
            grid.frame:Hide()
            self.syncing = false
        end
    end
end

function Module:OnConfigChanged()
    -- Everything is idempotent and cheap: it's reapplied in full.
    self:ApplyAll()
end

E:RegisterModule(addonName, Module)
