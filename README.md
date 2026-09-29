# loe_exp

Legends of Empire (LOE) için **Qbox** tabanlı, **aktif oyun süresine dayalı** 1-100 seviye sistemi.

- Oyuncu **her 60 aktif dakikada 1 EXP** kazanır. **AFK süresi sayılmaz.**
- İlerleme **karakter bazlıdır** (Qbox `citizenid`). Her karakter ayrı seviyelenir.
- Oyundan çıkıp girmek, karakter değiştirmek, resource veya sunucuyu yeniden başlatmak **ilerlemeyi sıfırlamaz**.
- EXP ve seviye hesaplamaları **tamamen sunucu tarafında** yapılır. İstemci EXP veya seviye belirleyemez.
- 1'den 100'e toplam **8.760 EXP = 8.760 aktif saat = 365 gün 24 saat** gerekir.
- Seviye ve EXP ayrıca Qbox metadata'sına (`metadata.level`, `metadata.exp`) yazılır. HUD gibi scriptler bunu doğrudan okuyabilir.

## Klasör yapısı

```
loe_exp/
├── fxmanifest.lua
├── config.lua              # tüm ayarlar ve Türkçe metinler
├── shared/sh_level.lua     # seviye formülü ve seviye hesaplama döngüsü
├── server/
│   ├── sv_qbox.lua         # Qbox + ox_lib: oyuncu, citizenid, metadata, bildirim
│   ├── sv_database.lua     # oxmysql sorguları (parametreli, toplu kayıt)
│   ├── sv_logs.lua         # yetkili logları (loe_exp_logs)
│   ├── sv_main.lua         # çekirdek: oturum, aktif süre, EXP ve seviye mantığı
│   ├── sv_exports.lua      # diğer LOE sistemleri için export ve event'ler
│   └── sv_commands.lua     # komutlar (lib.addCommand)
├── client/cl_main.lua      # aktivite gözlemi (AFK tespiti)
├── sql/loe_exp.sql         # veritabanı kurulumu
└── tests/                  # sunucu test paketi (oyuna yüklenmez)
```

## Gereksinimler

- `qbx_core`, `ox_lib`, `oxmysql`
- OneSync (sunucu taraflı hareketsizlik kontrolü için; Qbox zaten OneSync ile çalışır)

## Kurulum

1. `loe_exp` klasörünü `resources/[loe]/loe_exp` altına koyun. Klasör adı `loe_exp` olmalıdır.
2. Veritabanı tabloları ilk açılışta `sql/loe_exp.sql` dosyasından **otomatik** oluşturulur (`Config.AutoCreateTables = true`). İsterseniz dosyayı HeidiSQL / phpMyAdmin ile elle de çalıştırabilirsiniz.
3. `server.cfg` (bağımlılıklardan sonra):
   ```
   ensure oxmysql
   ensure ox_lib
   ensure qbx_core
   ensure loe_exp
   ```
   Yetkili komutları `group.admin` grubuna kısıtlıdır. ox_lib, `command.<komut>` ACE iznini bu gruba **kendisi ekler**. Bunun için Qbox kurulumunda `server.cfg` içinde zaten bulunan şu satırın olması yeterlidir, ayrıca komut için `add_ace` yazmanız gerekmez:
   ```
   add_ace resource.ox_lib command.add_ace allow
   ```
4. Sunucu açıldığında konsolda şu satır görünmelidir:
   ```
   [loe_exp] Hazır | Maks. seviye: 100 (8760 EXP) | 1 EXP / 60 aktif dk | AFK: 10 dk
   ```

> Canlı `restart loe_exp` desteklenir. İçerideki oyuncuların verisi otomatik olarak yeniden yüklenir.

## Ayarlar (`config.lua`)

| Ayar | Varsayılan | Açıklama |
|---|---|---|
| `Config.MaxLevel` | `100` | Maksimum seviye |
| `Config.ExpPerInterval` | `1` | Saatlik EXP (her aralıkta verilecek EXP) |
| `Config.ExpIntervalMinutes` | `60` | EXP verme süresi (aktif dakika) |
| `Config.AutoSaveMinutes` | `5` | Biriken aktif sürenin toplu kayıt aralığı |
| `Config.AutoCreateTables` | `true` | Tabloları açılışta otomatik oluştur |
| `Config.Metadata` | açık, `level` / `exp` | Qbox metadata'sına yazılacak anahtarlar |
| `Config.Afk.TimeoutMinutes` | `10` | AFK kontrol süresi |
| `Config.Afk.HeartbeatSeconds` | `30` | İstemcinin aktivite bildirme aralığı |
| `Config.Afk.ServerCheck.StillMinutes` | `10` | Sunucunun hiç hareket görmediği bu süreden sonra oyuncu AFK sayılır |
| `Config.Notify.*` | | ox_lib bildirim başlığı, süresi, konumu ve bildirim türleri |
| `Config.AdminGroup` | `'group.admin'` | Yetkili komutlarının kısıtlandığı grup |
| `Config.Commands.*` | | Komut adları (`false` ile kapatılır) |
| `Config.Logging.ExportChanges` | `false` | Export / event değişikliklerini de logla |
| `Config.Locale` | | Tüm Türkçe metinler |

