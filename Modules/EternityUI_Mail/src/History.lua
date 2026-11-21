-- EternityUI_Mail: the history of letters, saved for the whole account (EternityUIMailDB).
--   * Sent: SendMail is hooked (hooksecurefunc) to read the form (recipient, subject, gold, cash on
--     delivery and attachments) before Blizzard empties it; the letter is saved on
--     MAIL_SEND_SUCCESS and dropped on MAIL_FAILED.
--   * Received: there's no event for a letter arriving, so the mailbox is read each time it's open
--     (MAIL_SHOW, MAIL_INBOX_UPDATE). A letter has no ID: it's known again by its character,
--     sender, subject and when it expires (now + days left), within a margin. Taking its items or
--     gold keeps what was seen first.
-- Only the letters the client lists are read (up to 50).

---@type string, EternityUIMailNamespace
local addonName, ns = ...
local L, opt = ns.L, ns.opt

local SCHEMA_VERSION = 1
local SEND_SLOTS = 12 -- ATTACHMENTS_MAX_SEND
local RECEIVE_SLOTS = 16 -- ATTACHMENTS_MAX_RECEIVE
local DAY = 86400
local SAME_LETTER = 2 * 3600 -- seconds of difference in the expiry that still make the same letter

---@class EternityUIMailItem
---@field id integer
---@field count integer
---@field name string?
---@field quality integer?

---@class EternityUIMailEntry
---@field kind string sent or received
---@field time number time() it was sent, or first seen in the mailbox
---@field realm string
---@field char string the character that sent or received it
---@field charClass string? its class file (MAGE, PRIEST...)
---@field other string the recipient or the sender
---@field otherClass string? the other's class file, when it could be found
---@field subject string
---@field money integer copper sent or attached
---@field cod integer copper asked on delivery
---@field items EternityUIMailItem[]
---@field expires number? time() the letter expires (received ones)
---@field returned boolean?

---@class EternityUIMailHistory
---@field db table? EternityUIMailDB once bound
---@field running boolean?
---@field mailOpen boolean?
---@field sending EternityUIMailEntry? the letter waiting for MAIL_SEND_SUCCESS
---@field onChange fun()? called when the history changes
local History = {}
ns.History = History

local function secret(value)
    return issecretvalue ~= nil and issecretvalue(value)
end

local function text(value)
    return type(value) == "string" and not secret(value) and value or nil
end

local function number(value)
    return type(value) == "number" and not secret(value) and value or 0
end

