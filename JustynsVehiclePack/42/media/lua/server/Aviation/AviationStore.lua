--[[
    AviationStore - the SERVER-side home of the Aviation level.

    ============================ WHY THIS FILE EXISTS ============================

    The Aviation level would not survive a reload. The instrumented framework answered why,
    precisely:

        global store init: ok=true newGame=false entries restored=0 (isServer=false isClient=true)
        global store first write: [therentcollector] = 2 (table present, transmit sent)

    The table was created, the write happened, and NOTHING came back on the next load. So the
    fault was never the key, the perk, or the write - it was WHERE the write ran. The framework
    lives in shared/, which on a hosted game executes in the client context (isServer=false),
    and a global ModData table written there is a client-side copy that is not part of the save.

    Every vanilla global store that genuinely persists - forageData in server/Foraging,
    UniqueVehiclesSpawned in server/Vehicles/ProfessionVehicles.lua - is created and written
    from media/lua/server/. This file follows that pattern exactly rather than inventing one.

    ============================ WHAT IT GUARANTEES ============================

    * The table is created in OnInitGlobalModData, on the server side. A table first touched
      mid-session is not saved at all; this is the same reason ProfessionVehicles registers
      UniqueVehiclesSpawned there.
    * Writes go through this file, so there is exactly one writer and it is on the
      authoritative side.
    * ModData.transmit is called after a write so connected clients see the new value.

    ============================ HOW THE CLIENT REACHES IT ============================

    In singleplayer and on a coop host, server Lua shares one VM with the client and this
    global is directly callable - which is also how C172ServerCommands is reached, after
    Events.OnClientCommand was found not to deliver on a coop host. On a dedicated server the
    client cannot see this table at all and must go through the existing debugSetAviation
    command, which already runs here.

    This file deliberately contains NO skill logic. It is a keyed store and nothing else, so
    the framework remains the single place that decides what a level means.
]]

AviationStore = AviationStore or {}

-- ============================================== FILE-BACKED FALLBACK
--
-- WHY A FILE. Global ModData does not persist on a hosted (coop) game. Proven, not assumed:
-- after a session in which this file logged "saved [therentcollector] = 2", the very next load
-- logged "server store ready: table=true newGame=false restored=0 entries". The table is
-- created, the write succeeds, and nothing comes back - on the SERVER side as well as the
-- client. Character ModData behaved identically. Both of PZ's obvious per-player stores are
-- therefore unusable here, which is why the level has had to be re-granted every session.
--
-- getFileWriter/getFileReader are plain disk IO, used by vanilla itself (luautils.lua,
-- forageSystem.lua), and they do not depend on the save cycle at all. That makes them the one
-- mechanism that cannot be silently discarded by whichever side PZ decides owns the data.
--
-- FORMAT: one "username=level" per line, rewritten in full on every change. The file is tiny
-- (one short line per player who has ever flown) so rewriting beats append-and-compact.
--
-- SCOPE AND ITS LIMIT, STATED HONESTLY: the file lives beside the other Zomboid logs, so it is
-- per-INSTALL, not per-save. Two different worlds on the same machine share it. Keying on the
-- world name as well would fix that, but getWorld() is not reliably available at the moment
-- this first runs, and losing the level again is a worse failure than sharing it between
-- saves. Revisit if per-save separation is ever wanted.
local FILE_NAME = "C172AviationLevels.txt"

local cache = nil          -- username -> level, read once then kept in memory

local function readFile()
    local t = {}
    local ok = pcall(function()
        local r = getFileReader(FILE_NAME, false)
        if not r then return end
        while true do
            local line = r:readLine()
            if line == nil then break end
            local name, lvl = string.match(line, "^(.-)=(%d+)$")
            if name and lvl and name ~= "" then t[name] = tonumber(lvl) end
        end
        r:close()
    end)
    if not ok then return {} end
    return t
end

local function writeFile(t)
    pcall(function()
        local w = getFileWriter(FILE_NAME, true, false)   -- create, do NOT append
        if not w then return end
        for name, lvl in pairs(t) do
            if type(name) == "string" and type(lvl) == "number" then
                w:write(name .. "=" .. tostring(math.floor(lvl)) .. "\n")
            end
        end
        w:close()
    end)
end

local function fileCache()
    if cache == nil then cache = readFile() end
    return cache
end



local TABLE_NAME = "C172AviationLevels"

local function store()
    local ok, t = pcall(function() return ModData.getOrCreate(TABLE_NAME) end)
    return (ok and type(t) == "table") and t or nil
end

-- Registered here, on the server side, for the reason in the header.
if Events and Events.OnInitGlobalModData then
    Events.OnInitGlobalModData.Add(function(isNewGame)
        local t = store()
        local n = 0
        if t then for _ in pairs(t) do n = n + 1 end end
        local f = fileCache()
        local fn = 0
        for _ in pairs(f) do fn = fn + 1 end
        print(("[AviationStore] ready: modData table=%s restored=%d | FILE restored=%d entries")
            :format(tostring(t ~= nil), n, fn))
    end)
end

--- Reads a saved level. Returns 0 rather than nil so callers never have to special-case a
--- fresh world or an unknown player.
function AviationStore.get(username)
    if type(username) ~= "string" or username == "" then return 0 end

    -- File first: it is the store that actually survives. ModData is still consulted
    -- afterwards so a value written by an older build is not lost.
    local fromFile = tonumber(fileCache()[username])
    if type(fromFile) == "number" and fromFile > 0 then
        if fromFile > 10 then fromFile = 10 end
        return math.floor(fromFile)
    end

    local t = store()
    if not t then return 0 end
    local v = tonumber(t[username])
    if type(v) ~= "number" or v ~= v or v < 0 then return 0 end
    if v > 10 then v = 10 end
    return math.floor(v)
end

--- Writes a level. Never lowers a saved value by accident: the caller must pass `force` to
--- reduce one, so a stale read on a reconnect cannot wipe real progress.
function AviationStore.set(username, level, force)
    if type(username) ~= "string" or username == "" then return false end
    level = tonumber(level)
    if type(level) ~= "number" or level ~= level then return false end
    level = math.floor(math.max(0, math.min(10, level)))

    local t = store()
    if not t then
        print("[AviationStore] WRITE FAILED - global table unavailable on this side.")
        return false
    end

    local prev = tonumber(t[username]) or 0
    if not force and level < prev then return true end
    if t[username] == level then return true end

    t[username] = level
    pcall(function() ModData.transmit(TABLE_NAME) end)

    -- And to disk, which is the copy that will still be here next session.
    local c = fileCache()
    c[username] = level
    writeFile(c)
    print(("[AviationStore] saved [%s] = %d (was %s)")
        :format(username, level, tostring(prev)))
    return true
end

return AviationStore
