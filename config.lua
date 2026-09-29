--[[
    LOE - loe_exp | Yapılandırma

    Bu dosya hem SUNUCU hem İSTEMCİ tarafında yüklenir (shared_script).
    Gizli bilgileri (Discord webhook vb.) buraya YAZMAYIN, config_server.lua dosyasını kullanın.
]]

Config = {}

-- Ayrıntılı konsol çıktıları (geliştirme / test için)
Config.Debug = false

-- Kullanılan framework: 'auto' | 'esx' | 'qb' | 'qbx' | 'standalone'
-- 'auto' sırasıyla qbx_core, es_extended ve qb-core resource'larını arar. Hiçbiri yoksa standalone çalışır.
Config.Framework = 'auto'

-- İlerleme hangi kimliğe yazılır?
--   'character' : Framework karakter kimliği (ESX identifier / QBCore-Qbox citizenid). Her karakter ayrı seviyelenir.
--   'license'   : Rockstar lisansı. Hesaptaki bütün karakterler aynı seviyeyi paylaşır.
-- Standalone modda her zaman lisans kullanılır.
Config.IdentifierMode = 'character'

------------------------------------------------------------------------
-- Seviye / EXP
------------------------------------------------------------------------

-- Maksimum seviye. Bu seviyedeki oyuncu EXP kazanmaz ve aktif süre sayacı durur.
Config.MaxLevel = 100

-- Saatlik EXP: EXP verme süresi her dolduğunda verilecek EXP miktarı.
Config.ExpPerInterval = 1

-- EXP verme süresi: kaç AKTİF dakikada bir EXP verileceği.
-- (Varsayılan denge: 60 dk = 1 EXP, 1->100 toplam 8.760 EXP = 8.760 aktif saat)
Config.ExpIntervalMinutes = 60

------------------------------------------------------------------------
-- Kayıt
------------------------------------------------------------------------

-- Değişen oyuncu verilerinin toplu olarak (tek transaction) kaydedilme aralığı (dakika).
-- EXP / seviye değişiklikleri bu aralığı beklemeden anında kaydedilir.
-- Bu aralık yalnızca biriken aktif süre (saniye) için geçerlidir.
Config.AutoSaveMinutes = 5

-- Tablolar yoksa sunucu açılışında sql/loe_exp.sql otomatik çalıştırılır.
Config.AutoCreateTables = true

------------------------------------------------------------------------
-- Aktivite / AFK kontrolü
------------------------------------------------------------------------
Config.Afk = {
    -- false yapılırsa bağlı ve karakteri yüklü her oyuncu aktif sayılır (önerilmez)
    Enabled = true,

    -- 'internal' : Bu resource'un dahili aktivite kontrolü kullanılır.
    -- 'external' : LOE'nin kendi AFK sistemi durumu şu export ile bildirir:
    --              exports.loe_exp:SetPlayerAfk(source, true / false)
    Provider = 'internal',

    -- AFK kontrol süresi (dakika).
    -- İki aktivite arasındaki boşluk bu süreyi AŞARSA boşluğun TAMAMI AFK sayılır ve aktif süreye eklenmez.
    -- Daha kısa boşluklar (ör. birini dinlerken kıpırdamadan durmak) aktif oyun sayılır.
    TimeoutMinutes = 10,

    -- İstemcinin sunucuya aktivite bildirme aralığı (saniye). TimeoutMinutes'ten çok küçük olmalıdır.
    HeartbeatSeconds = 30,

    -- İstemcide aktivite örnekleme aralığı (ms). Her karede değil, bu aralıkla kontrol edilir.
    SampleIntervalMs = 1000,

    -- İstemci hassasiyeti
    CameraThreshold = 1.0, -- derece: kamera bu kadar döndüyse aktivite sayılır
    MoveThreshold = 0.3,   -- metre: karakter bu kadar yer değiştirdiyse aktivite sayılır (araç yolcusu hariç)
    CountVoice = true,     -- sesli konuşma (voice chat) aktivite sayılsın mı?

    -- Sunucu taraflı doğrulama (OneSync gerekir, yoksa otomatik atlanır).
    -- İstemci "aktifim" dese bile karakter StillMinutes boyunca hiç yer / yön değiştirmediyse
    -- sunucu oyuncuyu AFK kabul eder. Hileli (sahte) aktivite bildirimlerine karşı ek katmandır.
    ServerCheck = {
        Enabled = true,
        StillMinutes = 20,
        MinDistance = 1.0,  -- metre
        MinHeading = 10.0,  -- derece
    },
}

