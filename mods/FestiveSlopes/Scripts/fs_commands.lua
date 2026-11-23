-- Festive Slopes: commands (debug and player controls).
-- Three ways in, all running the same commands:
--   * keybinds (keybinds_enabled = true): Ctrl+Alt+F show/hide decorations, Ctrl+Alt+G regenerate, Ctrl+Alt+J info
--   * UE4SS console (when the console is enabled): "festive <command>"
--   * file: write commands (one per line) into <mod>/commands.txt; it is read and emptied once a second.
--     Results go to FestiveSlopes.log and <mod>/status.txt.
local Rng = require("fs_rng")
local C = { last = {} }
local ctx, W, L, S, P, SP, MG, Decor, Config

function C.init(c)
    ctx = c
    W, L, S, P, SP, MG, Decor, Config = c.W, c.L, c.S, c.P, c.SP, c.MG, c.Decor, c.Config
end

local function out(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    L.info("cmd", "%s", msg)
    C.last[#C.last + 1] = msg
    return msg
end
C.out = out

local function writeStatus()
    local f = io.open(ctx.modDir .. "/status.txt", "w")
    if not f then return end
    f:write(os.date("%Y-%m-%d %H:%M:%S"), "\n")
    for _, l in ipairs(C.last) do f:write(l, "\n") end
    f:close()
end

-- ground point at the centre of the screen (march along the view ray until it goes below the terrain)
function C.cameraFocus()
    local v = W.cameraView()
    if not v then return nil end
    local cp = math.cos(math.rad(v.pitch))
    local fx, fy, fz = math.cos(math.rad(v.yaw)) * cp, math.sin(math.rad(v.yaw)) * cp, math.sin(math.rad(v.pitch))
    if fz > -0.08 then
        local x, y = v.x + math.cos(math.rad(v.yaw)) * 15000, v.y + math.sin(math.rad(v.yaw)) * 15000
        return { x = x, y = y, z = S.height(x, y) or v.z, view = v }
    end
    local t, step, prevT = 0, 1500, 0
    for _ = 1, 160 do
        t = t + step
        local x, y, z = v.x + fx * t, v.y + fy * t, v.z + fz * t
        local g = S.height(x, y)
        if g and z <= g then
            local lo, hi = prevT, t
            for _ = 1, 8 do
                local m = (lo + hi) / 2
                local gh = S.height(v.x + fx * m, v.y + fy * m)
                if gh and v.z + fz * m <= gh then hi = m else lo = m end
            end
            local hx, hy = v.x + fx * hi, v.y + fy * hi
            return { x = hx, y = hy, z = S.height(hx, hy) or g, view = v }
        end
        prevT = t
    end
    return nil
end

-- slide the camera so (x, y, z) ends up where it is looking now
function C.lookAt(x, y, z)
    local p = W.playerPawn()
    local f = C.cameraFocus()
    if not (p and f) then return false end
    local v = f.view
    local dx, dy, up = f.x - v.x, f.y - v.y, v.z - f.z
    return pcall(function() p:K2_SetActorLocation({ X = x - dx, Y = y - dy, Z = z + up }, false, {}, true) end)
end

function C.info()
    local g, d = SP.count()
    local info = MG.info or {}
    out("Festive Slopes %s | phase %s | state %s | %s | density %s | %d decoration(s) in %d group(s)%s",
        ctx.version, W.phase, MG.state, ctx.active and "active" or "paused", ctx.cfg.density, d, g, SP.hidden and " (hidden)" or "")
    if info.id then
        out("  resort '%s', seed %d (%s)%s", tostring(info.id.name or "?"), info.id.seed, info.id.source,
            info.fromCache and ", placements from cache" or "")
    end
    if info.result then out("  last update: %s (%s, %.0f ms)", info.result, tostring(info.reason), info.totalMs or 0) end
    if info.chosen then out("  trails decorated: %d of %d eligible (of %d)", info.chosen, info.eligible or 0, info.trails or 0) end
    out("  skiable-area test: %s", tostring(S.corridorMode or "not yet checked"))
    local st = SP.stats
    out("  geometry: %d verts, %d tris, %d sections built; build time %.0f ms total, worst group %.0f ms", st.verts, st.tris, st.sections, st.buildMs, st.worstMs)
    local pf = ctx.perf
    if pf.avg then out("  mod time: avg %.2f ms/tick, worst %.1f ms (last minute)", pf.avg, pf.worstLast or 0) end
end

local function nearestPlacement(kind, x, y, skip)
    local best, bd
    for i, o in ipairs(MG.placements or {}) do
        if (not kind or o.kind == kind) and i ~= skip then
            local d = (o.x - x) ^ 2 + (o.y - y) ^ 2
            if not bd or d < bd then best, bd = i, d end
        end
    end
    return best
end

C.gotoIndex = 0
function C.gotoCmd(arg)
    local list = MG.placements or {}
    if #list == 0 then return out("no decorations placed") end
    local i
    local f = C.cameraFocus()
    if arg == "house" or arg == "tree" then
        -- the next one of that kind after the last visited
        for k = 1, #list do
            local j = (C.gotoIndex + k - 1) % #list + 1
            if list[j].kind == arg then i = j break end
        end
    elseif tonumber(arg) then i = math.max(1, math.min(#list, math.floor(tonumber(arg))))
    elseif f then i = nearestPlacement(nil, f.x, f.y)
    else i = 1 end
    if not i then return out("no %s placed", tostring(arg)) end
    C.gotoIndex = i
    local o = list[i]
    local okM = C.lookAt(o.x, o.y, o.z)
    out("camera -> %s #%d of %d at (%.0f, %.0f, %.0f) m [%s]: %s", o.kind, i, #list, o.x / 100, o.y / 100, o.z / 100, o.group, okM and "ok" or "failed")
end

-- spawn a sample tree + house in front of the camera (group "test"), validated the same way as real ones
function C.test(arg)
    local f = C.cameraFocus()
    if not f then return out("camera view unknown") end
    local Trees = ctx.Trees
    if not Trees.mode then Trees.resolve(S.trails(400)) end
    local rng = Rng.new(Rng.hash(os.time(), f.x, f.y))
    local list = {}
    local nTrees = (arg == "house") and 0 or 6
    if nTrees > 0 then
        local z = S.height(f.x, f.y) or f.z
        local cands = Trees.near(f.x, f.y, z, 3000)
        for _, c in ipairs(cands) do c.d = (c.x - f.x) ^ 2 + (c.y - f.y) ^ 2 end
        table.sort(cands, function(a, b) return a.d < b.d end)
        for _, c in ipairs(cands) do
            if #list >= nTrees then break end
            local info = Trees.info(c)
            if info then
                local H, R = Trees.measure(c, info)
                if H then
                    local look = Decor.rollLights(rng, ctx.cfg)
                    look.H, look.R, look.f0, look.gy = H, R, info.f0, math.deg(math.atan(f.y - c.y, f.x - c.x))
                    look.species = info.species
                    list[#list + 1] = { kind = "tree", x = c.x, y = c.y, z = c.z, yaw = 0, r = R, look = look, group = "test" }
                end
            end
        end
    end
    if arg ~= "trees" then
        local x, y = f.x + 1600, f.y
        local z = S.height(x, y)
        if z then list[#list + 1] = { kind = "house", x = x, y = y, z = z, yaw = 180, look = Decor.rollHouse(rng, ctx.cfg), group = "test" } end
    end
    local t0 = os.clock()
    local okB, e = SP.spawnGroup("test", list)
    local sp = {}
    for _, o in ipairs(list) do if o.kind == "tree" then sp[#sp + 1] = string.format("%s %.0fm", o.look.species or "?", o.look.H / 100) end end
    out("test decorations: %d at camera focus (%.0f, %.0f) m [%s]: %s (%.1f ms)", #list, f.x / 100, f.y / 100,
        table.concat(sp, ", "), okB and "ok" or tostring(e), (os.clock() - t0) * 1000)
end

C.help = "commands: info | regen | rebuild | clear | enable | hide | show | toggle | density <off|light|moderate|festive|wonderland> | trees <0-3> | houses <0-3> | lights on|off | seed <n|auto> | goto [tree|house|n] | test [trees|house] | untest | diag | reload | debug on|off"

local function setAndRegen(k, v)
    ctx.cfg[k] = v
    MG.regenerate(false, k .. " set by command")
end

function C.run(line)
    C.last = {}
    local args = {}
    for w in line:gmatch("%S+") do args[#args + 1] = w end
    local cmd = (args[1] or ""):lower()
    if cmd == "festive" then table.remove(args, 1) cmd = (args[1] or ""):lower() end
    L.info("cmd", "> %s", line)
    if cmd == "" or cmd == "help" then out(C.help)
    elseif cmd == "info" then C.info()
    elseif cmd == "regen" or cmd == "regenerate" then
        local okR, e = MG.regenerate(false, "regenerate command")
        out("regenerate: %s", okR and "started (cache used when the resort is unchanged)" or tostring(e))
    elseif cmd == "rebuild" then
        local okR, e = MG.regenerate(true, "rebuild command")
        out("rebuild: %s", okR and "started (placement recomputed, every group rebuilt)" or tostring(e))
    elseif cmd == "clear" or cmd == "disable" then
        ctx.active = false
        out("decorations removed: %d group(s); paused until 'enable'", MG.removeAll("clear command"))
    elseif cmd == "enable" then
        ctx.active = true
        local okR = MG.regenerate(false, "enable command")
        out("Festive Slopes active%s", okR and "" or " (decorations come when a resort loads)")
    elseif cmd == "hide" then out("hidden %d group(s)", SP.setHidden(true))
    elseif cmd == "show" then out("showing %d group(s)", SP.setHidden(false))
    elseif cmd == "toggle" then out("%s %d group(s)", SP.hidden and "showing" or "hiding", SP.setHidden(not SP.hidden))
    elseif cmd == "density" then
        local v = Config.parseValue(args[2] or "", Config.schema.density)
        if not v then out("unknown density '%s' (off, light, moderate, festive, wonderland)", tostring(args[2]))
        else setAndRegen("density", v) out("density %s (until the game restarts; set it in Config/FestiveSlopes.ini to keep it)", v) end
    elseif cmd == "trees" or cmd == "houses" then
        local k = cmd == "trees" and "tree_frequency" or "house_frequency"
        local v = Config.parseValue(args[2] or "", Config.schema[k])
        if not v then out("usage: %s <0-3>", cmd) else setAndRegen(k, v) out("%s = %s", k, tostring(v)) end
    elseif cmd == "lights" then
        setAndRegen("holiday_lighting", args[2] ~= "off")
        out("holiday lighting %s", ctx.cfg.holiday_lighting and "on" or "off")
    elseif cmd == "seed" then
        local n = tonumber(args[2]) or 0
        setAndRegen("placement_seed", math.floor(n))
        out("placement seed %s", n > 0 and tostring(math.floor(n)) or "auto (from the resort)")
    elseif cmd == "goto" then C.gotoCmd(args[2])
    elseif cmd == "test" then C.test(args[2])
    elseif cmd == "untest" then SP.destroyGroup("test") out("test decorations removed")
    elseif cmd == "diag" then C.diag()
    elseif cmd == "reload" then
        ctx.reloadConfig()
        out("config reloaded: %s", Config.describe(ctx.cfg))
        MG.regenerate(false, "config reloaded")
    elseif cmd == "debug" then
        L.debugOn = (args[2] ~= "off")
        out("debug logging %s", L.debugOn and "on" or "off")
    elseif ctx.extraCommands and ctx.extraCommands[cmd] then
        local okX, e = pcall(ctx.extraCommands[cmd], args, out)
        if not okX then out("%s failed: %s", cmd, tostring(e)) end
    else out("unknown command '%s'. %s", cmd, C.help) end
    writeStatus()
end

local function timed(fn)
    local t0 = os.clock()
    local okT, a, b = pcall(fn)
    return (os.clock() - t0) * 1000, okT, a, b
end

-- Read-only probes of every engine feature the mod uses.
function C.diag()
    out("---- diagnostics (Festive Slopes %s) ----", ctx.version)
    out("world: phase %s, generation %d, in resort for %.0f s", W.phase, W.gen, W.inResortFor())
    for _, cls in ipairs({ "/Script/ProceduralMeshComponent.ProceduralMeshComponent", "/Script/Engine.StaticMeshActor" }) do
        out("class %s: %s", cls, W.ok(StaticFindObject(cls)) and "found" or "MISSING")
    end
    local nMiss = 0
    for k, p in pairs(Decor.SOLID) do if not SP.asset(p, true) then nMiss = nMiss + 1 out("material %s (%s): MISSING", k, p) end end
    out("solid materials: %d missing", nMiss)
    out("glow material M_Prop_Unlit: %s", SP.asset("/Game/Materials/M_Prop_Unlit.M_Prop_Unlit", true) and "found" or "MISSING")
    out("game trees: mode %s; %s", tostring(ctx.Trees.mode), tostring(ctx.Trees.note))
    local f = C.cameraFocus()
    if not f then out("camera focus: MISSING") return end
    out("camera focus (%.0f, %.0f, %.0f) m", f.x / 100, f.y / 100, f.z / 100)
    local ms, _, h = timed(function() return S.height(f.x, f.y) end)
    out("height: %s (%.3f ms)", tostring(h), ms)
    ms, _, h = timed(function() return S.slope(f.x, f.y) end)
    out("slope: %s deg (%.3f ms)", tostring(h), ms)
    local inC, dC
    ms = timed(function() inC, dC = S.gameCorridor(f.x, f.y, f.z) end)
    out("TrailMapSubsystem IsPositionInCorridor=%s GetDistanceToCorridor=%s (%.3f ms); geometry distance %.1f m",
        tostring(inC), tostring(dC), ms, S.geoCorridorDistance(f.x, f.y) / 100)
    ms, _, h = timed(function() return S.treesNear(f.x, f.y, f.z, 1500) end)
    out("trees within 15 m: %s (%.3f ms)", tostring(h), ms)
    local trails, err = S.trails(400)
    out("trails: %d%s", #trails, err and (" (" .. err .. ")") or "")
    for i, tr in ipairs(trails) do
        if i > 20 then out("  ...") break end
        out("  trail %s '%s' shape %s, %d line(s), %.0f m, sig %d%s", tostring(tr.id), tostring(tr.name), tostring(tr.shape), #tr.lines,
            tr.length / 100, tr.sig, tr.disabled and " (disabled)" or "")
    end
    local lay = S.placeables()
    out("layout: %d buildings, %d lifts, %d towers, %d saved walkways, %d keep-away points, %d keep-away lines",
        lay.counts.buildings, lay.counts.lifts, lay.counts.towers, lay.counts.walkways, #lay.obstacles, #lay.segments)
    local id = S.identity(ctx.cfg)
    out("identity: name '%s', playthrough %s, map %s -> seed %d (%s)", tostring(id.name), tostring(id.playthrough), tostring(id.map), id.seed, id.source)
    out("---- end diagnostics ----")
end

-- Poll <mod>/commands.txt (called once a second on the game thread).
local nextPoll = 0
function C.pollFile()
    local now = os.clock()
    if now < nextPoll then return end
    nextPoll = now + 1                -- once a second is plenty for a hand-edited file
    local path = ctx.modDir .. "/commands.txt"
    local f = io.open(path, "r")
    if not f then return end
    local text = f:read("a") or ""
    f:close()
    if not text:find("%S") then return end
    local w = io.open(path, "w")
    if w then w:close() end
    for line in text:gmatch("[^\r\n]+") do
        if line:find("%S") and not line:match("^%s*[;#]") then
            local okR, e = pcall(C.run, line)
            if not okR then L.error("cmd", "'%s' failed: %s", line, tostring(e)) end
        end
    end
end

function C.registerInputs(cfg)
    if cfg.keybinds_enabled then
        local okK = pcall(function()
            local mods = { ModifierKey.CONTROL, ModifierKey.ALT }
            RegisterKeyBind(Key.F, mods, function() ExecuteInGameThread(function() C.run("toggle") end) end)
            RegisterKeyBind(Key.G, mods, function() ExecuteInGameThread(function() C.run("regen") end) end)
            RegisterKeyBind(Key.J, mods, function() ExecuteInGameThread(function() C.run("info") end) end)
        end)
        L.info("cmd", "keybinds Ctrl+Alt+F/G/J %s", okK and "registered" or "could not be registered")
    end
    local okC = pcall(function()
        RegisterConsoleCommandHandler("festive", function(full, params)
            local line = "festive"
            pcall(function() for i = 1, #params do line = line .. " " .. tostring(params[i]) end end)
            ExecuteInGameThread(function() C.run(line) end)
            return true
        end)
    end)
    L.info("cmd", "console command 'festive' %s", okC and "registered" or "unavailable")
end

return C
