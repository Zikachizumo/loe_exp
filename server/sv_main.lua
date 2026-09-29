--[[
    loe_exp / server / main

    EXP, seviye ve aktif süre hesaplamalarının TAMAMI burada, sunucu tarafında yapılır.
    İstemciden gelen tek bilgi "son aktiviteden bu yana geçen saniye"dir. Bu bilgi doğrulanır,
    sınırlandırılır ve hiçbir zaman doğrudan EXP'ye çevrilmez.

    Aktif süre modeli (çapa / anchor):
      - Her oyuncu için "en son sayılan aktivite anı" (anchor) tutulur.
      - İstemci her HeartbeatSeconds'ta bir son aktivite anını bildirir.
      - Yeni aktivite anı ile anchor arasındaki boşluk AFK süresinden (TimeoutMinutes) kısaysa
        bu boşluk aktif süreye eklenir. Uzunsa boşluğun TAMAMI AFK sayılır ve eklenmez.
      - anchor hiçbir zaman sunucu saatini geçemez. Bu nedenle eklenen süre, gerçekte geçen
        süreden fazla olamaz (sahte bildirimler en fazla gerçek zamanı kazandırabilir,
        bu da sunucu taraflı hareketsizlik kontrolüyle ayrıca sınırlandırılır).
]]

LoeExp = {
    Sessions = {},      -- [source] = oturum (çevrimiçi ve verisi yüklenmiş oyuncular)
    ByIdentifier = {},  -- [citizenid] = source
    Pending = {},       -- [citizenid] = oturum (oyundan çıkmış, son kaydı henüz onaylanmamış)
    Ready = false,
}

local Sessions = LoeExp.Sessions
local ByIdentifier = LoeExp.ByIdentifier
local Pending = LoeExp.Pending
local L = Config.Locale

local MAX_LEVEL = LoeLevel.MaxLevel
local INTERVAL_SECONDS = math.max(1, math.floor((tonumber(Config.ExpIntervalMinutes) or 60) * 60))
local EXP_PER_INTERVAL = math.max(0, math.floor(tonumber(Config.ExpPerInterval) or 1))
local AUTOSAVE_MS = math.max(1, tonumber(Config.AutoSaveMinutes) or 5) * 60000

local AFK_ENABLED = Config.Afk.Enabled == true
local AFK_TIMEOUT = math.max(60, math.floor((tonumber(Config.Afk.TimeoutMinutes) or 10) * 60))
local HEARTBEAT_SECONDS = math.max(5, math.floor(tonumber(Config.Afk.HeartbeatSeconds) or 30))
local HEARTBEAT_MIN_GAP = math.max(1, math.floor(HEARTBEAT_SECONDS / 2))
local MAX_IDLE_SECONDS = 30 * 24 * 3600
local SYNC_MIN_GAP = 5
local SPAM_WARN_COUNT = 20

local ServerCheck = Config.Afk.ServerCheck or {}
local STILL_ENABLED = AFK_ENABLED and ServerCheck.Enabled == true
local STILL_SECONDS = math.max(60, math.floor((tonumber(ServerCheck.StillMinutes) or 20) * 60))
local MIN_DISTANCE_SQ = (tonumber(ServerCheck.MinDistance) or 1.0) ^ 2
local MIN_HEADING = tonumber(ServerCheck.MinHeading) or 10.0

local loadTokens = {}  -- [source] = devam eden yüklemenin jetonu
local retryAt = {}     -- [source] = oturumu olmayan oyuncu için bir sonraki yükleme denemesi
local nextToken = 0

local function Debug(message, ...)
    if Config.Debug then
        print(('^5[loe_exp:debug]^0 ' .. message):format(...))
    end
end

------------------------------------------------------------------------
-- Oturum yardımcıları
------------------------------------------------------------------------

local function MarkDirty(session)
    session.version = session.version + 1
    session.dirty = true
end

