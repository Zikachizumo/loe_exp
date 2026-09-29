--[[
    loe_exp / server / database (oxmysql)

    - Tüm sorgular parametrelidir (?), kullanıcı verisi asla sorgu metnine eklenmez.
    - Kayıtlar toplu (tek transaction) yapılır; her saniye sorgu gönderilmez.
    - Her bekleyen çağrı zaman aşımıyla korunur (bkz. Await).
    - Metin alanları sütun uzunluğuna göre kırpılır; STRICT modda tek bir uzun değer
      kaydın tamamını reddettirmez.
]]

LoeExpDB = {}

LoeExpDB.TIMEOUT = 'timeout'

local SCHEMA_FILE = 'sql/loe_exp.sql'
local TIMEOUT_MS = math.max(5, tonumber(Config.DatabaseTimeout) or 30) * 1000

-- sql/loe_exp.sql içindeki sütun uzunlukları (karakter)
local LIMITS = {
    identifier = 64,
    name = 100,
    action = 32,
    note = 255,
}

local SELECT_PLAYER = 'SELECT `level`, `total_exp`, `active_seconds`, `total_active_seconds` FROM `loe_exp` WHERE `identifier` = ? LIMIT 1'

local INSERT_PLAYER = 'INSERT IGNORE INTO `loe_exp` (`identifier`, `level`, `total_exp`, `active_seconds`, `total_active_seconds`, `last_name`) VALUES (?, 1, 0, 0, 0, ?)'

local UPSERT_PLAYER = [[
INSERT INTO `loe_exp` (`identifier`, `level`, `total_exp`, `active_seconds`, `total_active_seconds`, `last_name`)
VALUES (?, ?, ?, ?, ?, ?)
ON DUPLICATE KEY UPDATE
    `level` = VALUES(`level`),
    `total_exp` = VALUES(`total_exp`),
    `active_seconds` = VALUES(`active_seconds`),
    `total_active_seconds` = VALUES(`total_active_seconds`),
    `last_name` = VALUES(`last_name`)
]]

local INSERT_LOG = [[
INSERT INTO `loe_exp_logs`
    (`action`, `actor_identifier`, `actor_name`, `target_identifier`, `target_name`,
     `amount`, `old_level`, `new_level`, `old_exp`, `new_exp`, `note`)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
]]

--- Metni sütuna sığacak şekilde karakter (UTF-8) bazında kırpar.
--- Geçersiz UTF-8 baytları '?' ile değiştirilir.
---@param value any
---@param maxChars integer
---@return string
function LoeExpDB.CleanText(value, maxChars)
    local text = tostring(value or '')
    if not utf8.len(text) then
        text = (text:gsub('[\128-\255]', '?'))
    end
    if utf8.len(text) > maxChars then
        text = text:sub(1, utf8.offset(text, maxChars + 1) - 1)
    end
    return text
end

local CleanText = LoeExpDB.CleanText

--- oxmysql .await çağrısını zaman aşımıyla çalıştırır.
--- oxmysql, veritabanına bağlanamadığında bekleyen çağrıya hiç cevap vermez. Bu sarmalayıcı
--- olmadan çağıran iş parçacığı (ör. otomatik kayıt döngüsü) sonsuza kadar asılı kalır.
---@return boolean ok
---@return any resultOrError başarısızsa hata mesajı veya LoeExpDB.TIMEOUT
local function Await(fn, ...)
    local p = promise.new()
    local args = table.pack(...)

    CreateThread(function()
        local ok, result = pcall(fn, table.unpack(args, 1, args.n))
        p:resolve({ ok, result })
    end)

    -- Önce hangisi gelirse o geçerlidir; promise yalnızca bir kez çözülür
    SetTimeout(TIMEOUT_MS, function()
        p:resolve({ false, LoeExpDB.TIMEOUT })
    end)

    local outcome = Citizen.Await(p)
    return outcome[1], outcome[2]
end

