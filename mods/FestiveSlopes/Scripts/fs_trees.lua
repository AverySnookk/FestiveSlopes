-- Festive Slopes: the game's own trees, which the mod decorates (it never adds trees).
--
-- Verified in game (CL8231, lab 2026-11-21):
--   * ObstacleDataManager:GetObstaclesInRadius(center, radius) returns FObstacleData { Type, Transform, ClearingCost,
--     InstanceIndex, ArtHandle } for trees in a sphere: the centre must be near the ground. (QueryObstaclesNearPosition
--     returns positions only.)
--   * ObstacleDataManager:GetMaxTreeCanopyTopZNearSegment(start, end, halfWidth, out) gives the real canopy top:
--     measured heights / instance scale came out at the art's nominal 10, 15 and 20 m.
--   * ArtHandle indexes the game's art table, which is not reflected. Its blocks match the TreeSpeciesDataAsset
--     assets sorted by name, each contributing its Art variants in order (Fir 15+, Pine 75+, Spruce 109+,
--     WhitebarkPine 127+ on Boha, with Sclerophyll apparently absent). The mapping is not hard-coded: each candidate
--     table (all species sorted by name, or one species left out) is checked against measured tree heights and the
--     best one is used; if none agrees, trees are decorated from their measured height alone.
-- Unsafe in this game (crashed it in the lab, never use): FindAllOf over (Hierarchical)InstancedStaticMeshComponent,
-- KismetProceduralMeshLibrary.GetSectionFromStaticMesh on the tree meshes.
local T = { mode = nil, note = "", tab = nil }
local W, L, S, SP

-- Evergreens worth decorating, with the share of their height that is bare trunk below the canopy (pines keep
-- their branches higher). Deciduous species, dead/dying trees and krummholz are left alone.
T.EVERGREEN = { Spruce = 0.05, Fir = 0.06, Hemlock = 0.06, Pine = 0.3, WhitebarkPine = 0.26 }
-- Tree meshes with a spreading, gnarled crown instead of a cone: a spiral of lights floats around them (user report
-- 2026-11-22). Lab: whitebark pine's own 10 m and 15 m meshes (sm_tree_whitebarkpine_*); its 20 m size uses the
-- conical SM_Pine_20m mesh and is still dressed. Matched against the lower-case mesh path.
T.SKIP_MESH = { "whitebarkpine" }
local HEALTHY = 0

function T.init(world, log, resort, spawn)
    W, L, S, SP = world, log, resort, spawn
    world.onMapChange(function() T.mode, T.tab, T.note = nil, nil, "" end)
end

local function om() return W.live("ObstacleDataManager") end

