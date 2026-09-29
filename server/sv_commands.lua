--[[
    loe_exp / server / commands
    Komutlar ox_lib (lib.addCommand) ile kaydedilir. Yetkili komutları Config.AdminGroup'a
    kısıtlanır (restricted); yetkisi olmayan oyuncu komutu hiç çalıştıramaz.
    Her yetkili işlemi loe_exp_logs tablosuna yazılır. Konsoldan da kullanılabilir.
]]

local L = Config.Locale

--- Komutu yazana yanıt verir (konsolda print, oyunda ox_lib bildirimi).
local function Reply(source, message, notifyType)
    if source == 0 then
        print('[loe_exp] ' .. message)
    else
        LoeQbox.Notify(source, message, notifyType or 'inform')
    end
end

local function ErrorText(errorCode)
    local text = L.errors[errorCode] or tostring(errorCode)
    return text:format(LoeLevel.GetMaxTotalExp())
end

-- Parametreler optional: eksik / hatalı girdide ox_lib yalnızca konsola yazdığı için
-- doğrulama burada yapılır ve yetkiliye Türkçe kullanım bilgisi gösterilir.
local ID_PARAM = { name = 'id', help = 'Oyuncu ID', optional = true }

local function AmountParam(help)
    return { name = 'miktar', help = help, optional = true }
end

------------------------------------------------------------------------
-- /seviyem (herkes)
------------------------------------------------------------------------
if Config.Commands.Self then
    lib.addCommand(Config.Commands.Self, {
        help = 'Seviye ve EXP bilgini gösterir',
    }, function(source)
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
    end)
end

------------------------------------------------------------------------
-- /seviyebak [id] (yetkili)
------------------------------------------------------------------------
if Config.Commands.View then
    lib.addCommand(Config.Commands.View, {
        help = 'Oyuncunun seviyesini gösterir (Yetkili)',
        params = { ID_PARAM },
        restricted = Config.AdminGroup,
    }, function(source, args)
        local targetId = LoeLevel.ToInteger(args.id)
        if not targetId then
            Reply(source, L.usage_view:format(Config.Commands.View), 'error')
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
            session = session,
            amount = 0,
            oldLevel = session.level,
            newLevel = session.level,
            oldExp = session.totalExp,
            newExp = session.totalExp,
        })
    end)
end

------------------------------------------------------------------------
-- /expekle, /expsil, /expayarla (yetkili)
------------------------------------------------------------------------
local AMOUNT_COMMANDS = {
    {
        command = Config.Commands.Add,
        action = 'add',
        help = 'Oyuncuya EXP ekler (Yetkili)',
        amountHelp = 'Eklenecek EXP',
        apply = LoeExp.AddExp,
    },
    {
        command = Config.Commands.Remove,
        action = 'remove',
        help = 'Oyuncudan EXP çıkarır (Yetkili)',
        amountHelp = 'Çıkarılacak EXP',
        apply = LoeExp.RemoveExp,
    },
    {
        command = Config.Commands.Set,
        action = 'set',
        help = 'Oyuncunun toplam EXP miktarını ayarlar (Yetkili)',
        amountHelp = 'Yeni toplam EXP',
        apply = LoeExp.SetExp,
    },
}

for _, definition in ipairs(AMOUNT_COMMANDS) do
    if definition.command then
        lib.addCommand(definition.command, {
            help = definition.help,
            params = { ID_PARAM, AmountParam(definition.amountHelp) },
            restricted = Config.AdminGroup,
        }, function(source, args)
            local targetId = LoeLevel.ToInteger(args.id)
            local amount = LoeLevel.ToInteger(args.miktar)
            if not targetId or not amount then
                Reply(source, L.usage_amount:format(definition.command), 'error')
                return
            end

            local session = LoeExp.GetSession(targetId)
            if not session then
                Reply(source, L.invalid_target, 'error')
                return
            end

            local oldLevel, oldExp = session.level, session.totalExp
            local ok, result = definition.apply(targetId, amount, 'admin:' .. definition.action)
            if not ok then
                Reply(source, L.admin_failed:format(ErrorText(result)), 'error')
                return
            end

            if definition.action == 'set' then
                Reply(source, L.admin_set:format(targetId, session.name, session.totalExp, oldLevel, session.level), 'success')
            else
                Reply(source, L['admin_' .. definition.action]:format(
                    targetId, session.name, amount, oldLevel, session.level, session.totalExp
                ), 'success')
            end

            LoeExpLog.Write({
                action = definition.action,
                actorSource = source,
                session = session,
                amount = amount,
                oldLevel = oldLevel,
                newLevel = session.level,
                oldExp = oldExp,
                newExp = session.totalExp,
            })
        end)
    end
end
