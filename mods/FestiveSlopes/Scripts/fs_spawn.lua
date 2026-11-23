-- Festive Slopes: turns placements into actors in the world.
-- One actor per group (a stretch of trail): a StaticMeshActor used only as a holder, with
--   * a ProceduralMeshComponent "solid" (one section per game material, casts shadows)
--   * a ProceduralMeshComponent "glow" (unlit coloured lights/windows, no shadows)
-- No collision anywhere: decorations can't block clicks, guests, placement or skiing. Nothing is registered with
-- the game's placeable registry, so nothing reaches the save file.
-- Rule from Ski-E-O Together 0.14.5: never keep asset objects only we reference between builds (GC frees them);
-- they are looked up by name at build time, and while decorations exist their components hold them.
local Mesh = require("fs_mesh")
local Rng = require("fs_rng")
local SP = { groups = {}, stats = { actors = 0, verts = 0, tris = 0, sections = 0, buildMs = 0, worstMs = 0 }, Mesh = Mesh }
local W, L, S, Decor, cfg

SP.TAG = "FestiveSlopes"
local UNLIT = "/Game/Materials/M_Prop_Unlit.M_Prop_Unlit"
local COLOR_PARAMS = { "Color", "BaseColor", "Base Color", "EmissiveColor", "Emissive Color", "Emissive", "Tint", "TintColor" }

function SP.init(world, log, resort, decor, config)
    W, L, S, Decor, cfg = world, log, resort, decor, config
    world.onMapChange(function()
        -- the old world destroys its actors itself; calling into them now could crash (Yeti Mayhem / Together)
        SP.groups = {}
        SP.hidden = false
    end)
end
function SP.setConfig(c) cfg = c end

local function ok(o) return W.ok(o) end

