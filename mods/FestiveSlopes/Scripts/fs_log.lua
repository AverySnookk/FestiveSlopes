-- Festive Slopes: logging.
-- Writes to the UE4SS console and to <mod>/FestiveSlopes.log (previous run kept as FestiveSlopes.prev.log).
-- The file is unbuffered: setvbuf("line") is full buffering in the Windows C runtime, so a crash would lose it.
local L = { debugOn = false }

local fh
local repeats = {}      -- key -> last time logged (rate limiting)

function L.init(modDir, debugOn)
    L.debugOn = debugOn and true or false
    local path = modDir .. "/FestiveSlopes.log"
    pcall(function() os.remove(modDir .. "/FestiveSlopes.prev.log") end)
    pcall(function() os.rename(path, modDir .. "/FestiveSlopes.prev.log") end)
    local okOpen, f = pcall(io.open, path, "w")
    if okOpen and f then
        fh = f
        pcall(function() fh:setvbuf("no") end)
    end
end

local function emit(level, cat, msg)
    local line = string.format("%s %-5s [%s] %s", os.date("%H:%M:%S"), level, cat, msg)
    print("[FestiveSlopes] " .. line .. "\n")
    if fh then pcall(function() fh:write(line, "\n") end) end
end

local function fmt(f, ...)
    if select("#", ...) == 0 then return tostring(f) end
    local ok, s = pcall(string.format, f, ...)
    return ok and s or (tostring(f) .. " <format error>")
end

function L.info(cat, f, ...) emit("INFO", cat, fmt(f, ...)) end
function L.warn(cat, f, ...) emit("WARN", cat, fmt(f, ...)) end
function L.error(cat, f, ...) emit("ERROR", cat, fmt(f, ...)) end
function L.debug(cat, f, ...) if L.debugOn then emit("DEBUG", cat, fmt(f, ...)) end end

-- Log at most once per `seconds` for the same key (keeps failures that repeat every tick out of the log).
function L.every(key, seconds, level, cat, f, ...)
    local now = os.clock()
    local last = repeats[key]
    if last and now - last < seconds then return end
    repeats[key] = now
    emit(level or "WARN", cat, fmt(f, ...))
end

function L.close()
    if fh then pcall(function() fh:close() end) fh = nil end
end

return L