------------------------------------------------------------------------
-- Bildirimler
------------------------------------------------------------------------
Config.Notify = {
    -- Otomatik bildirimleri (seviye atlama, EXP kazanma vb.) tamamen aç / kapat.
    -- Komut yanıtları bu ayardan etkilenmez.
    Enabled = true,

    -- Kullanılacak bildirim sistemi: 'auto' | 'ox_lib' | 'esx' | 'qb' | 'native' | 'custom'
    -- auto: ox_lib açıksa ox_lib, değilse framework bildirimi, o da yoksa GTA yerleşik bildirimi.
    System = 'auto',

    Title = 'Seviye',  -- ox_lib bildirim başlığı
    Duration = 7000,   -- ms

    LevelUp = true,    -- "Tebrikler! 25. seviyeye ulaştın."
    LevelDown = true,  -- EXP çıkarıldığında seviye düşüşü bilgisi
    ExpGain = true,    -- oyun süresinden EXP kazanıldığında bilgi
    AfkReturn = true,  -- AFK dönüşünde "bu süre sayılmadı" bilgisi

    -- System = 'custom' iken kullanılır ve SUNUCU tarafında çalışır.
    -- LOE'nin kendi bildirim sistemine bağlamak için örnek:
    -- Custom = function(source, message, notifyType, duration)
    --     TriggerClientEvent('loe_notify:client:show', source, message, notifyType, duration)
    -- end,
    Custom = nil,
}

------------------------------------------------------------------------
-- Yetkili
------------------------------------------------------------------------
Config.Admin = {
    -- ACE izni (önerilen yöntem). server.cfg: add_ace group.admin loe_exp.admin allow
    AcePermission = 'loe_exp.admin',

    -- Framework grup kontrolü (ESX getGroup / QBCore HasPermission / Qbox HasPermission).
    -- Boş tablo verilirse yalnızca ACE kontrolü yapılır.
    Groups = { 'admin', 'superadmin', 'god' },
}

-- Komut adları. Bir komutu kapatmak için false verin.
Config.Commands = {
    Self = 'seviyem',     -- herkes: kendi seviye bilgisini görür
    View = 'seviyebak',   -- yetkili: /seviyebak [id]
    Add = 'expekle',      -- yetkili: /expekle [id] [miktar]
    Remove = 'expsil',    -- yetkili: /expsil [id] [miktar]
    Set = 'expayarla',    -- yetkili: /expayarla [id] [toplam exp]
}

------------------------------------------------------------------------
-- Loglama
------------------------------------------------------------------------
Config.Logging = {
    Console = true,         -- sunucu konsoluna yaz
    Database = true,        -- loe_exp_logs tablosuna yaz
    ExportChanges = false,  -- diğer resource'ların export / event ile yaptığı EXP değişikliklerini de logla
}
-- Discord webhook adresi config_server.lua içindedir.

------------------------------------------------------------------------
-- Metinler
------------------------------------------------------------------------
Config.Locale = {
    level_up = 'Tebrikler! %d. seviyeye ulaştın.',
    max_level = 'Maksimum seviye olan %d. seviyeye ulaştın! Artık EXP kazanmayacaksın.',
    level_down = 'Seviyen %d olarak güncellendi.',
    exp_gain = '+%d EXP kazandın. Seviye %d: %d/%d EXP',
    afk_return = 'AFK / hareketsiz geçirdiğin yaklaşık %d dakika aktif oyun süresine sayılmadı.',

    self_info = 'Seviye: %d | Toplam EXP: %d | Sonraki seviye: %d/%d EXP | Sonraki EXP: %d/%d aktif dk',
    self_info_max = 'Seviye: %d (MAKS.) | Toplam EXP: %d',
    not_loaded = 'Seviye verin henüz yüklenmedi, lütfen biraz sonra tekrar dene.',

    no_permission = 'Bu komutu kullanma yetkin yok.',
    invalid_target = 'Oyuncu bulunamadı veya seviye verisi henüz yüklenmedi.',
    usage_view = 'Kullanım: /%s [oyuncu id]',
    usage_amount = 'Kullanım: /%s [oyuncu id] [miktar]',

    admin_view = '[%d] %s | Seviye: %d | Toplam EXP: %d | İlerleme: %d/%d EXP | Aktif süre: %d/%d dk | AFK: %s',
    admin_add = '[%d] %s oyuncusuna %d EXP eklendi. Seviye: %d -> %d (Toplam: %d EXP)',
    admin_remove = '[%d] %s oyuncusundan %d EXP çıkarıldı. Seviye: %d -> %d (Toplam: %d EXP)',
    admin_set = '[%d] %s oyuncusunun toplam EXP miktarı %d olarak ayarlandı. Seviye: %d -> %d',
    admin_failed = 'İşlem uygulanamadı: %s',

    yes = 'Evet',
    no = 'Hayır',

    errors = {
        not_loaded = 'oyuncunun seviye verisi yüklü değil',
        invalid_amount = 'geçersiz miktar (tam sayı olmalı ve %d değerini aşmamalı)',
        max_level = 'oyuncu zaten maksimum seviyede',
        no_exp = 'oyuncunun çıkarılacak EXP miktarı yok',
    },
}
