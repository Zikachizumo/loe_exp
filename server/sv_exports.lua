--[[
    loe_exp / server / exports
    Diğer LOE sistemleri için sunucu API'si.

    EXPORT'LAR (önerilen kullanım):
        exports.loe_exp:GetLevel(source)                     -> number|nil
        exports.loe_exp:GetTotalExp(source)                  -> number|nil
        exports.loe_exp:GetPlayerData(source)                -> table|nil
        exports.loe_exp:AddExp(source, amount, reason?)      -> ok, levelOrError, totalExp
        exports.loe_exp:RemoveExp(source, amount, reason?)   -> ok, levelOrError, totalExp
        exports.loe_exp:SetExp(source, totalExp, reason?)    -> ok, levelOrError, totalExp
        exports.loe_exp:RecalculateLevel(source)             -> ok, levelOrError, totalExp
        exports.loe_exp:IsPlayerAfk(source)                  -> boolean|nil
        exports.loe_exp:GetRequiredXP(level)                 -> number|nil
        exports.loe_exp:GetTotalExpForLevel(level)           -> number
        exports.loe_exp:GetMaxLevel()                        -> number

    SUNUCU İÇİ OLAYLAR (TriggerEvent ile, yalnızca sunucu tarafından tetiklenebilir):
        'loe_exp:server:getLevel'         (source, cb)
        'loe_exp:server:getTotalExp'      (source, cb)
        'loe_exp:server:addExp'           (source, amount, reason?, cb?)
        'loe_exp:server:removeExp'        (source, amount, reason?, cb?)
        'loe_exp:server:setExp'           (source, totalExp, reason?, cb?)
        'loe_exp:server:recalculateLevel' (source, cb?)

    YAYINLANAN OLAYLAR (AddEventHandler ile dinleyin, RegisterNetEvent KULLANMAYIN):
        'loe_exp:onPlayerLoaded'  (source, data)
        'loe_exp:onExpChanged'    (source, totalExp, delta, reason)
        'loe_exp:onLevelChanged'  (source, newLevel, oldLevel)   -- değişim başına bir kez
        'loe_exp:onLevelReached'  (source, level)                -- ulaşılan HER seviye için ayrı

    GÜVENLİK: Buradaki olaylar RegisterNetEvent ile kaydedilmediği için istemciler tarafından
    tetiklenemez. FiveM, ağdan gelen ve net olarak işaretlenmemiş olayları reddeder.
]]

--- Export / event ile yapılan değişikliği (ayar açıksa) loglar.
--- amount: gerçekte değişen miktar (işaretli).
local function LogExternalChange(action, source, before, reason)
    if not Config.Logging.ExportChanges then
        return
    end
    local session = LoeExp.GetSession(source)
    if not session then
        return
    end
    LoeExpLog.Write({
        action = 'export_' .. action,
        invoker = GetInvokingResource() or GetCurrentResourceName(),
        session = session,
        amount = session.totalExp - before.totalExp,
        oldLevel = before.level,
        newLevel = session.level,
        oldExp = before.totalExp,
        newExp = session.totalExp,
        note = reason and tostring(reason) or '',
    })
end

--- Değişiklik fonksiyonlarını loglamayla sarmalar.
local function WithLogging(action, fn)
    return function(source, amount, reason)
        local session = LoeExp.GetSession(source)
        local before = session and { level = session.level, totalExp = session.totalExp } or nil
        local ok, levelOrError, totalExp = fn(source, amount, reason)
        if ok and before then
            LogExternalChange(action, source, before, reason)
        end
        return ok, levelOrError, totalExp
    end
end

local AddExp = WithLogging('add', LoeExp.AddExp)
local RemoveExp = WithLogging('remove', LoeExp.RemoveExp)
local SetExp = WithLogging('set', LoeExp.SetExp)

local function GetLevel(source)
    local session = LoeExp.GetSession(source)
    return session and session.level or nil
end

local function GetTotalExp(source)
    local session = LoeExp.GetSession(source)
    return session and session.totalExp or nil
end

local function GetPlayerData(source)
    local session = LoeExp.GetSession(source)
    return session and LoeExp.BuildPublicData(session) or nil
end

------------------------------------------------------------------------
-- Export'lar
------------------------------------------------------------------------
exports('GetLevel', GetLevel)
exports('GetTotalExp', GetTotalExp)
exports('GetPlayerData', GetPlayerData)
exports('AddExp', AddExp)
exports('RemoveExp', RemoveExp)
exports('SetExp', SetExp)
exports('RecalculateLevel', LoeExp.RecalculateLevel)
exports('IsPlayerAfk', LoeExp.IsPlayerAfk)
-- Geçersiz seviyede hata fırlatmak yerine nil döner
exports('GetRequiredXP', function(level)
    local value = LoeLevel.ToInteger(level)
    if not value or value < 1 then
        return nil
    end
    return LoeLevel.GetRequiredXP(value)
end)
exports('GetTotalExpForLevel', LoeLevel.GetTotalExpForLevel)
exports('GetMaxLevel', function()
    return LoeLevel.MaxLevel
end)

------------------------------------------------------------------------
-- Sunucu içi olaylar (AddEventHandler: istemciden tetiklenemez)
------------------------------------------------------------------------
local function Reply(cb, ...)
    if cb then
        cb(...)
    end
end

AddEventHandler('loe_exp:server:getLevel', function(target, cb)
    Reply(cb, GetLevel(target))
end)

AddEventHandler('loe_exp:server:getTotalExp', function(target, cb)
    Reply(cb, GetTotalExp(target))
end)

AddEventHandler('loe_exp:server:addExp', function(target, amount, reason, cb)
    Reply(cb, AddExp(target, amount, reason))
end)

AddEventHandler('loe_exp:server:removeExp', function(target, amount, reason, cb)
    Reply(cb, RemoveExp(target, amount, reason))
end)

AddEventHandler('loe_exp:server:setExp', function(target, amount, reason, cb)
    Reply(cb, SetExp(target, amount, reason))
end)

AddEventHandler('loe_exp:server:recalculateLevel', function(target, cb)
    Reply(cb, LoeExp.RecalculateLevel(target))
end)
