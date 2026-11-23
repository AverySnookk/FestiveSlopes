-- Festive Slopes: low-poly geometry builder for ProceduralMeshComponent sections.
-- Everything is built from flat-shaded faces (each face has its own vertices and normal), which matches the game's
-- faceted low-poly look. Geometry is grouped by material key, one mesh section per key.
-- Coordinates: cm. A builder has a current transform (origin + yaw + uniform scale) that maps design-local points
-- (X forward, Y right, Z up) into the space of the actor that will own the mesh.
local M = {}

-- Triangle winding. With 1, (a, b, c) is counter-clockwise around the outward normal in the cross-product sense;
-- ProceduralMeshComponent wants the opposite (lab 2026-11-21: with 1 every face was culled from outside and the
-- decorations rendered black from their back faces; -1 shows the real colours).
M.WIND = -1

local sqrt, cos, sin, pi = math.sqrt, math.cos, math.sin, math.pi

local function norm(x, y, z)
    local l = sqrt(x * x + y * y + z * z)
    if l < 1e-9 then return 0, 0, 1 end
    return x / l, y / l, z / l
end
M.norm = norm
local function cross(ax, ay, az, bx, by, bz) return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx end

local B = {}
B.__index = B

function M.builder()
    return setmetatable({ secs = {}, order = {}, cur = {}, tris = 0, verts = 0, T = { 0, 0, 0, 1, 0, 1 } }, B)
end

-- Largest vertex count handed to the engine in one CreateMeshSection call. Lab 2026-11-21: a 27k-vertex group
-- crashed inside UE4SS while its sections were being created; big sections are split so each call stays small.
M.MAX_SECTION_VERTS = 3000

-- Set the design-local -> actor transform: origin (x, y, z), yaw in degrees, uniform scale.
function B:place(x, y, z, yawDeg, scale)
    local a = math.rad(yawDeg or 0)
    self.T = { x, y, z, cos(a), sin(a), scale or 1 }
end

