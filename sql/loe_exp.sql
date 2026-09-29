-- LOE - loe_exp | Veritabanı kurulumu
-- MariaDB 10.3+ / MySQL 5.7+ ile uyumludur.
-- Config.AutoCreateTables = true ise bu dosya sunucu açılışında otomatik çalıştırılır.
-- Not: Bu dosyadaki yorumlarda noktalı virgül kullanmayın (otomatik kurulum ifadeleri noktalı virgülden ayırır).

-- Oyuncu ilerlemesi
--   identifier            : Karakter kimliği (ESX identifier / QBCore-Qbox citizenid) veya license
--   level                 : Seviye (toplam EXP'den hesaplanır, sorgu kolaylığı için saklanır)
--   total_exp             : Toplam EXP (doğruluk kaynağı)
--   active_seconds        : Bir sonraki EXP için biriken aktif süre (saniye)
--   total_active_seconds  : Toplam aktif oyun süresi (istatistik)
CREATE TABLE IF NOT EXISTS `loe_exp` (
    `identifier` VARCHAR(64) NOT NULL,
    `level` SMALLINT UNSIGNED NOT NULL DEFAULT 1,
    `total_exp` INT UNSIGNED NOT NULL DEFAULT 0,
    `active_seconds` INT UNSIGNED NOT NULL DEFAULT 0,
    `total_active_seconds` BIGINT UNSIGNED NOT NULL DEFAULT 0,
    `last_name` VARCHAR(100) NOT NULL DEFAULT '',
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`identifier`),
    KEY `idx_loe_exp_level` (`level`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Yetkili (ve istenirse export) işlem logları
CREATE TABLE IF NOT EXISTS `loe_exp_logs` (
    `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
    `action` VARCHAR(32) NOT NULL,
    `actor_identifier` VARCHAR(64) NOT NULL DEFAULT '',
    `actor_name` VARCHAR(100) NOT NULL DEFAULT '',
    `target_identifier` VARCHAR(64) NOT NULL DEFAULT '',
    `target_name` VARCHAR(100) NOT NULL DEFAULT '',
    `amount` INT NOT NULL DEFAULT 0,
    `old_level` SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    `new_level` SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    `old_exp` INT UNSIGNED NOT NULL DEFAULT 0,
    `new_exp` INT UNSIGNED NOT NULL DEFAULT 0,
    `note` VARCHAR(255) NOT NULL DEFAULT '',
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_loe_exp_logs_target` (`target_identifier`),
    KEY `idx_loe_exp_logs_created` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
