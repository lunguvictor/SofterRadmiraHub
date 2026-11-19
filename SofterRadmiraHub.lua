script_name("SofterRadmira Hub")
script_description("SofterRadmira Hub: fishing, trucking, train, hunting, and Svalka")
script_author("SofterRadmira")
script_version("5.2.2")

local imgui    = require("mimgui")
local encoding = require("encoding")
local ffi      = require("ffi")
local inicfg   = require("inicfg")
local raknet   = require("samp.raknet")
local sampfuncs = require("sampfuncs")
local bit = require("bit")
local vkeys = require("vkeys")
local trainbot = {
    enabled = false,
    station = "",
    distance = 99999,
    speed = { min = 0, max = 0 },
    checkpoint = { position = { x = 0, y = 0, z = 0 }, isFinish = false },
    key = 0,
    dissync = false,
    moveToken = 0,
}
local ev = require("lib.samp.events")

local math_floor = math.floor
local math_abs   = math.abs
local math_cos   = math.cos
local math_sin   = math.sin

local OHOTA_KEY_DOWN_MS = 300
local OHOTA_KEY_REPEAT_DELAY_MS = 600
local STILL_ANIMAL_TIMEOUT_SECONDS = 20
local ANIMAL_MOVE_EPSILON = 0.01
local ANIMAL_PICKUP_DISTANCE = 5.0
local CAMERA_MODE_ADDRESS = 0xB6F1A8
local SCREEN_ASPECT_RATIO_ADDRESS = 0xC3EFA4
local CROSSHAIR_OFFSET_X_ADDRESS = 0xB6EC10
local CROSSHAIR_OFFSET_Y_ADDRESS = 0xB6EC14
local BONE_POSITION_ADDRESS = 0x5E4280
local CAMERA_MODE_SNIPER, CAMERA_MODE_RIFLE = 53, 55
local CAMERA_MODE_AIM_3, CAMERA_MODE_AIM_4 = 7, 8
local AIM_CAMERA_MODES = {
    [CAMERA_MODE_SNIPER] = true,
    [CAMERA_MODE_RIFLE] = true,
    [CAMERA_MODE_AIM_3] = true,
    [CAMERA_MODE_AIM_4] = true,
}
local AIM_CROSSHAIR_X, AIM_CROSSHAIR_Y = 339.1, 179.1
local HEAD_BONE_ID = 8
local OHOTA_DEG_TO_RAD = 0.017453292
local OHOTA_PI = 3.14159265
local animalLastState, deadAnimals, collectedDeadAnimals = {}, {}, {}
local animalPickupFinished = false

local getBonePosition = ffi.cast("int (__thiscall*)(void*, float*, int, bool)", BONE_POSITION_ADDRESS)
local function getBodyPartCoordinates(id, handle)
    local pedptr = getCharPointer(handle)
    local vec = ffi.new("float[3]")
    getBonePosition(ffi.cast("void*", pedptr), vec, id, true)
    return vec[0], vec[1], vec[2]
end

local OhotaClicker = {}
OhotaClicker.__index = OhotaClicker

function OhotaClicker:new(button, repeatDelay)
    return setmetatable({
        button = button,
        repeatDelay = repeatDelay,
        running = false,
        keyDown = false,
        generation = 0,
    }, self)
end

function OhotaClicker:Start()
    if self.running then return end
    self.generation = self.generation + 1
    local generation = self.generation
    self.running = true
    lua_thread.create(function()
        while self.running and generation == self.generation do
            setVirtualKeyDown(self.button, true)
            self.keyDown = true
            wait(OHOTA_KEY_DOWN_MS)
            if generation ~= self.generation then return end
            setVirtualKeyDown(self.button, false)
            self.keyDown = false
            wait(self.repeatDelay)
        end
        if generation == self.generation then self.running = false end
    end)
end

function OhotaClicker:Stop()
    self.generation = self.generation + 1
    self.running = false
    if self.keyDown then
        setVirtualKeyDown(self.button, false)
        self.keyDown = false
    end
end

local animalInfo = {
    [15555] = {
        name = "\206\235\229\237\252",
        health = {
            [100] = { 3, 0xFF00FF00 },
            [65] = { 2, 0xFFFF9D00 },
            [30] = { 1, 0xFFFF0000 },
        },
    },
    [15556] = {
        name = "\202\224\225\224\237",
        health = {
            [100] = { 7, 0xFF00FF00 },
            [85] = { 6, 0xFF55E100 },
            [70] = { 5, 0xFFAAC300 },
            [55] = { 4, 0xFFFFA500 },
            [40] = { 3, 0xFFFF6E00 },
            [25] = { 2, 0xFFFF3700 },
            [10] = { 1, 0xFFFF0000 },
        },
    },
}

local ohotaTracerColors = {
    { name = "\199\229\235\184\237\251\233", value = 0xFF00FF00 },
    { name = "\202\240\224\241\237\251\233", value = 0xFFFF3030 },
    { name = "\209\232\237\232\233", value = 0xFF3399FF },
    { name = "\198\184\235\242\251\233", value = 0xFFFFFF00 },
    { name = "\193\229\235\251\233", value = 0xFFFFFFFF },
}
local ohotaLiveLabelColors = {
    { name = "\207\238 \231\228\238\240\238\226\252\254" },
    { name = "\199\229\235\184\237\251\233", value = 0xFF00FF00 },
    { name = "\202\240\224\241\237\251\233", value = 0xFFFF3030 },
    { name = "\209\232\237\232\233", value = 0xFF3399FF },
    { name = "\198\184\235\242\251\233", value = 0xFFFFFF00 },
    { name = "\193\229\235\251\233", value = 0xFFFFFFFF },
}
local ohotaDeadLabelColors = {
    { name = "\209\229\240\251\233", value = 0xFF808080 },
    { name = "\199\229\235\184\237\251\233", value = 0xFF00FF00 },
    { name = "\202\240\224\241\237\251\233", value = 0xFFFF3030 },
    { name = "\209\232\237\232\233", value = 0xFF3399FF },
    { name = "\198\184\235\242\251\233", value = 0xFFFFFF00 },
    { name = "\193\229\235\251\233", value = 0xFFFFFFFF },
}

encoding.default = "CP1251"
local u8 = encoding.UTF8
local function ru(text) return u8:decode(text) end

ffi.cdef[[
int __stdcall MoveFileExA(const char* existing, const char* new, unsigned long flags);
]]

local svalka = {
    configPath = getWorkingDirectory() .. "\\config\\svalka_items.json",
    active = imgui.new.bool(false),
    thickness = imgui.new.int(1),
    textColor = imgui.new.int(1),
    lineColor = imgui.new.int(1),
    settings = { cmd = "svalka", cmdact = "activ.svalka", colortr = 2, colortx = 2, sizetr = 1 },
    whobjects = {},
    items = {},
    itemsByModel = {},
    loaded = false,
    error = nil,
    font = renderCreateFont("Arial", 11, 5),
    colors = {
        u8(ru("Красный")), u8(ru("Оранжевый")), u8(ru("Жёлтый")), u8(ru("Голубой")),
        u8(ru("Синий")), u8(ru("Фиолетовый")), u8(ru("Зелёный")), u8(ru("Светло-зелёный")),
    },
    drawColors = {
        4294641158, 4294670598, 4294441734, 4278640123,
        4278590715, 4287563515, 4278647573, 4281726305,
    },
    base64Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/",
    base64Lookup = {},
}
for i = 1, #svalka.base64Alphabet do
    svalka.base64Lookup[svalka.base64Alphabet:byte(i)] = i - 1
