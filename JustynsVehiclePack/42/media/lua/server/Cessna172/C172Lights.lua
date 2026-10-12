--[[
    C172Lights - real navigation, landing and taxi lights for the Cessna 172.

    ============================ WHAT THIS REPLACES ============================

    The four light parts were already repurposed and correctly NAMED - Landing Light, Taxi
    Light, Left/Right Navigation Light - but they were still four vanilla CAR lights: two
    white cones pointing forward and two dim red ones pointing aft, because that is what
    VehicleUtils.initHeadlight builds for HeadlightLeft/Right/RearLeft/RearRight. A red light
    on the right wingtip is not a navigation light, it is a brake light, and an aeroplane
    wearing one is wrong in a way pilots notice immediately.

    ============================ WHY THIS IS NOT A HACK ============================

    VehiclePart.createSpotLightColor(x, y, distance, intensity, dot, focusing, r, g, b) is a
    real, public part API, and vanilla itself uses it - Vehicles.lua's initHeadlight calls it
    to make the rear pair red. Everything below is the same call with aircraft positions and
    aircraft colours. Nothing is drawn by this mod, no light is faked, and no shared script
    object is mutated.

    VANILLA IS CALLED FIRST, DELIBERATELY. initHeadlight creates the part's inventory item and
    is where PZ's own condition scaling lives ("distance/intensity vary between 50% and 100%
    of the given value based on part condition" - its own comment). Calling it and then
    REPLACING the light keeps every bit of that: a smashed nav light still dims correctly, a
    missing bulb still means no light, and Vehicles.Update.Headlight still drains the battery.
    Writing a light from scratch would have quietly dropped all of it.

    ============================ THE COLOURS ============================

    Aviation position lights are standardised and not a style choice:
      LEFT (port) wingtip   RED
      RIGHT (starboard)     GREEN
    They are deliberately DIM and SHORT-RANGE. Position lights exist to be seen from outside,
    not to illuminate anything, and a wingtip that throws a four-metre pool of coloured light
    onto the ground would look like a floodlight. The landing light is the bright one.

    +X IS THE PILOT'S LEFT in this model's frame (see the axis note in
    vehicle_cessna172.txt), and vanilla's own convention in initHeadlight agrees: it passes
    +xOffset for HeadlightLeft and -xOffset for HeadlightRight. +Y is forward.

    Wingtips sit at x = +-3.19 (half of the 6.384 span), pulled in slightly to 3.0 so the
    light sits on the wing rather than hanging off the end of it.

    SP / MP. This file is in server/, which is where every other Vehicles.Create.* callback
    lives, so it runs on whichever side owns the vehicle - the host in singleplayer and coop,
    the server process on a dedicated box. The light state itself is vanilla's and replicates
    through vanilla's own netcode; nothing here is client-only and nothing is sent by hand.
]]

require "Cessna172/C172LightSpecs"

C172Lights = C172Lights or {}
C172Lights.Create = C172Lights.Create or {}
C172Lights.Init   = C172Lights.Init   or {}

