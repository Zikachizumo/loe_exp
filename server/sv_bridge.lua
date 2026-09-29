--[[
    LOE - loe_exp | Framework köprüsü (server)

    Framework'e özel her şey (oyuncu kimliği, isim, yetki, bildirim, giriş/çıkış olayları)
    bu dosyada toplanır. Diğer dosyalar yalnızca LoeBridge fonksiyonlarını kullanır.
    Desteklenen: ESX Legacy, QBCore, Qbox ve standalone.
]]

LoeBridge = {
    Framework = 'standalone',
}

local ESX, QBCore = nil, nil

local function IsResourceStarted(name)
    return GetResourceState(name) == 'started'
end

--- Framework'ü algılar ve çekirdek nesnesini alır.
function LoeBridge.Init()
    local framework = Config.Framework

    if framework == 'auto' then
        if IsResourceStarted('qbx_core') then
            framework = 'qbx'
        elseif IsResourceStarted('es_extended') then
            framework = 'esx'
        elseif IsResourceStarted('qb-core') then
            framework = 'qb'
        else
            framework = 'standalone'
        end
    end

    if framework == 'esx' then
        local ok, object = pcall(function()
            return exports['es_extended']:getSharedObject()
        end)
        if ok and object then
            ESX = object
        else
            -- Eski ESX sürümleri için geriye dönük yöntem
            TriggerEvent('esx:getSharedObject', function(obj) ESX = obj end)
        end
        if not ESX then
            print('^1[loe_exp] ESX nesnesi alınamadı, standalone moda geçiliyor.^0')
            framework = 'standalone'
        end
    elseif framework == 'qb' then
        local ok, object = pcall(function()
            return exports['qb-core']:GetCoreObject()
        end)
        if ok and object then
            QBCore = object
        else
            print('^1[loe_exp] QBCore nesnesi alınamadı, standalone moda geçiliyor.^0')
            framework = 'standalone'
        end
    end

    LoeBridge.Framework = framework
    return framework
end

--- Framework oyuncu nesnesi (standalone modda nil).
function LoeBridge.GetFrameworkPlayer(source)
    local framework = LoeBridge.Framework
    if framework == 'esx' then
        return ESX.GetPlayerFromId(source)
    elseif framework == 'qb' then
        return QBCore.Functions.GetPlayer(source)
    elseif framework == 'qbx' then
        local ok, player = pcall(function()
            return exports.qbx_core:GetPlayer(source)
        end)
        return ok and player or nil
    end
    return nil
end

--- Oyuncunun karakteri yüklenmiş mi? (Karakter seçim ekranındaki oyuncuya süre yazılmaz.)
function LoeBridge.IsPlayerLoaded(source)
    if not GetPlayerName(source) then
        return false
    end
    if LoeBridge.Framework == 'standalone' then
        return true
    end
    return LoeBridge.GetFrameworkPlayer(source) ~= nil
end

--- Rockstar lisans kimliği.
function LoeBridge.GetLicense(source)
    if GetPlayerIdentifierByType then
        local license = GetPlayerIdentifierByType(source, 'license')
        if license then
            return license
        end
    end
    for _, identifier in ipairs(GetPlayerIdentifiers(source) or {}) do
        if identifier:sub(1, 8) == 'license:' then
            return identifier
        end
    end
    return nil
end

