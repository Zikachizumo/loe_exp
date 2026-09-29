--[[
    LOE - loe_exp | İstemci

    İstemcinin tek görevi oyuncunun aktif olup olmadığını gözlemlemek ve sunucuya
    "son aktiviteden bu yana geçen saniye" bilgisini göndermektir.
    İstemci EXP, seviye veya süre BELİRLEYEMEZ. Bu karar sunucudadır.

    Aktivite sayılanlar: kamera hareketi, karakterin yer değiştirmesi (araç yolcusu hariç),
    sesli konuşma ve temel kontrol tuşları.
    Performans: her karede değil, SampleIntervalMs aralığıyla tek bir döngüde kontrol edilir.
]]

local SAMPLE_MS = math.max(250, math.floor(tonumber(Config.Afk.SampleIntervalMs) or 1000))
local HEARTBEAT_MS = math.max(5, math.floor(tonumber(Config.Afk.HeartbeatSeconds) or 30)) * 1000
local SYNC_RETRY_MS = 10000
local TRACK_ACTIVITY = Config.Afk.Enabled == true and Config.Afk.Provider ~= 'external'
local CAMERA_THRESHOLD = tonumber(Config.Afk.CameraThreshold) or 1.0
local MOVE_THRESHOLD = tonumber(Config.Afk.MoveThreshold) or 0.3

-- Aktivite sayılan kontroller: koşma, zıplama, araca binme, ateş, nişan, ileri/geri/sağ/sol,
-- etkileşim (E), siper, araç direksiyonu / gaz / fren, sohbet (T), bas-konuş (N)
local ACTIVITY_CONTROLS = { 21, 22, 23, 24, 25, 30, 31, 38, 44, 59, 71, 72, 245, 249 }

local isLoaded = false
local playerData = nil
local lastActivity = GetGameTimer()
local lastCamRot, lastCoords = nil, nil

local function MarkActive()
    lastActivity = GetGameTimer()
end

local function AngleDiff(a, b)
    local diff = math.abs(a - b) % 360.0
    return diff > 180.0 and 360.0 - diff or diff
end

--- Tek bir aktivite örneği alır.
local function SampleActivity()
    local ped = PlayerPedId()

    -- Kamera: GTA'nın otomatik boşta kamerası dönerken kamera hareketi aktivite sayılmaz
    local idleCam = IsCinematicIdleCamRendering and IsCinematicIdleCamRendering()
    local camRot = GetGameplayCamRot(2)
    if lastCamRot and not idleCam then
        if AngleDiff(camRot.x, lastCamRot.x) >= CAMERA_THRESHOLD or AngleDiff(camRot.z, lastCamRot.z) >= CAMERA_THRESHOLD then
            MarkActive()
        end
    end
    lastCamRot = camRot

    -- Konum: araçta yalnızca sürücünün hareketi sayılır (AFK yolcu sayılmaz)
    local coords = GetEntityCoords(ped)
    local vehicle = GetVehiclePedIsIn(ped, false)
    local canMove = vehicle == 0 or GetPedInVehicleSeat(vehicle, -1) == ped
    if lastCoords and canMove and #(coords - lastCoords) >= MOVE_THRESHOLD then
        MarkActive()
    end
    lastCoords = coords

    -- Sesli konuşma
    if Config.Afk.CountVoice and NetworkIsPlayerTalking(PlayerId()) then
        MarkActive()
        return
    end

    -- Tuş girdileri
    for i = 1, #ACTIVITY_CONTROLS do
        local control = ACTIVITY_CONTROLS[i]
        if IsControlPressed(0, control) or IsDisabledControlPressed(0, control) then
            MarkActive()
            return
        end
    end
end

local function SendHeartbeat()
    local idleSeconds = 0
    if TRACK_ACTIVITY then
        idleSeconds = math.floor((GetGameTimer() - lastActivity) / 1000)
    end
    TriggerServerEvent('loe_exp:server:activity', idleSeconds)
