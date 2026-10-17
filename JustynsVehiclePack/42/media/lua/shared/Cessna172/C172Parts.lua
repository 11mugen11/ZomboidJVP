--[[
    C172Parts - THE SINGLE SOURCE OF TRUTH for this aircraft's components.

    WHY THIS FILE EXISTS. The cockpit HUD and the Vehicle Mechanics panel used to each
    carry their own idea of what the Cessna is made of: the HUD had a hand-written list of
    six rows, the mechanics panel had whatever vanilla templates happened to produce, and
    the two agreed only by coincidence. That is exactly the "two separate fake systems that
    drift apart" failure. There is now ONE list, here, and both readers walk it.

    THERE IS NO SECOND CONDITION NUMBER ANYWHERE. Everything below reads
    VehiclePart:getCondition(), which is vanilla's own value - stored on the part's
    inventory item, saved with the vehicle, replicated by vanilla in multiplayer, and
    written by vanilla's own repair and install actions. This file computes VIEWS of that
    (a system's worst part, the airframe average, a performance factor) and never a
    parallel copy. So if the mechanics panel says the left aileron is at 41%, the HUD says
    41% and the flight model degrades the roll rate by the amount 41% implies, because all
    three asked the same object the same question.

    NAMES LIVE HERE, NOT IN A TRANSLATION FILE. getText("IGUI_VehiclePart" .. id) is a
    GLOBAL key: adding IGUI_VehiclePartTireRearLeft to rename this aircraft's main tyre
    would rename the rear left tyre on every car in the game. That has bitten this author's
    mods before. Every label below is applied by this mod's own UI code, to this vehicle
    only, and no vanilla key is written. New Cessna-only part ids (Propeller, LeftAileron,
    ...) could safely have their own keys, but they are kept here too so there is one place
    to look rather than two.

    SHARED, not client: the flight model, the HUD, the mechanics UI and the server-side
    part callbacks all need it.
]]

C172Parts = C172Parts or {}

C172Parts.SCRIPT = "Base.Cessna172"

-- ------------------------------------------------------------------ safe calls
-- Same discipline as the rest of the mod: never index a Java object without proving the
-- member exists first. pcall does NOT protect Lua from a Kahlua-side failure, so the
-- guard has to come before the call, not around it.
local function call0(obj, name)
    if type(obj) ~= "userdata" and type(obj) ~= "table" then return false, nil end
    local ok, fn = pcall(function() return obj[name] end)
    if not ok or type(fn) ~= "function" then return false, nil end
    return pcall(function() return fn(obj) end)
end

local function call1(obj, name, a)
    if type(obj) ~= "userdata" and type(obj) ~= "table" then return false, nil end
    local ok, fn = pcall(function() return obj[name] end)
    if not ok or type(fn) ~= "function" then return false, nil end
    return pcall(function() return fn(obj, a) end)
end

function C172Parts.isCessna(vehicle)
    if not vehicle then return false end
    local ok, name = call0(vehicle, "getScriptName")
    return ok and name == C172Parts.SCRIPT
end

-- ------------------------------------------------------------------- systems
-- Order here is the order they appear in the panel. `column` picks which of the two
-- vanilla listboxes a system lands in - vanilla hardcodes that split by category name
-- ("door", "bodywork" and "lights" go right, everything else left), which is meaningless
-- for an aircraft, so the Cessna's panel reads it from this table instead.
--
-- Two columns rather than the three in the mockup, because ISVehicleMechanics builds
-- exactly two ISScrollingListBoxes and adding a third would mean rebuilding its layout,
-- its joypad focus order and its width arithmetic - a lot of surface area to break for a
-- column boundary. The systems are split 4/4 so both columns fill evenly.
C172Parts.SYSTEMS = {
    { key = "powerplant",     label = "POWERPLANT",          column = 1 },
    { key = "fuelsystem",     label = "FUEL SYSTEM",         column = 1 },
    { key = "airframe",       label = "AIRFRAME",            column = 1 },
    { key = "flightcontrols", label = "FLIGHT CONTROLS",     column = 1 },
    { key = "landinggear",    label = "LANDING GEAR",        column = 2 },
    { key = "cockpit",        label = "COCKPIT & BODY",      column = 2 },
    { key = "avionics",       label = "ELECTRICAL & LIGHTS", column = 2 },
    { key = "storage",        label = "STORAGE",             column = 2 },
}

-- ---------------------------------------------------------------------- parts
-- id      - the VehiclePart id, exactly as declared in vehicle_cessna172.txt
-- name    - what the player sees, everywhere
-- system  - which block of the panel it appears under
-- order   - position within that block
--
-- The vanilla-id entries are the ones the engine reaches by name (fuel, ignition, the
-- wheel-to-part mapping, seating, containers, lighting). They keep their ids and are
-- relabelled; see this file's header for why that is done here and not in IG_UI.json.
C172Parts.LIST = {
    -- POWERPLANT
    { id = "Engine",                system = "powerplant",     order = 1, name = "Engine" },
    { id = "Propeller",             system = "powerplant",     order = 2, name = "Propeller" },
    { id = "OilSystem",             system = "powerplant",     order = 3, name = "Engine Oil System" },
    { id = "Starter",               system = "powerplant",     order = 4, name = "Starter" },
    { id = "EngineDoor",            system = "powerplant",     order = 7, name = "Engine Cowling" },

    -- FUEL SYSTEM
    { id = "GasTank",               system = "fuelsystem",     order = 1, name = "Fuel Tank" },
    { id = "FuelSystem",            system = "fuelsystem",     order = 2, name = "Fuel System" },

    -- AIRFRAME
    { id = "Fuselage",              system = "airframe",       order = 1, name = "Fuselage" },
    { id = "LeftWing",              system = "airframe",       order = 2, name = "Left Wing" },
    { id = "RightWing",             system = "airframe",       order = 3, name = "Right Wing" },
    { id = "TailAssembly",          system = "airframe",       order = 4, name = "Tail Assembly" },
    { id = "HorizontalStabilizer",  system = "airframe",       order = 5, name = "Horizontal Stabilizer" },

    -- FLIGHT CONTROLS
    { id = "LeftAileron",           system = "flightcontrols", order = 1, name = "Left Aileron" },
    { id = "RightAileron",          system = "flightcontrols", order = 2, name = "Right Aileron" },
    { id = "Elevator",              system = "flightcontrols", order = 3, name = "Elevator" },
    { id = "Rudder",                system = "flightcontrols", order = 4, name = "Rudder" },

    -- LANDING GEAR
    -- ONE nose wheel, not two. PZ requires four wheels and a 172 has three, so
    -- TireFrontLeft/Right are a pair standing in for the single nose wheel; the right half
    -- is `nodisplay` in the script and C172Systems.Update.NoseGearMirror keeps it identical
    -- to the left. Listing both was the last thing here that read as a car with four tyres.
    { id = "TireFrontLeft",         system = "landinggear",    order = 1, name = "Tailwheel" },
    { id = "SuspensionFrontLeft",   system = "landinggear",    order = 2, name = "Tailwheel Spring" },
    { id = "TireRearLeft",          system = "landinggear",    order = 3, name = "Left Main Tire" },
    { id = "TireRearRight",         system = "landinggear",    order = 4, name = "Right Main Tire" },
    { id = "SuspensionRearLeft",    system = "landinggear",    order = 5, name = "Left Main Gear Leg" },
    { id = "SuspensionRearRight",   system = "landinggear",    order = 6, name = "Right Main Gear Leg" },
    { id = "BrakeRearLeft",         system = "landinggear",    order = 7, name = "Left Wheel Brake" },
    { id = "BrakeRearRight",        system = "landinggear",    order = 8, name = "Right Wheel Brake" },

    -- COCKPIT & BODY
    { id = "Windshield",            system = "cockpit",        order = 1, name = "Windshield" },
    { id = "DoorFrontLeft",         system = "cockpit",        order = 2, name = "Left Cabin Door" },
    { id = "DoorFrontRight",        system = "cockpit",        order = 3, name = "Right Cabin Door" },
    { id = "WindowFrontLeft",       system = "cockpit",        order = 4, name = "Left Cabin Window" },
    { id = "WindowFrontRight",      system = "cockpit",        order = 5, name = "Right Cabin Window" },
    { id = "SeatFrontLeft",         system = "cockpit",        order = 6, name = "Pilot Seat" },
    { id = "SeatFrontRight",        system = "cockpit",        order = 7, name = "Passenger Seat" },
    -- The rear bench, added with the aircraft's other two seats. Listed so the mechanics
    -- screen and the HUD show real parts rather than only half the cabin.
    { id = "SeatRearLeft",          system = "cockpit",        order = 8, name = "Left Rear Seat" },
    { id = "SeatRearRight",         system = "cockpit",        order = 9, name = "Right Rear Seat" },

    -- ELECTRICAL & LIGHTS
    -- The four vanilla light parts, repurposed. They are real switchable lights in real
    -- positions - front pair forward, rear pair aft - which is a light aircraft's
    -- landing/taxi and navigation lighting. Nothing about them is faked; only the labels
    -- and the system they are filed under changed.
    -- Battery and Alternator live here, not under POWERPLANT. They were filed with the engine
    -- because that is where a car mod puts them, and the result was a pilot opening
    -- ELECTRICAL & LIGHTS to check the battery and not finding it at all.
    { id = "ElectricalSystem",      system = "avionics",       order = 1, name = "Electrical System" },
    { id = "Battery",               system = "avionics",       order = 2, name = "Battery" },
    { id = "Alternator",            system = "avionics",       order = 3, name = "Alternator" },
    { id = "HeadlightLeft",         system = "avionics",       order = 2, name = "Landing Light" },
    { id = "HeadlightRight",        system = "avionics",       order = 3, name = "Taxi Light" },
    { id = "HeadlightRearLeft",     system = "avionics",       order = 4, name = "Left Navigation Light" },
    { id = "HeadlightRearRight",    system = "avionics",       order = 5, name = "Right Navigation Light" },
    { id = "Radio",                 system = "avionics",       order = 6, name = "Avionics Radio" },

    -- STORAGE
    { id = "TruckBed",              system = "storage",        order = 1, name = "Baggage Compartment" },
    { id = "TrunkDoor",             system = "storage",        order = 2, name = "Baggage Door" },
}

-- id -> entry, built once.
C172Parts.BY_ID = {}
for _, e in ipairs(C172Parts.LIST) do C172Parts.BY_ID[e.id] = e end

-- system key -> ordered list of entries, built once.
C172Parts.BY_SYSTEM = {}
for _, sys in ipairs(C172Parts.SYSTEMS) do C172Parts.BY_SYSTEM[sys.key] = {} end
for _, e in ipairs(C172Parts.LIST) do
    local bucket = C172Parts.BY_SYSTEM[e.system]
    if bucket then table.insert(bucket, e) end
end
for _, bucket in pairs(C172Parts.BY_SYSTEM) do
    table.sort(bucket, function(a, b) return (a.order or 0) < (b.order or 0) end)
end

-- Display name for a part id. Falls back to the id itself rather than to
-- getText("IGUI_VehiclePart" .. id): a part this mod added has no such key, and asking
-- for one would print the raw key into the panel.
function C172Parts.displayName(id)
    local e = C172Parts.BY_ID[id]
    if e then return e.name end
    return id
end

-- ----------------------------------------------------------------- conditions
--
-- ONE reading, from vanilla, for everybody. Returns nil when the part does not exist on
-- this vehicle (so a caller can tell "not fitted to this airframe" apart from "at zero"),
-- and 0 when the part exists but its item has been removed - which is what the mechanics
-- panel itself does, and is the honest answer for a wing that is not on the aeroplane.
function C172Parts.condition(vehicle, id)
    if not vehicle then return nil end
    local okP, part = call1(vehicle, "getPartById", id)
    if not (okP and part) then return nil end
    -- A part with an install table and no item is MISSING, not intact. Vanilla's own
    -- recalculGeneralCondition makes exactly this correction.
    local okT, tbl = call1(part, "getTable", "install")
    if okT and tbl then
        local okI, item = call0(part, "getInventoryItem")
        if not (okI and item) then return 0 end
    end
    local okC, cond = call0(part, "getCondition")
    if okC and type(cond) == "number" then
        if cond < 0 then return 0 end
        if cond > 100 then return 100 end
        return cond
    end
    return nil
end

-- Worst condition across a set of ids, ignoring ids this airframe does not have.
-- nil if none of them exist.
function C172Parts.worstOf(vehicle, ids)
    local worst = nil
    for _, id in ipairs(ids) do
        local c = C172Parts.condition(vehicle, id)
        if c ~= nil and (worst == nil or c < worst) then worst = c end
    end
    return worst
end

-- A system's headline number is its WORST part, not its average. An average hides the one
-- destroyed aileron behind three healthy neighbours, and the destroyed aileron is the fact
-- the pilot needs.
function C172Parts.systemCondition(vehicle, systemKey)
    local bucket = C172Parts.BY_SYSTEM[systemKey]
    if not bucket then return nil end
    local worst = nil
    for _, e in ipairs(bucket) do
        local c = C172Parts.condition(vehicle, e.id)
        if c ~= nil and (worst == nil or c < worst) then worst = c end
    end
    return worst
end

-- Overall aircraft condition: the mean over every part this mod knows about that the
-- airframe actually has. Deliberately the MEAN and not the worst, because it is a summary
-- line rather than a warning - the per-system bars carry the warnings.
function C172Parts.overallCondition(vehicle)
    local total, n = 0, 0
    for _, e in ipairs(C172Parts.LIST) do
        local c = C172Parts.condition(vehicle, e.id)
        if c ~= nil then total = total + c; n = n + 1 end
    end
    if n == 0 then return nil end
    return total / n
end

-- ------------------------------------------------------- performance mapping
--
-- DEGRADATION SHAPE, and why it is this shape.
--
-- A part in good order must behave EXACTLY as it did before this pass - otherwise the
-- flight model has quietly changed for every aircraft in the world, which is not a
-- maintenance feature, it is a nerf. So the curve is flat at 1.0 from 100% down to
-- HEALTHY_ABOVE, and only then begins to fall. Normal wear therefore costs nothing at all,
-- and the brief's "meaningful maintenance without making the aircraft unusable because one
-- component is slightly damaged" is satisfied by construction rather than by tuning.
--
-- Below that it falls linearly to a per-effect FLOOR at zero condition. The floor is never
-- 0 for anything that would strand the player: a destroyed rudder still yaws, badly. The
-- one exception is the propeller, which is handled separately and explicitly, because an
-- aeroplane with no propeller genuinely has no thrust and pretending otherwise would be
-- the sort of decorative lie this pass exists to remove.
C172Parts.HEALTHY_ABOVE = 70

-- cond 0..100 -> 1.0 above HEALTHY_ABOVE, falling linearly to `floor` at 0.
-- A missing part (cond nil) reads as HEALTHY: the aircraft may simply not have it.
function C172Parts.factor(cond, floor)
    if cond == nil then return 1.0 end
    if cond >= C172Parts.HEALTHY_ABOVE then return 1.0 end
    local t = cond / C172Parts.HEALTHY_ABOVE          -- 0 at destroyed, 1 at the threshold
    return floor + (1.0 - floor) * t
end

-- The full effect set, recomputed from live part conditions. Callers cache it (see
-- C172Parts.effects below) - this walks ~20 parts and is not something to do per tick.
local function computeEffects(vehicle)
    local P = C172Parts
    local e = {}

    local engine    = P.condition(vehicle, "Engine")
    local prop      = P.condition(vehicle, "Propeller")
    local oil       = P.condition(vehicle, "OilSystem")
    local fuelSys   = P.condition(vehicle, "FuelSystem")
    local ailerons  = P.worstOf(vehicle, { "LeftAileron", "RightAileron" })
    local elevator  = P.condition(vehicle, "Elevator")
    local rudder    = P.condition(vehicle, "Rudder")
    local wings     = P.worstOf(vehicle, { "LeftWing", "RightWing" })
    local fuselage  = P.condition(vehicle, "Fuselage")
    local hstab     = P.condition(vehicle, "HorizontalStabilizer")
    local tail      = P.condition(vehicle, "TailAssembly")
    local gear      = P.worstOf(vehicle, { "TireFrontLeft", "TireFrontRight",
                                           "TireRearLeft", "TireRearRight",
                                           "SuspensionFrontLeft", "SuspensionFrontRight",
                                           "SuspensionRearLeft", "SuspensionRearRight" })
    local elec      = P.worstOf(vehicle, { "ElectricalSystem", "Alternator", "Battery" })

    -- NO PROPELLER, NO THRUST. Not a factor - a hard fact, and the only hard one here.
    e.propellerFitted = (prop ~= nil) and (prop > 0)

    -- THRUST. Engine and propeller dominate; oil and fuel delivery are secondary, so a
    -- neglected oil system is a nagging loss of performance rather than a grounding.
    e.thrust = P.factor(engine,  0.50)
             * P.factor(prop,    0.45)
             * P.factor(oil,     0.80)
             * P.factor(fuelSys, 0.70)
    if not e.propellerFitted then e.thrust = 0.0 end

    -- TOP SPEED. Structural: a damaged wing or fuselage is draggy and cannot be flown to
    -- the same numbers. Floors are high on purpose - this multiplies the whole envelope.
    e.maxSpeed = P.factor(wings,    0.72)
               * P.factor(fuselage, 0.85)

    -- ROLL / TURN AUTHORITY. The ailerons are the control; the wing is what they are
    -- mounted on, so a wrecked wing costs some authority even with a perfect aileron.
    e.roll = P.factor(ailerons, 0.40)
           * P.factor(wings,    0.85)

    -- PITCH: elevator on its stabiliser. Governs climb and descent rate.
    e.pitch = P.factor(elevator, 0.45)
            * P.factor(hstab,    0.75)

    -- YAW: rudder on its fin. Feeds heading stability rather than the commanded turn.
    e.yaw = P.factor(rudder, 0.55)
          * P.factor(tail,   0.80)

    -- GROUND HANDLING: taxi and landing. Never below half - a bad landing should be hard,
    -- not impossible, and this is the number a pilot meets at the worst possible moment.
    e.ground = P.factor(gear, 0.50)

    -- ELECTRICAL: lights and the instrument panel.
    e.electrical = P.factor(elec, 0.30)

    -- Worst single reading among the parts that can actually stop the aeroplane. Used by
    -- the HUD for its master caution, so the pilot gets one number to watch.
    e.critical = math.min(P.factor(engine, 0), P.factor(prop, 0), P.factor(fuelSys, 0),
                          P.factor(ailerons, 0), P.factor(elevator, 0))
    return e
end

-- Cached per vehicle id, recomputed at most every EFFECTS_TTL seconds. Part conditions
-- change on the timescale of a repair action or a crash, never within a tick, so a cache
-- this coarse is exact for every purpose that reads it - and it keeps ~20 Java calls out
-- of the flight hot path.
local effectsCache = {}
C172Parts.EFFECTS_TTL = 1.0

local function nowSec()
    local ok, ms = pcall(function() return getTimestampMs() end)
    if ok and type(ms) == "number" then return ms / 1000 end
    return os.time()
end

function C172Parts.effects(vehicle, force)
    if not vehicle then return nil end
    local okId, id = call0(vehicle, "getId")
    if not okId then return nil end
    local now = nowSec()
    local c = effectsCache[id]
    if (not force) and c and (now - c.at) < C172Parts.EFFECTS_TTL then return c.e end
    local ok, e = pcall(computeEffects, vehicle)
    if not ok or type(e) ~= "table" then
        -- Never hand a caller a nil effect set mid-flight: an unmodified aircraft is the
        -- safe answer, and it is what every flight constant was tuned against.
        e = { propellerFitted = true, thrust = 1, maxSpeed = 1, roll = 1, pitch = 1,
              yaw = 1, ground = 1, electrical = 1, critical = 1 }
    end
    effectsCache[id] = { at = now, e = e }
    return e
end

-- Called by the mechanics UI after a repair/install/uninstall so the HUD and the flight
-- model see the change immediately rather than up to EFFECTS_TTL later.
function C172Parts.invalidate(vehicle)
    if not vehicle then return end
    local okId, id = call0(vehicle, "getId")
    if okId and id then effectsCache[id] = nil end
end

-- A world reload must not carry a previous session's cache.
if Events and Events.OnGameStart then
    Events.OnGameStart.Add(function() effectsCache = {} end)
end

-- ------------------------------------------------------------- hour meters
--
-- READ-ONLY VIEWS of numbers written on the authoritative side (see
-- C172Systems.Update.Engine and C172Server.lua's trackAirborneTime). They live on a PART's
-- modData rather than the vehicle's, because transmitPartModData() is the only
-- replication vanilla offers for arbitrary data on a vehicle - so these reach an MP client
-- through vanilla's own netcode, and they are saved and reloaded with the vehicle.
--
-- nil means "no meter", which is different from zero and is what a caller should show as a
-- dash rather than as 0.0 h: a Fuselage that has never been fitted has no logbook.
local function partHours(vehicle, partId, key)
    if not vehicle then return nil end
    local okP, part = call1(vehicle, "getPartById", partId)
    if not (okP and part) then return nil end
    local okD, md = call0(part, "getModData")
    if not (okD and md) then return nil end
    local v = tonumber(md[key])
    if type(v) ~= "number" or v ~= v or v < 0 then return nil end
    return v
end

function C172Parts.engineHours(vehicle)
    return partHours(vehicle, "Engine", "c172EngineHours")
end

function C172Parts.airframeHours(vehicle)
    return partHours(vehicle, "Fuselage", "c172AirframeHours")
end

-- ------------------------------------------------------- container readouts
-- Fuel and baggage, straight off the vanilla container the part already owns.
-- Returns amount, capacity, fraction - or nil when the part is absent.
function C172Parts.containerLevel(vehicle, partId)
    if not vehicle then return nil end
    local okP, part = call1(vehicle, "getPartById", partId)
    if not (okP and part) then return nil end
    local okA, amount = call0(part, "getContainerContentAmount")
    local okC, cap = call0(part, "getContainerCapacity")
    if not (okA and okC) then return nil end
    if type(amount) ~= "number" or type(cap) ~= "number" or cap <= 0 then return nil end
    return amount, cap, math.max(0, math.min(1, amount / cap))
end

return C172Parts
