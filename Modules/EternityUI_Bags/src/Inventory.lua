-- EternityUI_Bags: what every character carries, saved for the whole account (EternityUIBagsDB),
-- and the lines it adds to the item tooltips ("who has it and how many").
--   * Bags (and keyring) and equipment are read on login and whenever they change. The bank and
--     the warband bank can only be read while the bank is open: they're updated on each visit and
--     the last snapshot is kept. The guild bank too, while it's open: its tabs are asked for
--     (QueryGuildBankTab) and kept per guild, shared by the characters in it.
--   * The mailbox, while it's open (only the mails the client lists, up to 50). What you mail to
--     one of your own characters is added to its mail right away (SendMail is hooked, and the
--     items are counted on MAIL_SEND_SUCCESS), until that character opens its mailbox.
--   * Totals per item (what the tooltips read) and, for the Companion, where each item sits:
--     every bag or bank tab with its size and slots, and the equipment by slot.
--   * No links: only IDs and counts per slot, plus one account-wide entry per item with its
--     name, quality and icon (`items`), pruned to what someone still carries.
-- The tooltip lines use TooltipDataProcessor.AddTooltipPostCall (no taint, nothing replaced).
-- The hook can't be removed: it does nothing while `running` is false.

---@type string, EternityUIBagsNamespace
local addonName, ns = ...
local E = EternityUI
local L = ns.L

local SCHEMA_VERSION = 2
local FIRST_EQUIPPED, LAST_EQUIPPED = 1, 19 -- INVSLOT_HEAD .. INVSLOT_TABARD

---@class EternityUIBagsContainer one bag or bank tab as the Companion draws it
---@field id integer bag ID
---@field kind string backpack, bag, reagent, keyring or tab
---@field name string?
---@field size integer
---@field slots table<integer, integer[]> slot -> { itemID, count }

---@class EternityUIBagsLayout
---@field bags EternityUIBagsContainer[]
---@field bank EternityUIBagsContainer[]?
---@field equipped table<integer, integer>? inventory slot -> itemID

---@class EternityUIBagsItem
---@field name string?
---@field quality integer?
---@field icon integer? icon fileID

---@class EternityUIBagsCharacter
---@field class string? class file (MAGE, PRIEST...)
---@field faction string? Alliance / Horde
---@field updated number? time() of the last scan
---@field bankUpdated number? time() of the last bank visit
---@field money number? copper the character had, last time it played
---@field bags table<integer, integer> itemID -> count
---@field bank table<integer, integer>
---@field equipped table<integer, integer>
---@field mail table<integer, integer>? itemID -> count in the mailbox
---@field mailUpdated number? time() of the last look at the mailbox
---@field layout EternityUIBagsLayout?
---@field guild string? key of the character's guild in `guilds` (realm/guild name)

---@class EternityUIBagsGuild
---@field name string
---@field realm string
---@field tabs EternityUIBagsContainer[]
---@field updated number? time() of the last visit

---@class EternityUIBagsOwner
---@field name string display name (Name or Name-Realm)
---@field class string?
---@field current boolean
---@field warband boolean?
---@field bags integer
---@field bank integer
---@field equipped integer
---@field mail integer
---@field total integer

---@class EternityUIBagsInventory
---@field running boolean?
---@field hooked boolean?
---@field bankOpen boolean?
---@field db table? EternityUIBagsDB once bound
local Inventory = {}
ns.Inventory = Inventory

local function opt(path)
    return E.store:Get(addonName, path)
end

local function secret(value)
    return issecretvalue ~= nil and issecretvalue(value)
end

-- Bag lists ---------------------------------------------------------------------------------

local BagIndex = Enum.BagIndex or {}