-- Materials are pinned: a hidden holder component in the current world references every material the mod uses, so
-- the garbage collector never unloads one while the mod still wants it (lab 2026-11-21: materials were unloaded
-- and reloaded between builds, and a festive build crashed 0.7 s after such a reload). Pinned objects are reused
-- instead of being looked up by name again, and the holder dies with its world.
local missing = {}
local pinned = {}               -- path -> object, valid while the holder lives
local holder, holderComp, holderWorld, pinCount
local PM = "/Script/ProceduralMeshComponent.ProceduralMeshComponent"
local class, tagActor, addComponent
local function pinHolder()
    local w = W.world()
    if not w then return nil end
    local wa = w:GetAddress()
    if holderWorld == wa and ok(holder) and ok(holderComp) then return holderComp end
    pinned, holder, holderComp, holderWorld, pinCount = {}, nil, nil, wa, 0
    local a
    pcall(function()
        a = w:SpawnActor(class("/Script/Engine.StaticMeshActor"), { X = 0, Y = 0, Z = -100000 }, { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    if not ok(a) then return nil end
    tagActor(a)
    pcall(function() a.StaticMeshComponent:SetCollisionEnabled(0) end)
    pcall(function() a:SetActorHiddenInGame(true) end)
    local c = addComponent(a, PM)
    if not c then pcall(function() a:K2_DestroyActor() end) return nil end
    holder, holderComp = a, c
    return c
end
-- pin = true only for materials (the holder references them as its materials)
local function asset(path, pin)
    local p = pinned[path]
    if p and ok(holderComp) and ok(p) then return p end
    if missing[path] then return nil end
    local o
    pcall(function() o = StaticFindObject(path) end)
    if not ok(o) then
        pcall(function() o = LoadAsset(path) end)
        if not ok(o) then missing[path] = true L.warn("spawn", "asset not available: %s", path) return nil end
    end
    local c = pin and pinHolder()
    if c then
        pcall(function() c:SetMaterial(pinCount, o) end)
        pinCount = pinCount + 1
        pinned[path] = o
    end
    return o
end
SP.asset = asset
function SP.forgetMissing() missing = {} end

local classes = {}
function class(path)
    local c = classes[path]
    if not ok(c) then c = StaticFindObject(path) classes[path] = c end
    return ok(c) and c or nil
end

-- Size of a mesh (pivot at the base): height and widest radius at scale 1. Used for the game's tree meshes.
local meshDimsCache = {}
function SP.meshDims(path)
    local d = meshDimsCache[path]
    if d ~= nil then return d or nil end
    local m = asset(path)
    if not m then meshDimsCache[path] = false return nil end
    pcall(function()
        local bnd = m:GetBounds()
        local h = (tonumber(bnd.Origin.Z) or 0) + (tonumber(bnd.BoxExtent.Z) or 0)
        local r = math.max(tonumber(bnd.BoxExtent.X) or 0, tonumber(bnd.BoxExtent.Y) or 0)
        if h > 100 and r > 50 then d = { h = h, r = r } end
    end)
    meshDimsCache[path] = d or false
    return d
end

-- ------------------------------------------------------------------ geometry for one group
-- Returns builder, origin, number of decorations whose ground moved since they were placed
local function buildGroup(list)
    local ox, oy, oz = 0, 0, math.huge
    for _, o in ipairs(list) do ox, oy = ox + o.x, oy + o.y oz = math.min(oz, o.z) end
    ox, oy = ox / #list, oy / #list
    if oz == math.huge then oz = 0 end
    local b = Mesh.builder()
    local nRe = 0
    for _, o in ipairs(list) do
        if o.kind == "tree" then
            -- a tree of the game: lights around it, from its trunk base (the game's own position)
            local t = o.look
            b:place(o.x - ox, o.y - oy, o.z - oz, 0, 1)
            local function ground(lx, ly)
                local hz = S.height(o.x + lx, o.y + ly)
                return hz and (hz - o.z) or 0
            end
            Decor.drawLights(b, t, ground, t.gy, Rng)
        elseif o.kind == "house" then
            -- the ground may have been reshaped since the placement was cached: follow it
            local z = S.height(o.x, o.y) or o.z
            if math.abs(z - o.z) > 1 then nRe = nRe + 1 end
            local h = o.look
            local sc = h.scale
            local a = math.rad(o.yaw)
            local c, s = math.cos(a), math.sin(a)
            -- sink the house to the lowest point of its footprint so no side floats
            local lo = z
            for _, q in ipairs({ { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }) do
                local lx, ly = q[1] * h.w / 2 * sc, q[2] * h.l / 2 * sc
                local hz = S.height(o.x + lx * c - ly * s, o.y + lx * s + ly * c)
                if hz and hz < lo then lo = hz end
            end
            local baseZ = lo
            b:place(o.x - ox, o.y - oy, baseZ - oz, o.yaw, sc)
            local function ground(lx, ly)
                local wx = o.x + sc * (lx * c - ly * s)
                local wy = o.y + sc * (lx * s + ly * c)
                local hz = S.height(wx, wy)
                return hz and (hz - baseZ) / sc or 0
            end
            Decor.drawHouse(b, h, ground, Rng)
        elseif o.kind == "marker" then
            b:place(o.x - ox, o.y - oy, (S.height(o.x, o.y) or o.z) - oz, 0, 1)
            Decor.drawMarker(b, o.ok)
        end
    end
    return b, { ox, oy, oz }, nRe
end

-- ------------------------------------------------------------------ actors
function tagActor(a)
    pcall(function() a.Tags[#a.Tags + 1] = FName(SP.TAG) end)
end

local function isOurs(a)
    local yes = false
    pcall(function()
        a.Tags:ForEach(function(_, t) if t:get():ToString() == SP.TAG then yes = true end end)
    end)
    return yes
end
SP.isOurs = isOurs

-- Destroys every actor of ours in the current world, including ones left by an earlier run of the mod
-- (e.g. after a UE4SS mod restart). Walks all StaticMeshActors once: only called at start-up / on "clear all".
function SP.sweep()
    local w = W.world()
    if not w then return 0 end
    local wa = w:GetAddress()
    local n = 0
    for _, a in ipairs(FindAllOf("StaticMeshActor") or {}) do
        if ok(a) then
            local same = false
            pcall(function() same = a:GetWorld():GetAddress() == wa end)
            if same and isOurs(a) then pcall(function() a:K2_DestroyActor() end) n = n + 1 end
        end
    end
    SP.groups = {}
    return n
end

local function destroyGroup(key)
    local g = SP.groups[key]
    if g and ok(g.actor) then pcall(function() g.actor:K2_DestroyActor() end) end
    SP.groups[key] = nil
end
SP.destroyGroup = destroyGroup

function SP.clearAll()
    local n = 0
    for k in pairs(SP.groups) do destroyGroup(k) n = n + 1 end
    return n
end

local function identityTransform(x, y, z)
    return { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = x or 0, Y = y or 0, Z = z or 0 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
end

function addComponent(actor, classPath)
    local cls = class(classPath)
    if not cls then return nil, "class missing: " .. classPath end
    local comp
    local okA, err = pcall(function() comp = actor:AddComponentByClass(cls, false, identityTransform(), false) end)
    if not okA then return nil, tostring(err) end
    if not ok(comp) then return nil, "AddComponentByClass returned nothing" end
    pcall(function() comp:SetCollisionEnabled(0) end)
    return comp
end

local function glowMaterial(comp, idx, key)
    local base = asset(UNLIT, true)
    if not base then return nil end
    local mid
    pcall(function() mid = comp:CreateDynamicMaterialInstance(idx, base, FName("None")) end)
    if not ok(mid) then return nil end
    local col = Decor.GLOW[key] or { 1, 1, 1 }
    local k = (cfg.light_brightness or 1) * 3.0
    for _, pn in ipairs(COLOR_PARAMS) do
        pcall(function() mid:SetVectorParameterValue(FName(pn), { R = col[1] * k, G = col[2] * k, B = col[3] * k, A = 1 }) end)
    end
    return mid
end

-- Creating a group is split into small jobs that run over several ticks (one engine call batch per job), so a
-- big group neither hitches the frame nor hands the engine huge arrays at once:
--   SP.beginGroup(key, list) -> job   builds the geometry in Lua and spawns the holder actor
--   SP.stepGroup(job, deadline) -> done, err   creates sections / instances until the deadline (at least one)
-- Lab 2026-11-21: one 27k-vertex group created in a single tick crashed inside UE4SS.
function SP.beginGroup(key, list)
    destroyGroup(key)
    if #list == 0 then return nil end
    local t0 = os.clock()
    local b, origin, nRe = buildGroup(list)
    local w = W.world()
    if not w then return nil, "no world" end
    local actor
    local okS, err = pcall(function()
        actor = w:SpawnActor(class("/Script/Engine.StaticMeshActor"), { X = origin[1], Y = origin[2], Z = origin[3] }, { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    if not (okS and ok(actor)) then return nil, "SpawnActor failed: " .. tostring(err) end
    tagActor(actor)
    pcall(function() actor.StaticMeshComponent:SetCollisionEnabled(0) end)
    if SP.hidden then pcall(function() actor:SetActorHiddenInGame(true) end) end
    SP.groups[key] = { actor = actor, n = #list, sig = SP.listSig(list), building = true }
    local queue = {}
    local solid, glow = {}, {}
    for _, k in ipairs(b.order) do
        if #b.secs[k].t > 0 then
            if Decor.isGlow(k) then glow[#glow + 1] = k else solid[#solid + 1] = k end
        end
    end
    -- at most SECS_PER_COMP sections per mesh component (festive groups reached 31 on one component)
    for _, kind in ipairs({ { "solid", solid, false }, { "glow", glow, true } }) do
        local name, keys, isGlow = kind[1], kind[2], kind[3]
        for i, k in ipairs(keys) do
            local n = math.floor((i - 1) / SP.SECS_PER_COMP)
            local slot = name .. n
            local idx = (i - 1) % SP.SECS_PER_COMP
            if idx == 0 then queue[#queue + 1] = { op = "comp", slot = slot, glow = isGlow } end
            queue[#queue + 1] = { op = "sec", slot = slot, key = k, idx = idx, glow = isGlow }
        end
    end
    return { key = key, actor = actor, b = b, queue = queue, qi = 1, comps = {}, t0 = t0, ms = (os.clock() - t0) * 1000,
        n = #list, nRe = nRe, nSec = #solid + #glow }
end

SP.SECS_PER_COMP = 10
local function runItem(job, it)
    if not ok(job.actor) then return false, "actor gone" end
    if it.op == "comp" then
        local comp, e = addComponent(job.actor, PM)
        if not comp then return false, it.slot .. " mesh: " .. tostring(e) end
        if it.glow then pcall(function() comp:SetCastShadow(false) end) end
        job.comps[it.slot] = comp
    elseif it.op == "sec" then
        local comp = job.comps[it.slot]
        if not ok(comp) then return false, it.slot .. " component gone" end
        local s = job.b.secs[it.key]
        local okC, err = pcall(function() comp:CreateMeshSection(it.idx, s.v, s.t, s.n, s.uv, {}, {}, false) end)
        if not okC then return false, "CreateMeshSection: " .. tostring(err) end
        if it.glow then
            if not glowMaterial(comp, it.idx, s.mat) then L.every("glowmat", 30, "WARN", "spawn", "glow material for %s unavailable", s.mat) end
        else
            local m = asset(Decor.SOLID[s.mat] or "", true)
            if m then pcall(function() comp:SetMaterial(it.idx, m) end) end
        end
        job.b.secs[it.key] = nil          -- handed to the engine: let Lua free it
        SP.stats.sections = SP.stats.sections + 1
    end
    return true
end

function SP.stepGroup(job, deadline)
    local t0 = os.clock()
    repeat
        local it = job.queue[job.qi]
        if not it then break end
        job.qi = job.qi + 1
        local okR, e = runItem(job, it)
        if not okR then
            job.ms = job.ms + (os.clock() - t0) * 1000
            return true, e
        end
    until os.clock() > deadline
    job.ms = job.ms + (os.clock() - t0) * 1000
    if job.queue[job.qi] then return false end
    local g = SP.groups[job.key]
    local v, tr = job.b:stats()
    if g then g.building = nil g.verts = v end
    local st = SP.stats
    st.verts, st.tris = st.verts + v, st.tris + tr
    st.buildMs = st.buildMs + job.ms
    if job.ms > st.worstMs then st.worstMs = job.ms end
    L.debug("spawn", "group %s: %d decoration(s), %d verts, %d tris, %d section(s), %d re-snapped, %.1f ms engine+Lua over %.1f s",
        job.key, job.n, v, tr, job.nSec, job.nRe, job.ms, os.clock() - job.t0)
    return true
end

-- Whole group in one go (debug "test" command only: small lists).
function SP.spawnGroup(key, list)
    local job, e = SP.beginGroup(key, list)
    if not job then return e == nil, e end
    local done, err
    repeat done, err = SP.stepGroup(job, 0) until done
    return err == nil, err
end

-- A signature of a group's content, so unchanged groups are not rebuilt after a rescan.
function SP.listSig(list)
    local parts = {}
    for _, o in ipairs(list) do parts[#parts + 1] = string.format("%s%d,%d,%d", o.kind, math.floor(o.x), math.floor(o.y), math.floor(o.yaw or 0)) end
    table.sort(parts)
    return Rng.hash(table.concat(parts, ";"), cfg.light_brightness, tostring(cfg.holiday_lighting))
end

function SP.setHidden(h)
    SP.hidden = h
    local n = 0
    for _, g in pairs(SP.groups) do
        if ok(g.actor) then pcall(function() g.actor:SetActorHiddenInGame(h) end) n = n + 1 end
    end
    return n
end

function SP.count()
    local g, d = 0, 0
    for _, x in pairs(SP.groups) do g = g + 1 d = d + (x.n or 0) end
    return g, d
end

return SP
