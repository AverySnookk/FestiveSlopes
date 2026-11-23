-- Festive Slopes: game world detection and cached handles (shared design with Yeti Mayhem, verified there).
-- Rules learned on this game (Ski-E-O Together MODLOG):
--  * FindAllOf walks every UObject: never call it per tick; cache per world.
--  * Objects of a level being unloaded still pass IsValid for a while; calling into them crashes.
--    Everything cached here is dropped by the LoadMap pre-hook, and the current world is taken from the
--    engine's game viewport (it lives for the whole game).
local UEHelpers = require("UEHelpers")
local W = { gen = 0, phase = "boot" }
local L

function W.ok(o)
    if o == nil then return false end
    local s, v = pcall(function() return o:IsValid() end)
    return s and v == true
end
local ok = W.ok

local listeners = {}
function W.onMapChange(fn) listeners[#listeners + 1] = fn end

local cache = {}            -- className -> { o, w, t }
local statics, gstatics, worldObj, worldA

local function clearCaches()
    cache = {}
    worldObj, worldA = nil, nil
end

local function mapChanged(when)
    W.gen = W.gen + 1
    clearCaches()
    W.loadingSince = os.clock()
    W.resortSince = nil
    if L then L.info("world", "map load %s (generation %d)", when, W.gen) end
    for _, fn in ipairs(listeners) do
        local s, e = pcall(fn, when)
        if not s and L then L.error("world", "map listener failed: %s", tostring(e)) end
    end
end

function W.init(log)
    L = log
    local a = pcall(function() RegisterLoadMapPreHook(function() mapChanged("pre") end) end)
    local b = pcall(function() RegisterLoadMapPostHook(function() mapChanged("post") end) end)
    if not (a and b) then L.warn("world", "LoadMap hooks unavailable (pre=%s post=%s): relying on world address checks", tostring(a), tostring(b)) end
end

-- The world on screen. Cheap: the engine object is cached by UEHelpers.
function W.world()
    local w
    pcall(function()
        local vp = UEHelpers.GetGameViewportClient()
        if ok(vp) then w = vp.World end
    end)
    if not ok(w) then return nil end
    local a = w:GetAddress()
    if a ~= worldA then
        -- a new world without a LoadMap hook (or the first call): drop handles from the old one
        if worldA ~= nil then clearCaches() W.gen = W.gen + 1 W.resortSince = nil end
        worldA, worldObj = a, w
    end
    return w
end

function W.statics()
    if not ok(gstatics) then gstatics = StaticFindObject("/Script/Engine.Default__GameplayStatics") end
    return gstatics
end

function W.kismetSystem()
    if not ok(statics) then statics = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
    return statics
end

local function gameModeName()
    local w = W.world()
    if not w then return nil end
    local n
    pcall(function()
        local gm = w.AuthorityGameMode
        if ok(gm) then n = gm:GetClass():GetFName():ToString() end
    end)
    return n
end

-- Updates W.phase: "menu", "resort", "loading" or "unknown".
function W.update()
    local n = gameModeName()
    local prev = W.phase
    if n == nil then W.phase = "loading"
    elseif n:find("SkiResortGameMode", 1, true) then W.phase = "resort"
    elseif n:find("MainMenu", 1, true) then W.phase = "menu"
    else W.phase = "unknown" end
    if W.phase == "resort" and not W.resortSince then W.resortSince = os.clock() end
    if W.phase ~= "resort" then W.resortSince = nil end
    if prev ~= W.phase and L then L.info("world", "phase %s -> %s (game mode %s)", prev, W.phase, tostring(n)) end
    return W.phase
end

function W.inResortFor()
    if W.phase ~= "resort" or not W.resortSince then return 0 end
    return os.clock() - W.resortSince
end

-- A live object of this class that belongs to the current world (cached; FindAllOf at most every 10 s,
-- misses remembered with back-off).
function W.live(className)
    local w = W.world()
    if not w then return nil end
    local now = os.clock()
    local c = cache[className]
    if c and c.w == worldA then
        if c.o and now - c.t < 10 and ok(c.o) then return c.o end
        if not c.o and now - c.t < (c.backoff or 2) then return nil end
    end
    local found
    for _, o in ipairs(FindAllOf(className) or {}) do
        if ok(o) then
            local okW, wa = pcall(function() return o:GetWorld():GetAddress() end)
            if okW and wa == worldA and not o:GetFullName():find("Default__", 1, true) then found = o break end
        end
    end
    local backoff = 2
    if not found and c and c.w == worldA and not c.o then backoff = math.min(30, (c.backoff or 2) * 2) end
    cache[className] = { o = found, w = worldA, t = now, backoff = backoff }
    return found
end

function W.forget(className) cache[className] = nil end

function W.playerPawn()
    local w = W.world()
    if not w then return nil end
    local p
    pcall(function() p = W.statics():GetPlayerPawn(w, 0) end)
    return ok(p) and p or nil
end

-- The camera: position and view angles (degrees). In this game the camera pawn sits at the camera position
-- (lab 2026-11-19: pawn == PlayerCameraManager location, pitch about -38, ~86 m above the ground), so the
-- point on screen centre is ahead of the pawn; Terrain.cameraFocus finds it.
function W.cameraView()
    local w = W.world()
    if not w then return nil end
    local v
    pcall(function()
        local pc = W.statics():GetPlayerController(w, 0)
        local cm = pc.PlayerCameraManager
        local l, r = cm:GetCameraLocation(), cm:GetCameraRotation()
        v = { x = l.X, y = l.Y, z = l.Z, pitch = r.Pitch, yaw = r.Yaw }
    end)
    if v and v.x then return v end
    local p = W.playerPawn()
    if not p then return nil end
    pcall(function()
        local l, r = p:K2_GetActorLocation(), p:K2_GetActorRotation()
        v = { x = l.X, y = l.Y, z = l.Z, pitch = r.Pitch, yaw = r.Yaw }
    end)
    return v
end

-- Game speed: 0 when the player paused the simulation (the pause button sets rate 0, MODLOG 0.11.10).
function W.timeRate()
    local ts = W.live("TimeSubsystem")
    if not ts then return 1 end
    local r, paused = 1, false
    pcall(function() r = ts:GetTimeRate() end)
    pcall(function() paused = ts:IsTimePaused() end)
    if paused then return 0 end
    return tonumber(r) or 1
end

function W.enginePaused()
    local w = W.world()
    if not w then return true end
    local p = false
    pcall(function() p = W.statics():IsGamePaused(w) end)
    return p == true
end

return W