--- The player's bags: backpack, bags 1-4, reagent bag and keyring (those this client has).
---@return integer[]
function Inventory.PlayerBags()
    local list = {}
    if BagIndex.Keyring and C_Container.GetContainerNumSlots(BagIndex.Keyring) > 0 then
        list[#list + 1] = BagIndex.Keyring
    end
    for bag = BagIndex.Backpack or 0, BagIndex.Bag_4 or 4 do
        list[#list + 1] = bag
    end
    if BagIndex.ReagentBag then
        list[#list + 1] = BagIndex.ReagentBag
    end
    return list
end

--- Bags of a bank type (Enum.BankType.Character or Account): its purchased tabs.
---@param bankType integer?
---@return integer[]
function Inventory.BankBags(bankType)
    local list = {}
    if bankType == nil or not C_Bank or not C_Bank.FetchPurchasedBankTabData then
        return list
    end
    for _, tab in ipairs(C_Bank.FetchPurchasedBankTabData(bankType) or {}) do
        list[#list + 1] = tab.ID
    end
    return list
end

--- Whether the bank of that type can be seen right now (bank open and not locked).
function Inventory.CanViewBank(bankType)
    if bankType == nil or not C_Bank then
        return false
    end
    if C_Bank.CanViewBank then
        return C_Bank.CanViewBank(bankType)
    end
    return true
end

local function bankTypes()
    local types = Enum.BankType
    return types and types.Character, types and types.Account
end

-- Database ----------------------------------------------------------------------------------

-- The one realm of the saved characters, if there's only one: the core's guess when the game
-- answers an empty realm and none was ever seen.
local function onlyRealm(db)
    local found
    for realm in pairs(db and db.realms or {}) do
        if realm ~= "" and realm ~= "?" then
            if found then
                return nil
            end
            found = realm
        end
    end
    return found
end

local function realmName()
    local db = Inventory.db or _G.EternityUIBagsDB
    return E.RealmName(onlyRealm(type(db) == "table" and db or nil)) or "?"
end

-- Two saved copies of one character (or guild bank): the newer scan wins, and the bank of the
-- newer visit.
local function newer(a, b)
    local new, old = a, b
    if (tonumber(b.updated) or 0) > (tonumber(a.updated) or 0) then
        new, old = b, a
    end
    if (tonumber(old.bankUpdated) or 0) > (tonumber(new.bankUpdated) or 0) then
        new.bank, new.bankUpdated = old.bank, old.bankUpdated
    end
    return new
end

--- Characters and guild banks saved under an empty realm (GetRealmName answered "") go back to
--- the real realm, merged with the copies saved there. Returns how many characters it moved.
---@param db table
---@param realm string?
---@return number
function Inventory.MergeEmptyRealm(db, realm)
    if not realm or realm == "" or realm == "?" then
        return 0
    end
    local moved = 0
    local empty = db.realms[""]
    if type(empty) == "table" then
        db.realms[realm] = type(db.realms[realm]) == "table" and db.realms[realm] or {}
        local target = db.realms[realm]
        for name, char in pairs(empty) do
            if type(char) == "table" then
                local other = target[name]
                target[name] = type(other) == "table" and newer(other, char) or char
                moved = moved + 1
            end
        end
        db.realms[""] = nil
    end
    for key, guild in pairs(db.guilds or {}) do
        local name = type(key) == "string" and key:match("^/(.+)$")
        if name and type(guild) == "table" then
            local real = realm .. "/" .. name
            guild.realm = realm
            local other = db.guilds[real]
            db.guilds[real] = type(other) == "table" and newer(other, guild) or guild
            db.guilds[key] = nil
        end
    end
    for _, chars in pairs(db.realms) do
        for _, char in pairs(chars) do
            if type(char) == "table" and type(char.guild) == "string" and char.guild:sub(1, 1) == "/" then
                char.guild = realm .. char.guild
            end
        end
    end
    return moved
end

-- The whole name: Forever's UnitName gives the first name and the surname apart, and two characters
-- of a realm can share a first name.
local function playerName()
    local name, surname = UnitName("player")
    if surname and surname ~= "" then
        return (name or "?") .. " " .. surname
    end
    return name or "?"
end

--- Binds EternityUIBagsDB (the client loads it before ADDON_LOADED of this addon).
function Inventory:Bind()
    if self.db then
        return self.db
    end
    local db = _G.EternityUIBagsDB
    if type(db) ~= "table" or type(db.realms) ~= "table" then
        db = { realms = {} }
    end
    -- v1 → v2 only adds fields (layout, items, warband.tabs): the next scan fills them.
    db.version = SCHEMA_VERSION
    db.warband = type(db.warband) == "table" and db.warband or { items = {} }
    db.items = type(db.items) == "table" and db.items or {}
    db.guilds = type(db.guilds) == "table" and db.guilds or {}
    _G.EternityUIBagsDB = db
    self.db = db
    Inventory.MergeEmptyRealm(db, realmName())
    return db
end

---@return EternityUIBagsCharacter
function Inventory:Current()
    local db = self:Bind()
    local realm, name = realmName(), playerName()
    db.realms[realm] = db.realms[realm] or {}
    local char = db.realms[realm][name]
    if type(char) ~= "table" then
        char = { bags = {}, bank = {}, equipped = {} }
        db.realms[realm][name] = char
    end
    local _, class = UnitClass("player")
    char.class = class
    char.faction = UnitFactionGroup("player")
    return char
end

--- Characters remembered other than this one: { realm, name, class }, sorted.
function Inventory:Others()
    local db = self:Bind()
    local list = {}
    local myRealm, myName = realmName(), playerName()
    for realm, chars in pairs(db.realms) do
        for name, char in pairs(chars) do
            if not (realm == myRealm and name == myName) then
                list[#list + 1] = { realm = realm, name = name, class = char.class }
            end
        end
    end
    table.sort(list, function(a, b)
        if a.realm ~= b.realm then
            return a.realm < b.realm
        end
        return a.name < b.name
    end)
    return list
end

--- Every remembered character, this one first, then by realm and name: { realm, name, class,
--- current }.
function Inventory:Characters()
    local db = self:Bind()
    local myRealm, myName = realmName(), playerName()
    local list = {}
    for realm, chars in pairs(db.realms) do
        for name, char in pairs(chars) do
            local current = realm == myRealm and name == myName
            list[#list + 1] = { realm = realm, name = name, class = char.class, current = current }
        end
    end
    table.sort(list, function(a, b)
        if a.current ~= b.current then
            return a.current
        elseif a.realm ~= b.realm then
            return a.realm < b.realm
        end
        return a.name < b.name
    end)
    return list
end

--- This character's realm and name, as they're saved.
---@return string realm
---@return string name
function Inventory.Me()
    return realmName(), playerName()
end

--- A saved character, or nil.
---@return EternityUIBagsCharacter?
function Inventory:Character(realm, name)
    local chars = self:Bind().realms[realm]
    return chars and chars[name] or nil
end

--- The saved guild bank of a character's guild, or nil.
---@param char EternityUIBagsCharacter?
---@return EternityUIBagsGuild?
function Inventory:GuildOf(char)
    return char and char.guild and self:Bind().guilds[char.guild] or nil
end

function Inventory:Forget(realm, name)
    local db = self:Bind()
    if db.realms[realm] then
        db.realms[realm][name] = nil
        if next(db.realms[realm]) == nil then
            db.realms[realm] = nil
        end
    end
    self:PruneItems()
end

-- Scanning ----------------------------------------------------------------------------------

local function nameFromLink(link)
    return type(link) == "string" and not secret(link) and link:match("%[(.-)%]") or nil
end

--- Remembers an item's name, quality and icon for the Companion (the first values seen win;
--- missing ones are filled later).
function Inventory:Remember(id, name, quality, icon)
    local items = self:Bind().items
    local entry = items[id]
    if not entry then
        entry = {}
        items[id] = entry
    end
    if entry.name == nil and type(name) == "string" and name ~= "" and not secret(name) then
        entry.name = name
    end
    if entry.quality == nil and type(quality) == "number" and not secret(quality) then
        entry.quality = quality
    end
    if entry.icon == nil and type(icon) == "number" and not secret(icon) then
        entry.icon = icon
    end
end

--- Adds a bag's items to `items` (itemID -> count) and returns its slots for the layout.
function Inventory:ReadContainer(items, bag)
    local size = C_Container.GetContainerNumSlots(bag)
    local slots = {}
    for slot = 1, size do
        local info = C_Container.GetContainerItemInfo(bag, slot)
        local id = info and info.itemID
        if id and not secret(id) then
            local count = info.stackCount or 1
            if secret(count) then
                count = 1
            end
            items[id] = (items[id] or 0) + count
            slots[slot] = { id, count }
            self:Remember(id, info.itemName or nameFromLink(info.hyperlink), info.quality, info.iconFileID)
        end
    end
    return size, slots
end

local function bagKind(bag)
    local index = Enum.BagIndex or {}
    if bag == index.Keyring then
        return "keyring"
    elseif bag == index.ReagentBag then
        return "reagent"
    elseif bag == (index.Backpack or 0) then
        return "backpack"
    end
    return "bag"
end

--- Reads the bank tabs of a type: totals and containers.
function Inventory:ReadBank(bankType)
    local items, containers = {}, {}
    local tabs = C_Bank.FetchPurchasedBankTabData and C_Bank.FetchPurchasedBankTabData(bankType) or {}
    for i, tab in ipairs(tabs) do
        local size, slots = self:ReadContainer(items, tab.ID)
        local name = tab.name
        containers[#containers + 1] = {
            id = tab.ID,
            kind = "tab",
            name = type(name) == "string" and name ~= "" and name or L.TAB_N:format(i),
            size = size,
            slots = slots,
        }
    end
    return items, containers
end

local function layoutOf(char)
    if type(char.layout) ~= "table" then
        char.layout = { bags = {} }
    end
    return char.layout
end

function Inventory:ScanBags()
    local items, containers = {}, {}
    for _, bag in ipairs(Inventory.PlayerBags()) do
        local size, slots = self:ReadContainer(items, bag)
        if size > 0 then
            local kind = bagKind(bag)
            local name = kind == "bag" and C_Container.GetBagName and C_Container.GetBagName(bag) or nil
            containers[#containers + 1] = { id = bag, kind = kind, name = name, size = size, slots = slots }
        end
    end
    local char = self:Current()
    char.bags = items
    layoutOf(char).bags = containers
    char.updated = time()
    -- The guild the character is in, to find its guild bank (none: it left).
    local guild = GetGuildInfo and GetGuildInfo("player")
    if type(guild) == "string" and guild ~= "" and not secret(guild) then
        char.guild = realmName() .. "/" .. guild
    elseif IsInGuild and not IsInGuild() then
        char.guild = nil
    end
end

function Inventory:ScanEquipped()
    local items, bySlot = {}, {}
    for slot = FIRST_EQUIPPED, LAST_EQUIPPED do
        local id = GetInventoryItemID("player", slot)
        if id and not secret(id) then
            items[id] = (items[id] or 0) + 1
            bySlot[slot] = id
            self:Remember(
                id,
                nameFromLink(GetInventoryItemLink("player", slot)),
                GetInventoryItemQuality("player", slot),
                GetInventoryItemTexture("player", slot)
            )
        end
    end
    local char = self:Current()
    char.equipped = items
    layoutOf(char).equipped = bySlot
end

--- The bank only while it's open: closed, its bags report 0 slots and would wipe the snapshot.
function Inventory:ScanBank()
    if not self.bankOpen then
        return
    end
    local character, account = bankTypes()
    if Inventory.CanViewBank(character) then
        local items, containers = self:ReadBank(character)
        local char = self:Current()
        char.bank = items
        layoutOf(char).bank = containers
        char.bankUpdated = time()
    end
    if opt("inventory.warband") and Inventory.CanViewBank(account) then
        local items, containers = self:ReadBank(account)
        local warband = self:Bind().warband
        warband.items = items
        warband.tabs = containers
        warband.updated = time()
    end
end

-- Guild bank ---------------------------------------------------------------------------------

local GUILD_SLOTS = 98 -- MAX_GUILDBANK_SLOTS_PER_TAB in Blizzard_GuildBankUI
local QUERY_GAP = 0.4 -- seconds between tab requests
local QUERY_WAIT = 1.5 -- a tab asked for this long ago and still empty is empty

local function itemIDFromLink(link)
    if type(link) ~= "string" or secret(link) then
        return nil
    end
    return tonumber(link:match("item:(%d+)"))
end

--- Asks the server for every tab this character can see, a little apart: until a tab arrives
--- it reads as empty.
function Inventory:QueryGuildTabs()
    if not (GetNumGuildBankTabs and QueryGuildBankTab) then
        return
    end
    self.guildQueried = {}
    local delay = 0
    for tab = 1, GetNumGuildBankTabs() do
        local _, _, isViewable = GetGuildBankTabInfo(tab)
        if isViewable then
            C_Timer.After(delay, function()
                if self.guildOpen then
                    QueryGuildBankTab(tab)
                    self.guildQueried[tab] = GetTime()
                end
            end)
            delay = delay + QUERY_GAP
        end
    end
end

--- Reads the guild bank's tabs while it's open. A tab that hasn't arrived yet keeps its last
--- snapshot instead of being wiped.
function Inventory:ScanGuild()
    if not (self.guildOpen and opt("inventory.guild") and GetNumGuildBankTabs) then
        return
    end
    local guild = GetGuildInfo and GetGuildInfo("player")
    if type(guild) ~= "string" or guild == "" or secret(guild) then
        return
    end
    local db = self:Bind()
    local key = realmName() .. "/" .. guild
    local saved = db.guilds[key] or { name = guild, realm = realmName(), tabs = {} }
    local current = GetCurrentGuildBankTab and GetCurrentGuildBankTab()
    local tabs = {}
    for tab = 1, GetNumGuildBankTabs() do
        local name, icon, isViewable = GetGuildBankTabInfo(tab)
        if isViewable then
            local slots, found = {}, false
            for slot = 1, GUILD_SLOTS do
                local id = itemIDFromLink(GetGuildBankItemLink(tab, slot))
                if id then
                    local texture, count, _, _, quality = GetGuildBankItemInfo(tab, slot)
                    count = type(count) == "number" and not secret(count) and count or 1
                    slots[slot] = { id, count }
                    found = true
                    self:Remember(id, nameFromLink(GetGuildBankItemLink(tab, slot)), quality, texture)
                end
            end
            local asked = self.guildQueried and self.guildQueried[tab]
            local arrived = found or tab == current or (asked and GetTime() - asked >= QUERY_WAIT)
            local previous
            for _, old in ipairs(saved.tabs) do
                if old.index == tab then
                    previous = old
                end
            end
            tabs[#tabs + 1] = {
                id = tab,
                index = tab,
                kind = "guild",
                name = type(name) == "string" and name ~= "" and not secret(name) and name or L.TAB_N:format(tab),
                icon = type(icon) == "number" and not secret(icon) and icon or nil,
                size = GUILD_SLOTS,
                slots = (arrived or not previous) and slots or previous.slots,
            }
        end
    end
    saved.name, saved.realm, saved.tabs = guild, realmName(), tabs
    saved.updated = time()
    db.guilds[key] = saved
    self:Current().guild = key
end

-- Mail ---------------------------------------------------------------------------------------

local SEND_SLOTS = 12 -- ATTACHMENTS_MAX_SEND
local RECEIVE_SLOTS = 16 -- ATTACHMENTS_MAX_RECEIVE

--- Reads the mailbox while it's open: every attachment of the mails the client lists.
function Inventory:ScanMail()
    if not (self.mailOpen and opt("inventory.mail") and GetInboxNumItems and GetInboxItem) then
        return
    end
    local items = {}
    local count = GetInboxNumItems()
    for index = 1, type(count) == "number" and not secret(count) and count or 0 do
        for slot = 1, RECEIVE_SLOTS do
            local name, id, texture, stack, quality = GetInboxItem(index, slot)
            if type(id) == "number" and not secret(id) then
                stack = type(stack) == "number" and not secret(stack) and stack or 1
                items[id] = (items[id] or 0) + stack
                self:Remember(id, name, quality, texture)
            end
        end
    end
    local char = self:Current()
    char.mail = items
    char.mailUpdated = time()
end

--- The saved character a mail goes to, or nil: "Name" or "Name-Realm", by whole name or by first
--- name (Forever's names carry a surname). Only when it's one character, never this one.
---@param recipient string
---@return EternityUIBagsCharacter?
function Inventory:Recipient(recipient)
    if type(recipient) ~= "string" or secret(recipient) then
        return nil
    end
    recipient = recipient:gsub("^%s+", ""):gsub("%s+$", "")
    local name, realm = recipient:match("^(.-)%-(.+)$")
    if not name then
        name, realm = recipient, realmName()
    end
    name = name:lower()
    local myRealm, myName = realmName(), playerName()
    local chars = self:Bind().realms[realm] or self:Bind().realms[realm:gsub("%s", "")]
    if name == "" or type(chars) ~= "table" then
        return nil
    end
    local found, matches = nil, 0
    for saved, char in pairs(chars) do
        if not (realm == myRealm and saved == myName) then
            local lower = saved:lower()
            if lower == name then
                return char
            end
            if lower:match("^(%S+)") == name then
                found, matches = char, matches + 1
            end
        end
    end
    return matches == 1 and found or nil
end

--- After SendMail: what's attached, to count it for the recipient if the mail goes out.
function Inventory:OnSendMail(recipient)
    self.sending = nil
    if not (self.running and opt("inventory.track") and opt("inventory.mail") and GetSendMailItem) then
        return
    end
    local char = self:Recipient(recipient)
    if not char then
        return
    end
    local items = {}
    for slot = 1, SEND_SLOTS do
        local name, id, texture, stack, quality = GetSendMailItem(slot)
        if type(id) == "number" and not secret(id) then
            stack = type(stack) == "number" and not secret(stack) and stack or 1
            items[id] = (items[id] or 0) + stack
            self:Remember(id, name, quality, texture)
        end
    end
    if next(items) then
        self.sending = { char = char, items = items }
    end
end

--- The mail went out: its items are in the recipient's mailbox.
function Inventory:CommitSentMail()
    local sending = self.sending
    self.sending = nil
    if not sending then
        return
    end
    local mail = type(sending.char.mail) == "table" and sending.char.mail or {}
    for id, count in pairs(sending.items) do
        mail[id] = (mail[id] or 0) + count
    end
    sending.char.mail = mail
end

--- Forgets the item entries nobody carries any more.
function Inventory:PruneItems()
    local db = self:Bind()
    local used = {}
    local function mark(items)
        for id in pairs(type(items) == "table" and items or {}) do
            used[id] = true
        end
    end
    for _, chars in pairs(db.realms) do
        for _, char in pairs(chars) do
            mark(char.bags)
            mark(char.bank)
            mark(char.equipped)
            mark(char.mail)
        end
    end
    mark(db.warband.items)
    for _, guild in pairs(db.guilds) do
        for _, tab in ipairs(type(guild.tabs) == "table" and guild.tabs or {}) do
            for _, slot in pairs(type(tab.slots) == "table" and tab.slots or {}) do
                used[slot[1]] = true
            end
        end
    end
    for id in pairs(db.items) do
        if not used[id] then
            db.items[id] = nil
        end
    end
end

--- The gold this character has now.
function Inventory:ScanMoney()
    local money = GetMoney()
    if type(money) == "number" and not secret(money) then
        self:Current().money = money
    end
end

--- Every character whose gold is known, richest first, and the total: { realm, name, class,
--- money, current }.
---@return table[] list
---@return number total
function Inventory:MoneyList()
    local list, total = {}, 0
    for _, char in ipairs(self:Characters()) do
        local saved = self:Character(char.realm, char.name)
        local money = saved and saved.money
        if type(money) == "number" then
            char.money = money
            list[#list + 1] = char
            total = total + money
        end
    end
    table.sort(list, function(a, b)
        if a.money ~= b.money then
            return a.money > b.money
        end
        return a.name < b.name
    end)
    return list, total
end

function Inventory:ScanAll()
    self:ScanMoney()
    self:ScanBags()
    self:ScanEquipped()
    self:ScanBank()
    self:ScanMail()
    self:PruneItems()
end

-- Counting ----------------------------------------------------------------------------------

local function countIn(items, id)
    return type(items) == "table" and items[id] or 0
end

--- Who has the item, according to the tooltip options: owners sorted (this character first,
--- then by count) and the total. `force` overrides the "this character" and "warband bank" options
--- (the supply crates always count both).
---@param itemID integer
---@param force { current: boolean?, warband: boolean? }?
---@return EternityUIBagsOwner[] owners
---@return integer total
function Inventory:Owners(itemID, force)
    local db = self:Bind()
    local myRealm, myName = realmName(), playerName()
    local myFaction = UnitFactionGroup("player")
    local allRealms = opt("tooltip.realms") == "all"
    local sameFaction = opt("tooltip.faction") == "same"
    local withCurrent, withWarband = opt("tooltip.current"), opt("tooltip.warband")
    if force and force.current ~= nil then
        withCurrent = force.current
    end
    if force and force.warband ~= nil then
        withWarband = force.warband
    end
    local withMail = opt("inventory.mail")
    local owners, total = {}, 0
    for realm, chars in pairs(db.realms) do
        if allRealms or realm == myRealm then
            for name, char in pairs(chars) do
                local current = realm == myRealm and name == myName
                local shown = (not current or withCurrent)
                    and (not sameFaction or current or char.faction == myFaction)
                if shown then
                    local bags = countIn(char.bags, itemID)
                    local bank = countIn(char.bank, itemID)
                    local equipped = countIn(char.equipped, itemID)
                    local mail = withMail and countIn(char.mail, itemID) or 0
                    local sum = bags + bank + equipped + mail
                    if sum > 0 then
                        owners[#owners + 1] = {
                            name = realm == myRealm and name or (name .. "-" .. realm),
                            class = char.class,
                            current = current,
                            bags = bags,
                            bank = bank,
                            equipped = equipped,
                            mail = mail,
                            total = sum,
                        }
                        total = total + sum
                    end
                end
            end
        end
    end
    table.sort(owners, function(a, b)
        if a.current ~= b.current then
            return a.current
        end
        if a.total ~= b.total then
            return a.total > b.total
        end
        return a.name < b.name
    end)
    if withWarband then
        local count = countIn(db.warband.items, itemID)
        if count > 0 then
            owners[#owners + 1] = {
                name = L.WARBAND,
                warband = true,
                current = false,
                bags = 0,
                bank = count,
                equipped = 0,
                mail = 0,
                total = count,
            }
            total = total + count
        end
    end
    return owners, total
end

-- Tooltip -----------------------------------------------------------------------------------

local MODIFIERS = { shift = IsShiftKeyDown, ctrl = IsControlKeyDown, alt = IsAltKeyDown }

local function modifierHeld()
    local check = MODIFIERS[opt("tooltip.modifier")]
    return check == nil or check()
end

-- An icon per place, in the tooltip text: the client's own atlas when it has it, an item icon
-- (always there) when it doesn't.
local PLACE_ICONS = {
    bags = { atlas = "bag-main", file = "Interface\\Icons\\INV_Misc_Bag_08" },
    bank = { atlas = "Banker", file = "Interface\\Icons\\INV_Box_02" },
    mail = { atlas = "Mailbox", file = "Interface\\Icons\\INV_Letter_15" },
    equipped = { file = "Interface\\Icons\\INV_Shirt_White_01" },
}
local ICON_SIZE = 14
local iconCache = {}

--- The inline icon of a place (bags, bank, mail, equipped).
---@param place string
---@return string
function Inventory.PlaceIcon(place)
    if iconCache[place] then
        return iconCache[place]
    end
    local icon = PLACE_ICONS[place]
    local markup
    local hasAtlas = icon.atlas and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(icon.atlas)
    if hasAtlas then
        markup = ("|A:%s:%d:%d|a"):format(icon.atlas, ICON_SIZE, ICON_SIZE)
    else
        markup = ("|T%s:%d:%d:0:0:64:64:5:59:5:59|t"):format(icon.file, ICON_SIZE, ICON_SIZE)
    end
    iconCache[place] = markup
    return markup
end

--- An owner's count with where it is: "12 (bank)", "12 (bags 3, bank 9)", or with the tooltip's
--- icons option, an icon per place: "12 [bank]", "3 [bags]  9 [bank]".
function Inventory.Breakdown(owner)
    if owner.warband then
        return tostring(owner.total)
    end
    local places = {}
    local all = {
        { L.IN_BAGS, owner.bags, "bags" },
        { L.IN_BANK, owner.bank, "bank" },
        { L.IN_MAIL, owner.mail or 0, "mail" },
        { L.EQUIPPED, owner.equipped, "equipped" },
    }
    for _, place in ipairs(all) do
        if place[2] > 0 then
            places[#places + 1] = place
        end
    end
    if opt("tooltip.icons") then
        if #places == 1 then
            return owner.total .. " " .. Inventory.PlaceIcon(places[1][3])
        end
        local parts = {}
        for i, place in ipairs(places) do
            parts[i] = place[2] .. " " .. Inventory.PlaceIcon(place[3])
        end
        return table.concat(parts, "  ")
    end
    -- A single place: "12 (bank)"; several: "12 (bags 3, bank 9)".
    if #places == 1 then
        return owner.total .. " (" .. places[1][1] .. ")"
    end
    local parts = {}
    for i, place in ipairs(places) do
        parts[i] = place[1] .. " " .. place[2]
    end
    return owner.total .. " (" .. table.concat(parts, ", ") .. ")"
end

--- The color of an owner's name: its class (if the option is on) or the warband bank's.
function Inventory.NameColor(owner)
    if owner.warband then
        return 0.6, 0.8, 1
    end
    if opt("tooltip.classColors") and owner.class and C_ClassColor then
        local color = C_ClassColor.GetClassColor(owner.class)
        if color then
            return color:GetRGB()
        end
    end
    return 1, 0.82, 0
end

--- Lines for the item in `tip`: one per owner and the total.
function Inventory:AddLines(tip, itemID)
    local owners, total = self:Owners(itemID)
    if #owners == 0 then
        return
    end
    local detail = opt("tooltip.breakdown")
    tip:AddLine(" ")
    for _, owner in ipairs(owners) do
        local r, g, b = Inventory.NameColor(owner)
        tip:AddDoubleLine(owner.name, detail and Inventory.Breakdown(owner) or tostring(owner.total), r, g, b, 1, 1, 1)
    end
    if opt("tooltip.total") and #owners > 1 then
        tip:AddDoubleLine(L.TOTAL, tostring(total), 0.64, 0.62, 0.72, 1, 1, 1)
    end
end

function Inventory:OnTooltipItem(tip, data)
    if not self.running then
        return
    end
    -- Only GameTooltip-like frames (the comparison and embedded ones too, but not shopping lists).
    if not tip or not tip.AddDoubleLine or (tip.IsForbidden and tip:IsForbidden()) then
        return
    end
    local id = data and data.id
    if not id or secret(id) or type(id) ~= "number" then
        return
    end
    -- A supply crate: its material and who has it, whatever the "who has it" options say.
    if opt("supplies.enabled") then
        ns.Supplies.AddLines(tip, id, data)
    end
    if opt("tooltip.enabled") and modifierHeld() then
        self:AddLines(tip, id)
    end
end

-- Lifecycle ---------------------------------------------------------------------------------

local EVENTS = {
    "PLAYER_ENTERING_WORLD",
    "BAG_UPDATE_DELAYED",
    "PLAYER_EQUIPMENT_CHANGED",
    "BANKFRAME_OPENED",
    "BANKFRAME_CLOSED",
    "PLAYERBANKSLOTS_CHANGED",
    "GUILDBANKFRAME_OPENED",
    "GUILDBANKFRAME_CLOSED",
    "GUILDBANKBAGSLOTS_CHANGED",
    "PLAYER_MONEY",
    "MAIL_SHOW",
    "MAIL_CLOSED",
    "MAIL_INBOX_UPDATE",
    "MAIL_SEND_SUCCESS",
    "MAIL_FAILED",
}

function Inventory:OnEvent(event)
    if event == "BANKFRAME_OPENED" then
        self.bankOpen = true
    elseif event == "BANKFRAME_CLOSED" then
        -- No last read: once closing, the bank bags may already report 0 slots.
        self.bankOpen = false
        return
    elseif event == "GUILDBANKFRAME_OPENED" then
        self.guildOpen = true
    elseif event == "GUILDBANKFRAME_CLOSED" then
        self.guildOpen = false
        return
    elseif event == "MAIL_SHOW" then
        self.mailOpen = true
    elseif event == "MAIL_CLOSED" then
        self.mailOpen = false
        return
    elseif event == "MAIL_FAILED" then
        self.sending = nil
        return
    end
    if not self.running or not opt("inventory.track") then
        return
    end
    if event == "GUILDBANKFRAME_OPENED" then
        if opt("inventory.guild") then
            self:QueryGuildTabs()
            self:ScanGuild()
        end
        return
    elseif event == "GUILDBANKBAGSLOTS_CHANGED" then
        self:ScanGuild()
        return
    end
    if event == "MAIL_SHOW" or event == "MAIL_INBOX_UPDATE" then
        self:ScanMail()
        return
    elseif event == "MAIL_SEND_SUCCESS" then
        self:CommitSentMail()
        return
    end
    if event == "PLAYER_MONEY" then
        self:ScanMoney()
    elseif event == "PLAYER_ENTERING_WORLD" then
        self:ScanAll()
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        self:ScanEquipped()
    elseif event == "BAG_UPDATE_DELAYED" then
        self:ScanBags()
        self:ScanBank()
    else
        self:ScanBank()
    end
end

function Inventory:InstallHooks()
    self.hooked = true
    if TooltipDataProcessor and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tip, data)
            self:OnTooltipItem(tip, data)
        end)
    end
    -- What's attached is read right after SendMail, before Blizzard empties the form.
    if _G.SendMail then
        hooksecurefunc("SendMail", function(recipient)
            self:OnSendMail(recipient)
        end)
    end
    -- Bank state is followed even while stopped, so enabling with the bank open knows it.
    local events = CreateFrame("Frame")
    for _, event in ipairs(EVENTS) do
        -- An event this client doesn't have errors on RegisterEvent: skip it.
        pcall(events.RegisterEvent, events, event)
    end
    events:SetScript("OnEvent", function(_, event)
        self:OnEvent(event)
    end)
    self.events = events
end

function Inventory:Start()
    self.running = true
    if not self.hooked then
        self:InstallHooks()
        -- Enabled with the bank already open: the events of this visit were missed.
        self.bankOpen = _G.BankFrame ~= nil and _G.BankFrame:IsShown()
        self.mailOpen = _G.MailFrame ~= nil and _G.MailFrame:IsShown()
    end
    self:Bind()
    if opt("inventory.track") then
        self:ScanAll()
    end
end

function Inventory:Stop()
    self.running = false
end
