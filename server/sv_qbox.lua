--[[
    loe_exp / server / qbox
    Qbox (qbx_core) ve ox_lib ile konuşan her şey burada toplanır:
    oyuncu nesnesi, citizenid, karakter adı, metadata ve bildirim.
    Diğer dosyalar Qbox'a doğrudan değil, LoeQbox üzerinden erişir.
]]

LoeQbox = {}

local qbx = exports.qbx_core

--- Qbox oyuncu nesnesi. Karakter seçilmemişse nil döner.
function LoeQbox.GetPlayer(source)
    local ok, player = pcall(qbx.GetPlayer, qbx, source)
    return ok and player or nil
end

--- Karakteri yüklü mü? (Karakter seçim ekranındaki oyuncuya süre yazılmaz.)
function LoeQbox.IsPlayerLoaded(source)
    return LoeQbox.GetPlayer(source) ~= nil
end

--- İlerlemenin kaydedildiği kimlik: karakterin citizenid'si.
function LoeQbox.GetCitizenId(source)
    local player = LoeQbox.GetPlayer(source)
    return player and player.PlayerData.citizenid or nil
end

--- Karakter adı (yoksa oyuncu adı).
function LoeQbox.GetName(source)
    local player = LoeQbox.GetPlayer(source)
    local charinfo = player and player.PlayerData.charinfo
    if charinfo and charinfo.firstname then
        return ('%s %s'):format(charinfo.firstname, charinfo.lastname or '')
    end
    return GetPlayerName(source) or ('ID ' .. tostring(source))
end

--- Rockstar lisansı (yetkili loglarında işlemi yapan kişiyi tanımlamak için).
function LoeQbox.GetLicense(source)
    return GetPlayerIdentifierByType(source, 'license') or ('source:' .. tostring(source))
end

--- Seviye ve toplam EXP'yi Qbox metadata'sına yazar (yalnızca değer değiştiyse).
--- HUD gibi scriptler qbx:GetPlayerData().metadata.level ile okuyabilir.
function LoeQbox.SyncMetadata(source, level, totalExp)
    if not Config.Metadata.Enabled then
        return
    end

    local player = LoeQbox.GetPlayer(source)
    if not player then
        return
    end

    local metadata = player.PlayerData.metadata or {}
    if metadata[Config.Metadata.LevelKey] ~= level then
        player.Functions.SetMetaData(Config.Metadata.LevelKey, level)
    end
    if metadata[Config.Metadata.ExpKey] ~= totalExp then
        player.Functions.SetMetaData(Config.Metadata.ExpKey, totalExp)
    end
end

--- ox_lib bildirimi gösterir. Bildirim sistemi değişirse yalnızca bu fonksiyon düzenlenir.
---@param notifyType? 'success'|'error'|'inform'
function LoeQbox.Notify(source, message, notifyType)
    TriggerClientEvent('ox_lib:notify', source, {
        title       = Config.Notify.Title,
        description = message,
        type        = notifyType or 'inform',
        duration    = Config.Notify.Duration,
        position    = Config.Notify.Position,
    })
end
