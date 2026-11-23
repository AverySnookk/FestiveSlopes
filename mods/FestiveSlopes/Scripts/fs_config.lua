-- Festive Slopes: settings from <mod>/Config/FestiveSlopes.ini.
-- Plain "key = value" lines; [Sections] and ; comments are for readability only (keys are unique).
-- Unknown keys are ignored, bad values fall back to the default and are reported, numbers are clamped.
local C = {}

C.DENSITIES = { "off", "light", "moderate", "festive", "wonderland" }
local DENSITY_ALIASES = {
    off = "off", none = "off", light = "light", moderate = "moderate", medium = "moderate", festive = "festive",
    wonderland = "wonderland", ["christmas wonderland"] = "wonderland", christmaswonderland = "wonderland",
    christmas_wonderland = "wonderland", max = "wonderland",
}

-- name -> { default, min, max } for numbers, { default } for booleans, { default, enum = {...} } for words
C.schema = {
    -- General
    enabled                  = { true },
    debug_logging            = { false },
    keybinds_enabled         = { true },
    -- Decorations
    density                  = { "moderate", enum = DENSITY_ALIASES },
    tree_frequency           = { 1.0, 0, 3 },
    house_frequency          = { 1.0, 0, 3 },
    max_decorations          = { 600, 0, 3000 },
    holiday_lighting         = { true },
    light_brightness         = { 1.0, 0.2, 4 },
    -- Placement
    placement_seed           = { 0, 0, 2147483646 },
    trail_edge_offset_m      = { 3, 0, 40 },
    max_house_slope_deg      = { 18, 3, 30 },
    building_clearance_m     = { 22, 0, 200 },
    lift_clearance_m         = { 14, 0, 200 },
    walkway_clearance_m      = { 5, 0, 50 },
    min_trail_length_m       = { 80, 10, 2000 },
    auto_update              = { true },
    update_interval_seconds  = { 30, 5, 600 },
    use_cache                = { true },
}

local function parseValue(raw, def)
    local d = def[1]
    if def.enum then
        local v = def.enum[raw:lower():gsub("^%s+", ""):gsub("%s+$", "")]
        return v
    end
    if type(d) == "boolean" then
        local v = raw:lower()
        if v == "true" or v == "1" or v == "yes" or v == "on" then return true end
        if v == "false" or v == "0" or v == "no" or v == "off" then return false end
        return nil
    end
    local n = tonumber(raw)
    if not n then return nil end
    if def[2] and n < def[2] then n = def[2] end
    if def[3] and n > def[3] then n = def[3] end
    return n
end
C.parseValue = parseValue

function C.defaults()
    local cfg = {}
    for k, def in pairs(C.schema) do cfg[k] = def[1] end
    return cfg
end

-- Returns the settings table, a list of problems (strings) and whether the file was found.
function C.load(path)
    local cfg, problems = C.defaults(), {}
    local f = io.open(path, "r")
    if not f then
        problems[#problems + 1] = "FestiveSlopes.ini not found, using defaults"
        return cfg, problems, false
    end
    local n = 0
    for line in f:lines() do
        n = n + 1
        line = line:gsub("^\239\187\191", "")              -- UTF-8 BOM on the first line
        line = line:gsub("[;#].*$", "")
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k then
            local def = C.schema[k]
            if not def then
                problems[#problems + 1] = string.format("line %d: unknown setting '%s' ignored", n, k)
            else
                local pv = parseValue(v, def)
                if pv == nil then
                    problems[#problems + 1] = string.format("line %d: bad value '%s' for %s, using %s", n, v, k, tostring(def[1]))
                else
                    if type(pv) == "number" and tonumber(v) ~= pv then
                        problems[#problems + 1] = string.format("line %d: %s = %s is out of range, using %s", n, k, v, tostring(pv))
                    end
                    cfg[k] = pv
                end
            end
        end
    end
    f:close()
    cfg.max_decorations = math.floor(cfg.max_decorations + 0.5)
    cfg.placement_seed = math.floor(cfg.placement_seed + 0.5)
    return cfg, problems, true
end

function C.describe(cfg)
    local keys = {}
    for k in pairs(C.schema) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(cfg[k]) end
    return table.concat(parts, " ")
end

-- The settings that change where decorations go / what they look like (part of the placement cache key).
function C.placementKey(cfg)
    return table.concat({ cfg.density, cfg.tree_frequency, cfg.house_frequency, cfg.max_decorations,
        cfg.trail_edge_offset_m, cfg.max_house_slope_deg, cfg.building_clearance_m,
        cfg.lift_clearance_m, cfg.walkway_clearance_m, cfg.min_trail_length_m }, "|")
end

return C