--- sql/loe_exp.sql dosyasını çalıştırarak tabloları oluşturur (CREATE TABLE IF NOT EXISTS).
--- Böylece tablo tanımı tek bir yerde (SQL dosyasında) tutulur.
function LoeExpDB.EnsureSchema()
    local content = LoadResourceFile(GetCurrentResourceName(), SCHEMA_FILE)
    if not content then
        print(('^1[loe_exp] %s okunamadı, tablolar otomatik oluşturulamadı.^0'):format(SCHEMA_FILE))
        return false
    end

    -- '--' ile başlayan yorum satırlarını çıkar
    local lines = {}
    for line in (content:gsub('\r', '') .. '\n'):gmatch('([^\n]*)\n') do
        if not line:match('^%s*%-%-') then
            lines[#lines + 1] = line
        end
    end

    local success = true
    for statement in table.concat(lines, '\n'):gmatch('[^;]+') do
        if statement:match('%S') then
            local ok, err = Await(MySQL.query.await, statement)
            if not ok then
                success = false
                print(('^1[loe_exp] Tablo oluşturma hatası: %s^0'):format(tostring(err)))
            end
        end
    end
    return success
end

--- Oyuncu verisini okur, kayıt yoksa oluşturur.
--- Okuma başarısız olursa hata fırlatır: böylece hatalı durumda oyuncuya sıfır veriyle
--- oturum açılıp gerçek verinin üzerine yazılması engellenir.
function LoeExpDB.FetchPlayer(identifier, name)
    local ok, row = Await(MySQL.single.await, SELECT_PLAYER, { identifier })
    if not ok then
        error(('okuma başarısız: %s'):format(tostring(row)))
    end
    if row then
        return row
    end

    ok, row = Await(MySQL.insert.await, INSERT_PLAYER, { identifier, CleanText(name, LIMITS.name) })
    if not ok then
        error(('kayıt oluşturulamadı: %s'):format(tostring(row)))
    end

    -- Satırı tekrar okuyarak doğrula (ilk SELECT sessizce başarısız olduysa mevcut veri korunur)
    ok, row = Await(MySQL.single.await, SELECT_PLAYER, { identifier })
    if not ok or not row then
        error(('oyuncu satırı okunamadı: %s'):format(identifier))
    end
    return row
end

local function BuildSaveQueries(snapshots)
    local queries = {}
    for i = 1, #snapshots do
        local snap = snapshots[i]
        queries[i] = {
            query = UPSERT_PLAYER,
            values = {
                CleanText(snap.identifier, LIMITS.identifier),
                snap.level,
                snap.totalExp,
                snap.activeSeconds,
                snap.totalActiveSeconds,
                CleanText(snap.name, LIMITS.name),
            },
        }
    end
    return queries
end

--- Birden fazla oyuncuyu tek transaction ile kaydeder (bekler, zaman aşımlı).
---@return boolean ok
---@return 'timeout'|'error'|nil reason
function LoeExpDB.SavePlayersAwait(snapshots)
    if #snapshots == 0 then
        return true
    end

    local ok, result = Await(MySQL.transaction.await, BuildSaveQueries(snapshots))
    if ok and result == true then
        return true
    end

    if not ok and result == LoeExpDB.TIMEOUT then
        print(('^1[loe_exp] Kayıt zaman aşımına uğradı (%d oyuncu), veritabanı yanıt vermiyor.^0'):format(#snapshots))
        return false, 'timeout'
    end

    print(('^1[loe_exp] Kayıt başarısız (%d oyuncu): %s^0'):format(#snapshots, ok and 'transaction reddedildi' or tostring(result)))
    return false, 'error'
end

--- Kapanış anında kullanılır: sonucu beklemeden sorguyu oxmysql'e iletir.
function LoeExpDB.SavePlayersNoWait(snapshots)
    if #snapshots == 0 then
        return
    end
    MySQL.transaction(BuildSaveQueries(snapshots))
end

--- Log kaydı ekler (beklemez).
function LoeExpDB.InsertLog(entry)
    MySQL.insert(INSERT_LOG, {
        CleanText(entry.action, LIMITS.action),
        CleanText(entry.actorIdentifier, LIMITS.identifier),
        CleanText(entry.actorName, LIMITS.name),
        CleanText(entry.targetIdentifier, LIMITS.identifier),
        CleanText(entry.targetName, LIMITS.name),
        entry.amount or 0,
        entry.oldLevel or 0,
        entry.newLevel or 0,
        entry.oldExp or 0,
        entry.newExp or 0,
        CleanText(entry.note, LIMITS.note),
    })
end