end
svalka.decodeBase64 = function(data)
    local output = {}
    for i = 1, #data, 4 do
        local a = svalka.base64Lookup[data:byte(i)]
        local b = svalka.base64Lookup[data:byte(i + 1)]
        local cByte, dByte = data:byte(i + 2), data:byte(i + 3)
        local c = svalka.base64Lookup[cByte]
        local d = svalka.base64Lookup[dByte]
        if a == nil or b == nil then break end
        local first = a * 4 + math_floor(b / 16)
        if cByte == nil or cByte == 61 then
            output[#output + 1] = string.char(first)
            break
        end
        if c == nil then break end
        local second = (b % 16) * 16 + math_floor(c / 4)
        if dByte == nil or dByte == 61 then
            output[#output + 1] = string.char(first, second)
            break
        end
        if d == nil then break end
        output[#output + 1] = string.char(first, second, (c % 4) * 64 + d)
    end
    return table.concat(output)
end
svalka.colorsConst = imgui.new["const char*"][#svalka.colors](svalka.colors)

svalka.loadConfig = function()
    local file = io.open(svalka.configPath, "rb")
    if not file then
        svalka.error = ru("Не найден файл config\\svalka_items.json")
        return false
    end
    local contents = file:read("*a")
    file:close()
    local ok, data = pcall(decodeJson, contents)
    if not ok or type(data) ~= "table" or type(data.items) ~= "table" then
        svalka.error = ru("Не удалось прочитать список предметов Svalka")
        return false
    end

    if type(data.settings) == "table" then
        for key, value in pairs(data.settings) do svalka.settings[key] = value end
    end
    if type(data.whobjects) == "table" then
        for key, value in pairs(data.whobjects) do svalka.whobjects[key] = value end
    end

    for _, item in ipairs(data.items) do
        if item.model_id == nil or type(item.item_name) ~= "string" then
            svalka.error = ru("В списке Svalka есть запись без модели или названия")
            return false
        end
        item.key = tostring(item.model_id)
        item.checkbox_id = "##" .. item.key
        item.render_name = u8:decode(item.item_name)
        item.enabled = imgui.new.bool(svalka.whobjects[item.key] or false)
        svalka.whobjects[item.key] = item.enabled[0]
        svalka.items[#svalka.items + 1] = item
        svalka.itemsByModel[item.model_id] = item
    end

    svalka.thickness[0] = tonumber(svalka.settings.sizetr) or 1
    svalka.textColor[0] = tonumber(svalka.settings.colortx) or 1
    svalka.lineColor[0] = tonumber(svalka.settings.colortr) or 1
    svalka.loaded = true
    return true
end

svalka.loadConfig()
svalka.openCommand = imgui.new.char[56](svalka.settings.cmd)
svalka.toggleCommand = imgui.new.char[56](svalka.settings.cmdact)

svalka.requestSave = function()
    svalka.saveTime = os.clock() + 1
end

svalka.saveConfig = function()
    if not svalka.loaded then return false end
    svalka.settings.sizetr = svalka.thickness[0]
    svalka.settings.colortx = svalka.textColor[0]
    svalka.settings.colortr = svalka.lineColor[0]

    local file = io.open(svalka.configPath, "rb")
    if not file then
        print("[SofterRadmira Hub] Failed to open Svalka config: " .. svalka.configPath)
        return false
    end
    local contents = file:read("*a")
    file:close()
    local itemsPos = contents:find('"items"', 1, true)
    if not itemsPos then
        print("[SofterRadmira Hub] Svalka config has no items list")
        return false
    end

    local tmpPath = svalka.configPath .. ".tmp"
    local tmp = io.open(tmpPath, "wb")
    if not tmp then
        print("[SofterRadmira Hub] Failed to write temporary Svalka config: " .. tmpPath)
        return false
    end
    local written = tmp:write(string.format('{\r\n  "settings": %s,\r\n  "whobjects": %s,\r\n  ',
        encodeJson(svalka.settings), encodeJson(svalka.whobjects)), contents:sub(itemsPos))
    tmp:close()
    if not written then
        os.remove(tmpPath)
        print("[SofterRadmira Hub] Failed to save Svalka settings")
        return false
    end
    if ffi.C.MoveFileExA(tmpPath, svalka.configPath, 1) == 0 then
        os.remove(tmpPath)
        print("[SofterRadmira Hub] Failed to replace Svalka config")
        return false
    end
    svalka.saveTime = nil
    return true
end

local ImVec2 = imgui.ImVec2
local ImVec4 = imgui.ImVec4
local Cond   = imgui.Cond

local VERSION  = "5.2.1"
local INI_NAME = "SofterRadmiraFish_red.ini"

--================= ��������� =================--
local DEFAULTS = {
    Opacity = 0.97,
    AccentR = 0.92, AccentG = 0.16, AccentB = 0.22,
    HookMin = 65, HookMax = 75, HookDelay = 0,
    Timeout1 = 20, Timeout2 = 5, Timeout3 = 10,
    Watchdog = true,
    PressEnter = true, EnterDelay = 150,
    CloseEsc = true, EscDelay = 100,
    AutoRestart = true,
    StopAfter = 0,
    ChatMsgs = true,
    Notifs = true,
    Hud = true, HudPos = 0,
    MenuKey = 0,
    TruckMax = true, TruckMinPrice = "10000", TruckType = 0, TruckDebug = false,
}

local config = inicfg.load({ Settings = DEFAULTS }, INI_NAME)
if not config.Settings then config.Settings = {} end
for k, v in pairs(DEFAULTS) do
    if config.Settings[k] == nil then config.Settings[k] = v end
end
local cs = config.Settings

local OHOTA_CONFIG_NAME = "Ohota_v_lesy.ini"
local OHOTA_DEFAULTS = {
    Wh = false,
    Players = false,
    HeadDot = false,
    Dead = false,
    Distance = false,
    LiveLabelColor = 1,
    DeadLabelColor = 1,
    Tracers = false,
    TracerColor = 1,
    TracerWidth = 1.5,
    Aim = false,
    AutoY = false,
    Clear = false,
}
local ohotaConfig = inicfg.load({ Ohota = OHOTA_DEFAULTS }, OHOTA_CONFIG_NAME)
if not ohotaConfig or not ohotaConfig.Ohota then
    error("Failed to load configuration: " .. OHOTA_CONFIG_NAME)
end
for key, value in pairs(OHOTA_DEFAULTS) do
    if ohotaConfig.Ohota[key] == nil then ohotaConfig.Ohota[key] = value end
end

local function validOhotaIndex(value, maximum)
    value = math.floor(tonumber(value) or 1)
    if value < 1 or value > maximum then return 1 end
    return value
end

local Ohota = {
    enabled = false,
    wh = imgui.new.bool(ohotaConfig.Ohota.Wh),
    players = imgui.new.bool(ohotaConfig.Ohota.Players),
    headDot = imgui.new.bool(ohotaConfig.Ohota.HeadDot),
    dead = imgui.new.bool(ohotaConfig.Ohota.Dead),
    distance = imgui.new.bool(ohotaConfig.Ohota.Distance),
    liveLabelColor = imgui.new.int(validOhotaIndex(ohotaConfig.Ohota.LiveLabelColor, 6) - 1),
    deadLabelColor = imgui.new.int(validOhotaIndex(ohotaConfig.Ohota.DeadLabelColor, 6) - 1),
    tracers = imgui.new.bool(ohotaConfig.Ohota.Tracers),
    tracerColor = imgui.new.int(validOhotaIndex(ohotaConfig.Ohota.TracerColor, 5) - 1),
    tracerWidth = imgui.new.float(math.max(1, math.min(5, tonumber(ohotaConfig.Ohota.TracerWidth) or 1.5))),
    aim = imgui.new.bool(ohotaConfig.Ohota.Aim),
    autoY = imgui.new.bool(ohotaConfig.Ohota.AutoY),
    clear = imgui.new.bool(ohotaConfig.Ohota.Clear),
    autoYClicker = OhotaClicker:new(vkeys.VK_Y, OHOTA_KEY_REPEAT_DELAY_MS),
    aimHandle = nil,
}

local OHOTA_LIVE_COLORS = {
    u8("\207\238 \231\228\238\240\238\226\252\254"), u8("\199\229\235\184\237\251\233"),
    u8("\202\240\224\241\237\251\233"), u8("\209\232\237\232\233"),
    u8("\198\184\235\242\251\233"), u8("\193\229\235\251\233"),
}
local OHOTA_DEAD_COLORS = {
    u8("\209\229\240\251\233"), u8("\199\229\235\184\237\251\233"),
    u8("\202\240\224\241\237\251\233"), u8("\209\232\237\232\233"),
    u8("\198\184\235\242\251\233"), u8("\193\229\235\251\233"),
}
local OHOTA_TRACER_COLORS = {
    u8("\199\229\235\184\237\251\233"), u8("\202\240\224\241\237\251\233"),
    u8("\209\232\237\232\233"), u8("\198\184\235\242\251\233"),
    u8("\193\229\235\251\233"),
}
local ohotaLiveColorItems = imgui.new["const char*"][#OHOTA_LIVE_COLORS](OHOTA_LIVE_COLORS)
local ohotaDeadColorItems = imgui.new["const char*"][#OHOTA_DEAD_COLORS](OHOTA_DEAD_COLORS)
local ohotaTracerColorItems = imgui.new["const char*"][#OHOTA_TRACER_COLORS](OHOTA_TRACER_COLORS)

local ohotaDirty, ohotaLastSave = false, 0
local function markOhotaDirty() ohotaDirty = true end

local function saveOhotaConfig()
    local settings = ohotaConfig.Ohota
    settings.Wh = Ohota.wh[0]
    settings.Players = Ohota.players[0]
    settings.HeadDot = Ohota.headDot[0]
    settings.Dead = Ohota.dead[0]
    settings.Distance = Ohota.distance[0]
    settings.LiveLabelColor = Ohota.liveLabelColor[0] + 1
    settings.DeadLabelColor = Ohota.deadLabelColor[0] + 1
    settings.Tracers = Ohota.tracers[0]
    settings.TracerColor = Ohota.tracerColor[0] + 1
    settings.TracerWidth = Ohota.tracerWidth[0]
    settings.Aim = Ohota.aim[0]
    settings.AutoY = Ohota.autoY[0]
    settings.Clear = Ohota.clear[0]
    if not inicfg.save(ohotaConfig, OHOTA_CONFIG_NAME) then
        error("Failed to save configuration: " .. OHOTA_CONFIG_NAME)
    end
    ohotaDirty = false
    ohotaLastSave = os.clock()
end

local S = {
    opacity     = imgui.new.float(cs.Opacity),
    accent      = imgui.new.float[3](cs.AccentR, cs.AccentG, cs.AccentB),
    hookMin     = imgui.new.int(cs.HookMin),
    hookMax     = imgui.new.int(cs.HookMax),
    hookDelay   = imgui.new.int(cs.HookDelay),
    t1          = imgui.new.int(cs.Timeout1),
    t2          = imgui.new.int(cs.Timeout2),
    t3          = imgui.new.int(cs.Timeout3),
    watchdog    = imgui.new.bool(cs.Watchdog),
    pressEnter  = imgui.new.bool(cs.PressEnter),
    enterDelay  = imgui.new.int(cs.EnterDelay),
    closeEsc    = imgui.new.bool(cs.CloseEsc),
    escDelay    = imgui.new.int(cs.EscDelay),
    autoRestart = imgui.new.bool(cs.AutoRestart),
    stopAfter   = imgui.new.int(cs.StopAfter),
    chat        = imgui.new.bool(cs.ChatMsgs),
    notifs      = imgui.new.bool(cs.Notifs),
    hud         = imgui.new.bool(cs.Hud),
    hudPos      = imgui.new.int(cs.HudPos),
    menuKey     = imgui.new.int(cs.MenuKey),
    truckMax    = imgui.new.bool(cs.TruckMax),
    truckPrice  = imgui.new.char[128](tostring(cs.TruckMinPrice)),
    truckType   = imgui.new.int(tonumber(cs.TruckType) or 0),
    truckDebug  = imgui.new.bool(cs.TruckDebug),
}

local dirty, lastSave = false, 0
local function markDirty() dirty = true end

local function save_config()
    cs.Opacity = S.opacity[0]
    cs.AccentR, cs.AccentG, cs.AccentB = S.accent[0], S.accent[1], S.accent[2]
    cs.HookMin, cs.HookMax, cs.HookDelay = S.hookMin[0], S.hookMax[0], S.hookDelay[0]
    cs.Timeout1, cs.Timeout2, cs.Timeout3 = S.t1[0], S.t2[0], S.t3[0]
    cs.Watchdog = S.watchdog[0]
    cs.PressEnter, cs.EnterDelay = S.pressEnter[0], S.enterDelay[0]
    cs.CloseEsc, cs.EscDelay = S.closeEsc[0], S.escDelay[0]
    cs.AutoRestart = S.autoRestart[0]
    cs.StopAfter = S.stopAfter[0]
    cs.ChatMsgs, cs.Notifs = S.chat[0], S.notifs[0]
    cs.Hud, cs.HudPos = S.hud[0], S.hudPos[0]
    cs.MenuKey = S.menuKey[0]
    cs.TruckMax = S.truckMax[0]
    cs.TruckMinPrice = ffi.string(S.truckPrice)
    cs.TruckType = S.truckType[0]
    cs.TruckDebug = S.truckDebug[0]
    inicfg.save(config, INI_NAME)
    dirty = false
    lastSave = os.clock()
end

--================= ������ � ������� =================--
local Fonts = { body = nil, bold = nil, smallBold = nil, heading = nil }
local hubLogoTexture

local P = {
    bg       = { 0.035, 0.035, 0.043 },
    card     = { 0.070, 0.068, 0.080 },
    cardHi   = { 0.105, 0.098, 0.113 },
    border   = { 0.155, 0.135, 0.145 },
    borderHi = { 0.280, 0.170, 0.185 },
    text     = { 0.945, 0.935, 0.935 },
    muted    = { 0.620, 0.580, 0.590 },
    dim      = { 0.400, 0.365, 0.375 },
    success  = { 0.298, 0.780, 0.500 },
    warning  = { 0.960, 0.640, 0.200 },
    danger   = { 1.000, 0.280, 0.300 },
    accent   = { 0.92, 0.16, 0.22 },
}

local function update_accent()
    P.accent[1], P.accent[2], P.accent[3] = S.accent[0], S.accent[1], S.accent[2]
end
update_accent()

local function u32(c, a)
    local alpha = a
    if alpha == nil then
        if type(c[4]) == "number" then alpha = c[4] else alpha = 1.0 end
    end
    return imgui.ColorConvertFloat4ToU32(ImVec4(c[1], c[2], c[3], alpha))
end

local function clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

local function now() return getGameTimer() / 1000 end

local function fmtTime(sec)
    sec = math_floor(sec)
    return string.format("%02d:%02d:%02d", math_floor(sec / 3600), math_floor((sec % 3600) / 60), sec % 60)
end

local function text(dl, x, y, col, str, font)
    if font then imgui.PushFont(font) end
    dl:AddText(ImVec2(x, y), col, str)
    if font then imgui.PopFont() end
end

local ohotaTextQueue = {}
local function queueOhotaLabel(label, x, y, color)
    ohotaTextQueue[#ohotaTextQueue + 1] = {
        label = u8(label),
        x = x,
        y = y,
        color = color,
    }
end

local function textWidth(str, font)
    if font then imgui.PushFont(font) end
    local s = imgui.CalcTextSize(str)
    if font then imgui.PopFont() end
    return s.x
end

--================= ����� ��������� =================--
local Log = {}
local function pushLog(msg, kind)
    table.insert(Log, 1, { time = os.date("%H:%M:%S"), msg = msg, kind = kind or "muted" })
    while #Log > 12 do table.remove(Log) end
end

local Notifications = { items = {}, maximum = 4, duration = 3.8 }

function Notifications.push(kind, title, description)
    if not S.notifs[0] then return end
    table.insert(Notifications.items, 1, {
        kind = kind or "info", title = title or "", description = description or "",
        createdAt = now(),
    })
    while #Notifications.items > Notifications.maximum do table.remove(Notifications.items) end
end

function Notifications.color(kind)
    if kind == "success" then return P.success end
    if kind == "warning" then return P.warning end
    if kind == "danger"  then return P.danger  end
    return P.accent
end

local function chatMsg(color, str)
    if S.chat[0] then sampAddChatMessage("{" .. color .. "}" .. ru("[Рыбалка]") .. " {FFFFFF}" .. str, -1) end
end

local function truckChat(str)
    if S.chat[0] then sampAddChatMessage("{FF3B3B}" .. ru("[Дальнобойщик]") .. " {FFFFFF}" .. str, -1) end
end

local function sendBytes(data)
    local bs = raknetNewBitStream()
    for i = 1, #data do raknetBitStreamWriteInt8(bs, data[i]) end
    raknetSendBitStream(bs)
    raknetDeleteBitStream(bs)
end

--================= ������: ������� =================--
local bot = {
    on = false,
    state = 0,
    timer = os.time(),
    startedAt = 0,
    runAccum = 0,
}
local stats = { catches = 0, restarts = 0 }

local STATE_NAMES = {
    [0] = ru("Остановлена"),
    [1] = ru("Ожидание поклёвки"),
    [2] = ru("Подсечка"),
    [3] = ru("Сбор улова"),
}

local function runTime()
    if bot.on then return bot.runAccum + (os.time() - bot.startedAt) end
    return bot.runAccum
end

local pktStart = {215, 2, 0, 0, 0, 0, 0, 21, 0, 0, 0, 79, 110, 80, 108, 97, 121, 101, 114, 67, 108, 105, 101, 110, 116, 83, 105, 100, 101, 75, 101, 121, 2, 0, 0, 0, 100, 18, 0, 0, 0}
local pktHook  = {215, 2, 0, 0, 0, 0, 0, 19, 0, 0, 0, 79, 110, 73, 110, 116, 101, 114, 97, 99, 116, 105, 111, 110, 115, 67, 108, 105, 99, 107, 2, 0, 0, 0, 100, 69, 0, 0, 0}
local pktTake  = {215, 2, 0, 0, 0, 0, 0, 16, 0, 0, 0, 79, 110, 68, 105, 97, 108, 111, 103, 82, 101, 115, 112, 111, 110, 115, 101, 8, 0, 0, 0, 100, 0, 0, 0, 0, 100, 1, 0, 0, 0, 100, 255, 255, 255, 255, 115, 0, 0, 0, 0}

local function sendFishPacket(data) sendBytes(data) end

local function fishRestart()
    bot.state = 1
    bot.timer = os.time()
    sendFishPacket(pktStart)
end

--================= ������: ������������ =================--
local truck = { enabled = false, last = "" }
local stopOhota
local stopTrucking -- Stop the truck module before starting another module

local function startBot()
    if bot.on then return end
    if truck.enabled then stopTrucking(true) end
    if trainbot.enabled then trainbot.stop() end
    if stopOhota then stopOhota(true) end
    if svalka.stop then svalka.stop(true) end
    bot.on = true
    bot.startedAt = os.time()
    fishRestart()
    pushLog(ru("Рыбалка запущена"), "success")
    Notifications.push("success", ru("Рыбалка"), ru("Бот включён"))
    chatMsg("00FF00", ru("Рыбалка запущена."))
end

local function stopBot(reason)
    if not bot.on then return end
    bot.runAccum = runTime()
    bot.on = false
    bot.state = 0
    pushLog(reason or ru("Рыбалка остановлена"), "muted")
    Notifications.push("info", ru("Рыбалка"), reason or ru("Бот выключен"))
    chatMsg("FF0000", reason and (reason .. ".") or ru("Рыбалка остановлена."))
end

local function toggleBot()
    if bot.on then stopBot() else startBot() end
end

svalka.start = function()
    if svalka.active[0] then return end
    if not svalka.loaded then
        Notifications.push("info", ru("Свалка"), svalka.error or ru("Список предметов недоступен"))
        return
    end
    if bot.on then stopBot(ru("Остановлено для запуска Свалки")) end
    if truck.enabled then stopTrucking(true) end
    if trainbot.enabled then trainbot.stop() end
    if stopOhota then stopOhota(true) end
    svalka.active[0] = true
    pushLog(ru("Поиск предметов на свалке запущен"), "success")
    Notifications.push("success", ru("Свалка"), ru("Метки предметов включены"))
end

svalka.stop = function(silent)
    if not svalka.active[0] then return end
    svalka.active[0] = false
    if not silent then
        pushLog(ru("Поиск предметов на свалке остановлен"), "muted")
        Notifications.push("info", ru("Свалка"), ru("Метки предметов выключены"))
    end
end

svalka.toggle = function()
    if svalka.active[0] then svalka.stop() else svalka.start() end
end

svalka.drawObjects = function()
    for _, obj in pairs(getAllObjects()) do
        if isObjectOnScreen(obj) then
            local pX, pY, pZ = getCharCoordinates(playerPed)
            local res, oX, oY, oZ = getObjectCoordinates(obj)
            local soX, soY = convert3DCoordsToScreen(oX, oY, oZ)
            local poX, poY = convert3DCoordsToScreen(pX, pY, pZ)
            local item = svalka.itemsByModel[getObjectModel(obj)]

            if res and item and item.enabled[0]
                and getDistanceBetweenCoords3d(oX, oY, oZ, pX, pY, pZ) > 1.2 then
                local dist = math_floor(getDistanceBetweenCoords3d(oX, oY, oZ, pX, pY, pZ))
                renderDrawLine(poX, poY, soX, soY, svalka.thickness[0],
                    svalka.drawColors[svalka.lineColor[0] + 1])
                renderFontDrawText(svalka.font, string.format("%s {FFFFFF}%dm.", item.render_name, dist),
                    soX, soY, svalka.drawColors[svalka.textColor[0] + 1])
            end
        end
    end
end

local function fishPacket(bs)
    local _style = raknetBitStreamReadInt16(bs)
    local _type = raknetBitStreamReadInt32(bs)
    local l = raknetBitStreamReadInt8(bs)
    local style3 = raknetBitStreamReadInt8(bs)
    local length = raknetBitStreamReadInt32(bs)
    local str = nil
    if length > 0 and length < 10000 then str = raknetBitStreamReadString(bs, length) end
    raknetBitStreamResetReadPointer(bs)

    if not str then return end
    local state = bot.state

    if state == 1 and str:find("updateFishingInfo", 1, true) then
        local percent = 0
        for num in str:gmatch("%d+") do percent = tonumber(num) end
        if percent >= S.hookMin[0] and percent <= S.hookMax[0] then
            bot.state = 2
            bot.timer = os.time()
            local delay = S.hookDelay[0]
            if delay > 0 then
                lua_thread.create(function()
                    wait(delay)
                    if bot.on then sendFishPacket(pktHook) end
                end)
            else
                sendFishPacket(pktHook)
            end
            pushLog(ru("Подсечка на ") .. percent .. "%", "muted")
        end
    end

    -- ����� �������� ������ ��������� ������ �����: �������� ���� ��� �������� � ������
    if state == 2 and str:find("addDialogInQueue", 1, true) then
        sendFishPacket(pktTake)
        bot.state = 3
        bot.timer = os.time()
        stats.catches = stats.catches + 1
        pushLog(ru("Улов получен (#") .. stats.catches .. ")", "success")
        if S.pressEnter[0] or S.closeEsc[0] then
            lua_thread.create(function()
                if S.pressEnter[0] then
                    wait(S.enterDelay[0])
                    setVirtualKeyDown(0x0D, true)
                    wait(60)
                    setVirtualKeyDown(0x0D, false)
                end
                if S.closeEsc[0] then
                    wait(S.escDelay[0])
                    setVirtualKeyDown(0x1B, true)
                    wait(50)
                    setVirtualKeyDown(0x1B, false)
                end
            end)
        end
    end

    if state == 3 and str:find("Interactions[[161", 1, true) then
        if not S.autoRestart[0] then
            stopBot(ru("Остановлено вручную"))
        elseif S.stopAfter[0] > 0 and stats.catches >= S.stopAfter[0] then
            stopBot(ru("Достигнут лимит уловов"))
        else
            fishRestart()
        end
    end
end

--================= ������������: ������ =================--
local LOG_PATH = getWorkingDirectory() .. "\\SofterRadmiraTrucking_debug.log"
local function dbgLog(line)
    if not S.truckDebug[0] then return end
    local f = io.open(LOG_PATH, "a")
    if f then f:write(os.date("%H:%M:%S ") .. line .. "\n"); f:close() end
end

local function rawPacket(bs)
    raknetBitStreamResetReadPointer(bs)
    local n = raknetBitStreamGetNumberOfBytesUsed(bs)
    local t = {}
    for i = 1, n do t[i] = string.char(bit.band(raknetBitStreamReadInt8(bs), 0xFF)) end
    raknetBitStreamResetReadPointer(bs)
    return table.concat(t), n
end

local function hexAscii(str)
    local hex, asc = {}, {}
    for i = 1, #str do
        local b = str:byte(i)
        hex[#hex + 1] = string.format("%02X", b)
        asc[#asc + 1] = (b >= 32 and b < 127) and string.char(b) or "."
    end
    return table.concat(hex, " "), table.concat(asc)
end

local function sendSelectOrder(index0)
    sendBytes({215, 2, 0, 0, 0, 0, 0, 16, 0, 0, 0, 79, 110, 68, 105, 97, 108, 111, 103, 82, 101, 115, 112, 111, 110, 115, 101, 8, 0, 0, 0, 100, 0, 0, 0, 0, 100, 1, 0, 0, 0, 100, index0, 0, 0, 0, 115, 0, 0, 0, 0})
end

local function detectType(order)
    local qty = order:match("<t>(.-)<t>") or ""
    if qty:find(ru("л."), 1, true) then return "fuel" end
    if qty:find(ru("ед."), 1, true) then return "goods" end
    return "unknown"
end

local function truckPacket(bs)
    local raw, n = rawPacket(bs)
    if not raw:find("addDialogInQueue", 1, true) then return end

    local hex, asc = hexAscii(raw:sub(1, 600))
    dbgLog(string.format("PACKET bytes=%d", n))
    dbgLog("  HEX: " .. hex)
    dbgLog("  ASC: " .. asc)

    local cleanText = raw:gsub("%{[%x]+}", ""):gsub("[%c]", "")
    if not cleanText:find("<t>", 1, true) or not cleanText:find("<n>", 1, true) then return end

    local startPos = 1
    local endPos = cleanText:find('", 0)', startPos, true) or cleanText:find('")', startPos, true) or (#cleanText + 1)
    local ordersPart = cleanText:sub(startPos, endPos - 1)

    local payList, nameList, typeList = {}, {}, {}
    for rawOrder in ordersPart:gmatch("(.-)<n>") do
        local order = rawOrder:match("^%s*(.-)%s*$")
        if order ~= "" then
            local pay = order:match("<t>(%d+)%s*" .. ru("руб")) or order:match("<t>(%d+)%s*" .. ru("р"))
            if pay then
                payList[#payList + 1] = tonumber(pay)
                local name = order:match("^(.-)<t>")
                if name then
                    name = name:gsub("%{[%x]+}", ""):gsub("\\'", "'"):match("^%s*(.-)%s*$")
                else
                    name = ru("Заказ ") .. #payList
                end
                nameList[#nameList + 1] = name
                typeList[#typeList + 1] = detectType(order)
            end
        end
    end

    dbgLog("  Orders found: " .. #payList)
    for i = 1, #payList do dbgLog(string.format("   #%d type=%s pay=%d name=%s", i, typeList[i], payList[i], nameList[i])) end
    if #payList == 0 then return end

    local minPay = tonumber(ffi.string(S.truckPrice)) or 0
    local requiredType = (S.truckType[0] == 0) and "goods" or "fuel"

    local bestIndex, bestPay = nil, -1
    local maxIndex, maxPay = nil, -1
    for i, pay in ipairs(payList) do
        if typeList[i] == requiredType then
            if pay > maxPay then maxPay, maxIndex = pay, i end
            if pay > minPay and pay > bestPay then bestPay, bestIndex = pay, i end
        end
    end

    local selected = bestIndex or (S.truckMax[0] and maxIndex or nil)

    if selected then
        sendSelectOrder(selected - 1)
        sendBytes(pktTake)
        truck.enabled = false
        truck.last = ru("Заказ: ") .. nameList[selected] .. " - " .. payList[selected]
        pushLog(ru("Заказ выбран: ") .. payList[selected] .. ru(" руб."), "success")
        Notifications.push("success", ru("Дальнобойщик"), ru("Заказ выбран: ") .. payList[selected])
        truckChat(ru("Выбран заказ: ") .. nameList[selected] .. " (" .. payList[selected] .. ")")
        return false
    else
        truck.last = ru("Подходящий заказ не найден")
        truckChat(ru("Подходящий заказ не найден, повторный поиск..."))
        sendBytes(pktTake)
        lua_thread.create(function() wait(1500); if truck.enabled then sampSendChat("/bizlist") end end)
        return false
    end
end

local function startTrucking()
    if truck.enabled then return end
    if bot.on then stopBot(ru("Остановлено: запуск дальнобойщика")) end
    if trainbot.enabled then trainbot.stop() end
    if stopOhota then stopOhota(true) end
    if svalka.stop then svalka.stop(true) end
    truck.enabled = true
    truck.last = ""
    pushLog(ru("Дальнобойщик: поиск заказа"), "success")
    Notifications.push("success", ru("Дальнобойщик"), ru("Поиск заказа запущен"))
    lua_thread.create(function() wait(500); sampSendChat("/bizlist") end)
    truckChat(ru("Поиск заказа запущен"))
end

stopTrucking = function(silent)
    if not truck.enabled then return end
    truck.enabled = false
    if not silent then
        pushLog(ru("Дальнобойщик остановлен"), "muted")
        Notifications.push("info", ru("Дальнобойщик"), ru("Остановлен"))
        truckChat(ru("Дальнобойщик остановлен"))
    end
end

local function toggleTrucking()
    if truck.enabled then stopTrucking() else startTrucking() end
end

local function trainbotHandleText(text)
    if text:find("Machinist", 1, true) and text:find("setStation", 1, true) then
        local json = text:match("setStation%('(.*)'%)")
        if json then
            local ok, data = pcall(decodeJson, json)
            if ok and type(data) == "table" then
                trainbot.station = tostring(data[1] or "")
                trainbot.distance = tonumber(data[2]) or trainbot.distance
            end
        end
    end

    local minSpeed, maxSpeed = text:match(
        'interface%(\'Machinist\'%)%.setSpeed%(\'%["(%d+)%-(%d+)", %d+%]\'%)'
    )
    if minSpeed and maxSpeed then
        trainbot.speed.min = tonumber(minSpeed) or trainbot.speed.min
        trainbot.speed.max = tonumber(maxSpeed) or trainbot.speed.max
    end
end

function trainbot.onPacket(id, bs)
    if id ~= 215 or not trainbot.enabled then return end

    local startOffset = raknetBitStreamGetReadOffset(bs)
    local ok, err = pcall(function()
        if raknetBitStreamGetNumberOfUnreadBits(bs) < 24 then return end
        raknetBitStreamIgnoreBits(bs, 8)
        if raknetBitStreamReadInt16(bs) ~= 2 then return end
        if raknetBitStreamGetNumberOfUnreadBits(bs) < 40 then return end

        raknetBitStreamReadInt32(bs)
        local count = raknetBitStreamReadInt8(bs)
        if count <= 0 or count > 16 then return end

        for _ = 1, count do
            if raknetBitStreamGetNumberOfUnreadBits(bs) < 32 then break end
            local length = raknetBitStreamReadInt32(bs)
            if length <= 0 or length > 65535
                or length * 8 > raknetBitStreamGetNumberOfUnreadBits(bs) then
                break
            end
            trainbotHandleText(raknetBitStreamReadString(bs, length))
        end
    end)

    raknetBitStreamSetReadOffset(bs, startOffset)
    if not ok then print("[TrainBot] Packet parse failed: " .. tostring(err)) end
end

function trainbot.start()
    if trainbot.enabled then return end
    trainbot.enabled = true
end

function trainbot.stop()
    if not trainbot.enabled then return end
    trainbot.enabled = false
    trainbot.key = 0
    trainbot.moveToken = trainbot.moveToken + 1
    trainbot.dissync = false
    setGameKeyState(16, 0)
    setGameKeyState(14, 0)
end

function trainbot.update()
    if not trainbot.enabled then return end
    if not isCharInAnyTrain(PLAYER_PED) then
        trainbot.key = 0
        setGameKeyState(16, 0)
        setGameKeyState(14, 0)
        return
    end

    local car = storeCarCharIsInNoSave(PLAYER_PED)
    local speed = getCarSpeed(car) * 3.67
    local x, y, z = getCharCoordinates(PLAYER_PED)
    local checkpoint = trainbot.checkpoint
    local distance = math.max(0,
        getDistanceBetweenCoords3d(x, y, z, checkpoint.position.x, checkpoint.position.y, checkpoint.position.z) - 1)

    trainbot.timer = trainbot.timer or os.clock()
    trainbot.lastDistance = trainbot.lastDistance or 1

    if checkpoint.isFinish or (trainbot.distance - distance >= 0 and trainbot.distance - distance <= 35) then
        if trainbot.timer < os.clock() then
            trainbot.lastDistance = math.max(distance, 1)
            trainbot.timer = os.clock() + 1
        end

        local desiredSpeed = trainbot.speed.min + (trainbot.speed.max - trainbot.speed.min) / 2
        local stopDistance = distance - ((speed / 42) * math.max(trainbot.lastDistance, 1)) / 1.2
        local brakeStartDistance = math.max(20, math.min(60, speed * 1.3 + 15))
        local finalStopDistance = math.max(6, math.min(18, speed * 0.7 + 4))
        local finalBrake = distance <= finalStopDistance
            or (distance <= brakeStartDistance and speed <= desiredSpeed + 8)

        printStringNow(string.format("%d/%d ; %d/%d/%d ; %d",
            math.floor(speed), trainbot.speed.max, math.floor(trainbot.distance),
            math.floor(distance), math.floor(trainbot.lastDistance), math.floor(stopDistance)), 250)

        if finalBrake then
            setGameKeyState(16, 0)
            setGameKeyState(14, 255)
            writeMemory(0xB73458 + 0x1C, 1, 255, false)
            if distance < 3 and speed < 5 then setTrainSpeed(car, 0) end
        elseif stopDistance <= 1 and distance < 260 then
            if distance < 3 and speed < 4 then
                setTrainSpeed(car, math.max(0, getCarSpeed(car) / 1.1 - 1))
            else
                setGameKeyState(16, 0)
                setGameKeyState(14, 255)
                writeMemory(0xB73458 + 0x1C, 1, 255, false)
            end
        elseif speed < desiredSpeed then
            setGameKeyState(16, 255)
            writeMemory(0xB73458 + 0x20, 1, 255, false)
        end
    elseif speed < trainbot.speed.min + (trainbot.speed.max - trainbot.speed.min) / 2 then
        setGameKeyState(16, 255)
        writeMemory(0xB73458 + 0x20, 1, 255, false)
    end

    local moveSpeed = getCarSpeed(car)
    local moveDirection = moveSpeed > 0 and 1 or (moveSpeed < 0 and -1 or 0)
    trainbot.key = moveDirection == 1 and 8 or (moveDirection == -1 and 32 or 0)
end

function trainbot.onSetRaceCheckpoint(checkpointType, position)
    trainbot.checkpoint.position = position
    trainbot.checkpoint.isFinish = checkpointType == 1
end

function trainbot.onDisableRaceCheckpoint()
    trainbot.checkpoint.isFinish = false
end

local function trainbotSendPosition(x, y, z)
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, 207)
    raknetBitStreamWriteInt16(bs, 0)
    raknetBitStreamWriteInt16(bs, 0)
    raknetBitStreamWriteInt16(bs, 0)
    raknetBitStreamWriteFloat(bs, x)
    raknetBitStreamWriteFloat(bs, y)
    raknetBitStreamWriteFloat(bs, z)
    for _ = 1, 7 do raknetBitStreamWriteFloat(bs, 0) end
    raknetBitStreamWriteInt8(bs, getCharHealth(PLAYER_PED))
    raknetBitStreamWriteInt8(bs, getCharArmour(PLAYER_PED))
    raknetBitStreamWriteInt8(bs, getCurrentCharWeapon(PLAYER_PED))
    raknetBitStreamWriteInt8(bs, 0)
    for _ = 1, 6 do raknetBitStreamWriteFloat(bs, 0) end
    raknetBitStreamWriteInt16(bs, 0)
    raknetBitStreamWriteInt16(bs, 0)
    raknetBitStreamWriteInt16(bs, 0)
    raknetSendBitStreamEx(bs, 2, 8, 0)
    raknetDeleteBitStream(bs)
end

function trainbot.onSetCheckpoint(position)
    if not trainbot.enabled or not isCharOnFoot(PLAYER_PED) then return end

    trainbot.moveToken = trainbot.moveToken + 1
    local moveToken = trainbot.moveToken
    lua_thread.create(function()
        local x, y, z = getCharCoordinates(PLAYER_PED)
        trainbot.dissync = true
        while getDistanceBetweenCoords3d(position.x, position.y, position.z, x, y, z) > 1
            and trainbot.enabled and trainbot.moveToken == moveToken
            and isCharOnFoot(PLAYER_PED) do
            x = x + (x > position.x and -1 or 1)
            y = y + (y > position.y and -1 or 1)
            z = z + (z > position.z and -1 or 1)
            trainbotSendPosition(x, y, z)
            printStringNow(ru("Поезд: движение к станции"), 110)
            wait(100)
        end
        if trainbot.enabled and trainbot.moveToken == moveToken and isCharOnFoot(PLAYER_PED) then
            setCharCoordinates(PLAYER_PED, position.x, position.y, position.z)
        end
        if trainbot.moveToken == moveToken then trainbot.dissync = false end
    end)
end

function trainbot.onSendVehicleSync(data)
    if trainbot.key ~= 0 then data.keysData = bit.bor(data.keysData or 0, trainbot.key) end
end

function trainbot.onSendPlayerSync()
    if trainbot.dissync then return false end
end

local function ohotaIsAnimal(handle)
    return animalInfo[getCharModel(handle)] ~= nil
end

local function ohotaAnimalHealthInfo(info, health)
    local nearestInfo
    local nearestDifference = math.huge
    for threshold, healthInfo in pairs(info.health) do
        local difference = math.abs(health - threshold)
        if difference < nearestDifference then
            nearestInfo = healthInfo
            nearestDifference = difference
        end
    end
    return nearestInfo
end

local function ohotaDistance3D(x1, y1, z1, x2, y2, z2)
    local dx, dy, dz = x1 - x2, y1 - y2, z1 - z2
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function ohotaIsValidAimTarget(handle)
    return handle and handle ~= PLAYER_PED and doesCharExist(handle)
        and getCharHealth(handle) > 0 and ohotaIsAnimal(handle)
        and isCharOnScreen(handle)
end

local function ohotaUpdateDeadAnimals(chars)
    for _, handle in pairs(chars) do
        if handle ~= PLAYER_PED and doesCharExist(handle) then
            local model = getCharModel(handle)
            if animalInfo[model] then
                if getCharHealth(handle) <= 0 then
                    if not collectedDeadAnimals[handle] then
                        local x, y, z = getCharCoordinates(handle)
                        deadAnimals[handle] = { model = model, x = x, y = y, z = z }
                    end
                else
                    collectedDeadAnimals[handle] = nil
                    deadAnimals[handle] = nil
                end
            end
        end
    end

    for handle in pairs(collectedDeadAnimals) do
        if not doesCharExist(handle) then collectedDeadAnimals[handle] = nil end
    end
    for handle, state in pairs(deadAnimals) do
        if doesCharExist(handle)
            and (getCharModel(handle) ~= state.model or getCharHealth(handle) > 0) then
            collectedDeadAnimals[handle] = nil
            deadAnimals[handle] = nil
        end
    end
end

local function ohotaClearNearestDeadAnimal()
    local playerX, playerY, playerZ = getCharCoordinates(PLAYER_PED)
    local nearestHandle
    local nearestDistance = ANIMAL_PICKUP_DISTANCE
    for handle, state in pairs(deadAnimals) do
        local distance = ohotaDistance3D(state.x, state.y, state.z, playerX, playerY, playerZ)
        if distance <= nearestDistance then
            nearestHandle = handle
            nearestDistance = distance
        end
    end

    if nearestHandle then
        if doesCharExist(nearestHandle) then collectedDeadAnimals[nearestHandle] = true end
        deadAnimals[nearestHandle] = nil
    end
end

local function ohotaDrawAnimals(chars)
    ohotaTextQueue = {}
    if not Ohota.wh[0] then return end

    local playerX, playerY, playerZ = getCharCoordinates(PLAYER_PED)
    local screenX, screenY = convert3DCoordsToScreen(playerX, playerY, playerZ)
    local aimHandle = Ohota.aim[0] and Ohota.aimHandle or nil
    local hasAimHandle = ohotaIsValidAimTarget(aimHandle)

    for _, handle in pairs(chars) do
        if handle ~= PLAYER_PED and doesCharExist(handle) and isCharOnScreen(handle) then
            local model = getCharModel(handle)
            local info = animalInfo[model]
            local health = getCharHealth(handle)
            local x, y, z = getCharCoordinates(handle)
            local labelX, labelY = convert3DCoordsToScreen(x, y, z)

            if health > 0 and (info or Ohota.players[0]) then
                local healthInfo
                if info then
                    healthInfo = ohotaAnimalHealthInfo(info, health)
                    if healthInfo then
                        local label = info.name .. " (" .. healthInfo[1] .. ")"
                        local color = ohotaLiveLabelColors[Ohota.liveLabelColor[0] + 1].value or healthInfo[2]
                        if Ohota.distance[0] then
                            local distance = ohotaDistance3D(playerX, playerY, playerZ, x, y, z)
                            label = label .. " [" .. math.floor(distance + 0.5) .. " \236]"
                        end
                        queueOhotaLabel(label, labelX, labelY, color)
                    end

                    if Ohota.headDot[0] or (hasAimHandle and aimHandle == handle) then
                        local hx, hy, hz = getBodyPartCoordinates(HEAD_BONE_ID, handle)
                        local headX, headY = convert3DCoordsToScreen(hx, hy, hz)
                        if Ohota.headDot[0] then
                            renderDrawBoxWithBorder(headX, headY, 3, 3, 0xFF00FF00, 1, 0xFF00FF00)
                        end
                        if hasAimHandle and aimHandle == handle then
                            renderDrawLine(screenX, screenY, headX, headY, 1.0,
                                healthInfo and healthInfo[2] or 0xFF00FF00)
                        end
                    end
                end

                if Ohota.players[0] then
                    local resultPlayerId = sampGetPlayerIdByCharHandle(handle)
                    if resultPlayerId then
                        queueOhotaLabel("\200\227\240\238\234", labelX, labelY, 0xFF8C8C8C)
                    end
                end
            end
        end
    end

    if Ohota.dead[0] then
        local screenWidth, screenHeight = getScreenResolution()
        for _, state in pairs(deadAnimals) do
            if isPointOnScreen(state.x, state.y, state.z) then
                local labelX, labelY = convert3DCoordsToScreen(state.x, state.y, state.z)
                if labelX >= 0 and labelX <= screenWidth and labelY >= 0 and labelY <= screenHeight then
                    local info = animalInfo[state.model]
                    local label = info.name .. " (\243\225\232\242)"
                    if Ohota.distance[0] then
                        local distance = ohotaDistance3D(playerX, playerY, playerZ, state.x, state.y, state.z)
                        label = label .. " [" .. math.floor(distance + 0.5) .. " \236]"
                    end
                    queueOhotaLabel(label, labelX, labelY,
                        ohotaDeadLabelColors[Ohota.deadLabelColor[0] + 1].value)
                end
            end
        end
    end
end

local function ohotaDrawTracers(chars)
    if not Ohota.tracers[0] then return end
    local screenWidth, screenHeight = getScreenResolution()
    local centerX, centerY = screenWidth / 2, screenHeight / 2
    local color = ohotaTracerColors[Ohota.tracerColor[0] + 1].value
    local thickness = Ohota.tracerWidth[0]

    for _, handle in pairs(chars) do
        if handle ~= PLAYER_PED and doesCharExist(handle) and ohotaIsAnimal(handle)
            and getCharHealth(handle) > 0 and isCharOnScreen(handle) then
            local x, y, z = getCharCoordinates(handle)
            local targetX, targetY = convert3DCoordsToScreen(x, y, z)
            if targetX >= 0 and targetX <= screenWidth and targetY >= 0 and targetY <= screenHeight then
                renderDrawLine(centerX, centerY, targetX, targetY, thickness, color)
            end
        end
    end

    for _, state in pairs(deadAnimals) do
        if isPointOnScreen(state.x, state.y, state.z) then
            local targetX, targetY = convert3DCoordsToScreen(state.x, state.y, state.z)
            if targetX >= 0 and targetX <= screenWidth and targetY >= 0 and targetY <= screenHeight then
                renderDrawLine(centerX, centerY, targetX, targetY, thickness, color)
            end
        end
    end
end

local function ohotaCleanStillAnimals(chars)
    if not Ohota.clear[0] then
        for handle in pairs(animalLastState) do animalLastState[handle] = nil end
        return
    end

    local nowTime, seen = os.clock(), {}
    for _, handle in pairs(chars) do
        if handle ~= PLAYER_PED and doesCharExist(handle) and ohotaIsAnimal(handle) then
            seen[handle] = true
            local x, y, z = getCharCoordinates(handle)
            local state, model = animalLastState[handle], getCharModel(handle)
            if not state or state.model ~= model then
                animalLastState[handle] = { model = model, x = x, y = y, z = z, lastMoveTime = nowTime }
            elseif math.abs(x - state.x) > ANIMAL_MOVE_EPSILON
                or math.abs(y - state.y) > ANIMAL_MOVE_EPSILON
                or math.abs(z - state.z) > ANIMAL_MOVE_EPSILON then
                state.x, state.y, state.z = x, y, z
                state.lastMoveTime = nowTime
            elseif nowTime - state.lastMoveTime >= STILL_ANIMAL_TIMEOUT_SECONDS then
                deleteChar(handle)
                animalLastState[handle] = nil
                seen[handle] = nil
            end
        end
    end

    for handle in pairs(animalLastState) do
        if not seen[handle] or not doesCharExist(handle) then animalLastState[handle] = nil end
    end
end

local function ohotaGetAimFrame()
    local screenWidth = getScreenResolution()
    local distance = 0.025 * screenWidth / (getCameraFov() * OHOTA_DEG_TO_RAD)
    local centerX, centerY = convertGameScreenCoordsToWindowScreenCoords(339.1, 179.1)
    return centerX, centerY, distance
end

local ohotaTargetAtCoords

local function ohotaUpdateAim(chars)
    Ohota.aimHandle = nil
    if not Ohota.aim[0] then return end
    local cameraMode = readMemory(CAMERA_MODE_ADDRESS, 1, false)
    if not AIM_CAMERA_MODES[cameraMode] then return end

    local centerX, centerY, distance = ohotaGetAimFrame()
    renderDrawBoxWithBorder(centerX - distance / 2, centerY - distance / 2,
        distance, distance, nil, 2, 0xFF5AE053)
    local playerX, playerY, playerZ = getCharCoordinates(PLAYER_PED)
    local candidates = {}
    local maxScreenDistance, maxWorldDistance = 0, 0

    for _, handle in pairs(chars) do
        if ohotaIsValidAimTarget(handle) then
            local x, y, z = getBodyPartCoordinates(HEAD_BONE_ID, handle)
            local screenX, screenY = convert3DCoordsToScreen(x, y, z)
            if screenX > centerX - distance / 2 and screenX < centerX + distance / 2
                and screenY > centerY - distance / 2 and screenY < centerY + distance / 2 then
                local screenDistance = math.sqrt((screenX - centerX) ^ 2 + (screenY - centerY) ^ 2)
                local targetX, targetY, targetZ = getCharCoordinates(handle)
                local worldDistance = ohotaDistance3D(targetX, targetY, targetZ, playerX, playerY, playerZ)
                candidates[#candidates + 1] = {
                    handle = handle, screenDistance = screenDistance, worldDistance = worldDistance,
                    x = x, y = y, z = z,
                }
                maxScreenDistance = math.max(maxScreenDistance, screenDistance)
                maxWorldDistance = math.max(maxWorldDistance, worldDistance)
            end
        end
    end

    local bestScore, target = math.huge, nil
    for _, candidate in ipairs(candidates) do
        local screenScore = maxScreenDistance > 0 and candidate.screenDistance / maxScreenDistance or 0
        local worldScore = maxWorldDistance > 0 and candidate.worldDistance / maxWorldDistance or 0
        local score = screenScore + worldScore
        if score < bestScore then bestScore, target = score, candidate end
    end

    if target and ohotaIsValidAimTarget(target.handle) then
        Ohota.aimHandle = target.handle
        ohotaTargetAtCoords(target.x, target.y, target.z)
    end
end

local function ohotaGetCameraTargetAtCoords(x, y, z)
    local cx, cy, cz = getActiveCameraCoordinates()
    local aspectRatio = representIntAsFloat(readMemory(SCREEN_ASPECT_RATIO_ADDRESS, 4, false))
    local offsetX = representIntAsFloat(readMemory(CROSSHAIR_OFFSET_X_ADDRESS, 4, false))
    local offsetY = representIntAsFloat(readMemory(CROSSHAIR_OFFSET_Y_ADDRESS, 4, false))
    local multiplier = math.tan(getCameraFov() * 0.5 * OHOTA_DEG_TO_RAD)
    local targetZ = OHOTA_PI - math.atan2(1.0, multiplier * ((0.5 - offsetX) * (2 / aspectRatio)))
    local targetX = OHOTA_PI - math.atan2(1.0, multiplier * 2 * (offsetY - 0.5))
    local cameraMode = readMemory(CAMERA_MODE_ADDRESS, 1, false)
    if cameraMode ~= CAMERA_MODE_SNIPER and cameraMode ~= CAMERA_MODE_RIFLE then
        targetX, targetZ = OHOTA_PI / 2, OHOTA_PI / 2
    end
    local dx, dy, dz = cx - x, cy - y, cz - z
    local angleX = math.atan2(dy, -dx) - OHOTA_PI / 2
    local angleZ = math.atan2(math.sqrt(dx * dx + dy * dy), dz)
    return angleZ - targetZ, targetX - angleX
end

ohotaTargetAtCoords = function(x, y, z)
    local angleZ, angleX = ohotaGetCameraTargetAtCoords(x, y, z)
    setCameraPositionUnfixed(angleZ, angleX)
end

local function ohotaOnPacket(bs)
    if not Ohota.enabled then return end
    local startOffset = raknetBitStreamGetReadOffset(bs)
    local ok, err = pcall(function()
        if raknetBitStreamGetNumberOfUnreadBits(bs) < 96 then return end
        raknetBitStreamReadInt16(bs)
        raknetBitStreamReadInt32(bs)
        raknetBitStreamReadInt8(bs)
        raknetBitStreamReadInt8(bs)
        local length = raknetBitStreamReadInt32(bs)
        if not length or length <= 0 or length >= 10000
            or length * 8 > raknetBitStreamGetNumberOfUnreadBits(bs) then return end
        local text = raknetBitStreamReadString(bs, length)
        local started = text:find("interface('ProgressBar').setFill(0, 3)", 1, true)
        local finished = text:find("interface('ProgressBar').setFill(0, 100)", 1, true)
        if Ohota.autoY[0] then
            if started then Ohota.autoYClicker:Start()
            elseif finished then Ohota.autoYClicker:Stop() end
        end
        if finished then animalPickupFinished = true end
    end)
    raknetBitStreamSetReadOffset(bs, startOffset)
    if not ok then print("[\206\245\238\242\224] \206\248\232\225\234\224 \240\224\241\239\224\234\238\226\234\232 \239\224\234\229\242\224: " .. tostring(err)) end
end

local function toggleTrain()
    if trainbot.enabled then
        trainbot.stop()
        pushLog(ru("Автопилот поезда остановлен"), "muted")
        Notifications.push("info", ru("Поезд"), ru("Автопилот остановлен"))
    else
        if bot.on then stopBot(ru("Остановлено для запуска автопилота поезда")) end
        if truck.enabled then stopTrucking(true) end
        if stopOhota then stopOhota(true) end
        if svalka.stop then svalka.stop(true) end
        trainbot.start()
        pushLog(ru("Автопилот поезда запущен"), "success")
        Notifications.push("success", ru("Поезд"), ru("Автопилот включён"))
    end
end

stopOhota = function(silent)
    if not Ohota.enabled then return end
    Ohota.enabled = false
    Ohota.aimHandle = nil
    Ohota.autoYClicker:Stop()
    animalPickupFinished = false
    if not silent then
        pushLog("\206\245\238\242\224 \238\241\242\224\237\238\226\235\229\237\224", "muted")
        Notifications.push("info", "\206\245\238\242\224", "\204\238\228\243\235\252 \238\241\242\224\237\238\226\235\229\237")
    end
end

local function toggleOhota()
    if Ohota.enabled then
        stopOhota()
        return
    end
    if bot.on then stopBot("\206\241\242\224\237\238\226\235\229\237\238 \228\235\255 \238\245\238\242\251") end
    if truck.enabled then stopTrucking(true) end
    if trainbot.enabled then trainbot.stop() end
    if svalka.stop then svalka.stop(true) end
    Ohota.enabled = true
    pushLog("\206\245\238\242\224 \231\224\239\243\249\229\237\224", "success")
    Notifications.push("success", "\206\245\238\242\224", "\204\238\228\243\235\252 \226\234\235\254\247\229\237")
end

function ev.onSetRaceCheckpoint(checkpointType, position)
    trainbot.onSetRaceCheckpoint(checkpointType, position)
end

function ev.onDisableRaceCheckpoint()
    trainbot.onDisableRaceCheckpoint()
end

function ev.onSetCheckpoint(position)
    trainbot.onSetCheckpoint(position)
end

function ev.onSendVehicleSync(data)
    trainbot.onSendVehicleSync(data)
end

function ev.onSendPlayerSync(data)
    return trainbot.onSendPlayerSync(data)
end

function onReceivePacket(id, bs)
    if id ~= 215 then return end
    ohotaOnPacket(bs)
    trainbot.onPacket(id, bs)
    if caseCatcher then
        caseCatcher.onPacket(id, bs)
    end
    if truck.enabled then
        if truckPacket(bs) == false then return false end
    end
    if bot.on then fishPacket(bs) end
end

--================= ������ =================--
local function drawFishIcon(dl, cx, cy, iconCol)
    local c = u32(iconCol)
    for i = 0, 15 do
        local a = math.pi * 2 * (i / 15)
        local nxt_a = math.pi * 2 * ((i + 1) / 15)
        dl:AddLine(
            ImVec2(cx - 4 + math_cos(a) * 8, cy + math_sin(a) * 5),
            ImVec2(cx - 4 + math_cos(nxt_a) * 8, cy + math_sin(nxt_a) * 5),
            c, 1.5
        )
    end
    dl:AddTriangleFilled(ImVec2(cx + 4, cy), ImVec2(cx + 12, cy - 6), ImVec2(cx + 12, cy + 6), c)
    dl:AddCircleFilled(ImVec2(cx - 8, cy - 1), 1.5, c)
end

local function drawClose(dl, cx, cy, size, color)
    local s = size * 0.25
    local c = u32(color)
    dl:AddLine(ImVec2(cx - s, cy - s), ImVec2(cx + s, cy + s), c, 1.5)
    dl:AddLine(ImVec2(cx + s, cy - s), ImVec2(cx - s, cy + s), c, 1.5)
end

-- 1 �������, 2 �������, 3 ����������, 4 ���������, 5 ��������
local function drawNavIcon(dl, kind, cx, cy, col)
    local c = u32(col)
    if kind == 1 then
        dl:AddRect(ImVec2(cx - 8, cy - 8), ImVec2(cx - 1, cy - 1), c, 2, nil, 1.5)
        dl:AddRect(ImVec2(cx + 1, cy - 8), ImVec2(cx + 8, cy - 1), c, 2, nil, 1.5)
        dl:AddRect(ImVec2(cx - 8, cy + 1), ImVec2(cx - 1, cy + 8), c, 2, nil, 1.5)
        dl:AddRect(ImVec2(cx + 1, cy + 1), ImVec2(cx + 8, cy + 8), c, 2, nil, 1.5)
    elseif kind == 2 then
        drawFishIcon(dl, cx, cy, col)
    elseif kind == 3 then
        dl:AddCircle(ImVec2(cx, cy), 8, c, 20, 1.5)
        dl:AddCircleFilled(ImVec2(cx - 3, cy - 2), 1.8, c, 8)
        dl:AddCircleFilled(ImVec2(cx + 3, cy - 2), 1.8, c, 8)
        dl:AddCircleFilled(ImVec2(cx, cy + 3), 1.8, c, 8)
    elseif kind == 5 then
        dl:AddRect(ImVec2(cx - 10, cy - 6), ImVec2(cx + 1, cy + 3), c, 1, nil, 1.5)
        dl:AddRect(ImVec2(cx + 1, cy - 2), ImVec2(cx + 9, cy + 3), c, 1, nil, 1.5)
        dl:AddCircleFilled(ImVec2(cx - 5, cy + 5), 2.2, c, 10)
        dl:AddCircleFilled(ImVec2(cx + 5, cy + 5), 2.2, c, 10)
    else
        dl:AddCircle(ImVec2(cx, cy), 7, c, 16, 2.5)
        dl:AddCircleFilled(ImVec2(cx, cy), 2.2, c, 8)
    end
end

--================= UI �������� =================--
local Ui = {}
local ROW_H = 54

function Ui.switch(id, value)
    local w, h = 38, 20
    local p = imgui.GetCursorScreenPos()
    imgui.InvisibleButton("##sw_" .. id, ImVec2(w, h))
    local hovered = imgui.IsItemHovered()
    local clicked = imgui.IsItemClicked()
    if clicked then value[0] = not value[0] end

    local dl = imgui.GetWindowDrawList()
    local trackCol = value[0] and u32(P.accent) or u32(P.cardHi, hovered and 1.0 or 0.8)
    dl:AddRectFilled(p, ImVec2(p.x + w, p.y + h), trackCol, h * 0.5)
    if not value[0] then
        dl:AddRect(p, ImVec2(p.x + w, p.y + h), u32(P.border, 0.9), h * 0.5, nil, 1)
    end
    local kx = value[0] and (p.x + w - h * 0.5) or (p.x + h * 0.5)
    dl:AddCircleFilled(ImVec2(kx, p.y + h * 0.5), h * 0.5 - 3, u32({ 0.96, 0.95, 0.95 }), 20)
    return clicked
end

function Ui.button(id, label, w, h, variant, disabled)
    if w == -1 then w = imgui.GetContentRegionAvail().x end
    w = w or imgui.GetContentRegionAvail().x
    h = h or 34
    variant = variant or "default"
    local p = imgui.GetCursorScreenPos()
    imgui.InvisibleButton("##btn_" .. id, ImVec2(w, h))
    local hovered = not disabled and imgui.IsItemHovered()
    local active  = not disabled and imgui.IsItemActive()
    local clicked = not disabled and imgui.IsItemClicked()

    local dl = imgui.GetWindowDrawList()
    local bg, border, tc
    if disabled then
        bg = u32(P.card, 0.4); border = u32(P.border, 0.3); tc = u32(P.dim)
    elseif variant == "accent" then
        bg = u32(P.accent, active and 0.95 or (hovered and 0.88 or 0.78))
        border = bg
        tc = u32({ 1, 1, 1 })
    elseif variant == "danger" then
        bg = u32(P.danger, active and 0.35 or (hovered and 0.25 or 0.15))
        border = u32(P.danger, hovered and 0.6 or 0.35)
        tc = u32(P.danger)
    else
        bg = u32(P.cardHi, active and 1.0 or (hovered and 0.85 or 0.55))
        border = u32(P.border, hovered and 0.85 or 0.55)
        tc = u32(P.text)
    end

    if variant == "accent" and not disabled then
        local g = hovered and 14 or 8
        for i = g, 1, -2 do
            dl:AddRect(ImVec2(p.x - i * 0.5, p.y - i * 0.5), ImVec2(p.x + w + i * 0.5, p.y + h + i * 0.5),
                u32(P.accent, 0.035 * (g - i + 2) / 2), 8 + i * 0.5, nil, 1.5)
        end
    end
    dl:AddRectFilled(p, ImVec2(p.x + w, p.y + h), bg, 8)
    if variant == "accent" and not disabled then
        dl:AddRectFilledMultiColor(p, ImVec2(p.x + w, p.y + h * 0.5),
            u32({1,1,1}, 0.16), u32({1,1,1}, 0.16), u32({1,1,1}, 0), u32({1,1,1}, 0))
    end
    if variant ~= "accent" then
        dl:AddRect(p, ImVec2(p.x + w, p.y + h), border, 8, nil, 1)
    end

    local rendered = u8(label)
    if Fonts.bold then imgui.PushFont(Fonts.bold) end
    local ts = imgui.CalcTextSize(rendered)
    dl:AddText(ImVec2(p.x + (w - ts.x) * 0.5, p.y + (h - ts.y) * 0.5), tc, rendered)
    if Fonts.bold then imgui.PopFont() end
    return clicked
end

function Ui.label(title)
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    dl:AddRectFilled(ImVec2(p.x + 2, p.y + 5), ImVec2(p.x + 5, p.y + 17), u32(P.accent), 1)
    text(dl, p.x + 12, p.y + 3, u32(P.muted), u8(title), Fonts.smallBold)
    imgui.Dummy(ImVec2(10, 26))
end

-- ������ ��������: ���� ��������, ������ ������ � �������������
function Ui.group(title, items)
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local w = imgui.GetContentRegionAvail().x
    local total = 0
    for _, it in ipairs(items) do total = total + (it.h or ROW_H) end

    if title then
        dl:AddRectFilled(ImVec2(p.x + 2, p.y + 5), ImVec2(p.x + 5, p.y + 17), u32(P.accent), 1)
        text(dl, p.x + 12, p.y + 3, u32(P.muted), u8(title), Fonts.smallBold)
    end
    local top = p.y + (title and 26 or 0)
    dl:AddRectFilled(ImVec2(p.x, top), ImVec2(p.x + w, top + total), u32(P.card), 12)
    dl:AddRect(ImVec2(p.x, top), ImVec2(p.x + w, top + total), u32(P.border, 0.7), 12, nil, 1)

    local y = top
    for i, it in ipairs(items) do
        local h = it.h or ROW_H
        if i > 1 then
            dl:AddLine(ImVec2(p.x + 16, y), ImVec2(p.x + w - 16, y), u32(P.border, 0.45), 1)
        end
        if it.title then
            if it.desc and it.desc ~= "" then
                text(dl, p.x + 16, y + 9, u32(P.text), u8(it.title), Fonts.bold)
                text(dl, p.x + 16, y + 30, u32(P.muted), u8(it.desc), Fonts.smallBold)
            else
                text(dl, p.x + 16, y + (h - 18) * 0.5, u32(P.text), u8(it.title), Fonts.bold)
            end
        end

        local rx = p.x + w - 16
        local k = it.kind
        if k == "switch" then
            imgui.SetCursorScreenPos(ImVec2(rx - 38, y + (h - 20) * 0.5))
            if Ui.switch(it.id, it.ptr) then
                markDirty()
                if it.onChange then it.onChange() end
            end
        elseif k == "slider" then
            imgui.SetCursorScreenPos(ImVec2(rx - 210, y + (h - 20) * 0.5))
            imgui.PushItemWidth(210)
            if imgui.SliderInt("##" .. it.id, it.ptr, it.mn, it.mx, u8(it.fmt)) then
                if it.onChange then it.onChange() end
                markDirty()
            end
            imgui.PopItemWidth()
        elseif k == "sliderf" then
            local sw = it.sw or 210
            imgui.SetCursorScreenPos(ImVec2(rx - sw, y + (h - 20) * 0.5))
            imgui.PushItemWidth(sw)
            if imgui.SliderFloat("##" .. it.id, it.ptr, it.mn, it.mx, it.fmt) then
                if it.onChange then it.onChange() end
                markDirty()
            end
            imgui.PopItemWidth()
        elseif k == "combo" then
            local cw = it.cw or 170
            imgui.SetCursorScreenPos(ImVec2(rx - cw, y + (h - 22) * 0.5))
            imgui.PushItemWidth(cw)
            if imgui.Combo("##" .. it.id, it.ptr, it.items, it.count) then
                if it.onChange then it.onChange() end
                markDirty()
            end
            imgui.PopItemWidth()
        elseif k == "button" then
            local bw = it.bw or 140
            imgui.SetCursorScreenPos(ImVec2(rx - bw, y + (h - 32) * 0.5))
            if Ui.button(it.id, it.label, bw, 32, it.variant) then it.onClick() end
        elseif k == "custom" then
            it.draw(p.x, y, w, h)
        end
        y = y + h
    end

    imgui.SetCursorScreenPos(ImVec2(p.x, top + total))
    imgui.Dummy(ImVec2(w, 16))
end

function Ui.statCard(title, value, accent, w, h)
    local p = imgui.GetCursorScreenPos()
    local dl = imgui.GetWindowDrawList()
    dl:AddRectFilled(p, ImVec2(p.x + w, p.y + h), u32(P.card), 12)
    dl:AddRect(p, ImVec2(p.x + w, p.y + h), u32(P.border, 0.7), 12, nil, 1)
    dl:AddRectFilled(ImVec2(p.x + 1, p.y + 16), ImVec2(p.x + 4, p.y + h - 16), u32(accent), 2)
    text(dl, p.x + 16, p.y + 12, u32(P.muted), u8(title), Fonts.smallBold)
    text(dl, p.x + 16, p.y + 32, u32(P.text), u8(value), Fonts.heading)
    imgui.Dummy(ImVec2(w, h))
end

-- �������� ������ ��� ��������
function Ui.moduleCard(id, title, desc, icon, running, status, w, onToggle, onOpen)
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local h = 108
    dl:AddRectFilled(p, ImVec2(p.x + w, p.y + h), u32(P.card), 14)
    if running then
        dl:AddRectFilledMultiColor(p, ImVec2(p.x + w, p.y + h),
            u32(P.accent, 0.14), u32(P.accent, 0.02), u32(P.accent, 0.02), u32(P.accent, 0.14))
    end
    dl:AddRect(p, ImVec2(p.x + w, p.y + h), u32(running and P.accent or P.border, running and 0.55 or 0.7), 14, nil, 1)

    local ix, iy = p.x + 18, p.y + 22
    dl:AddRectFilled(ImVec2(ix, iy), ImVec2(ix + 52, iy + 52), u32(P.accent, 0.18), 12)
    dl:AddRect(ImVec2(ix, iy), ImVec2(ix + 52, iy + 52), u32(P.accent, 0.7), 12, nil, 1.2)
    drawNavIcon(dl, icon, ix + 26, iy + 26, { 1.0, 0.45, 0.48 })

    text(dl, p.x + 84, p.y + 16, u32(P.text), u8(title), Fonts.heading)
    text(dl, p.x + 84, p.y + 46, u32(P.muted), u8(desc), Fonts.smallBold)
    local pulse = running and (1.2 * math_sin(now() * 4)) or 0
    dl:AddCircleFilled(ImVec2(p.x + 90, p.y + 82), 4 + pulse, u32(running and P.success or P.dim), 12)
    text(dl, p.x + 102, p.y + 75, u32(running and P.success or P.dim), u8(status), Fonts.smallBold)

    local by = p.y + (h - 36) * 0.5
    imgui.SetCursorScreenPos(ImVec2(p.x + w - 16 - 110, by))
    if Ui.button(id .. "_o", ru("Настроить"), 110, 36) then onOpen() end
    imgui.SetCursorScreenPos(ImVec2(p.x + w - 16 - 110 - 10 - 124, by))
    if Ui.button(id .. "_t", running and ru("Остановить") or ru("Запустить"), 124, 36, running and "danger" or "accent") then onToggle() end

    imgui.SetCursorScreenPos(ImVec2(p.x, p.y + h))
    imgui.Dummy(ImVec2(w, 12))
end

--================= ������ ���� =================--
local W, H = 820, 560
local SB_X, SB_W = 10, 188
local CONTENT_X = 214
local TOP_H = 64

local TAB_HOME, TAB_FISH, TAB_TRUCK, TAB_TRAIN, TAB_OHOTA, TAB_SVALKA, TAB_CASE, TAB_LOOK, TAB_SET = 1, 2, 3, 4, 5, 6, 7, 8, 9

local Tabs = {
    { ru("Главная"), ru("Обзор модулей и управление"), 1 },
    { ru("Рыбалка"), ru("Автоматическая ловля и сбор улова"), 2 },
    { ru("Дальнобойщик"), ru("Автоматический выбор заказов"), 5 },
    { ru("Оформление"), ru("Цвета, прозрачность и HUD"), 3 },
    { ru("Настройки"), ru("Управление, уведомления и выход"), 4 },
    { ru("Поезд"), ru("Автопилот машиниста"), 5 },
}

local trainTab = table.remove(Tabs, 6)
table.insert(Tabs, 4, trainTab)
table.insert(Tabs, 5, { "\206\245\238\242\224", "\204\229\242\234\232, \239\240\232\246\229\235 \232 \243\242\232\235\232\242\251", 4 })
table.insert(Tabs, 6, { ru("Свалка"), ru("Метки предметов на свалке"), 3 })
table.insert(Tabs, 7, { ru("Кейсы"), ru("Автопокупка кейсов по таймеру"), 5 })

local State = {
    window = imgui.new.bool(false),
    tab = 1,
    dragPos = nil,
    lastMouse = nil,
}

--================= Кейсы =================--
caseCatcher = {
    enabled = imgui.new.bool(false),
    timerDuration = nil,
    timerStartedAt = nil,
    lastBuy = 0,
    quantities = {},
}

caseCatcher.categories = {
    { id = 30, name = ru("Форсаж") },
    { id = 31, name = ru("Темные дела") },
    { id = 32, name = ru("Весёлая ночь") },
    { id = 33, name = ru("Оперской") },
    { id = 34, name = ru("Новогодний") },
    { id = 35, name = ru("Черное золото") },
    { id = 36, name = ru("Охотники") },
    { id = 37, name = ru("Египетская сила") },
    { id = 38, name = ru("Весёлая ночь 2") },
    { id = 39, name = ru("Рождественский экспресс") },
    { id = 40, name = ru("Путь воина") },
    { id = 41, name = ru("Пиратский") },
    { id = 42, name = ru("Проклятие") },
    { id = 43, name = ru("Зимняя сказка") },
    { id = 44, name = ru("Бандитский кейс") },
    { id = 45, name = ru("Клоунский кейс") },
    { id = 46, name = ru("Мандариновый кейс") },
    { id = 47, name = ru("Тихая роскошь") },
    { id = 48, name = ru("Проклятие Велеса") },
}

for _, category in ipairs(caseCatcher.categories) do
    caseCatcher.quantities[category.id] = imgui.new.int(0)
end

local function sendCasePacket()
    local lines = {}
    for _, category in ipairs(caseCatcher.categories) do
        local quantity = caseCatcher.quantities[category.id][0]
        if quantity > 0 then lines[#lines + 1] = string.format("%d|0|0|%d", category.id, quantity) end
    end
    if #lines == 0 then return false end

    local bytes = {}
    local function wB(value) bytes[#bytes + 1] = value end
    local function wI32(value)
        for _ = 1, 4 do
            wB(value % 256)
            value = math.floor(value / 256)
        end
    end
    local function wS(value)
        wI32(#value)
        for i = 1, #value do wB(value:byte(i)) end
    end

    wB(0xD7); wB(0x02); wB(0x00); wI32(0)
    wS("DS_OnPlayerBuyCart")
    wI32(4); wB(100); wI32(#lines); wB(0x73)
    local encoded = {}
    for _, line in ipairs(lines) do encoded[#encoded + 1] = '"' .. line .. '"' end
    wS("[" .. table.concat(encoded, ",") .. "]")

    local bs = raknetNewBitStream()
    if not bs then return false end
    local ok, result = pcall(function()
        for i = 1, #bytes do raknetBitStreamWriteInt8(bs, bytes[i]) end
        return raknetSendBitStream(bs)
    end)
    pcall(raknetDeleteBitStream, bs)
    return ok and result ~= false
end

function caseCatcher.update()
    if not caseCatcher.enabled[0] or not caseCatcher.timerDuration or not caseCatcher.timerStartedAt then return end
    local currentTime = getGameTimer() / 1000
    local remaining = caseCatcher.timerDuration - (currentTime - caseCatcher.timerStartedAt)
    if remaining <= 0 and (currentTime - caseCatcher.lastBuy) >= 2 then
        local hasItems = false
        for _, quantity in pairs(caseCatcher.quantities) do
            if quantity[0] > 0 then hasItems = true break end
        end
        if hasItems and sendCasePacket() then
            caseCatcher.lastBuy = currentTime
            caseCatcher.timerStartedAt = currentTime - caseCatcher.timerDuration
            Notifications.push("success", ru("Кейсы"), ru("Заказ кейсов отправлен"))
        end
    end
end

function caseCatcher.onPacket(id, bs)
    if id ~= 215 then return end
    raknetBitStreamResetReadPointer(bs)
    raknetBitStreamReadInt8(bs)
    local rpcId = raknetBitStreamReadInt16(bs)
    raknetBitStreamReadInt32(bs)
    local count = raknetBitStreamReadInt8(bs)
    if rpcId == 2 and count and count > 0 and count < 128 then
        local parts = {}
        for _ = 1, count do
            local len = raknetBitStreamReadInt32(bs)
            if len and len > 0 and len < 10000 then
                local success, value = pcall(raknetBitStreamReadString, bs, len)
                if success and value and value ~= "" then parts[#parts + 1] = value end
            end
        end
        local text = table.concat(parts)
        if text:find("onServerResponse(22", 1, true) then
            local seconds = text:match("onServerResponse%(22,%s*'%[%[%d+%],%s*%[%d+%],%s*(%d+),")
            if seconds then
                caseCatcher.timerDuration = tonumber(seconds)
                caseCatcher.timerStartedAt = getGameTimer() / 1000
            end
        end
    end
    raknetBitStreamResetReadPointer(bs)
end

svalka.showPage = function()
    State.tab = TAB_SVALKA
    State.window[0] = true
end

local keyNames = { "INSERT", "F4", "HOME", "DELETE", "END" }
local keyCodes = { 0x2D, 0x73, 0x24, 0x2E, 0x23 }
local keyItems = imgui.new["const char*"][#keyNames](keyNames)

local posNames = { ru("Сверху по центру"), ru("Сверху слева"), ru("Сверху справа") }
for i, v in ipairs(posNames) do posNames[i] = u8(v) end
local posItems = imgui.new["const char*"][#posNames](posNames)

local function menuKeyCode() return keyCodes[S.menuKey[0] + 1] or 0x2D end

local function runningModule()
    if bot.on then return "fish" elseif truck.enabled then return "truck" elseif trainbot.enabled then return "train" elseif Ohota.enabled then return "hunt" elseif svalka.active[0] then return "svalka" elseif caseCatcher.enabled[0] then return "case" end
    return nil
end

local function currentModule()
    if State.tab == TAB_TRUCK then return "truck" end
    if State.tab == TAB_TRAIN then return "train" end
    if State.tab == TAB_OHOTA then return "hunt" end
    if State.tab == TAB_SVALKA then return "svalka" end
    if State.tab == TAB_CASE then return "case" end
    return "fish"
end

local MODULE_NAMES = {
    fish = "\208\251\225\224\235\234\224",
    truck = "\196\224\235\252\237\238\225\238\233\249\232\234",
    train = "\207\238\229\231\228",
    hunt = "\206\245\238\242\224",
    svalka = ru("Свалка"),
    case = ru("Кейсы"),
}

local function resetSettings()
    S.opacity[0] = DEFAULTS.Opacity
    S.accent[0], S.accent[1], S.accent[2] = DEFAULTS.AccentR, DEFAULTS.AccentG, DEFAULTS.AccentB
    S.hookMin[0], S.hookMax[0], S.hookDelay[0] = DEFAULTS.HookMin, DEFAULTS.HookMax, DEFAULTS.HookDelay
    S.t1[0], S.t2[0], S.t3[0] = DEFAULTS.Timeout1, DEFAULTS.Timeout2, DEFAULTS.Timeout3
    S.watchdog[0] = DEFAULTS.Watchdog
    S.pressEnter[0], S.enterDelay[0] = DEFAULTS.PressEnter, DEFAULTS.EnterDelay
    S.closeEsc[0], S.escDelay[0] = DEFAULTS.CloseEsc, DEFAULTS.EscDelay
    S.autoRestart[0] = DEFAULTS.AutoRestart
    S.stopAfter[0] = DEFAULTS.StopAfter
    S.chat[0], S.notifs[0] = DEFAULTS.ChatMsgs, DEFAULTS.Notifs
    S.hud[0], S.hudPos[0] = DEFAULTS.Hud, DEFAULTS.HudPos
    S.menuKey[0] = DEFAULTS.MenuKey
    S.truckMax[0] = DEFAULTS.TruckMax
    ffi.copy(S.truckPrice, tostring(DEFAULTS.TruckMinPrice))
    S.truckType[0] = DEFAULTS.TruckType
    S.truckDebug[0] = DEFAULTS.TruckDebug
    update_accent()
    save_config()
    Notifications.push("info", ru("Настройки"), ru("Настройки сброшены"))
end

--================= �������� =================--
local function renderHome(w)
    local dl = imgui.GetWindowDrawList()

    Ui.label(ru("Модули"))

    local fishStatus = bot.on and (STATE_NAMES[bot.state] .. "  |  " .. ru("Улов: ") .. stats.catches) or ru("Не запущена")
    Ui.moduleCard("m_fish", ru("Рыбалка"), ru("Автоматическая ловля и сбор улова"), 2, bot.on, fishStatus, w,
        toggleBot, function() State.tab = TAB_FISH end)

    local truckStatus = truck.enabled and ru("Идёт поиск заказа...") or (truck.last ~= "" and truck.last or ru("Не запущен"))
    Ui.moduleCard("m_truck", ru("Дальнобойщик"), ru("Автоматический выбор заказов"), 5, truck.enabled, truckStatus, w,
        toggleTrucking, function() State.tab = TAB_TRUCK end)

    Ui.moduleCard("m_train", ru("Поезд"), ru("Автопилот машиниста"), 5, trainbot.enabled,
        trainbot.enabled and ru("Автопилот включён") or ru("Ожидает запуска"), w,
        toggleTrain, function() State.tab = TAB_TRAIN end)

    Ui.moduleCard("m_hunt", ru("Охота"), ru("Метки, прицел и утилиты"), 4, Ohota.enabled,
        Ohota.enabled and ru("Охота включена") or ru("Готов к запуску"), w,
        toggleOhota, function() State.tab = TAB_OHOTA end)

    local enabledSvalkaItems = 0
    for _, item in ipairs(svalka.items) do
        if item.enabled[0] then enabledSvalkaItems = enabledSvalkaItems + 1 end
    end
    local svalkaStatus = svalka.active[0] and ru("Метки включены")
        or (svalka.loaded and (ru("Предметов выбрано: ") .. enabledSvalkaItems) or ru("Список предметов не загружен"))
    Ui.moduleCard("m_svalka", ru("Свалка"), ru("Метки предметов на свалке"), 3, svalka.active[0], svalkaStatus, w,
        svalka.toggle, svalka.showPage)

    local caseStatus = caseCatcher.enabled[0] and ru("Автопокупка включена") or ru("Ожидает запуска")
    Ui.moduleCard("m_case", ru("Кейсы"), ru("Автопокупка кейсов по таймеру"), 5, caseCatcher.enabled[0], caseStatus, w,
        function() caseCatcher.enabled[0] = not caseCatcher.enabled[0] end,
        function() State.tab = TAB_CASE end)

    -- ����� ��� ������� ������
    local pp = imgui.GetCursorScreenPos()
    dl:AddRect(pp, ImVec2(pp.x + w, pp.y + 56), u32(P.border, 0.6), 14, nil, 1)
    local msg = u8(ru("+  Здесь появится новый модуль"))
    text(dl, pp.x + (w - textWidth(msg, Fonts.smallBold)) * 0.5, pp.y + 20, u32(P.dim), msg, Fonts.smallBold)
    imgui.Dummy(ImVec2(w, 56))
    imgui.Dummy(ImVec2(w, 16))

    -- ������
    local lp = imgui.GetCursorScreenPos()
    dl:AddRectFilled(ImVec2(lp.x + 2, lp.y + 5), ImVec2(lp.x + 5, lp.y + 17), u32(P.accent), 1)
    text(dl, lp.x + 12, lp.y + 3, u32(P.muted), u8(ru("Журнал событий")), Fonts.smallBold)
    local n = math.min(#Log, 5)
    local hh = math.max(n, 1) * 30 + 8
    local top = lp.y + 26
    dl:AddRectFilled(ImVec2(lp.x, top), ImVec2(lp.x + w, top + hh), u32(P.card), 12)
    dl:AddRect(ImVec2(lp.x, top), ImVec2(lp.x + w, top + hh), u32(P.border, 0.7), 12, nil, 1)
    if n == 0 then
        text(dl, lp.x + 16, top + 14, u32(P.dim), u8(ru("Записей пока нет")), Fonts.smallBold)
    else
        for i = 1, n do
            local e = Log[i]
            local ry = top + 4 + (i - 1) * 30
            dl:AddCircleFilled(ImVec2(lp.x + 20, ry + 15), 3, u32(e.kind == "success" and P.success or P.dim), 10)
            text(dl, lp.x + 34, ry + 8, u32(P.dim), u8(e.time), Fonts.smallBold)
            text(dl, lp.x + 108, ry + 8, u32(P.text), u8(e.msg), Fonts.smallBold)
            if i < n then
                dl:AddLine(ImVec2(lp.x + 16, ry + 30), ImVec2(lp.x + w - 16, ry + 30), u32(P.border, 0.35), 1)
            end
        end
    end
    imgui.SetCursorScreenPos(ImVec2(lp.x, top + hh))
    imgui.Dummy(ImVec2(w, 12))
end

local function renderFishOverview(w)
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local ch = 112

    dl:AddRectFilled(p, ImVec2(p.x + w, p.y + ch), u32(P.card), 14)
    if bot.on then
        dl:AddRectFilledMultiColor(p, ImVec2(p.x + w, p.y + ch),
            u32(P.accent, 0.14), u32(P.accent, 0.02), u32(P.accent, 0.02), u32(P.accent, 0.14))
    end
    dl:AddRect(p, ImVec2(p.x + w, p.y + ch), u32(bot.on and P.accent or P.border, bot.on and 0.55 or 0.7), 14, nil, 1)

    local pulse = bot.on and (1.5 * math_sin(now() * 4)) or 0
    dl:AddCircleFilled(ImVec2(p.x + 28, p.y + 29), 6 + pulse, u32(bot.on and P.success or P.dim), 16)
    text(dl, p.x + 46, p.y + 16, u32(P.text), u8(bot.on and ru("Запущена") or ru("Остановлена")), Fonts.heading)
    local range = u8(ru("Порог подсечки: ") .. S.hookMin[0] .. "-" .. S.hookMax[0] .. "%")
    text(dl, p.x + w - 16 - textWidth(range, Fonts.smallBold), p.y + 22, u32(P.dim), range, Fonts.smallBold)

    local steps = { ru("Ожидание"), ru("Подсечка"), ru("Сбор улова") }
    local sx = p.x + 20
    for i, name in ipairs(steps) do
        local label = u8(name)
        local tw = textWidth(label, Fonts.smallBold) + 28
        local isActive = bot.on and bot.state == i
        local isDone = bot.on and bot.state > i
        local col = isActive and P.accent or (isDone and P.success or P.dim)
        local sy = p.y + 66
        dl:AddRectFilled(ImVec2(sx, sy), ImVec2(sx + tw, sy + 28), u32(col, isActive and 0.28 or 0.10), 14)
        dl:AddRect(ImVec2(sx, sy), ImVec2(sx + tw, sy + 28), u32(col, isActive and 0.9 or 0.35), 14, nil, 1)
        text(dl, sx + 14, sy + 7, u32(isActive and P.text or (isDone and P.success or P.muted)), label, Fonts.smallBold)
        sx = sx + tw
        if i < #steps then
            dl:AddLine(ImVec2(sx + 6, p.y + 80), ImVec2(sx + 22, p.y + 80), u32(P.border, 0.9), 1.5)
            sx = sx + 28
        end
    end
    imgui.SetCursorScreenPos(ImVec2(p.x, p.y + ch))
    imgui.Dummy(ImVec2(w, 12))

    local gap = 10
    local cw = (w - gap * 3) / 4
    local sp = imgui.GetCursorScreenPos()
    local rt = runTime()
    local perHour = rt >= 60 and (stats.catches / (rt / 3600)) or 0
    Ui.statCard(ru("Улов"), tostring(stats.catches), P.success, cw, 68)
    imgui.SetCursorScreenPos(ImVec2(sp.x + (cw + gap), sp.y))
    Ui.statCard(ru("Время работы"), fmtTime(rt), P.accent, cw, 68)
    imgui.SetCursorScreenPos(ImVec2(sp.x + (cw + gap) * 2, sp.y))
    Ui.statCard(ru("Улов в час"), string.format("%.0f", perHour), P.warning, cw, 68)
    imgui.SetCursorScreenPos(ImVec2(sp.x + (cw + gap) * 3, sp.y))
    Ui.statCard(ru("Перезапуски"), tostring(stats.restarts), P.muted, cw, 68)
    imgui.SetCursorScreenPos(ImVec2(sp.x, sp.y + 68))
    imgui.Dummy(ImVec2(w, 16))
end

local function renderBot(w)
    renderFishOverview(w)

    Ui.group(ru("Подсечка"), {
        { kind = "custom", h = 66, draw = function(x, y, wd, h)
            local dl = imgui.GetWindowDrawList()
            local mn, mx = S.hookMin[0], S.hookMax[0]
            text(dl, x + 16, y + 10, u32(P.text), u8(ru("Порог подсечки")), Fonts.bold)
            local rng = mn .. "% - " .. mx .. "%"
            text(dl, x + wd - 16 - textWidth(rng, Fonts.bold), y + 10, u32(P.accent), rng, Fonts.bold)
            local bx1, bx2, by = x + 16, x + wd - 16, y + 44
            local bw = bx2 - bx1
            dl:AddRectFilled(ImVec2(bx1, by), ImVec2(bx2, by + 8), u32(P.cardHi), 4)
            local zx1, zx2 = bx1 + bw * mn / 100, bx1 + bw * mx / 100
            dl:AddRectFilledMultiColor(ImVec2(zx1, by), ImVec2(math.max(zx2, zx1 + 2), by + 8),
                u32(P.accent, 0.55), u32(P.accent, 1), u32(P.accent, 1), u32(P.accent, 0.55))
            dl:AddCircleFilled(ImVec2(zx1, by + 4), 6, u32(P.text), 14)
            dl:AddCircleFilled(ImVec2(zx2, by + 4), 6, u32(P.text), 14)
            dl:AddCircleFilled(ImVec2(zx1, by + 4), 3, u32(P.accent), 10)
            dl:AddCircleFilled(ImVec2(zx2, by + 4), 3, u32(P.accent), 10)
        end },
        { kind = "slider", id = "hmin", title = "Мин.", desc = ru("Минимальный порог подсечки"),
          ptr = S.hookMin, mn = 0, mx = 100, fmt = "%d%%",
          onChange = function() if S.hookMin[0] > S.hookMax[0] then S.hookMax[0] = S.hookMin[0] end end },
        { kind = "slider", id = "hmax", title = "Макс.", desc = ru("Максимальный порог подсечки"),
          ptr = S.hookMax, mn = 0, mx = 100, fmt = "%d%%",
          onChange = function() if S.hookMax[0] < S.hookMin[0] then S.hookMin[0] = S.hookMax[0] end end },
        { kind = "slider", id = "hdelay", title = ru("Задержка"), desc = ru("Пауза перед подсечкой, 0 — без задержки"),
          ptr = S.hookDelay, mn = 0, mx = 500, fmt = "%d " .. ru("мс") },
    })

    Ui.group(ru("Действия после улова"), {
        { kind = "switch", id = "enter", title = ru("Нажимать Enter"), desc = ru("Подтверждать окно после улова"), ptr = S.pressEnter },
        { kind = "slider", id = "enterdelay", title = ru("Задержка Enter"), desc = ru("Пауза перед нажатием Enter"),
          ptr = S.enterDelay, mn = 0, mx = 1000, fmt = "%d " .. ru("мс") },
        { kind = "switch", id = "esc", title = ru("Закрывать окно (ESC)"), desc = ru("Нажать ESC после улова"), ptr = S.closeEsc },
        { kind = "slider", id = "escdelay", title = ru("Задержка ESC"), desc = ru("Пауза перед закрытием окна"),
          ptr = S.escDelay, mn = 0, mx = 1000, fmt = "%d " .. ru("мс") },
        { kind = "switch", id = "autorestart", title = ru("Автоперезапуск"), desc = ru("Перезапускать рыбалку после улова"), ptr = S.autoRestart },
        { kind = "slider", id = "stopafter", title = ru("Остановить после N уловов"), desc = ru("0 — без ограничений"),
          ptr = S.stopAfter, mn = 0, mx = 500, fmt = "%d " .. ru("шт.") },
    })

    Ui.group(ru("Защита от зависания"), {
        { kind = "switch", id = "watchdog", title = ru("Автоперезапуск"), desc = ru("Перезапускать рыбалку при зависании"), ptr = S.watchdog },
        { kind = "slider", id = "t1", title = ru("Таймаут ожидания"), desc = ru("Время ожидания поклёвки"),
          ptr = S.t1, mn = 5, mx = 90, fmt = "%d " .. ru("сек.") },
        { kind = "slider", id = "t2", title = ru("Таймаут подсечки"), desc = ru("Время ожидания подсечки"),
          ptr = S.t2, mn = 2, mx = 60, fmt = "%d " .. ru("сек.") },
        { kind = "slider", id = "t3", title = ru("Таймаут сбора"), desc = ru("Время ожидания сбора улова"),
          ptr = S.t3, mn = 2, mx = 60, fmt = "%d " .. ru("сек.") },
    })
end

local function renderTruck(w)
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local ch = 92

    dl:AddRectFilled(p, ImVec2(p.x + w, p.y + ch), u32(P.card), 14)
    if truck.enabled then
        dl:AddRectFilledMultiColor(p, ImVec2(p.x + w, p.y + ch),
            u32(P.accent, 0.14), u32(P.accent, 0.02), u32(P.accent, 0.02), u32(P.accent, 0.14))
    end
    dl:AddRect(p, ImVec2(p.x + w, p.y + ch), u32(truck.enabled and P.accent or P.border, truck.enabled and 0.55 or 0.7), 14, nil, 1)

    local pulse = truck.enabled and (1.5 * math_sin(now() * 4)) or 0
    dl:AddCircleFilled(ImVec2(p.x + 28, p.y + 29), 6 + pulse, u32(truck.enabled and P.success or P.dim), 16)
    text(dl, p.x + 46, p.y + 16, u32(P.text), u8(truck.enabled and ru("Идёт поиск заказа...") or ru("Остановлен")), Fonts.heading)
    local last = truck.last ~= "" and truck.last or ru("Заказы не найдены — будет повторный поиск")
    text(dl, p.x + 46, p.y + 52, u32(P.muted), u8(last), Fonts.smallBold)
    local info = u8((S.truckType[0] == 0 and ru("Товары") or ru("Топливо")) .. "  |  " .. ru("от ") .. ffi.string(S.truckPrice) .. ru(" руб."))
    text(dl, p.x + w - 16 - textWidth(info, Fonts.smallBold), p.y + 22, u32(P.dim), info, Fonts.smallBold)
    imgui.SetCursorScreenPos(ImVec2(p.x, p.y + ch))
    imgui.Dummy(ImVec2(w, 16))

    Ui.group(ru("Параметры заказа"), {
        { kind = "custom", title = ru("Тип груза"), desc = ru("Выберите нужную категорию"), draw = function(x, y, wd, h)
            local bw = 104
            local bx = x + wd - 16 - bw * 2 - 8
            imgui.SetCursorScreenPos(ImVec2(bx, y + (h - 32) * 0.5))
            if Ui.button("t_goods", ru("Товары"), bw, 32, S.truckType[0] == 0 and "accent" or "default") then
                S.truckType[0] = 0; markDirty()
            end
            imgui.SetCursorScreenPos(ImVec2(bx + bw + 8, y + (h - 32) * 0.5))
            if Ui.button("t_fuel", ru("Топливо"), bw, 32, S.truckType[0] == 1 and "accent" or "default") then
                S.truckType[0] = 1; markDirty()
            end
        end },
        { kind = "custom", title = ru("Минимальная выплата"), desc = ru("Брать только заказы дороже этой суммы"), draw = function(x, y, wd, h)
            local dl2 = imgui.GetWindowDrawList()
            text(dl2, x + wd - 16 - 34, y + (h - 18) * 0.5, u32(P.accent), u8(ru("руб.")), Fonts.bold)
            imgui.SetCursorScreenPos(ImVec2(x + wd - 16 - 34 - 10 - 130, y + (h - 22) * 0.5))
            imgui.PushItemWidth(130)
            if imgui.InputText("##minprice", S.truckPrice, 128, imgui.InputTextFlags.CharsDecimal) then markDirty() end
            imgui.PopItemWidth()
        end },
        { kind = "switch", id = "tmax", title = ru("Брать максимальный заказ"), desc = ru("Выбрать самый дорогой, если нет заказа выше минимума"), ptr = S.truckMax },
    })

    Ui.group(ru("Отладка"), {
        { kind = "switch", id = "tdebug", title = ru("Запись лога пакетов"), desc = ru("Файл SofterRadmiraTrucking_debug.log в папке moonloader"), ptr = S.truckDebug },
    })
end

local function renderTrain(w)
    Ui.group(ru("Состояние автопилота"), {
        { title = trainbot.enabled and ru("В пути") or ru("Остановлен"),
          desc = ru("Автоматическое управление поездом") },
        { title = ru("Станция"), desc = trainbot.station ~= "" and trainbot.station or ru("Ожидание станции") },
        { title = ru("Расстояние"), desc = trainbot.distance < 99999 and string.format("%.0f " .. ru("м"), trainbot.distance) or ru("Нет данных") },
        { title = ru("Скорость"), desc = string.format("%d-%d " .. ru("км/ч"), trainbot.speed.min, trainbot.speed.max) },
        { kind = "button", id = "train_toggle", title = ru("Управление поездом"),
          desc = ru("Запустить или остановить автопилот"), label = trainbot.enabled and ru("Остановить") or ru("Запустить"),
          variant = trainbot.enabled and "danger" or "accent", onClick = toggleTrain },
    })
end

local function renderCase(w)
    local remainingText = "--:--:--"
    if caseCatcher.timerDuration and caseCatcher.timerStartedAt then
        local remaining = caseCatcher.timerDuration - (getGameTimer() / 1000 - caseCatcher.timerStartedAt)
        if remaining > 0 then
            remainingText = string.format("%02d:%02d:%02d",
                math.floor(remaining / 3600),
                math.floor((remaining % 3600) / 60),
                math.floor(remaining % 60))
        else
            remainingText = "00:00:00"
        end
    end

    Ui.group(ru("Автопокупка кейсов"), {
        { kind = "switch", id = "case_enabled", title = ru("Автопокупка"),
          desc = ru("Отправлять корзину при истечении таймера"), ptr = caseCatcher.enabled },
        { title = ru("До следующей покупки"), desc = remainingText },
    })

    Ui.group(ru("Количества"), {
        { kind = "custom", h = #caseCatcher.categories * 42, draw = function(x, y, wd, h)
            local cy = y
            for _, category in ipairs(caseCatcher.categories) do
                local quantity = caseCatcher.quantities[category.id]
                text(imgui.GetWindowDrawList(), x + 16, cy + 10, u32(P.text), u8(category.name), Fonts.bold)
                local controlsX = x + wd - 118
                imgui.SetCursorScreenPos(ImVec2(controlsX, cy))
                if Ui.button("case_minus_" .. category.id, "-", 32, 32, "default") then
                    quantity[0] = math.max(0, quantity[0] - 1)
                end
                text(imgui.GetWindowDrawList(), controlsX + 38, cy + 8, u32(P.text), tostring(quantity[0]), Fonts.bold)
                imgui.SetCursorScreenPos(ImVec2(controlsX + 54, cy))
                if Ui.button("case_plus_" .. category.id, "+", 32, 32, "accent") then
                    quantity[0] = math.min(99, quantity[0] + 1)
                end
                cy = cy + 42
            end
        end },
    })
end

local function renderOhota(w)
    Ui.group(nil, {
        { kind = "custom", h = 70, title = "\204\238\228\243\235\252 \238\245\238\242\251",
          desc = Ohota.enabled and "\208\224\225\238\242\224\229\242" or "\194\251\234\235\254\247\229\237", draw = function(x, y, wd, h)
            imgui.SetCursorScreenPos(ImVec2(x + wd - 16 - 132, y + (h - 34) * 0.5))
            if Ui.button("hunt_toggle", Ohota.enabled and "\206\241\242\224\237\238\226\232\242\252" or "\199\224\239\243\241\242\232\242\252", 132, 34,
                Ohota.enabled and "danger" or "accent") then
                toggleOhota()
            end
        end },
    })

    local availableWidth = imgui.GetContentRegionAvail().x
    local columnGap = 10
    local columnWidth = (availableWidth - columnGap) * 0.5

    imgui.BeginChild("##ohota_display", ImVec2(columnWidth, 462), false)
    Ui.group("\206\242\238\225\240\224\230\229\237\232\229", {
        { kind = "switch", id = "hunt_esp", title = "\207\238\234\224\231\251\226\224\242\252 \230\232\226\238\242\237\251\245", desc = "\207\238\228\239\232\241\232 \232 \231\228\238\240\238\226\252\229", ptr = Ohota.wh, onChange = markOhotaDirty },
        { kind = "switch", id = "hunt_players", title = "\194\232\228\229\242\252 \232\227\240\238\234\238\226", desc = "\206\242\236\229\247\224\242\252 \240\255\228\238\236 \241 \230\232\226\238\242\237\251\236\232", ptr = Ohota.players, onChange = markOhotaDirty },
        { kind = "switch", id = "hunt_headdot", title = "\204\229\242\234\224 \227\238\235\238\226\251", desc = "\206\242\236\229\247\224\242\252 \227\238\235\238\226\243 \230\232\226\238\242\237\238\227\238", ptr = Ohota.headDot, onChange = markOhotaDirty },
        { kind = "switch", id = "hunt_dead", title = "\211\225\232\242\251\229 \230\232\226\238\242\237\251\229", desc = "\204\229\242\234\232 \238\241\242\224\254\242\241\255 \228\238 \241\225\238\240\224", ptr = Ohota.dead, onChange = markOhotaDirty },
        { kind = "switch", id = "hunt_distance", title = "\208\224\241\241\242\238\255\237\232\229", desc = "\196\238\225\224\226\235\255\242\252 \236\229\242\240\251 \226 \239\238\228\239\232\241\252", ptr = Ohota.distance, onChange = markOhotaDirty },
    })
    Ui.group("\214\226\229\242\224 \239\238\228\239\232\241\229\233", {
        { kind = "combo", id = "hunt_live_color", title = "\214\226\229\242 \230\232\226\251\245", ptr = Ohota.liveLabelColor,
          items = ohotaLiveColorItems, count = #OHOTA_LIVE_COLORS, cw = 120, onChange = markOhotaDirty },
        { kind = "combo", id = "hunt_dead_color", title = "\214\226\229\242 \243\225\232\242\251\245", ptr = Ohota.deadLabelColor,
          items = ohotaDeadColorItems, count = #OHOTA_DEAD_COLORS, cw = 120, onChange = markOhotaDirty },
    })
    imgui.EndChild()
    imgui.SameLine(0, columnGap)

    imgui.BeginChild("##ohota_tools", ImVec2(columnWidth, 462), false)
    Ui.group("\203\232\237\232\232 \228\238 \230\232\226\238\242\237\251\245", {
        { kind = "switch", id = "hunt_tracers", title = "\207\238\234\224\231\251\226\224\242\252 \235\232\237\232\232", desc = "\203\232\237\232\232 \234 \230\232\226\251\236 \232 \243\225\232\242\251\236", ptr = Ohota.tracers, onChange = markOhotaDirty },
        { kind = "combo", id = "hunt_tracer_color", title = "\214\226\229\242", ptr = Ohota.tracerColor,
          items = ohotaTracerColorItems, count = #OHOTA_TRACER_COLORS, cw = 120, onChange = markOhotaDirty },
        { kind = "sliderf", id = "hunt_tracer_width", title = "\210\238\235\249\232\237\224 \235\232\237\232\232",
          ptr = Ohota.tracerWidth, mn = 1, mx = 5, fmt = "%.1f", sw = 120, onChange = markOhotaDirty },
    })
    Ui.group("\207\240\232\246\229\235 \232 \243\242\232\235\232\242\251", {
        { kind = "switch", id = "hunt_aim", title = "\192\226\242\238\237\224\226\229\228\229\237\232\229", desc = "\205\224\226\229\228\229\237\232\229 \237\224 \227\238\235\238\226\243", ptr = Ohota.aim, onChange = function()
            if not Ohota.aim[0] then Ohota.aimHandle = nil end
            markOhotaDirty()
        end },
        { kind = "switch", id = "hunt_clearanimals", title = "\206\247\232\241\242\234\224 \237\229\239\238\228\226\232\230\237\251\245", desc = "\211\228\224\235\255\242\252 \247\229\240\229\231 20 \241\229\234\243\237\228", ptr = Ohota.clear, onChange = markOhotaDirty },
        { kind = "switch", id = "hunt_autoy", title = "\192\226\242\238\237\224\230\224\242\232\229 Y", desc = "\207\238\226\242\238\240\255\242\252 Y \239\240\232 \241\225\238\240\229", ptr = Ohota.autoY, onChange = function()
            if not Ohota.autoY[0] then Ohota.autoYClicker:Stop() end
            markOhotaDirty()
        end },
        { title = "\192\226\242\238\241\238\245\240\224\237\229\237\232\229", desc = "\205\224\241\242\240\238\233\234\232 \241\238\245\240\224\237\255\254\242\241\255 \224\226\242\238\236\224\242\232\247\229\241\234\232" },
    })
    imgui.EndChild()
end

svalka.setCommand = function(key, buffer)
    local command = ffi.string(buffer)
    local current = svalka.settings[key]
    if command == current then return end
    if current ~= "" then sampUnregisterChatCommand(current) end
    svalka.settings[key] = command
    if command ~= "" then
        if key == "cmd" then
            sampRegisterChatCommand(command, svalka.showPage)
        else
            sampRegisterChatCommand(command, svalka.toggle)
        end
    end
    svalka.requestSave()
end

svalka.loadNextTexture = function()
    for _, item in ipairs(svalka.items) do
        if item.image_base64 then
            local png = svalka.decodeBase64(item.image_base64)
            item.texture = imgui.CreateTextureFromFileInMemory(png, #png)
            item.image_base64 = nil
            return
        end
    end
end

svalka.render = function(w)
    if not svalka.loaded then
        Ui.group(ru("Свалка"), {
            { title = ru("Список предметов недоступен"), desc = svalka.error or ru("Проверьте config\\svalka_items.json") },
        })
        return
    end

    Ui.group(ru("Состояние"), {
        { kind = "custom", h = 70,
          title = svalka.active[0] and ru("Поиск меток активен") or ru("Метки остановлены"),
          desc = ru("Отображение выбранных предметов на свалке"),
          draw = function(x, y, wd, h)
              imgui.SetCursorScreenPos(ImVec2(x + wd - 16 - 132, y + (h - 34) * 0.5))
              if Ui.button("svalka_toggle", svalka.active[0] and ru("Остановить") or ru("Запустить"),
                  132, 34, svalka.active[0] and "danger" or "accent") then
                  svalka.toggle()
              end
          end },
    })

    Ui.group(ru("Оформление меток"), {
        { kind = "custom", title = ru("Толщина линии"), desc = ru("Ширина линии до предмета"),
          draw = function(x, y, wd, h)
              imgui.SetCursorScreenPos(ImVec2(x + wd - 16 - 120, y + (h - 22) * 0.5))
              imgui.PushItemWidth(120)
              if imgui.InputInt("##svalka_thickness", svalka.thickness, 0, 0) then
                  svalka.settings.sizetr = svalka.thickness[0]
                  svalka.requestSave()
              end
              imgui.PopItemWidth()
          end },
        { kind = "custom", title = ru("Цвет линии"), desc = ru("Цвет соединения с предметом"),
          draw = function(x, y, wd, h)
              imgui.SetCursorScreenPos(ImVec2(x + wd - 16 - 150, y + (h - 22) * 0.5))
              imgui.PushItemWidth(150)
              if imgui.Combo("##svalka_line_color", svalka.lineColor, svalka.colorsConst, #svalka.colors) then
                  svalka.settings.colortr = svalka.lineColor[0]
                  svalka.requestSave()
              end
              imgui.PopItemWidth()
          end },
        { kind = "custom", title = ru("Цвет подписи"), desc = ru("Цвет названия и расстояния"),
          draw = function(x, y, wd, h)
              imgui.SetCursorScreenPos(ImVec2(x + wd - 16 - 150, y + (h - 22) * 0.5))
              imgui.PushItemWidth(150)
              if imgui.Combo("##svalka_text_color", svalka.textColor, svalka.colorsConst, #svalka.colors) then
                  svalka.settings.colortx = svalka.textColor[0]
                  svalka.requestSave()
              end
              imgui.PopItemWidth()
          end },
    })

    Ui.group(ru("Команды"), {
        { kind = "custom", title = ru("Открыть страницу"), desc = ru("Команда для перехода к модулю в Hub"),
          draw = function(x, y, wd, h)
              imgui.SetCursorScreenPos(ImVec2(x + wd - 16 - 150, y + (h - 22) * 0.5))
              imgui.PushItemWidth(150)
              if imgui.InputText("##svalka_open_command", svalka.openCommand, ffi.sizeof(svalka.openCommand)) then
                  svalka.setCommand("cmd", svalka.openCommand)
              end
              imgui.PopItemWidth()
          end },
        { kind = "custom", title = ru("Переключить метки"), desc = ru("Команда для запуска и остановки"),
          draw = function(x, y, wd, h)
              imgui.SetCursorScreenPos(ImVec2(x + wd - 16 - 150, y + (h - 22) * 0.5))
              imgui.PushItemWidth(150)
              if imgui.InputText("##svalka_toggle_command", svalka.toggleCommand, ffi.sizeof(svalka.toggleCommand)) then
                  svalka.setCommand("cmdact", svalka.toggleCommand)
              end
              imgui.PopItemWidth()
          end },
    })

    Ui.label(ru("Список предметов"))
    svalka.loadNextTexture()
    imgui.BeginChild("##svalka_items", ImVec2(0, 270), true)
    for _, item in ipairs(svalka.items) do
        if imgui.Checkbox(item.checkbox_id, item.enabled) then
            svalka.whobjects[item.key] = item.enabled[0]
            svalka.requestSave()
        end
        imgui.SameLine(nil, 10)
        if item.texture then
            imgui.Image(item.texture, ImVec2(46, 46))
        else
            imgui.Dummy(ImVec2(46, 46))
        end
        imgui.SameLine(nil, 10)
        imgui.BeginGroup()
        imgui.TextWrapped("%s", item.item_name)
        imgui.TextDisabled(u8(ru("Модель: ") .. tostring(item.model_id)))
        imgui.EndGroup()
        imgui.Separator()
    end
    imgui.EndChild()
end

local function renderInterface(w)
    local presets = {
        { 0.92, 0.16, 0.22 }, { 1.00, 0.30, 0.15 }, { 0.80, 0.08, 0.35 },
        { 1.00, 0.45, 0.50 }, { 0.90, 0.90, 0.92 },
        { 0.58, 0.30, 0.95 },
    }

    Ui.group(ru("Внешний вид"), {
        { kind = "sliderf", id = "opacity", title = ru("Прозрачность окна"), desc = ru("Общая прозрачность меню"),
          ptr = S.opacity, mn = 0.3, mx = 1.0, fmt = "%.2f" },
        { kind = "custom", title = ru("Цвет интерфейса"), desc = ru("Выберите основной цвет меню"), draw = function(x, y, wd, h)
            local dl = imgui.GetWindowDrawList()
            local swSize = 28
            local sx = x + wd - 16 - 150 - 14 - (#presets * (swSize + 4))
            for i, preset in ipairs(presets) do
                imgui.SetCursorScreenPos(ImVec2(sx + (i - 1) * (swSize + 4), y + (h - swSize) * 0.5))
                local p = imgui.GetCursorScreenPos()
                imgui.InvisibleButton("##preset" .. i, ImVec2(swSize, swSize))
                local hovered = imgui.IsItemHovered()
                local cx, cy = p.x + swSize * 0.5, p.y + swSize * 0.5
                dl:AddCircleFilled(ImVec2(cx, cy), swSize * 0.34, u32(preset), 24)
                if hovered then dl:AddCircle(ImVec2(cx, cy), swSize * 0.42, u32(P.text, 0.6), 28, 1) end
                local selected = math_abs(preset[1] - S.accent[0]) < 0.01
                             and math_abs(preset[2] - S.accent[1]) < 0.01
                             and math_abs(preset[3] - S.accent[2]) < 0.01
                if selected then dl:AddCircle(ImVec2(cx, cy), swSize * 0.47, u32(P.text), 28, 1.5) end
                if imgui.IsItemClicked() then
                    S.accent[0], S.accent[1], S.accent[2] = preset[1], preset[2], preset[3]
                    update_accent()
                    markDirty()
                end
            end
            imgui.SetCursorScreenPos(ImVec2(x + wd - 16 - 150, y + (h - 22) * 0.5))
            imgui.PushItemWidth(150)
            if imgui.ColorEdit3("##custom", S.accent) then
                update_accent()
                markDirty()
            end
            imgui.PopItemWidth()
        end },
    })

    Ui.group(ru("Интерфейс HUD"), {
        { kind = "switch", id = "hud", title = ru("Показывать HUD"), desc = ru("Отображать статус работающего модуля"), ptr = S.hud },
        { kind = "combo", id = "hudpos", title = ru("Позиция HUD"), ptr = S.hudPos, items = posItems, count = #posNames, cw = 190 },
    })
end

local function renderScript(w)
    Ui.group(ru("Управление"), {
        { kind = "combo", id = "menukey", title = ru("Клавиша меню"), desc = ru("Открыть или закрыть меню"),
          ptr = S.menuKey, items = keyItems, count = #keyNames, cw = 140 },
        { title = ru("Команды"), desc = ru("/sfradmira — меню, /fb — рыбалка, /truck — дальнобойщик") },
        { title = ru("Поезд"), desc = ru("/msh — переключить, /train — открыть страницу поезда") },
        { title = "\206\245\238\242\224", desc = "/les - \238\242\234\240\251\242\252 \241\242\240\224\237\232\246\243, /ohota - \239\229\240\229\234\235\254\247\232\242\252 \236\238\228\243\235\252" },
        { title = ru("Свалка"), desc = ru("/") .. svalka.settings.cmd .. ru(" — страница, /") .. svalka.settings.cmdact .. ru(" — включить или выключить метки") },
        { title = ru("Кейсы"), desc = ru("/case — открыть страницу автопокупки кейсов") },
    })

    Ui.group(ru("Обновления"), {
        { title = ru("Источник"), desc = "github.com/lunguvictor/SofterRadmiraHub / main" },
        { title = ru("Состояние"), desc = svalka.updater.message },
        { kind = "button", id = "check_hub_update", title = ru("Проверить сейчас"),
          desc = ru("Получить изменения из GitHub без создания релиза"),
          label = ru("Проверить"), variant = "accent", onClick = svalka.checkUpdate },
    })

    Ui.group(ru("Уведомления"), {
        { kind = "switch", id = "chat", title = ru("Сообщения в чате"), desc = ru("Показывать сообщения о работе модулей"), ptr = S.chat },
        { kind = "switch", id = "notifs", title = ru("Экранные уведомления"), desc = ru("Показывать уведомления при запуске и остановке"), ptr = S.notifs },
    })

    Ui.group(ru("Действия"), {
        { kind = "button", id = "resetstats", title = ru("Сбросить статистику"), desc = ru("Очистить улов, время и журнал"),
          label = ru("Сбросить"), onClick = function()
            stats.catches, stats.restarts = 0, 0
            bot.runAccum = 0
            bot.startedAt = os.time()
            Log = {}
            Notifications.push("info", ru("Статистика"), ru("Статистика сброшена"))
        end },
        { kind = "button", id = "resetcfg", title = ru("Сбросить настройки"), desc = ru("Вернуть настройки по умолчанию"),
          label = ru("Сбросить"), variant = "danger", onClick = resetSettings },
    })

    Ui.group(ru("Перезапуск и выход v") .. VERSION, {
        { kind = "button", id = "reload", title = ru("Перезагрузить скрипт"), desc = ru("Сохранить настройки и перезапустить"),
          label = ru("Перезагрузить"), variant = "accent", onClick = function()
            save_config()
            thisScript():reload()
        end },
        { kind = "button", id = "unload", title = ru("Выгрузить скрипт"), desc = ru("Остановить и выгрузить скрипт"),
          label = ru("Выгрузить"), variant = "danger", onClick = function()
            save_config()
            thisScript():unload()
        end },
    })
end

--================= ����� ���� =================--
local function dragArea(id, x, y, w, h, winPos)
    imgui.SetCursorPos(ImVec2(x, y))
    imgui.InvisibleButton(id, ImVec2(w, h))
    if imgui.IsItemActive() then
        local mp = imgui.GetIO().MousePos
        if State.lastMouse then
            local cur = State.dragPos or winPos
            State.dragPos = ImVec2(cur.x + mp.x - State.lastMouse.x, cur.y + mp.y - State.lastMouse.y)
        end
        State.lastMouse = ImVec2(mp.x, mp.y)
    elseif State.lastMouse and not imgui.IsMouseDown(0) then
        State.lastMouse = nil
    end
end

local function renderSidebar(winPos)
    local dl = imgui.GetWindowDrawList()
    local px, py = winPos.x + SB_X, winPos.y + SB_X

    dl:AddRectFilled(ImVec2(px, py), ImVec2(px + SB_W, py + H - SB_X * 2), u32(P.card, 0.92), 14)
    dl:AddRectFilledMultiColor(ImVec2(px + 1, py + 1), ImVec2(px + SB_W - 1, py + 150),
        u32(P.accent, 0.10), u32(P.accent, 0.10), u32(P.accent, 0), u32(P.accent, 0))
    dl:AddRect(ImVec2(px, py), ImVec2(px + SB_W, py + H - SB_X * 2), u32(P.border, 0.8), 14, nil, 1)

    dragArea("##drag_logo", SB_X, SB_X, SB_W, 66, winPos)
    local lx, ly = px + 14, py + 14
    for i = 6, 1, -1 do
        dl:AddRect(ImVec2(lx - i, ly - i), ImVec2(lx + 36 + i, ly + 36 + i), u32(P.accent, 0.03 * (7 - i)), 10 + i, nil, 1.5)
    end
    dl:AddRectFilled(ImVec2(lx, ly), ImVec2(lx + 36, ly + 36), u32(P.accent, 0.22), 10)
    if hubLogoTexture then
        dl:AddImageRounded(hubLogoTexture, ImVec2(lx, ly), ImVec2(lx + 36, ly + 36),
            ImVec2(0, 0), ImVec2(1, 1), 0xFFFFFFFF, 10)
    else
        drawFishIcon(dl, lx + 18, ly + 18, { 1.0, 0.45, 0.48 })
    end
    dl:AddRect(ImVec2(lx, ly), ImVec2(lx + 36, ly + 36), u32(P.accent, 0.85), 10, nil, 1.2)
    text(dl, lx + 46, ly + 2, u32(P.text), "SofterRadmira", Fonts.bold)
    text(dl, lx + 46, ly + 21, u32(P.dim), u8("Hub  v" .. VERSION), Fonts.smallBold)

    -- ���������
    local navY = 78
    for i, tab in ipairs(Tabs) do
        imgui.SetCursorPos(ImVec2(SB_X + 10, navY + (i - 1) * 32))
        imgui.InvisibleButton("##nav" .. i, ImVec2(SB_W - 20, 32))
        local hovered = imgui.IsItemHovered()
        if imgui.IsItemClicked() then State.tab = i end
        local mn = imgui.GetItemRectMin()
        local active = (i == State.tab)
        local x1, y1, x2, y2 = mn.x, mn.y, mn.x + SB_W - 20, mn.y + 32
        if active then
            dl:AddRectFilledMultiColor(ImVec2(x1, y1), ImVec2(x2, y2),
                u32(P.accent, 0.30), u32(P.accent, 0.06), u32(P.accent, 0.06), u32(P.accent, 0.30))
            dl:AddRectFilled(ImVec2(x1, y1 + 7), ImVec2(x1 + 3, y2 - 7), u32(P.accent), 2)
        elseif hovered then
            dl:AddRectFilled(ImVec2(x1, y1), ImVec2(x2, y2), u32(P.cardHi, 0.6), 10)
        end
        local col = active and P.text or (hovered and P.text or P.muted)
        drawNavIcon(dl, tab[3], x1 + 24, y1 + 16, active and P.accent or col)
        text(dl, x1 + 46, y1 + 7, u32(col), u8(tab[1]), Fonts.bold)
        -- ��������� ����������� ������
        if (i == TAB_FISH and bot.on) or (i == TAB_TRUCK and truck.enabled)
            or (i == TAB_TRAIN and trainbot.enabled) or (i == TAB_OHOTA and Ohota.enabled)
            or (i == TAB_SVALKA and svalka.active[0]) or (i == TAB_CASE and caseCatcher.enabled[0]) then
            dl:AddCircleFilled(ImVec2(x2 - 14, y1 + 16), 3.5 + 0.8 * math_sin(now() * 4), u32(P.success), 12)
        end
    end

    -- ���� ���������� ������� ������� (������ �� ����)
    local running = runningModule()
    local cur = currentModule()
    local bx, by = px + 10, py + H - SB_X * 2 - 174
    dl:AddRectFilled(ImVec2(bx, by), ImVec2(bx + SB_W - 20, by + 164), u32(P.bg, 0.7), 12)
    dl:AddRect(ImVec2(bx, by), ImVec2(bx + SB_W - 20, by + 164),
        u32(running and P.accent or P.border, running and 0.5 or 0.7), 12, nil, 1)
    local pulse = running and (1.2 * math_sin(now() * 4)) or 0
    dl:AddCircleFilled(ImVec2(bx + 18, by + 22), 4.5 + pulse, u32(running and P.success or P.dim), 14)
    text(dl, bx + 32, by + 13, u32(P.text), u8(running and ru("Работает") or ru("Не активен")), Fonts.bold)
    local shown = running or cur
    text(dl, bx + 14, by + 36, u32(P.muted), u8(MODULE_NAMES[shown]), Fonts.smallBold)
    local info
    if shown == "fish" then
        info = bot.on and (fmtTime(runTime()) .. "   |   " .. "\243\235\238\226: " .. stats.catches) or "\208\251\225\224\235\234\224"
    elseif shown == "truck" then
        info = truck.enabled and ru("Идёт поиск заказа...") or ru("Дальнобойщик")
    elseif shown == "svalka" then
        info = ru("Метки предметов на свалке")
    else
        info = ru("Выберите модуль")
    end
    if shown == "train" then info = ru("Автопилот машиниста") end
    if shown == "hunt" then info = "\204\238\228\243\235\252 \238\245\238\242\251" end
    if running then text(dl, bx + 14, by + 54, u32(P.dim), u8(info), Fonts.smallBold) end

    imgui.SetCursorScreenPos(ImVec2(bx + 12, by + 74))
    if Ui.button("toggle", running and ru("Остановить") or ru("Запустить"), SB_W - 44, 40, running and "danger" or "accent") then
        if running == "case" then caseCatcher.enabled[0] = false
        elseif cur == "case" and not running then caseCatcher.enabled[0] = true
        elseif running == "fish" then stopBot()
        elseif running == "truck" then stopTrucking()
        elseif running == "train" then toggleTrain()
        elseif running == "hunt" then toggleOhota()
        elseif running == "svalka" then svalka.toggle()
        elseif cur == "truck" then startTrucking()
        elseif cur == "train" then toggleTrain()
        elseif cur == "hunt" then toggleOhota()
        elseif cur == "svalka" then svalka.toggle()
        else startBot() end
    end
    text(dl, bx + 14, by + 126, u32(P.dim), u8(keyNames[S.menuKey[0] + 1] .. ru(" — открыть меню")), Fonts.smallBold)
    text(dl, bx + 14, by + 142, u32(P.dim), u8("/sfradmira  |  /fb"), Fonts.smallBold)
end

local function renderTopbar(winPos, winSize)
    local dl = imgui.GetWindowDrawList()
    local tab = Tabs[State.tab]

    dragArea("##drag_top", CONTENT_X, 0, W - CONTENT_X - 120, TOP_H, winPos)

    text(dl, winPos.x + CONTENT_X, winPos.y + 12, u32(P.text), u8(tab[1]), Fonts.heading)
    text(dl, winPos.x + CONTENT_X, winPos.y + 38, u32(P.dim), u8(tab[2]), Fonts.smallBold)

    local cx, cy = winPos.x + winSize.x - 16 - 32, winPos.y + 14
    imgui.SetCursorScreenPos(ImVec2(cx, cy))
    imgui.InvisibleButton("##close", ImVec2(32, 32))
    local hov = imgui.IsItemHovered()
    dl:AddRectFilled(ImVec2(cx, cy), ImVec2(cx + 32, cy + 32), hov and u32(P.danger, 0.2) or u32(P.cardHi, 0.6), 9)
    drawClose(dl, cx + 16, cy + 16, 32, hov and P.danger or P.muted)
    if imgui.IsItemClicked() then State.window[0] = false end

    local running = runningModule()
    local label = u8(running and (ru("Работает: ") .. MODULE_NAMES[running]) or ru("Ожидание"))
    local chipW = textWidth(label, Fonts.smallBold) + 38
    local chipX = cx - 10 - chipW
    local chipY = winPos.y + 17
    local chipCol = running and P.success or P.dim
    dl:AddRectFilled(ImVec2(chipX, chipY), ImVec2(chipX + chipW, chipY + 26), u32(chipCol, 0.14), 13)
    dl:AddRect(ImVec2(chipX, chipY), ImVec2(chipX + chipW, chipY + 26), u32(chipCol, 0.4), 13, nil, 1)
    dl:AddCircleFilled(ImVec2(chipX + 14, chipY + 13), 3.5, u32(chipCol), 12)
    text(dl, chipX + 26, chipY + 6, u32(running and P.success or P.muted), label, Fonts.smallBold)

    dl:AddLine(ImVec2(winPos.x + CONTENT_X, winPos.y + TOP_H), ImVec2(winPos.x + winSize.x - 16, winPos.y + TOP_H),
        u32(P.border, 0.6), 1)
end

local function renderMain()
    local display = imgui.GetIO().DisplaySize
    imgui.SetNextWindowSize(ImVec2(W, H), Cond.Always)
    if State.dragPos then
        imgui.SetNextWindowPos(State.dragPos, Cond.Always)
    else
        imgui.SetNextWindowPos(ImVec2(display.x * 0.5, display.y * 0.5), Cond.Always, ImVec2(0.5, 0.5))
    end

    imgui.PushStyleColor(imgui.Col.WindowBg, ImVec4(0, 0, 0, 0))
    imgui.PushStyleColor(imgui.Col.Border, ImVec4(0, 0, 0, 0))
    imgui.PushStyleColor(imgui.Col.ChildBg, ImVec4(0, 0, 0, 0))
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 16)
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 0)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, ImVec2(0, 0))

    imgui.Begin("##softerradmira_fish", State.window,
        imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize +
        imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoScrollbar)

    local winPos = imgui.GetWindowPos()
    local winSize = imgui.GetWindowSize()
    local dl = imgui.GetWindowDrawList()

    dl:AddRectFilled(winPos, ImVec2(winPos.x + winSize.x, winPos.y + winSize.y), u32(P.bg, S.opacity[0]), 16)
    dl:AddRectFilledMultiColor(ImVec2(winPos.x + 2, winPos.y + 2), ImVec2(winPos.x + winSize.x - 2, winPos.y + 160),
        u32(P.accent, 0.07 * S.opacity[0]), u32(P.accent, 0.03 * S.opacity[0]), u32(P.accent, 0), u32(P.accent, 0))
    dl:AddRect(winPos, ImVec2(winPos.x + winSize.x, winPos.y + winSize.y), u32(P.border, 0.8), 16, nil, 1)
    dl:AddRectFilledMultiColor(ImVec2(winPos.x + 20, winPos.y), ImVec2(winPos.x + winSize.x - 20, winPos.y + 2),
        u32(P.accent, 0), u32(P.accent, 1), u32(P.accent, 1), u32(P.accent, 0))

    renderSidebar(winPos)
    renderTopbar(winPos, winSize)

    imgui.SetCursorPos(ImVec2(CONTENT_X, TOP_H + 10))
    imgui.BeginChild("##content", ImVec2(W - CONTENT_X - 14, H - TOP_H - 10 - 14), false)
    local w = imgui.GetContentRegionAvail().x - 4
    if State.tab == TAB_HOME then
        renderHome(w)
    elseif State.tab == TAB_FISH then
        renderBot(w)
    elseif State.tab == TAB_TRUCK then
        renderTruck(w)
    elseif State.tab == TAB_LOOK then
        renderInterface(w)
    elseif State.tab == TAB_SET then
        renderScript(w)
    elseif State.tab == TAB_OHOTA then
        renderOhota(w)
    elseif State.tab == TAB_SVALKA then
        svalka.render(w)
    elseif State.tab == TAB_CASE then
        renderCase(w)
    else
        renderTrain(w)
    end
    imgui.EndChild()

    imgui.End()
    imgui.PopStyleVar(3)
    imgui.PopStyleColor(3)
end

--================= ����������� � HUD =================--
function Notifications.render()
    if #Notifications.items == 0 then return end
    local t = now()
    local NW, NH, gap, pad = 300, 60, 8, 14
    local display = imgui.GetIO().DisplaySize
    local winH = #Notifications.items * NH + (#Notifications.items - 1) * gap + pad * 2

    imgui.SetNextWindowPos(ImVec2(display.x - NW - pad * 2 - 14, display.y - winH - 14), Cond.Always)
    imgui.SetNextWindowSize(ImVec2(NW + pad * 2, winH), Cond.Always)
    imgui.PushStyleColor(imgui.Col.WindowBg, ImVec4(0, 0, 0, 0))
    imgui.PushStyleColor(imgui.Col.Border,  ImVec4(0, 0, 0, 0))
    imgui.Begin("##sr_notif", nil,
        imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove +
        imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse + imgui.WindowFlags.NoInputs +
        imgui.WindowFlags.NoBringToFrontOnFocus)

    local dl = imgui.GetWindowDrawList()
    local origin = imgui.GetCursorScreenPos()

    for i = #Notifications.items, 1, -1 do
        local n = Notifications.items[i]
        local age = t - n.createdAt
        if age >= Notifications.duration then
            table.remove(Notifications.items, i)
        else
            local alpha
            if age < 0.35 then alpha = age / 0.35
            elseif age > Notifications.duration - 0.45 then alpha = (Notifications.duration - age) / 0.45
            else alpha = 1 end
            alpha = clamp(alpha, 0, 1)

            local slide = (1 - alpha) * 60
            if age < 0.4 then
                local tt = age / 0.4
                slide = (1 - tt) * (1 - tt) * 80
            end

            local x, y = origin.x + slide, origin.y + (i - 1) * (NH + gap)
            local ac = Notifications.color(n.kind)

            dl:AddRectFilled(ImVec2(x, y), ImVec2(x + NW, y + NH), u32(P.card, 0.95 * alpha), 10)
            dl:AddRect(ImVec2(x, y), ImVec2(x + NW, y + NH), u32(P.border, alpha), 10, nil, 1)
            dl:AddRectFilled(ImVec2(x + 1, y + 10), ImVec2(x + 4, y + NH - 10), u32(ac, alpha), 2)
            dl:AddCircleFilled(ImVec2(x + 22, y + NH * 0.5), 4, u32(ac, alpha), 12)
            text(dl, x + 36, y + 12, u32(P.text, alpha), u8(n.title), Fonts.bold)
            if n.description ~= "" then
                text(dl, x + 36, y + 32, u32(P.muted, alpha), u8(n.description), Fonts.smallBold)
            end
        end
    end

    imgui.End()
    imgui.PopStyleColor(2)
end

local function renderHud()
    local display = imgui.GetIO().DisplaySize
    local HW, HH = 280, 38
    local x
    if S.hudPos[0] == 1 then x = 14
    elseif S.hudPos[0] == 2 then x = display.x - HW - 14
    else x = (display.x - HW) * 0.5 end

    imgui.SetNextWindowPos(ImVec2(x, 14), Cond.Always)
    imgui.SetNextWindowSize(ImVec2(HW, HH), Cond.Always)
    imgui.PushStyleColor(imgui.Col.WindowBg, ImVec4(0, 0, 0, 0))
    imgui.PushStyleColor(imgui.Col.Border, ImVec4(0, 0, 0, 0))
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, ImVec2(0, 0))
    imgui.Begin("##sr_hud", nil,
        imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove +
        imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoInputs + imgui.WindowFlags.NoBringToFrontOnFocus)

    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetWindowPos()
    dl:AddRectFilled(p, ImVec2(p.x + HW, p.y + HH), u32(P.bg, 0.88), 12)
    dl:AddRectFilledMultiColor(ImVec2(p.x + 1, p.y + 1), ImVec2(p.x + HW - 1, p.y + HH - 1),
        u32(P.accent, 0.16), u32(P.accent, 0.02), u32(P.accent, 0.02), u32(P.accent, 0.16))
    dl:AddRect(p, ImVec2(p.x + HW, p.y + HH), u32(P.accent, 0.5), 12, nil, 1)
    dl:AddCircleFilled(ImVec2(p.x + 18, p.y + HH * 0.5), 4 + 1.2 * math_sin(now() * 4), u32(P.success), 14)
    dl:AddRectFilled(ImVec2(p.x + 28, p.y + 5), ImVec2(p.x + HW - 6, p.y + HH - 5), u32(P.bg, 0.96), 5)
    if bot.on then
        text(dl, p.x + 32, p.y + 11, u32(P.text), u8(ru("Рыбалка")), Fonts.bold)
        text(dl, p.x + 104, p.y + 13, u32(P.muted),
            u8(ru("Улов: ") .. stats.catches .. "  |  " .. fmtTime(runTime())), Fonts.smallBold)
    elseif truck.enabled then
        text(dl, p.x + 32, p.y + 11, u32(P.text), u8(ru("Дальнобойщик")), Fonts.bold)
        text(dl, p.x + 104, p.y + 13, u32(P.muted), u8(ru("Поиск заказа...")), Fonts.smallBold)
    elseif trainbot.enabled then
        text(dl, p.x + 32, p.y + 11, u32(P.text), u8(ru("Поезд")), Fonts.bold)
        text(dl, p.x + 104, p.y + 13, u32(P.muted),
            u8(trainbot.station ~= "" and trainbot.station or ru("Автопилот активен")), Fonts.smallBold)
    elseif svalka.active[0] then
        text(dl, p.x + 32, p.y + 11, u32(P.text), u8(ru("Свалка")), Fonts.bold)
        text(dl, p.x + 104, p.y + 13, u32(P.muted), u8(ru("Метки предметов включены")), Fonts.smallBold)
    else
        text(dl, p.x + 32, p.y + 11, u32(P.text), u8(ru("Охота")), Fonts.bold)
        text(dl, p.x + 104, p.y + 13, u32(P.muted), u8(ru("Метки, прицел и утилиты")), Fonts.smallBold)
    end

    imgui.End()
    imgui.PopStyleVar(1)
    imgui.PopStyleColor(2)
end

imgui.OnFrame(
    function() return #Notifications.items > 0 end,
    function(frame)
        frame.HideCursor = true
        Notifications.render()
    end
)

imgui.OnFrame(
    function() return State.window[0] and not isPauseMenuActive() end,
    function(frame)
        frame.HideCursor = false
        renderMain()
    end
)

imgui.OnFrame(
    function() return S.hud[0] and (bot.on or truck.enabled or trainbot.enabled or Ohota.enabled or svalka.active[0]) and not isPauseMenuActive() end,
    function(frame)
        frame.HideCursor = true
        renderHud()
    end
)

imgui.OnFrame(
    function() return Ohota.enabled and #ohotaTextQueue > 0 and not isPauseMenuActive() end,
    function(frame)
        frame.HideCursor = true
        local dl = imgui.GetBackgroundDrawList()
        local display = imgui.GetIO().DisplaySize
        local screenWidth, screenHeight = getScreenResolution()
        for _, item in ipairs(ohotaTextQueue) do
            local color = item.color
            local alpha = bit.band(bit.rshift(color, 24), 0xFF) / 255
            local red = bit.band(bit.rshift(color, 16), 0xFF) / 255
            local green = bit.band(bit.rshift(color, 8), 0xFF) / 255
            local blue = bit.band(color, 0xFF) / 255
            local imguiColor = imgui.ColorConvertFloat4ToU32(ImVec4(red, green, blue, alpha))
            text(dl, item.x * display.x / screenWidth, item.y * display.y / screenHeight,
                imguiColor, item.label, Fonts.smallBold)
        end
    end
)

imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil
    local logoPath = getWorkingDirectory() .. "\\SofterRadmiraHub_logo.png"
    hubLogoTexture = imgui.CreateTextureFromFile(logoPath)
    if not hubLogoTexture then
        print("[SofterRadmira Hub] Failed to load logo image: " .. logoPath)
    end

    local fonts = imgui.GetIO().Fonts
    local winFonts = getFolderPath(0x14) .. "\\"
    local cyrillic = fonts:GetGlyphRangesCyrillic()

    local function load(path, size)
        local ok, f = pcall(function() return fonts:AddFontFromFileTTF(path, size, nil, cyrillic) end)
        if ok and f then return f end
    end

    Fonts.body      = load(winFonts .. "segoeui.ttf",  15) or load(winFonts .. "arial.ttf",  15) or fonts:AddFontDefault()
    Fonts.bold      = load(winFonts .. "segoeuib.ttf", 15) or load(winFonts .. "arialbd.ttf", 15) or Fonts.body
    Fonts.smallBold = load(winFonts .. "segoeuib.ttf", 12) or load(winFonts .. "arialbd.ttf", 12) or Fonts.body
    Fonts.heading   = load(winFonts .. "segoeuib.ttf", 20) or Fonts.body

    imgui.SwitchContext()
    local style = imgui.GetStyle()
    style.WindowRounding = 16
    style.ChildRounding  = 8
    style.FrameRounding  = 6
    style.PopupRounding  = 8
    style.ScrollbarRounding = 6
    style.GrabRounding   = 6
    style.ItemSpacing    = ImVec2(8, 0)
    style.ScrollbarSize  = 6
    style.Colors[imgui.Col.ScrollbarBg]          = ImVec4(0, 0, 0, 0)
    style.Colors[imgui.Col.ScrollbarGrab]        = ImVec4(P.border[1], P.border[2], P.border[3], 0.6)
    style.Colors[imgui.Col.ScrollbarGrabHovered] = ImVec4(P.borderHi[1], P.borderHi[2], P.borderHi[3], 1)
    style.Colors[imgui.Col.ScrollbarGrabActive]  = ImVec4(P.accent[1], P.accent[2], P.accent[3], 1)
    style.Colors[imgui.Col.FrameBg]              = ImVec4(P.cardHi[1], P.cardHi[2], P.cardHi[3], 1)
    style.Colors[imgui.Col.FrameBgHovered]       = ImVec4(P.borderHi[1], P.borderHi[2], P.borderHi[3], 1)
    style.Colors[imgui.Col.FrameBgActive]        = ImVec4(P.borderHi[1], P.borderHi[2], P.borderHi[3], 1)
    style.Colors[imgui.Col.SliderGrab]           = ImVec4(P.accent[1], P.accent[2], P.accent[3], 1)
    style.Colors[imgui.Col.SliderGrabActive]     = ImVec4(P.accent[1], P.accent[2], P.accent[3], 1)
    style.Colors[imgui.Col.PopupBg]              = ImVec4(P.card[1], P.card[2], P.card[3], 1)
    style.Colors[imgui.Col.Header]               = ImVec4(P.accent[1], P.accent[2], P.accent[3], 0.25)
    style.Colors[imgui.Col.HeaderHovered]        = ImVec4(P.accent[1], P.accent[2], P.accent[3], 0.35)
    style.Colors[imgui.Col.HeaderActive]         = ImVec4(P.accent[1], P.accent[2], P.accent[3], 0.45)
    style.Colors[imgui.Col.Text]                 = ImVec4(P.text[1], P.text[2], P.text[3], 1)
end)

--================= MAIN =================--
svalka.updater = {
    apiUrl = "https://api.github.com/repos/lunguvictor/SofterRadmiraHub/commits/main",
    rawUrl = "https://raw.githubusercontent.com/lunguvictor/SofterRadmiraHub/",
    status = require("moonloader").download_status,
    apiTempPath = getWorkingDirectory() .. "\\SofterRadmiraHub.commit.tmp",
    configTempPath = svalka.configPath .. ".download.tmp",
    tempPath = getWorkingDirectory() .. "\\SofterRadmiraHub.update.tmp",
    targetPath = nil,
    inProgress = false,
    startedAt = 0,
    message = ru("Автопроверка при запуске"),
}

local function openHubUpdateFile(path)
    for attempt = 1, 10 do
        if not svalka.updater.inProgress then return nil end
        local file = io.open(path, "rb")
        if file then return file end
        wait(100)
    end
end

local function failHubUpdate(message, logMessage)
    svalka.updater.inProgress = false
    svalka.updater.message = ru(message)
    os.remove(svalka.updater.apiTempPath)
    os.remove(svalka.updater.configTempPath)
    os.remove(svalka.updater.tempPath)
    print("[SofterRadmira Hub] " .. logMessage)
end

local function downloadHubScript(commitSha, configWasInstalled)
    svalka.updater.message = ru("Загрузка коммита ") .. commitSha:sub(1, 7)
    local updateUrl = svalka.updater.rawUrl .. commitSha .. "/SofterRadmiraHub.lua"
    downloadUrlToFile(updateUrl, svalka.updater.tempPath, function(id, status)
        if not svalka.updater.inProgress then return end
        if status ~= svalka.updater.status.STATUS_ENDDOWNLOADDATA then return end

        lua_thread.create(function()
            wait(0)
            if not svalka.updater.inProgress then return end

            local updateFile = openHubUpdateFile(svalka.updater.tempPath)
            if not updateFile then
                if not svalka.updater.inProgress then return end
                failHubUpdate("Не удалось прочитать файл обновления", "Failed to read downloaded update")
                return
            end

            local updatedCode = updateFile:read("*a")
            updateFile:close()
            if not updatedCode or not updatedCode:find('script_name("SofterRadmira Hub")', 1, true) then
                failHubUpdate("В репозитории нет корректного файла Hub", "GitHub file is not a valid Hub script")
                return
            end

            local currentFile = io.open(svalka.updater.targetPath, "rb")
            if not currentFile then
                failHubUpdate("Не удалось прочитать текущий файл Hub", "Failed to read the installed Hub script")
                return
            end
            local currentCode = currentFile:read("*a")
            currentFile:close()
            if currentCode == updatedCode then
                os.remove(svalka.updater.tempPath)
                svalka.updater.inProgress = false
                svalka.updater.message = ru("Установлен актуальный файл")
                if configWasInstalled then
                    sampAddChatMessage("{FF3844}[SofterRadmira] {FFFFFF}" .. ru("Список Svalka загружен. Перезапуск Hub..."), -1)
                    thisScript():reload()
                end
                return
            end

            if ffi.C.MoveFileExA(svalka.updater.tempPath, svalka.updater.targetPath, 1) == 0 then
                failHubUpdate("Не удалось установить обновление", "Failed to replace the installed Hub script")
                return
            end
            svalka.updater.inProgress = false
            sampAddChatMessage("{FF3844}[SofterRadmira] {FFFFFF}" .. ru("Обновление установлено. Перезапуск Hub..."), -1)
            thisScript():reload()
        end)
    end)
end

local function downloadSvalkaConfig(commitSha)
    local function continueWithoutConfig(logMessage)
        os.remove(svalka.updater.configTempPath)
        svalka.updater.message = ru("Не удалось загрузить JSON списка Svalka")
        print("[SofterRadmira Hub] " .. logMessage)
        downloadHubScript(commitSha, false)
    end

    svalka.updater.message = ru("Загрузка списка Svalka...")
    local configUrl = svalka.updater.rawUrl .. commitSha .. "/config/svalka_items.json"
    downloadUrlToFile(configUrl, svalka.updater.configTempPath, function(id, status)
        if not svalka.updater.inProgress then return end
        if status ~= svalka.updater.status.STATUS_ENDDOWNLOADDATA then return end

        lua_thread.create(function()
            wait(0)
            if not svalka.updater.inProgress then return end

            local configFile = openHubUpdateFile(svalka.updater.configTempPath)
            if not configFile then
                if not svalka.updater.inProgress then return end
                continueWithoutConfig("Failed to read downloaded Svalka JSON")
                return
            end
            local configContents = configFile:read("*a")
            configFile:close()

            local ok, configData = pcall(decodeJson, configContents)
            if not ok or type(configData) ~= "table" or type(configData.items) ~= "table" then
                continueWithoutConfig("GitHub Svalka JSON is invalid or missing")
                return
            end
            for _, item in ipairs(configData.items) do
                if type(item) ~= "table" or item.model_id == nil or type(item.item_name) ~= "string" then
                    continueWithoutConfig("GitHub Svalka JSON contains an invalid item")
                    return
                end
            end

            local existingConfig = io.open(svalka.configPath, "rb")
            if existingConfig then
                existingConfig:close()
                os.remove(svalka.updater.configTempPath)
                downloadHubScript(commitSha, true)
                return
            end

            if ffi.C.MoveFileExA(svalka.updater.configTempPath, svalka.configPath, 1) == 0 then
                continueWithoutConfig("Failed to install downloaded Svalka JSON")
                return
            end
            downloadHubScript(commitSha, true)
        end)
    end)
end

svalka.checkUpdate = function()
    if svalka.updater.inProgress then return end
    svalka.updater.inProgress = true
    svalka.updater.startedAt = os.time()
    svalka.updater.message = ru("Проверка GitHub...")
    svalka.updater.targetPath = thisScript().path
    os.remove(svalka.updater.apiTempPath)
    os.remove(svalka.updater.configTempPath)
    os.remove(svalka.updater.tempPath)

    local nonce = tostring(os.time()) .. tostring(getGameTimer())
    local commitApiUrl = svalka.updater.apiUrl .. "?t=" .. nonce
    downloadUrlToFile(commitApiUrl, svalka.updater.apiTempPath, function(id, status)
        if not svalka.updater.inProgress then return end
        if status ~= svalka.updater.status.STATUS_ENDDOWNLOADDATA then return end

        lua_thread.create(function()
            wait(0)
            if not svalka.updater.inProgress then return end

            local apiFile = openHubUpdateFile(svalka.updater.apiTempPath)
            if not apiFile then
                if not svalka.updater.inProgress then return end
                failHubUpdate("Не удалось прочитать ответ GitHub", "Failed to read the GitHub commit response")
                return
            end
            local apiResponse = apiFile:read("*a")
            apiFile:close()
            os.remove(svalka.updater.apiTempPath)

            local ok, commitData = pcall(decodeJson, apiResponse)
            local commitSha = ok and type(commitData) == "table" and commitData.sha or nil
            if type(commitSha) ~= "string" or #commitSha ~= 40 or not commitSha:match("^[%da-fA-F]+$") then
                failHubUpdate("Не удалось получить SHA коммита GitHub", "GitHub did not return a valid commit SHA")
                return
            end

            local configFile = io.open(svalka.configPath, "rb")
            if configFile then
                configFile:close()
                downloadHubScript(commitSha, false)
            else
                downloadSvalkaConfig(commitSha)
            end
        end)
    end)
end
local function toggleMenu() State.window[0] = not State.window[0] end
local function hotkeyAvailable() return not isPauseMenuActive() and not sampIsChatInputActive() and not sampIsDialogActive() end

function main()
    if not isSampLoaded() then return end
    while not isSampAvailable() do wait(100) end

    sampRegisterChatCommand("fish", toggleMenu)
    local openHubMenu = function()
        -- ��������� ����� ���� �� �������, ��� ����� ����� ��� ������
        if State.window[0] then
            State.window[0] = false
        else
            State.tab = TAB_HOME
            State.window[0] = true
        end
    end
    sampRegisterChatCommand("sfradmira", openHubMenu)
    sampRegisterChatCommand("sfradmria", openHubMenu)
    sampRegisterChatCommand("fb", toggleBot)
    sampRegisterChatCommand("truck", function()
        State.tab = TAB_TRUCK
        State.window[0] = true
    end)
    sampRegisterChatCommand("msh", toggleTrain)
    sampRegisterChatCommand("train", function()
        State.tab = TAB_TRAIN
        State.window[0] = true
    end)
    sampRegisterChatCommand("les", function()
        State.tab = TAB_OHOTA
        State.window[0] = true
    end)
    sampRegisterChatCommand("ohota", toggleOhota)
    sampRegisterChatCommand("case", function()
        State.tab = TAB_CASE
        State.window[0] = true
    end)
    if svalka.settings.cmd ~= "" then sampRegisterChatCommand(svalka.settings.cmd, svalka.showPage) end
    if svalka.settings.cmdact ~= "" then sampRegisterChatCommand(svalka.settings.cmdact, svalka.toggle) end

    sampAddChatMessage("{FF3844}[SofterRadmira] {FFFFFF}" .. ru("Hub запущен 5.2.3 . Меню: ") .. keyNames[S.menuKey[0] + 1] .. ru(" или /sfradmira"), -1)
    if not svalka.loaded then
        sampAddChatMessage("{FF3844}[SofterRadmira] {FFFFFF}" .. (svalka.error or ru("Список Svalka недоступен")), -1)
    end
    svalka.checkUpdate()

    while true do
        wait(0)

        if svalka.updater.inProgress and os.time() - svalka.updater.startedAt > 30 then
            svalka.updater.inProgress = false
            svalka.updater.message = ru("Не удалось получить обновление за 30 секунд")
            os.remove(svalka.updater.apiTempPath)
            os.remove(svalka.updater.configTempPath)
            os.remove(svalka.updater.tempPath)
            print("[SofterRadmira Hub] GitHub update download timed out")
        end

        if bot.on and S.watchdog[0] then
            local limit = (bot.state == 1 and S.t1[0]) or (bot.state == 2 and S.t2[0]) or (bot.state == 3 and S.t3[0])
            if limit and os.time() - bot.timer > limit then
                stats.restarts = stats.restarts + 1
                pushLog(ru("Перезапуск после зависания"), "muted")
                fishRestart()
            end
        end

        trainbot.update()

        if svalka.active[0] then
            svalka.drawObjects()
        end

        if Ohota.enabled then
            local chars = {}
            if Ohota.wh[0] or Ohota.clear[0] or Ohota.aim[0] or Ohota.tracers[0] then
                chars = getAllChars()
            end
            ohotaCleanStillAnimals(chars)
            ohotaUpdateAim(chars)
            ohotaUpdateDeadAnimals(chars)
            if animalPickupFinished then
                ohotaClearNearestDeadAnimal()
                animalPickupFinished = false
            end
            ohotaDrawAnimals(chars)
            ohotaDrawTracers(chars)
        end

        if dirty and os.clock() - lastSave > 1 then save_config() end
        if ohotaDirty and os.clock() - ohotaLastSave > 1 then saveOhotaConfig() end
        if svalka.saveTime and os.clock() >= svalka.saveTime then
            svalka.saveTime = nil
            svalka.saveConfig()
        end

        caseCatcher.update()

        if hotkeyAvailable() and isKeyDown(vkeys.VK_CONTROL) and wasKeyPressed(vkeys.VK_B) then
            State.tab = TAB_SVALKA
            State.window[0] = not State.window[0]
        end
        if hotkeyAvailable() and isKeyJustPressed(menuKeyCode()) then
            toggleMenu()
        end
    end
end

function onScriptTerminate(scr, quitGame)
    if scr == thisScript() then
        trainbot.stop()
        Ohota.autoYClicker:Stop()
        Ohota.enabled = false
        if dirty then save_config() end
        if ohotaDirty then saveOhotaConfig() end
        if svalka.saveTime then svalka.saveConfig() end
    end
end