--- This character: realm and name (Forever's names carry a surname, given apart).
---@return string realm
---@return string name
function History.Me()
    local name, surname = UnitName("player")
    name = text(name) or "?"
    surname = text(surname)
    if surname and surname ~= "" then
        name = name .. " " .. surname
    end
    -- The realm from the core: Forever's GetRealmName can answer "".
    return EternityUI.RealmName() or "?", name
end

--- This character's class file (MAGE, PRIEST...).
---@return string?
function History.MyClass()
    local _, class = UnitClass("player")
    return text(class)
end

--- Binds EternityUIMailDB (the client loads it before ADDON_LOADED of this addon).
function History.Bind()
    if History.db then
        return History.db
    end
    local db = _G.EternityUIMailDB
    if type(db) ~= "table" or type(db.mails) ~= "table" then
        db = { mails = {} }
    end
    db.version = SCHEMA_VERSION
    _G.EternityUIMailDB = db
    History.db = db
    return db
end

local function changed()
    if History.onChange then
        History.onChange()
    end
end

--- Keeps the newest letters up to the option's limit.
function History.Trim()
    local mails = History.Bind().mails
    local limit = opt("history.limit") or 500
    local extra = #mails - limit
    if extra > 0 then
        for _ = 1, extra do
            table.remove(mails, 1)
        end
        changed()
    end
end

--- Adds a letter at the end (newest).
---@param entry EternityUIMailEntry
function History.Add(entry)
    local mails = History.Bind().mails
    mails[#mails + 1] = entry
    History.Trim()
    changed()
end

---@param entry EternityUIMailEntry
function History.Remove(entry)
    local mails = History.Bind().mails
    for i = #mails, 1, -1 do
        if mails[i] == entry then
            table.remove(mails, i)
        end
    end
    changed()
end

function History.Clear()
    History.Bind().mails = {}
    changed()
end

-- Sent -----------------------------------------------------------------------------------------

--- After SendMail: the form as it goes out. Saved if the mail is sent.
---@param recipient any
---@param subject any
function History.OnSendMail(recipient, subject)
    History.sending = nil
    if not (History.running and opt("history.record")) then
        return
    end
    recipient = text(recipient)
    if not recipient or recipient == "" then
        return
    end
    local items = {}
    if GetSendMailItem then
        for slot = 1, SEND_SLOTS do
            local name, id, _, count, quality = GetSendMailItem(slot)
            if type(id) == "number" and not secret(id) then
                items[#items + 1] = { id = id, count = math.max(number(count), 1), name = text(name), quality = quality and number(quality) }
            end
        end
    end
    local realm, char = History.Me()
    ns.Classes.Scan()
    History.sending = {
        kind = "sent",
        time = time(),
        realm = realm,
        char = char,
        charClass = History.MyClass(),
        other = recipient,
        otherClass = ns.Classes.Find(recipient),
        subject = text(subject) or "",
        money = GetSendMailMoney and number(GetSendMailMoney()) or 0,
        cod = GetSendMailCOD and number(GetSendMailCOD()) or 0,
        items = items,
    }
end

function History.OnSendSuccess()
    local entry = History.sending
    History.sending = nil
    if entry then
        History.Add(entry)
    end
end

function History.OnSendFailed()
    History.sending = nil
end

-- Received -------------------------------------------------------------------------------------

local function itemsOf(index)
    local items = {}
    if not GetInboxItem then
        return items
    end
    for slot = 1, RECEIVE_SLOTS do
        local name, id, _, count, quality = GetInboxItem(index, slot)
        if type(id) == "number" and not secret(id) then
            items[#items + 1] = { id = id, count = math.max(number(count), 1), name = text(name), quality = quality and number(quality) }
        end
    end
    return items
end

--- The saved letter that is this one, or nil.
---@param entry EternityUIMailEntry
---@return EternityUIMailEntry?
function History.Find(entry)
    local mails = History.Bind().mails
    for i = #mails, 1, -1 do
        local saved = mails[i]
        if saved.kind == "received"
            and saved.realm == entry.realm
            and saved.char == entry.char
            and saved.other == entry.other
            and saved.subject == entry.subject
            and math.abs((saved.expires or 0) - (entry.expires or 0)) <= SAME_LETTER
        then
            return saved
        end
    end
    return nil
end

-- What's in `seen` and not in `saved` yet: more of an item, gold, cash on delivery.
local function merge(saved, seen)
    local counts = {}
    for _, item in ipairs(saved.items) do
        counts[item.id] = item
    end
    for _, item in ipairs(seen.items) do
        local known = counts[item.id]
        if not known then
            saved.items[#saved.items + 1] = item
        elseif item.count > known.count then
            known.count = item.count
        end
    end
    saved.money = math.max(saved.money or 0, seen.money)
    saved.cod = math.max(saved.cod or 0, seen.cod)
    saved.returned = saved.returned or seen.returned
    saved.otherClass = saved.otherClass or seen.otherClass
end

--- Reads the mailbox: new letters are added, known ones keep what was seen first.
function History.ScanInbox()
    if not (History.running and History.mailOpen and opt("history.record")) then
        return
    end
    if not (GetInboxNumItems and GetInboxHeaderInfo) then
        return
    end
    local count = number(GetInboxNumItems())
    local realm, char = History.Me()
    local myClass = History.MyClass()
    local now = time()
    local added = false
    ns.Classes.Scan()
    for index = 1, count do
        local _, _, sender, subject, money, cod, daysLeft, _, _, returned = GetInboxHeaderInfo(index)
        local entry = {
            kind = "received",
            time = now,
            realm = realm,
            char = char,
            charClass = myClass,
            other = text(sender) or L.UNKNOWN,
            otherClass = ns.Classes.Find(text(sender)),
            subject = text(subject) or "",
            money = number(money),
            cod = number(cod),
            items = itemsOf(index),
            expires = math.floor(now + number(daysLeft) * DAY),
            returned = returned == true or nil,
        }
        local saved = History.Find(entry)
        if saved then
            merge(saved, entry)
        else
            local mails = History.Bind().mails
            mails[#mails + 1] = entry
            added = true
        end
    end
    if added then
        History.Trim()
    end
    changed()
end

-- Lifecycle ------------------------------------------------------------------------------------

History.EVENTS = { "MAIL_SHOW", "MAIL_CLOSED", "MAIL_INBOX_UPDATE", "MAIL_SEND_SUCCESS", "MAIL_FAILED" }

function History.OnEvent(event)
    if event == "MAIL_SHOW" then
        History.mailOpen = true
        History.ScanInbox()
    elseif event == "MAIL_CLOSED" then
        History.mailOpen = false
        History.sending = nil
    elseif event == "MAIL_INBOX_UPDATE" then
        History.ScanInbox()
    elseif event == "MAIL_SEND_SUCCESS" then
        History.OnSendSuccess()
    elseif event == "MAIL_FAILED" then
        History.OnSendFailed()
    end
end

function History.Start()
    History.Bind()
    ns.Classes.Scan()
    History.running = true
    History.mailOpen = _G.MailFrame ~= nil and _G.MailFrame:IsShown()
    -- The hook can't be removed: it does nothing while stopped.
    if not History.hooked and _G.SendMail then
        History.hooked = true
        hooksecurefunc("SendMail", function(recipient, subject)
            History.OnSendMail(recipient, subject)
        end)
    end
    History.Trim()
end

function History.Stop()
    History.running = false
    History.sending = nil
end
