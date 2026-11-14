-- Registry of the suite's modules. Modules never call each other and their errors don't escape.
-- Disabling a module restores what it changed, live: its OnDisable runs, then the core releases
-- its events and hidden frames. A module that can't do that says so with needsReload, and stays
-- on until the next /reload.
---@type string, EternityUINamespace
local _, ns = ...
local Events = ns.Events
local Hider = ns.Hider
local Schema = ns.Schema

---@class EternityUIModuleDefinition
---@field schema table? option schema; schema.module must be the module's name
---@field needsReload boolean? disabling only takes effect after /reload
---@field tabs table[]? extra tabs on its options page (see EternityUI_Options/src/ModulePage.lua)
---@field actions table[]? buttons beside its switch on the options page: { text, onClick }
---@field defaultTab string? the tab its options page opens on (the last one by default)
---@field OnEnable fun(self)?
---@field OnDisable fun(self)?
---@field OnConfigChanged fun(self, path: string?, value: any)? path nil = anything may have changed

---@class EternityUIModule: EternityUIModuleDefinition
---@field name string
---@field active boolean
---@field reloadPending boolean?
---@field lastError string?

---@class EternityUIModules
---@field ready boolean? the store exists and modules may start
local Modules = { list = {}, byName = {} }
ns.Modules = Modules

local clock = debugprofilestop

local function call(module, hook, ...)
    local fn = module[hook]
    if not fn then
        return true
    end
    -- While the startup metrics record, each hook is timed, with the memory it allocated.
    local probe = ns.probe
    local start, kb
    if probe and clock then
        start, kb = clock(), collectgarbage("count")
    end
    local ok, err = pcall(fn, module, ...)
    if start then
        probe(module, hook, clock() - start, collectgarbage("count") - kb)
    end
    if not ok then
        module.lastError = tostring(err)
        geterrorhandler()(err)
    end
    return ok
end

local function setActive(module, active)
    module.reloadPending = nil
    if active == module.active then
        return
    end
    if active then
        module.active = call(module, "OnEnable")
    elseif module.needsReload then
        module.reloadPending = true
    else
        call(module, "OnDisable")
        Events.Release(module)
        Hider.RestoreAll(module)
        ns.Mover.ReleaseOwner(module.name)
        module.active = false
    end
end

--- Registers a module. Returns it, or nil and the reason.
---@param name string
---@param definition EternityUIModuleDefinition
---@return EternityUIModule?, string?
function EternityUI:RegisterModule(name, definition)
    if type(name) ~= "string" or type(definition) ~= "table" then
        return nil, "RegisterModule(name, definition)"
    end
    if Modules.byName[name] then
        return nil, "module already registered"
    end
    local schema = definition.schema
    if schema then
        if schema.module ~= name then
            return nil, "schema.module does not match"
        end
        local ok, err = Schema.Register(schema)
        if not ok then
            return nil, err
        end
    end
    local module = definition --[[@as EternityUIModule]]
    module.name = name
    module.active = false
    Modules.byName[name] = module
    Modules.list[#Modules.list + 1] = module
    if Modules.ready then
        ns.store:Sanitize(name)
        setActive(module, ns.store:IsModuleEnabled(name))
    end
    return module
end

---@param name string
---@return EternityUIModule?
function EternityUI:GetModule(name)
    return Modules.byName[name]
end

---@return EternityUIModule[]
function EternityUI:ListModules()
    return Modules.list
end

--- Called by the store on every change.
---@param moduleName string?
---@param path string?
---@param value any
function Modules.OnStoreChanged(moduleName, path, value)
    if path == "@profile" then
        for _, module in ipairs(Modules.list) do
            setActive(module, ns.store:IsModuleEnabled(module.name))
            if module.active then
                call(module, "OnConfigChanged", nil, nil)
            end
        end
    elseif path ~= "@layout" then
        local module = moduleName and Modules.byName[moduleName]
        if module and path == "@enabled" then
            setActive(module, value)
        elseif module and module.active then
            call(module, "OnConfigChanged", path, value)
        end
    end
end

--- Starts every module once the store exists.
function Modules.Start()
    Modules.ready = true
    for _, module in ipairs(Modules.list) do
        ns.store:Sanitize(module.name)
        setActive(module, ns.store:IsModuleEnabled(module.name))
    end
end
