--[[
    loe_exp / tests / mock_fivem
    FiveM sunucu native'lerini, olay sistemini, iş parçacıklarını (CreateThread / Wait / SetTimeout),
    promise + Citizen.Await'i, sahte saati (os.time), oxmysql'i, Qbox'ı (exports.qbx_core,
    oyuncu olayları, isLoggedIn, metadata) ve ox_lib'i (lib.addCommand, ox_lib:notify) taklit eder.

    Veritabanı taklidi gerçek davranışa yakındır:
      - STRICT mod: sütun uzunluğunu aşan değer sorguyu reddeder (MariaDB 10.11 ile doğrulandı)
      - transaction: bir sorgu reddedilirse tamamı geri alınır ve false döner
      - dbLatencyMs: .await çağrıları bu kadar bekler (gerçek eşzamansızlık)
      - dbHang: oxmysql'in bağlantı kuramadığında hiç cevap vermemesi (await sonsuza kadar bekler)

    Bu dosya fxmanifest.lua'da yer almaz, oyuna yüklenmez.
]]

local Mock = {}
Mock.__index = Mock

-- fxmanifest.lua'daki sunucu yükleme sırası (shared + server)
Mock.ServerFiles = {
    'config.lua',
    'shared/sh_level.lua',
    'server/sv_qbox.lua',
    'server/sv_database.lua',
    'server/sv_logs.lua',
    'server/sv_main.lua',
    'server/sv_exports.lua',
    'server/sv_commands.lua',
}

-- sql/loe_exp.sql sütun uzunlukları (STRICT mod taklidi)
local COLUMN_LIMITS = {
    player = { [1] = 64, [6] = 100 },                                     -- identifier, last_name
    log = { [1] = 32, [2] = 64, [3] = 100, [4] = 64, [5] = 100, [11] = 255 }, -- action ... note
}

local realTime = os.time

local function Copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

-- Veritabanının reddettiği sorgu (kod hatasından ayırt etmek için)
local DbError = {}
DbError.__index = DbError
DbError.__tostring = function(e) return e.message end
local function RaiseDb(message)
    error(setmetatable({ message = message }, DbError), 0)
end
local function IsDbError(err)
    return getmetatable(err) == DbError
end

function Mock.NewDatabase()
    return { players = {}, logs = {}, schemaRuns = 0, writes = 0, transactions = 0 }
end

---@param opts? { root?: string, db?: table, configure?: fun(Config: table) }
function Mock.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Mock)
    self.root = opts.root or '.'
    self.configure = opts.configure
    self.clock = 1700000000
    self.clockBase = self.clock
    self.ms = 0
    self.threads = {}
    self.handlers = {}
    self.netEvents = {}
    self.commands = {}
    self.exported = {}
    self.clientEvents = {}
    self.players = {}
    self.db = opts.db or Mock.NewDatabase()
    self.dbFail = false
    self.dbHang = false
    self.dbLatencyMs = 0
    self.failIdentifiers = {}
    self.lostQueries = 0
    self.getPlayerCalls = 0
    self.logs = {}
    self.invoker = nil
    self.oneSync = true
    self.resourceStates = opts.resourceStates or { oxmysql = 'started', ox_lib = 'started', qbx_core = 'started' }
    self:InstallGlobals()
    return self
end

------------------------------------------------------------------------
-- İş parçacıkları ve zaman (olay güdümlü)
------------------------------------------------------------------------
function Mock:Spawn(fn, ...)
    local co = coroutine.create(fn)
    self:Resume(co, ...)
end