-- The section currently filled for a material key; a full one rolls over to "key#2", "key#3"... (s.mat = key).
function B:sec(key)
    local sub = self.cur[key] or key
    local s = self.secs[sub]
    if s and #s.v + 3 > M.MAX_SECTION_VERTS then
        local n = (s.part or 1) + 1
        sub = key .. "#" .. n
        self.cur[key] = sub
        s = nil
        self.secs[sub] = { v = {}, n = {}, uv = {}, t = {}, mat = key, part = n }
        self.order[#self.order + 1] = sub
        return self.secs[sub]
    end
    if not s then
        s = { v = {}, n = {}, uv = {}, t = {}, mat = key, part = 1 }
        self.secs[sub] = s
        self.cur[key] = sub
        self.order[#self.order + 1] = sub
    end
    return s
end

-- local point -> actor space
function B:tp(x, y, z)
    local T = self.T
    local k = T[6]
    return T[1] + k * (x * T[4] - y * T[5]), T[2] + k * (x * T[5] + y * T[4]), T[3] + k * z
end
-- local direction -> actor space (rotation only)
function B:td(x, y, z)
    local T = self.T
    return x * T[4] - y * T[5], x * T[5] + y * T[4], z
end

-- One flat triangle (actor-space points). hint: a direction the face should look toward (actor space), or nil
-- to keep the geometric normal of the given order.
function B:triA(key, a, b, c, hx, hy, hz)
    local ux, uy, uz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
    local vx, vy, vz = c[1] - a[1], c[2] - a[2], c[3] - a[3]
    local nx, ny, nz = cross(ux, uy, uz, vx, vy, vz)
    local l = sqrt(nx * nx + ny * ny + nz * nz)
    if l < 1e-6 then return end
    nx, ny, nz = nx / l, ny / l, nz / l
    if hx and (nx * hx + ny * hy + nz * hz) < 0 then nx, ny, nz = -nx, -ny, -nz b, c = c, b end
    -- now (a, b, c) is counter-clockwise around n in the cross-product sense; apply the engine's convention
    if M.WIND < 0 then b, c = c, b end
    local s = self:sec(key)
    local base = #s.v
    s.v[base + 1] = { X = a[1], Y = a[2], Z = a[3] }
    s.v[base + 2] = { X = b[1], Y = b[2], Z = b[3] }
    s.v[base + 3] = { X = c[1], Y = c[2], Z = c[3] }
    local n = { X = nx, Y = ny, Z = nz }
    s.n[base + 1], s.n[base + 2], s.n[base + 3] = n, n, n
    s.uv[base + 1], s.uv[base + 2], s.uv[base + 3] = { X = 0, Y = 0 }, { X = 1, Y = 0 }, { X = 0, Y = 1 }
    local t = s.t
    t[#t + 1], t[#t + 2], t[#t + 3] = base, base + 1, base + 2
    self.tris = self.tris + 1
    self.verts = self.verts + 3
end

-- Triangle / quad in design-local coordinates with a local outward hint.
function B:tri(key, a, b, c, hint)
    local A = { self:tp(a[1], a[2], a[3]) }
    local Bp = { self:tp(b[1], b[2], b[3]) }
    local C = { self:tp(c[1], c[2], c[3]) }
    if hint then
        local hx, hy, hz = self:td(hint[1], hint[2], hint[3])
        self:triA(key, A, Bp, C, hx, hy, hz)
    else
        self:triA(key, A, Bp, C)
    end
end
function B:quad(key, a, b, c, d, hint)
    self:tri(key, a, b, c, hint)
    self:tri(key, a, c, d, hint)
end

-- Oriented box: centre c and three half-axis vectors (local).
function B:obox(key, c, ax, ay, az)
    local function P(sx, sy, sz)
        return { c[1] + sx * ax[1] + sy * ay[1] + sz * az[1], c[2] + sx * ax[2] + sy * ay[2] + sz * az[2], c[3] + sx * ax[3] + sy * ay[3] + sz * az[3] }
    end
    local faces = {
        { ax, { 1, -1, -1 }, { 1, 1, -1 }, { 1, 1, 1 }, { 1, -1, 1 }, 1 },
        { ax, { -1, -1, -1 }, { -1, -1, 1 }, { -1, 1, 1 }, { -1, 1, -1 }, -1 },
        { ay, { -1, 1, -1 }, { -1, 1, 1 }, { 1, 1, 1 }, { 1, 1, -1 }, 1 },
        { ay, { -1, -1, -1 }, { 1, -1, -1 }, { 1, -1, 1 }, { -1, -1, 1 }, -1 },
        { az, { -1, -1, 1 }, { 1, -1, 1 }, { 1, 1, 1 }, { -1, 1, 1 }, 1 },
        { az, { -1, -1, -1 }, { -1, 1, -1 }, { 1, 1, -1 }, { 1, -1, -1 }, -1 },
    }
    for _, f in ipairs(faces) do
        local h = { f[1][1] * f[6], f[1][2] * f[6], f[1][3] * f[6] }
        self:quad(key, P(f[2][1], f[2][2], f[2][3]), P(f[3][1], f[3][2], f[3][3]), P(f[4][1], f[4][2], f[4][3]), P(f[5][1], f[5][2], f[5][3]), h)
    end
end

-- Axis-aligned (in design space) box rotated by yaw degrees about its own centre.
function B:box(key, cx, cy, cz, hx, hy, hz, yawDeg)
    local a = math.rad(yawDeg or 0)
    local c, s = cos(a), sin(a)
    self:obox(key, { cx, cy, cz }, { hx * c, hx * s, 0 }, { -hy * s, hy * c, 0 }, { 0, 0, hz })
end

-- Basis perpendicular to a direction.
local function basis(dx, dy, dz)
    local ux, uy, uz
    if math.abs(dz) < 0.9 then ux, uy, uz = cross(dx, dy, dz, 0, 0, 1) else ux, uy, uz = cross(dx, dy, dz, 1, 0, 0) end
    ux, uy, uz = norm(ux, uy, uz)
    local vx, vy, vz = cross(dx, dy, dz, ux, uy, uz)
    return ux, uy, uz, vx, vy, vz
end

-- Tube/frustum from p0 (radius r0) to p1 (radius r1). sides >= 3. caps: "both", "bottom", "top" or nil.
-- jitter: optional function(i) -> radius factor for ring points (natural variation), phase: start angle (rad).
function B:tube(key, p0, p1, r0, r1, sides, caps, phase, jitter0, jitter1)
    local dx, dy, dz = norm(p1[1] - p0[1], p1[2] - p0[2], p1[3] - p0[3])
    local ux, uy, uz, vx, vy, vz = basis(dx, dy, dz)
    local ring0, ring1 = {}, {}
    phase = phase or 0
    for i = 1, sides do
        local a = phase + (i - 1) * 2 * pi / sides
        local ca, sa = cos(a), sin(a)
        local f0 = jitter0 and jitter0(i) or 1
        local f1 = jitter1 and jitter1(i) or 1
        ring0[i] = { p0[1] + (ux * ca + vx * sa) * r0 * f0, p0[2] + (uy * ca + vy * sa) * r0 * f0, p0[3] + (uz * ca + vz * sa) * r0 * f0 }
        ring1[i] = { p1[1] + (ux * ca + vx * sa) * r1 * f1, p1[2] + (uy * ca + vy * sa) * r1 * f1, p1[3] + (uz * ca + vz * sa) * r1 * f1 }
    end
    local mx, my, mz = (p0[1] + p1[1]) / 2, (p0[2] + p1[2]) / 2, (p0[3] + p1[3]) / 2
    for i = 1, sides do
        local j = i % sides + 1
        local a, b, c, d = ring0[i], ring0[j], ring1[j], ring1[i]
        local fx, fy, fz = (a[1] + b[1] + c[1] + d[1]) / 4 - mx, (a[2] + b[2] + c[2] + d[2]) / 4 - my, (a[3] + b[3] + c[3] + d[3]) / 4 - mz
        if r1 <= 0.01 then
            self:tri(key, a, b, p1, { fx, fy, fz })
        else
            self:quad(key, a, b, c, d, { fx, fy, fz })
        end
    end
    if caps == "both" or caps == "bottom" then
        for i = 1, sides do self:tri(key, p0, ring0[i % sides + 1], ring0[i], { -dx, -dy, -dz }) end
    end
    if (caps == "both" or caps == "top") and r1 > 0.01 then
        for i = 1, sides do self:tri(key, p1, ring1[i], ring1[i % sides + 1], { dx, dy, dz }) end
    end
end

-- Small gem (octahedron): bulbs, gumdrop sprinkles, icing dots.
function B:gem(key, c, r, rz)
    rz = rz or r
    local px, nx = { c[1] + r, c[2], c[3] }, { c[1] - r, c[2], c[3] }
    local py, ny = { c[1], c[2] + r, c[3] }, { c[1], c[2] - r, c[3] }
    local pz, nz = { c[1], c[2], c[3] + rz }, { c[1], c[2], c[3] - rz }
    local function T(a, b, d) self:tri(key, a, b, d, { (a[1] + b[1] + d[1]) / 3 - c[1], (a[2] + b[2] + d[2]) / 3 - c[2], (a[3] + b[3] + d[3]) / 3 - c[3] }) end
    T(px, py, pz) T(py, nx, pz) T(nx, ny, pz) T(ny, px, pz)
    T(py, px, nz) T(nx, py, nz) T(ny, nx, nz) T(px, ny, nz)
end

-- Rounded dome (gumdrop / snow mound): base radius r, height h, on point c (base centre).
function B:dome(key, c, r, h, sides)
    sides = sides or 7
    local z0, z1, z2 = c[3], c[3] + h * 0.55, c[3] + h
    local r1 = r * 0.78
    local mid = { c[1], c[2], c[3] + h * 0.4 }
    local ring0, ring1 = {}, {}
    for i = 1, sides do
        local a = (i - 1) * 2 * pi / sides
        ring0[i] = { c[1] + cos(a) * r, c[2] + sin(a) * r, z0 }
        ring1[i] = { c[1] + cos(a + pi / sides) * r1, c[2] + sin(a + pi / sides) * r1, z1 }
    end
    local top = { c[1], c[2], z2 }
    for i = 1, sides do
        local j = i % sides + 1
        local function H(p) return { p[1] - mid[1], p[2] - mid[2], p[3] - mid[3] } end
        self:tri(key, ring0[i], ring0[j], ring1[i], H(ring1[i]))
        self:tri(key, ring0[j], ring1[j], ring1[i], H(ring1[j]))
        self:tri(key, ring1[i], ring1[j], top, H(top))
    end
end

-- Five-pointed star in the plane spanned by local direction (dirx, diry) (horizontal) and Z, extruded by thick.
function B:star(key, c, R, r, thick, yawDeg)
    local a0 = math.rad(yawDeg or 0)
    local ux, uy = cos(a0), sin(a0)          -- in-plane horizontal axis
    local nx, ny = -uy, ux                   -- extrusion axis
    local pts = {}
    for i = 0, 9 do
        local ang = pi / 2 + i * pi / 5
        local rad = (i % 2 == 0) and R or r
        local h, v = cos(ang) * rad, sin(ang) * rad
        pts[#pts + 1] = { c[1] + ux * h, c[2] + uy * h, c[3] + v }
    end
    local t = thick / 2
    local function off(p, s) return { p[1] + nx * t * s, p[2] + ny * t * s, p[3] } end
    local cf, cb = off(c, 1), off(c, -1)
    for i = 1, 10 do
        local j = i % 10 + 1
        local a, b = pts[i], pts[j]
        self:tri(key, cf, off(a, 1), off(b, 1), { nx, ny, 0 })
        self:tri(key, cb, off(b, -1), off(a, -1), { -nx, -ny, 0 })
        local mx, my, mz = (a[1] + b[1]) / 2 - c[1], (a[2] + b[2]) / 2 - c[2], (a[3] + b[3]) / 2 - c[3]
        self:quad(key, off(a, 1), off(a, -1), off(b, -1), off(b, 1), { mx, my, mz })
    end
end

-- Polyline tube (candy canes, garlands). keys: list cycled per segment (stripes).
function B:pipe(keys, pts, r, sides)
    for i = 1, #pts - 1 do
        local key = keys[(i - 1) % #keys + 1]
        self:tube(key, pts[i], pts[i + 1], r, r, sides or 6, (i == 1 and "bottom") or (i == #pts - 1 and "top") or nil, 0)
    end
end

function B:stats() return self.verts, self.tris, #self.order end

return M