--- İlerlemenin kaydedileceği kimlik (Config.IdentifierMode'a göre).
function LoeBridge.GetIdentifier(source)
    if Config.IdentifierMode == 'license' or LoeBridge.Framework == 'standalone' then
        return LoeBridge.GetLicense(source)
    end

    local player = LoeBridge.GetFrameworkPlayer(source)
    if not player then
        return nil
    end

    if LoeBridge.Framework == 'esx' then
        return player.identifier
    end
    return player.PlayerData and player.PlayerData.citizenid or nil
end

--- Loglarda ve yetkili ekranlarında gösterilecek isim.
function LoeBridge.GetName(source)
    local player = LoeBridge.GetFrameworkPlayer(source)
    if player then
        if LoeBridge.Framework == 'esx' then
            if player.getName then
                return player.getName()
            end
        else
            local charinfo = player.PlayerData and player.PlayerData.charinfo
            if charinfo and charinfo.firstname then
                return ('%s %s'):format(charinfo.firstname, charinfo.lastname or '')
            end
        end
    end
    return GetPlayerName(source) or ('ID ' .. tostring(source))
end

--- Yetkili kontrolü. Konsol (source 0) her zaman yetkilidir.
function LoeBridge.IsAdmin(source)
    if source == 0 then
        return true
    end

    if Config.Admin.AcePermission and IsPlayerAceAllowed(source, Config.Admin.AcePermission) then
        return true
    end

    local groups = Config.Admin.Groups
    if not groups or #groups == 0 then
        return false
    end

    local framework = LoeBridge.Framework
    if framework == 'esx' then
        local xPlayer = ESX.GetPlayerFromId(source)
        local group = xPlayer and xPlayer.getGroup and xPlayer.getGroup()
        for i = 1, #groups do
            if group == groups[i] then
                return true
            end
        end
    elseif framework == 'qb' then
        for i = 1, #groups do
            if QBCore.Functions.HasPermission(source, groups[i]) then
                return true
            end
        end
    elseif framework == 'qbx' then
        for i = 1, #groups do
            local ok, allowed = pcall(function()
                return exports.qbx_core:HasPermission(source, groups[i])
            end)
            if ok and allowed then
                return true
            end
        end
    end

    return false
end

--- Framework giriş / çıkış olaylarını bağlar.
---@param onLoaded fun(source: number) Karakter yüklendiğinde
---@param onUnloaded fun(source: number) Karakterden çıkıldığında (oyundan çıkış hariç)
function LoeBridge.RegisterPlayerHooks(onLoaded, onUnloaded)
    local framework = LoeBridge.Framework

    if framework == 'esx' then
        AddEventHandler('esx:playerLoaded', function(playerId)
            onLoaded(tonumber(playerId))
        end)
        AddEventHandler('esx:playerLogout', function(playerId)
            onUnloaded(tonumber(playerId))
        end)
    elseif framework == 'qb' or framework == 'qbx' then
        AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
            local source = player and player.PlayerData and player.PlayerData.source
            if source then
                onLoaded(tonumber(source))
            end
        end)
        AddEventHandler('QBCore:Server:OnPlayerUnload', function(playerId)
            onUnloaded(tonumber(playerId))
        end)
    else
        AddEventHandler('playerJoining', function()
            onLoaded(tonumber(source))
        end)
    end
end

------------------------------------------------------------------------
-- Bildirim
------------------------------------------------------------------------

-- Bildirim tipleri: 'success' | 'error' | 'inform'. Her sistemin kendi tip adına çevrilir.
local NOTIFY_TYPES = {
    ox_lib = { success = 'success', error = 'error', inform = 'inform' },
    esx = { success = 'success', error = 'error', inform = 'info' },
    qb = { success = 'success', error = 'error', inform = 'primary' },
}

local function ResolveNotifySystem()
    local system = Config.Notify.System
    if system ~= 'auto' then
        return system
    end
    if IsResourceStarted('ox_lib') then
        return 'ox_lib'
    end
    if LoeBridge.Framework == 'esx' then
        return 'esx'
    end
    if LoeBridge.Framework == 'qb' or LoeBridge.Framework == 'qbx' then
        return 'qb'
    end
    return 'native'
end

--- Oyuncuya bildirim gösterir. LOE'nin kendi bildirim sistemine bağlamak için
--- Config.Notify.System = 'custom' yapıp Config.Notify.Custom fonksiyonunu doldurmanız yeterlidir.
---@param source number
---@param message string
---@param notifyType? 'success'|'error'|'inform'
---@param duration? number
function LoeBridge.Notify(source, message, notifyType, duration)
    if not source or source <= 0 then
        print('[loe_exp] ' .. tostring(message))
        return
    end

    notifyType = notifyType or 'inform'
    duration = duration or Config.Notify.Duration

    local system = ResolveNotifySystem()

    if system == 'custom' and type(Config.Notify.Custom) == 'function' then
        local ok, err = pcall(Config.Notify.Custom, source, message, notifyType, duration)
        if ok then
            return
        end
        print(('^1[loe_exp] Özel bildirim fonksiyonu hata verdi: %s^0'):format(err))
    elseif system == 'ox_lib' then
        TriggerClientEvent('ox_lib:notify', source, {
            title = Config.Notify.Title,
            description = message,
            type = NOTIFY_TYPES.ox_lib[notifyType] or 'inform',
            duration = duration,
        })
        return
    elseif system == 'esx' then
        TriggerClientEvent('esx:showNotification', source, message, NOTIFY_TYPES.esx[notifyType] or 'info', duration)
        return
    elseif system == 'qb' then
        TriggerClientEvent('QBCore:Notify', source, message, NOTIFY_TYPES.qb[notifyType] or 'primary', duration)
        return
    end

    -- 'native' veya yedek: GTA yerleşik bildirimi (client/cl_main.lua)
    TriggerClientEvent('loe_exp:client:notify', source, message, notifyType, duration)
end
