-- The distance to a unit worked out from spell ranges, as LibRangeCheck-style addons do: the
-- game has no exact distance to enemies, but C_Spell.IsSpellInRange answers in combat too (its
-- answer isn't secret on Forever). Each known spell narrows a bracket [low, high]:
--   * in range: low >= its minimum and high <= its maximum;
--   * out of range without a minimum: low >= its maximum;
--   * out of range with a minimum (Auto Shot's 8 yards): too far or too close. Settled by the
--     other spells: once low reaches its minimum it's too far, once high is within its maximum
--     it's too close.
-- Out of combat the game's interaction distances (duel about 10 yards, follow about 28) help too.
-- The zone (melee, dead zone, in range, out of range) comes from the class's main attack.

---@type string, EternityUIRangeNamespace
local _, ns = ...
local E = EternityUI

local Distance = {}
ns.Distance = Distance

-- Spells whose range is asked, per class: attacks for enemies, heals or buffs for friends.
-- Forever's own (1.x) IDs; only those the player knows count.
local SPELLS = {
    hostile = {
        HUNTER = { 2974, 2973, 75, 3044, 1978, 5116, 1130 },
        MAGE = { 133, 116, 2136, 5143 },
        WARLOCK = { 686, 172, 5782 },
        PRIEST = { 585, 589, 8092 },
        DRUID = { 5176, 8921, 770, 6795, 1082 },
        SHAMAN = { 403, 8042, 370 },
        PALADIN = { 879, 20271, 853 },
        ROGUE = { 1752, 2764, 1766 },
        WARRIOR = { 78, 100, 355, 2764 },
    },
    friendly = {
        PRIEST = { 2050, 2061, 17 },
        DRUID = { 5185, 774 },
        SHAMAN = { 331, 8004 },
        PALADIN = { 635, 19750 },
        MAGE = { 1459 },
        WARLOCK = { 5697 },
    },
}
Distance.SPELLS = SPELLS

-- The main ranged attack of each class: in its range is "in range". Classes not listed fight in
-- melee, so melee reach is their "in range".
local MAIN = {
    HUNTER = { 75, 3044 },
    MAGE = { 133, 116 },
    WARLOCK = { 686 },
    PRIEST = { 585, 589 },
    DRUID = { 5176, 8921 },
    SHAMAN = { 403 },
}
Distance.MAIN = MAIN

local MELEE = 5 -- a spell reaching this far or less is a melee one
local DUEL, FOLLOW = 10, 28 -- the game's interaction distances 3 and 4

local cache = {} -- "kind" -> list of { id, low, high } the player knows

local function try(fn, ...)
    local ok, a, b = pcall(fn, ...)
    if ok then
        return a, b
    end
end

local function plain(value)
    if E.Secret.Is(value) then
        return nil
    end
    return value
end

-- A spell's minimum and maximum range (0 and nil when the game doesn't say).
local function reach(id)
    local info = C_Spell and C_Spell.GetSpellInfo and try(C_Spell.GetSpellInfo, id)
    if type(info) ~= "table" then
        return 0, nil
    end
    local low, high = plain(info.minRange), plain(info.maxRange)
    return type(low) == "number" and low or 0, type(high) == "number" and high > 0 and high or nil
end

local function playerClass()
    local _, class = UnitClass("player")
    return plain(class)
end

--- The spells of a kind the player knows, with their reach.
---@param kind string "hostile" or "friendly"
---@return table[]
function Distance.Known(kind)
    if not cache[kind] then
        local list = {}
        for _, id in ipairs(SPELLS[kind][playerClass() or ""] or {}) do
            if IsPlayerSpell and IsPlayerSpell(id) then
                local low, high = reach(id)
                if high then
                    list[#list + 1] = { id = id, low = low, high = high }
                end
            end
        end
        cache[kind] = list
    end
    return cache[kind]
end

--- Forgets the spells found (new spells learned).
function Distance.Reset()
    cache = {}
end

local function inRange(id, unit)
    local result = C_Spell and C_Spell.IsSpellInRange and try(C_Spell.IsSpellInRange, id, unit)
    result = plain(result)
    if type(result) == "boolean" then
        return result
    end
    return nil
end

local function interact(unit, index)
    if not CheckInteractDistance or InCombatLockdown() then
        return nil
    end
    local near = plain(try(CheckInteractDistance, unit, index))
    return type(near) == "boolean" and near or nil
end

--- Narrows [low, high] with a list of answers { low, high, result }.
---@param answers table[]
---@return number low
---@return number high math.huge when unknown
function Distance.Bracket(answers)
    local low, high = 0, math.huge
    local pending = {}
    for _, a in ipairs(answers) do
        if a.result == true then
            low, high = math.max(low, a.low), math.min(high, a.high)
        elseif a.result == false then
            if a.low <= 0 then
                low = math.max(low, a.high)
            else
                pending[#pending + 1] = a
            end
        end
    end
    -- Out with a minimum: too far or too close, whichever the rest allows. Twice, since one
    -- settled answer can settle another.
    for _ = 1, 2 do
        for i = #pending, 1, -1 do
            local a = pending[i]
            if low >= a.low then
                low = math.max(low, a.high)
                table.remove(pending, i)
            elseif high <= a.high then
                high = math.min(high, a.low)
                table.remove(pending, i)
            end
        end
    end
    if low > high then
        -- Ranges count the unit's size, so answers can disagree by a little: trust the farthest.
        high = math.huge
    end
    return low, high
end

-- The zone of a bracket for the player's class: "melee", "dead", "in" or "out".
local function zone(low, high, answers, kind)
    local byId = {}
    for _, a in ipairs(answers) do
        -- The interaction distances (duel, follow) have no spell id.
        if a.id then
            byId[a.id] = a
        end
    end
    if kind == "friendly" then
        for _, a in ipairs(answers) do
            if a.result == true then
                return "in"
            end
        end
        return "out"
    end
    local main
    for _, id in ipairs(MAIN[playerClass() or ""] or {}) do
        if byId[id] then
            main = byId[id]
            break
        end
    end
    local melee = high <= MELEE
    if not main then
        return melee and "in" or "out"
    end
    if main.result == true then
        return "in"
    elseif melee then
        return "melee"
    elseif main.low > 0 and high <= main.low then
        return "dead"
    end
    return "out"
end

Distance.Zone = zone

--- The distance to a unit: low, high (math.huge when unknown) and its zone, or nil when it can't
--- be told (no spell for that kind of unit and in combat).
---@param unit string
---@param kind string "hostile" or "friendly"
---@return number? low
---@return number? high
---@return string? zone
function Distance.Measure(unit, kind)
    local answers = {}
    for _, spell in ipairs(Distance.Known(kind)) do
        local result = inRange(spell.id, unit)
        if result ~= nil then
            answers[#answers + 1] = { id = spell.id, low = spell.low, high = spell.high, result = result }
        end
    end
    local duel, follow = interact(unit, 3), interact(unit, 4)
    if duel ~= nil then
        answers[#answers + 1] = { low = 0, high = DUEL, result = duel }
    end
    if follow ~= nil then
        answers[#answers + 1] = { low = 0, high = FOLLOW, result = follow }
    end
    if #answers == 0 then
        return nil
    end
    local low, high = Distance.Bracket(answers)
    return low, high, zone(low, high, answers, kind)
end

--- A bracket as text: "0-5", "8-35", "35+".
---@param low number
---@param high number
---@return string
function Distance.Format(low, high)
    low, high = math.floor(low + 0.5), high
    if high == math.huge then
        return low .. "+"
    end
    return low .. "-" .. math.floor(high + 0.5)
end