function Mock:Resume(co, ...)
    local ok, waitMs = coroutine.resume(co, ...)
    if not ok then
        error(debug.traceback(co, tostring(waitMs)), 0)
    end
    if coroutine.status(co) == 'suspended' then
        self.threads[#self.threads + 1] = { co = co, wakeAt = self.ms + (waitMs or 0) }
    end
end

--- Sahte saati ilerletir. Bekleyen iş parçacıkları uyanma sırasına göre, kendi zamanlarında çalışır.
function Mock:Advance(seconds)
    local target = self.ms + math.floor(seconds * 1000)
    while true do
        local index, wakeAt
        for i = 1, #self.threads do
            local t = self.threads[i]
            if t.wakeAt <= target and (not wakeAt or t.wakeAt < wakeAt) then
                index, wakeAt = i, t.wakeAt
            end
        end
        if not index then
            break
        end
        if wakeAt > self.ms then
            self.ms = wakeAt
            self.clock = self.clockBase + self.ms // 1000
        end
        local thread = table.remove(self.threads, index)
        self:Resume(thread.co)
    end
    self.ms = target
    self.clock = self.clockBase + self.ms // 1000
end

------------------------------------------------------------------------
-- Olaylar
------------------------------------------------------------------------
function Mock:Dispatch(name, eventSource, ...)
    local list = self.handlers[name]
    if not list then
        return
    end
    local args = table.pack(...)
    for i = 1, #list do
        local handler = list[i]
        self:Spawn(function()
            local previous = _G.source
            _G.source = eventSource
            handler(table.unpack(args, 1, args.n))
            _G.source = previous
        end)
    end
end

--- İstemciden sunucuya ağ olayı (yalnızca RegisterNetEvent ile kayıtlı olaylar kabul edilir).
function Mock:ClientEvent(src, name, ...)
    if not self.netEvents[name] then
        return false
    end
    self:Dispatch(name, src, ...)
    return true
end

--- ox_lib lib.addCommand davranışı: restricted grup kontrolü (FiveM ACE) ve parametre eşleme.
---@return boolean çalıştırıldı mı
function Mock:Command(src, name, args)
    local command = self.commands[name]
    assert(command, 'komut yok: ' .. name)

    if command.restricted and src ~= 0 then
        local player = self.players[src]
        if not (player and player.groups[command.restricted]) then
            return false
        end
    end

    args = args or {}
    local parsed = {}
    for i, param in ipairs(command.properties.params or {}) do
        if args[i] == nil and not param.optional then
            return false
        end
        parsed[param.name] = args[i]
    end

    self:Spawn(function()
        command.handler(src, parsed, name)
    end)
    return true
end

function Mock:Export(name, ...)
    local fn = self.exported[name]
    assert(fn, 'export yok: ' .. name)
    return fn(...)
end

function Mock:ClientEventsFor(src, name)
    local out = {}
    for _, event in ipairs(self.clientEvents) do
        if event.target == src and (not name or event.name == name) then
            out[#out + 1] = event
        end
    end
    return out
end

--- Oyuncuya giden ox_lib bildirim metinleri
function Mock:Notifications(src)
    local out = {}
    for _, event in ipairs(self:ClientEventsFor(src, 'ox_lib:notify')) do
        out[#out + 1] = event.args[1].description
    end
    return out
end

------------------------------------------------------------------------
-- Oyuncu yardımcıları
------------------------------------------------------------------------

--- Qbox oyuncu nesnesi (exports.qbx_core:GetPlayer). Karakter seçilmemişse nil.
--- Gerçekte resource'lar arası export nesneyi kopyalar; burada da kopya döner.
function Mock:QbxPlayer(src)
    local player = self.players[tonumber(src)]
    if not player or not player.loggedIn then
        return nil
    end
    return {
        PlayerData = {
            source = tonumber(src),
            citizenid = player.citizenid,
            charinfo = { firstname = player.firstname, lastname = player.lastname },
            metadata = Copy(player.metadata),
        },
    }
end

--- Oyuncu bağlanır ve karakterini seçer (QBCore:Server:PlayerLoaded).
function Mock:AddPlayer(src, opts)
    opts = opts or {}
    self.players[src] = {
        name = opts.name or ('Oyuncu' .. src),
        license = opts.license or ('license:' .. src),
        groups = opts.groups or {},
        coords = { x = 0.0, y = 0.0, z = 0.0 },
        heading = 0.0,
        loggedIn = false,
        metadata = {},
        metaWrites = 0,
    }
    self:Login(src, opts)
end

--- Karakter seçimi (multichar).
function Mock:Login(src, opts)
    opts = opts or {}
    local player = self.players[src]
    player.citizenid = opts.citizenid or ('CID' .. src)
    player.firstname = opts.firstname or ('Oyuncu' .. src)
    player.lastname = opts.lastname or 'Test'
    player.metadata = opts.metadata or {}
    player.loggedIn = true
    self:Dispatch('QBCore:Server:PlayerLoaded', '', self:QbxPlayer(src))
end

--- Karakterden çıkış (QBCore:Server:OnPlayerUnload).
function Mock:Logout(src)
    self.players[src].loggedIn = false
    self:Dispatch('QBCore:Server:OnPlayerUnload', '', src)
end

function Mock:Drop(src)
    self:Dispatch('playerDropped', src, 'Exiting')
    self.players[src] = nil
end

function Mock:Heartbeat(src, idle)
    return self:ClientEvent(src, 'loe_exp:server:activity', idle)
end

--- Oyuncuyu bir yere yürütür (sunucu taraflı hareket kontrolü için).
function Mock:Move(src)
    local player = self.players[src]
    player.coords = { x = player.coords.x + 5.0, y = player.coords.y, z = player.coords.z }
end

--- Oyuncu aktif şekilde oynar: her adımda hareket eder ve idle = 0 bildirir.
function Mock:PlayActive(src, seconds, step)
    step = step or 30
    local elapsed = 0
    while elapsed < seconds do
        self:Advance(step)
        self:Move(src)
        self:Heartbeat(src, 0)
        elapsed = elapsed + step
    end
end

--- Resource'u başlatır (sunucu dosyalarını fxmanifest sırasıyla yükler).
function Mock:Boot()
    for _, file in ipairs(Mock.ServerFiles) do
        local chunk = assert(loadfile(self.root .. '/' .. file))
        chunk()
        if file == 'config.lua' and self.configure then
            self.configure(Config)
        end
    end
    -- Başlangıçtaki Wait(2000) geçilir
    self:Advance(3)
end

function Mock:StopResource()
    self:Dispatch('onResourceStop', '', 'loe_exp')
end

------------------------------------------------------------------------
-- Sahte oxmysql
------------------------------------------------------------------------
local function CheckParams(query, params)
    local _, expected = query:gsub('%?', '')
    params = params or {}
    for i = 1, expected do
        assert(params[i] ~= nil, ('sorgu parametresi #%d nil: %s'):format(i, query))
    end
    assert(#params == expected, ('parametre sayısı uyuşmuyor (%d / %d): %s'):format(#params, expected, query))
end

local function CheckLengths(limits, params)
    for index, limit in pairs(limits) do
        local value = params[index]
        if type(value) == 'string' then
            local length = utf8.len(value)
            if not length or length > limit then
                RaiseDb(('Data too long for column #%d'):format(index))
            end
        end
    end
end

function Mock:Execute(query, params)
    if self.dbFail then
        RaiseDb('sahte veritabanı hatası')
    end
    local db = self.db

    if query:find('CREATE TABLE', 1, true) then
        db.schemaRuns = db.schemaRuns + 1
        return {}
    end

    CheckParams(query, params)

    if query:find('^%s*SELECT') and query:find('FROM `loe_exp`', 1, true) then
        local row = db.players[params[1]]
        return row and Copy(row) or nil
    end

    if query:find('INSERT IGNORE INTO `loe_exp`', 1, true) then
        CheckLengths({ [1] = 64, [2] = 100 }, params)
        if db.players[params[1]] then
            return 0
        end
        db.players[params[1]] = {
            identifier = params[1], level = 1, total_exp = 0, active_seconds = 0,
            total_active_seconds = 0, last_name = params[2],
        }
        return 1
    end

    if query:find('INSERT INTO `loe_exp` ', 1, true) and query:find('ON DUPLICATE KEY UPDATE', 1, true) then
        CheckLengths(COLUMN_LIMITS.player, params)
        if self.failIdentifiers[params[1]] then
            RaiseDb('sahte satır hatası: ' .. params[1])
        end
        db.players[params[1]] = {
            identifier = params[1], level = params[2], total_exp = params[3], active_seconds = params[4],
            total_active_seconds = params[5], last_name = params[6],
        }
        db.writes = db.writes + 1
        return 1
    end

    if query:find('INSERT INTO `loe_exp_logs`', 1, true) then
        CheckLengths(COLUMN_LIMITS.log, params)
        db.logs[#db.logs + 1] = {
            action = params[1], actor_identifier = params[2], actor_name = params[3],
            target_identifier = params[4], target_name = params[5], amount = params[6],
            old_level = params[7], new_level = params[8], old_exp = params[9], new_exp = params[10], note = params[11],
        }
        return #db.logs
    end

    error('işlenmeyen sorgu: ' .. query)
end

--- oxmysql rawTransaction: bir sorgu reddedilirse hepsi geri alınır ve false döner.
function Mock:Transaction(queries)
    if self.dbFail then
        return false
    end
    local backup = {}
    for k, v in pairs(self.db.players) do backup[k] = Copy(v) end
    local writes = self.db.writes
    for _, entry in ipairs(queries) do
        local ok, err = pcall(self.Execute, self, entry.query, entry.values)
        if not ok then
            if not IsDbError(err) then
                error(err, 0) -- kod hatası: testi düşür
            end
            self.db.players = backup
            self.db.writes = writes
            return false
        end
    end
    self.db.transactions = self.db.transactions + 1
    return true
end

--- .await çağrılarında gecikme / asılma
function Mock:AwaitDb()
    if not coroutine.isyieldable() then
        return
    end
    if self.dbHang then
        coroutine.yield(math.huge) -- oxmysql: bağlantı yoksa cevap hiç gelmez
    end
    if self.dbLatencyMs > 0 then
        coroutine.yield(self.dbLatencyMs)
    end
end

function Mock:BuildMySQL()
    local mock = self

    local function Method(run)
        return setmetatable({
            await = function(q, p)
                mock:AwaitDb()
                return run(q, p)
            end,
        }, {
            __call = function(_, q, p, cb)
                -- Beklemeyen çağrı: veritabanı hatası oxmysql tarafından yalnızca loglanır
                local ok, result = pcall(run, q, p)
                if not ok then
                    if not IsDbError(result) then error(result, 0) end
                    mock.lostQueries = mock.lostQueries + 1
                    result = nil
                end
                if type(cb) == 'function' then cb(result) end
            end,
        })
    end

    local function Run(q, p) return mock:Execute(q, p) end

    return {
        query = Method(Run),
        single = Method(Run),
        insert = Method(Run),
        update = Method(Run),
        transaction = Method(function(queries) return mock:Transaction(queries) end),
    }
end

------------------------------------------------------------------------
-- Global native'ler
------------------------------------------------------------------------
function Mock:InstallGlobals()
    local mock = self
    _G.source = nil
    _G.Config = nil

    os.time = function(t)
        if t then return realTime(t) end
        return mock.clock
    end

    _G.MySQL = self:BuildMySQL()

    _G.CreateThread = function(fn) mock:Spawn(fn) end
    _G.Wait = function(ms)
        if coroutine.isyieldable() then
            coroutine.yield(ms)
        end
    end
    _G.SetTimeout = function(ms, fn)
        mock:Spawn(function()
            coroutine.yield(ms)
            fn()
        end)
    end

    -- FiveM deferred.lua: promise yalnızca bekleme durumundayken çözülür
    _G.promise = {
        new = function()
            local p = { state = 0 }
            function p:resolve(value)
                if self.state == 0 then self.state, self.value = 1, value end
            end
            function p:reject(value)
                if self.state == 0 then self.state, self.value = 2, value end
            end
            return p
        end,
    }
    _G.Citizen = {
        Await = function(p)
            while p.state == 0 do
                coroutine.yield(100)
            end
            if p.state == 2 then error(p.value, 2) end
            return p.value
        end,
    }

    _G.AddEventHandler = function(name, fn)
        mock.handlers[name] = mock.handlers[name] or {}
        table.insert(mock.handlers[name], fn)
    end
    _G.RegisterNetEvent = function(name, fn)
        mock.netEvents[name] = true
        if fn then _G.AddEventHandler(name, fn) end
    end
    _G.TriggerEvent = function(name, ...) mock:Dispatch(name, '', ...) end
    _G.TriggerClientEvent = function(name, target, ...)
        table.insert(mock.clientEvents, { name = name, target = target, args = table.pack(...) })
    end

    -- ox_lib: gerçek sürüm gibi restricted bilgisini kayıttan sonra properties'ten siler
    _G.lib = {
        addCommand = function(name, properties, handler)
            mock.commands[name] = { properties = properties, handler = handler, restricted = properties.restricted }
            properties.restricted = nil
        end,
    }

    -- Qbox
    local qbxExports = {
        GetPlayer = function(_, src)
            mock.getPlayerCalls = mock.getPlayerCalls + 1
            return mock:QbxPlayer(src)
        end,
        SetMetadata = function(_, src, key, value)
            local player = mock.players[tonumber(src)]
            if player and player.loggedIn then
                player.metadata[key] = value
                player.metaWrites = player.metaWrites + 1
            end
        end,
    }
    _G.Player = function(src)
        local player = mock.players[tonumber(src)]
        return { state = { isLoggedIn = player ~= nil and player.loggedIn or nil } }
    end

    _G.exports = setmetatable({}, {
        __call = function(_, name, fn) mock.exported[name] = fn end,
        __index = function(_, resource)
            if resource == 'qbx_core' then
                return qbxExports
            end
            return setmetatable({}, { __index = function(_, fnName)
                return function() error(('export yok: %s.%s'):format(resource, fnName)) end
            end })
        end,
    })

    _G.GetCurrentResourceName = function() return 'loe_exp' end
    _G.GetInvokingResource = function() return mock.invoker end
    _G.GetResourceState = function(name) return mock.resourceStates[name] or 'missing' end
    _G.LoadResourceFile = function(_, path)
        local file = io.open(mock.root .. '/' .. path, 'r')
        if not file then return nil end
        local content = file:read('a')
        file:close()
        return content
    end

    _G.GetPlayers = function()
        local list = {}
        for src in pairs(mock.players) do list[#list + 1] = tostring(src) end
        table.sort(list)
        return list
    end
    _G.GetPlayerName = function(src)
        local player = mock.players[tonumber(src)]
        return player and player.name or nil
    end
    _G.GetPlayerIdentifierByType = function(src, kind)
        local player = mock.players[tonumber(src)]
        if player and kind == 'license' then return player.license end
        return nil
    end
    _G.GetPlayerPed = function(src)
        if not mock.oneSync or not mock.players[tonumber(src)] then return 0 end
        return tonumber(src)
    end
    _G.DoesEntityExist = function(ped) return mock.players[ped] ~= nil end
    _G.GetEntityCoords = function(ped) return Copy(mock.players[ped].coords) end
    _G.GetEntityHeading = function(ped) return mock.players[ped].heading end

    -- Konsol çıktılarını sessize al ama sakla
    _G.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        table.insert(mock.logs, table.concat(parts, ' '))
    end
end

return Mock
