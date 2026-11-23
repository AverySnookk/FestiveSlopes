-- Festive Slopes: decoration lifecycle.
--   waiting  -> the resort has been loaded for SETTLE seconds and its trail subsystem answers
--   working  -> a job, run as explicit steps a few ms per tick (UE4SS game calls fail inside Lua coroutines):
--               scan -> (cache hit: build) | plan -> validate (batches) -> finish -> build (one group per tick)
--   live     -> decorations up; every update_interval a cheap layout fingerprint check starts a new job if the
--               resort changed (new trail, building, lift...). Unchanged groups are kept as they are.
-- Map changes drop everything (the world destroys our actors); nothing is ever written to the save.
local Rng = require("fs_rng")
local MG = { state = "waiting", job = nil, placements = {}, info = {} }
local W, L, S, P, SP, Decor, Config, Trees, ctx

-- First impression matters (user report 2026-11-22: with 15 s + 4 ms/tick nothing showed for about a minute after a
-- first load, and the player left the resort at 53 s, before the first light was built). The first build of a
-- resort and command-started jobs now get twice the budget, start sooner and build the groups nearest the camera
-- first. Background updates (layout changed) keep the small budget.
local SETTLE = 5             -- s after the resort is up before the first scan (the trail subsystem must answer too)
local BUDGET = 0.004         -- s of work per tick for background jobs
local BUDGET_FAST = 0.008    -- s of work per tick for the first build after a load and for commands
local snowNext, snowKeys, snowI, snowDirty = 0, {}, 1, {}     -- snow watch (below)

function MG.init(c)
    ctx = c
    W, L, S, P, SP, Decor, Config, Trees = c.W, c.L, c.S, c.P, c.SP, c.Decor, c.Config, c.Trees
    W.onMapChange(function()
        MG.state = "waiting"
        MG.job = nil
        snowKeys, snowI, snowDirty = {}, 1, {}
        MG.placements = {}
        MG.info = {}
        MG.lastFp = nil
        MG.swept = false
        S.corridorMode = nil
    end)
end

local function cfg() return ctx.cfg end
local function cachePath(seed) return ctx.modDir .. "/Cache/resort_" .. tostring(seed) .. ".txt" end

