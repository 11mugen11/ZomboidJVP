require "Cessna172/C172Variants"
--[[
    C172Contacts - flying OVER things without Java (1.9.0).

    Replaces Patch_AirborneCollision, Patch_PlantCollision and Patch_ZombieContact.

    The body really is up in the air, so the physics library never touches a fence or a car
    below it. But the game's Java side keeps testing a vehicle against the GROUND under it,
    ignoring height - every one of these reads the vehicle script's `extents` (42.21 jar):
      BaseVehicle.breakingObjects()   grass and bushes ("VehicleScrapePastPlant" and a BRAKING
          impulse - the speed lost flying low over scrub), fences and signs broken, zombies
          marked to be run down, corpses
      BaseVehicle.damageObjects()     on a crash
      BaseVehicle.isCharacterAdjacentTo()  zombies "attacking" an aircraft flying over them
      testCollisionWithCharacter / ProneCharacter / Corpse
    The Java build skipped those calls with patches. Here, while one of this client's Cessnas
    is CLEAR of the ground, the footprint's width and length are set NEGATIVE. Read back from
    the jar, that makes the scan radius max(x, z)/2 + 1.3 < 0 (zero squares scanned) and
    adjacency impossible, and leaves alone what must not change: the height (spawn height and
    the draw test read it) and pathfinding (VehiclePoly re-winds the corners).
    It is put back the moment the aircraft is low again, so takeoff, landing and skimming
    the ground still hit things exactly as a car would.

    The part lights sit at their offset x HALF the footprint, so they are re-aimed with each
    change (C172LightSpecs) - otherwise the landing light would shine from behind the tail.

    LIMIT: the footprint belongs to the vehicle SCRIPT, so while one Cessna is clear every
    Cessna near this player is contact-free too. Only this aircraft type is affected, and a
    parked one with its engine off hits nothing anyway. Nothing else in the game is touched.

    MULTIPLAYER (1.10.3). Every game runs these tests against its OWN copy of the script, and this
    file only ever shrank the copy of the client flying the aircraft - the server and everyone else
    kept the full footprint, so in multiplayer a Cessna flying over a town still broke fences, scraped
    bushes and had zombies "attack" it, with the noises (Jay, 10-08: "seems to hit more stuff in mp",
    "hear a lot of noises when flying in areas"). The flying client now says "clear" in the flight
    update it sends every 0.5 s; the server shrinks its copy the same way (server/Cessna172/
    C172ServerContacts.lua) and so does every other client (remoteReport below). A report counts for
    REMOTE_FRESH_MS only, so a pilot who drops out mid-air does not leave the footprint shrunk.
]]

require "Cessna172/C172Phys"
require "Cessna172/C172LightSpecs"

local P = C172Phys
local C = {}
C172Contacts = C
P.Contacts = C

C.CLEAR_EXTENTS = -3.0      -- m; anything <= -2.6 zeroes the scan radius (see above)
C.REMOTE_FRESH_MS = 1500    -- three missed 0.5 s flight updates and another player's report lapses
C.small = false
C.extents = nil             -- the script's live extents vector
C.full = nil                -- its real values, captured before any change

local function log(msg) print("[Cessna172] " .. msg) end

-- First sight of the script: remember its real footprint. If what is there is not a real one
-- (a session that ended mid-flight in this same game launch), fall back to the known size.
local function capture(v)
    if C.extents then return true end
    local ok, e = pcall(function() return v:getScript():getExtents() end)
    if not (ok and e) then return false end
    C.extents = e
    local x, y, z = P.num(e:x(), 0), P.num(e:y(), 0), P.num(e:z(), 0)
    if x > 0.5 and z > 0.5 then
        C.full = { x, y, z }
    else
        local f = P.FULL_EXTENTS
        C.full = { f[1], f[2], f[3] }
        e:set(f[1], f[2], f[3])
        log("ground footprint was left shrunk by an earlier session - restored")
    end
    return true
end

