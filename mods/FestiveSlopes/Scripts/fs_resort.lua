-- Festive Slopes: reads the resort layout from the game (read-only) and answers "what is here?" questions.
--   Trails:     TrailMapSubsystem.RegisteredTrails  TMap<int32, FTrailInfo>  (Curve / AdditionalCurves = quadratic
--               Bezier FTrailCurve{StartPoint, ControlPoint, Endpoint, CorridorWidth, EndCorridorWidth}; bowls have
--               Shape = 1 and a BowlOutline polygon). The skiable area is asked from the game itself:
--               TrailMapSubsystem:IsPositionInCorridor / GetDistanceToCorridor (geometry fallback if unavailable).
--   Terrain:    TerrainUtils:GetHeightAtLocation / GetSlopeAngleAtLocation
--   Trees:      ObstacleDataManager:QueryObstaclesNearPosition
--   Buildings:  PlaceableRegistrySubsystem.Buildings (+ actor bounds)
--   Lifts:      PlaceableRegistrySubsystem.Lifts -> Waypoints (terminals, cable line), TowerMeshComponents
--   Walkways:   not reflected live; the save the resort was loaded from (GameSessionSubsystem.PendingLoadSave
--               .WalkwayMapData.Runs[].Points) is used, plus clearance around buildings and lift stations.
-- Distances are in cm (Unreal units) unless a name says _m.
local Rng = require("fs_rng")
local S = { stats = { height = 0, slope = 0, corridor = 0, trees = 0 } }
local W, L

function S.init(world, log)
    W, L = world, log
    W.onMapChange(function() S.snowReset() end)
end

local function ok(o) return W.ok(o) end

local function vec(v)
    if v == nil then return nil end
    local x, y, z
    pcall(function() x, y, z = tonumber(v.X), tonumber(v.Y), tonumber(v.Z) end)
    if x and y then return x, y, z or 0 end
    return nil
end
S.vec = vec

local function forEach(arr, fn)
    if arr == nil then return end
    if type(arr) == "table" then
        for i, v in ipairs(arr) do fn(i, v) end
        return
    end
    arr:ForEach(function(i, e) fn(i, e:get()) end)
end
S.forEach = forEach

-- ------------------------------------------------------------------ terrain
local utilsCDO
local function utils()
    if not ok(utilsCDO) then utilsCDO = StaticFindObject("/Script/SkiResortSimulator.Default__TerrainUtils") end
    return ok(utilsCDO) and utilsCDO or nil
end

function S.height(x, y)
    S.stats.height = S.stats.height + 1
    local w, u = W.world(), utils()
    if not (w and u) then return nil end
    local z
    local s = pcall(function() z = u:GetHeightAtLocation(w, { X = x, Y = y }) end)
    z = tonumber(z)
    if s and z and z == z and math.abs(z) < 1e8 then return z end
    return nil
end

function S.slope(x, y)
    S.stats.slope = S.stats.slope + 1
    local w, u = W.world(), utils()
    if not (w and u) then return nil end
    local a
    pcall(function() a = u:GetSlopeAngleAtLocation(w, { X = x, Y = y }) end)
    a = tonumber(a)
    if a and a == a then return a end
    return nil
end

-- ------------------------------------------------------------------ snow depth
-- The terrain height functions answer the bare ground (lab 2026-11-22: GetHeightAtLocation, SnapToTerrain,
-- SnapToBaseTerrain and GetGroundHeightAtLocation all gave the same value), but the game's snow is up to a few
-- metres deep on top of it and buried the gingerbread houses (user report 2026-11-22). The snow simulation keeps a
-- CPU-readable copy of its coarse grid: SnowSimulationSubsystem.CoarseMipReadbackFp16RT, GetGridResolution() cells
-- (1162 on Palisades Tahoe) of SnowCoarseCellSizeCm (800) each, centred on the landscape. Lab readings: R and G
-- are snow depths in cm (about 200 + 35 at the houses beside the forest, near 0 under the game's own buildings,
-- which clear the snow), so the surface is the ground + R + G. ReadRenderTargetRawUV costs about 1 ms (it waits
-- for the render thread), so each 8 m cell is read once and remembered; the block read
-- (ReadRenderTargetRawUVArea) came back with a single value through UE4SS and is not used.
local snow = { cells = {}, state = nil }
S.SNOW_MAX = 600             -- cm; a larger reading is treated as noise