-- At most GROUP_MAX decorations per mesh actor: a group's geometry is built in Lua in one tick. Lab 2026-11-22: with
-- the denser 0.1.2 levels, festive groups reached 55 decorations (97k vertices, ticks up to 221 ms); bigger groups
-- are split in a fixed order (stable keys, so unchanged parts are kept on updates).
local GROUP_MAX = 12
local function groupLists(list)
    local g = {}
    for _, o in ipairs(list) do
        local l = g[o.group]
        if not l then l = {} g[o.group] = l end
        l[#l + 1] = o
    end
    local out = {}
    for k, l in pairs(g) do
        if #l <= GROUP_MAX then out[k] = l
        else
            table.sort(l, function(a, b) if a.x ~= b.x then return a.x < b.x end return a.y < b.y end)
            local n = math.ceil(#l / GROUP_MAX)
            for i = 1, n do
                local part = {}
                for j = math.floor((i - 1) * #l / n) + 1, math.floor(i * #l / n) do part[#part + 1] = l[j] end
                out[k .. "." .. i] = part
            end
        end
    end
    return out
end

-- ------------------------------------------------------------------ job steps
local steps = {}

function steps.scan(j)
    local tScan = os.clock()
    local c = cfg()
    local info = j.info
    if c.density == "off" then
        local n = SP.clearAll()
        info.result = string.format("density off: %d group(s) removed", n)
        MG.placements = {}
        L.info("manager", "%s", info.result)
        return "done"
    end
    local id = S.identity(c)
    info.id = id
    local trails, terr = S.trails(400)
    if terr then L.warn("scan", "trail read: %s", terr) end
    S.setTrails(trails)
    if not S.corridorMode then
        local mode, note = S.calibrateCorridor(trails)
        L.info("scan", "skiable area test: %s (%s)", mode, note)
    end
    local lay = S.placeables()
    local fp, nParts = S.fingerprint(trails, lay)
    fp = Rng.hash(fp, Trees.forestSig())               -- trees cleared or planted
    if not Trees.mode then
        local t0 = os.clock()
        Trees.resolve(trails)
        L.info("scan", "game trees: %s (%.0f ms)", Trees.note, (os.clock() - t0) * 1000)
    end
    MG.lastFp = fp
    info.trails, info.layout, info.fp = #trails, lay.counts, fp
    L.info("scan", "resort '%s' (seed %d from %s): %d trail(s), %d building(s), %d small prop(s), %d lift(s), %d tower(s), %d saved walkway(s); fingerprint %d (%d parts); scan %.0f ms",
        tostring(id.name or "?"), id.seed, id.source, #trails, lay.counts.buildings, lay.counts.props, lay.counts.lifts, lay.counts.towers, lay.counts.walkways, fp, nParts, (os.clock() - tScan) * 1000)
    j.key = table.concat({ ctx.version, P.REV, fp, Config.placementKey(c), Trees.mode or "?", S.corridorMode or "?" }, "/")
    j.cachePath = cachePath(id.seed)
    if c.use_cache and not j.opts.force then
        local list = P.loadCache(j.cachePath, j.key)
        if list then
            info.fromCache = true
            j.list = list
            return "prebuild"
        end
    end
    j.gctx = { cfg = c, seed = id.seed, trails = trails, layout = lay }
    return "plan"
end

function steps.plan(j)
    local t0 = os.clock()
    P.plan(j.gctx)
    j.taskI = 1
    j.genT0 = t0
    L.debug("place", "planned %d candidate task(s) on %d trail(s) in %.1f ms", #j.gctx.tasks, #j.gctx.chosen, (os.clock() - t0) * 1000)
    return "validate"
end

function steps.validate(j, deadline)
    j.taskI = P.runTasks(j.gctx, j.taskI, deadline)
    if j.taskI <= #j.gctx.tasks then return "validate" end
    return "finish"
end

function steps.finish(j)
    local g, info, c = j.gctx, j.info, cfg()
    local list = P.finish(g)
    info.genMs = (os.clock() - j.genT0) * 1000
    info.chosen, info.eligible, info.stats = #g.chosen, g.eligible, g.stats
    local why = {}
    for k, v in pairs(g.stats.why) do why[#why + 1] = string.format("%s %d", k, v) end
    table.sort(why)
    L.info("place", "%d of %d eligible trail(s) decorated (density %s): %d candidates tried, %d accepted%s (%.0f ms over several ticks)",
        info.chosen, info.eligible, c.density, g.stats.tried, #list, g.stats.capped and " (capped)" or "", info.genMs)
    if #why > 0 then L.info("place", "rejected: %s", table.concat(why, ", ")) end
    for _, tr in ipairs(g.chosen) do
        L.debug("place", "  trail %s '%s' %.0f m%s: %d tree(s) placed", tostring(tr.id), tostring(tr.name), tr.length / 100,
            tr.showcase and " (showcase)" or "", tr.placed or 0)
    end
    if c.use_cache then
        if P.saveCache(j.cachePath, j.key, list) then info.cached = true
        else L.warn("place", "could not write the placement cache") end
    end
    j.list = list
    return "prebuild"
end

function steps.prebuild(j)
    local info = j.info
    local nT, nH = 0, 0
    for _, o in ipairs(j.list) do if o.kind == "house" then nH = nH + 1 else nT = nT + 1 end end
    info.trees, info.houses = nT, nH
    j.groups = groupLists(j.list)
    j.removed = 0
    for k in pairs(SP.groups) do
        if k ~= "test" and not j.groups[k] then SP.destroyGroup(k) j.removed = j.removed + 1 end
    end
    j.keys = {}
    for k in pairs(j.groups) do j.keys[#j.keys + 1] = k end
    -- nearest to what the player is looking at first (name order when the camera is unknown: stable)
    local f
    pcall(function() f = ctx.Commands.cameraFocus() end)
    local dist = {}
    for _, k in ipairs(j.keys) do
        local sx, sy, n = 0, 0, 0
        for _, o in ipairs(j.groups[k]) do sx, sy, n = sx + o.x, sy + o.y, n + 1 end
        dist[k] = (f and n > 0) and ((sx / n - f.x) ^ 2 + (sy / n - f.y) ^ 2) or 0
    end
    table.sort(j.keys, function(a, b)
        if dist[a] ~= dist[b] then return dist[a] < dist[b] end
        return a < b
    end)
    j.keyI, j.built, j.kept, j.failed = 1, 0, 0, 0
    MG.placements = j.list
    return "build"
end

function steps.build(j, deadline)
    while true do
        if j.cur then
            local done, e = SP.stepGroup(j.cur, deadline)
            if not done then return "build" end
            if e then
                j.failed = j.failed + 1
                L.every("build", 20, "ERROR", "spawn", "group %s failed: %s", j.cur.key, tostring(e))
                SP.destroyGroup(j.cur.key)
            else
                j.built = j.built + 1
            end
            j.cur = nil
            if os.clock() > deadline then return "build" end
        end
        if j.keyI > #j.keys then break end
        local k = j.keys[j.keyI]
        j.keyI = j.keyI + 1
        local list = j.groups[k]
        local g = SP.groups[k]
        if g and not g.building and W.ok(g.actor) and g.sig == SP.listSig(list) and not j.opts.force
            and not (j.opts.rebuild and j.opts.rebuild[k]) then
            j.kept = j.kept + 1
        else
            -- the snow under the group first, a few reads per tick
            if not SP.snowPrefetch(list, deadline) then j.keyI = j.keyI - 1 return "build" end
            local job, e = SP.beginGroup(k, list)
            if job then j.cur = job
            elseif e then
                j.failed = j.failed + 1
                L.every("build", 20, "ERROR", "spawn", "group %s failed: %s", k, tostring(e))
                SP.destroyGroup(k)
            end
            return "build"                      -- sections start next tick: geometry building took this one
        end
    end
    local info = j.info
    info.built, info.kept, info.removed, info.failed = j.built, j.kept, j.removed, j.failed
    info.totalMs = (os.clock() - j.t0) * 1000
    info.result = string.format("%d tree(s), %d gingerbread house(s) in %d group(s): %d built, %d kept, %d removed, %d failed%s",
        info.trees, info.houses, #j.keys, j.built, j.kept, j.removed, j.failed, info.fromCache and " (placements from cache)" or "")
    L.info("manager", "%s (%s; %.1f s wall time)", info.result, tostring(j.opts.reason), info.totalMs / 1000)
    return "done"
end

function MG.start(opts)
    opts = opts or {}
    S.snowForget()                      -- snow falls and melts: read it again for whatever gets built
    MG.job = { opts = opts, step = "scan", info = { reason = opts.reason }, t0 = os.clock() }
    MG.info = MG.job.info
    MG.state = "working"
    L.debug("manager", "job started: %s", tostring(opts.reason))
end

local function runJob()
    local j = MG.job
    local deadline = os.clock() + ((j and j.opts.background) and BUDGET or BUDGET_FAST)
    local guard = 0
    while j and j.step ~= "done" and guard < 20 do
        guard = guard + 1
        local fn = steps[j.step]
        local okS, nextStep = pcall(fn, j, deadline)
        if not okS then
            L.error("manager", "job step %s failed: %s", j.step, tostring(nextStep))
            j.step = "done"
            break
        end
        local same = (nextStep == j.step)
        j.step = nextStep
        if same or os.clock() > deadline then break end
    end
    if not j or j.step == "done" then
        MG.job = nil
        MG.state = "live"
    end
end

-- ------------------------------------------------------------------ snow watch
-- While live, one group's snow is read again every SNOW_EVERY seconds (round robin; one ~1 ms read). A group whose
-- snow rose or fell by more than SNOW_HOUSE (with a house) / SNOW_TREE cm since it was built is rebuilt, so houses
-- are not buried again by a storm and do not float on their base after a thaw.
local SNOW_EVERY, SNOW_HOUSE, SNOW_TREE = 2, 40, 70
local function snowWatch()
    if os.clock() < snowNext then return end
    snowNext = os.clock() + SNOW_EVERY
    if snowI > #snowKeys then
        snowKeys, snowI = {}, 1
        for k, g in pairs(SP.groups) do if g.snow then snowKeys[#snowKeys + 1] = k end end
        table.sort(snowKeys)
        if next(snowDirty) and not MG.job then
            local n = 0
            for _ in pairs(snowDirty) do n = n + 1 end
            L.info("manager", "snow depth changed at %d group(s): rebuilding them", n)
            MG.start({ reason = "snow depth changed", background = true, rebuild = snowDirty })
            snowDirty = {}
        end
        return
    end
    local k = snowKeys[snowI]
    snowI = snowI + 1
    local g = SP.groups[k]
    local w = g and not g.building and g.snow
    if not w then return end
    local d = S.snowDepth(w.x, w.y, "fresh")
    if math.abs(d - w.d) > (w.house and SNOW_HOUSE or SNOW_TREE) then
        L.debug("manager", "group %s: snow %.0f cm, was %.0f when built", k, d, w.d)
        snowDirty[k] = true
    end
end

-- ------------------------------------------------------------------ per tick
local nextCheck = 0
function MG.tick()
    local c = cfg()
    if W.phase ~= "resort" then return end
    if not MG.swept and W.inResortFor() > 3 then
        -- leftovers of an earlier run of this mod in this world (mod restart): remove once
        MG.swept = true
        local n = SP.sweep()
        if n > 0 then L.info("manager", "removed %d leftover decoration actor(s) from an earlier run", n) end
    end
    if MG.state == "waiting" then
        if not ctx.active then return end
        if W.inResortFor() < SETTLE then return end
        if not W.live("TrailMapSubsystem") then return end
        MG.start({ reason = "resort loaded" })
        nextCheck = os.clock() + c.update_interval_seconds
    end
    if MG.state == "working" then runJob() return end
    if MG.state == "live" and ctx.active then snowWatch() end
    if MG.state == "live" and ctx.active and c.auto_update and os.clock() >= nextCheck then
        nextCheck = os.clock() + c.update_interval_seconds
        local t0 = os.clock()
        local trails = S.trails(400)
        local lay = S.placeables()
        local fp = Rng.hash(S.fingerprint(trails, lay), Trees.forestSig())
        L.debug("manager", "layout check %.1f ms (fingerprint %d, was %s)", (os.clock() - t0) * 1000, fp, tostring(MG.lastFp))
        if MG.lastFp and fp ~= MG.lastFp then
            L.info("manager", "resort layout changed: updating decorations")
            MG.start({ reason = "layout changed", background = true })
        end
    end
end

function MG.regenerate(force, reason)
    if W.phase ~= "resort" then return false, "not in a resort" end
    if force then SP.clearAll() end
    MG.start({ force = force, reason = reason or "regenerate command" })
    return true
end

function MG.removeAll(why)
    MG.job = nil
    MG.state = "live"
    local n = SP.clearAll()
    MG.placements = {}
    L.info("manager", "removed %d group(s): %s", n, tostring(why))
    return n
end

return MG
