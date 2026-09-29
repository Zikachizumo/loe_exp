--[[
    loe_exp / tests / mock_client
    client/cl_main.lua'yı GTA native'leri, ox_lib cache'i ve Qbox isLoggedIn taklidiyle çalıştırır.
    Oyun durumu (kamera, konum, konuşma, tuş, NUI imleci, araç koltuğu) test içinden değiştirilir.

    Bu dosya fxmanifest.lua'da yer almaz, oyuna yüklenmez.
]]

local MockClient = {}
MockClient.__index = MockClient

local vecmt = {}
vecmt.__index = vecmt
local function vec(x, y, z)
    return setmetatable({ x = x, y = y, z = z }, vecmt)
end
vecmt.__sub = function(a, b) return vec(a.x - b.x, a.y - b.y, a.z - b.z) end
vecmt.__len = function(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end
MockClient.vec = vec

---@param opts? { root?: string, configure?: fun(Config: table) }
function MockClient.new(opts)
    opts = opts or {}
    local self = setmetatable({}, MockClient)
    self.root = opts.root or '.'
    self.ms = 0
    self.threads = {}
    self.handlers = {}
    self.serverEvents = {}
    self.exported = {}
    self.state = {
        cam = vec(0, 0, 0),
        coords = vec(0, 0, 0),
        talking = false,
        pressed = {},
        idleCam = false,
        nuiFocus = false,
        cursor = { 500, 400 },
    }

    _G.Config = nil
    assert(loadfile(self.root .. '/config.lua'))()
    if opts.configure then opts.configure(Config) end

    local client = self
    _G.cache = { ped = 100, playerId = 1, vehicle = false, seat = false }
    _G.LocalPlayer = { state = { isLoggedIn = false } }
    _G.GetGameTimer = function() return client.ms end
    _G.GetGameplayCamRot = function() local c = client.state.cam; return vec(c.x, c.y, c.z) end
    _G.GetEntityCoords = function() local c = client.state.coords; return vec(c.x, c.y, c.z) end
    _G.NetworkIsPlayerTalking = function() return client.state.talking end
    _G.IsControlPressed = function(_, control) return client.state.pressed[control] == true end
    _G.IsDisabledControlPressed = function() return false end
    _G.IsCinematicIdleCamRendering = function() return client.state.idleCam end
    _G.IsNuiFocused = function() return client.state.nuiFocus end
    _G.GetNuiCursorPosition = function() return client.state.cursor[1], client.state.cursor[2] end
    _G.TriggerServerEvent = function(name, ...)
        client.serverEvents[#client.serverEvents + 1] = { name = name, at = client.ms, args = { ... } }
    end
    _G.RegisterNetEvent = function(name, fn) client.handlers[name] = fn end
    _G.TriggerEvent = function() end
    _G.exports = function(name, fn) client.exported[name] = fn end
    _G.CreateThread = function(fn) client:Spawn(fn) end
    _G.Wait = function(ms) coroutine.yield(ms) end

    assert(loadfile(self.root .. '/client/cl_main.lua'))()
    return self
end

function MockClient:Spawn(fn)
    local co = coroutine.create(fn)
    local ok, wait = coroutine.resume(co)
    assert(ok, wait)
    if coroutine.status(co) == 'suspended' then
        self.threads[#self.threads + 1] = { co = co, at = self.ms + (wait or 0) }
    end
end

function MockClient:Advance(ms)
    local target = self.ms + ms
    while true do
        local index, at
        for i, t in ipairs(self.threads) do
            if t.at <= target and (not at or t.at < at) then index, at = i, t.at end
        end
        if not index then break end
        self.ms = math.max(self.ms, at)
        local t = table.remove(self.threads, index)
        local ok, wait = coroutine.resume(t.co)
        assert(ok, wait)
        if coroutine.status(t.co) == 'suspended' then
            self.threads[#self.threads + 1] = { co = t.co, at = self.ms + (wait or 0) }
        end
    end
    self.ms = target
end

--- Her saniye durumu güncelleyerek ilerler: fn(saniye) oyun durumunu değiştirir.
function MockClient:Simulate(seconds, fn)
    for i = 1, seconds do
        if fn then fn(i) end
        self:Advance(1000)
    end
end

function MockClient:Events(name)
    local out = {}
    for _, event in ipairs(self.serverEvents) do
        if event.name == name then out[#out + 1] = event end
    end
    return out
end

--- Son aktivite bildirimindeki boşta süresi (sn)
function MockClient:LastIdle()
    local beats = self:Events('loe_exp:server:activity')
    return beats[#beats] and beats[#beats].args[1]
end

--- Sunucudan seviye verisi gelir (karakter yüklendi)
function MockClient:Sync()
    LocalPlayer.state.isLoggedIn = true
    self.handlers['loe_exp:client:sync']({ level = 1 })
end

function MockClient:Unload()
    LocalPlayer.state.isLoggedIn = false
    self.handlers['loe_exp:client:unloaded']()
end

return MockClient
