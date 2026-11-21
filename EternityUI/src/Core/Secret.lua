-- Secret values: the one place that asks whether a value can be read. Nothing here tries to work
-- out what a secret holds; a secret is either passed untouched to a widget that accepts it or
-- replaced by a fallback.
---@type string, EternityUINamespace
local _, ns = ...

---@class EternitySecret
local Secret = {}
ns.Secret = Secret
EternityUI.Secret = Secret

--- True if value is secret. Comparing or doing arithmetic on such a value throws.
---@param value any
---@return boolean
function Secret.Is(value)
    return issecretvalue ~= nil and issecretvalue(value) or false
end

--- The value, or fallback if it's secret.
---@param value any
---@param fallback any
---@return any
function Secret.Plain(value, fallback)
    if Secret.Is(value) then
        return fallback
    end
    return value
end

--- True if none of the arguments is secret.
---@return boolean
function Secret.Known(...)
    for i = 1, select("#", ...) do
        if Secret.Is((select(i, ...))) then
            return false
        end
    end
    return true
end

--- True while auras are secret. This can start before InCombatLockdown() turns true.
---@return boolean
function Secret.AurasRestricted()
    return C_Secrets ~= nil and C_Secrets.ShouldAurasBeSecret() and true or false
end

local function realmText(value)
    if type(value) ~= "string" or Secret.Is(value) or value == "" then
        return nil
    end
    return value
end

--- The realm's name, for keys of saved data. Forever's GetRealmName can answer "" (seen from
--- November 2026 on), which saved every character a second time under an empty realm; then the
--- last name seen is used (EternityUIDB.realm, account wide). guess, a realm a module already
--- knows (from its own saved data), stands in when none was ever seen, and is kept from then on.
--- nil while nothing is known.
---@param guess string?
---@return string?
function EternityUI.RealmName(guess)
    local db = _G.EternityUIDB
    local realm = realmText(GetRealmName and GetRealmName())
    if realm then
        if type(db) == "table" then
            db.realm = realm
        end
        return realm
    end
    local known = type(db) == "table" and realmText(db.realm) or nil
    if known then
        return known
    end
    guess = realmText(guess)
    if guess and type(db) == "table" then
        db.realm = guess
    end
    return guess
end
