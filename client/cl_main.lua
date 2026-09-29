--[[
    loe_exp / client
    İstemcinin tek görevi oyuncunun aktif olup olmadığını gözlemlemek ve sunucuya
    "son aktiviteden bu yana geçen saniye" bilgisini göndermektir.
    İstemci EXP, seviye veya süre BELİRLEYEMEZ; karar sunucudadır.

    Aktivite sayılanlar: kamera hareketi (araç yolcusu hariç), karakterin yer değiştirmesi
    (araç yolcusu hariç), sesli konuşma, telefon / envanter gibi ekranlarda imleç hareketi
    ve temel kontrol tuşları.
    FPS dostu: her karede değil, SampleIntervalMs aralığıyla tek bir döngüde kontrol edilir.
]]

local SAMPLE_MS        = math.max(250, math.floor(tonumber(Config.Afk.SampleIntervalMs) or 1000))
local HEARTBEAT_MS     = math.max(5, math.floor(tonumber(Config.Afk.HeartbeatSeconds) or 30)) * 1000
local SYNC_RETRY_MS    = 10000
local TRACK_ACTIVITY   = Config.Afk.Enabled == true
local CAMERA_THRESHOLD = tonumber(Config.Afk.CameraThreshold) or 1.0
local MOVE_THRESHOLD   = tonumber(Config.Afk.MoveThreshold) or 0.3
local COUNT_NUI_CURSOR = Config.Afk.CountNuiCursor ~= false
local PASSENGER_CAMERA = Config.Afk.PassengerCamera == true

-- Aktivite sayılan kontroller: koşma, zıplama, araca binme, ateş, nişan, ileri/geri/sağ/sol,
-- etkileşim (E), siper, araç direksiyonu / gaz / fren, sohbet (T), bas-konuş (N)
local ACTIVITY_CONTROLS = { 21, 22, 23, 24, 25, 30, 31, 38, 44, 59, 71, 72, 245, 249 }

local isLoaded = false
local playerData = nil
local lastActivity = GetGameTimer()
local lastCamRot, lastCoords = nil, nil
local lastCursorX, lastCursorY = nil, nil
local sinceHeartbeat = 0

local function MarkActive()
    lastActivity = GetGameTimer()
end

local function AngleDiff(a, b)
    local diff = math.abs(a - b) % 360.0
    return diff > 180.0 and 360.0 - diff or diff
end

-- ------------------------------------------------------------------ aktivite örneği
local function SampleActivity()
    local ped = cache.ped
    local isPassenger = cache.vehicle and cache.seat ~= -1

    -- Kamera: GTA'nın otomatik boşta kamerası dönerken kamera hareketi aktivite sayılmaz.
    -- Araç yolcusunda da sayılmaz (PassengerCamera): araç dönerken takip kamerası kendiliğinden döner.
    local idleCam = IsCinematicIdleCamRendering and IsCinematicIdleCamRendering()
    local camRot = GetGameplayCamRot(2)
    if lastCamRot and not idleCam and (PASSENGER_CAMERA or not isPassenger) then
        if AngleDiff(camRot.x, lastCamRot.x) >= CAMERA_THRESHOLD or AngleDiff(camRot.z, lastCamRot.z) >= CAMERA_THRESHOLD then
            MarkActive()
        end
    end
    lastCamRot = camRot

    -- Konum: araçta yalnızca sürücünün hareketi sayılır (AFK yolcu sayılmaz)
    local coords = GetEntityCoords(ped)
    if lastCoords and not isPassenger and #(coords - lastCoords) >= MOVE_THRESHOLD then
        MarkActive()
    end
    lastCoords = coords

    -- Telefon / envanter gibi NUI ekranları: kamera ve karakter sabittir, imleç hareketi aktivitedir
    if COUNT_NUI_CURSOR and IsNuiFocused() then
        local x, y = GetNuiCursorPosition()
        if lastCursorX and (x ~= lastCursorX or y ~= lastCursorY) then
            MarkActive()
        end
        lastCursorX, lastCursorY = x, y
    else
        lastCursorX, lastCursorY = nil, nil
    end

    -- Sesli konuşma
    if Config.Afk.CountVoice and NetworkIsPlayerTalking(cache.playerId) then
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

-- ------------------------------------------------------------------ ana döngü
CreateThread(function()
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
            -- Karakter yüklü ama veri gelmediyse (resource yeniden başlatma vb.) belirli aralıkla iste
            Wait(1000)
            sinceSyncRequest = sinceSyncRequest + 1000
            if sinceSyncRequest >= SYNC_RETRY_MS and LocalPlayer.state.isLoggedIn then
                sinceSyncRequest = 0
                TriggerServerEvent('loe_exp:server:requestSync')
            end
        end
    end
end)

-- ------------------------------------------------------------------ sunucu olayları

-- Seviye verisi (yalnızca gösterim amaçlı; sunucu bu veriye asla güvenmez)
RegisterNetEvent('loe_exp:client:sync', function(data)
    if type(data) ~= 'table' then
        return
    end

    playerData = data

    if not isLoaded then
        isLoaded = true
        lastCamRot, lastCoords = nil, nil
        lastCursorX, lastCursorY = nil, nil
        MarkActive()
        -- İlk bildirim sunucuda referans noktası oluşturur; sayaç sıfırlanır ki
        -- bir sonraki bildirim sunucunun hız sınırına takılmadan tam aralıkla gitsin
        sinceHeartbeat = 0
        SendHeartbeat()
    end

    -- HUD vb. istemci scriptleri için yerel olay
    TriggerEvent('loe_exp:client:onDataUpdated', data)
end)

-- Karakterden çıkıldı: aktivite bildirimi durur
RegisterNetEvent('loe_exp:client:unloaded', function()
    isLoaded = false
    playerData = nil
end)

-- ------------------------------------------------------------------ exports (salt okunur)
exports('GetLevel', function()
    return playerData and playerData.level or nil
end)

exports('GetData', function()
    return playerData
end)
