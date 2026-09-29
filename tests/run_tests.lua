--[[
    loe_exp / tests

    Çalıştırma (resource klasöründe):
        lua5.4 tests/run_tests.lua

    Sunucu kodu, tests/mock_fivem.lua içindeki sahte FiveM + oxmysql + Qbox + ox_lib ortamında
    uçtan uca çalıştırılır.
]]

local realPrint = print
package.path = './tests/?.lua;' .. package.path
local Mock = require('mock_fivem')
local MockClient = require('mock_client')

local tests = {}
local function test(name, fn)
    tests[#tests + 1] = { name = name, fn = fn }
end

local function eq(actual, expected, message)
    if actual ~= expected then
        error(('%s\n      beklenen: %s\n      gelen   : %s'):format(message or 'değerler eşit değil', tostring(expected), tostring(actual)), 2)
    end
end

local function truthy(value, message)
    if not value then
        error(message or 'koşul sağlanmadı', 2)
    end
end

local function Contains(list, text)
    for _, item in ipairs(list) do
        if item == text then
            return true
        end
    end
    return false
end

local function ContainsPattern(list, pattern)
    for _, item in ipairs(list) do
        if item:find(pattern) then
            return true
        end
    end
    return false
end

--- Hazır ortam: 1 numaralı oyuncu (citizenid CID1) karakterini seçmiş ve ilk aktivite bildirimi gönderilmiş.
local function Setup(opts)
    opts = opts or {}
    local env = Mock.new(opts)
    env:Boot()
    env:AddPlayer(1, opts.player)
    env:Heartbeat(1, 0)
    return env
end

------------------------------------------------------------------------
-- Formül ve denge
------------------------------------------------------------------------
test('Formül: örnek seviye geçişleri', function()
    Mock.new():Boot()
    local cases = {
        [1] = 1, [2] = 2, [3] = 3, [4] = 5, [9] = 14, [19] = 32, [29] = 51,
        [49] = 87, [59] = 105, [69] = 123, [79] = 141, [89] = 159, [99] = 177,
    }
    for level, xp in pairs(cases) do
        eq(LoeLevel.GetRequiredXP(level), xp, ('%d -> %d geçişi'):format(level, level + 1))
    end
end)

test('Formül: toplam ilerleme hedefleri (100. seviye = 8.760 EXP = 365 gün)', function()
    Mock.new():Boot()
    local targets = {
        [10] = 65, [20] = 308, [30] = 732, [40] = 1337, [50] = 2122,
        [60] = 3088, [70] = 4235, [80] = 5562, [90] = 7071, [100] = 8760,
    }
    for level, total in pairs(targets) do
        eq(LoeLevel.GetTotalExpForLevel(level), total, level .. '. seviye toplamı')
    end
    eq(LoeLevel.GetMaxTotalExp(), 8760)
    eq(LoeLevel.GetMaxTotalExp() / 24, 365.0, 'gün karşılığı')
end)

test('Seviye hesaplama: sınırlar, döngü ve geçersiz girdiler', function()
    Mock.new():Boot()
    eq(LoeLevel.CalculateLevel(0), 1)
    eq(LoeLevel.CalculateLevel(64), 9)
    eq(LoeLevel.CalculateLevel(65), 10)
    eq(select(2, LoeLevel.CalculateLevel(66)), 1, '10. seviyede biriken EXP')
    eq(LoeLevel.CalculateLevel(8759), 99)
    eq(LoeLevel.CalculateLevel(8760), 100)
    eq(LoeLevel.CalculateLevel(999999), 100)
    eq(LoeLevel.CalculateLevel(-5), 1)
    eq(LoeLevel.CalculateLevel(0 / 0), 1)
    eq(LoeLevel.CalculateLevel('abc'), 1)
    for level = 1, 100 do
        eq(LoeLevel.CalculateLevel(LoeLevel.GetTotalExpForLevel(level)), level, 'eşik ' .. level)
    end
    for level = 2, 100 do
        eq(LoeLevel.CalculateLevel(LoeLevel.GetTotalExpForLevel(level) - 1), level - 1, 'eşik altı ' .. level)
    end
end)

------------------------------------------------------------------------
-- Aktif süre ve EXP
------------------------------------------------------------------------
test('60 aktif dakika = 1 EXP, Türkçe seviye bildirimi, anında kayıt', function()
    local env = Setup()
    env:PlayActive(1, 59 * 60)
    eq(env:Export('GetTotalExp', 1), 0, '59 dk sonra EXP')
    env:PlayActive(1, 60)
    eq(env:Export('GetTotalExp', 1), 1)
    eq(env:Export('GetLevel', 1), 2)
    truthy(Contains(env:Notifications(1), 'Tebrikler! 2. seviyeye ulaştın.'), 'seviye bildirimi')
    eq(env.db.players['CID1'].total_exp, 1, 'EXP veritabanına anında yazılmalı')
    eq(env.db.players['CID1'].level, 2)
end)

test('Tam simülasyon: 8.759 aktif saatte 99, 8.760 aktif saatte 100. seviye', function()
    local env = Setup()
    local session = LoeExp.GetSession(1)
    -- 10 dakikalık adımlarla (AFK sınırında) aktif oyun
    local steps = 8759 * 6
    for _ = 1, steps do
        env:Advance(600)
        env:Move(1)
        env:Heartbeat(1, 0)
    end
    eq(session.level, 99, '8.759 saat')
    eq(session.totalExp, 8759)
    for _ = 1, 6 do
        env:Advance(600)
        env:Move(1)
        env:Heartbeat(1, 0)
    end
    eq(session.level, 100, '8.760 saat')
    eq(session.totalExp, 8760)
end)

test('AFK geçen süre sayılmaz, dönüşte bilgi verilir', function()
    local env = Setup()
    local session = LoeExp.GetSession(1)
    local idle = 0
    for _ = 1, 240 do -- 2 saat hiç hareket yok
        env:Advance(30)
        idle = idle + 30
        env:Heartbeat(1, idle)
    end
    eq(session.activeSeconds, 0)
    eq(session.totalExp, 0)
    eq(env:Export('IsPlayerAfk', 1), true)

    env:Advance(30)
    env:Move(1)
    env:Heartbeat(1, 0)
    eq(session.activeSeconds, 0, 'AFK boşluğu sayılmamalı')
    eq(env:Export('IsPlayerAfk', 1), false)
    truthy(ContainsPattern(env:Notifications(1), 'yaklaşık 120 dakika aktif oyun süresine sayılmadı'), 'AFK dönüş bildirimi')

    env:PlayActive(1, 600)
    eq(session.activeSeconds, 600, 'dönüşten sonra süre sayılmalı')
end)

test('AFK süresinden kısa duraklamalar aktif sayılır', function()
    local env = Setup()
    local session = LoeExp.GetSession(1)
    for i = 1, 10 do -- 5 dk kıpırdamadan dinler
        env:Advance(30)
        env:Heartbeat(1, i * 30)
    end
    eq(session.activeSeconds, 0, 'duraklama henüz kesinleşmedi')
    env:Advance(30)
    env:Move(1)
    env:Heartbeat(1, 0)
    eq(session.activeSeconds, 330)
end)

test('Oyundan çıkıp girmek süreyi sıfırlamaz, çevrimdışı süre sayılmaz', function()
    local env = Setup()
    env:PlayActive(1, 45 * 60)
    env:Drop(1)
    eq(LoeExp.GetSession(1), nil)
    eq(env.db.players['CID1'].active_seconds, 2700, 'çıkışta kaydedildi')

    env:Advance(3 * 3600)
    env:AddPlayer(2, { citizenid = 'CID1' }) -- aynı karakterle farklı sunucu ID ile geri döner
    env:Heartbeat(2, 0)
    local session = LoeExp.GetSession(2)
    eq(session.activeSeconds, 2700)
    eq(session.totalExp, 0)

    env:PlayActive(2, 15 * 60)
    eq(session.totalExp, 1)
    eq(session.activeSeconds, 0)
end)

test('Resource yeniden başlatılınca ilerleme kaldığı yerden devam eder', function()
    local env = Setup()
    env:PlayActive(1, 20 * 60)
    env:StopResource()
    eq(env.db.players['CID1'].active_seconds, 1200, 'kapanış kaydı')

    local env2 = Mock.new({ db = env.db })
    env2.players[1] = env.players[1] -- oyuncu sunucuda kalır
    env2:Boot()
    local session = LoeExp.GetSession(1)
    truthy(session, 'içerideki oyuncu yeniden yüklenmeli')
    eq(session.activeSeconds, 1200)
    eq(#env2:ClientEventsFor(1, 'loe_exp:client:sync'), 1, 'istemciye veri gönderildi')

    env2:Heartbeat(1, 0)
    env2:PlayActive(1, 40 * 60)
    eq(session.totalExp, 1)
end)

test('Ani çökmede en fazla bir otomatik kayıt aralığı kadar süre kaybolur', function()
    local env = Setup()
    env:PlayActive(1, 12 * 60)
    local saved = env.db.players['CID1'].active_seconds
    truthy(saved >= 12 * 60 - 5 * 60, 'kaydedilen aktif süre: ' .. saved)
end)

test('Otomatik kayıt değişen oyuncuları tek transaction ile toplu yazar', function()
    local env = Setup()
    env:AddPlayer(2)
    env:AddPlayer(3)
    env:Heartbeat(2, 0)
    env:Heartbeat(3, 0)
    local before = env.db.transactions or 0
    local writesBefore = env.db.writes
    for _ = 1, 10 do -- 5 dk
        env:Advance(30)
        for src = 1, 3 do
            env:Move(src)
            env:Heartbeat(src, 0)
        end
    end
    eq((env.db.transactions or 0) - before, 1, 'tek toplu kayıt')
    eq(env.db.writes - writesBefore, 3, '3 oyuncu yazıldı')
end)

test('Maksimum seviyede EXP ve aktif süre sayacı durur', function()
    local env = Setup()
    eq(env:Export('SetExp', 1, 8759), true)
    eq(env:Export('GetLevel', 1), 99)
    env:PlayActive(1, 3600)
    eq(env:Export('GetLevel', 1), 100)
    eq(env:Export('GetTotalExp', 1), 8760)
    truthy(Contains(env:Notifications(1), 'Tebrikler! 100. seviyeye ulaştın.'))

    env:PlayActive(1, 2 * 3600)
    local session = LoeExp.GetSession(1)
    eq(session.totalExp, 8760)
    eq(session.activeSeconds, 0)
    truthy(session.totalActiveSeconds >= 3 * 3600, 'istatistik süre tutulmaya devam eder')

    local ok, err = env:Export('AddExp', 1, 5)
    eq(ok, false)
    eq(err, 'max_level')
    eq(env:Export('GetPlayerData', 1).isMaxLevel, true)
    eq(env.db.players['CID1'].level, 100)
    eq(env.db.players['CID1'].total_exp, 8760)
end)

test('Tek seferde birden fazla seviye döngüyle hesaplanır, EXP çıkarma seviyeyi düşürür', function()
    local env = Setup()
    local ok, level, total = env:Export('AddExp', 1, 2122, 'test')
    eq(ok, true)
    eq(level, 50)
    eq(total, 2122)
    local notes = env:Notifications(1)
    eq(notes[#notes], 'Tebrikler! 50. seviyeye ulaştın.')
    truthy(not Contains(notes, 'Tebrikler! 49. seviyeye ulaştın.'), 'yalnızca son seviye bildirilir')

    ok, level = env:Export('RemoveExp', 1, 2122 - 65)
    eq(level, 10)
    truthy(Contains(env:Notifications(1), 'Seviyen 10 olarak güncellendi.'))

    env:Export('RemoveExp', 1, 5000)
    eq(env:Export('GetTotalExp', 1), 0, '0 altına inmez')
    eq(env:Export('GetLevel', 1), 1)
    local ok2, err = env:Export('RemoveExp', 1, 1)
    eq(ok2, false)
    eq(err, 'no_exp')
end)

test('25. seviye bildirimi istenen metinle gösterilir', function()
    local env = Setup()
    env:Export('AddExp', 1, LoeLevel.GetTotalExpForLevel(25))
    truthy(Contains(env:Notifications(1), 'Tebrikler! 25. seviyeye ulaştın.'))
end)

------------------------------------------------------------------------
-- Güvenlik
------------------------------------------------------------------------
test('İstemci EXP / seviye belirleyemez: yalnızca iki ağ olayı açık', function()
    local env = Setup()
    local names = {}
    for name in pairs(env.netEvents) do
        names[#names + 1] = name
    end
    table.sort(names)
    eq(table.concat(names, ','), 'loe_exp:server:activity,loe_exp:server:requestSync')
    eq(env:ClientEvent(1, 'loe_exp:server:addExp', 1, 500), false)
    eq(env:ClientEvent(1, 'loe_exp:server:setExp', 1, 8760), false)
    eq(env:Export('GetTotalExp', 1), 0)
end)

test('Sahte / hatalı aktivite bildirimleri gerçek zamanı aşamaz ve çökertmez', function()
    local env = Setup()
    local session = LoeExp.GetSession(1)
    for _ = 1, 600 do -- 10 dk boyunca saniyede bir "aktifim"
        env:Advance(1)
        env:Move(1)
        env:Heartbeat(1, 0)
    end
    truthy(session.activeSeconds <= 600, 'gerçek zamandan fazla: ' .. session.activeSeconds)
    truthy(session.activeSeconds >= 540, 'geçerli süre sayılmalı: ' .. session.activeSeconds)

    -- Aynı saniyede yoğun spam: yok sayılır ve şüpheli olarak konsola yazılır
    local lastBeat = session.lastHeartbeat
    env:Advance(1)
    for _ = 1, 25 do
        env:Heartbeat(1, 0)
    end
    eq(session.lastHeartbeat, lastBeat, 'hız sınırı içindeki bildirimler işlenmez')
    truthy(ContainsPattern(env.logs, 'Şüpheli'), 'spam uyarısı loglanmalı')

    local before = session.activeSeconds
    for _, bad in ipairs({ 'abc', -5, 0 / 0, math.huge, -math.huge, 1e308, {}, true }) do
        env:Advance(30)
        env:Heartbeat(1, bad)
    end
    eq(session.activeSeconds, before, 'geçersiz yük süre eklememeli')
    eq(session.totalExp, 0)
end)

test('Sunucu taraflı hareketsizlik kontrolü sahte "aktifim" bildirimini durdurur', function()
    local env = Setup()
    local session = LoeExp.GetSession(1)
    for _ = 1, 120 do -- 60 dk: istemci idle = 0 der ama karakter hiç hareket etmez
        env:Advance(30)
        env:Heartbeat(1, 0)
    end
    truthy(session.activeSeconds <= 10 * 60, 'sayılan: ' .. session.activeSeconds)
    truthy(session.activeSeconds >= 9 * 60, 'sayılan: ' .. session.activeSeconds)
    eq(session.totalExp, 0)

    -- OneSync yoksa kontrol atlanır
    local env2 = Mock.new()
    env2.oneSync = false
    env2:Boot()
    env2:AddPlayer(1)
    env2:Heartbeat(1, 0)
    for _ = 1, 120 do
        env2:Advance(30)
        env2:Heartbeat(1, 0)
    end
    eq(env2:Export('GetTotalExp', 1), 1)
end)

------------------------------------------------------------------------
-- Yetkili komutları
------------------------------------------------------------------------
test('Yetkili komutları: yetki, doğrulama ve loglama', function()
    local env = Setup()
    env:AddPlayer(2, { firstname = 'Yetkili', lastname = 'Admin', groups = { ['group.admin'] = true } })

    eq(env:Command(1, 'expekle', { '1', '100' }), false, 'group.admin olmayan komutu çalıştıramaz')
    eq(env:Command(1, 'expayarla', { '1', '8760' }), false)
    eq(env:Command(1, 'seviyebak', { '2' }), false)
    eq(env:Export('GetTotalExp', 1), 0, 'yetkisiz oyuncu EXP ekleyemez')

    env:Command(2, 'expekle', { '1', '65' })
    eq(env:Export('GetLevel', 1), 10)
    env:Command(2, 'expayarla', { '1', '308' })
    eq(env:Export('GetLevel', 1), 20)
    env:Command(2, 'expsil', { '1', '8' })
    eq(env:Export('GetTotalExp', 1), 300)
    env:Command(2, 'seviyebak', { '1' })
    truthy(ContainsPattern(env:Notifications(2), '^%[1%] Oyuncu1 Test | Seviye: 19 | Toplam EXP: 300'), 'görüntüleme çıktısı')

    for _, args in ipairs({ { '1', '12.5' }, { '1', '-3' }, { '1', 'abc' }, { '1', '99999' }, { '99', '10' }, {} }) do
        env:Command(2, 'expekle', args)
    end
    eq(env:Export('GetTotalExp', 1), 300, 'geçersiz girdiler uygulanmaz')

    env:Command(0, 'expekle', { '1', '8' })
    eq(env:Export('GetTotalExp', 1), 308, 'konsol kullanabilir')

    local actions = {}
    for _, log in ipairs(env.db.logs) do
        actions[#actions + 1] = log.action
    end
    eq(table.concat(actions, ','), 'add,set,remove,view,add')
    local first = env.db.logs[1]
    eq(first.actor_identifier, 'license:2')
    eq(first.actor_name, 'Yetkili Admin')
    eq(first.target_identifier, 'CID1')
    eq(first.target_name, 'Oyuncu1 Test')
    eq(first.amount, 65)
    eq(first.old_level, 1)
    eq(first.new_level, 10)
    eq(env.db.logs[5].actor_identifier, 'console')
end)

test('/seviyem oyuncuya kendi ilerlemesini gösterir', function()
    local env = Setup()
    env:Export('AddExp', 1, 70)
    env:PlayActive(1, 25 * 60)
    env:Command(1, 'seviyem', {})
    local notes = env:Notifications(1)
    eq(notes[#notes], 'Seviye: 10 | Toplam EXP: 70 | Sonraki seviye: 5/16 EXP | Sonraki EXP: 25/60 aktif dk')
end)

------------------------------------------------------------------------
-- Export / event API
------------------------------------------------------------------------
test('Export ve sunucu içi olaylar', function()
    local env = Setup()
    local levelEvents, expEvents = {}, {}
    AddEventHandler('loe_exp:onLevelChanged', function(src, new, old)
        levelEvents[#levelEvents + 1] = { src, new, old }
    end)
    AddEventHandler('loe_exp:onExpChanged', function(src, total, delta, reason)
        expEvents[#expEvents + 1] = { src, total, delta, reason }
    end)

    local result
    TriggerEvent('loe_exp:server:addExp', 1, 11, 'gorev', function(ok, level, total)
        result = { ok, level, total }
    end)
    eq(result[1], true)
    eq(result[2], 5)
    eq(result[3], 11)
    eq(levelEvents[1][2], 5)
    eq(levelEvents[1][3], 1)
    eq(expEvents[1][3], 11)
    eq(expEvents[1][4], 'gorev')

    TriggerEvent('loe_exp:server:getLevel', 1, function(level) result = level end)
    eq(result, 5)
    TriggerEvent('loe_exp:server:getTotalExp', 1, function(total) result = total end)
    eq(result, 11)
    TriggerEvent('loe_exp:server:setExp', 1, 65, nil, function(_, level) result = level end)
    eq(result, 10)
    TriggerEvent('loe_exp:server:removeExp', 1, 1, nil, function(_, level) result = level end)
    eq(result, 9)

    LoeExp.GetSession(1).level = 77 -- bozulmuş seviye
    local _, level = env:Export('RecalculateLevel', 1)
    eq(level, 9, 'seviye yeniden hesaplandı')
    TriggerEvent('loe_exp:server:recalculateLevel', 1, function(_, lvl) result = lvl end)
    eq(result, 9)

    local ok, err = env:Export('AddExp', 99, 5)
    eq(ok, false)
    eq(err, 'not_loaded')
    eq(env:Export('GetLevel', 99), nil)

    for _, bad in ipairs({ 0, -1, 1.5, 'x', 0 / 0, 9000 }) do
        local okBad, errBad = env:Export('AddExp', 1, bad)
        eq(okBad, false)
        eq(errBad, 'invalid_amount')
    end

    eq(env:Export('GetRequiredXP', 99), 177)
    eq(env:Export('GetTotalExpForLevel', 50), 2122)
    eq(env:Export('GetMaxLevel'), 100)
    eq(env:Export('GetPlayerData', 1).requiredExp, 14)
end)

test('Export değişiklikleri istenirse çağıran resource adıyla loglanır', function()
    local env = Setup({ configure = function(c) c.Logging.ExportChanges = true end })
    env.invoker = 'loe_jobs'
    env:Export('AddExp', 1, 3, 'görev ödülü')
    local log = env.db.logs[#env.db.logs]
    eq(log.action, 'export_add')
    eq(log.actor_identifier, 'resource:loe_jobs')
    eq(log.note, 'görev ödülü')
end)

------------------------------------------------------------------------
-- Veritabanı dayanıklılığı
------------------------------------------------------------------------
test('Açılışta SQL dosyasından iki tablo oluşturulur', function()
    local env = Mock.new()
    env:Boot()
    eq(env.db.schemaRuns, 2)
end)

test('Veritabanındaki tutarsız seviye yüklemede düzeltilir', function()
    local db = Mock.NewDatabase()
    db.players['CID1'] = {
        identifier = 'CID1', level = 50, total_exp = 65, active_seconds = 100,
        total_active_seconds = 0, last_name = '',
    }
    local env = Mock.new({ db = db })
    env:Boot()
    env:AddPlayer(1)
    eq(env:Export('GetLevel', 1), 10)
    eq(db.players['CID1'].level, 10, 'düzeltilmiş seviye kaydedildi')
end)

test('Yüklemede veritabanı hatası: veri sıfırlanmaz, sonra yeniden denenir', function()
    local db = Mock.NewDatabase()
    db.players['CID1'] = {
        identifier = 'CID1', level = 10, total_exp = 65, active_seconds = 1000,
        total_active_seconds = 500000, last_name = 'X',
    }
    local env = Mock.new({ db = db })
    env:Boot()
    env.dbFail = true
    env:AddPlayer(1)
    eq(LoeExp.GetSession(1), nil, 'hatalı yüklemede oturum açılmaz')
    env.dbFail = false
    eq(db.players['CID1'].total_exp, 65, 'mevcut veri korunmalı')

    env:Advance(10)
    env:ClientEvent(1, 'loe_exp:server:requestSync')
    local session = LoeExp.GetSession(1)
    truthy(session, 'yeniden deneme ile yüklenmeli')
    eq(session.totalExp, 65)
    eq(session.level, 10)
    eq(session.activeSeconds, 1000)
end)

test('Çıkışta kayıt başarısızsa veri bellekte tutulur ve tekrar denenir', function()
    local env = Setup()
    env:PlayActive(1, 30 * 60)
    env.dbFail = true
    env:Drop(1)
    truthy(LoeExp.Pending['CID1'], 'bekleyen kayıt')

    env:AddPlayer(3, { citizenid = 'CID1' }) -- veritabanı hâlâ çalışmıyorken geri döner
    local session = LoeExp.GetSession(3)
    truthy(session, 'bellekteki veriyle yüklenmeli')
    eq(session.activeSeconds, 1800)

    env.dbFail = false
    env:Heartbeat(3, 0)
    env:Advance(301)
    eq(env.db.players['CID1'].active_seconds, 1800)
    eq(LoeExp.Pending['CID1'], nil)
end)

test('Qbox karakter değiştirme: oturum kaydedilir, her karakter ayrı seviyelenir', function()
    local env = Setup()
    env:PlayActive(1, 10 * 60)
    env:Export('AddExp', 1, 65)
    env:Logout(1)
    eq(LoeExp.GetSession(1), nil, 'karakterden çıkınca oturum kapanır')
    eq(env.db.players['CID1'].active_seconds, 600)
    eq(#env:ClientEventsFor(1, 'loe_exp:client:unloaded'), 1)

    -- Karakter seçim ekranında süre yazılmaz, yükleme denenmez
    env:Advance(30)
    env:ClientEvent(1, 'loe_exp:server:requestSync')
    eq(LoeExp.GetSession(1), nil)

    -- İkinci karakter kendi seviyesiyle başlar
    env:Login(1, { citizenid = 'CID9' })
    eq(env:Export('GetLevel', 1), 1)
    eq(env:Export('GetTotalExp', 1), 0)

    -- İlk karaktere dönünce ilerlemesi yerindedir
    env:Logout(1)
    env:Login(1, { citizenid = 'CID1' })
    eq(env:Export('GetLevel', 1), 10)
    eq(LoeExp.GetSession(1).activeSeconds, 600)
end)

test('Qbox metadata: seviye ve EXP metadata.level / metadata.exp alanına yazılır', function()
    local env = Setup()
    local player = env.players[1]
    eq(player.metadata.level, 1, 'yüklemede yazılır')
    eq(player.metadata.exp, 0)

    env:Export('AddExp', 1, 65)
    eq(player.metadata.level, 10)
    eq(player.metadata.exp, 65)

    -- Değişmeyen değer tekrar yazılmaz; aktif süre metadata'ya hiç yazılmaz
    local writes = player.metaWrites
    env:PlayActive(1, 30 * 60)
    eq(player.metaWrites, writes, 'aktif süre metadata yazmaz')
    env:Export('AddExp', 1, 1)
    eq(player.metaWrites, writes + 1, 'yalnızca exp değişti')
    eq(player.metadata.exp, 66)

    local env2 = Setup({ configure = function(c) c.Metadata.Enabled = false end })
    env2:Export('AddExp', 1, 65)
    eq(env2.players[1].metaWrites, 0, 'kapalıyken metadata yazılmaz')
end)

test('Yetkili komutları group.admin ile kısıtlı, /seviyem herkese açık', function()
    local env = Setup()
    for _, name in ipairs({ 'seviyebak', 'expekle', 'expsil', 'expayarla' }) do
        eq(env.commands[name].restricted, 'group.admin', name)
    end
    eq(env.commands['seviyem'].restricted, nil)
end)

------------------------------------------------------------------------
-- Test raporundaki sorunların regresyon testleri
------------------------------------------------------------------------
test('Veritabanı yanıt vermezse kayıt kilitlenmez; bağlantı dönünce veri yazılır', function()
    local env = Setup()
    env:AddPlayer(2)
    env:Heartbeat(2, 0)
    env:PlayActive(1, 60)

    env.dbHang = true -- oxmysql bağlantı kuramıyor: await hiç dönmez
    for _ = 1, 12 do -- 6 dk: otomatik kayıt asılı veritabanına denk gelir
        env:Advance(30)
        env:Move(1)
        env:Heartbeat(1, 0)
    end
    eq(LoeExp.GetSession(1).saving, false, 'zaman aşımından sonra kayıt kilidi açılmalı')
    truthy(ContainsPattern(env.logs, 'zaman aşımına uğradı'), 'zaman aşımı loglanmalı')

    env:Drop(2) -- kesinti sırasında çıkan oyuncu
    env:AddPlayer(3) -- kesinti sırasında giren oyuncu: yükleme zaman aşımına uğrar
    env:Advance(31)
    eq(LoeExp.GetSession(3), nil)

    env.dbHang = false
    for _ = 1, 20 do -- 10 dk
        env:Advance(30)
        env:Move(1)
        env:Heartbeat(1, 0)
    end
    local saved = env.db.players['CID1'].active_seconds
    truthy(saved >= 12 * 60, 'kesinti sonrası kaydedilen aktif süre: ' .. saved)
    eq(LoeExp.Pending['CID2'], nil, 'kesintide çıkan oyuncunun kaydı sonradan yazılmalı')

    env:ClientEvent(3, 'loe_exp:server:requestSync')
    env:Advance(1)
    truthy(LoeExp.GetSession(3), 'veritabanı dönünce yükleme yeniden denenmeli')
end)

test('Uzun karakter adı kırpılır, diğer oyuncuların toplu kaydını bozmaz', function()
    local env = Setup()
    env:AddPlayer(2, { firstname = string.rep('Ş', 120) })
    env:Heartbeat(2, 0)
    for _ = 1, 12 do
        env:Advance(30)
        for src = 1, 2 do
            env:Move(src)
            env:Heartbeat(src, 0)
        end
    end
    truthy(env.db.players['CID1'].active_seconds > 0, 'oyuncu 1 kaydedilmeli')
    truthy(env.db.players['CID2'].active_seconds > 0, 'uzun isimli oyuncu da kaydedilmeli')
    eq(utf8.len(env.db.players['CID2'].last_name), 100, 'isim sütun uzunluğuna kırpılmalı')
end)

test('Toplu kayıt reddedilirse oyuncular tek tek kaydedilir, bozuk satır diğerlerini engellemez', function()
    local env = Setup()
    env:AddPlayer(2)
    env:AddPlayer(3)
    env:Heartbeat(2, 0)
    env:Heartbeat(3, 0)
    env.failIdentifiers['CID2'] = true
    local function Play(steps)
        for _ = 1, steps do
            env:Advance(30)
            for src = 1, 3 do
                env:Move(src)
                env:Heartbeat(src, 0)
            end
        end
    end
    Play(12)
    truthy(env.db.players['CID1'].active_seconds > 0, 'oyuncu 1 kaydedilmeli')
    truthy(env.db.players['CID3'].active_seconds > 0, 'oyuncu 3 kaydedilmeli')
    eq(env.db.players['CID2'].active_seconds, 0, 'reddedilen satır yazılmaz')
    eq(LoeExp.GetSession(2).dirty, true, 'reddedilen oyuncu sonraki kayıtta tekrar denenir')

    env.failIdentifiers['CID2'] = nil
    Play(10)
    truthy(env.db.players['CID2'].active_seconds > 0, 'sorun giderilince kaydedilmeli')
end)

test('Uzun not (reason) kırpılır, log kaybolmaz', function()
    local env = Setup({ configure = function(c) c.Logging.ExportChanges = true end })
    env.invoker = 'loe_jobs'
    env:Export('AddExp', 1, 1, string.rep('ğ', 300))
    local log = env.db.logs[#env.db.logs]
    truthy(log, 'log yazılmalı')
    eq(utf8.len(log.note), 255)
    eq(env.lostQueries, 0)
end)

test('Config.MaxLevel düşürülse de EXP ve süre silinmez, ayar geri alınınca seviye geri gelir', function()
    local db = Mock.NewDatabase()
    db.players['CID1'] = {
        identifier = 'CID1', level = 80, total_exp = 5562, active_seconds = 1800,
        total_active_seconds = 0, last_name = '',
    }
    local env = Mock.new({ db = db, configure = function(c) c.MaxLevel = 50 end })
    env:Boot()
    env:AddPlayer(1)
    env:Heartbeat(1, 0)
    eq(env:Export('GetLevel', 1), 50, 'maksimum seviyede görünür')
    eq(db.players['CID1'].total_exp, 5562, 'toplam EXP veritabanında korunur')

    env:PlayActive(1, 3600)
    eq(env:Export('GetTotalExp', 1), 5562, 'maksimum seviyede EXP kazanmaz')
    local _, err = env:Export('AddExp', 1, 5)
    eq(err, 'max_level')
    env:Export('RemoveExp', 1, 2)
    eq(env:Export('GetTotalExp', 1), 5560, 'çıkarma fazlayı silmez, yalnızca istenen kadar azaltır')
    env:Drop(1)

    local env2 = Mock.new({ db = db })
    env2:Boot()
    env2:AddPlayer(1)
    eq(env2:Export('GetLevel', 1), 79, 'MaxLevel 100 olunca gerçek seviye')
    eq(LoeExp.GetSession(1).activeSeconds, 1800, 'biriken aktif süre de korunur')
end)

test('Sınıra takılan yetkili işleminde gerçek miktar gösterilir ve loglanır', function()
    local env = Setup()
    env:AddPlayer(2, { groups = { ['group.admin'] = true } })
    env:Export('SetExp', 1, 8750)

    env:Command(2, 'expekle', { '1', '500' })
    local notes = env:Notifications(2)
    eq(notes[#notes], '[1] Oyuncu1 Test oyuncusuna 10 EXP eklendi. Seviye: 99 -> 100 (Toplam: 8760 EXP) (istenen: 500 EXP, sınır nedeniyle 10 EXP uygulandı)')
    local log = env.db.logs[#env.db.logs]
    eq(log.amount, 10)
    eq(log.note, 'istenen: 500')

    env:Command(2, 'expsil', { '1', '8000' })
    log = env.db.logs[#env.db.logs]
    eq(log.amount, -8000, 'çıkarma işaretli loglanır')
    eq(log.note, '')

    env:Command(2, 'expsil', { '1', '8000' }) -- 760 EXP kaldı
    notes = env:Notifications(2)
    truthy(notes[#notes]:find('oyuncusundan 760 EXP çıkarıldı', 1, true), notes[#notes])
    eq(env.db.logs[#env.db.logs].amount, -760)
end)

test('Her ulaşılan seviye için onLevelReached ayrı tetiklenir', function()
    local env = Setup()
    local reached = {}
    AddEventHandler('loe_exp:onLevelReached', function(src, level)
        reached[#reached + 1] = src .. ':' .. level
    end)
    env:Export('AddExp', 1, 65)
    eq(table.concat(reached, ','), '1:2,1:3,1:4,1:5,1:6,1:7,1:8,1:9,1:10')
    env:Export('RemoveExp', 1, 10)
    eq(#reached, 9, 'seviye düşüşünde tetiklenmez')
    env:Export('AddExp', 1, 10)
    eq(reached[#reached], '1:10', 'yeniden ulaşılınca tekrar tetiklenir')
end)

test('GetRequiredXP export geçersiz girdide hata fırlatmaz', function()
    local env = Setup()
    for _, bad in ipairs({ 'nil', 'abc', 0, -3, 1.5 }) do
        eq(env:Export('GetRequiredXP', bad ~= 'nil' and bad or nil), nil, tostring(bad))
    end
    eq(env:Export('GetRequiredXP', 99), 177)
    eq(env:Export('GetRequiredXP', '9'), 14)
end)

test('ox_lib bildirimi güncel tip adıyla gider, konum oyuncu ayarına bırakılır', function()
    local env = Setup()
    env:PlayActive(1, 3600)
    env:Command(1, 'seviyem', {})
    local events = env:ClientEventsFor(1, 'ox_lib:notify')
    truthy(#events >= 2)
    local valid = { success = true, error = true, info = true, warning = true }
    for _, event in ipairs(events) do
        truthy(valid[event.args[1].type], 'geçersiz tip: ' .. tostring(event.args[1].type))
        eq(event.args[1].position, nil)
    end
end)

test('Qbox oyuncu nesnesi az kopyalanır, metadata yalnızca değişince yazılır', function()
    local env = Mock.new()
    env:Boot()
    local before = env.getPlayerCalls
    env:AddPlayer(1)
    truthy(env.getPlayerCalls - before <= 2, 'girişte GetPlayer çağrısı: ' .. (env.getPlayerCalls - before))

    local calls = env.getPlayerCalls
    env:Heartbeat(1, 0)
    env:PlayActive(1, 3600)
    eq(env.getPlayerCalls, calls, 'EXP kazanımında oyuncu nesnesi kopyalanmaz')
    eq(env.players[1].metadata.exp, 1)

    -- Metadata zaten güncelse yeniden girişte yazılmaz
    env:Logout(1)
    local writes = env.players[1].metaWrites
    env:Login(1, { metadata = { level = 2, exp = 1 } })
    eq(env.players[1].metaWrites, writes)
end)

------------------------------------------------------------------------
-- İstemci (client/cl_main.lua)
------------------------------------------------------------------------
local vec = MockClient.vec

test('İstemci: karakter seçilmeden veri istemez, girişte 10 sn aralıkla ister', function()
    local client = MockClient.new()
    client:Advance(30000)
    eq(#client:Events('loe_exp:server:requestSync'), 0)
    LocalPlayer.state.isLoggedIn = true
    client:Advance(25000)
    local count = #client:Events('loe_exp:server:requestSync')
    truthy(count >= 2 and count <= 3, count .. ' istek')
end)

test('İstemci: ilk bildirim hemen, sonra 30 sn aralıkla gider; karakterden çıkınca durur', function()
    local client = MockClient.new()
    client:Sync()
    local beats = client:Events('loe_exp:server:activity')
    eq(#beats, 1)
    eq(beats[1].args[1], 0)
    client:Advance(95000)
    beats = client:Events('loe_exp:server:activity')
    for i = 2, #beats do
        local gap = beats[i].at - beats[i - 1].at
        truthy(gap >= 30000 and gap <= 31000, 'aralık ' .. gap)
    end
    client:Unload()
    local count = #client:Events('loe_exp:server:activity')
    client:Advance(60000)
    eq(#client:Events('loe_exp:server:activity'), count)
end)

test('İstemci: yeniden girişte ikinci bildirim sunucu hız sınırına takılmaz', function()
    local client = MockClient.new()
    client:Sync()
    client:Advance(25000)
    client:Unload()
    client:Sync()
    local first = #client:Events('loe_exp:server:activity')
    client:Advance(40000)
    local beats = client:Events('loe_exp:server:activity')
    truthy(beats[first + 1].at - beats[first].at >= 30000, 'yeniden girişten sonraki aralık')
end)

test('İstemci: kamera, yürüme, konuşma ve tuş aktivite sayılır; hareketsizlikte boşta süre artar', function()
    local client = MockClient.new()
    client:Sync()
    client:Advance(90000)
    truthy(client:LastIdle() >= 55, 'boşta süre artmalı: ' .. client:LastIdle())

    client.state.cam = vec(0, 0, 25)
    client:Advance(30000)
    truthy(client:LastIdle() <= 30, 'kamera: ' .. client:LastIdle())

    client:Advance(60000)
    client.state.talking = true
    client:Advance(30000)
    client.state.talking = false
    truthy(client:LastIdle() <= 1, 'konuşma: ' .. client:LastIdle())

    client:Advance(60000)
    client.state.coords = vec(3, 0, 0)
    client:Advance(30000)
    truthy(client:LastIdle() <= 30, 'yürüme: ' .. client:LastIdle())

    client:Advance(60000)
    client.state.pressed[38] = true -- E
    client:Advance(30000)
    client.state.pressed[38] = nil
    truthy(client:LastIdle() <= 1, 'tuş: ' .. client:LastIdle())
end)

test('İstemci: GTA boşta kamerası dönerken aktivite sayılmaz', function()
    local client = MockClient.new()
    client:Sync()
    client.state.idleCam = true
    client:Simulate(90, function(i) client.state.cam = vec(0, 0, i * 4) end)
    truthy(client:LastIdle() >= 55, 'idle=' .. client:LastIdle())
end)

test('İstemci: AFK araç yolcusu dönen takip kamerasıyla aktif sayılmaz; sürücü sayılır', function()
    local function Ride(seat, configure)
        local client = MockClient.new({ configure = configure })
        client:Sync()
        cache.vehicle, cache.seat = 5, seat
        client:Simulate(180, function(i)
            client.state.coords = vec(i * 10, 0, 0)
            client.state.cam = vec(0, 0, (i * 3) % 360) -- kamera aracın yönüyle döner
        end)
        cache.vehicle, cache.seat = false, false
        return client:LastIdle()
    end
    truthy(Ride(0) >= 150, 'AFK yolcu boşta sayılmalı')
    truthy(Ride(-1) <= 1, 'sürücü aktif sayılmalı')
    truthy(Ride(0, function(c) c.Afk.PassengerCamera = true end) <= 1, 'PassengerCamera açıkken yolcu kamerası sayılır')
end)

test('İstemci: telefon / envanter ekranında imleç hareketi aktivite sayılır', function()
    local client = MockClient.new()
    client:Sync()
    client.state.nuiFocus = true
    client:Simulate(12 * 60, function(i)
        if i % 20 == 0 then client.state.cursor = { 500 + i, 400 } end
    end)
    truthy(client:LastIdle() <= 30, 'imleç hareketi sayılmalı: ' .. client:LastIdle())

    client:Advance(12 * 60000) -- ekran açık ama imleç hareketsiz
    truthy(client:LastIdle() >= 600, 'hareketsiz imleç sayılmamalı: ' .. client:LastIdle())

    local off = MockClient.new({ configure = function(c) c.Afk.CountNuiCursor = false end })
    off:Sync()
    off.state.nuiFocus = true
    off:Simulate(120, function(i) off.state.cursor = { i, i } end)
    truthy(off:LastIdle() >= 55, 'ayar kapalıyken sayılmaz')
end)

test('fxmanifest.lua içindeki tüm dosyalar mevcut', function()
    local file = assert(io.open('fxmanifest.lua', 'r'))
    local manifest = file:read('a')
    file:close()
    local count = 0
    for path in manifest:gmatch("'([%w_/%.]+%.lua)'") do
        local handle = io.open(path, 'r')
        truthy(handle, 'eksik dosya: ' .. path)
        handle:close()
        count = count + 1
    end
    eq(count, 9, 'manifest dosya sayısı')
end)

------------------------------------------------------------------------
-- Çalıştır
------------------------------------------------------------------------
local passed, failed = 0, 0
for _, entry in ipairs(tests) do
    local ok, err = xpcall(entry.fn, debug.traceback)
    if ok then
        passed = passed + 1
        realPrint('  [OK]   ' .. entry.name)
    else
        failed = failed + 1
        realPrint('  [HATA] ' .. entry.name .. '\n      ' .. tostring(err))
    end
end

realPrint(('\n%d test, %d başarılı, %d başarısız'):format(passed + failed, passed, failed))
os.exit(failed == 0 and 0 or 1)