-- Re-aim one aircraft's four part lights for the footprint the engine now sees.
local function aimLights(v)
    if not (C.extents and C.full) then return end
    local ex, ez = P.num(C.extents:x(), C.full[1]), P.num(C.extents:z(), C.full[3])
    if ex == 0 or ez == 0 then return end
    local kx, ky = C.full[1] / ex, C.full[3] / ez
    for id, spec in pairs(C172LightSpecs) do
        if type(spec) == "table" then
            pcall(function()
                local part = v:getPartById(id)
                if part and part:getInventoryItem() then
                    part:createSpotLightColor(spec.x * kx, spec.y * ky, spec.dist, spec.intensity,
                                              spec.dot, 0, spec.r, spec.g, spec.b)
                end
            end)
        end
    end
end

local function aimAll(around)
    local n = P.c172ScanNearbyAircraft(around:getX(), around:getY(), 60)
    for i = 0, n - 1 do
        local v = P.c172NearbyAircraft(i)
        if v then aimLights(v) end
    end
end

local function setSmall(small, around)
    if small then
        C.extents:set(C.CLEAR_EXTENTS, C.full[2], C.CLEAR_EXTENTS)
    else
        C.extents:set(C.full[1], C.full[2], C.full[3])
    end
    C172Variants.footprints(small,C.full,C.CLEAR_EXTENTS)
    C.small = small
    log("ground contacts " .. (small and "OFF (flying clear)" or "ON"))
    if around then aimAll(around) end
end

-- Called by the flight controller every tick it flies: clear = this aircraft is airborne and
-- high enough that nothing on the ground can be touching it.
C.clearIds = {}
C.remoteClear = {}          -- id -> { vehicle =, at = ms }: other players' Cessnas reported clear

local function nowMs()
    local ok, ms = pcall(getTimestampMs)
    return (ok and type(ms) == "number") and ms or 0
end

-- Whether any Cessna is clear right now: one this client flies, or another player's whose last
-- report is fresh (stale ones are dropped here).
local function wanted()
    for _ in pairs(C.clearIds) do return true end
    local now, any = nowMs(), false
    for id, e in pairs(C.remoteClear) do
        if now - e.at > C.REMOTE_FRESH_MS or now < e.at then C.remoteClear[id] = nil else any = true end
    end
    return any
end
C._wanted = wanted

function C.report(v, clear)
    local ok, id = pcall(function() return v:getId() end)
    if not ok then return end
    C.clearIds[id] = clear and v or nil
    C.remoteClear[id] = nil
    if not capture(v) then return end
    local want = wanted()
    if want ~= C.small then setSmall(want, v) end
end

-- Another player's Cessna, from the flight update the server relays (C172Flight onServerCommand).
function C.remoteReport(v, clear)
    local ok, id = pcall(function() return v:getId() end)
    if not (ok and id) or C.clearIds[id] then return end
    C.remoteClear[id] = clear and { vehicle = v, at = nowMs() } or nil
    if not capture(v) then return end
    local want = wanted()
    if want ~= C.small then setSmall(want, v) end
end

-- Lapsed reports, checked while any are held (every tick: one table walk).
function C.expire()
    if not C.small then return end
    local anyRemote = false
    for _ in pairs(C.remoteClear) do anyRemote = true break end
    if not anyRemote then return end
    if not wanted() then setSmall(false, getSpecificPlayer(0)) end
end

-- Every aircraft this client stopped flying (landed, left, unloaded) drops out.
function C.release(v)
    local ok, id = pcall(function() return v:getId() end)
    if ok and id then C.clearIds[id] = nil end
    if C.small and not wanted() then setSmall(false, v) end
end

-- Back to the real footprint, no questions (game start, main menu, a reset).
function C.restore()
    for id in pairs(C.remoteClear) do C.remoteClear[id] = nil end
    for id in pairs(C.clearIds) do C.clearIds[id] = nil end
    if C.small and C.extents and C.full then
        C.extents:set(C.full[1], C.full[2], C.full[3])
        C172Variants.footprints(false,C.full,C.CLEAR_EXTENTS)
        C.small = false
        log("ground contacts ON (reset)")
    end
end

-- A Cessna that comes into range while the footprint is shrunk gets its lights aimed for it.
function C.aimIfSmall(v)
    if C.small then aimLights(v) end
end

-- The script outlives a save being closed (it is not reloaded until the game restarts), so a
-- world left mid-flight must not hand the next one a shrunk footprint.
Events.OnGameStart.Add(C.restore)
Events.OnMainMenuEnter.Add(C.restore)
Events.OnTick.Add(function() pcall(C.expire) end)

return C
