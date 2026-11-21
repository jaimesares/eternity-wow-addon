-- The discs (EternityUIDiscsDB): account-wide discs with their slots, and keys per character.
-- They don't fit in options.json (no lists there), so they live in their own SavedVariable,
-- outside Eternity's profiles.

---@type string, EternityUIDiscsNamespace
local _, ns = ...

local SCHEMA_VERSION = 1
local MAX_SLOTS = 24

---One slot of a disc. kind decides which fields it uses:
---spell (id), item (id), toy (id), macro (macro = macro name), text (text = macro text),
---disc (disc = disc id), hearthstone and professions (resolved on the character).
---name and icon override the resolved ones.
---@class EternityUIDiscsSlot
---@field kind string
---@field id number?
---@field macro string?
---@field text string?
---@field disc number?
---@field name string?
---@field icon number|string|nil

---@class EternityUIDiscsDisc
---@field id number
---@field name string
---@field icon number|string|nil
---@field generated boolean? created by the general disc button (pressing it again rebuilds it)
---@field slots EternityUIDiscsSlot[]

---@class EternityUIDiscsStore
---@field db table?
---@field listeners fun()[]
local Store = { listeners = {}, MAX_SLOTS = MAX_SLOTS }
ns.Store = Store

local KINDS = {
    spell = true,
    item = true,
    toy = true,
    macro = true,
    text = true,
    disc = true,
    hearthstone = true,
    professions = true,
}
Store.KINDS = KINDS

local function validSlot(slot)
    return type(slot) == "table" and KINDS[slot.kind] ~= nil
end

