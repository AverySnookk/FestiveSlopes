-- Festive Slopes: where decorations go.
-- 1. trails from the game (fs_resort.trails), each resampled every 4 m with its corridor half width and direction
-- 2. a deterministic share of trails is picked for the chosen density (some always stay natural)
-- 3. along each picked trail, stretches are laid out on the trail EDGE (corridor edge + offset, either side;
--    bowl trails use their outline), with the trail's own random stream (same resort + same trail = same result)
-- 4. at each stretch the nearest healthy evergreens of the game's own forest are dressed with lights (fs_trees;
--    the mod adds no trees), and so are a few trees around every building
-- 5. gingerbread house spots are validated: outside every skiable corridor (game test), terrain height + slope,
--    footprint flatness, natural trees, buildings, lift stations/towers/cable lines, saved walkways, spacing
-- 6. the result is capped to max_decorations and grouped in chunks (one mesh actor each)
local Rng = require("fs_rng")
local P = {}
local S, L, Decor, Trees

function P.init(resort, log, decor, trees) S, L, Decor, Trees = resort, log, decor, trees end

-- share: of eligible trails decorated (one always stays natural); spacing: cm between decorated stretches of a trail
-- edge; per: game trees dressed per stretch; bld: trees dressed around each building; house: chance of a
-- gingerbread house per stretch; both: chance both sides of a trail get a stretch; village: chance of two houses.
-- Lab 2026-11-22 (user: "they should be more dense"): every level roughly doubled; moderate dresses about three times
-- as many trees as in 0.1.1. hspacing: the stretch spacing the house chance is meant for (0.1.1's spacing), so the
-- number of houses per metre of trail stays as it was (each house try searches its whole trail edge: with the house
-- chance per stretch unchanged, planning took 26 s instead of 8 on Palisades Tahoe).
P.PROFILES = {
    light      = { share = 0.60, spacing = 4500, hspacing = 7000, per = { 1, 2 }, bld = 2, house = 0.00, both = 0.40, village = 0.0 },
    moderate   = { share = 0.90, spacing = 2200, hspacing = 4000, per = { 2, 3 }, bld = 3, house = 0.12, both = 0.80, village = 0.0 },
    festive    = { share = 1.00, spacing = 1500, hspacing = 2600, per = { 3, 4 }, bld = 5, house = 0.20, both = 1.00, village = 0.25 },
    wonderland = { share = 1.00, spacing = 1000, hspacing = 1600, per = { 3, 5 }, bld = 7, house = 0.28, both = 1.00, village = 0.40, showcase = 2 },
}

P.REV = 10                   -- bump when placement results change for the same inputs (invalidates caches)
local HOUSE_STEP = 1500        -- spacing of the house-spot grid along a trail edge
local HOUSE_EDGE = 1300        -- house spots start this far beyond the edge offset (+ depth)
local PICK_R = 2200            -- radius searched for a game tree to dress around a trail-edge spot
local CHUNK = 15000          -- cm of trail per mesh actor (smaller groups = smaller engine calls)
local END_MARGIN = 2500      -- keep the first/last 25 m of a trail free (lift stations, base areas)

-- ------------------------------------------------------------------ spatial grid for spacing
local function grid(cell)
    local g = { cell = cell, c = {} }
    function g:add(o)
        local k = math.floor(o.x / cell) .. ":" .. math.floor(o.y / cell)
        local b = self.c[k]
        if not b then b = {} self.c[k] = b end
        b[#b + 1] = o
    end
    function g:near(x, y, r, fn)
        local x0, x1 = math.floor((x - r) / cell), math.floor((x + r) / cell)
        local y0, y1 = math.floor((y - r) / cell), math.floor((y + r) / cell)
        for i = x0, x1 do for j = y0, y1 do
            local b = self.c[i .. ":" .. j]
            if b then for _, o in ipairs(b) do if fn(o) == false then return false end end end
        end end
        return true
    end
    return g
end

-- point at arc length s on a sampled line (wraps for closed outlines)
local function at(line, s)
    local pts = line.pts
    if line.closed then s = s % line.length end
    if s <= pts[1].s then return pts[1] end
    local lo, hi = 1, #pts
    while hi - lo > 1 do
        local m = math.floor((lo + hi) / 2)
        if pts[m].s <= s then lo = m else hi = m end
    end
    local a, b = pts[lo], pts[hi]
    local f = (b.s > a.s) and (s - a.s) / (b.s - a.s) or 0
    if f > 1 then f = 1 end
    local tx, ty = a.tx + (b.tx - a.tx) * f, a.ty + (b.ty - a.ty) * f
    local tl = math.sqrt(tx * tx + ty * ty)
    if tl < 1e-6 then tx, ty, tl = a.tx, a.ty, 1 end
    return { x = a.x + (b.x - a.x) * f, y = a.y + (b.y - a.y) * f, hw = a.hw + (b.hw - a.hw) * f, tx = tx / tl, ty = ty / tl, s = s }
end
P.at = at

-- ------------------------------------------------------------------ validation
-- Returns z (and slope) or nil, reason. kind = "tree" | "house". r = footprint radius (cm).
-- rc: core footprint radius (houses: the building without its fence/path), used for the ground and tree checks.
-- spacing to decorations already accepted
local function spacingOk(ctx, kind, x, y, r)
    return ctx.grid:near(x, y, r + 2600, function(o)
        local d = math.sqrt((o.x - x) ^ 2 + (o.y - y) ^ 2)
        local need = r + o.r + ((kind == "house" and o.kind == "house") and 900 or 150)
        if d < need then return false end
    end)
end

local function validate(ctx, kind, x, y, r, yaw, rc, noSpacing)
    rc = rc or r
    local cfg = ctx.cfg
    local st = ctx.stats
    if not noSpacing and not spacingOk(ctx, kind, x, y, r) then return nil, "spacing" end
    -- buildings, lift stations, towers, cable lines, walkways
    local lay = ctx.layout
    local bc = cfg.building_clearance_m * 100 + (kind == "house" and 500 or 0)
    local lc = cfg.lift_clearance_m * 100
    for _, o in ipairs(lay.obstacles) do
        local need
        if o.kind == "building" then need = bc + o.r + r
        elseif o.kind == "lift tower" then need = 600 + r
        elseif o.kind == "prop" then need = 400 + o.r + r
        else need = lc + o.r + r end
        if math.abs(o.x - x) < need and math.abs(o.y - y) < need then
            if (o.x - x) ^ 2 + (o.y - y) ^ 2 < need * need then return nil, o.kind end
        end
    end
    for _, sgm in ipairs(lay.segments) do
        local need = (sgm.kind == "lift line") and (700 + r) or (cfg.walkway_clearance_m * 100 + sgm.r + r)
        local minx, maxx = math.min(sgm.ax, sgm.bx) - need, math.max(sgm.ax, sgm.bx) + need
        local miny, maxy = math.min(sgm.ay, sgm.by) - need, math.max(sgm.ay, sgm.by) + need
        if x > minx and x < maxx and y > miny and y < maxy then
            if S.segDist(x, y, sgm.ax, sgm.ay, sgm.bx, sgm.by) < need then return nil, sgm.kind end
        end
    end
    -- terrain
    local z = S.height(x, y)
    if not z then return nil, "no terrain" end
    local slope = S.slope(x, y) or 0
    local maxSlope = (kind == "house") and cfg.max_house_slope_deg or 32
    if slope > maxSlope then return nil, "steep" end
    -- skiable area (all trails, including the one we are decorating): game corridor test + geometry
    local clr = S.corridorClearance(x, y, z)
    if clr < r + (kind == "house" and 300 or 120) then return nil, "on a trail" end
    -- natural trees / rocks
    -- (a tree may stand next to the forest, canopies touching, but not inside it)
    -- houses keep clear of canopies, not just trunks (lab 2026-11-21: a house 1.5 m from trunks was hidden under
    -- the crowns of the game's 10-12 m conifers, whose canopy reaches ~3-4 m out)
    local trees = S.treesNear(x, y, z, (kind == "house") and (rc + 450) or (r * 0.55 + 100))
    if trees > 0 then return nil, "trees" end
    -- footprint flatness for houses (corners of the rotated footprint)
    if kind == "house" then
        local lo, hi = z, z
        local a = math.rad(yaw or 0)
        local c, s = math.cos(a), math.sin(a)
        for _, q in ipairs({ { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }) do
            local lx, ly = q[1] * rc * 0.8, q[2] * rc * 0.8
            local h = S.height(x + lx * c - ly * s, y + lx * s + ly * c)
            if not h then return nil, "no terrain" end
            if h < lo then lo = h end
            if h > hi then hi = h end
        end
        if hi - lo > 250 then return nil, "uneven ground" end   -- the body reaches ~2 m into the ground
    end
    st.ok = st.ok + 1
    return z, slope
end
P.validate = validate

-- ------------------------------------------------------------------ trail selection
function P.selectTrails(trails, seed, prof, cfg)
    local eligible = {}
    for _, tr in ipairs(trails) do
        if tr.length >= cfg.min_trail_length_m * 100 then
            tr.score = Rng.hash(seed, "pick", tr.sig) / 2147483647
            eligible[#eligible + 1] = tr
        end
    end
    table.sort(eligible, function(a, b) return a.score < b.score end)
    local chosen = {}
    for _, tr in ipairs(eligible) do if tr.score < prof.share then chosen[#chosen + 1] = tr end end
    if #chosen == 0 and #eligible > 0 then chosen[1] = eligible[1] end
    if #eligible >= 2 and #chosen >= #eligible then chosen[#chosen] = nil end   -- one trail always stays natural
    for i, tr in ipairs(chosen) do tr.showcase = prof.showcase and i <= prof.showcase or false end
    return chosen, #eligible
end

-- ------------------------------------------------------------------ generation, in three steps
-- UE4SS game calls do not work from inside Lua coroutines, so the work is split into explicit steps that the
-- manager runs a few milliseconds at a time:
--   P.plan(ctx)                  pure Lua: picks trails and lays out every candidate (all random numbers drawn here)
--   P.runTasks(ctx, i, deadline) validates candidates in order with the game; returns the next task index
--   P.finish(ctx)                caps the result to max_decorations
-- Tasks are always processed in the same order, so the result is the same however many ticks it takes.
function P.plan(ctx)
    local cfg = ctx.cfg
    local prof = P.PROFILES[cfg.density]
    ctx.out = {}
    ctx.tasks = {}
    ctx.spots = {}
    ctx.grid = grid(3000)
    ctx.stats = { tried = 0, ok = 0, why = {} }
    if not prof then ctx.chosen, ctx.eligible = {}, 0 return ctx.tasks end
    local chosen, nEligible = P.selectTrails(ctx.trails, ctx.seed, prof, cfg)
    ctx.chosen, ctx.eligible = chosen, nEligible
    local tf, hf = cfg.tree_frequency, cfg.house_frequency
    local houseP = math.min(0.8, prof.house * hf)
    local spacing = prof.spacing / math.sqrt(math.max(0.25, tf > 0 and tf or 1))
    local edge = cfg.trail_edge_offset_m * 100
    local tasks = ctx.tasks
    for _, tr in ipairs(chosen) do
        local rng = Rng.new(Rng.hash(ctx.seed, "trail", tr.sig))
        tr.placed = 0
        local sp = tr.showcase and spacing * 0.6 or spacing
        for li, line in ipairs(tr.lines) do
            line.idx = li
            local len = line.length
            local s = END_MARGIN + rng:range(0, sp)
            local stop = line.closed and len or (len - END_MARGIN)
            while s < stop do
                local sides
                if line.closed then sides = { 0 }
                else
                    local first = rng:sign()
                    sides = (tr.showcase or rng:chance(prof.both)) and { first, -first } or { first }
                end
                for _, side in ipairs(sides) do
                    local sc = s + rng:range(-500, 500)
                    -- outward normal: left/right of travel, or away from the bowl centre
                    local function edgePoint(ds, off)
                        local p = at(line, sc + ds)
                        local mx, my = -p.ty, p.tx
                        if line.closed then
                            if (p.x - line.cx) * mx + (p.y - line.cy) * my < 0 then mx, my = -mx, -my end
                        else mx, my = mx * side, my * side end
                        return p.x + mx * (p.hw + off), p.y + my * (p.hw + off), mx, my
                    end
                    local function group(ds) return string.format("t%d_%d_%d", tr.sig, li, math.floor((sc + ds) / CHUNK)) end
                    -- gingerbread house (faces the trail), maybe a small village of two
                    local plannedHouses = 0
                    if houseP > 0 and rng:chance(math.min(0.8, houseP * sp / (prof.hspacing or sp))) then
                        local nH = (rng:chance(prof.village or 0)) and 2 or 1
                        for hI = 1, nH do
                            local look = Decor.rollHouse(rng, cfg)
                            local r = Decor.houseRadius(look)
                            local ds = (hI == 1) and 0 or rng:sign() * (r * 2 + 600)
                            -- House spots lie on a fixed grid along each edge (every 15 m, three depths, independent of
                            -- the house) so validation results are shared by all houses of a trail edge; the whole edge is
                            -- searched, nearest to the rolled spot first, and the first valid spot wins. Lab 2026-11-21:
                            -- only ~7% of edge spots beside the game's forests are flat and clear of canopies, so a search
                            -- near the rolled spot rarely found one, and an unshared whole-edge search was too slow.
                            -- (the candidate list is made when the task runs: building every house's list here took
                            -- 196 ms in one tick at wonderland; it draws no random numbers, so the result is the same)
                            local function makeCands()
                                local cands = {}
                                local gLo = line.closed and 0 or math.ceil(END_MARGIN / HOUSE_STEP)
                                local gHi = line.closed and (math.floor(len / HOUSE_STEP) - 1) or math.floor((len - END_MARGIN) / HOUSE_STEP)
                                local g0 = math.floor((sc + ds) / HOUSE_STEP + 0.5)
                                local grid = {}
                                for g = gLo, gHi do grid[#grid + 1] = g end
                                table.sort(grid, function(g1, g2)
                                    local d1, d2 = math.abs(g1 - g0), math.abs(g2 - g0)
                                    if line.closed then d1, d2 = math.min(d1, #grid - d1), math.min(d2, #grid - d2) end
                                    if d1 ~= d2 then return d1 < d2 end
                                    return g1 < g2
                                end)
                                for _, g in ipairs(grid) do
                                    local dsG = g * HOUSE_STEP - sc
                                    for di, depth in ipairs({ 200, 900, 1700 }) do
                                        local x, y, mx, my = edgePoint(dsG, edge + HOUSE_EDGE + depth)
                                        cands[#cands + 1] = { x = x, y = y, yaw = math.deg(math.atan(-my, -mx)), group = group(dsG),
                                            key = string.format("%d:%d:%d:%d:%d", tr.sig, li, side, g, di) }
                                    end
                                end
                                return cands
                            end
                            tasks[#tasks + 1] = { kind = "house", look = look, r = r, rc = Decor.houseCore(look), make = makeCands, group = group(ds), trail = tr }
                            plannedHouses = plannedHouses + 1
                        end
                    end
                    -- dress the game's own trees at the edge of this stretch
                    if tf > 0 then
                        local n = rng:int(prof.per[1], prof.per[2])
                        n = math.max(1, math.floor(n * math.sqrt(tf) + 0.5))
                        if tr.showcase then n = n + 1 end
                        local looks = {}
                        for k = 1, n do looks[k] = Decor.rollLights(rng, cfg) end
                        local x, y, mx, my = edgePoint(0, edge + 600)
                        tasks[#tasks + 1] = { kind = "pick", x = x, y = y, nx = mx, ny = my, looks = looks, group = group(0),
                            trail = tr, radius = PICK_R }
                    end
                end
                s = s + sp * rng:range(0.7, 1.3)
            end
        end
    end
    -- dressed trees around buildings (lodges, huts, shops): the village gets festive too
    if tf > 0 and prof.bld > 0 then
        for bi, o in ipairs(ctx.layout.obstacles) do
            if o.kind == "building" then
                local rng = Rng.new(Rng.hash(ctx.seed, "bld", math.floor(o.x), math.floor(o.y)))
                local n = math.max(1, math.floor(prof.bld * math.sqrt(tf) + 0.5))
                local looks = {}
                for k = 1, n do looks[k] = Decor.rollLights(rng, cfg) end
                tasks[#tasks + 1] = { kind = "pick", x = o.x, y = o.y, looks = looks, group = string.format("b%d", math.floor(o.x / 20000) * 1000 + math.floor(o.y / 20000)),
                    radius = o.r + 3000, minD = o.r + 400, building = true }
            end
        end
    end
    -- Houses first: they need the rare open, flat spots, which trees would otherwise take. Lab 2026-11-21: with trees
    -- validated first, Wonderland placed 349 trees and 1 house (2048 house rejections for spacing).
    local ordered = {}
    for _, t in ipairs(tasks) do if t.kind == "house" then ordered[#ordered + 1] = t end end
    for _, t in ipairs(tasks) do if t.kind ~= "house" then ordered[#ordered + 1] = t end end
    ctx.tasks = ordered
    return ordered
end

-- Of a task's valid candidates, the most open one wins (fewest natural trees within 12 m, then the gentlest
-- slope): decorations end up in clearings and open snow beside the trail, where the play camera can see them,
-- instead of half hidden in the forest. A candidate with no tree around at all is taken at once.
function P.runTasks(ctx, i, deadline)
    local tasks = ctx.tasks
    local st = ctx.stats
    while i <= #tasks do
        local t = tasks[i]
        if t.kind == "pick" then
            P.runPick(ctx, t)
            i = i + 1
            if os.clock() > deadline then break end
        else
        local first = (t.kind == "house")            -- houses: candidates are ordered by preference, first valid wins
        if t.make then t.cands, t.make = t.make(), nil end
        t.ci = t.ci or 1
        while t.ci <= #t.cands do
            local c = t.cands[t.ci]
            t.ci = t.ci + 1
            st.tried = st.tried + 1
            local z, why
            if c.key then
                -- shared spot result: reuse a pass checked for a house at least this big, or a failure for one no bigger
                local e = ctx.spots[c.key]
                if e and ((e.z and e.r >= t.r) or (not e.z and e.r <= t.r)) then z, why = e.z, e.why
                else
                    z, why = validate(ctx, t.kind, c.x, c.y, t.r, c.yaw, t.rc, true)
                    ctx.spots[c.key] = { z = z, why = why, r = t.r }
                end
                if z and not spacingOk(ctx, t.kind, c.x, c.y, t.r) then z, why = nil, "spacing" end
            else
                z, why = validate(ctx, t.kind, c.x, c.y, t.r, c.yaw, t.rc)
            end
            if z then
                local open = first and 0 or S.treesNear(c.x, c.y, z, t.r + 1200)
                local score = open + (why or 0) / 10          -- (why = slope on success)
                if not t.best or score < t.best.score then t.best = { c = c, z = z, score = score } end
                if open == 0 then break end
            else
                local k = t.kind .. ": " .. why
                st.why[k] = (st.why[k] or 0) + 1
            end
            if os.clock() > deadline and t.ci <= #t.cands then return i end      -- resume this task next tick
        end
        if t.best then
            local c = t.best.c
            local o = { kind = t.kind, x = c.x, y = c.y, z = t.best.z, yaw = c.yaw, look = t.look, r = t.r, group = c.group or t.group }
            ctx.out[#ctx.out + 1] = o
            ctx.grid:add(o)
            if t.kind == "tree" then t.trail.placed = (t.trail.placed or 0) + 1 end
        elseif first then
            st.why["house: no valid spot on this trail"] = (st.why["house: no valid spot on this trail"] or 0) + 1
        end
        i = i + 1
        if os.clock() > deadline then break end
        end
    end
    return i
end

-- Dresses up to #t.looks of the game's trees near (t.x, t.y): healthy evergreens, trunk off the trails, not too close
-- to an already dressed tree; nearest to the spot first (trees at the edge of the forest, where they are seen).
local TREE_GAP = 400            -- cm between the canopies of two dressed trees (0.1.1: 700)
function P.runPick(ctx, t)
    local st = ctx.stats
    local z = S.height(t.x, t.y)
    if not z then return end
    local cands = Trees.near(t.x, t.y, z, t.radius)
    for _, c in ipairs(cands) do c.d = (c.x - t.x) ^ 2 + (c.y - t.y) ^ 2 end
    table.sort(cands, function(a, b) return a.d < b.d end)
    local k = 0
    for _, c in ipairs(cands) do
        if k >= #t.looks then break end
        st.tried = st.tried + 1
        local why
        local info = Trees.info(c)
        if not info then why = "not an evergreen to dress"
        elseif t.minD and c.d < t.minD * t.minD then why = "against a building"
        end
        local H, R
        if not why then
            -- spacing first (Lua only), then the game queries
            local rGuess = (info.r and info.r * c.s) or 300
            local free = ctx.grid:near(c.x, c.y, rGuess + 2600, function(o)
                if o.kind == "tree" and math.sqrt((o.x - c.x) ^ 2 + (o.y - c.y) ^ 2) < rGuess + o.r + TREE_GAP then return false end
            end)
            if not free then why = "next to a dressed tree"
            elseif S.corridorClearance(c.x, c.y, c.z) < 150 then why = "on a trail"
            else
                H, R = Trees.measure(c, info)
                if not H then why = "could not measure" end
            end
        end
        if why then
            local key = "tree: " .. why
            st.why[key] = (st.why[key] or 0) + 1
        else
            k = k + 1
            local look = {}
            for kk, v in pairs(t.looks[k]) do look[kk] = v end
            look.H, look.R, look.f0 = math.floor(H + 0.5), math.floor(R + 0.5), info.f0
            -- gifts go on the open side: toward the trail (or the building)
            local gx, gy
            if t.nx then gx, gy = -t.nx, -t.ny else gx, gy = t.x - c.x, t.y - c.y end
            look.gy = math.floor(math.deg(math.atan(gy, gx)) + 0.5)
            local o = { kind = "tree", x = c.x, y = c.y, z = c.z, yaw = 0, r = R, look = look, group = t.group }
            ctx.out[#ctx.out + 1] = o
            ctx.grid:add(o)
            if t.trail then t.trail.placed = (t.trail.placed or 0) + 1 end
        end
    end
end

function P.finish(ctx)
    local out = ctx.out
    local cap = ctx.cfg.max_decorations
    if #out > cap then
        for _, o in ipairs(out) do o.keep = (o.kind == "house" and 0 or 1) + Rng.hash(ctx.seed, "cap", o.x, o.y) / 2147483647 end
        table.sort(out, function(a, b) return a.keep < b.keep end)
        for i = #out, cap + 1, -1 do out[i] = nil end
        ctx.stats.capped = true
    end
    for _, o in ipairs(out) do o.keep = nil end
    return out
end

-- ------------------------------------------------------------------ cache (one file per resort seed)
local function ser(v)
    if type(v) == "number" then return string.format("%.4f", v):gsub("%.?0+$", "") end
    if type(v) == "boolean" then return v and "T" or "F" end
    return (tostring(v):gsub("[%s=;|]", "_"))
end
local function deser(s)
    if s == "T" then return true elseif s == "F" then return false end
    local n = tonumber(s)
    if n then return n end
    return s
end

function P.saveCache(path, key, list)
    local f = io.open(path, "w")
    if not f then return false end
    f:write("key=", key, "\n")
    for _, o in ipairs(list) do
        local parts = { o.kind, ser(o.x), ser(o.y), ser(o.z), ser(o.yaw), ser(o.r), o.group }
        local lk = {}
        for k, v in pairs(o.look) do lk[#lk + 1] = k .. "=" .. ser(v) end
        table.sort(lk)
        parts[#parts + 1] = table.concat(lk, ";")
        f:write(table.concat(parts, "|"), "\n")
    end
    f:close()
    return true
end

function P.loadCache(path, key)
    local f = io.open(path, "r")
    if not f then return nil end
    local head = f:read("l")
    if head ~= "key=" .. key then f:close() return nil end
    local list = {}
    for line in f:lines() do
        local p = {}
        for part in (line .. "|"):gmatch("([^|]*)|") do p[#p + 1] = part end
        if #p >= 8 then
            local look = {}
            for kv in p[8]:gmatch("[^;]+") do
                local k, v = kv:match("^([^=]+)=(.*)$")
                if k then look[k] = deser(v) end
            end
            list[#list + 1] = { kind = p[1], x = tonumber(p[2]), y = tonumber(p[3]), z = tonumber(p[4]), yaw = tonumber(p[5]),
                r = tonumber(p[6]), group = p[7], look = look }
        end
    end
    f:close()
    return list
end

return P
