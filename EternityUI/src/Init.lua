-- EternityUI: the core of the new Eternity suite (title in game: "Eternity"). First file loaded.
-- It exposes a single global, `EternityUI`, the public API for modules. It has no dependency on
-- the old Projects/Eternity core or on Framework/: the code there is reference only.

---Private table of the core (for LuaLS; each file annotates `local _, ns = ...` with this type).
---@class EternityUINamespace
---@field E EternityUI
---@field L table<string, string>
---@field Events EternityEvents
---@field Secret EternitySecret
---@field Combat EternityCombat
---@field Hider EternityHider
---@field Pixel EternityPixel
---@field Theme EternityTheme
---@field Shape EternityShape
---@field Widgets EternityWidgets
---@field CONFIG_CHANGED string
---@field Schema EternityUISchema
---@field Store EternityUIStore
---@field Modules EternityUIModules
---@field CoreOptions table schema of the core's own options (Config/Options.lua)
---@field Diagnostics EternityDiagnostics
---@field db table? the SavedVariables table, set at ADDON_LOADED
---@field store EternityUIStore? set at PLAYER_LOGIN
---@field Startup EternityStartup
---@field firstFile number? debugprofilestop() when the first file ran
---@field probe fun(owner: any, label: string, ms: number, kb: number?)? set while startup is measured

---@type string, EternityUINamespace
local addonName, ns = ...

-- When Eternity's first file ran, for the startup metrics (Core/Startup.lua).
ns.firstFile = debugprofilestop and debugprofilestop() or nil

---@class EternityUI
EternityUI = {
    version = "0.9.0",
    addonName = addonName,
    -- For tests and debugging only. Modules must not use it.
    Internal = { ns = ns },
}
ns.E = EternityUI

-- Internal messages. READY: the store exists. CONFIG_CHANGED: (module, path, value).
EternityUI.READY = "ETERNITY_READY"
ns.CONFIG_CHANGED = "ETERNITY_CONFIG_CHANGED"
EternityUI.CONFIG_CHANGED = ns.CONFIG_CHANGED

--- Prints a line in the chat with the addon's prefix.
function ns.Print(...)
    print("|cff8b5cf6Eternity|r", ...)
end

--- Deep copy of a table (non-table values are returned as they are).
function ns.DeepCopy(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for k, v in pairs(value) do
        copy[k] = ns.DeepCopy(v)
    end
    return copy
end

EternityUI.DeepCopy = ns.DeepCopy