local function snowSetup()
    if snow.state or (snow.state == false and os.clock() < snow.retry) then return snow.state end
    snow.state, snow.retry = false, os.clock() + 30
    local okS = pcall(function()
        local ss = W.live("SnowSimulationSubsystem")
        if not ok(ss) then return end
        local rt = ss.CoarseMipReadbackFp16RT
        local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
        local res = tonumber(ss:GetGridResolution())
        local cell = tonumber(ss.CachedSnowTileSettings.SnowCoarseCellSizeCm)
        if not (ok(rt) and ok(krl) and res and res > 0 and cell and cell > 0) then return end
        local cx, cy = 0, 0
        for _, a in ipairs(FindAllOf("Landscape") or {}) do
            if ok(a) then
                local o, e = {}, {}
                pcall(function() a:GetActorBounds(false, o, e, false) end)
                if tonumber(o.X) then cx, cy = o.X, o.Y break end
            end
        end
        snow.rt, snow.krl, snow.res, snow.cell = rt, krl, res, cell
        snow.x0, snow.y0 = cx - res * cell / 2, cy - res * cell / 2
        snow.state = true
    end)
    if snow.state then
        L.info("snow", "snow depth readable: %d x %d cells of %.0f cm from (%.0f, %.0f)", snow.res, snow.res, snow.cell, snow.x0, snow.y0)
    elseif not snow.warned then
        snow.warned = true
        L.warn("snow", "snow depth not readable%s: decorations stand on the bare ground", okS and "" or " (error)")
    end
    return snow.state
end

local function snowKey(x, y)
    local ix, iy = math.floor((x - snow.x0) / snow.cell), math.floor((y - snow.y0) / snow.cell)
    if ix < 0 or iy < 0 or ix >= snow.res or iy >= snow.res then return nil end
    return iy * snow.res + ix, ix, iy
end

-- Snow depth (cm) at (x, y), or the remembered value; 0 when unknown. read=false: only what is remembered (nil if
-- not); read="fresh": ask the game even if remembered.
function S.snowDepth(x, y, read)
    if not snowSetup() then return 0 end
    local k, ix, iy = snowKey(x, y)
    if not k then return 0 end
    local d = snow.cells[k]
    if read == false or (d and read ~= "fresh") then return d end
    d = 0
    pcall(function()
        local c = snow.krl:ReadRenderTargetRawUV(W.world(), snow.rt, (ix + 0.5) / snow.res, (iy + 0.5) / snow.res, false)
        local r, g = tonumber(c.R) or 0, tonumber(c.G) or 0
        d = math.max(0, r) + math.max(0, g)
        if d ~= d or d > S.SNOW_MAX then d = 0 end
    end)
    S.stats.snow = (S.stats.snow or 0) + 1
    snow.cells[k] = d
    return d
end

-- Forget remembered depths (snow falls and melts): the next reads ask the game again.
function S.snowForget() snow.cells = {} end
function S.snowReset() snow.cells, snow.state, snow.warned = {}, nil, nil end

-- Number of natural trees/rocks (obstacles) within radius.
function S.treesNear(x, y, z, radius)
    S.stats.trees = S.stats.trees + 1
    local om = W.live("ObstacleDataManager")
    if not om then return 0 end
    local n = 0
    pcall(function()
        local arr = om:QueryObstaclesNearPosition({ X = x, Y = y, Z = z or 0 }, radius)
        if type(arr) == "table" then n = #arr elseif arr then n = arr:GetArrayNum() end
    end)
    return tonumber(n) or 0
end

