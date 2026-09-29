--[[
    LOE - loe_exp | Test ortamı

    FiveM sunucu native'lerini, olay sistemini, iş parçacıklarını (CreateThread / Wait),
    sahte saati (os.time) ve oxmysql'i taklit eder. Böylece sunucu kodu FiveM olmadan,
    düz Lua 5.4 ile uçtan uca test edilebilir.

    Bu dosya fxmanifest.lua'da yer almaz, oyuna yüklenmez.
]]

local Mock = {}
Mock.__index = Mock

-- fxmanifest.lua'daki sunucu yükleme sırası (shared + server)
Mock.ServerFiles = {
    'config.lua',
    'shared/sh_level.lua',
    'config_server.lua',
    'server/sv_bridge.lua',
    'server/sv_database.lua',
    'server/sv_logs.lua',
    'server/sv_main.lua',
    'server/sv_exports.lua',
    'server/sv_commands.lua',
}

local realTime = os.time

local function Copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

function Mock.NewDatabase()
    return { players = {}, logs = {}, schemaRuns = 0, writes = 0 }
end

---@param opts? { root?: string, db?: table, configure?: fun(Config: table), resourceStates?: table }
function Mock.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Mock)
    self.root = opts.root or '.'
    self.configure = opts.configure
    self.clock = 1700000000
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
    self.webhooks = {}
    self.logs = {}
    self.invoker = nil
    self.oneSync = true
    self.resourceStates = opts.resourceStates or { oxmysql = 'started' }
    self:InstallGlobals()
    return self
end

------------------------------------------------------------------------
-- İş parçacıkları
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

function Mock:RunDueThreads()
    local progressed = true
    while progressed do
        progressed = false
        for i = 1, #self.threads do
            local thread = self.threads[i]
            if thread.wakeAt <= self.ms then
                table.remove(self.threads, i)
                self:Resume(thread.co)
                progressed = true
                break
            end
        end
    end
end

--- Sahte saati ilerletir ve zamanı gelen iş parçacıklarını çalıştırır.
function Mock:Advance(seconds)
    self.clock = self.clock + seconds
    self.ms = self.ms + seconds * 1000
    self:RunDueThreads()
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

function Mock:Command(src, name, args)
    local command = self.commands[name]
    assert(command, 'komut yok: ' .. name)
    self:Spawn(function()
        command(src, args or {}, name)
    end)
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

--- Oyuncuya giden bildirim metinleri (native bildirim sistemi)
function Mock:Notifications(src)
    local out = {}
    for _, event in ipairs(self:ClientEventsFor(src, 'loe_exp:client:notify')) do
        out[#out + 1] = event.args[1]
    end
    return out
end

------------------------------------------------------------------------
-- Oyuncu yardımcıları
------------------------------------------------------------------------
function Mock:AddPlayer(src, opts)
    opts = opts or {}
    self.players[src] = {
        name = opts.name or ('Oyuncu' .. src),
        license = opts.license or ('license:' .. src),
        aces = opts.aces or {},
        coords = { x = 0.0, y = 0.0, z = 0.0 },
        heading = 0.0,
    }
    self:Dispatch('playerJoining', src, 'temp:' .. src)
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

function Mock:Execute(query, params)
    if self.dbFail then
        error('sahte veritabanı hatası')
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
        db.players[params[1]] = {
            identifier = params[1], level = params[2], total_exp = params[3], active_seconds = params[4],
            total_active_seconds = params[5], last_name = params[6],
        }
        db.writes = db.writes + 1
        return 1
    end

    if query:find('INSERT INTO `loe_exp_logs`', 1, true) then
        db.logs[#db.logs + 1] = {
            action = params[1], actor_identifier = params[2], actor_name = params[3],
            target_identifier = params[4], target_name = params[5], amount = params[6],
            old_level = params[7], new_level = params[8], old_exp = params[9], new_exp = params[10], note = params[11],
        }
        return #db.logs
    end

    error('işlenmeyen sorgu: ' .. query)
end

function Mock:Transaction(queries)
    if self.dbFail then
        return false
    end
    -- Parametre hataları (kod hatası) yutulmaz, doğrudan testi düşürür
    for _, entry in ipairs(queries) do
        self:Execute(entry.query, entry.values)
    end
    self.db.transactions = (self.db.transactions or 0) + 1
    return true
end

function Mock:BuildMySQL()
    local mock = self

    local function Callable(awaitFn, asyncFn)
        return setmetatable({ await = awaitFn }, {
            __call = function(_, ...) return asyncFn(...) end,
        })
    end

    return {
        query = Callable(function(q, p) return mock:Execute(q, p) end, function(q, p, cb)
            local r = mock:Execute(q, p); if cb then cb(r) end
        end),
        single = Callable(function(q, p) return mock:Execute(q, p) end, function(q, p, cb)
            local r = mock:Execute(q, p); if cb then cb(r) end
        end),
        insert = Callable(function(q, p) return mock:Execute(q, p) end, function(q, p, cb)
            local r = mock:Execute(q, p); if cb then cb(r) end
        end),
        update = Callable(function(q, p) return mock:Execute(q, p) end, function(q, p, cb)
            local r = mock:Execute(q, p); if cb then cb(r) end
        end),
        transaction = Callable(function(queries) return mock:Transaction(queries) end, function(queries, cb)
            local r = mock:Transaction(queries); if type(cb) == 'function' then cb(r) end
        end),
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
    _G.RegisterCommand = function(name, fn) mock.commands[name] = fn end

    _G.exports = setmetatable({}, {
        __call = function(_, name, fn) mock.exported[name] = fn end,
        __index = function(_, resource)
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
    _G.GetPlayerIdentifiers = function(src)
        local player = mock.players[tonumber(src)]
        return player and { player.license } or {}
    end
    _G.IsPlayerAceAllowed = function(src, ace)
        local player = mock.players[tonumber(src)]
        return player ~= nil and player.aces[ace] == true
    end
    _G.GetPlayerPed = function(src)
        if not mock.oneSync or not mock.players[tonumber(src)] then return 0 end
        return tonumber(src)
    end
    _G.DoesEntityExist = function(ped) return mock.players[ped] ~= nil end
    _G.GetEntityCoords = function(ped) return Copy(mock.players[ped].coords) end
    _G.GetEntityHeading = function(ped) return mock.players[ped].heading end

    _G.PerformHttpRequest = function(url, _, method, body)
        table.insert(mock.webhooks, { url = url, method = method, body = body })
    end
    _G.json = { encode = function() return '{}' end }

    -- Konsol çıktılarını sessize al ama sakla
    _G.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        table.insert(mock.logs, table.concat(parts, ' '))
    end
end

return Mock
