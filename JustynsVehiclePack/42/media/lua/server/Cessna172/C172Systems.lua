--[[
    C172Systems - the SERVER-SIDE part callbacks that give the Cessna's aircraft-only
    components real consequences.

    WHY SERVER-SIDE. A VehiclePart's `lua { update = ..., checkEngine = ... }` functions are
    resolved as globals and invoked by the game on the side that owns the vehicle - the
    server in multiplayer, the host in singleplayer. They must therefore live under
    media/lua/server, the same place C172Fuel.UpdateGasTank already does, or they will
    simply never be found on a dedicated server and the consequence will silently not
    happen. (A missing script lua function is not an error in PZ; it is a no-op, which is
    the worst possible failure mode for something like this.)

    WHAT IS DELIBERATELY *NOT* DONE HERE, and why it matters:

      * checkEngine is used on the FUEL SYSTEM AND NOTHING ELSE. That callback is not a
        "can this engine start" test, whatever its name suggests - decompiling
        VehicleEngine shows isEngineWorking() (which is the OR over every part's
        checkEngine) is consulted in exactly one place, shouldAutoShutDown(), and only
        while the engine is already Running. So a false answer STOPS A RUNNING ENGINE.
        That is right for fuel starvation and wrong for everything else: a broken starter
        or a dead alternator does not stop a running Cessna, and wiring either of them to
        checkEngine would cut the engine in flight. Fuel delivery is the only failure that
        genuinely does.

      * The propeller has no checkEngine either. An engine with no propeller still runs;
        it just produces no thrust. That is modelled where it belongs, in the flight
        model's thrust term (C172Parts.effects().propellerFitted), not by pretending the
        engine has died.

    EVERYTHING HERE READS AND WRITES VANILLA STATE ONLY - part condition and battery
    charge - and transmits every write, so a dedicated server, a client and a save file all
    agree without this mod inventing any replication of its own.
]]

require "Cessna172/C172Parts"
require "Cessna172/C172Util"   -- getFlightState, used by the zombie-damage gate

C172Systems = C172Systems or {}
C172Systems.CheckEngine = C172Systems.CheckEngine or {}
C172Systems.Update = C172Systems.Update or {}

local function call0(obj, name)
    if type(obj) ~= "userdata" and type(obj) ~= "table" then return false, nil end
    local ok, fn = pcall(function() return obj[name] end)
    if not ok or type(fn) ~= "function" then return false, nil end
    return pcall(function() return fn(obj) end)
end

-- ------------------------------------------------------------- fuel delivery
--
-- The tank can be full and the engine still starve: lines, gascolator, selector and the
-- boost pump are a separate failure. This returns false ONLY when the fuel system is
-- physically absent or destroyed - never for ordinary wear - so it can never surprise a
-- pilot whose aircraft is merely tired. Partial damage instead costs thrust, in
-- C172Parts.effects().
--
-- The visible behaviour of a destroyed fuel system is that the engine will crank, catch,
-- and die again a moment later. That is what fuel starvation looks like, it is legible,
-- and the mechanics panel names the cause in plain language at 0%.
function C172Systems.CheckEngine.FuelSystem(vehicle, part)
    if not part then return true end
    local okI, item = call0(part, "getInventoryItem")
    if not (okI and item) then return false end     -- not fitted: no fuel reaches the engine
    local okC, cond = call0(part, "getCondition")
    if okC and type(cond) == "number" and cond <= 0 then return false end
    return true
end