-- ------------------------------------------------------------------ identity / seed
-- A stable seed for this resort: its playthrough id (kept by the game across saves of the same resort), else the
-- resort name, else the map. placement_seed in the config overrides it.
function S.identity(cfg)
    local id = { source = "map" }
    pcall(function()
        local gss = W.live("GameSessionSubsystem")
        local s = gss and gss.PendingLoadSave
        if ok(s) then
            local p = s.PlaythroughId
            local a, b, c, d = tonumber(p.A) or 0, tonumber(p.B) or 0, tonumber(p.C) or 0, tonumber(p.D) or 0
            if a ~= 0 or b ~= 0 or c ~= 0 or d ~= 0 then
                id.playthrough = string.format("%08X%08X%08X%08X", a % 4294967296, b % 4294967296, c % 4294967296, d % 4294967296)
                id.source = "playthrough"
            end
            pcall(function() id.name = s.ResortName:ToString() end)
            pcall(function() if not id.name or id.name == "" then id.name = s.SaveDisplayName:ToString() end end)
            pcall(function() id.map = s.MapPath:ToString() end)
        end
    end)
    if not id.map then
        pcall(function() id.map = W.world():GetFullName():match("([^%.:]+)$") end)
    end
    if id.playthrough then id.seed = Rng.hash("pt", id.playthrough)
    elseif id.name and id.name ~= "" then id.seed = Rng.hash("name", id.name) id.source = "resort name"
    else id.seed = Rng.hash("map", id.map or "?") end
    if cfg and cfg.placement_seed and cfg.placement_seed > 0 then id.seed = cfg.placement_seed id.source = "config placement_seed" end
    return id
end

-- ------------------------------------------------------------------ trails
local function quad(p0, p1, p2, t)
    local u = 1 - t
    return u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1], u * u * p0[2] + 2 * u * t * p1[2] + t * t * p2[2]
end

