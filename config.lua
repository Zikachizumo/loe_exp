--[[
    loe_exp / config
    Hem sunucu hem istemci tarafında yüklenir (shared). Gizli bilgi yazmayın.
]]

Config = {}

-- Ayrıntılı konsol çıktıları (geliştirme / test için)
Config.Debug = false

-- ------------------------------------------------------------------ seviye / exp
-- İlerleme karakter bazlıdır (Qbox citizenid). Her karakter ayrı seviyelenir.

Config.MaxLevel           = 100  -- maksimum seviye; bu seviyedeki oyuncu EXP kazanmaz
Config.ExpPerInterval     = 1    -- saatlik EXP: EXP verme süresi her dolduğunda verilecek miktar
Config.ExpIntervalMinutes = 60   -- EXP verme süresi: kaç AKTİF dakikada bir EXP verilir

-- ------------------------------------------------------------------ kayıt
-- EXP / seviye değişiklikleri anında kaydedilir. Bu aralık yalnızca biriken
-- aktif süre (saniye) için geçerlidir; değişen tüm oyuncular tek transaction ile yazılır.
Config.AutoSaveMinutes  = 5
Config.AutoCreateTables = true   -- tablolar yoksa açılışta sql/loe_exp.sql çalıştırılır

-- ------------------------------------------------------------------ qbox metadata
-- Seviye ve toplam EXP ayrıca oyuncu metadata'sına yazılır. Böylece HUD gibi scriptler
-- qbx:GetPlayerData().metadata.level ile ek kod yazmadan okuyabilir.
-- Asıl kayıt her zaman loe_exp tablosundadır; metadata yalnızca bir kopyadır.
Config.Metadata = {
    Enabled  = true,
    LevelKey = 'level',
    ExpKey   = 'exp',
}

-- ------------------------------------------------------------------ afk kontrolü
Config.Afk = {
    Enabled = true,          -- false: karakteri yüklü her oyuncu aktif sayılır (önerilmez)

    -- AFK kontrol süresi (dk). İki aktivite arasındaki boşluk bu süreyi AŞARSA
    -- boşluğun TAMAMI AFK sayılır. Daha kısa duraklamalar aktif oyun sayılır.
    TimeoutMinutes = 10,

    HeartbeatSeconds = 30,   -- istemcinin sunucuya aktivite bildirme aralığı (sn)
    SampleIntervalMs = 1000, -- istemcide aktivite örnekleme aralığı (ms)

    CameraThreshold = 1.0,   -- derece: kamera bu kadar döndüyse aktivite
    MoveThreshold   = 0.3,   -- metre: karakter bu kadar yer değiştirdiyse aktivite (araç yolcusu hariç)
    CountVoice      = true,  -- sesli konuşma aktivite sayılsın mı

    -- Sunucu taraflı doğrulama (OneSync). İstemci "aktifim" dese bile karakter
    -- StillMinutes boyunca hiç yer / yön değiştirmediyse sunucu oyuncuyu AFK sayar.
    ServerCheck = {
        Enabled      = true,
        StillMinutes = 10,
        MinDistance  = 1.0,  -- metre
        MinHeading   = 10.0, -- derece
    },
}

-- ------------------------------------------------------------------ bildirimler (ox_lib)
Config.Notify = {
    Enabled   = true,         -- otomatik bildirimler (komut yanıtları etkilenmez)
    Title     = 'Seviye',
    Duration  = 7000,         -- ms
    Position  = 'top-right',  -- ox_lib bildirim konumu

    LevelUp   = true,         -- "Tebrikler! 25. seviyeye ulaştın."
    LevelDown = true,         -- EXP çıkarılınca seviye düşüşü
    ExpGain   = true,         -- oyun süresinden her EXP kazanımında
    AfkReturn = true,         -- AFK dönüşünde "bu süre sayılmadı" bilgisi
}

-- ------------------------------------------------------------------ komutlar
-- Yetkili komutları bu gruba kısıtlanır (lib.addCommand restricted).
Config.AdminGroup = 'group.admin'

-- Komut adları. Bir komutu kapatmak için false verin.
Config.Commands = {
    Self   = 'seviyem',    -- herkes: kendi seviye bilgisini görür
    View   = 'seviyebak',  -- yetkili: /seviyebak [id]
    Add    = 'expekle',    -- yetkili: /expekle [id] [miktar]
    Remove = 'expsil',     -- yetkili: /expsil [id] [miktar]
    Set    = 'expayarla',  -- yetkili: /expayarla [id] [toplam exp]
}

-- ------------------------------------------------------------------ log
-- Yetkili işlemleri her zaman loe_exp_logs tablosuna yazılır.
Config.Logging = {
    ExportChanges = false,  -- diğer resource'ların export / event ile yaptığı değişiklikleri de logla
}

-- ------------------------------------------------------------------ metinler
Config.Locale = {
    level_up   = 'Tebrikler! %d. seviyeye ulaştın.',
    max_level  = 'Maksimum seviye olan %d. seviyeye ulaştın! Artık EXP kazanmayacaksın.',
    level_down = 'Seviyen %d olarak güncellendi.',
    exp_gain   = '+%d EXP kazandın. Seviye %d: %d/%d EXP',
    afk_return = 'AFK / hareketsiz geçirdiğin yaklaşık %d dakika aktif oyun süresine sayılmadı.',

    self_info     = 'Seviye: %d | Toplam EXP: %d | Sonraki seviye: %d/%d EXP | Sonraki EXP: %d/%d aktif dk',
    self_info_max = 'Seviye: %d (MAKS.) | Toplam EXP: %d',
    not_loaded    = 'Seviye verin henüz yüklenmedi, lütfen biraz sonra tekrar dene.',

    invalid_target = 'Oyuncu bulunamadı veya seviye verisi henüz yüklenmedi.',
    usage_view     = 'Kullanım: /%s [oyuncu id]',
    usage_amount   = 'Kullanım: /%s [oyuncu id] [miktar]',

    admin_view   = '[%d] %s | Seviye: %d | Toplam EXP: %d | İlerleme: %d/%d EXP | Aktif süre: %d/%d dk | AFK: %s',
    admin_add    = '[%d] %s oyuncusuna %d EXP eklendi. Seviye: %d -> %d (Toplam: %d EXP)',
    admin_remove = '[%d] %s oyuncusundan %d EXP çıkarıldı. Seviye: %d -> %d (Toplam: %d EXP)',
    admin_set    = '[%d] %s oyuncusunun toplam EXP miktarı %d olarak ayarlandı. Seviye: %d -> %d',
    admin_failed = 'İşlem uygulanamadı: %s',

    yes = 'Evet',
    no  = 'Hayır',

    errors = {
        not_loaded     = 'oyuncunun seviye verisi yüklü değil',
        invalid_amount = 'geçersiz miktar (tam sayı olmalı ve %d değerini aşmamalı)',
        max_level      = 'oyuncu zaten maksimum seviyede',
        no_exp         = 'oyuncunun çıkarılacak EXP miktarı yok',
    },
}