## Seviye dengesi

```lua
local function GetRequiredXP(currentLevel)
    return math.max(1, math.floor((currentLevel * 1.808) - 1.93 + 0.5))
end
```

Gereksinim her seviyede ~1,8 EXP artar, iki katına çıkmaz.

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

Seviye her zaman **toplam EXP'den döngüyle** hesaplanır. Tek seferde birkaç seviyeye yetecek EXP gelirse döngü her seviyeyi sırayla atlar ve oyuncuya yalnızca ulaşılan son seviye bildirilir (`Tebrikler! 50. seviyeye ulaştın.`). 100. seviyede EXP ve aktif süre sayacı durur.

## Aktif süre ve AFK kontrolü

Karar her zaman **sunucudadır**. İstemci yalnızca "son aktiviteden bu yana geçen saniye" bilgisini gönderir.

**İstemci** saniyede bir, tek bir hafif döngüyle şunlara bakar:

- kamera dönüşü (GTA'nın otomatik boşta kamerası hariç),
- karakterin yer değiştirmesi (araçta yalnızca sürücü; AFK yolcu sayılmaz),
- sesli konuşma,
- temel kontrol tuşları.

Her 30 saniyede bir sunucuya bildirim gönderir.

**Sunucu** her oyuncu için "en son sayılan aktivite anı"nı tutar:

1. İki aktivite arasındaki boşluk **10 dakikadan kısaysa** aktif süreye eklenir. Kısa duraklamalar (birini dinlemek vb.) haksız yere kesilmez.
2. Boşluk 10 dakikayı **aşarsa boşluğun tamamı AFK sayılır**. Oyuncu döndüğünde `AFK / hareketsiz geçirdiğin yaklaşık X dakika aktif oyun süresine sayılmadı.` bilgisi gösterilir.
3. Eklenen süre, sunucu saatine göre **gerçekte geçen süreyi asla aşamaz**. Sahte bildirimler zamanı hızlandıramaz.
4. İstemci "aktifim" dese bile sunucu karakterin **10 dakika** boyunca hiç yer veya yön değiştirmediğini görürse oyuncuyu AFK kabul eder.
5. İstemciden hiç bildirim gelmezse (script durdurulmuş, oyun donmuş vb.) süre sayılmaz. Karakter seçim ekranında da süre sayılmaz.

## Kayıt ve kalıcılık

| Olay | Davranış |
|---|---|
| EXP / seviye değişimi | Anında kaydedilir ve Qbox metadata'sı güncellenir |
| Biriken aktif süre | 5 dakikada bir, değişen tüm oyuncular **tek transaction** ile kaydedilir |
| Oyundan çıkış | Anında kaydedilir. Başarısız olursa veri bellekte tutulur ve tekrar denenir. |
| Karakter değiştirme | `QBCore:Server:OnPlayerUnload` ile oturum kapatılır ve kaydedilir |
| Resource durdurma / txAdmin kapanışı | Tüm oyuncular kaydedilir |
| Resource / sunucu açılışı | İçerideki oyuncular yeniden yüklenir, kalan aktif süre kaldığı yerden devam eder |

- Ani çökmede en fazla son 5 dakikalık **aktif süre** kaybolabilir. Kazanılmış **EXP kaybolmaz**.
- Veritabanına her saniye sorgu gönderilmez.
- Yüklemede veritabanı hatası olursa oyuncuya sıfır veriyle oturum açılmaz, gerçek veri korunur ve yükleme kendiliğinden yeniden denenir.

## Komutlar

| Komut | Yetki | Açıklama |
|---|---|---|
| `/seviyem` | Herkes | Kendi seviye, EXP ve aktif süre ilerlemesi |
| `/seviyebak [id]` | `group.admin` | Oyuncunun seviye, EXP, ilerleme, aktif süre ve AFK durumu |
| `/expekle [id] [miktar]` | `group.admin` | EXP ekler |
| `/expsil [id] [miktar]` | `group.admin` | EXP çıkarır (seviye gerekirse düşer) |
| `/expayarla [id] [toplam]` | `group.admin` | Toplam EXP'yi ayarlar |

- Komutlar sunucu konsolundan da kullanılabilir (ör. `expekle 12 50`).
- Miktar tam sayı olmalı ve en fazla 8.760 olabilir. Ondalıklı, negatif veya metin girdi reddedilir.
- **Tüm yetkili işlemleri `loe_exp_logs` tablosuna yazılır:** işlemi yapan (lisans + karakter adı), hedef karakter (citizenid + ad), miktar, eski/yeni seviye ve eski/yeni EXP.

## Geliştirici API'si

### Qbox metadata (en kolay yol)

```lua
-- client (ör. HUD)
local pd = exports.qbx_core:GetPlayerData()
local level = pd.metadata.level
local exp   = pd.metadata.exp

-- server
local player = exports.qbx_core:GetPlayer(source)
local level = player.PlayerData.metadata.level
```

Metadata yalnızca EXP / seviye değiştiğinde (saatte bir) güncellenir. Asıl kayıt `loe_exp` tablosundadır.

### Sunucu export'ları

```lua
exports.loe_exp:GetLevel(source)                          -- number | nil
exports.loe_exp:GetTotalExp(source)                       -- number | nil
exports.loe_exp:GetPlayerData(source)                     -- table | nil
-- { level, totalExp, currentExp, requiredExp, maxLevel, isMaxLevel,
--   activeMinutes, intervalMinutes, totalActiveMinutes }

local ok, levelOrError, total = exports.loe_exp:AddExp(source, 5, 'gorev_odulu')
local ok, levelOrError, total = exports.loe_exp:RemoveExp(source, 3, 'ceza')
local ok, levelOrError, total = exports.loe_exp:SetExp(source, 2122, 'aktarim')
local ok, level = exports.loe_exp:RecalculateLevel(source)
-- hata kodları: 'not_loaded' | 'invalid_amount' | 'max_level' | 'no_exp'

exports.loe_exp:IsPlayerAfk(source)
exports.loe_exp:GetRequiredXP(level)
exports.loe_exp:GetTotalExpForLevel(level)
exports.loe_exp:GetMaxLevel()
```

Örnek, bir mesleğe seviye şartı koymak için:

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
-- AddEventHandler kullanın, RegisterNetEvent KULLANMAYIN (istemciler taklit edebilir)
AddEventHandler('loe_exp:onPlayerLoaded', function(source, data) end)
AddEventHandler('loe_exp:onExpChanged', function(source, totalExp, delta, reason) end)
AddEventHandler('loe_exp:onLevelChanged', function(source, newLevel, oldLevel) end)
```

`reason`: `'playtime'`, `'admin:add'`, `'admin:remove'`, `'admin:set'`, `'recalculate'` veya çağrıda verilen metin.

### İstemci (salt okunur)

```lua
exports.loe_exp:GetLevel()
exports.loe_exp:GetData()   -- currentExp / requiredExp / activeMinutes dahil

AddEventHandler('loe_exp:client:onDataUpdated', function(data) end)
```

> Seviyeye bağlı kontrolleri **her zaman sunucuda** yapın. İstemci verisi yalnızca gösterim içindir.

## Veritabanı

`sql/loe_exp.sql` iki tablo oluşturur. Qbox tablolarına dokunulmaz.

**`loe_exp`**

| Sütun | Açıklama |
|---|---|
| `identifier` (PK) | Karakterin `citizenid`'si |
| `level` | Seviye (toplam EXP'den hesaplanır) |
| `total_exp` | Toplam EXP (doğruluk kaynağı) |
| `active_seconds` | Bir sonraki EXP için biriken aktif süre (saniye) |
| `total_active_seconds` | Toplam aktif oyun süresi (istatistik) |
| `last_name` | Son bilinen karakter adı |
| `created_at`, `updated_at` | Zaman damgaları |

**`loe_exp_logs`**: `action`, `actor_identifier`, `actor_name`, `target_identifier`, `target_name`, `amount`, `old_level`, `new_level`, `old_exp`, `new_exp`, `note`, `created_at`

```sql
-- En yüksek 10 karakter
SELECT last_name, level, total_exp FROM loe_exp ORDER BY total_exp DESC LIMIT 10;

-- Son 50 yetkili işlemi
SELECT * FROM loe_exp_logs ORDER BY id DESC LIMIT 50;
```

## Güvenlik

- İstemciye açık **yalnızca iki** ağ olayı vardır:
  - `loe_exp:server:activity`: yalnızca bir sayı alır. Tip ve aralık kontrolünden geçer, hız sınırı vardır. EXP veya seviye belirleyemez.
  - `loe_exp:server:requestSync`: oyuncuya yalnızca **kendi** verisini gönderir.
- EXP değiştiren event'ler `AddEventHandler` ile kayıtlıdır, istemciden tetiklenemez.
- Yetkili komutları ox_lib `restricted` ile `group.admin`'e kısıtlıdır.
- Tüm SQL sorguları parametrelidir (`?`).

## Testler

Sunucu kodu, FiveM + oxmysql + Qbox + ox_lib'i taklit eden bir ortamda Lua 5.4 ile uçtan uca test edilir:

```bash
lua5.4 tests/run_tests.lua
```

## Sorun giderme

| Belirti | Çözüm |
|---|---|
| Oyuncular EXP kazanmıyor | `Config.Debug = true` yapıp konsolu izleyin. `HeartbeatSeconds`, `TimeoutMinutes * 60`'tan küçük olmalı. |
| Uzun süre kıpırdamadan RP yapan oyuncular süre kaybediyor | `Config.Afk.ServerCheck.StillMinutes` değerini artırın. |
| Yetkili komutu çalışmıyor | Yetkilinin `group.admin` grubunda olduğundan emin olun (`add_principal identifier.license:xxx group.admin`). |
| `sql/loe_exp.sql okunamadı` | SQL'i elle çalıştırıp `Config.AutoCreateTables = false` yapın. |
