--[[
    loe_exp / server / qbox
    Qbox (qbx_core) ve ox_lib ile konuşan her şey burada toplanır:
    oyuncu nesnesi, citizenid, karakter adı, metadata ve bildirim.
    Diğer dosyalar Qbox'a doğrudan değil, LoeQbox üzerinden erişir.

    Not: exports.qbx_core:GetPlayer her çağrıda oyuncu nesnesinin TAMAMINI kopyalar
    (resource'lar arası export). Bu yüzden yalnızca gerektiğinde ve bir kez çağrılır.
]]

LoeQbox = {}

local qbx = exports.qbx_core
local LEVEL_KEY = Config.Metadata.LevelKey
local EXP_KEY = Config.Metadata.ExpKey

--- Qbox oyuncu nesnesi. Karakter seçilmemişse nil döner.
function LoeQbox.GetPlayer(source)
    local ok, player = pcall(function()
        return qbx:GetPlayer(source)
    end)
    return ok and player or nil
end

--- Karakteri yüklü mü? Qbox'ın isLoggedIn durumu okunur (oyuncu nesnesi kopyalanmaz).
--- Karakter seçim ekranındaki oyuncuya süre yazılmaz.
function LoeQbox.IsPlayerLoaded(source)
    local player = Player(source)
    return player ~= nil and player.state.isLoggedIn == true
end

--- Yükleme için gereken karakter bilgisi, tek export çağrısıyla.
---@return { citizenid: string, name: string, metaLevel: any, metaExp: any }|nil
function LoeQbox.GetCharacter(source)
    local player = LoeQbox.GetPlayer(source)
    local playerData = player and player.PlayerData
    if not playerData or not playerData.citizenid then
        return nil
    end

    local charinfo = playerData.charinfo
    local name
    if charinfo and charinfo.firstname then
        name = ('%s %s'):format(charinfo.firstname, charinfo.lastname or '')
    else
        name = GetPlayerName(source) or ('ID ' .. tostring(source))
    end

    local metadata = playerData.metadata or {}
    return {
        citizenid = playerData.citizenid,
        name = name,
        metaLevel = metadata[LEVEL_KEY],
        metaExp = metadata[EXP_KEY],
    }
end

--- Karakterin citizenid'si.
function LoeQbox.GetCitizenId(source)
    local character = LoeQbox.GetCharacter(source)
    return character and character.citizenid or nil
end

--- Yetkili loglarında görünen ad: karakter adı, karakter yoksa oyuncu adı.
function LoeQbox.GetName(source)
    local character = LoeQbox.GetCharacter(source)
    return character and character.name or GetPlayerName(source) or ('ID ' .. tostring(source))
end

--- Rockstar lisansı (yetkili loglarında işlemi yapan kişiyi tanımlamak için).
function LoeQbox.GetLicense(source)
    return GetPlayerIdentifierByType(source, 'license') or ('source:' .. tostring(source))
end

local function SetMetadata(source, key, value)
    local ok, err = pcall(function()
        qbx:SetMetadata(source, key, value)
    end)
    if not ok then
        print(('^1[loe_exp] Metadata yazılamadı (%s): %s^0'):format(key, tostring(err)))
    end
    return ok
end

--- Seviye ve toplam EXP'yi Qbox metadata'sına yazar. Yalnızca değişen değer yazılır:
--- Qbox her SetMetadata çağrısında oyuncunun tamamını kaydeder ve PlayerData'yı istemciye yollar.
--- Son yazılan değerler oturumda (metaLevel / metaExp) tutulur, Qbox'tan tekrar okunmaz.
function LoeQbox.SyncMetadata(session)
    if not Config.Metadata.Enabled or not session.source then
        return
    end

    if session.metaLevel ~= session.level and SetMetadata(session.source, LEVEL_KEY, session.level) then
        session.metaLevel = session.level
    end
    if session.metaExp ~= session.totalExp and SetMetadata(session.source, EXP_KEY, session.totalExp) then
        session.metaExp = session.totalExp
    end
end

--- ox_lib bildirimi gösterir. Bildirim sistemi değişirse yalnızca bu fonksiyon düzenlenir.
---@param notifyType? 'success'|'error'|'info'|'warning'
function LoeQbox.Notify(source, message, notifyType)
    TriggerClientEvent('ox_lib:notify', source, {
        title       = Config.Notify.Title,
        description = message,
        type        = notifyType or 'info',
        duration    = Config.Notify.Duration,
        position    = Config.Notify.Position, -- nil: oyuncunun ox_lib ayarındaki konum
    })
end
