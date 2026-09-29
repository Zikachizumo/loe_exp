--[[
    loe_exp / shared / level

    Seviye, toplam EXP'den türetilir. Veritabanındaki seviye sütunu yalnızca sorgu kolaylığı içindir;
    doğruluk kaynağı her zaman toplam EXP'dir.
]]

LoeLevel = {}

local MAX_LEVEL = math.max(1, math.floor(tonumber(Config.MaxLevel) or 100))
LoeLevel.MaxLevel = MAX_LEVEL

--- Mevcut seviyeden bir sonraki seviyeye geçmek için gereken EXP.
--- LOE denge formülü: 1 -> 100 toplamı tam 8.760 EXP (= 8.760 aktif oyun saati) olacak şekilde ayarlanmıştır.
--- Gereksinim her seviyede ~1,8 EXP artar, iki katına çıkmaz.
---@param currentLevel number
---@return number
function LoeLevel.GetRequiredXP(currentLevel)
    return math.max(
        1,
        math.floor((currentLevel * 1.808) - 1.93 + 0.5)
    )
end

-- Her seviyeye ulaşmak için gereken TOPLAM EXP bir kez hesaplanıp önbelleğe alınır.
-- thresholds[1] = 0, thresholds[10] = 65, thresholds[100] = 8760
local thresholds = { [1] = 0 }
for level = 2, MAX_LEVEL do
    thresholds[level] = thresholds[level - 1] + LoeLevel.GetRequiredXP(level - 1)
end

--- Verilen seviyeye ulaşmak için gereken toplam EXP.
---@param level number
---@return number
function LoeLevel.GetTotalExpForLevel(level)
    level = math.floor(tonumber(level) or 1)
    if level ~= level or level < 1 then
        level = 1
    elseif level > MAX_LEVEL then
        level = MAX_LEVEL
    end
    return thresholds[level]
end

--- Maksimum seviyeye karşılık gelen toplam EXP (bir oyuncunun sahip olabileceği en yüksek EXP).
---@return number
function LoeLevel.GetMaxTotalExp()
    return thresholds[MAX_LEVEL]
end

--- Toplam EXP'den seviyeyi DÖNGÜ ile hesaplar.
--- Oyuncu aynı anda birden fazla seviyeye yetecek EXP almışsa her seviye sırayla atlanır.
---@param totalExp number
---@return number level Seviye
---@return number remaining Mevcut seviyede biriken (bir sonraki seviyeye sayılan) EXP
function LoeLevel.CalculateLevel(totalExp)
    local remaining = math.floor(tonumber(totalExp) or 0)
    if remaining ~= remaining or remaining < 0 then
        remaining = 0
    end

    local level = 1
    while level < MAX_LEVEL do
        local required = LoeLevel.GetRequiredXP(level)
        if remaining < required then
            break
        end
        remaining = remaining - required
        level = level + 1
    end

    return level, remaining
end

--- Seviye ilerleme bilgisi.
---@param totalExp number
---@return number level
---@return number current Mevcut seviyede biriken EXP (maks. seviyede 0)
---@return number required Sonraki seviye için gereken EXP (maks. seviyede 0)
function LoeLevel.GetProgress(totalExp)
    local level, current = LoeLevel.CalculateLevel(totalExp)
    if level >= MAX_LEVEL then
        return level, 0, 0
    end
    return level, current, LoeLevel.GetRequiredXP(level)
end

--- Dışarıdan gelen değeri güvenli tam sayıya çevirir.
--- Sayı olmayan, NaN, sonsuz veya ondalıklı değerler için nil döner.
---@param value any
---@return integer|nil
function LoeLevel.ToInteger(value)
    local number = tonumber(value)
    if not number or number ~= number or number == math.huge or number == -math.huge then
        return nil
    end
    if number ~= math.floor(number) then
        return nil
    end
    return math.tointeger(number)
end
