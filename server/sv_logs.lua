--[[
    LOE - loe_exp | Loglama

    Yetkili işlemleri (ve istenirse export değişiklikleri) konsola, veritabanına
    (loe_exp_logs) ve Discord webhook'una yazılır.
]]

LoeExpLog = {}

local ACTION_LABELS = {
    view = 'Seviye görüntüleme',
    add = 'EXP ekleme',
    remove = 'EXP çıkarma',
    set = 'EXP ayarlama',
}

--- İşlemi yapanın kimliği ve adı.
local function GetActor(data)
    if data.actorSource == 0 then
        return 'console', 'Konsol'
    end
    if data.actorSource then
        local source = data.actorSource
        return LoeBridge.GetLicense(source) or ('source:' .. source), LoeBridge.GetName(source)
    end
    local resource = data.invoker or 'bilinmiyor'
    return 'resource:' .. resource, resource
end

local function SendWebhook(title, description)
    local url = Config.DiscordWebhook
    if not url or url == '' then
        return
    end

    PerformHttpRequest(url, function() end, 'POST', json.encode({
        username = Config.DiscordWebhookName,
        embeds = {
            {
                title = title,
                description = description,
                color = 15105570,
                timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
            },
        },
    }), { ['Content-Type'] = 'application/json' })
end

--- Bir işlemi loglar.
---@param data table action, actorSource | invoker, targetSource, session, amount, oldLevel, newLevel, oldExp, newExp, note
function LoeExpLog.Write(data)
    local actorIdentifier, actorName = GetActor(data)
    local session = data.session or {}
    local label = ACTION_LABELS[data.action] or data.action

    local text = ('%s | Yapan: %s (%s) | Hedef: [%s] %s (%s) | Miktar: %d | Seviye: %d -> %d | EXP: %d -> %d%s'):format(
        label,
        actorName, actorIdentifier,
        tostring(data.targetSource or '-'), session.name or '-', session.identifier or '-',
        data.amount or 0,
        data.oldLevel or 0, data.newLevel or 0,
        data.oldExp or 0, data.newExp or 0,
        data.note and data.note ~= '' and (' | Not: ' .. data.note) or ''
    )

    if Config.Logging.Console then
        print('^3[loe_exp][LOG]^0 ' .. text)
    end

    if Config.Logging.Database then
        LoeExpDB.InsertLog({
            action = data.action,
            actorIdentifier = actorIdentifier,
            actorName = actorName,
            targetIdentifier = session.identifier,
            targetName = session.name,
            amount = data.amount,
            oldLevel = data.oldLevel,
            newLevel = data.newLevel,
            oldExp = data.oldExp,
            newExp = data.newExp,
            note = data.note,
        })
    end

    SendWebhook(label, text)
end
