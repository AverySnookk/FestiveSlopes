-- Festive Slopes v0.1 for Ski-E-O! Ski Resort Tycoon (UE4SS Lua). AverySnookk Studios.
-- Decorated Christmas trees and gingerbread houses along the edges of selected ski trails. Standalone: needs no
-- other mod. Cosmetic only: nothing is registered with the game, nothing is written to the save.
local VERSION = "0.1.1"

local here = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
local modDir = here:match("^(.*)/Scripts$") or here

local Log = require("fs_log")
local Config = require("fs_config")

local cfgPath = modDir .. "/Config/FestiveSlopes.ini"
local cfg, problems, found = Config.load(cfgPath)
Log.init(modDir, cfg.debug_logging)
Log.info("main", "Festive Slopes %s starting (mod folder %s)", VERSION, modDir:match("[^/]+/[^/]+$") or modDir)
if not found then Log.warn("main", "Config/FestiveSlopes.ini missing: using built-in defaults") end
for _, p in ipairs(problems) do Log.warn("config", "%s", p) end
if not cfg.enabled then
    Log.info("main", "disabled in Config/FestiveSlopes.ini (enabled = false): nothing loaded")
    return
end

local W = require("fs_world")
local S = require("fs_resort")
local Decor = require("fs_decor")
local P = require("fs_place")
local SP = require("fs_spawn")
local Trees = require("fs_trees")
local MG = require("fs_manager")
local Commands = require("fs_commands")

local ctx = { version = VERSION, modDir = modDir, cfg = cfg, active = true, perf = { n = 0, sum = 0, worst = 0 },
    W = W, L = Log, S = S, P = P, SP = SP, Trees = Trees, MG = MG, Decor = Decor, Config = Config, Commands = Commands }

W.init(Log)
S.init(W, Log)
SP.init(W, Log, S, Decor, cfg)
Trees.init(W, Log, S, SP)
P.init(S, Log, Decor, Trees)
MG.init(ctx)
Commands.init(ctx)

function ctx.reloadConfig()
    local c, probs = Config.load(cfgPath)
    for _, p in ipairs(probs) do Log.warn("config", "%s", p) end
    for k, v in pairs(c) do cfg[k] = v end           -- same table everywhere: modules see the change
    Log.debugOn = cfg.debug_logging
end

-- Lab-only hooks (not shipped): Scripts/fs_lab.lua adds extra commands when present.
pcall(function()
    local lab = require("fs_lab")
    if lab and lab.init then lab.init(ctx) Log.warn("main", "lab helpers loaded (development build)") end
end)

Log.info("config", "%s", Config.describe(cfg))
Commands.registerInputs(cfg)

-- ------------------------------------------------------------------ main loop (20 Hz, game thread)
local cmdT, perfT = os.clock(), os.clock()

local function tick()
    local t0 = os.clock()
    W.update()
    if t0 - cmdT >= 1 then
        cmdT = t0
        local okC, e = pcall(ctx.Commands.pollFile)
        if not okC then Log.every("cmdpoll", 30, "ERROR", "cmd", "command file: %s", tostring(e)) end
    end
    local okT, e = pcall(ctx.MG.tick)
    if not okT then Log.every("tick", 10, "ERROR", "main", "tick failed: %s", tostring(e)) end
    local ms = (os.clock() - t0) * 1000
    local p = ctx.perf
    p.n, p.sum = p.n + 1, p.sum + ms
    if ms > p.worst then p.worst = ms end
    if os.clock() - perfT >= 60 then
        p.avg = p.sum / math.max(p.n, 1)
        p.worstLast = p.worst
        Log.debug("perf", "last minute: %d ticks, avg %.2f ms, worst %.1f ms, state %s, height queries %d, corridor checks %d, tree queries %d",
            p.n, p.avg, p.worst, ctx.MG.state, ctx.S.stats.height, ctx.S.stats.corridor, ctx.S.stats.trees)
        p.n, p.sum, p.worst, perfT = 0, 0, 0, os.clock()
    end
end

-- The loop runs on the game thread only (LoopInGameThreadWithDelay, as the game's own bundled mod menu does).
-- Lab 2026-11-21: the earlier LoopAsync + ExecuteInGameThread loop ran Lua on UE4SS's async thread at the same time
-- as the game-thread tick. With the long ticks of festive/wonderland builds this corrupted the Lua state (numbers
-- turning into functions: "attempt to perform arithmetic on a function value", "Ref was not function") and crashed
-- the game inside UE4SS twice. No Lua of this mod now runs off the game thread except the key-bind callbacks.
LoopInGameThreadWithDelay(50, function()
    local okT, e = pcall(tick)
    if not okT then Log.every("loop", 10, "ERROR", "main", "%s", tostring(e)) end
    return false
end)

Log.info("main", "ready: decorations start appearing near the camera about %d s after a resort loads (the first visit to a resort takes longer: its layout is worked out once, then cached). Ctrl+Alt+F show/hide, Ctrl+Alt+G regenerate, Ctrl+Alt+J info", 10)
