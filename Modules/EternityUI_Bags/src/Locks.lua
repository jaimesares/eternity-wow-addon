-- EternityUI_Bags: locked slots, and the sort that leaves them alone.
--   * A locked slot keeps what it holds (or stays empty) when the bags or the bank are sorted.
--     The locks are this character's, saved in EternityUIBagsDB (char.locks, "bag:slot").
--   * Eternity's sort (windows.sortMode, the default): Blizzard's (C_Container.SortBags /
--     SortBank) can't skip a slot, so this one moves the items one at a time with
--     C_Container.PickupContainerItem, as a player would, waiting for each move to end. Only
--     normal bags take part (no keyring, reagent bag, quiver or profession bag), and never in
--     combat: entering it stops the sort.
--   * Order: like items together (weapons, armor, consumables, trade goods... junk last), better
--     quality and item level first, then name; partial stacks of the same item are merged first.

---@type string, EternityUIBagsNamespace
local addonName, ns = ...
local E = EternityUI
local L, Inventory = ns.L, ns.Inventory

local STEP = 0.05 -- seconds between moves
local MAX_STEPS = 600
local MAX_WAIT = 5 -- seconds a move may take before the sort gives up

-- Item classes in the order they're sorted into (Enum.ItemClass); others after them.
local CLASS_ORDER = { [2] = 1, [4] = 2, [0] = 3, [1] = 4, [11] = 5, [7] = 6, [5] = 7, [9] = 8, [3] = 9, [16] = 10, [12] = 11, [15] = 12 }

---@class EternityUIBagsLocks
---@field running table? the sort in progress: { grid, steps, waited, elapsed }
local Locks = {}
ns.Locks = Locks

local function opt(path)
    return E.store:Get(addonName, path)
end

local function say(text)
    print("|cff8b5cf6Eternity Bags|r: " .. text)
end

local function key(bag, slot)
    return bag .. ":" .. slot
end

-- This character's locks (created on the first lock).
local function store(create)
    local char = Inventory:Current()
    if create and type(char.locks) ~= "table" then
        char.locks = {}
    end
    return type(char.locks) == "table" and char.locks or nil
end

--- Whether a slot is locked.
---@param bag integer
---@param slot integer
---@return boolean
function Locks.Is(bag, slot)
    local locks = store(false)
    return locks ~= nil and locks[key(bag, slot)] == true
end

--- Locks a slot, or unlocks it. Returns whether it's locked now.
---@param bag integer
---@param slot integer
---@return boolean
function Locks.Toggle(bag, slot)
    local locks = store(true)
    local k = key(bag, slot)
    locks[k] = not locks[k] or nil
    return locks[k] == true
end

--- Whether any slot of these bags is locked.
---@param bags integer[]
---@return boolean
function Locks.Any(bags)
    local locks = store(false)
    if not locks or next(locks) == nil then
        return false
    end
    local wanted = {}
    for _, bag in ipairs(bags) do
        wanted[bag] = true
    end
    for k in pairs(locks) do
        local bag = tonumber(k:match("^(%-?%d+):"))
        if bag and wanted[bag] then
            return true
        end
    end
    return false
end

-- Planning --------------------------------------------------------------------------------------

-- Whether a bag takes part: a normal bag (family 0), not the keyring or the reagent bag.
local function sortable(bag)
    local index = Enum.BagIndex or {}
    if bag == index.Keyring or bag == index.ReagentBag then
        return false
    end
    local _, family = C_Container.GetContainerNumFreeSlots(bag)
    return family == nil or family == 0
end

-- What a slot holds, as the plan needs it; nil if it's empty.
local function readItem(bag, slot)
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if not info or not info.itemID then
        return nil
    end
    local id = info.itemID
    local _, _, _, _, _, classID, subclassID = C_Item.GetItemInfoInstant(id)
    local name, _, _, level, _, _, _, maxStack = C_Item.GetItemInfo(info.hyperlink or id)
    return {
        id = id,
        link = info.hyperlink or tostring(id),
        count = info.stackCount or 1,
        maxStack = maxStack or 1,
        quality = info.quality or 1,
        class = classID or 99,
        subclass = subclassID or 0,
        level = level or 0,
        name = name or info.itemName or "",
        locked = info.isLocked,
    }
end

