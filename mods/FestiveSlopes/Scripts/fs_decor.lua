-- Festive Slopes: the decoration designs (lights for the game's own trees, gingerbread houses, candy canes, gifts).
-- Each design writes flat-shaded low-poly geometry into a builder (fs_mesh) using material keys. Solid keys use
-- the game's own coloured prop materials (the non-"Snowless" ones put snow on upward faces by themselves); "g_" keys
-- are glowing (unlit, coloured) and go into a separate mesh that casts no shadow.
-- Design space: cm, X forward (houses face +X), Y right, Z up, origin on the ground at the decoration's centre.
local D = {}

local B = "/Game/Materials/Basic/"
D.SOLID = {
    -- (the non-Snowless materials turn white below the game's current snow depth: decorations use Snowless ones)
    ginger    = B .. "MI_Prop_Amber_Snowless.MI_Prop_Amber_Snowless",
    ginger2   = B .. "MI_Prop_DarkAmber_Shiny_Snowless.MI_Prop_DarkAmber_Shiny_Snowless",
    choc      = B .. "MI_Prop_Chocolate.MI_Prop_Chocolate",                     -- roofs: snow on top faces
    choc_s    = B .. "MI_Prop_Chocolate_Snowless.MI_Prop_Chocolate_Snowless",
    icing     = B .. "MI_Prop_White_Snowless.MI_Prop_White_Snowless",
    snow      = B .. "MI_Prop_White.MI_Prop_White",
    red       = B .. "MI_Prop_Red_Snowless.MI_Prop_Red_Snowless",
    pink      = B .. "MI_Prop_Pink_Shiny_Snowless.MI_Prop_Pink_Shiny_Snowless",
    green     = B .. "MI_Prop_Green_Snowless.MI_Prop_Green_Snowless",
    yellow    = B .. "MI_Prop_Yellow_Snowless.MI_Prop_Yellow_Snowless",
    violet    = B .. "MI_Prop_Violet_Snowless.MI_Prop_Violet_Snowless",
    orange    = B .. "MI_Prop_Orange_Shiny_Snowless.MI_Prop_Orange_Shiny_Snowless",
    blue      = B .. "MI_Prop_Blue_Snowless.MI_Prop_Blue_Snowless",
    burgundy  = B .. "MI_Prop_Burgundy_Shiny_Snowless.MI_Prop_Burgundy_Shiny_Snowless",
    brick     = B .. "MI_Prop_Brick_Snowless.MI_Prop_Brick_Snowless",
    gold      = "/Game/Materials/Metals/MI_Prop_Gold_Snowless.MI_Prop_Gold_Snowless",
}
-- glowing colours (linear RGB, multiplied by light_brightness); base material in fs_spawn
D.GLOW = {
    g_red    = { 1.0, 0.06, 0.04 },
    g_green  = { 0.08, 1.0, 0.18 },
    g_blue   = { 0.12, 0.32, 1.0 },
    g_gold   = { 1.0, 0.68, 0.12 },
    g_pink   = { 1.0, 0.22, 0.6 },
    g_warm   = { 1.0, 0.8, 0.5 },
    g_window = { 1.0, 0.56, 0.18 },
    g_star   = { 1.0, 0.86, 0.32 },
}
function D.isGlow(key) return key:sub(1, 2) == "g_" end

local MULTI = { "g_red", "g_green", "g_blue", "g_gold", "g_pink" }
local GUMDROPS = { "pink", "green", "yellow", "violet", "orange", "red" }
local GIFTS = { "red", "blue", "green", "gold", "violet", "pink" }

local cos, sin, pi, rad = math.cos, math.sin, math.pi, math.rad
local GOLDEN = pi * (3 - math.sqrt(5))

-- ------------------------------------------------------------------ decorating one of the game's own trees
-- The mod adds no trees (user feedback 2026-11-21): it dresses trees the game already placed. t (the "look", kept
-- in the placement cache) describes the real tree, measured in game (fs_trees):
--   H  height from the trunk base to the top of the canopy (cm, the game's canopy-top query)
--   R  canopy radius where it is widest (cm, the tree mesh's bounds at the tree's scale)
--   f0 share of the height below the canopy (bare trunk; pines have more)
-- and the decoration choices (lights, star, ornaments, gifts, seed). The builder is placed at the trunk base.
-- Lights sit slightly inside the canopy's outline so they rest on the branch tips instead of floating beside them.
D.LIGHT_IN = 0.84          -- share of the canopy radius where lights sit (tuned on screenshots of the game's trees)

function D.rollLights(rng, cfg)
    local t = {}
    local r = rng:float()
    if not cfg.holiday_lighting then t.lights = "none"
    elseif r < 0.6 then t.lights = "multi"
    elseif r < 0.9 then t.lights = "warm"
    else t.lights = "none" end
    t.orn = (t.lights == "none") or rng:chance(0.45)
    t.star = rng:chance(0.55)
    t.gifts = rng:chance(0.3) and rng:int(2, 3) or 0
    t.phase = rng:range(0, 2 * pi)
    t.seed = rng:int(1, 2147483000)
    return t
end

-- canopy radius at height z (cm) of a measured tree (a cone from the crown base to the top)
local function canopyR(t, z)
    local zb = t.H * t.f0
    if z <= zb then return t.R end
    return t.R * math.max(0, (t.H - z) / math.max(1, t.H - zb))
end

-- ground(lx, ly) -> local z of the ground (gifts); giftYaw: direction (deg, local) of the open side (the trail)
function D.drawLights(b, t, ground, giftYaw, Rng)
    local rng = Rng.new(t.seed)
    local H, R = t.H, t.R
    local bulbR = math.max(10, math.min(18, H * 0.011))
    local zLo = H * math.max(t.f0 + 0.04, 0.14)
    local zHi = H * 0.9
    if t.lights ~= "none" then
        -- one string spiralling up the canopy, a bulb every `gap` cm along it
        local turns = 2.6 + H / 900
        local gap = 34 * math.sqrt(H / 1000)
        local steps = math.floor(turns * 48)
        local lastX, lastY, lastZ
        local acc, n = gap, 0
        for i = 0, steps do
            local u = i / steps
            local z = zLo + (zHi - zLo) * u
            local rr = canopyR(t, z) * D.LIGHT_IN
            local a = t.phase + u * turns * 2 * pi
            local x, y = cos(a) * rr, sin(a) * rr
            if lastX then acc = acc + math.sqrt((x - lastX) ^ 2 + (y - lastY) ^ 2 + (z - lastZ) ^ 2) end
            lastX, lastY, lastZ = x, y, z
            if acc >= gap then
                acc = 0
                n = n + 1
                local key = (t.lights == "multi") and MULTI[(n - 1) % #MULTI + 1] or "g_warm"
                b:gem(key, { x, y, z - bulbR * 0.4 }, bulbR, bulbR * 1.3)
            end
        end
    end
    if t.orn then
        local n = math.floor(4 + H / 160)
        for _ = 1, n do
            local z = zLo + (zHi - zLo) * rng:float() * 0.9
            local rr = canopyR(t, z) * (D.LIGHT_IN + 0.04)
            local a = rng:range(0, 2 * pi)
            local orn = bulbR * 1.5
            b:gem(rng:pick({ "red", "gold", "burgundy", "blue", "icing" }), { cos(a) * rr, sin(a) * rr, z - orn }, orn, orn * 1.1)
        end
    end
    if t.star then
        local sR = math.max(30, H * 0.045)
        local c = { 0, 0, H + sR * 0.35 }
        local yaw = math.deg(t.phase)
        b:star("gold", c, sR, sR * 0.45, sR * 0.28, yaw)
        b:star("gold", c, sR, sR * 0.45, sR * 0.28, yaw + 90)
        if t.lights ~= "none" then b:gem("g_star", c, sR * 0.6, sR * 0.5) end
    end
    for i = 1, (t.gifts or 0) do
        -- on the open (trail) side, just outside the canopy so they are not hidden under the branches
        local a = rad(giftYaw or 0) + (i - (t.gifts + 1) / 2) * 0.45
        local d = R * 1.05 + 40
        local sz = rng:range(30, 44)
        local cx, cy = cos(a) * d, sin(a) * d
        local gz = ground and ground(cx, cy) or 0
        local col = rng:pick(GIFTS)
        local cz = gz + sz * 0.45 - 4            -- (box takes half extents; sunk a little into the snow)
        b:box(col, cx, cy, cz, sz * 0.5, sz * 0.5, sz * 0.45, math.deg(a))
        local rib = (col == "gold") and "red" or "icing"
        b:box(rib, cx, cy, cz, sz * 0.52, sz * 0.08, sz * 0.47, math.deg(a))
        b:box(rib, cx, cy, cz, sz * 0.08, sz * 0.52, sz * 0.47, math.deg(a))
    end
end

-- ------------------------------------------------------------------ candy cane
-- A striped cane standing at local (x, y, z), hook pointing toward yawDeg.
function D.drawCane(b, x, y, z, height, yawDeg, glow)
    local r = height * 0.045
    local a = rad(yawDeg or 0)
    local dx, dy = cos(a), sin(a)
    local pts = {}
    local shaft = height * 0.78
    local segs = 8
    for i = 0, segs do pts[#pts + 1] = { x, y, z - 10 + (shaft + 10) * i / segs } end
    -- hook: half circle over the top
    local hr = height * 0.13
    local cx, cy, cz = x + dx * hr, y + dy * hr, z + shaft
    for i = 1, 6 do
        local t = pi - i * pi / 6
        pts[#pts + 1] = { cx + dx * hr * cos(t), cy + dy * hr * cos(t), cz + hr * sin(t) }
    end
    pts[#pts + 1] = { cx + dx * hr, cy + dy * hr, cz - hr * 0.4 }
    b:pipe({ "red", "icing" }, pts, r, 6)
    if glow then b:gem("g_red", { x, y, z + shaft * 0.5 }, r * 0.6) end
end

-- ------------------------------------------------------------------ gingerbread house
function D.rollHouse(rng, cfg)
    local h = {}
    h.scale = rng:range(1.3, 1.7)       -- readable from the play camera, about a small cabin
    h.w = rng:range(330, 420)          -- depth (X, front to back)
    h.l = rng:range(420, 560)          -- width (Y, along the ridge)
    h.wallH = rng:range(230, 290)
    h.pitch = rng:range(36, 46)
    h.walls = rng:chance(0.7) and "ginger" or "ginger2"
    local r = rng:float()
    h.roof = (r < 0.55) and "choc" or ((r < 0.85) and "snow" or "pink")
    h.chimney = rng:chance(0.6)
    h.fence = rng:chance(0.45)
    h.path = rng:chance(0.6)
    h.lights = cfg.holiday_lighting and rng:chance(0.75)
    h.sideWindows = rng:int(1, 2)
    h.seed = rng:int(1, 2147483000)
    return h
end

-- Footprint radius (cm) including fence and path (spacing to other decorations, trails, buildings).
function D.houseRadius(h)
    local fence = h.fence and 170 or 0
    return (math.max(h.w, h.l) / 2 + 60 + fence) * h.scale
end
-- The house itself (ground flatness and natural trees).
function D.houseCore(h)
    return (math.max(h.w, h.l) / 2 + 40) * h.scale
end

-- ground(lx, ly) -> local z of the terrain (design space, before scale) or nil
function D.drawHouse(b, h, ground, Rng)
    local rng = Rng.new(h.seed)
    local W, Lh, WH = h.w / 2, h.l / 2, h.wallH
    local p = rad(h.pitch)
    local ridgeZ = WH + W * math.tan(p)
    local function gz(x, y) return (ground and ground(x, y)) or 0 end
    local walls = h.walls
    -- body (goes into the ground so slopes don't show a gap)
    b:obox(walls, { 0, 0, (WH - 120) / 2 }, { W, 0, 0 }, { 0, Lh, 0 }, { 0, 0, (WH + 120) / 2 })
    -- gables (triangles at +-Y)
    for _, sy in ipairs({ -1, 1 }) do
        b:tri(walls, { -W, sy * Lh, WH }, { W, sy * Lh, WH }, { 0, sy * Lh, ridgeZ }, { 0, sy, 0 })
    end
    -- roof slabs + snow/frosting layer, icing along the eaves and rakes
    local oh, th = 45, 26
    local roofKey = (h.roof == "snow") and "snow" or ((h.roof == "pink") and "pink" or "choc")
    for _, sx in ipairs({ -1, 1 }) do
        local dx, dz = sx * math.cos(p), -math.sin(p)                     -- ridge -> eave direction
        local nx, nz = sx * math.sin(p), math.cos(p)                       -- slab normal (up/out)
        local len = (W + oh) / math.cos(p)
        local c = { dx * len / 2 + nx * th / 2, 0, ridgeZ + dz * len / 2 + nz * th / 2 }
        b:obox(roofKey, c, { dx * len / 2, 0, dz * len / 2 }, { 0, Lh + oh, 0 }, { nx * th / 2, 0, nz * th / 2 })
        if roofKey ~= "snow" then
            local c2 = { c[1] + nx * th * 0.62 - dx * 8, 0, c[3] + nz * th * 0.62 - dz * 8 }
            b:obox("snow", c2, { dx * (len / 2 - 14), 0, dz * (len / 2 - 14) }, { 0, Lh + oh - 18, 0 }, { nx * 7, 0, nz * 7 })
        end
        -- eave icing: a rounded bead with drips
        local ex, ez = dx * len + nx * th * 0.5, ridgeZ + dz * len + nz * th * 0.5
        b:tube("icing", { ex, -(Lh + oh), ez }, { ex, Lh + oh, ez }, 11, 11, 5, "both", 0)
        local n = math.floor((Lh + oh) * 2 / 34)
        for i = 0, n do
            local y = -(Lh + oh) + i * (Lh + oh) * 2 / n
            local drip = (i % 2 == 0) and 15 or 9
            b:gem("icing", { ex, y, ez - 10 - drip * 0.6 }, 8, drip)
        end
        -- rakes (gable edges)
        for _, sy in ipairs({ -1, 1 }) do
            local y = sy * (Lh + oh)
            b:tube("icing", { 0, y, ridgeZ + th }, { ex, y, ez }, 9, 9, 5, "both", 0)
        end
        -- string lights along the eave
        if h.lights then
            local m = math.floor((Lh + oh) * 2 / 42)
            for i = 0, m do
                local y = -(Lh + oh) + i * (Lh + oh) * 2 / m
                b:gem(MULTI[i % #MULTI + 1], { ex + sx * 6, y, ez - 26 }, 9)
            end
        end
    end
    -- ridge gumdrops
    local nG = math.floor((Lh + oh) * 2 / 70)
    for i = 0, nG do
        local y = -(Lh + oh) + 25 + i * ((Lh + oh) * 2 - 50) / nG
        b:dome(GUMDROPS[(i + rng:int(0, 5)) % #GUMDROPS + 1], { 0, y, ridgeZ + th - 4 }, 20, 30, 7)
    end
    -- chimney
    if h.chimney then
        local cx, cy = -W * 0.45, Lh * 0.45
        local top = ridgeZ + 70
        b:box("brick", cx, cy, (WH + top) / 2, 34, 34, (top - WH) / 2, 0)
        b:box("snow", cx, cy, top + 8, 40, 40, 9, 0)
    end
    -- front door (+X) with icing frame, knob
    local fx = W + 3
    b:box("choc_s", fx, 0, 95, 6, 52, 100, 0)
    b:box("icing", fx + 3, 0, 198, 5, 60, 7, 0)
    b:box("icing", fx + 3, -56, 95, 5, 6, 103, 0)
    b:box("icing", fx + 3, 56, 95, 5, 6, 103, 0)
    b:gem("gold", { fx + 9, 34, 95 }, 7)
    -- windows: glowing panes with icing frames and a cross
    local function window(x, y, z, nx, ny, wHalf, hHalf)
        local px, py = x + nx * 4, y + ny * 4
        -- pane faces outward along (nx, ny)
        local ax, ay = -ny, nx
        b:obox("g_window", { px, py, z }, { nx * 2, ny * 2, 0 }, { ax * wHalf, ay * wHalf, 0 }, { 0, 0, hHalf })
        local fx2, fy2 = x + nx * 8, y + ny * 8
        b:obox("icing", { fx2, fy2, z + hHalf + 5 }, { nx * 4, ny * 4, 0 }, { ax * (wHalf + 10), ay * (wHalf + 10), 0 }, { 0, 0, 6 })
        b:obox("icing", { fx2, fy2, z - hHalf - 5 }, { nx * 4, ny * 4, 0 }, { ax * (wHalf + 10), ay * (wHalf + 10), 0 }, { 0, 0, 6 })
        for _, s in ipairs({ -1, 1 }) do
            b:obox("icing", { fx2 + ax * s * (wHalf + 5), fy2 + ay * s * (wHalf + 5), z }, { nx * 4, ny * 4, 0 }, { ax * 6, ay * 6, 0 }, { 0, 0, hHalf })
        end
        b:obox("icing", { fx2, fy2, z }, { nx * 3, ny * 3, 0 }, { ax * 3, ay * 3, 0 }, { 0, 0, hHalf })
        b:obox("icing", { fx2, fy2, z }, { nx * 3, ny * 3, 0 }, { ax * wHalf, ay * wHalf, 0 }, { 0, 0, 3 })
    end
    window(W, -Lh * 0.55, 135, 1, 0, 36, 38)
    window(W, Lh * 0.55, 135, 1, 0, 36, 38)
    window(-W, -Lh * 0.45, 135, -1, 0, 36, 38)
    if h.sideWindows > 1 then window(-W, Lh * 0.45, 135, -1, 0, 36, 38) end
    window(0, Lh, WH + (ridgeZ - WH) * 0.35, 0, 1, 26, 26)
    window(0, -Lh, WH + (ridgeZ - WH) * 0.35, 0, -1, 26, 26)
    -- gumdrops along the bottom of the walls
    for _, sy in ipairs({ -1, 1 }) do
        for i = 0, 4 do
            local x = -W + 30 + i * (2 * W - 60) / 4
            b:dome(GUMDROPS[(i + (sy > 0 and 2 or 0)) % #GUMDROPS + 1], { x, sy * (Lh + 14), gz(x, sy * (Lh + 14)) }, 16, 24, 6)
        end
    end
    -- candy canes beside the door
    for _, sy in ipairs({ -1, 1 }) do
        local x, y = W + 70, sy * 95
        D.drawCane(b, x, y, gz(x, y), 150, sy > 0 and 90 or -90, false)
    end
    -- candy path to the front
    if h.path then
        for i = 1, 5 do
            local x = W + 40 + i * 62
            local y = (i % 2 == 0) and 12 or -12
            b:box(i % 2 == 0 and "pink" or "icing", x, y, gz(x, y) + 4, 26, 26, 6, 20 * i)
        end
    end
    -- candy fence: posts alternating red/white with an icing rail, on both front corners
    if h.fence then
        for _, sy in ipairs({ -1, 1 }) do
            local prev
            for i = 0, 4 do
                local x = W + 60 - i * 70
                local y = sy * (Lh + 150)
                local z = gz(x, y)
                b:tube(i % 2 == 0 and "red" or "icing", { x, y, z - 15 }, { x, y, z + 75 }, 8, 8, 6, "top", 0)
                b:gem(i % 2 == 0 and "icing" or "red", { x, y, z + 82 }, 9)
                if prev then b:tube("icing", { prev[1], prev[2], prev[3] + 55 }, { x, y, z + 55 }, 5, 5, 4, nil, 0) end
                prev = { x, y, z }
            end
        end
    end
    return ridgeZ
end

-- ------------------------------------------------------------------ test placeholder (debug only)
function D.drawMarker(b, ok)
    b:tube(ok and "g_green" or "g_red", { 0, 0, 0 }, { 0, 0, 600 }, 25, 25, 4, "top", 0)
end

return D