-- Landing light: longer throw, wider cone, LOWER intensity. Same reasoning as the rig - a
-- bright tight pool right in front of the nose is the steepest light gradient anywhere near
-- the aircraft, and the aeroplane crosses it constantly. Spreading the same light over more
-- ground makes neighbouring squares more alike and the re-lighting step smaller.
-- 09-26 (Jay: "the cessna flickers on taxi but fine in air"): y 1.70 -> 3.2. x/y are multiples
-- of HALF the extents (1.49 x 2.63 m after the 1.75 model scale), so 1.70 put the light's origin
-- 2.23 m ahead of centre - just past the nose - and the engine lights every square within about a
-- tile of that origin (2.6 tiles sideways) at full strength, backwards too. That spill sat over the
-- nose and wings and jumped a tile at a time while taxiing. BMWE92M3/tools/probe/headlight_pool_sim.py
-- (a copy of the engine's rule) has 1.70 over the airframe 100% of the time, 3.0 never; 3.2 = 4.2 m.
local LANDING = C172LightSpecs.HeadlightLeft
-- Taxi light: same wing, aimed shorter and wider. Deliberately much weaker so that having
-- both on reads as two different lights rather than one brighter one.
-- Taxi light: narrowed slightly (0.45 -> 0.50) and brightened a touch. Going to 0.70 made the
-- ground noticeably dimmer for no real gain, since the taxi light points forward and away.
-- 09-26: y 1.55 -> 2.7 for the same reason (1.55 = 2.03 m, over the airframe 94% of the time;
-- 2.5 and up never).
local TAXI    = C172LightSpecs.HeadlightRight
-- Position lights. Short, dim, coloured.
-- TIGHT CONES, AND THIS IS THE FIX FOR "THE PLANE IS SHINING ALL OVER".
--
-- `dot` is the cone's cosine threshold: HIGHER is narrower. These were 0.30, which is an
-- extremely wide cone - close to a point light - mounted right on the wingtips at x = +-3.0.
-- The result was red and green sprayed across the whole airframe from either side, which is
-- exactly what the recording shows: a red wash down one side of the fuselage and a green wash
-- down the other, with the aircraft parked at 0 ft.
--
-- It was not the IsoLightSource rig. That was proved by setting the rig to forward-light-only
-- and finding the coloured glow still there.
--
-- ALMOST OFF, ON PURPOSE - and this is Jay's diagnosis, not mine.
--
-- These are vehicle PART lights: they are attached to the aeroplane, so they light the
-- aeroplane. That is why the airframe was visibly turning red on one side and green on the
-- other. No cone width fixes that - a light bolted to the wingtip will always illuminate the
-- wing it is bolted to.
--
-- So they are reduced to a token glow (intensity 0.06, tight cone, 2 tiles) - just enough that
-- a working bulb is not literally dark - and the VISIBLE red and green now come from the
-- ground pools in C172AirborneLights, which sit on the terrain and cannot tint the model.
-- Part condition still matters: break a nav light and its ground pool is what you lose.
--
-- For reference, the history: 0.30 was the original wash, The original 0.30 was near-omnidirectional and sprayed colour
-- across the whole airframe; the first correction went to 0.94, which is a pencil beam and
-- made the position lights barely visible at all. 0.55 is a real cone - it reads as a lamp on
-- the wingtip without washing the fuselage - and the distance and intensity come back up with
-- it. These four numbers are pure aesthetics and are safe to keep tuning.
local NAV_L   = C172LightSpecs.HeadlightRearLeft
local NAV_R   = C172LightSpecs.HeadlightRearRight

-- Vanilla first (item + condition behaviour), then replace the light it built with ours.
-- Both halves are guarded: a light that fails to be created must never stop the rest of the
-- vehicle being built, which would leave the aircraft unspawnable.
local function fit(vehicle, part, spec)
    if not part then return end
    pcall(function() VehicleUtils.initHeadlight(vehicle, part) end)
    pcall(function()
        -- focusing is ignored by the engine (it is derived from part condition - see
        -- initHeadlight's own note), so the value passed here is irrelevant and matches
        -- vanilla's ZombRand call only for consistency.
        part:createSpotLightColor(spec.x, spec.y, spec.dist, spec.intensity, spec.dot,
                                  ZombRand(200), spec.r, spec.g, spec.b)
    end)
end

function C172Lights.Create.LandingLight(vehicle, part) fit(vehicle, part, LANDING) end
function C172Lights.Create.TaxiLight(vehicle, part)    fit(vehicle, part, TAXI)    end
function C172Lights.Create.NavLightLeft(vehicle, part) fit(vehicle, part, NAV_L)   end
function C172Lights.Create.NavLightRight(vehicle, part) fit(vehicle, part, NAV_R)  end

-- Init runs when an EXISTING vehicle is loaded from a save, Create when one is built fresh.
-- Both must fit the light or a saved aircraft comes back with vanilla car lights.
C172Lights.Init.LandingLight  = C172Lights.Create.LandingLight
C172Lights.Init.TaxiLight     = C172Lights.Create.TaxiLight
C172Lights.Init.NavLightLeft  = C172Lights.Create.NavLightLeft
C172Lights.Init.NavLightRight = C172Lights.Create.NavLightRight

-- ============================================== NO UPDATE OVERRIDE HERE, ON PURPOSE
--
-- An earlier version of this file also owned the light parts' `update`, to stop vanilla
-- switching every light off when the battery reads zero (which is what kills them on a long
-- flight). It made the game unloadable and is reverted.
--
-- WHAT WENT WRONG, SO IT IS NOT REPEATED. A part `update` runs once per part, per vehicle,
-- per tick - during WORLD LOAD as well as play. The override called
-- vehicle:getBatteryCharge(), which vanilla's own Vehicles.lua calls but which does NOT exist
-- on BaseVehicle or any superclass (verified with javap against the game jar). It therefore
-- threw thousands of times before the world could finish loading.
--
-- And the part that cost three attempts: pcall CATCHES that error, but "Break On Error" halts
-- on a thrown error whether or not anything catches it. Wrapping it more tightly changed
-- nothing. A guarded call is not free when the guarded thing throws every single time.
--
-- IF THIS IS ATTEMPTED AGAIN: read the charge through the Battery PART's own inventory item
-- (getPartById("Battery") -> getInventoryItem() -> getCurrentUsesFloat(), which is what
-- C172Systems already does and which demonstrably works), never through getBatteryCharge, and
-- test a full world load before anything else.
--
-- The create/init colours below are UNAFFECTED - they loaded and worked correctly - so the
-- aircraft keeps its red/green position lights and its landing and taxi lights.

return C172Lights
