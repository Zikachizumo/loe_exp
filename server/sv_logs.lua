--[[
    loe_exp / server / logs
    Yetkili işlemleri (ve istenirse export değişiklikleri) loe_exp_logs tablosuna yazılır.
]]

LoeExpLog = {}

--- İşlemi yapanın kimliği ve adı.
local function GetActor(data)
    if data.actorSource == 0 then
        return 'console', 'Konsol'
    end
    if data.actorSource then
        return LoeQbox.GetLicense(data.actorSource), LoeQbox.GetName(data.actorSource)
    end
    local resource = data.invoker or 'bilinmiyor'
    return 'resource:' .. resource, resource
end

--- Bir işlemi loglar.
---@param data table action, actorSource | invoker, session, amount, oldLevel, newLevel, oldExp, newExp, note
function LoeExpLog.Write(data)
    local actorIdentifier, actorName = GetActor(data)
    local session = data.session or {}

    LoeExpDB.InsertLog({
        action           = data.action,
        actorIdentifier  = actorIdentifier,
        actorName        = actorName,
        targetIdentifier = session.identifier,
        targetName       = session.name,
        amount           = data.amount,
        oldLevel         = data.oldLevel,
        newLevel         = data.newLevel,
        oldExp           = data.oldExp,
        newExp           = data.newExp,
        note             = data.note,
    })
end