--- Aktivite takibini sıfırlar. Giriş / yeniden yüklemede çağrılır, böylece
--- çevrimdışı geçen süre veya yükleme ekranı asla aktif süre sayılmaz.
local function ResetActivity(session, now)
    session.anchor = nil
    session.lastHeartbeat = 0
    session.lastSyncRequest = 0
    session.spam = 0
    session.isAfk = false
    session.afkSince = nil
    session.lastPos = nil
    session.lastHeading = nil
    session.lastMoveAt = now
end

local function NewSession(identifier, row)
    return {
        identifier = identifier,
        source = nil,
        name = '',
        level = math.floor(tonumber(row.level) or 1),
        totalExp = math.floor(tonumber(row.total_exp) or 0),
        activeSeconds = math.floor(tonumber(row.active_seconds) or 0),
        totalActiveSeconds = math.floor(tonumber(row.total_active_seconds) or 0),
        -- Kayıt durumu
        version = 0,
        dirty = false,
        saving = false,
        saveQueued = false,
        offline = false,
    }
end

--- Değerleri sınırlar ve seviyeyi toplam EXP'den yeniden hesaplar.
---@return boolean changed
local function Normalize(session)
    local maxTotal = LoeLevel.GetMaxTotalExp()
    local total = session.totalExp
    if total ~= total or total < 0 then
        total = 0
    elseif total > maxTotal then
        total = maxTotal
    end

    local level = LoeLevel.CalculateLevel(total)
    local active = session.activeSeconds
    if active ~= active or active < 0 or level >= MAX_LEVEL then
        active = 0
    end

    local changed = total ~= session.totalExp or level ~= session.level or active ~= session.activeSeconds
    session.totalExp, session.level, session.activeSeconds = total, level, active
    if changed then
        MarkDirty(session)
    end
    return changed
end

local function Snapshot(session)
    return {
        identifier = session.identifier,
        level = session.level,
        totalExp = session.totalExp,
        activeSeconds = session.activeSeconds,
        totalActiveSeconds = session.totalActiveSeconds,
        name = session.name or '',
    }
end

--- İstemciye ve diğer resource'lara verilen salt okunur veri.
function LoeExp.BuildPublicData(session)
    local level, current, required = LoeLevel.GetProgress(session.totalExp)
    return {
        level = level,
        totalExp = session.totalExp,
        currentExp = current,               -- mevcut seviyede biriken EXP
        requiredExp = required,             -- sonraki seviye için gereken EXP (maks. seviyede 0)
        maxLevel = MAX_LEVEL,
        isMaxLevel = level >= MAX_LEVEL,
        activeMinutes = math.floor(session.activeSeconds / 60),  -- sonraki EXP'ye doğru biriken aktif dk
        intervalMinutes = math.floor(INTERVAL_SECONDS / 60),
        totalActiveMinutes = math.floor(session.totalActiveSeconds / 60),
    }
end

function LoeExp.Sync(session)
    if session.source then
        TriggerClientEvent('loe_exp:client:sync', session.source, LoeExp.BuildPublicData(session))
    end
end

local function NotifyPlayer(session, message, notifyType)
    if Config.Notify.Enabled and session.source then
        LoeQbox.Notify(session.source, message, notifyType)
    end
end

------------------------------------------------------------------------
-- Kayıt
------------------------------------------------------------------------

--- Kayıt tamamlandığında çağrılır. Kayıt sürerken veri değiştiyse (version farklı) dirty kalır.
local function FinishSave(session, version, ok)
    session.saving = false

    if ok then
        if session.version == version then
            session.dirty = false
        end
    else
        print(('^1[loe_exp] %s için kayıt başarısız, bir sonraki otomatik kayıtta tekrar denenecek.^0'):format(session.identifier))
    end

    -- Oyundan çıkmış oyuncunun son kaydı onaylandıysa bellekten temizle
    if session.offline and not session.dirty and Pending[session.identifier] == session then
        Pending[session.identifier] = nil
    end

    if session.saveQueued then
        session.saveQueued = false
        LoeExp.SaveSession(session)
    end
end

