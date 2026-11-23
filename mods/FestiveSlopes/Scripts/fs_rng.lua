-- Festive Slopes: deterministic random numbers and hashes.
-- The same resort + the same trail always gives the same decorations, independent of math.random (which other code
-- may reseed) and of the order things are scanned in. Plain arithmetic only (no bit operators), exact in doubles.
local R = {}

local M = 2147483647            -- 2^31 - 1 (Park-Miller "minimal standard" generator)

-- Hash any mix of strings and numbers into 1..M-1.
function R.hash(...)
    local h = 5381
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        local s = type(v) == "number" and string.format("%.0f", v) or tostring(v)
        for j = 1, #s do h = (h * 33 + s:byte(j)) % M end
        h = (h * 131 + 7) % M
    end
    if h == 0 then h = 1 end
    return h
end

local Gen = {}
Gen.__index = Gen

function R.new(seed)
    local s = math.floor(tonumber(seed) or 1) % M
    if s <= 0 then s = s + M - 1 end
    local g = setmetatable({ s = s }, Gen)
    g:next() g:next()
    return g
end

function Gen:next()
    self.s = (self.s * 48271) % M
    return self.s
end
-- [0, 1)
function Gen:float() return (self:next() - 1) / (M - 1) end
function Gen:range(a, b) return a + (b - a) * self:float() end
-- integer in [a, b]
function Gen:int(a, b) return a + math.floor(self:float() * (b - a + 1)) end
function Gen:chance(p) return self:float() < p end
function Gen:pick(list) return list[self:int(1, #list)] end
function Gen:sign() return self:float() < 0.5 and -1 or 1 end

return R
