--[[
    C172ServerContacts - the server's half of flying OVER things (1.10.3, multiplayer).

    Jay, 2026-10-08, after co-op tests: "seems to hit more stuff in mp", "hear a lot of noises when
    flying in areas". The game tests a vehicle against the GROUND under it with the vehicle script's
    footprint (`extents`), ignoring height - bushes scraped, fences broken, zombies "attacking" it
    from below (client/Cessna172/C172Contacts.lua has the whole list, read from the 42.21 jar). The
    flying client shrinks that footprint to nothing while its Cessna is clear of the ground - but
    every game tests against its OWN copy of the script, and in multiplayer the server's copy stayed
    full size, so the server kept "hitting" everything under the flight path and sent the noises to
    everyone.

    So the server does what the flying client does, from the flight update that client already
    sends every 0.5 s (C172Server.lua checks the sender really is that Cessna's driver; `clear` is
    one more field in it): while any Cessna reports clear, the server's footprint is shrunk exactly
    as C172Contacts shrinks the client's - width and length negative, height kept - and put back
    the moment none does. A report counts for FRESH_MS only: a pilot who drops out mid-air stops
    sending, and the next check puts the footprint back. Checks run on every flight update, on
    every Cessna engine part update (C172Systems.Update.Engine - part updates run on the server)
    and once a game minute.

    LIMIT, as on the client: the footprint belongs to the vehicle SCRIPT, so while one Cessna is
    clear every Cessna on the server is contact-free. A parked one with its engine off hits nothing
    anyway; one taxiing while another flies does not knock down fences until the other one lands.

    Dedicated or hosted server only (isServer()). In single player the client's C172Contacts already
    shrinks the one script there is, and no flight update is ever sent.
]]

C172ServerContacts = C172ServerContacts or {}
local S = C172ServerContacts

S.CLEAR_EXTENTS = -3.0      -- m, as C172Contacts.CLEAR_EXTENTS: anything <= -2.6 zeroes the scan radius
S.FRESH_MS = 1500           -- three missed 0.5 s flight updates
S.FULL_EXTENTS = { 1.4875, 1.225, 2.625 }   -- only if the script is found already shrunk (= C172Phys.FULL_EXTENTS)
S.small = false
S.extents = nil             -- the server script's live extents vector
S.full = nil                -- its real values, captured before any change
S.clear = {}                -- vehicle id -> server ms of its last "clear" report

local function log(msg) print("[Cessna172][server] " .. msg) end

local function nowMs()
    local ok, ms = pcall(getTimestampMs)
    return (ok and type(ms) == "number") and ms or 0
end
S._nowMs = nowMs

local function num(x, d)
    if type(x) ~= "number" or x ~= x or x == math.huge or x == -math.huge then return d end
    return x
end

local function capture(v)
    if S.extents then return true end
    local ok, e = pcall(function() return v:getScript():getExtents() end)
    if not (ok and e) then return false end
    S.extents = e
    local x, y, z = num(e:x(), 0), num(e:y(), 0), num(e:z(), 0)
    if x > 0.5 and z > 0.5 then
        S.full = { x, y, z }
    else
        local f = S.FULL_EXTENTS
        S.full = { f[1], f[2], f[3] }
        e:set(f[1], f[2], f[3])
        log("ground footprint was found shrunk - restored")
    end
    return true
end

local function setSmall(small)
    if not (S.extents and S.full) then return end
    if small then
        S.extents:set(S.CLEAR_EXTENTS, S.full[2], S.CLEAR_EXTENTS)
    else
        S.extents:set(S.full[1], S.full[2], S.full[3])
    end
    S.small = small
    log("ground contacts " .. (small and "OFF (a Cessna is flying clear)" or "ON"))
end

-- Any fresh "clear" report left (stale ones dropped).
local function wanted()
    local now, any = nowMs(), false
    for id, at in pairs(S.clear) do
        if now - at > S.FRESH_MS or now < at then S.clear[id] = nil else any = true end
    end
    return any
end
S._wanted = wanted

-- One validated flight update (C172Server.onClientCommand): `vehicle` is the sender's own Cessna.
function S.report(vehicle, clear)
    if not isServer() then return end
    local ok, id = pcall(function() return vehicle:getId() end)
    if not (ok and id) then return end
    S.clear[id] = clear and nowMs() or nil
    if not capture(vehicle) then return end
    local want = wanted()
    if want ~= S.small then setSmall(want) end
end

-- Put the footprint back once the last report has lapsed.
function S.check()
    if not S.small then return end
    if not wanted() then setSmall(false) end
end

function S.restore()
    for id in pairs(S.clear) do S.clear[id] = nil end
    if S.small then setSmall(false) end
end

Events.EveryOneMinute.Add(function() pcall(S.check) end)

return S
