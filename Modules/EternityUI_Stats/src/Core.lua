-- EternityUI_Stats core: helpers the other files share (options, secret guard, colors, the
-- per-character saved state).

---@type string, EternityUIStatsNamespace
local addonName, ns = ...
local E = EternityUI
local Theme = ns.Ui.Theme

---@class EternityUIStatsCore
---@field running boolean? between the module's OnEnable and OnDisable
local Core = {}
ns.Core = Core

--- An option of this module ("group.option").
function Core.Opt(path)
    return E.store:Get(addonName, path)
end

--- True for a secret value (always false on clients without secrets).
function Core.Secret(value)
    return issecretvalue ~= nil and issecretvalue(value) == true
end

--- Color option ("#RRGGBB[AA]" or a theme color like "@accent") as { r, g, b, a }; white if
--- it isn't valid.
function Core.Hex(hex)
    return Theme.RGBA(hex)
end

--- The player's class token ("WARRIOR"...), nil when the client doesn't say.
function Core.Class()
    local ok, _, class = pcall(UnitClass, "player")
    if ok and type(class) == "string" then
        return class
    end
    return nil
end

local function characterKey()
    local name = UnitName("player") or "?"
    -- From the core: Forever's GetRealmName can answer "".
    local realm = E.RealmName() or "?"
    return name .. "-" .. realm
end

--- The account's saved state: { version, chars, position = { x, y }?, size = { w, h }?,
--- hidden = { [stat] = true } }.
--- position is the panel's top left corner in UIParent's units, set by dragging it; size is
--- its size in its own units, set with its grip.
function Core.Account()
    local db = _G.EternityUIStatsDB
    if type(db) ~= "table" or db.version ~= 1 then
        db = { version = 1, chars = {} }
        _G.EternityUIStatsDB = db
    end
    db.chars = type(db.chars) == "table" and db.chars or {}
    db.hidden = type(db.hidden) == "table" and db.hidden or {}
    local position = db.position
    if type(position) ~= "table" or type(position.x) ~= "number" or type(position.y) ~= "number" then
        db.position = nil
    end
    local size = db.size
    if type(size) ~= "table" or type(size.w) ~= "number" or type(size.h) ~= "number" then
        db.size = nil
    end
    return db
end

--- Whether the player hid one stat from the panel (the panel's settings).
function Core.StatHidden(id)
    return Core.Account().hidden[id] == true
end

function Core.SetStatHidden(id, hidden)
    Core.Account().hidden[id] = hidden and true or nil
end

--- This character's saved state: { shown = bool, collapsed = { [category] = true } }.
function Core.Char()
    local db = Core.Account()
    local key = characterKey()
    local char = db.chars[key]
    if type(char) ~= "table" then
        char = { shown = Core.Opt("panel.startShown") ~= false, collapsed = {} }
        db.chars[key] = char
    end
    char.collapsed = type(char.collapsed) == "table" and char.collapsed or {}
    return char
end

--- A chat line from the module, in the theme's accent color.
function Core.Print(text)
    local r, g, b = Theme.Color("accent")
    print(("|cff%02x%02x%02xEternity:|r %s"):format(r * 255, g * 255, b * 255, text))
end