--- Tek bir oturumu kaydeder. Aynı oturum için kayıtlar sıraya alınır, üst üste binmez.
function LoeExp.SaveSession(session)
    if session.saving then
        session.saveQueued = true
        return
    end

    session.saving = true
    local version = session.version
    local snapshot = Snapshot(session)

    CreateThread(function()
        local ok = LoeExpDB.SavePlayersAwait({ snapshot })
        FinishSave(session, version, ok)
    end)
end

--- Değişmiş tüm oturumları TEK transaction ile kaydeder (otomatik kayıt).
---@return number kaydedilen oturum sayısı
function LoeExp.SaveDirtySessions()
    local snapshots, entries = {}, {}

    local function Collect(session)
        if session.dirty and not session.saving then
            session.saving = true
            snapshots[#snapshots + 1] = Snapshot(session)
            entries[#entries + 1] = { session = session, version = session.version }
        end
    end

    for _, session in pairs(Sessions) do Collect(session) end
    for _, session in pairs(Pending) do Collect(session) end

    if #snapshots == 0 then
        return 0
    end

    local ok = LoeExpDB.SavePlayersAwait(snapshots)
    for i = 1, #entries do
        FinishSave(entries[i].session, entries[i].version, ok)
    end

    Debug('Otomatik kayıt: %d oyuncu (%s)', #snapshots, ok and 'başarılı' or 'BAŞARISIZ')
    return #snapshots
end

--- Kapanışta tüm oturumları beklemeden kaydeder.
function LoeExp.FlushAll()
    local snapshots = {}
    for _, session in pairs(Sessions) do snapshots[#snapshots + 1] = Snapshot(session) end
    for _, session in pairs(Pending) do snapshots[#snapshots + 1] = Snapshot(session) end
    LoeExpDB.SavePlayersNoWait(snapshots)
    return #snapshots
end

------------------------------------------------------------------------
-- EXP / seviye
------------------------------------------------------------------------

--- Toplam EXP'yi değiştirir, seviyeyi DÖNGÜ ile yeniden hesaplar, kaydeder,
--- istemciyi günceller, bildirim ve olayları tetikler.
---@return number delta
local function ChangeTotalExp(session, newTotal, reason)
    local maxTotal = LoeLevel.GetMaxTotalExp()
    if newTotal < 0 then
        newTotal = 0
    elseif newTotal > maxTotal then
        newTotal = maxTotal
    end

    local oldTotal, oldLevel = session.totalExp, session.level
    local newLevel = LoeLevel.CalculateLevel(newTotal)

    session.totalExp = newTotal
    session.level = newLevel
    if newLevel >= MAX_LEVEL then
        -- Maksimum seviyede aktif süre sayacı durur
        session.activeSeconds = 0
    end
    MarkDirty(session)

    -- EXP / seviye değişiklikleri seyrek olduğundan otomatik kaydı beklemeden hemen yazılır
    LoeExp.SaveSession(session)
    LoeExp.Sync(session)
    LoeQbox.SyncMetadata(session.source, newLevel, newTotal)

    local delta = newTotal - oldTotal

    if newLevel > oldLevel then
        if Config.Notify.LevelUp then
            -- Birden fazla seviye atlandıysa yalnızca ulaşılan son seviye bildirilir
            NotifyPlayer(session, L.level_up:format(newLevel), 'success')
            if newLevel >= MAX_LEVEL then
                NotifyPlayer(session, L.max_level:format(MAX_LEVEL), 'success')
            end
        end
    elseif newLevel < oldLevel then
        if Config.Notify.LevelDown then
            NotifyPlayer(session, L.level_down:format(newLevel), 'error')
        end
    elseif delta > 0 and reason == 'playtime' and Config.Notify.ExpGain then
        local _, current, required = LoeLevel.GetProgress(newTotal)
        NotifyPlayer(session, L.exp_gain:format(delta, newLevel, current, required), 'inform')
    end

    -- Diğer LOE sistemleri için sunucu içi olaylar (istemci tetikleyemez)
    if delta ~= 0 then
        TriggerEvent('loe_exp:onExpChanged', session.source, newTotal, delta, reason)
    end
    if newLevel ~= oldLevel then
        TriggerEvent('loe_exp:onLevelChanged', session.source, newLevel, oldLevel)
    end

    Debug('%s: EXP %d -> %d, seviye %d -> %d (%s)', session.identifier, oldTotal, newTotal, oldLevel, newLevel, tostring(reason))
    return delta
end

--- Doğrulanmış aktif süreyi ekler. Her INTERVAL_SECONDS dolduğunda EXP_PER_INTERVAL EXP verilir.
function LoeExp.CreditActiveTime(session, seconds)
    seconds = math.floor(seconds)
    if seconds <= 0 then
        return
    end

    -- İstatistik: toplam aktif oyun süresi (maks. seviyede de tutulur)
    session.totalActiveSeconds = session.totalActiveSeconds + seconds

    if session.level >= MAX_LEVEL then
        session.activeSeconds = 0
        MarkDirty(session)
        return
    end

    session.activeSeconds = session.activeSeconds + seconds
    local intervals = session.activeSeconds // INTERVAL_SECONDS
    MarkDirty(session)

    if intervals > 0 then
        session.activeSeconds = session.activeSeconds - intervals * INTERVAL_SECONDS
        if EXP_PER_INTERVAL > 0 then
            ChangeTotalExp(session, session.totalExp + intervals * EXP_PER_INTERVAL, 'playtime')
        end
    end
end

------------------------------------------------------------------------
-- Aktivite doğrulama
------------------------------------------------------------------------

local function HeadingDiff(a, b)
    local diff = math.abs(a - b) % 360.0
    return diff > 180.0 and 360.0 - diff or diff
end

--- Sunucu taraflı hareketsizlik kontrolü (OneSync). İstemci verisinden bağımsızdır.
---@return boolean still Oyuncu StillMinutes boyunca hiç yer / yön değiştirmedi mi?
local function IsServerSideStill(session, now)
    if not STILL_ENABLED then
        return false
    end

    local ped = GetPlayerPed(session.source)
    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return false -- OneSync kapalı veya ped yok: kontrol atlanır
    end

    local coords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local last = session.lastPos

    if not last then
        session.lastPos, session.lastHeading, session.lastMoveAt = coords, heading, now
        return false
    end

    local dx, dy, dz = coords.x - last.x, coords.y - last.y, coords.z - last.z
    if (dx * dx + dy * dy + dz * dz) >= MIN_DISTANCE_SQ or HeadingDiff(heading, session.lastHeading) >= MIN_HEADING then
        session.lastPos, session.lastHeading, session.lastMoveAt = coords, heading, now
    end

    return (now - session.lastMoveAt) >= STILL_SECONDS
end

--- İstemciden gelen "son aktiviteden bu yana geçen saniye" değerini doğrular.
---@return integer|nil
local function SanitizeIdle(value)
    if type(value) ~= 'number' or value ~= value or value < 0 or value > MAX_IDLE_SECONDS then
        return nil
    end
    return math.floor(value)
end

local function MarkAfk(session, since)
    if not session.isAfk then
        session.isAfk = true
        session.afkSince = since
        Debug('%s AFK durumuna geçti', session.identifier)
    end
end

--- Aktivite bildirimini işler. EXP verme kararı tamamen burada, sunucu saatine göre verilir.
function LoeExp.HandleActivity(session, idleSeconds, now)
    local activityAt

    if not AFK_ENABLED then
        activityAt = now
    else
        local idle = SanitizeIdle(idleSeconds)
        activityAt = idle and (now - idle) or nil
    end

    -- İstemci aktif dese bile sunucu uzun süre hiç hareket görmediyse AFK kabul edilir
    if activityAt and IsServerSideStill(session, now) then
        activityAt = nil
    end

    if not activityAt then
        -- AFK (sunucu hareketsizlik) / doğrulanamayan bildirim: bu ana kadar geçen süre sayılmaz
        MarkAfk(session, session.anchor or now)
        session.anchor = now
        return
    end

    local anchor = session.anchor
    if not anchor then
        -- Girişten sonraki ilk bildirim yalnızca referans noktası oluşturur
        session.anchor = activityAt
        return
    end

    if activityAt <= anchor then
        -- Yeni aktivite yok. AFK süresi aşıldıysa oyuncu AFK'dır.
        if now - anchor > AFK_TIMEOUT then
            MarkAfk(session, anchor)
        end
        return
    end

    local gap = activityAt - anchor
    local wasAfk, afkSince = session.isAfk, session.afkSince

    session.anchor = activityAt
    session.isAfk = false
    session.afkSince = nil

    if gap <= AFK_TIMEOUT and not wasAfk then
        LoeExp.CreditActiveTime(session, gap)
        return
    end

    -- AFK dönüşü: aradaki sürenin tamamı sayılmaz
    local afkMinutes = (activityAt - (afkSince or anchor)) // 60
    Debug('%s AFK dönüşü, %d dk sayılmadı', session.identifier, afkMinutes)
    if Config.Notify.AfkReturn and afkMinutes >= 1 and session.level < MAX_LEVEL then
        NotifyPlayer(session, L.afk_return:format(afkMinutes), 'inform')
    end
end

------------------------------------------------------------------------
-- Oyuncu yükleme / bırakma
------------------------------------------------------------------------

--- Bellekte bu kimliğe ait daha güncel bir oturum varsa onu devralır
--- (aynı kimlik başka bir kaynakta açık kalmışsa veya son kaydı bekleniyorsa).
local function TakeInMemorySession(identifier, newSource)
    local existingSource = ByIdentifier[identifier]
    if existingSource and existingSource ~= newSource and Sessions[existingSource] then
        local session = Sessions[existingSource]
        Sessions[existingSource] = nil
        ByIdentifier[identifier] = nil
        if GetPlayerName(existingSource) then
            TriggerClientEvent('loe_exp:client:unloaded', existingSource)
        end
        return session
    end

    local pending = Pending[identifier]
    if pending then
        Pending[identifier] = nil
        return pending
    end

    return nil
end

--- Oyuncunun seviye verisini yükler ve oturum açar.
---@return boolean
function LoeExp.LoadPlayer(source)
    local src = tonumber(source)
    if not src or src <= 0 or not LoeExp.Ready then
        return false
    end
    if Sessions[src] or loadTokens[src] or not GetPlayerName(src) then
        return false
    end

    local identifier = LoeQbox.GetCitizenId(src)
    if not identifier then
        Debug('citizenid bulunamadı (karakter yüklü değil): %d', src)
        return false
    end
    local name = LoeQbox.GetName(src)

    local session = TakeInMemorySession(identifier, src)

    if not session then
        nextToken = nextToken + 1
        local token = nextToken
        loadTokens[src] = token

        local ok, row = pcall(LoeExpDB.FetchPlayer, identifier, name)

        if loadTokens[src] ~= token then
            return false -- beklerken oyuncu çıktı veya karakter değiştirdi
        end
        loadTokens[src] = nil

        if not ok or not row then
            print(('^1[loe_exp] %s (%d) verisi yüklenemedi: %s^0'):format(identifier, src, tostring(row)))
            return false
        end
        if not GetPlayerName(src) or LoeQbox.GetCitizenId(src) ~= identifier or Sessions[src] then
            return false
        end

        -- Beklerken bellekte daha güncel veri oluştuysa (çok nadir) onu kullan
        session = TakeInMemorySession(identifier, src) or NewSession(identifier, row)
    end

    session.source = src
    session.name = name
    session.offline = false
    ResetActivity(session, os.time())

    -- Veritabanındaki seviye toplam EXP ile uyuşmuyorsa düzeltilir
    if Normalize(session) then
        LoeExp.SaveSession(session)
    end

    Sessions[src] = session
    ByIdentifier[identifier] = src
    retryAt[src] = nil

    LoeExp.Sync(session)
    LoeQbox.SyncMetadata(src, session.level, session.totalExp)
    TriggerEvent('loe_exp:onPlayerLoaded', src, LoeExp.BuildPublicData(session))
    Debug('Yüklendi: %s (%d) seviye %d, %d EXP, %d sn aktif', identifier, src, session.level, session.totalExp, session.activeSeconds)
    return true
end

--- Oyuncunun oturumunu kapatır ve verisini kaydeder.
---@param reason 'drop'|'logout'|string drop: oyundan çıkış, logout: karakter değiştirme
function LoeExp.UnloadPlayer(source, reason)
    local src = tonumber(source)
    if not src then
        return
    end

    loadTokens[src] = nil
    retryAt[src] = nil

    local session = Sessions[src]
    if not session then
        return
    end

    Sessions[src] = nil
    if ByIdentifier[session.identifier] == src then
        ByIdentifier[session.identifier] = nil
    end

    session.source = nil
    session.offline = true
    -- Son kayıt onaylanana kadar bellekte tutulur. Kayıt başarısız olursa otomatik kayıt tekrar dener,
    -- oyuncu bu arada geri gelirse veritabanı yerine bu güncel veri kullanılır.
    Pending[session.identifier] = session
    MarkDirty(session)
    LoeExp.SaveSession(session)

    if reason ~= 'drop' and GetPlayerName(src) then
        TriggerClientEvent('loe_exp:client:unloaded', src)
    end
    Debug('Bırakıldı: %s (%d) [%s]', session.identifier, src, tostring(reason))
end

------------------------------------------------------------------------
-- Genel API (sv_exports.lua ve sv_commands.lua kullanır)
------------------------------------------------------------------------

function LoeExp.GetSession(source)
    local src = tonumber(source)
    return src and Sessions[src] or nil
end

local function ValidateAmount(amount, minimum)
    local value = LoeLevel.ToInteger(amount)
    if not value or value < minimum or value > LoeLevel.GetMaxTotalExp() then
        return nil
    end
    return value
end

---@return boolean ok, number|string levelOrError, number? totalExp
function LoeExp.AddExp(source, amount, reason)
    local session = LoeExp.GetSession(source)
    if not session then
        return false, 'not_loaded'
    end
    amount = ValidateAmount(amount, 1)
    if not amount then
        return false, 'invalid_amount'
    end
    if session.level >= MAX_LEVEL then
        return false, 'max_level'
    end
    ChangeTotalExp(session, session.totalExp + amount, reason or 'external')
    return true, session.level, session.totalExp
end

function LoeExp.RemoveExp(source, amount, reason)
    local session = LoeExp.GetSession(source)
    if not session then
        return false, 'not_loaded'
    end
    amount = ValidateAmount(amount, 1)
    if not amount then
        return false, 'invalid_amount'
    end
    if session.totalExp <= 0 then
        return false, 'no_exp'
    end
    ChangeTotalExp(session, session.totalExp - amount, reason or 'external')
    return true, session.level, session.totalExp
end

function LoeExp.SetExp(source, amount, reason)
    local session = LoeExp.GetSession(source)
    if not session then
        return false, 'not_loaded'
    end
    amount = ValidateAmount(amount, 0)
    if not amount then
        return false, 'invalid_amount'
    end
    ChangeTotalExp(session, amount, reason or 'external')
    return true, session.level, session.totalExp
end

--- Seviyeyi toplam EXP'den yeniden hesaplar (tutarsızlık düzeltme).
function LoeExp.RecalculateLevel(source)
    local session = LoeExp.GetSession(source)
    if not session then
        return false, 'not_loaded'
    end
    ChangeTotalExp(session, session.totalExp, 'recalculate')
    return true, session.level, session.totalExp
end

function LoeExp.IsPlayerAfk(source)
    local session = LoeExp.GetSession(source)
    if not session then
        return nil
    end
    return session.isAfk
end

------------------------------------------------------------------------
-- İstemci olayları (yalnızca bu iki olay istemciye açıktır)
------------------------------------------------------------------------

-- Aktivite bildirimi. Yük: son aktiviteden bu yana geçen saniye (sayı).
-- Bu olay EXP / seviye belirleyemez; yalnızca sunucunun doğruladığı aktivite zamanını günceller.
RegisterNetEvent('loe_exp:server:activity', function(idleSeconds)
    local src = source
    local session = Sessions[src]
    if not session then
        return
    end

    local now = os.time()

    -- Hız sınırı: beklenenden sık gelen bildirimler yok sayılır
    if session.lastHeartbeat > 0 and (now - session.lastHeartbeat) < HEARTBEAT_MIN_GAP then
        session.spam = session.spam + 1
        if session.spam == SPAM_WARN_COUNT then
            print(('^3[loe_exp] Şüpheli: %s (%d) aktivite olayını çok sık gönderiyor.^0'):format(session.name, src))
        end
        return
    end

    session.lastHeartbeat = now
    session.spam = 0
    LoeExp.HandleActivity(session, idleSeconds, now)
end)

-- İstemci kendi verisini ister (resource yeniden başlatma / geç yükleme durumları için).
-- Oturum yoksa ve karakter yüklüyse yükleme yeniden denenir (ör. geçici veritabanı hatası).
RegisterNetEvent('loe_exp:server:requestSync', function()
    local src = source
    local now = os.time()
    local session = Sessions[src]

    if session then
        if now - session.lastSyncRequest >= SYNC_MIN_GAP then
            session.lastSyncRequest = now
            LoeExp.Sync(session)
        end
        return
    end

    if not LoeExp.Ready or (retryAt[src] or 0) > now then
        return
    end
    retryAt[src] = now + SYNC_MIN_GAP

    if LoeQbox.IsPlayerLoaded(src) then
        CreateThread(function()
            LoeExp.LoadPlayer(src)
        end)
    end
end)

------------------------------------------------------------------------
-- Yaşam döngüsü
------------------------------------------------------------------------

-- Qbox: karakter yüklendi
AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
    local src = player and player.PlayerData and tonumber(player.PlayerData.source)
    if src then
        CreateThread(function()
            LoeExp.LoadPlayer(src)
        end)
    end
end)

-- Qbox: karakterden çıkış (karakter değiştirme)
AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
    LoeExp.UnloadPlayer(src, 'logout')
end)

AddEventHandler('playerDropped', function()
    LoeExp.UnloadPlayer(source, 'drop')
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then
        return
    end
    local count = LoeExp.FlushAll()
    print(('[loe_exp] Kapanış kaydı gönderildi (%d oyuncu).'):format(count))
end)

-- txAdmin planlı yeniden başlatma / kapatma
AddEventHandler('txAdmin:events:serverShuttingDown', function()
    LoeExp.FlushAll()
end)

CreateThread(function()
    if HEARTBEAT_SECONDS >= AFK_TIMEOUT then
        print('^1[loe_exp] Config.Afk.HeartbeatSeconds, TimeoutMinutes süresinden kısa olmalı! Aktif süre sayılamaz.^0')
    end

    if Config.AutoCreateTables then
        LoeExpDB.EnsureSchema()
    end

    -- Kaynak yeniden başlatıldıysa önceki kapanış kaydının veritabanına ulaşması için kısa bekleme
    Wait(2000)
    LoeExp.Ready = true

    -- Kaynak sunucu açıkken başlatıldıysa içerideki oyuncuları yükle
    for _, playerId in ipairs(GetPlayers()) do
        local src = tonumber(playerId)
        if src and LoeQbox.IsPlayerLoaded(src) then
            LoeExp.LoadPlayer(src)
        end
    end

    print(('[loe_exp] Hazır | Maks. seviye: %d (%d EXP) | %d EXP / %d aktif dk | AFK: %s'):format(
        MAX_LEVEL, LoeLevel.GetMaxTotalExp(), EXP_PER_INTERVAL, INTERVAL_SECONDS // 60,
        AFK_ENABLED and ((AFK_TIMEOUT // 60) .. ' dk') or 'kapalı'
    ))

    -- Otomatik toplu kayıt
    while true do
        Wait(AUTOSAVE_MS)
        LoeExp.SaveDirtySessions()
    end
end)