-- Resample one trail curve into points every `step` cm with half widths and unit tangents.
local function sampleCurve(c, step)
    local sx, sy = vec(c.StartPoint)
    local cx, cy = vec(c.ControlPoint)
    local ex, ey = vec(c.Endpoint)
    if not (sx and ex) then return nil end
    if not cx then cx, cy = (sx + ex) / 2, (sy + ey) / 2 end
    local w1 = tonumber(c.CorridorWidth) or 3000
    local w2 = tonumber(c.EndCorridorWidth) or 0
    if w2 <= 0 then w2 = w1 end
    local p0, p1, p2 = { sx, sy }, { cx, cy }, { ex, ey }
    -- fine arc-length table
    local N = 96
    local xs, ys, ls = { sx }, { sy }, { 0 }
    for i = 1, N do
        local x, y = quad(p0, p1, p2, i / N)
        xs[i + 1], ys[i + 1] = x, y
        ls[i + 1] = ls[i] + math.sqrt((x - xs[i]) ^ 2 + (y - ys[i]) ^ 2)
    end
    local total = ls[N + 1]
    if total < 100 then return nil end
    local pts = {}
    local n = math.max(2, math.floor(total / step + 0.5))
    local j = 1
    for k = 0, n do
        local s = total * k / n
        while j < N and ls[j + 1] < s do j = j + 1 end
        local seg = ls[j + 1] - ls[j]
        local f = seg > 0 and (s - ls[j]) / seg or 0
        local t = ((j - 1) + f) / N
        local x, y = quad(p0, p1, p2, t)
        -- tangent of the quadratic Bezier
        local dx = 2 * (1 - t) * (cx - sx) + 2 * t * (ex - cx)
        local dy = 2 * (1 - t) * (cy - sy) + 2 * t * (ey - cy)
        local dl = math.sqrt(dx * dx + dy * dy)
        if dl < 1e-6 then dx, dy, dl = ex - sx, ey - sy, math.max(1, math.sqrt((ex - sx) ^ 2 + (ey - sy) ^ 2)) end
        pts[#pts + 1] = { x = x, y = y, s = s, t = t, hw = (w1 + (w2 - w1) * t) / 2, tx = dx / dl, ty = dy / dl }
    end
    return { pts = pts, length = total, closed = false }
end

-- A bowl outline as an edge polyline with outward tangents (normals are derived the same way as for curves).
local function sampleOutline(outline, step)
    local raw = {}
    forEach(outline, function(_, v) local x, y = vec(v) if x then raw[#raw + 1] = { x, y } end end)
    if #raw < 3 then return nil end
    local cx, cy = 0, 0
    for _, p in ipairs(raw) do cx, cy = cx + p[1], cy + p[2] end
    cx, cy = cx / #raw, cy / #raw
    local pts, s = {}, 0
    for i = 1, #raw do
        local a, b = raw[i], raw[i % #raw + 1]
        local dx, dy = b[1] - a[1], b[2] - a[2]
        local len = math.sqrt(dx * dx + dy * dy)
        if len > 1 then
            local n = math.max(1, math.floor(len / step + 0.5))
            for k = 0, n - 1 do
                local f = k / n
                pts[#pts + 1] = { x = a[1] + dx * f, y = a[2] + dy * f, s = s + len * f, hw = 0, tx = dx / len, ty = dy / len }
            end
            s = s + len
        end
    end
    return { pts = pts, length = s, closed = true, cx = cx, cy = cy }
end

-- A trail is usually several curve pieces (the base curve + ExtendTrailWithCurve pieces) that join end to start.
-- Joins open pieces whose ends meet (within 8 m, either direction) into longer polylines, so a trail is walked as
-- one continuous edge instead of many short ones (each with its own end margins).
local function reversed(l)
    local pts, n = {}, #l.pts
    for i = n, 1, -1 do
        local p = l.pts[i]
        pts[#pts + 1] = { x = p.x, y = p.y, hw = p.hw, tx = -p.tx, ty = -p.ty, t = p.t, s = l.length - p.s }
    end
    return { pts = pts, length = l.length, closed = false }
end
local function joinTo(a, b)
    local off = a.length
    for i = 2, #b.pts do
        local p = b.pts[i]
        a.pts[#a.pts + 1] = { x = p.x, y = p.y, hw = p.hw, tx = p.tx, ty = p.ty, t = p.t, s = off + p.s }
    end
    a.length = a.length + b.length
end
function S.chain(lines)
    local out, open = {}, {}
    for _, l in ipairs(lines) do if l.closed then out[#out + 1] = l else open[#open + 1] = l end end
    local JOIN = 800
    local function d2(p, q) return (p.x - q.x) ^ 2 + (p.y - q.y) ^ 2 end
    while #open > 0 do
        local first = table.remove(open, 1)
        local cur = { pts = {}, length = first.length, closed = false }
        for i, p in ipairs(first.pts) do cur.pts[i] = p end
        local grown = true
        while grown do
            grown = false
            for i, l in ipairs(open) do
                local head, tail = cur.pts[1], cur.pts[#cur.pts]
                local a, b = l.pts[1], l.pts[#l.pts]
                local matched = true
                if d2(tail, a) < JOIN * JOIN then joinTo(cur, l)
                elseif d2(tail, b) < JOIN * JOIN then joinTo(cur, reversed(l))
                elseif d2(head, b) < JOIN * JOIN then
                    local r = { pts = {}, length = l.length, closed = false }
                    for k, p in ipairs(l.pts) do r.pts[k] = p end
                    joinTo(r, cur) cur = r
                elseif d2(head, a) < JOIN * JOIN then
                    local r = reversed(l) joinTo(r, cur) cur = r
                else matched = false end
                if matched then
                    table.remove(open, i)
                    grown = true
                    break
                end
            end
        end
        out[#out + 1] = cur
    end
    return out
end

-- Every trail as { id, name, shape, lines = { polyline, ... }, length, sig }.
function S.trails(step)
    step = step or 400
    local out = {}
    local tm = W.live("TrailMapSubsystem")
    if not tm then return out, "no TrailMapSubsystem" end
    local okAll, err = pcall(function()
        tm.RegisteredTrails:ForEach(function(k, v)
            local info = v:get()
            local tr = { lines = {}, length = 0 }
            pcall(function() tr.id = tonumber(k:get()) end)
            pcall(function() tr.id = tr.id or tonumber(info.TrailId) end)
            pcall(function() tr.name = info.DisplayName:ToString() end)
            pcall(function() tr.shape = tonumber(info.Shape) or 0 end)
            pcall(function() tr.disabled = info.bManuallyDisabled == true end)
            pcall(function() tr.maxSlope = tonumber(info.MaxSlopeAngle) end)
            local sigParts = {}
            local function addLine(l)
                if l and #l.pts >= 2 then
                    tr.lines[#tr.lines + 1] = l
                    tr.length = tr.length + l.length
                    local a, b = l.pts[1], l.pts[#l.pts]
                    sigParts[#sigParts + 1] = string.format("%d,%d,%d,%d", math.floor(a.x / 100), math.floor(a.y / 100), math.floor(b.x / 100), math.floor(b.y / 100))
                end
            end
            if tr.shape == 1 then
                pcall(function() addLine(sampleOutline(info.BowlOutline, step)) end)
            end
            pcall(function() addLine(sampleCurve(info.Curve, step)) end)
            pcall(function() info.AdditionalCurves:ForEach(function(_, c) addLine(sampleCurve(c:get(), step)) end) end)
            tr.pieces = #tr.lines
            tr.lines = S.chain(tr.lines)
            if #tr.lines > 0 then
                -- geometry signature: same trail = same decorations, whatever its id or name
                tr.sig = Rng.hash(table.concat(sigParts, ";"))
                out[#out + 1] = tr
            end
        end)
    end)
    if not okAll then return out, tostring(err) end
    table.sort(out, function(a, b) return a.sig < b.sig end)
    return out
end

-- ------------------------------------------------------------------ the skiable area
-- The game's own corridor test is used when it answers (checked once per world: S.corridorMode).
S.corridorMode = nil       -- "game" | "geometry"
local geoTrails             -- trails used by the geometry fallback

function S.setTrails(trails) geoTrails = trails end

local function segDist(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local l2 = dx * dx + dy * dy
    local t = l2 > 0 and ((px - ax) * dx + (py - ay) * dy) / l2 or 0
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local qx, qy = ax + dx * t, ay + dy * t
    return math.sqrt((px - qx) ^ 2 + (py - qy) ^ 2), t
end
S.segDist = segDist

local function pointInPoly(px, py, pts)
    local inside = false
    local j = #pts
    for i = 1, #pts do
        local a, b = pts[i], pts[j]
        if ((a.y > py) ~= (b.y > py)) and (px < (b.x - a.x) * (py - a.y) / ((b.y - a.y) ~= 0 and (b.y - a.y) or 1e-9) + a.x) then inside = not inside end
        j = i
    end
    return inside
end

-- Distance (cm) from the point to the nearest skiable corridor edge (negative = inside a corridor), by geometry.
function S.geoCorridorDistance(x, y)
    local best = math.huge
    for _, tr in ipairs(geoTrails or {}) do
        for _, l in ipairs(tr.lines) do
            local pts = l.pts
            if l.closed then
                local inside = pointInPoly(x, y, pts)
                local d = math.huge
                for i = 1, #pts do
                    local a, b = pts[i], pts[i % #pts + 1]
                    local dd = segDist(x, y, a.x, a.y, b.x, b.y)
                    if dd < d then d = dd end
                end
                d = inside and -d or d
                if d < best then best = d end
            else
                for i = 1, #pts - 1 do
                    local a, b = pts[i], pts[i + 1]
                    -- quick reject
                    local r = math.max(a.hw, b.hw) + 60000
                    if math.abs(x - a.x) < r and math.abs(y - a.y) < r then
                        local d, t = segDist(x, y, a.x, a.y, b.x, b.y)
                        d = d - (a.hw + (b.hw - a.hw) * t)
                        if d < best then best = d end
                    end
                end
            end
        end
    end
    return best
end

-- Calls the game's corridor functions. Returns inside(bool|nil), distance(cm|nil).
local function gameCorridor(x, y, z)
    local tm = W.live("TrailMapSubsystem")
    if not tm then return nil, nil end
    local pos = { X = x, Y = y, Z = z or 0 }
    local inside, dist
    pcall(function()
        local r = tm:IsPositionInCorridor(pos, -1)
        if type(r) == "boolean" then inside = r end
    end)
    pcall(function()
        local d = tm:GetDistanceToCorridor(pos, -1)
        d = tonumber(d)
        if d and d == d then dist = d end
    end)
    return inside, dist
end
S.gameCorridor = gameCorridor

-- Checks the game's corridor answers against the geometry at a few points, once per world.
-- Uses the trail's own centre line (must be inside) and points well outside (must be outside).
function S.calibrateCorridor(trails)
    S.corridorMode = "geometry"
    S.corridorNote = "no trails to check against"
    local tests, agree, answered = 0, 0, 0
    for _, tr in ipairs(trails) do
        local l = tr.lines[1]
        if l and not l.closed and #l.pts >= 3 then
            local p = l.pts[math.floor(#l.pts / 2) + 1]
            local z = S.height(p.x, p.y)
            local inC, dC = gameCorridor(p.x, p.y, z)
            local nx, ny = -p.ty, p.tx
            local ox, oy = p.x + nx * (p.hw + 6000), p.y + ny * (p.hw + 6000)
            local inO, dO = gameCorridor(ox, oy, S.height(ox, oy))
            tests = tests + 2
            if inC ~= nil then answered = answered + 1 end
            if inO ~= nil then answered = answered + 1 end
            local geoO = S.geoCorridorDistance(ox, oy)
            if inC == true then agree = agree + 1 end
            if inO == false or (geoO < 1000 and inO == true) then agree = agree + 1 end
            L.debug("scan", "corridor check trail %s: centre in=%s d=%s | +%.0f m in=%s d=%s (geometry %.0f m)", tostring(tr.id),
                tostring(inC), tostring(dC), (p.hw + 6000) / 100, tostring(inO), tostring(dO), geoO / 100)
            if tests >= 8 then break end
        end
    end
    if tests > 0 then
        if answered == tests and agree >= tests - 1 then
            S.corridorMode = "game"
            S.corridorNote = string.format("game corridor test agreed %d/%d", agree, tests)
        else
            S.corridorNote = string.format("game corridor test answered %d/%d, agreed %d/%d: using trail geometry", answered, tests, agree, tests)
        end
    end
    return S.corridorMode, S.corridorNote
end

-- Clearance (cm) from the skiable area: >0 outside, <=0 inside a corridor.
function S.corridorClearance(x, y, z)
    S.stats.corridor = S.stats.corridor + 1
    local geo = S.geoCorridorDistance(x, y)
    if S.corridorMode == "game" then
        local inside, d = gameCorridor(x, y, z)
        if inside == true then return -1 end
        -- the game's distance (if it is a distance) and our geometry must both say "clear"
        if d and d >= 0 then return math.min(d, geo > 0 and geo or d) end
        return geo > 0 and geo or 1   -- the game says outside; geometry only refines the distance
    end
    return geo
end

-- ------------------------------------------------------------------ placeables and paths
local function actorBounds(a)
    local o, e = {}, {}
    local s = pcall(function() a:GetActorBounds(false, o, e, false) end)
    local ox, oy, oz = tonumber(o.X), tonumber(o.Y), tonumber(o.Z)
    local ex, ey = tonumber(e.X), tonumber(e.Y)
    if s and ox and ex then return ox, oy, oz, math.sqrt(ex * ex + ey * ey) end
    return nil
end

-- Small placeables that line trails and plazas (lights, benches, terrain-park features...): decorations keep a
-- short distance from them instead of the building clearance. Lab 2026-11-21, Boha: 44 tower lights, 12 benches
-- and the park rails/kickers counted as buildings blocked most trail edges for houses. Class names seen in CL8231.
local PROP_CLASSES = { "^BP_LampPost", "^BP_TowerLight", "^BP_Park", "^BP_PicnicTable", "^BP_PropaneHeater",
    "^BP_SkiRack", "^BP_SnowSculpture", "^BP_TrashCan", "^BP_Sign" }
function S.isProp(cls)
    for _, p in ipairs(PROP_CLASSES) do if cls:match(p) then return true end end
    return false
end

-- Snapshot of solid things to keep away from. Returns layout with .obstacles = { {x,y,r,kind}, ... },
-- .segments = { {ax,ay,bx,by,r,kind}, ... } and counts.
function S.placeables()
    local lay = { obstacles = {}, segments = {}, counts = { buildings = 0, props = 0, lifts = 0, towers = 0, walkways = 0 } }
    local function addO(x, y, r, kind) if x and y then lay.obstacles[#lay.obstacles + 1] = { x = x, y = y, r = r, kind = kind } end end
    local function addS(ax, ay, bx, by, r, kind) if ax and bx then lay.segments[#lay.segments + 1] = { ax = ax, ay = ay, bx = bx, by = by, r = r, kind = kind } end end
    local reg = W.live("PlaceableRegistrySubsystem")
    if reg then
        pcall(function()
            reg.Buildings:ForEach(function(_, e)
                local a = e:get()
                if ok(a) then
                    local x, y, _, r = actorBounds(a)
                    if not x then x, y = vec(a:K2_GetActorLocation()) r = 800 end
                    local cls = ""
                    pcall(function() cls = a:GetClass():GetFName():ToString() end)
                    if S.isProp(cls) then
                        addO(x, y, math.min(r or 300, 1000), "prop")
                        lay.counts.props = lay.counts.props + 1
                    else
                        addO(x, y, math.min(r or 800, 6000), "building")
                        lay.counts.buildings = lay.counts.buildings + 1
                    end
                end
            end)
        end)
        pcall(function()
            reg.Lifts:ForEach(function(_, e)
                local a = e:get()
                if not ok(a) then return end
                lay.counts.lifts = lay.counts.lifts + 1
                local prev
                pcall(function()
                    a.Waypoints:ForEach(function(_, wp)
                        local w = wp:get()
                        local x, y = vec(w.position)
                        if x then
                            if w.bIsTerminal or w.bIsAngleStation then addO(x, y, 1500, "lift station") end
                            if prev then addS(prev[1], prev[2], x, y, 0, "lift line") end
                            prev = { x, y }
                        end
                    end)
                end)
                pcall(function()
                    a.TowerMeshComponents:ForEach(function(_, c)
                        local comp = c:get()
                        if ok(comp) then
                            local x, y = vec(comp:K2_GetComponentLocation())
                            addO(x, y, 300, "lift tower")
                            lay.counts.towers = lay.counts.towers + 1
                        end
                    end)
                end)
                if not prev then local x, y = vec(a:K2_GetActorLocation()) addO(x, y, 1500, "lift") end
            end)
        end)
    end
    -- walkways as saved in the save file the resort was opened from (paths painted later are not in it)
    pcall(function()
        local gss = W.live("GameSessionSubsystem")
        local s = gss and gss.PendingLoadSave
        if not ok(s) then return end
        s.WalkwayMapData.Runs:ForEach(function(_, e)
            local run = e:get()
            local prev
            run.Points:ForEach(function(_, p)
                local x, y = vec(p:get())
                if x then
                    if prev then addS(prev[1], prev[2], x, y, 150, "walkway") end
                    prev = { x, y }
                end
            end)
            lay.counts.walkways = lay.counts.walkways + 1
        end)
    end)
    return lay
end

-- A cheap fingerprint of everything placement depends on (trails, buildings, lifts). Rounded to 1 m.
function S.fingerprint(trails, lay)
    local parts = {}
    for _, tr in ipairs(trails) do parts[#parts + 1] = tostring(tr.sig) end
    for _, o in ipairs(lay.obstacles) do parts[#parts + 1] = string.format("%s%d,%d", o.kind:sub(1, 2), math.floor(o.x / 100), math.floor(o.y / 100)) end
    for _, s in ipairs(lay.segments) do parts[#parts + 1] = string.format("%s%d,%d", s.kind:sub(1, 2), math.floor(s.ax / 100), math.floor(s.bx / 100)) end
    table.sort(parts)
    return Rng.hash(table.concat(parts, ";")), #parts
end

return S