--- Binds EternityUIDiscsDB (the client loads it before ADDON_LOADED of this addon), dropping
--- anything malformed.
function Store:Bind()
    if self.db then
        return self.db
    end
    local db = _G.EternityUIDiscsDB
    if type(db) ~= "table" then
        db = {}
    end
    db.version = SCHEMA_VERSION
    db.discs = type(db.discs) == "table" and db.discs or {}
    db.order = type(db.order) == "table" and db.order or {}
    db.characters = type(db.characters) == "table" and db.characters or {}
    db.nextId = tonumber(db.nextId) or 1

    -- Discs: by id, with valid slots; order lists each existing disc once.
    local discs, seen, order = {}, {}, {}
    for key, disc in pairs(db.discs) do
        local id = tonumber(key)
        if id and type(disc) == "table" then
            local slots = {}
            for _, slot in ipairs(type(disc.slots) == "table" and disc.slots or {}) do
                if validSlot(slot) and #slots < MAX_SLOTS then
                    slots[#slots + 1] = slot
                end
            end
            disc.id, disc.slots = id, slots
            disc.name = type(disc.name) == "string" and disc.name or ns.L.NEW_DISC
            discs[id] = disc
            db.nextId = math.max(db.nextId, id + 1)
        end
    end
    for _, id in ipairs(db.order) do
        if discs[id] and not seen[id] then
            seen[id] = true
            order[#order + 1] = id
        end
    end
    for id in pairs(discs) do
        if not seen[id] then
            order[#order + 1] = id
        end
    end
    db.discs, db.order = discs, order
    _G.EternityUIDiscsDB = db
    self.db = db
    return db
end

--- Forgets the bound table (tests: the next Bind reads _G.EternityUIDiscsDB again).
function Store:Unbind()
    self.db = nil
end

--- Calls fn() after every change.
function Store:OnChange(fn)
    self.listeners[#self.listeners + 1] = fn
end

function Store:Changed()
    for _, fn in ipairs(self.listeners) do
        fn()
    end
end

---@return EternityUIDiscsDisc[] discs in order
function Store:List()
    local db = self:Bind()
    local list = {}
    for _, id in ipairs(db.order) do
        list[#list + 1] = db.discs[id]
    end
    return list
end

---@return EternityUIDiscsDisc?
function Store:Get(id)
    return self:Bind().discs[id]
end

---@param name string?
---@return EternityUIDiscsDisc
function Store:Create(name)
    local db = self:Bind()
    local disc = { id = db.nextId, name = name or ns.L.NEW_DISC, slots = {} }
    db.nextId = db.nextId + 1
    db.discs[disc.id] = disc
    db.order[#db.order + 1] = disc.id
    self:Changed()
    return disc
end

--- Deletes a disc, the slots of other discs that open it and its keys on every character.
function Store:Delete(id)
    local db = self:Bind()
    if not db.discs[id] then
        return
    end
    db.discs[id] = nil
    for i = #db.order, 1, -1 do
        if db.order[i] == id then
            table.remove(db.order, i)
        end
    end
    for _, disc in pairs(db.discs) do
        for i = #disc.slots, 1, -1 do
            if disc.slots[i].kind == "disc" and disc.slots[i].disc == id then
                table.remove(disc.slots, i)
            end
        end
    end
    for _, character in pairs(db.characters) do
        if type(character.keys) == "table" then
            character.keys[id] = nil
        end
    end
    self:Changed()
end

function Store:Rename(id, name)
    local disc = self:Get(id)
    if disc and type(name) == "string" and name ~= "" then
        disc.name = name
        self:Changed()
    end
end

--- true if `from` reaches `to` through its disc slots (so `to` can't hold `from`).
function Store:Reaches(from, to, seen)
    if from == to then
        return true
    end
    seen = seen or {}
    if seen[from] then
        return false
    end
    seen[from] = true
    local disc = self:Get(from)
    for _, slot in ipairs(disc and disc.slots or {}) do
        if slot.kind == "disc" and self:Reaches(slot.disc, to, seen) then
            return true
        end
    end
    return false
end

--- Adds a slot at the end. Fails on a full disc or on a disc slot that would make a loop.
---@return boolean ok, string? reason
function Store:AddSlot(id, slot)
    local disc = self:Get(id)
    if not disc or not validSlot(slot) or #disc.slots >= MAX_SLOTS then
        return false
    end
    if slot.kind == "disc" and (not self:Get(slot.disc) or self:Reaches(slot.disc, id)) then
        return false, "cycle"
    end
    disc.slots[#disc.slots + 1] = slot
    self:Changed()
    return true
end

function Store:RemoveSlot(id, index)
    local disc = self:Get(id)
    if disc and disc.slots[index] then
        table.remove(disc.slots, index)
        self:Changed()
    end
end

--- Moves a slot by `delta` places (-1 up, 1 down).
function Store:MoveSlot(id, index, delta)
    local disc = self:Get(id)
    local target = index + delta
    if disc and disc.slots[index] and disc.slots[target] then
        disc.slots[index], disc.slots[target] = disc.slots[target], disc.slots[index]
        self:Changed()
    end
end

--- Changes a slot's own name or icon (nil = back to the resolved one).
function Store:SetSlotLook(id, index, name, icon)
    local disc = self:Get(id)
    local slot = disc and disc.slots[index]
    if slot then
        slot.name, slot.icon = name, icon
        self:Changed()
    end
end

-- Keys per character ---------------------------------------------------------------------------

-- The realm comes from the core: Forever's GetRealmName can answer "", which once saved the keys
-- under "-Name"; those are the newest, so they take that character's place.
local function characterKey()
    local name = UnitName("player") or "?"
    return (EternityUI.RealmName() or "?") .. "-" .. name, "-" .. name
end

---@return table<number, string> disc id → key (e.g. "CTRL-Q")
function Store:Keys()
    local db = self:Bind()
    local key, emptyRealm = characterKey()
    if key ~= emptyRealm and type(db.characters[emptyRealm]) == "table" then
        db.characters[key] = db.characters[emptyRealm]
        db.characters[emptyRealm] = nil
    end
    local character = db.characters[key]
    if type(character) ~= "table" then
        character = {}
        db.characters[key] = character
    end
    character.keys = type(character.keys) == "table" and character.keys or {}
    return character.keys
end

--- Binds `key` to the disc on this character; a key belongs to one disc only. nil unbinds it.
function Store:SetKey(id, key)
    local keys = self:Keys()
    if key then
        for other, bound in pairs(keys) do
            if bound == key then
                keys[other] = nil
            end
        end
    end
    keys[id] = key
    self:Changed()
end

-- General disc ---------------------------------------------------------------------------------

--- Creates the general disc (hearthstone + professions) or rebuilds the one it created before.
---@return EternityUIDiscsDisc
function Store:Generate()
    for _, disc in ipairs(self:List()) do
        if disc.generated then
            disc.slots = { { kind = "hearthstone" }, { kind = "professions" } }
            self:Changed()
            return disc
        end
    end
    local db = self:Bind()
    local disc = {
        id = db.nextId,
        name = ns.L.GENERAL_DISC,
        generated = true,
        slots = { { kind = "hearthstone" }, { kind = "professions" } },
    }
    db.nextId = db.nextId + 1
    db.discs[disc.id] = disc
    table.insert(db.order, 1, disc.id)
    self:Changed()
    return disc
end
