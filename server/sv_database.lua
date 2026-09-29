--[[
    loe_exp / server / database (oxmysql)

    - Tüm sorgular parametrelidir (?), kullanıcı verisi asla sorgu metnine eklenmez.
    - Kayıtlar toplu (tek transaction) yapılır; her saniye sorgu gönderilmez.
]]

LoeExpDB = {}

local SCHEMA_FILE = 'sql/loe_exp.sql'

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
            local ok, err = pcall(MySQL.query.await, statement)
            if not ok then
                success = false
                print(('^1[loe_exp] Tablo oluşturma hatası: %s^0'):format(err))
            end
        end
    end
    return success
end

--- Oyuncu verisini okur, kayıt yoksa oluşturur.
--- Okuma başarısız olursa hata fırlatır: böylece hatalı durumda oyuncuya sıfır veriyle
--- oturum açılıp gerçek verinin üzerine yazılması engellenir.
function LoeExpDB.FetchPlayer(identifier, name)
    local row = MySQL.single.await(SELECT_PLAYER, { identifier })
    if row then
        return row
    end

    MySQL.insert.await(INSERT_PLAYER, { identifier, name or '' })

    -- Satırı tekrar okuyarak doğrula (ilk SELECT sessizce başarısız olduysa mevcut veri korunur)
    row = MySQL.single.await(SELECT_PLAYER, { identifier })
    if not row then
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
                snap.identifier,
                snap.level,
                snap.totalExp,
                snap.activeSeconds,
                snap.totalActiveSeconds,
                snap.name or '',
            },
        }
    end
    return queries
end

--- Birden fazla oyuncuyu tek transaction ile kaydeder (bekler).
---@return boolean başarılı mı
function LoeExpDB.SavePlayersAwait(snapshots)
    if #snapshots == 0 then
        return true
    end
    local ok, result = pcall(MySQL.transaction.await, BuildSaveQueries(snapshots))
    if not ok then
        print(('^1[loe_exp] Kayıt hatası: %s^0'):format(result))
        return false
    end
    return result == true
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
        entry.action,
        entry.actorIdentifier or '',
        entry.actorName or '',
        entry.targetIdentifier or '',
        entry.targetName or '',
        entry.amount or 0,
        entry.oldLevel or 0,
        entry.newLevel or 0,
        entry.oldExp or 0,
        entry.newExp or 0,
        entry.note or '',
    })
end
