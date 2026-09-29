--[[
    LOE - loe_exp | Komutlar

    Yetkili komutları hem ACE izni (Config.Admin.AcePermission) hem framework grubu ile
    kontrol edilir. Her yetkili işlemi loglanır. Konsoldan (source 0) da kullanılabilir.
]]

local L = Config.Locale

--- Komutu yazana yanıt verir (konsolda print, oyunda bildirim).
local function Reply(source, message, notifyType)
    if source == 0 then
        print('[loe_exp] ' .. message)
    else
        LoeBridge.Notify(source, message, notifyType or 'inform')
    end
end

local function ErrorText(errorCode)
    local text = L.errors[errorCode] or tostring(errorCode)
    return text:format(LoeLevel.GetMaxTotalExp())
end

--- Yalnızca yetkililerin kullanabileceği komut kaydeder.
local function RegisterAdminCommand(name, handler)
    if not name then
        return
    end
    RegisterCommand(name, function(source, args)
        if not LoeBridge.IsAdmin(source) then
            Reply(source, L.no_permission, 'error')
            return
        end
        handler(source, args or {}, name)
    end, false)
end

------------------------------------------------------------------------
-- /seviyem (herkes)
------------------------------------------------------------------------
if Config.Commands.Self then
    RegisterCommand(Config.Commands.Self, function(source)
        if source == 0 then
            return
        end

        local session = LoeExp.GetSession(source)
        if not session then
            Reply(source, L.not_loaded, 'error')
            return
        end

        local data = LoeExp.BuildPublicData(session)
        if data.isMaxLevel then
            Reply(source, L.self_info_max:format(data.level, data.totalExp))
        else
            Reply(source, L.self_info:format(
                data.level, data.totalExp, data.currentExp, data.requiredExp,
                data.activeMinutes, data.intervalMinutes
            ))
        end
    end, false)
end

------------------------------------------------------------------------
-- /seviyebak [id] (yetkili)
------------------------------------------------------------------------
RegisterAdminCommand(Config.Commands.View, function(source, args, command)
    local targetId = LoeLevel.ToInteger(args[1])
    if not targetId then
        Reply(source, L.usage_view:format(command), 'error')
        return
    end

    local session = LoeExp.GetSession(targetId)
    if not session then
        Reply(source, L.invalid_target, 'error')
        return
    end

    local data = LoeExp.BuildPublicData(session)
    Reply(source, L.admin_view:format(
        targetId, session.name, data.level, data.totalExp, data.currentExp, data.requiredExp,
        data.activeMinutes, data.intervalMinutes, LoeExp.IsPlayerAfk(targetId) and L.yes or L.no
    ))

    LoeExpLog.Write({
        action = 'view',
        actorSource = source,
        targetSource = targetId,
        session = session,
        amount = 0,
        oldLevel = session.level,
        newLevel = session.level,
        oldExp = session.totalExp,
        newExp = session.totalExp,
    })
end)

------------------------------------------------------------------------
-- /expekle, /expsil, /expayarla (yetkili)
------------------------------------------------------------------------
local AMOUNT_ACTIONS = {
    add = { apply = LoeExp.AddExp, message = 'admin_add' },
    remove = { apply = LoeExp.RemoveExp, message = 'admin_remove' },
    set = { apply = LoeExp.SetExp, message = 'admin_set' },
}

local function CreateAmountCommand(action)
    local definition = AMOUNT_ACTIONS[action]

    return function(source, args, command)
        local targetId = LoeLevel.ToInteger(args[1])
        local amount = LoeLevel.ToInteger(args[2])
        if not targetId or not amount then
            Reply(source, L.usage_amount:format(command), 'error')
            return
        end

        local session = LoeExp.GetSession(targetId)
        if not session then
            Reply(source, L.invalid_target, 'error')
            return
        end

        local oldLevel, oldExp = session.level, session.totalExp
        local ok, result = definition.apply(targetId, amount, 'admin:' .. action)
        if not ok then
            Reply(source, L.admin_failed:format(ErrorText(result)), 'error')
            return
        end

        if action == 'set' then
            Reply(source, L.admin_set:format(targetId, session.name, session.totalExp, oldLevel, session.level), 'success')
        else
            Reply(source, L[definition.message]:format(targetId, session.name, amount, oldLevel, session.level, session.totalExp), 'success')
        end

        LoeExpLog.Write({
            action = action,
            actorSource = source,
            targetSource = targetId,
            session = session,
            amount = amount,
            oldLevel = oldLevel,
            newLevel = session.level,
            oldExp = oldExp,
            newExp = session.totalExp,
        })
    end
end

RegisterAdminCommand(Config.Commands.Add, CreateAmountCommand('add'))
RegisterAdminCommand(Config.Commands.Remove, CreateAmountCommand('remove'))
RegisterAdminCommand(Config.Commands.Set, CreateAmountCommand('set'))