--- The slots that take part in a sort of these bags, in order: { bag, slot, item?, locked }.
---@param bags integer[]
---@return table[]
function Locks.ReadSlots(bags)
    local slots = {}
    for _, bag in ipairs(bags) do
        if sortable(bag) then
            for slot = 1, C_Container.GetContainerNumSlots(bag) do
                slots[#slots + 1] = { bag = bag, slot = slot, item = readItem(bag, slot), locked = Locks.Is(bag, slot) }
            end
        end
    end
    return slots
end

-- Sort order: junk last, then the classes' order, subclass, quality and level (higher first),
-- name, id, link and the bigger stack first.
local function before(a, b)
    local junkA, junkB = a.quality == 0, b.quality == 0
    if junkA ~= junkB then
        return junkB
    end
    local classA, classB = CLASS_ORDER[a.class] or 50 + a.class, CLASS_ORDER[b.class] or 50 + b.class
    if classA ~= classB then
        return classA < classB
    elseif a.subclass ~= b.subclass then
        return a.subclass < b.subclass
    elseif a.quality ~= b.quality then
        return a.quality > b.quality
    elseif a.level ~= b.level then
        return a.level > b.level
    elseif a.name ~= b.name then
        return a.name < b.name
    elseif a.id ~= b.id then
        return a.id < b.id
    elseif a.link ~= b.link then
        return a.link < b.link
    end
    return a.count > b.count
end
Locks.Before = before

local function same(a, b)
    return a ~= nil and b ~= nil and a.link == b.link and a.count == b.count
end

--- The next move of a sort, from the slots as they are now (see ReadSlots): { from, to } with
--- two slots, or nil when everything is in place. Merges come first, then each unlocked slot in
--- turn gets the item that belongs there. reverse fills the slots from the end.
---@param slots table[]
---@param reverse boolean?
---@return table?
function Locks.NextMove(slots, reverse)
    local free = {}
    for _, s in ipairs(slots) do
        if not s.locked then
            free[#free + 1] = s
        end
    end
    -- Partial stacks of the same item: the later one onto the earlier one.
    local partial = {}
    for _, s in ipairs(free) do
        local item = s.item
        if item and item.maxStack > 1 and item.count < item.maxStack then
            local first = partial[item.link]
            if first then
                return { from = s, to = first }
            end
            partial[item.link] = s
        end
    end
    local items = {}
    for _, s in ipairs(free) do
        if s.item then
            items[#items + 1] = s.item
        end
    end
    table.sort(items, before)
    local order = free
    if reverse then
        order = {}
        for i = #free, 1, -1 do
            order[#order + 1] = free[i]
        end
    end
    for i, wanted in ipairs(items) do
        local target = order[i]
        if not same(target.item, wanted) then
            for j = i + 1, #order do
                if same(order[j].item, wanted) then
                    return { from = order[j], to = target }
                end
            end
            return nil -- can't happen with a consistent read; stop rather than loop
        end
    end
    return nil
end

-- Running ---------------------------------------------------------------------------------------

local runner = CreateFrame("Frame")
runner:Hide()

local function stop(message)
    local run = Locks.running
    Locks.running = nil
    runner:Hide()
    if message then
        say(message)
    end
    if run and run.grid and run.grid.frame:IsShown() then
        run.grid:Refresh()
    end
end
Locks.Stop = stop

-- Whether any slot that takes part is still moving (locked by the game).
local function busy(slots)
    for _, s in ipairs(slots) do
        if s.item and s.item.locked then
            return true
        end
    end
    return false
end

runner:SetScript("OnUpdate", function(_, elapsed)
    local run = Locks.running
    if not run then
        runner:Hide()
        return
    end
    run.elapsed = run.elapsed + elapsed
    if run.elapsed < STEP then
        return
    end
    run.elapsed = 0
    if InCombatLockdown() then
        stop(L.SORT_COMBAT)
        return
    end
    local slots = Locks.ReadSlots(run.grid:Bags())
    if GetCursorInfo() or busy(slots) then
        run.waited = run.waited + STEP
        if run.waited > MAX_WAIT then
            stop(L.SORT_STOPPED)
        end
        return
    end
    run.waited = 0
    local move = Locks.NextMove(slots, opt("windows.sortReverse"))
    if not move then
        stop(nil)
        return
    end
    run.steps = run.steps + 1
    if run.steps > MAX_STEPS then
        stop(L.SORT_STOPPED)
        return
    end
    C_Container.PickupContainerItem(move.from.bag, move.from.slot)
    C_Container.PickupContainerItem(move.to.bag, move.to.slot)
    -- Whatever is left on the cursor (a stack that didn't fit) goes back where it came from.
    if GetCursorInfo() then
        C_Container.PickupContainerItem(move.from.bag, move.from.slot)
    end
end)

--- Sorts a window's bags around its locked slots.
---@param grid EternityUIBagsGrid
function Locks.Sort(grid)
    if InCombatLockdown() then
        say(L.SORT_COMBAT)
        return
    end
    if Locks.running then
        return
    end
    Locks.running = { grid = grid, steps = 0, waited = 0, elapsed = STEP }
    runner:Show()
end

--- Whether a sort is running.
---@return boolean
function Locks.Busy()
    return Locks.running ~= nil
end