-- Trees within radius of (x, y, z): { x, y, z, s (scale), art } (z: the trunk base).
function T.near(x, y, z, radius)
    local out = {}
    local m = om()
    if not m then return out end
    pcall(function()
        local arr = m:GetObstaclesInRadius({ X = x, Y = y, Z = z }, radius)
        for i = 1, #arr do
            local e = arr[i]:get()
            local tr = e.Transform
            local p = tr.Translation
            out[#out + 1] = { x = p.X, y = p.Y, z = p.Z, s = tr.Scale3D.Z, art = e.ArtHandle, type = e.Type }
        end
    end)
    S.stats.trees = S.stats.trees + 1
    return out
end

-- Top of the canopy at a trunk (world z) or nil.
function T.top(x, y, z)
    local m = om()
    if not m then return nil end
    local res = {}
    local okT, hit = pcall(function() return m:GetMaxTreeCanopyTopZNearSegment({ X = x, Y = y, Z = z }, { X = x + 1, Y = y, Z = z }, 30, res) end)
    if not okT or not hit then return nil end
    return tonumber(res.OutMaxTopZ)
end

-- Something that changes when the player clears trees (part of the resort fingerprint). Only the cleared zones: the
-- number of obstacles also changes as the game's forest grows by itself, which re-planned the whole resort every
-- 30 s for nothing (user log 2026-11-22: three re-plans of 26 s each, all ending "0 built, 53 kept").
function T.forestSig()
    local m = om()
    if not m then return "0" end
    local b = 0
    pcall(function() b = m.ClearedZones:GetArrayNum() end)
    return tostring(b)
end

-- ------------------------------------------------------------------ art table
local function speciesList()
    local list = {}
    for _, o in ipairs(FindAllOf("TreeSpeciesDataAsset") or {}) do
        local full = ""
        pcall(function() full = o:GetFullName() end)
        local name = full:match("%.([%w_]+)$")
        if name and not full:find("Default__") then
            local arts = {}
            pcall(function()
                o.Art:ForEach(function(_, a)
                    local v = a:get()
                    local path
                    pcall(function() path = v.Mesh:GetFullName():match("%s(%S+)$") end)
                    arts[#arts + 1] = { size = tonumber(v.SizeClass) or -1, cond = tonumber(v.Condition) or -1, mesh = path }
                end)
            end)
            list[#list + 1] = { name = name, short = name:gsub("^DA_TreeSpecies_", ""), arts = arts }
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

local function buildTable(list, skip)
    local tab, h = {}, 0
    for i, sp in ipairs(list) do
        if i ~= skip then
            for _, a in ipairs(sp.arts) do
                tab[h] = { species = sp.short, size = a.size, cond = a.cond, mesh = a.mesh }
                h = h + 1
            end
        end
    end
    return tab
end

-- Works out which art table the game uses, from trees near the trails. Cheap (a few dozen queries), once per map.
function T.resolve(trails)
    if T.mode then return T.mode end
    local samples = {}
    local seen = {}
    for ti = 1, math.min(#trails, 8) do
        local line = trails[ti].lines[1]
        local pts = line and line.pts
        if pts and #pts > 2 then
            local p = pts[math.floor(#pts / 2)]
            for _, sd in ipairs({ 1, -1 }) do
                local x, y = p.x - p.ty * sd * (p.hw + 2500), p.y + p.tx * sd * (p.hw + 2500)
                local z = S.height(x, y)
                if z then
                    for _, t in ipairs(T.near(x, y, z, 2000)) do
                        local key = math.floor(t.x / 50) .. ":" .. math.floor(t.y / 50)
                        if not seen[key] and #samples < 60 then
                            seen[key] = true
                            local top = T.top(t.x, t.y, t.z)
                            if top and top > t.z + 150 then t.h = top - t.z samples[#samples + 1] = t end
                        end
                    end
                end
            end
        end
    end
    local list = speciesList()
    -- species the resort's biome grows: breaks ties between tables whose sizes line up equally well (lab: leaving out
    -- Pine or Sclerophyll, both 18 variants with the same size layout, matched the measured heights equally)
    local roster = {}
    pcall(function()
        om().CachedBiomeSettings.SpeciesRoster:ForEach(function(_, e)
            local n = e:get().Species:GetFullName():match("%.([%w_]+)$")
            if n then roster[(n:gsub("^DA_TreeSpecies_", ""))] = true end
        end)
    end)
    local best, bestScore, bestLocal, bestCover, bestSkip = nil, -1, -1, -1, nil
    for skip = 0, #list do
        local tab = buildTable(list, skip)
        -- a table that leaves out a species the biome grows cannot be the one in use
        local cover = (skip > 0 and roster[list[skip].short]) and 0 or 1
        local score, inBiome = 0, 0
        for _, t in ipairs(samples) do
            local e = tab[t.art]
            local d = e and e.mesh and SP.meshDims(e.mesh)
            if d and math.abs(d.h * t.s - t.h) <= math.max(80, t.h * 0.07) then score = score + 1 end
            if e and roster[e.species] then inBiome = inBiome + 1 end
        end
        if score > bestScore or (score == bestScore and (inBiome > bestLocal or (inBiome == bestLocal and cover > bestCover))) then
            best, bestScore, bestLocal, bestCover, bestSkip = tab, score, inBiome, cover, skip
        end
    end
    if #samples >= 12 and bestScore >= #samples * 0.8 then
        T.mode, T.tab = "mesh", best
        T.note = string.format("art table: %d species sorted by name%s; %d of %d measured trees agree, %d in the biome's roster",
            #list, bestSkip > 0 and (" without " .. list[bestSkip].short) or "", bestScore, #samples, bestLocal)
    else
        T.mode, T.tab = "height", nil
        T.note = string.format("art table not identified (best %d of %d trees agree, %d species): decorating by measured height",
            math.max(0, bestScore), #samples, #list)
    end
    return T.mode
end

-- What the mod knows about a tree: nil (leave it alone) or { species, f0, h (nominal height at scale 1), r }.
function T.info(t)
    if T.mode == "mesh" then
        local e = T.tab[t.art]
        if not e or e.cond ~= HEALTHY or not T.EVERGREEN[e.species] or not e.mesh then return nil end
        local m = e.mesh:lower()
        for _, k in ipairs(T.SKIP_MESH) do if m:find(k, 1, true) then return nil end end
        local d = SP.meshDims(e.mesh)
        if not d then return nil end
        return { species = e.species, f0 = T.EVERGREEN[e.species], h = d.h, r = d.r }
    elseif T.mode == "height" then
        if t.type ~= 0 then return nil end          -- (0 = tree in every sample seen)
        return { species = "?", f0 = 0.08 }
    end
    return nil
end

-- Measures one tree for decorating: H (base to canopy top) and R (widest canopy radius), or nil.
function T.measure(t, info)
    local top = T.top(t.x, t.y, t.z)
    local H = top and (top - t.z)
    if info.h then
        local expect = info.h * t.s
        -- a neighbour's taller canopy can answer the top query: trust the mesh then
        if not H or math.abs(H - expect) > expect * 0.15 then H = expect end
        return H, info.r * t.s
    end
    if not H or H < 400 or H > 3000 then return nil end
    return H, H * 0.3
end

return T
