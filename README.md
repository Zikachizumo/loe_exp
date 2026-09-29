# loe_exp: LOE Seviye ve EXP Sistemi

Legends of Empire (LOE) FiveM roleplay sunucusu için **aktif oyun süresine dayalı**, 1 ile 100 arası oyuncu seviye sistemi.

- Oyuncu **her 60 aktif dakikada 1 EXP** kazanır.
- **AFK geçen süre sayılmaz.**
- Oyundan çıkıp girmek, resource veya sunucuyu yeniden başlatmak **ilerlemeyi sıfırlamaz**.
- EXP ve seviye hesaplamaları **tamamen sunucu tarafında** yapılır. İstemci EXP veya seviye belirleyemez.
- 1'den 100'e toplam **8.760 EXP = 8.760 aktif saat = 365 gün 24 saat** gerekir.

---

## İçindekiler

1. [Dosya yapısı](#dosya-yapısı)
2. [Gereksinimler](#gereksinimler)
3. [Kurulum](#kurulum)
4. [Yapılandırma](#yapılandırma)
5. [Seviye dengesi](#seviye-dengesi)
6. [Aktif süre ve AFK kontrolü](#aktif-süre-ve-afk-kontrolü)
7. [Kayıt ve kalıcılık](#kayıt-ve-kalıcılık)
8. [Komutlar](#komutlar)
9. [Geliştirici API'si (export ve event)](#geliştirici-apisi-export-ve-event)
10. [Veritabanı](#veritabanı)
11. [Güvenlik](#güvenlik)
12. [Testler](#testler)
13. [Sorun giderme](#sorun-giderme)

---

## Dosya yapısı

```
loe_exp/
├── fxmanifest.lua          Resource tanımı
├── config.lua              Ayarlar (shared: sunucu + istemci)
├── config_server.lua       Sunucuya özel gizli ayarlar (Discord webhook)
├── shared/
│   └── sh_level.lua        Seviye formülü ve seviye hesaplama döngüsü
├── server/
│   ├── sv_bridge.lua       Framework köprüsü (ESX / QBCore / Qbox / standalone), yetki, bildirim
│   ├── sv_database.lua     oxmysql sorguları (parametreli, toplu kayıt)
│   ├── sv_logs.lua         Konsol / veritabanı / Discord loglama
│   ├── sv_main.lua         Çekirdek: oturumlar, aktif süre, EXP ve seviye mantığı
│   ├── sv_exports.lua      Diğer LOE sistemleri için export ve event'ler
│   └── sv_commands.lua     Oyuncu ve yetkili komutları
├── client/
│   └── cl_main.lua         Aktivite gözlemi (AFK tespiti) ve bildirim gösterimi
├── sql/
│   └── loe_exp.sql         Veritabanı kurulum dosyası
└── tests/                  Sunucu test paketi (oyuna yüklenmez)
    ├── mock_fivem.lua
    └── run_tests.lua
```

## Gereksinimler

| Gereksinim | Durum | Not |
|---|---|---|
| [oxmysql](https://github.com/overextended/oxmysql) | **Zorunlu** | Veritabanı erişimi |
| MariaDB 10.3+ / MySQL 5.7+ | **Zorunlu** | |
| OneSync | Önerilir | Sunucu taraflı hareketsizlik kontrolü için. Kapalıysa bu kontrol otomatik atlanır. |
| ESX Legacy / QBCore / Qbox | İsteğe bağlı | Otomatik algılanır. Hiçbiri yoksa standalone (lisans tabanlı) çalışır. |
| ox_lib | İsteğe bağlı | Varsa bildirimler ox_lib ile gösterilir. |

## Kurulum

1. **Dosyaları yerleştirin.** `loe_exp` klasörünü sunucunun `resources` dizinine kopyalayın (ör. `resources/[loe]/loe_exp`). Klasör adı `loe_exp` olmalıdır.

2. **Veritabanı tablolarını oluşturun.** İki yöntem vardır:
   - **Otomatik (varsayılan):** `Config.AutoCreateTables = true` iken tablolar sunucu açılışında `sql/loe_exp.sql` dosyasından oluşturulur.
   - **Elle:** `sql/loe_exp.sql` dosyasını HeidiSQL, phpMyAdmin veya benzeri bir araçla sunucu veritabanında çalıştırın.

3. **`server.cfg` dosyasını düzenleyin.** `loe_exp`, oxmysql ve framework'ten **sonra** başlatılmalıdır:

   ```cfg
   ensure oxmysql
   ensure es_extended      # veya qb-core / qbx_core (kullanılan framework)
   ensure ox_lib           # isteğe bağlı
   ensure loe_exp

   # Yetkili izni (önerilen yöntem)
   add_ace group.admin loe_exp.admin allow
   ```

4. **Ayarları kontrol edin.** `config.lua` dosyasındaki `Config.IdentifierMode`, bildirim sistemi ve AFK ayarlarını sunucunuza göre düzenleyin. Discord logu istiyorsanız `config_server.lua` içindeki `Config.DiscordWebhook` alanını doldurun.

5. **Sunucuyu başlatın.** Konsolda şu satırı görmelisiniz:

   ```
   [loe_exp] Hazır | Framework: esx | Maks. seviye: 100 (8760 EXP) | 1 EXP / 60 aktif dk | AFK: dahili, 10 dk
   ```

> Resource sunucu açıkken de başlatılabilir veya yeniden başlatılabilir (`ensure loe_exp` / `restart loe_exp`). İçerideki oyuncuların verisi otomatik olarak yeniden yüklenir.

## Yapılandırma

Tüm ayarlar `config.lua` içindedir. En önemlileri:

| Ayar | Varsayılan | Açıklama |
|---|---|---|
| `Config.Framework` | `'auto'` | `'auto'`, `'esx'`, `'qb'`, `'qbx'`, `'standalone'` |
| `Config.IdentifierMode` | `'character'` | `'character'`: her karakter ayrı seviyelenir. `'license'`: hesaptaki tüm karakterler aynı seviyeyi paylaşır. |
| `Config.MaxLevel` | `100` | Maksimum seviye |
| `Config.ExpPerInterval` | `1` | Saatlik EXP (her aralıkta verilecek EXP) |
| `Config.ExpIntervalMinutes` | `60` | EXP verme süresi (aktif dakika) |
| `Config.AutoSaveMinutes` | `5` | Toplu otomatik kayıt aralığı |
| `Config.AutoCreateTables` | `true` | Tabloları açılışta otomatik oluştur |
| `Config.Afk.Enabled` | `true` | AFK kontrolü |
| `Config.Afk.Provider` | `'internal'` | `'internal'` (dahili) veya `'external'` (LOE'nin kendi AFK sistemi) |
| `Config.Afk.TimeoutMinutes` | `10` | AFK kontrol süresi |
| `Config.Afk.HeartbeatSeconds` | `30` | İstemcinin aktivite bildirme aralığı |
| `Config.Afk.ServerCheck.StillMinutes` | `20` | Sunucunun hiç hareket görmediği bu süreden sonra oyuncu AFK sayılır |
| `Config.Notify.System` | `'auto'` | `'auto'`, `'ox_lib'`, `'esx'`, `'qb'`, `'native'`, `'custom'` |
| `Config.Notify.LevelUp` / `LevelDown` / `ExpGain` / `AfkReturn` | `true` | Bildirim türleri |
| `Config.Admin.AcePermission` | `'loe_exp.admin'` | Yetkili ACE izni |
| `Config.Admin.Groups` | `admin, superadmin, god` | Framework yetkili grupları |
| `Config.Commands.*` | | Komut adları (`false` ile kapatılır) |
| `Config.Logging.*` | | Konsol / veritabanı / export değişikliği logları |
| `Config.Locale` | | Tüm Türkçe metinler |

### LOE bildirim sistemine bağlama

`auto` modunda sırasıyla ox_lib, framework bildirimi ve GTA yerleşik bildirimi kullanılır. LOE'nin kendi bildirim resource'unu kullanmak için:

```lua
Config.Notify = {
    System = 'custom',
    Custom = function(source, message, notifyType, duration)
        -- notifyType: 'success' | 'error' | 'inform'
        TriggerClientEvent('loe_notify:client:show', source, message, notifyType, duration)
    end,
    -- ... diğer ayarlar
}
```

Tüm bildirimler `server/sv_bridge.lua` içindeki tek bir fonksiyondan (`LoeBridge.Notify`) geçer.

## Seviye dengesi

Mevcut seviyeden bir sonrakine geçmek için gereken EXP:

```lua
local function GetRequiredXP(currentLevel)
    return math.max(
        1,
        math.floor((currentLevel * 1.808) - 1.93 + 0.5)
    )
end
```

Gereksinim her seviyede yaklaşık 1,8 EXP artar, iki katına çıkmaz.

| Geçiş | EXP | | Seviye | Toplam EXP | Aktif süre |
|---|---|---|---|---|---|
| 1 → 2 | 1 | | 10 | 65 | 65 saat |
| 2 → 3 | 2 | | 20 | 308 | ~12,8 gün |
| 3 → 4 | 3 | | 30 | 732 | 30,5 gün |
| 4 → 5 | 5 | | 40 | 1.337 | ~55,7 gün |
| 9 → 10 | 14 | | 50 | 2.122 | ~88,4 gün |
| 19 → 20 | 32 | | 60 | 3.088 | ~128,7 gün |
| 29 → 30 | 51 | | 70 | 4.235 | ~176,5 gün |
| 49 → 50 | 87 | | 80 | 5.562 | ~231,8 gün |
| 59 → 60 | 105 | | 90 | 7.071 | ~294,6 gün |
| 99 → 100 | 177 | | **100** | **8.760** | **365 gün** |

Seviye her zaman **toplam EXP'den döngüyle** hesaplanır. Oyuncu tek seferde birkaç seviyeye yetecek EXP alırsa (ör. yetkili 2.122 EXP eklerse) döngü her seviyeyi sırayla atlar ve oyuncuya yalnızca ulaşılan son seviye bildirilir (`Tebrikler! 50. seviyeye ulaştın.`).

> `Config.MaxLevel` değiştirilirse toplam hedef de buna göre değişir. Formül sabitlerini değiştirmek 8.760 saatlik dengeyi bozar.

## Aktif süre ve AFK kontrolü

Karar her zaman **sunucudadır**. İstemci yalnızca "son aktiviteden bu yana geçen saniye" bilgisini gönderir.

**İstemci (`client/cl_main.lua`)** her `SampleIntervalMs` (1 sn) aralığında tek bir hafif döngüyle şunları kontrol eder:

- kamera dönüşü (GTA'nın otomatik boşta kamerası hariç),
- karakterin yer değiştirmesi (araçta yalnızca sürücü; AFK yolcu sayılmaz),
- sesli konuşma (`CountVoice`),
- temel kontrol tuşları (hareket, koşma, ateş, etkileşim, sohbet, bas-konuş vb.).

Her `HeartbeatSeconds` (30 sn) aralığında sunucuya `loe_exp:server:activity` olayı gönderilir.

**Sunucu (`server/sv_main.lua`)** her oyuncu için "en son sayılan aktivite anı"nı (çapa) tutar:

1. Yeni aktivite anı ile çapa arasındaki boşluk **AFK kontrol süresinden (10 dk) kısaysa** aktif süreye eklenir. Kısa duraklamalar (birini dinlemek, kısa bir bekleyiş) böylece haksız yere kesilmez.
2. Boşluk bu süreyi **aşarsa boşluğun tamamı AFK sayılır** ve eklenmez. Oyuncu döndüğünde `AFK / hareketsiz geçirdiğin yaklaşık X dakika aktif oyun süresine sayılmadı.` bilgisi gösterilir.
3. Eklenen süre, sunucu saatine göre **gerçekte geçen süreyi asla aşamaz**. Sahte bildirimler zamanı hızlandıramaz.
4. **Sunucu taraflı kontrol:** İstemci "aktifim" dese bile sunucu karakterin `StillMinutes` (20 dk) boyunca hiç yer veya yön değiştirmediğini görürse oyuncuyu AFK kabul eder. Bu kontrol OneSync gerektirir.
5. İstemciden hiç bildirim gelmezse (script durdurulmuş, oyun donmuş vb.) süre sayılmaz.
6. Aktif süre biriktikçe her 60 dakikada bir EXP verilir. Artan saniyeler bir sonraki EXP için saklanır.

### LOE'nin kendi AFK sistemini kullanma

Projede hazır bir AFK sistemi varsa `Config.Afk.Provider = 'external'` yapın ve o sistemden durumu bildirin:

```lua
-- LOE AFK sistemi (sunucu tarafı)
exports.loe_exp:SetPlayerAfk(source, true)   -- oyuncu AFK oldu
exports.loe_exp:SetPlayerAfk(source, false)  -- oyuncu geri döndü
```

Bu modda dahili istemci gözlemi kapanır. İstemci yalnızca bağlı olduğunu bildirir, AFK kararı dış sistemden gelir. Sunucu taraflı hareketsizlik kontrolü bu modda da çalışır.

## Kayıt ve kalıcılık

| Olay | Davranış |
|---|---|
| EXP / seviye değişimi | Anında kaydedilir (seyrek bir olay, saatte bir) |
| Biriken aktif süre | `AutoSaveMinutes` (5 dk) aralığında, değişen tüm oyuncular **tek transaction** ile toplu kaydedilir |
| Oyuncu çıkışı (`playerDropped`) | Anında kaydedilir. Kayıt başarısız olursa veri bellekte tutulur ve bir sonraki otomatik kayıtta tekrar denenir. Oyuncu bu arada geri gelirse bellekteki güncel veri kullanılır. |
| Karakter değiştirme (multichar) | `esx:playerLogout` / `QBCore:Server:OnPlayerUnload` ile oturum kapatılır ve kaydedilir |
| Resource durdurma | `onResourceStop` ile tüm oyuncular kaydedilir |
| txAdmin kapatma / yeniden başlatma | `txAdmin:events:serverShuttingDown` ile tüm oyuncular kaydedilir |
| Resource / sunucu açılışı | İçerideki oyuncular veritabanından yeniden yüklenir, kalan aktif süre kaldığı yerden devam eder |

- Ani çökmede (elektrik kesintisi vb.) en fazla son `AutoSaveMinutes` kadar **aktif süre** kaybolabilir. Kazanılmış **EXP kaybolmaz**, çünkü EXP değişimleri anında yazılır.
- Veritabanına her saniye sorgu gönderilmez. Bir oyuncu için saatte ~12 otomatik kayıt ve 1 EXP kaydı yapılır.
- Yükleme sırasında veritabanı hatası olursa oyuncuya sıfır veriyle oturum **açılmaz**, böylece gerçek verinin üzerine yazılamaz. İstemci 10 saniyede bir veri ister ve yükleme kendiliğinden yeniden denenir.
- Seviye sütunu toplam EXP ile uyuşmazsa (elle düzenleme vb.) yükleme sırasında otomatik düzeltilir.

## Komutlar

| Komut | Yetki | Açıklama |
|---|---|---|
| `/seviyem` | Herkes | Kendi seviye, EXP ve aktif süre ilerlemesini gösterir |
| `/seviyebak [id]` | Yetkili | Oyuncunun seviye, EXP, ilerleme, aktif süre ve AFK durumunu gösterir |
| `/expekle [id] [miktar]` | Yetkili | Oyuncuya EXP ekler |
| `/expsil [id] [miktar]` | Yetkili | Oyuncudan EXP çıkarır (seviye gerekirse düşer) |
| `/expayarla [id] [toplam]` | Yetkili | Oyuncunun toplam EXP miktarını ayarlar |

- Yetki kontrolü: `Config.Admin.AcePermission` ACE izni **veya** framework grubu (`Config.Admin.Groups`).
- Komutlar sunucu konsolundan da kullanılabilir (ör. `expekle 12 50`).
- Miktarlar tam sayı olmalı ve en fazla 8.760 olabilir. Ondalıklı, negatif veya metin girdiler reddedilir.
- **Tüm yetkili işlemleri loglanır:** konsol, `loe_exp_logs` tablosu ve (ayarlandıysa) Discord webhook. Logda işlemi yapan, hedef oyuncu, miktar, eski/yeni seviye ve eski/yeni EXP bulunur.

## Geliştirici API'si (export ve event)

### Sunucu export'ları

```lua
local level = exports.loe_exp:GetLevel(source)           -- number | nil (veri yüklü değilse)
local total = exports.loe_exp:GetTotalExp(source)        -- number | nil
local data  = exports.loe_exp:GetPlayerData(source)      -- table | nil
-- data = { level, totalExp, currentExp, requiredExp, maxLevel, isMaxLevel,
--          activeMinutes, intervalMinutes, totalActiveMinutes }

local ok, levelOrError, newTotal = exports.loe_exp:AddExp(source, 5, 'gorev_odulu')
local ok, levelOrError, newTotal = exports.loe_exp:RemoveExp(source, 3, 'ceza')
local ok, levelOrError, newTotal = exports.loe_exp:SetExp(source, 2122, 'aktarim')
local ok, level = exports.loe_exp:RecalculateLevel(source)
-- Hata kodları: 'not_loaded' | 'invalid_amount' | 'max_level' | 'no_exp'

exports.loe_exp:SetPlayerAfk(source, true)       -- Provider = 'external' için
local afk = exports.loe_exp:IsPlayerAfk(source)

exports.loe_exp:GetRequiredXP(level)             -- seviye -> sonraki seviye için gereken EXP
exports.loe_exp:GetTotalExpForLevel(level)       -- seviyeye ulaşmak için toplam EXP
exports.loe_exp:GetMaxLevel()                    -- 100
```

**Örnek:** 10. seviye altındaki oyuncuların bir mesleğe girmesini engellemek:

```lua
local level = exports.loe_exp:GetLevel(source)
if not level or level < 10 then
    return TriggerClientEvent('ox_lib:notify', source, { description = 'Bu meslek için en az 10. seviye olmalısın.', type = 'error' })
end
```

### Sunucu içi event'ler (istemci tetikleyemez)

```lua
TriggerEvent('loe_exp:server:getLevel', source, function(level) end)
TriggerEvent('loe_exp:server:getTotalExp', source, function(totalExp) end)
TriggerEvent('loe_exp:server:addExp', source, amount, reason, function(ok, levelOrError, totalExp) end)
TriggerEvent('loe_exp:server:removeExp', source, amount, reason, function(ok, levelOrError, totalExp) end)
TriggerEvent('loe_exp:server:setExp', source, totalExp, reason, function(ok, levelOrError, totalExp) end)
TriggerEvent('loe_exp:server:recalculateLevel', source, function(ok, level, totalExp) end)
```

### Dinlenebilir event'ler

```lua
-- Mutlaka AddEventHandler kullanın. RegisterNetEvent KULLANMAYIN, aksi hâlde istemciler bu olayları taklit edebilir.
AddEventHandler('loe_exp:onPlayerLoaded', function(source, data) end)
AddEventHandler('loe_exp:onExpChanged', function(source, totalExp, delta, reason) end)
AddEventHandler('loe_exp:onLevelChanged', function(source, newLevel, oldLevel)
    if newLevel == 25 then
        -- ör. ödül ver
    end
end)
```

`reason` değerleri: `'playtime'` (oyun süresi), `'admin:add'`, `'admin:remove'`, `'admin:set'`, `'recalculate'` veya export / event çağrısında verilen metin.

### İstemci (salt okunur, yalnızca gösterim)

```lua
local level = exports.loe_exp:GetLevel()
local data = exports.loe_exp:GetData()

-- HUD güncellemesi için
AddEventHandler('loe_exp:client:onDataUpdated', function(data)
    -- data.level, data.currentExp, data.requiredExp ...
end)
```

> İstemci verisi yalnızca gösterim içindir. Sunucu bu veriye hiçbir zaman güvenmez. Seviyeye bağlı kontrolleri **her zaman sunucu export'larıyla** yapın.

## Veritabanı

`sql/loe_exp.sql` iki tablo oluşturur:

**`loe_exp`**: oyuncu ilerlemesi

| Sütun | Tip | Açıklama |
|---|---|---|
| `identifier` (PK) | VARCHAR(64) | Karakter kimliği (ESX identifier / QB citizenid) veya lisans |
| `level` | SMALLINT | Seviye (toplam EXP'den hesaplanır, sorgu kolaylığı için saklanır) |
| `total_exp` | INT | Toplam EXP (doğruluk kaynağı) |
| `active_seconds` | INT | Bir sonraki EXP için biriken aktif süre (saniye) |
| `total_active_seconds` | BIGINT | Toplam aktif oyun süresi (istatistik, maks. seviyede de artar) |
| `last_name` | VARCHAR(100) | Son bilinen oyuncu / karakter adı |
| `created_at`, `updated_at` | TIMESTAMP | Zaman damgaları |

**`loe_exp_logs`**: yetkili işlem logları (`action`, `actor_identifier`, `actor_name`, `target_identifier`, `target_name`, `amount`, `old_level`, `new_level`, `old_exp`, `new_exp`, `note`, `created_at`)

Örnek sorgular:

```sql
-- En yüksek 10 seviye
SELECT last_name, level, total_exp FROM loe_exp ORDER BY total_exp DESC LIMIT 10;

-- Son 50 yetkili işlemi
SELECT * FROM loe_exp_logs ORDER BY id DESC LIMIT 50;
```

## Güvenlik

- İstemciye açık **yalnızca iki** ağ olayı vardır:
  - `loe_exp:server:activity`: yalnızca bir sayı (boşta geçen saniye) alır. Tip, NaN, negatif ve aşırı değer kontrolünden geçer. Hız sınırı vardır: beklenenden sık gelenler yok sayılır ve şüpheli spam konsola yazılır. EXP veya seviye belirleyemez.
  - `loe_exp:server:requestSync`: oyuncuya yalnızca **kendi** verisini gönderir. Hız sınırı vardır.
- EXP ekleme / çıkarma / ayarlama olayları `AddEventHandler` ile kaydedilmiştir (`RegisterNetEvent` değil). FiveM bu olayları istemciden gelirse reddeder.
- Tüm SQL sorguları parametrelidir (`?`). Kullanıcı verisi sorgu metnine eklenmez.
- Discord webhook adresi yalnızca sunucuda yüklenen `config_server.lua` içindedir, oyunculara gönderilmez.
- Sahte "aktifim" bildirimleri gerçek zamandan fazla süre kazandıramaz ve sunucu taraflı hareketsizlik kontrolüyle ayrıca sınırlanır.

## Testler

Sunucu kodu, FiveM ve oxmysql'i taklit eden bir ortamda düz Lua 5.4 ile uçtan uca test edilir (`tests/`). Bu klasör `fxmanifest.lua` içinde yer almaz, oyuna yüklenmez.

```bash
cd loe_exp
lua5.4 tests/run_tests.lua
```

Kapsanan senaryolar: formül ve tüm hedef tablolar, 8.760 saatlik tam simülasyon, AFK ve kısa duraklamalar, çıkış/giriş, resource yeniden başlatma, çökme sonrası kayıp sınırı, toplu kayıt, maksimum seviye, çoklu seviye atlama, EXP çıkarma, istemci exploit denemeleri, sahte/hatalı bildirimler ve spam, sunucu taraflı hareketsizlik kontrolü, yetkili komutları ve loglar, export/event API'si, harici AFK sağlayıcısı, veritabanı hatalarında veri koruma, multichar çıkışı.

## Sorun giderme

| Belirti | Çözüm |
|---|---|
| Konsolda `Framework: standalone` görünüyor ama ESX/QB kullanıyorum | `loe_exp`'i framework'ten **sonra** başlatın veya `Config.Framework` değerini elle ayarlayın. |
| Oyuncular EXP kazanmıyor | `Config.Debug = true` yapıp konsolu izleyin. `HeartbeatSeconds` değeri `TimeoutMinutes * 60`'tan küçük olmalı. Harici sağlayıcı kullanıyorsanız `SetPlayerAfk(source, false)` çağrıldığından emin olun. |
| RP sırasında uzun süre kıpırdamadan duran oyuncular süre kaybediyor | `Config.Afk.ServerCheck.StillMinutes` değerini artırın veya `ServerCheck.Enabled = false` yapın. |
| Yetkili komutu "yetkin yok" diyor | `server.cfg` içine `add_ace group.admin loe_exp.admin allow` ekleyin veya `Config.Admin.Groups` listesini kontrol edin. |
| `sql/loe_exp.sql okunamadı` hatası | Dosyanın `loe_exp/sql/` altında olduğundan emin olun veya SQL'i elle çalıştırıp `Config.AutoCreateTables = false` yapın. |
| Özel (LOE) karakter sistemi kullanıyorum | Kimlik, isim, yetki ve giriş/çıkış olaylarını `server/sv_bridge.lua` içinde uyarlayın. Diğer dosyalar framework'ten bağımsızdır. |