end

------------------------------------------------------------------------
-- Ana döngü (tek döngü, düşük frekans)
------------------------------------------------------------------------
CreateThread(function()
    local sinceHeartbeat = 0
    local sinceSyncRequest = SYNC_RETRY_MS

    while true do
        if isLoaded then
            Wait(SAMPLE_MS)
            if TRACK_ACTIVITY then
                SampleActivity()
            end
            sinceHeartbeat = sinceHeartbeat + SAMPLE_MS
            if sinceHeartbeat >= HEARTBEAT_MS then
                sinceHeartbeat = 0
                SendHeartbeat()
            end
        else
            -- Veri henüz gelmediyse (geç yükleme / resource yeniden başlatma) belirli aralıkla iste
            Wait(1000)
            sinceSyncRequest = sinceSyncRequest + 1000
            if sinceSyncRequest >= SYNC_RETRY_MS and NetworkIsPlayerActive(PlayerId()) then
                sinceSyncRequest = 0
                TriggerServerEvent('loe_exp:server:requestSync')
            end
        end
    end
end)

------------------------------------------------------------------------
-- Sunucudan gelen olaylar
------------------------------------------------------------------------

-- Seviye verisi (yalnızca gösterim amaçlı; sunucu bu veriye asla güvenmez)
RegisterNetEvent('loe_exp:client:sync', function(data)
    if type(data) ~= 'table' then
        return
    end

    playerData = data

    if not isLoaded then
        isLoaded = true
        lastCamRot, lastCoords = nil, nil
        MarkActive()
        -- İlk bildirim sunucuda referans noktası oluşturur
        SendHeartbeat()
    end

    -- HUD vb. istemci scriptleri için yerel olay
    TriggerEvent('loe_exp:client:onDataUpdated', data)
end)

-- Karakterden çıkıldı (multichar): aktivite bildirimi durur
RegisterNetEvent('loe_exp:client:unloaded', function()
    isLoaded = false
    playerData = nil
end)

-- GTA yerleşik bildirimi (Config.Notify.System = 'native' veya yedek)
RegisterNetEvent('loe_exp:client:notify', function(message)
    if type(message) ~= 'string' then
        return
    end
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(message)
    EndTextCommandThefeedPostTicker(false, true)
end)

------------------------------------------------------------------------
-- İstemci export'ları (salt okunur, yalnızca gösterim için)
------------------------------------------------------------------------
exports('GetLevel', function()
    return playerData and playerData.level or nil
end)

exports('GetData', function()
    return playerData
end)

------------------------------------------------------------------------
-- Sohbet komut önerileri
------------------------------------------------------------------------
CreateThread(function()
    local commands = Config.Commands
    local idParam = { name = 'id', help = 'Oyuncu ID' }

    if commands.Self then
        TriggerEvent('chat:addSuggestion', '/' .. commands.Self, 'Seviye ve EXP bilgini gösterir')
    end
    if commands.View then
        TriggerEvent('chat:addSuggestion', '/' .. commands.View, 'Oyuncunun seviyesini gösterir (Yetkili)', { idParam })
    end
    if commands.Add then
        TriggerEvent('chat:addSuggestion', '/' .. commands.Add, 'Oyuncuya EXP ekler (Yetkili)', { idParam, { name = 'miktar', help = 'Eklenecek EXP' } })
    end
    if commands.Remove then
        TriggerEvent('chat:addSuggestion', '/' .. commands.Remove, 'Oyuncudan EXP çıkarır (Yetkili)', { idParam, { name = 'miktar', help = 'Çıkarılacak EXP' } })
    end
    if commands.Set then
        TriggerEvent('chat:addSuggestion', '/' .. commands.Set, 'Oyuncunun toplam EXP miktarını ayarlar (Yetkili)', { idParam, { name = 'miktar', help = 'Yeni toplam EXP' } })
    end
end)