-- ------------------------------------------------------------- electrical bus
--
-- A damaged bus and a damaged alternator both mean the battery is being drained rather
-- than kept up. Rather than invent a new "electrical charge" number - which would be
-- exactly the parallel fake system this pass exists to eliminate - this drains the
-- BATTERY, which is vanilla's own value: it is stored on the battery item, saved,
-- replicated, shown in the mechanics panel and the dashboard, and already gates starting
-- (BaseVehicle's ignition path calls engineDoStartingFailedNoPower when it is flat).
--
-- So "damaged electrics make the aircraft hard to start" is implemented by making the
-- damage do the thing that really causes it, and every downstream system picks it up for
-- free, including on a dedicated server.
--
-- Rates are deliberately slow. At 0% condition this is 0.0006 per in-game minute against
-- vanilla's 0.001-per-minute recharge from a running engine, so a running aircraft still
-- charges (a Cessna with a sick alternator is flyable) but a parked one goes flat over a
-- couple of in-game days and has to be dealt with. Nothing here can flatten a battery
-- inside a single flight.
local ELEC_DRAIN_PER_MINUTE = 0.0006

function C172Systems.Update.Electrical(vehicle, part, elapsedMinutes)
    if not (vehicle and part) then return end
    -- Not while simulated as a VirtualVehicle (see C172Systems.Update.Engine): resumes on reload.
    if not instanceof(vehicle, "BaseVehicle") then return end
    if type(elapsedMinutes) ~= "number" or elapsedMinutes <= 0 then return end

    -- Ordinary wear on the bus itself, same helper vanilla uses for suspension/muffler, so
    -- this part ages like every other part rather than staying pristine forever.
    if Vehicles and Vehicles.LowerCondition then
        pcall(function() Vehicles.LowerCondition(vehicle, part, elapsedMinutes) end)
    end

    local okC, cond = call0(part, "getCondition")
    if not (okC and type(cond) == "number") then return end
    local okI, item = call0(part, "getInventoryItem")
    local fitted = okI and item ~= nil
    -- Not fitted at all is the worst case, and is treated as condition 0.
    local health = fitted and cond or 0
    if health >= C172Parts.HEALTHY_ABOVE then return end   -- healthy: no drain at all

    local severity = 1 - (health / C172Parts.HEALTHY_ABOVE)   -- 0 at the threshold, 1 at dead
    local drain = ELEC_DRAIN_PER_MINUTE * severity * elapsedMinutes
    if drain <= 0 then return end

    local okB, battery = pcall(function() return vehicle:getPartById("Battery") end)
    if not (okB and battery) then return end
    local okBI, bItem = call0(battery, "getInventoryItem")
    if not (okBI and bItem) then return end

    local okCh, charge = pcall(function() return bItem:getCurrentUsesFloat() end)
    if not (okCh and type(charge) == "number") then return end
    local newCharge = math.max(0, charge - drain)
    if newCharge == charge then return end

    pcall(function() bItem:setUsedDelta(newCharge) end)
    -- Same transmit discipline as Vehicles.Update.Battery: only send when the value has
    -- actually moved at the precision the network cares about, or a slow drain would push
    -- a packet every single update tick.
    if VehicleUtils and VehicleUtils.compareFloats
            and VehicleUtils.compareFloats(charge, newCharge, 2) then
        pcall(function() vehicle:transmitPartUsedDelta(battery) end)
    end
end

-- =========================================================== HOUR METERS
--
-- ENGINE HOURS AND AIRFRAME (FLIGHT) HOURS ARE REAL, NOT DECORATION. The brief was
-- explicit that these must not be faked, so both are accumulated from something the game
-- actually knows, stored where vanilla already persists and replicates it, and never
-- estimated or back-filled.
--
-- WHERE THEY LIVE: on a PART's modData, not the vehicle's. BaseVehicle exposes
-- transmitPartModData() and has no vehicle-level equivalent, so a part is the only place
-- a value can be both saved with the world AND pushed to other clients through vanilla's
-- own replication. Engine hours go on the Engine (which is what a Hobbs meter counts) and
-- airframe hours on the Fuselage (which is what an airframe logbook counts). Both survive
-- a save, a server restart and a part being repaired; both would correctly reset if that
-- part were ever replaced, which is also true of the real instruments.
--
-- HOW THEY ARE COUNTED:
--   Engine hours   from elapsedMinutes in this part update while isEngineRunning(). That
--                  is the game's own clock, delivered by the game, on the authoritative
--                  side. Exact in singleplayer and on a dedicated server alike.
--   Airframe hours from time spent NOT on the ground. The authoritative side cannot see
--                  this mod's airborne state directly - the airborne registry is
--                  client-side - so it is taken from the two places that ARE authoritative
--                  on each configuration:
--                    singleplayer  the persisted C172FlightData.mode on the vehicle, which
--                                  the in-process client writes and this code reads in the
--                                  same process (see below);
--                    multiplayer   C172Server.lua, which already receives and VALIDATES a
--                                  flightUpdate from the confirmed driver every 0.5 s and
--                                  can therefore integrate real airborne time server-side.
--                  Both funnel into addAirframeMinutes() so there is one accumulator and
--                  one storage location, not two that could disagree.
--
-- TRANSMIT THROTTLING: a tenth of an hour, which is also the resolution a real Hobbs meter
-- reads to. Without it this would push a packet on every part update forever.
local TRANSMIT_EPSILON_HOURS = 0.1

local function bumpHours(vehicle, partId, key, hours)
    if hours <= 0 then return end
    local okP, part = pcall(function() return vehicle:getPartById(partId) end)
    if not (okP and part) then return end
    local okD, md = pcall(function() return part:getModData() end)
    if not (okD and md) then return end
    local prev = tonumber(md[key]) or 0
    local now = prev + hours
    md[key] = now
    if math.floor(now / TRANSMIT_EPSILON_HOURS) ~= math.floor(prev / TRANSMIT_EPSILON_HOURS) then
        pcall(function() vehicle:transmitPartModData(part) end)
    end
end

-- Shared by the singleplayer path below and by C172Server.lua's multiplayer path.
function C172Systems.addAirframeMinutes(vehicle, minutes)
    if not (vehicle and type(minutes) == "number") then return end
    if minutes <= 0 or minutes ~= minutes then return end
    bumpHours(vehicle, "Fuselage", "c172AirframeHours", minutes / 60.0)
end

-- Chains vanilla's engine temperature model rather than replacing it - that model is what
-- makes a bad cowling or a missing heater cook the engine, and none of it is this mod's to
-- reimplement. The hour meters are appended after it.
-- ============================================== zombies damaging the airframe
--
-- WHY THIS IS DONE IN LUA INSTEAD OF THROUGH THE THUMP PATH.
--
-- The first attempt made the grounded aircraft "thumpable" - the interface PZ uses for things
-- zombies can beat on - by returning it from BaseVehicle.getThumpableFor. That was reasonable
-- and it does not work, for a reason only visible in the zombie AI's own bytecode:
--
--   * In stock B42, BaseVehicle.getThumpableFor is `aconst_null; areturn` for EVERY vehicle.
--   * IsoZombie's thumpable search walks SQUARE objects and tests them for IsoDoor and
--     IsoWindow. Vehicles are IsoMovingObjects and are never in that list.
--   * Every call IsoZombie makes on a BaseVehicle is getUseablePart, triggerAlarm,
--     isCharacterAdjacentTo, getIntersectPoint and similar - it never asks a vehicle for a
--     thumpable and never calls Thump on one.
--
-- So zombies in Build 42 cannot damage any vehicle at all, and no amount of answering a
-- question they never ask will change that. The damage therefore has to be applied by this
-- mod: count the zombies actually standing against the aircraft and chip the airframe.
--
-- SERVER SIDE, and this is the part worth being clear about: part conditions are world state
-- that every player must agree on. If this ran on the client, then in multiplayer each
-- connected player would run it on their own machine and all of them would damage the same
-- aeroplane - four players watching means four times the damage - and a dedicated server,
-- which has no client at all, would apply none. Running it in the part update means exactly
-- one machine decides, and transmitPartCondition then tells everyone else the new value.
-- RATE. Damage is accumulated as a FRACTION and only spent when it reaches a whole condition
-- point, because part condition is an integer: subtracting 1 per pass per zombie was the
-- coarsest possible rate and a handful of zombies stripped the airframe in seconds.
--
-- 0.05 per adjacent zombie per pass means one zombie needs twenty passes to cost a single
-- point, while a pack of ten still does real damage - the horde matters, one wanderer barely
-- does. The accumulator lives on the vehicle's own modData so it survives across updates and
-- is per-aircraft rather than global.
local ZOMBIE_DAMAGE_PER_ZOMBIE = 0.05   -- fractional condition points, per zombie, per pass
local ZOMBIE_DAMAGE_MAX_PER_PASS = 0.4  -- cap per pass so a huge horde is fast, not instant
local ZOMBIE_ACCUM_KEY = "c172ZombieChip"

-- WHICH PART TAKES THE HIT, IN ORDER.
--
-- All five airframe parts are replaceable - each declares an itemType with
-- specificItem = false, so a salvaged one of the right kind fits. But sending every hit into
-- the Fuselage meant the single most awkward part to source was always the one that broke,
-- and nothing else ever did.
--
-- Damage now goes to the first part in this list that still has condition left, so zombies
-- chew through the aircraft the way they would reach it: the wings and tail surfaces they can
-- actually stand against go first, each one breaking and becoming replaceable in turn, and the
-- Fuselage is last - by which point the aeroplane has been left in a horde for a very long
-- time and deserves to be a wreck.
--
-- The HUD's AIRFRAME bar is systemCondition("airframe"), the WORST part in the system, so it
-- starts moving on the first wing and keeps falling as each part is worked through.
local ZOMBIE_TARGET_PARTS = {
    "LeftWing", "RightWing", "HorizontalStabilizer", "TailAssembly", "Fuselage",
}

-- The first listed part that still has condition, or nil when the airframe is finished.
local function nextZombieTarget(vehicle)
    for i = 1, #ZOMBIE_TARGET_PARTS do
        local id = ZOMBIE_TARGET_PARTS[i]
        local okP, part = pcall(function() return vehicle:getPartById(id) end)
        if okP and part then
            local okC, cond = pcall(function() return part:getCondition() end)
            if okC and type(cond) == "number" and cond > 0 then return part, cond, id end
        end
    end
    return nil
end

local function countAdjacentZombies(vehicle)
    local n = 0
    pcall(function()
        local sq = vehicle:getSquare()
        local cell = getCell()
        if not (sq and cell) then return end
        local x, y, z = sq:getX(), sq:getY(), sq:getZ()
        -- The aircraft is far bigger than one tile, so a 5x5 block around its centre is a
        -- fair approximation of "against the aeroplane" without scanning the world.
        for dx = -2, 2 do
            for dy = -2, 2 do
                local s = cell:getGridSquare(x + dx, y + dy, z)
                if s then
                    local objs = s:getMovingObjects()
                    if objs then
                        for i = 0, objs:size() - 1 do
                            local o = objs:get(i)
                            if o and instanceof(o, "IsoZombie") then n = n + 1 end
                        end
                    end
                end
            end
        end
    end)
    return n
end

local function zombiesChipAirframe(vehicle)
    -- Airborne aircraft are untouchable; that guarantee stays exactly as it was.
    --
    -- Read from the mod's own per-vehicle flight state rather than the Java bridge: the only
    -- airborne global exposed to Lua is c172IsAirborne(), which is a WORLD flag meaning "some
    -- Cessna somewhere is flying". Using that here would make one aircraft in the air protect
    -- every other Cessna parked on the ground.
    local okA, st = pcall(function() return C172Util.getFlightState(vehicle) end)
    if okA and st and st.mode and st.mode ~= "GROUND" then return end

    local n = countAdjacentZombies(vehicle)
    if n <= 0 then return end

    -- NO FLOOR. Each part can be taken all the way to 0 and genuinely broken; an aircraft left
    -- parked in a horde long enough should not survive on a technicality.
    local part, cond, partId = nextZombieTarget(vehicle)
    if not part then return end          -- whole airframe already destroyed

    local okD, md = pcall(function() return vehicle:getModData() end)
    if not (okD and md) then return end

    local add = math.min(n * ZOMBIE_DAMAGE_PER_ZOMBIE, ZOMBIE_DAMAGE_MAX_PER_PASS)
    local accum = (tonumber(md[ZOMBIE_ACCUM_KEY]) or 0) + add
    if accum < 1.0 then
        md[ZOMBIE_ACCUM_KEY] = accum
        return                               -- not a whole point yet
    end

    local spend = math.floor(accum)
    md[ZOMBIE_ACCUM_KEY] = accum - spend
    local now = math.max(0, cond - spend)
    if now >= cond then return end
    pcall(function() part:setCondition(now) end)
    -- Without this the change is local and no other client's HUD bar moves.
    pcall(function() vehicle:transmitPartCondition(part) end)
    if now <= 0 then
        print(("[Cessna172] zombies destroyed the %s - it must be replaced (%d still adjacent)")
            :format(tostring(partId), n))
    end
end

-- ============================================== engine noise -> zombies
--
-- WHY THIS IS NEEDED. Zombies are drawn to vehicles by the world SOUND a running engine emits,
-- not by the audio the player hears. This mod deliberately closes off every vanilla car sound
-- event (see the VehicleSounds note in cessna172_sounds.txt) so the aircraft does not sound
-- like a car - and that silenced the zombie-facing noise along with it. A 180-horsepower
-- aero engine that no zombie can hear is wrong in both directions: it makes the aircraft a
-- safe place to idle, and it removes the main reason to think before starting up.
--
-- RADIUS. Vanilla's loudest trap uses addSound(obj, x, y, z, 40, 10). An aeroplane engine is
-- considerably louder than that, and the request was specifically that it carry about a street
-- block - which in this map is roughly 25-35 tiles - so 55 comfortably covers a block and a
-- bit beyond. Volume is what decides how strongly a zombie commits to it.
--
-- IT SCALES WITH POWER, because idling on the apron and climbing at full throttle should not
-- be equally alarming.
--
-- SERVER SIDE, deliberately. Zombie attraction is world state: emitting it from a client would
-- either do nothing on a dedicated server or, worse, fire once per connected client and pull
-- the whole map in. This runs in the Engine part update, which is server-owned and already
-- gated on the engine actually running.
local NOISE_RADIUS_IDLE   = 40
local NOISE_RADIUS_POWER  = 55
local NOISE_VOLUME_IDLE   = 25
local NOISE_VOLUME_POWER  = 55

local function emitEngineNoise(vehicle)
    pcall(function()
        if type(addSound) ~= "function" then return end
        local sq = vehicle:getSquare()
        if not sq then return end

        -- Power fraction from the engine's own speed, so it tracks the throttle rather than a
        -- guess. Falls back to idle values if the reading is unavailable.
        local frac = 0
        local okS, rpm = pcall(function() return vehicle:getEngineSpeed() end)
        if okS and type(rpm) == "number" and rpm > 0 then
            frac = math.min(1.0, rpm / 3000.0)
        end

        local radius = math.floor(NOISE_RADIUS_IDLE
                                  + (NOISE_RADIUS_POWER - NOISE_RADIUS_IDLE) * frac + 0.5)
        local volume = math.floor(NOISE_VOLUME_IDLE
                                  + (NOISE_VOLUME_POWER - NOISE_VOLUME_IDLE) * frac + 0.5)
        addSound(vehicle, sq:getX(), sq:getY(), sq:getZ(), radius, volume)
    end)
end

-- ============================================== the alternator
--
-- WHY THIS IS THE FIX FOR "LIGHTS STOP WORKING ONCE AIRBORNE", AND WHY IT IS HERE.
--
-- Vanilla's Vehicles.Update.Headlight switches EVERY light off the instant the battery reads
-- zero, and it drains the battery the whole time a light is on without the engine running. A
-- long flight with the lights on therefore flattens the battery and the lights all die at
-- once - which is exactly the reported symptom.
--
-- Two earlier attempts fixed it by overriding the light parts' own `update` to ignore the
-- battery. Both made the game UNLOADABLE: a part update runs once per part, per vehicle, per
-- tick, during world load as well as play, so anything unreliable in there throws thousands of
-- times before the world finishes loading - and pcall does not help, because "Break On Error"
-- halts on a thrown error whether or not it is caught.
--
-- So vanilla's light rule is left completely alone and the CAUSE is fixed instead: the engine
-- charges the battery, which is what an alternator does. With the battery never reaching zero
-- while the engine runs, vanilla never switches the lights off, and nothing about the light
-- code is touched at all.
--
-- IT IS DELIBERATELY BUILT FROM PROVEN LINES. Every call below is copied from the electrical
-- drain function already in this file - getPartById("Battery") -> getInventoryItem() ->
-- getCurrentUsesFloat() / setUsedDelta - which ships today and loads today. No new API is
-- introduced, in particular NOT vehicle:getBatteryCharge() or vehicle:getBattery(), and this
-- runs inside C172Systems.Update.Engine, an update hook that is already known to be safe.
--
-- RATE. 0.004 per minute of game time reaches a full charge in a few in-game hours from empty
-- and comfortably outpaces vanilla's 0.000025/min lighting drain, so the lights stay on
-- indefinitely with the engine running. It is capped at 1.0 and never charges with the engine
-- off, so a parked aircraft still goes flat exactly as before and the aeroplane can still be
-- left un-startable by leaving the lights on.
local ALTERNATOR_PER_MINUTE = 0.004

local function runAlternator(vehicle, elapsedMinutes)
    if type(elapsedMinutes) ~= "number" or elapsedMinutes <= 0 then return end

    local okB, battery = pcall(function() return vehicle:getPartById("Battery") end)
    if not (okB and battery) then return end
    local okBI, bItem = call0(battery, "getInventoryItem")
    if not (okBI and bItem) then return end

    local okCh, charge = pcall(function() return bItem:getCurrentUsesFloat() end)
    if not (okCh and type(charge) == "number") then return end
    if charge >= 1.0 then return end

    local newCharge = math.min(1.0, charge + ALTERNATOR_PER_MINUTE * elapsedMinutes)
    if newCharge == charge then return end
    pcall(function() bItem:setUsedDelta(newCharge) end)

    -- Same transmit discipline as the drain above: only send when the value has actually
    -- moved at the precision the network cares about.
    if VehicleUtils and VehicleUtils.compareFloats
            and VehicleUtils.compareFloats(charge, newCharge, 2) then
        pcall(function() vehicle:transmitPartUsedDelta(battery) end)
    end
end

function C172Systems.Update.Engine(vehicle, part, elapsedMinutes)
    if Vehicles and Vehicles.Update and Vehicles.Update.Engine then
        pcall(function() Vehicles.Update.Engine(vehicle, part, elapsedMinutes) end)
    end
    if not (vehicle and part) then return end
    -- 1.10.3: a lapsed "flying clear" report puts the server's ground footprint back (C172ServerContacts)
    if C172ServerContacts and C172ServerContacts.small then pcall(C172ServerContacts.check) end
    if type(elapsedMinutes) ~= "number" or elapsedMinutes <= 0 then return end
    -- A VIRTUAL VEHICLE (42.20): an aircraft far enough away is simulated by
    -- VirtualVehicleManager, which runs this same part update with a zombie.vehicles.VirtualVehicle
    -- - it has the parts, engine and position, but no modData, so getFlightState below threw
    -- "Object tried to call nil" (Jay, 09-25, getting into the VX-9 after flying the Cessna). Vanilla's
    -- engine update above already ran; everything after this line is ours and needs the real vehicle.
    if not instanceof(vehicle, "BaseVehicle") then return end

    -- Zombie clawing applies with the engine off too - a parked aeroplane is exactly what a
    -- horde gets to work on - so this sits outside the engine-running branch below.
    zombiesChipAirframe(vehicle)

    local okR, running = pcall(function() return vehicle:isEngineRunning() end)
    if okR and running then
        -- The alternator. Engine turning = battery charging = vanilla never blacks the lights.
        runAlternator(vehicle, elapsedMinutes)

        -- And the noise that draws zombies. Same gate: only while it is actually running.
        emitEngineNoise(vehicle)

        local okD, md = pcall(function() return part:getModData() end)
        if okD and md then
            local prev = tonumber(md.c172EngineHours) or 0
            local now = prev + elapsedMinutes / 60.0
            md.c172EngineHours = now
            if math.floor(now / TRANSMIT_EPSILON_HOURS)
                    ~= math.floor(prev / TRANSMIT_EPSILON_HOURS) then
                pcall(function() vehicle:transmitPartModData(part) end)
            end
        end
    end

    -- SINGLEPLAYER AIRFRAME HOURS. isClient() is true only on a multiplayer CLIENT, so
    -- `not isClient()` covers both singleplayer and the dedicated server. The extra
    -- isServer() exclusion is what keeps this from double-counting: on a dedicated server
    -- C172Server.lua is already integrating airborne time from the validated flightUpdate
    -- stream, and the persisted mode read below is not authoritative there anyway (the
    -- flying client writes it into ITS copy of the vehicle's modData).
    if isClient() or isServer() then return end
    local okS, st = pcall(function()
        local d = vehicle:getModData()
        return d and d.C172FlightData
    end)
    if okS and st and st.mode and st.mode ~= "GROUND" then
        C172Systems.addAirframeMinutes(vehicle, elapsedMinutes)
    end
end

-- ======================================================= NOSE GEAR MIRROR
--
-- The Cessna carries TWO physics wheels at the nose because PZ demands four and a 172 has
-- three. They are one wheel as far as the aircraft, the model and the player are concerned,
-- so the right-hand half is `nodisplay` in the vehicle script and this keeps it identical
-- to the left-hand half.
--
-- WHY THIS IS NOT COSMETIC. Vanilla's Vehicles.Update.Tire wears a tyre down with speed and
-- steering, and tyre condition and air pressure both feed grip. A hidden nose tyre left to
-- degrade on its own would silently change how the aircraft handles on the ground, with
-- nothing in the UI to show it and no way to service it. Mirroring makes "service the nose
-- wheel" service the nose wheel.
--
-- Chained onto the LEFT part's update, because that is the part that always ticks and it
-- is where the authoritative value lives. Writes only on a real difference, and transmits
-- only then, so a settled aircraft costs one comparison per update.
function C172Systems.Update.NoseGearMirror(vehicle, part, elapsedMinutes)
    if Vehicles and Vehicles.Update and Vehicles.Update.Tire then
        pcall(function() Vehicles.Update.Tire(vehicle, part, elapsedMinutes) end)
    end
    if not (vehicle and part) then return end

    local okT, twin = pcall(function() return vehicle:getPartById("TireFrontRight") end)
    if not (okT and twin) then return end

    -- CONDITION
    local okC, cond = call0(part, "getCondition")
    local okTC, twinCond = call0(twin, "getCondition")
    if okC and okTC and type(cond) == "number" and cond ~= twinCond then
        pcall(function() twin:setCondition(cond) end)
        pcall(function() vehicle:transmitPartCondition(twin) end)
    end

    -- TYRE PRESSURE. Same reasoning: a hidden flat is still a flat.
    local okA, amount = call0(part, "getContainerContentAmount")
    local okTA, twinAmount = call0(twin, "getContainerContentAmount")
    if okA and okTA and type(amount) == "number" and math.abs(amount - (twinAmount or 0)) > 0.01 then
        -- (amount, doTransmit, doSetCondition) - the same three-argument form vanilla's own
        -- Vehicles.Create.Tire uses, so the container is updated the way the game expects.
        pcall(function() twin:setContainerContentAmount(amount, true, true) end)
    end
end

return C172Systems
