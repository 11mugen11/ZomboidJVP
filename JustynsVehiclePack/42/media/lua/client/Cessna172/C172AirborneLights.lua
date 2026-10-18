require "Cessna172/C172Variants"
--[[
    C172AirborneLights - a light that actually follows the aircraft while it is flying.

    ============================ WHY THIS IS NEEDED AT ALL ============================

    The Cessna's four lights are real vanilla vehicle lights and they work correctly on the
    ground. They stop being visible once airborne, and the reason is structural rather than a
    bug in this mod: PZ places a vehicle's light at INTEGER TILE COORDINATES, including z, and
    this aircraft's LOGICAL z is deliberately pinned to the surface below by
    Patch_PinLogicalLevel. That pin is load-bearing - it is what stops the aircraft flickering
    over tall buildings and stops vanilla's fall-out-of-the-world recovery teleporting it - so
    only the RENDER is lifted. The engine has no fractional light altitude, so a vehicle light
    simply cannot sit where the aeroplane is drawn.

    ============================ WHY A SECOND LIGHT, NOT A FIX ============================

    So the vanilla light is not moved or fought. A SEPARATE IsoLightSource is created while
    airborne, placed on the ground beneath the aircraft, and moved as it flies - which is
    exactly what a landing light does in reality: it lights the ground, not the aeroplane.

    This is the technique AviationCore reached for and then switched off before release (their
    own HelicopterCarLightSet.lua says "Colored IsoLightSource navigation lights are not
    enabled for the public beta"). It is reimplemented here, not copied - and the honest
    limitation is stated plainly: PZ lights are tile-based, so the pool SNAPS from tile to tile
    rather than gliding. At cruise the aircraft crosses tiles quickly enough that it reads as
    movement; at a hover it would visibly step. That is the trade for having any light at all.

    ============================ SAFETY, AFTER THREE CRASHES ============================

    Two earlier attempts at the lights made the game unloadable, both because they ran inside a
    vehicle PART UPDATE - which executes during world load, thousands of times, where a single
    throw halts everything. This file is deliberately built the opposite way:

      * It is CLIENT-side and runs on OnTick, never in a part update or any load-time path.
      * It does nothing at all until a Cessna is actually airborne with its lights on, so on a
        normal game, every other vehicle, and the whole of world load, it costs one boolean.
      * Every engine call is wrapped, and the whole body is wrapped again.
      * It only uses calls confirmed present: IsoLightSource.new, cell:addLamppost,
        cell:removeLamppost, and the vehicle getters this mod already relies on. In
        particular it does NOT call getBatteryCharge or getBattery, which are what broke
        world loading before.
      * The light is REPLACED rather than mutated when it moves - remove then add - so no
        field assignment on a Java object is needed.
]]

-- 1.9.0: the old Java bridge functions now live in this mod's own C172Phys table (Lua, no
-- ZombieBuddy). Still looked up by name, so a missing one is a nil, never a call error.
require "Cessna172/C172Phys"
local function javaFn(name)
    local fn = C172Phys and C172Phys[name]
    if type(fn) == "function" then return fn end
    return nil
end
local function scanNearby(x, y, r)
    local scan = javaFn("c172ScanNearbyAircraft")
    if not scan then return 0 end
    return scan(x, y, r) or 0
end
local function nearbyAircraft(i)
    local get = javaFn("c172NearbyAircraft")
    if not get then return nil end
    return get(i)
end

-- ============================================== the rig
--
-- FOUR lights, not one, because one pool directly underneath told the player where the
-- aircraft was but nothing about where it was GOING.
--
--   BELLY    a wide, soft pool under the aircraft - the "I am up here" cue.
--   LANDING  thrown FORWARD along the heading, so the ground you are flying toward is lit.
--            This is what a real landing light is for and it is what makes night flying
--            usable rather than decorative.
--   NAV L/R  small red and green pools offset to either side, so the position lights are
--            visible in the air the way they are on the ground. Deliberately tiny - position
--            lights are meant to be SEEN, not to illuminate.
--
-- HEADING comes from c172ForwardX/Y, the same Java bridge the flight controller itself uses.
-- The file header on C172Flight records two separate shipped bugs that came from deriving
-- heading any other way, so it is not re-derived here. A near-zero vector means "no reliable
-- reading" and the directional lights are simply skipped for that tick.
-- 100ms, not 200. A light is only REBUILT when its tile actually changes, so a faster tick
-- adds no extra churn - it just notices the change sooner, which is the whole of the
-- "steppy" feel. Halving the latency halves the visible lag behind the aircraft.
-- 100 -> 50 (09-25, "smoothen out all lights"): at cruise a pool moved ~2.5 tiles per update;
-- at 20 Hz it is about half that, and the deadband still holds a slow or parked aircraft still.
local TICK_MS = 50
-- Bounds the ALIGNMENT offset only - no light is placed at this level any more. Without a cap
-- a runaway altitude reading would fling every light far off screen.
local MAX_LIGHT_LEVEL = 7

-- How far past a level boundary the aircraft must go before the lights change level. Must be
-- well above the frame-to-frame noise in the physics height, or a boundary becomes a flip-flop
-- that rebuilds lights every frame - see the note in updateOne.
local LEVEL_HYSTERESIS = 0.65

-- VISUAL ALIGNMENT. The ground lights sit at the aircraft's true x,y, which is geometrically
-- right - the ground IS directly below you - but in an isometric projection a raised sprite
-- moves UP the screen while the ground it is over does not. At altitude that reads as the
-- aeroplane flying above a disconnected spotlight, with a black gap between the two.
--
-- In PZ's 2:1 projection one z-level of upward screen movement is very close to one tile of
-- +x plus one tile of +y of downward movement. Subtracting the altitude in levels from both
-- axes therefore slides the pool back up the screen to sit under the DRAWN aircraft. Set to 0
-- to put the lights back under the aircraft's true ground position.
-- 0.45, not 1.0. Full alignment slid the pools a whole tile up-screen per level of altitude,
-- which at height threw the forward light so far from the aeroplane that it read as detached
-- rather than as its landing light. Half-alignment keeps them visibly tied to the aircraft
-- while still closing most of the isometric gap.
-- ISOMETRIC ALIGNMENT, BACK ON.
--
-- In an isometric view a raised sprite moves UP the screen while the ground it is over does
-- not. So at altitude an honest ground-position pool renders below and behind the aeroplane -
-- which is the "the light goes behind me when flying high" report. One z-level of upward
-- movement is very close to one tile of +x plus one tile of +y downward, so subtracting the
-- altitude in levels from both axes slides the pool back under the DRAWN aircraft.
--
-- This has been 1.0, then 0.45, then 0, and the reason it kept being wrong was not the value:
-- it was that the pools were simultaneously pushed 11-18 tiles away to stop an airframe glow
-- that turned out to be the part spotlights. Alignment plus a huge forward offset threw the
-- light right off the aeroplane. With the pools back in close, full compensation is simply the
-- correct geometry.
--
-- The cap remains as a backstop so that at the very top of the climb it stops compensating
-- rather than sliding the pool past the nose.
local VISUAL_ALIGN = 1.0
-- 9 tiles: enough to cover the full climb. At 5 the compensation stopped part-way up and the
-- pool started falling behind the aeroplane again exactly where it had been fixed lower down.
local VISUAL_ALIGN_MAX = 9.0        -- tiles

-- ALTITUDE SCALES THE RIG. The same radius that reads well from 400 ft is grotesque on the
-- tarmac: at ground level the pool lands right next to the camera with no distance to soften
-- it, so the position lights became two hard-edged coloured puddles the size of the aeroplane.
--
-- Each light therefore carries a `ground` factor - its radius multiplier at zero altitude -
-- and grows to full size by FULL_SIZE_LEVELS up.
--
-- WHAT RUNS ON THE GROUND, AND WHY.
--
-- Position lights: YES, full size (ground = 1.0). They look right beside a taxiing aeroplane
-- and are wanted.
--
-- White lights: NO (ground = 0). Two reasons, and the second is the important one:
--   1. Up close they washed out into a harsh bright wedge.
--   2. THE TAXI FLICKER. These lights are tile-snapped, so each one is destroyed and rebuilt
--      every time the aircraft crosses a tile boundary. At taxi speed that is several times a
--      second, and on the ground the camera is close enough that each jump is large on screen.
--      Five moving lights produced a visible pulse; two do not, and dropping the three big
--      white pools removes most of the moving lit AREA as well as most of the rebuilds.
--
-- Nothing is lost by this: vanilla's own headlight cones still light the way forward on the
-- ground, and C172Lights gives those four parts their proper aircraft colours and positions.
-- The rig exists to provide what the parts cannot - illumination from altitude - and that is
-- exactly where it still runs at full strength.
local FULL_SIZE_LEVELS = 4.0

-- NO RAMP WITH ALTITUDE. A light is either drawn at its full size or not drawn.
--
-- This used to interpolate from the `ground` factor up to full size over FULL_SIZE_LEVELS, so
-- a pool with ground = 0 was a QUARTER of its radius one level up and only reached full size
-- near the ceiling. That is why the lighting looked different at every height and only looked
-- right at maximum altitude - it genuinely was a different size at every level, and it stepped
-- each time the altitude band changed.
--
-- Uniform is what was asked for and uniform is also simpler: `ground` now decides only whether
-- a light is drawn on the deck, and everything airborne is full size.
local function scaledRadius(spec, levels)
    local g = spec.ground
    if g == nil then g = 1.0 end

    if levels < 0.5 then
        -- On the ground: `ground` is a straight multiplier, and 0 means do not draw.
        local r = math.floor(spec.radius * g + 0.5)
        return (r < 2) and 0 or r
    end

    -- Airborne: always full size, at every altitude - unless the light is ground-only.
    if spec.air == false then return 0 end
    return spec.radius
end

-- radius in tiles, colour, and where it sits relative to the aircraft (forward, lateral)
-- SIZES, INFORMED BY A WORKING REFERENCE. AviationCore's shipped helicopter night light
-- (client/AviationCore/Presentation/HelicopterNightLightService.lua) uses LIGHT_RADIUS = 20
-- for a single ground pool. That is a working, released value on this exact game build, and
-- our prototype at 7 - and then 12 - read as far too small next to it. The belly pool is
-- therefore sized in that region; the forward light is slightly smaller because it is an
-- addition rather than the main pool, and the position lights stay deliberately tiny because
-- they exist to be SEEN rather than to illuminate.
--
-- An earlier revision blamed a lights-out regression on radius. That was wrong: the tick
-- function had been deleted by an over-wide edit and nothing was running at any radius.
-- EVERY LIGHT SITS AT GROUND LEVEL. An earlier version raised the position lights to the
-- aircraft's drawn level so they would look mounted on it. That worked low down and failed at
-- altitude, because PZ lighting is tile-based and a light placed on a level with no geometry
-- has nothing to illuminate - which is exactly why they disappeared as you climbed.
--
-- The visual alignment below solves it far better and at any height: keeping the light on the
-- ground (where it always renders) and sliding it up-screen by the altitude puts it at the
-- aircraft's APPARENT position. The position lights therefore ride on the wings at 100 ft and
-- at the ceiling alike, and the whole MAX_LIGHT_LEVEL problem disappears with them.
-- NOTHING MAY SIT ON THE AIRCRAFT'S OWN SQUARE.
--
-- This is the rule the rig kept breaking. Patch_PinLogicalLevel deliberately pins the
-- aircraft's LOGICAL square to the surface below - that pin is load-bearing - and PZ lights an
-- object from its square. So a light placed at the aircraft's own x,y illuminates the
-- AEROPLANE, however high it is drawn: that is the "shining all over the body" report, and the
-- old belly pool (radius 18, centred exactly there) was the worst offender.
--
-- So the belly light is gone, the landing light is pushed 11 tiles ahead where it lights the
-- ground the aircraft is flying toward and nothing else, and the position lights are small
-- points out at the wingtips rather than pools wide enough to wash over the fuselage.
--
-- Anything added here in future must keep `fwd`/`lat` far enough out that its radius does not
-- reach back over the aircraft's square. The test is simply radius < distance-from-centre:
-- the landing light is radius 13 at 18 tiles ahead, so its lit disc spans 5 to 31 tiles in
-- front and never touches the aeroplane. A first pass at 11 tiles with radius 15 failed that
-- test and would have kept the body lit.
-- WHY THESE ARE BIG AND DIM RATHER THAN SMALL AND BRIGHT.
--
-- Confirmed by test: the aircraft does NOT pulse while parked, only while moving. PZ lights a
-- vehicle from the square it occupies, and Patch_PinLogicalLevel pins the aircraft's logical
-- square to the ground - so as it moves, that square changes constantly and the whole model is
-- re-lit from the new one. With the lights off, neighbouring squares are nearly identical and
-- nothing shows. With the lights on there is a steep brightness gradient across the ground, so
-- every square change is a visible jump in how the entire aeroplane is lit.
--
-- That is PZ lighting a moving object from discrete tiles, not a fault in this rig - so the
-- lever is the GRADIENT, not the number of lights. A larger, dimmer pool covers the same
-- ground while making adjacent squares more similar, which makes each step smaller. Radii are
-- therefore up ~35% and brightness down ~38%.
--
-- ============================ TUNING THIS RIG ============================
--
--   fwd    tiles AHEAD of the aircraft (negative = behind)
--   lat    tiles to the SIDE (+ right, - left)
--   ground radius multiplier on the deck; 0 = not drawn on the ground at all
--
-- THE ONE HARD RULE: radius must be SMALLER than sqrt(fwd^2 + lat^2).
--
-- Patch_PinLogicalLevel pins the aircraft's LOGICAL square to the surface below, and PZ lights
-- an object from its square - so any light whose radius reaches back over the aircraft's own
-- position floodlights the AEROPLANE instead of the ground. That was the "shining all over the
-- body" problem, caused by a radius-18 pool centred exactly on it. Check any change against
-- this rule before flying it.
-- ============================ A/B TEST SWITCH ============================
-- true  = FORWARD LIGHT ONLY. Just the landing pool 18 tiles ahead; no pool behind you and
--         no coloured wingtip points. This is the minimal look.
-- false = the full rig (forward pool + trailing pool + red/green position lights).
--
-- Flip this one word and restart - it is plain Lua, no rebuild needed. Nothing else changes,
-- so switching back and forth costs nothing and neither setting can affect flight.
-- Back to the full rig. The forward-only test did its job: the body still looked wrong with a
-- single light 18 tiles away, which cleared the rig of causing that and pointed at the part
-- spotlights instead. Leaving it on forward-only afterwards just made the ground darker for
-- no diagnostic value.
local FORWARD_LIGHT_ONLY = false

local RIG_FULL = {
    -- RESTORED TO THE BUILD THAT LOOKED RIGHT IN THE AIR.
    --
    -- These are the sizes and brightnesses from before the flicker hunt: a big pool under the
    -- aircraft and two staggered forward pools, all at full brightness. Chasing the flicker I
    -- shrank the radii by a third and dimmed every colour by ~38%, on the theory that a gentler
    -- gradient meant smaller re-lighting steps between squares. It did - and it also took away
    -- the thing the lights were for. Being able to see the ground you are flying over is worth
    -- more than a smaller step, especially now the real offenders (the part spotlights tinting
    -- the airframe, and shutOff ejecting the ignition key) are fixed at their own causes.
    --
    -- What is NOT reverted, because none of it changes the look: the speed-scaled deadband,
    -- the ground-mode fix that lets the position lights show while taxiing, the alignment cap,
    -- and the tighter tracking for small lights.
    { key = "under",   radius = 18, r = 1.00, g = 0.96, b = 0.86, fwd =   0.0, lat =  0.0, ground = 0 },
    -- landing/reach pushed ~25% further ahead (09-25, Jay: "make light show a little further
    -- in front"): 8 -> 10, 19 -> 24.
    { key = "landing", radius = 16, r = 1.00, g = 0.97, b = 0.90, fwd =  10.0, lat =  0.0, ground = 0 },
    { key = "reach",   radius = 13, r = 0.98, g = 0.95, b = 0.88, fwd =  24.0, lat =  0.0, ground = 0 },
    -- RED / GREEN POOLS OFF (09-25). First "make the red and green cessna lights work better or
    -- just make it appear on ground only" (-> air = false), then, having seen them on the ground:
    -- "green and red lights follow weird and look bad". A tile light cannot be a wingtip glow - a
    -- radius-6 pool is a 12-tile coloured blob that tints the whole airframe (the model's ambient
    -- comes from its square) and trails a tile behind while taxiing. ground = 0 and air = false
    -- mean no pool at all; the entries stay so a session that still has one lit removes it.
    { key = "navL",    radius = 6,  r = 1.00, g = 0.05, b = 0.05, fwd =  -0.5, lat = -2.5, ground = 0, air = false },
    { key = "navR",    radius = 6,  r = 0.05, g = 1.00, b = 0.15, fwd =  -0.5, lat =  2.5, ground = 0, air = false },
}

-- Built once at load rather than filtered per tick: the rig never changes at runtime, and the
-- light loop runs several times a second.
local RIG = RIG_FULL
if FORWARD_LIGHT_ONLY then
    RIG = {}
    for i = 1, #RIG_FULL do
        if RIG_FULL[i].key == "landing" then RIG[#RIG + 1] = RIG_FULL[i] end
    end
end


local created, reportedOk, reportedFail = 0, false, false

-- OVERLAP ON REBUILD (1.10.4). A Workshop report (10-09): "With Viewpoint enabled (Vivid shader)
-- the landing lights keep blinking when turned on during flight". A moving pool is a rebuild -
-- new light added, then the old one removed - and the lighting system takes a moment to light the
-- new one, so for that moment neither lit the ground: a blink every rebuild, which at cruise is
-- several times a second. The old light now stays RETIRE_MS longer, so the pools overlap instead
-- of leaving a gap. A light switched off entirely still goes at once (dropOne).
local RETIRE_MS = 150
local retiring = {}          -- { light =, dueAt = } waiting to be removed

local active   = {}          -- vehicleId -> { [key] = { light=, x=, y=, z= } }
local lastTick = 0

local function nowMs()
    return (getTimestampMs and getTimestampMs()) or 0
end

-- A light being switched off entirely is removed immediately: there is no replacement coming,
-- so holding it would just leave a stale light burning after the aircraft has gone.
local function dropOne(rec, key)
    local e = rec and rec[key]
    if not e then return end
    pcall(function()
        local cell = getCell()
        if cell and e.light then cell:removeLamppost(e.light) end
    end)
    rec[key] = nil
end

-- Iterates RIG rather than the record's keys, so the bookkeeping field __vehicle is never
-- mistaken for a light entry.
local function dropAll(id)
    local rec = active[id]
    if not rec then return end
    for _, spec in ipairs(RIG) do dropOne(rec, spec.key) end
    active[id] = nil
end

-- True only when this aircraft should be lit: flying, and with its lights switched on.
local function shouldLight(vehicle)
    local on = false
    pcall(function() on = vehicle:getHeadlightsOn() == true end)
    if not on then return false end
    -- NO GROUND CHECK HERE ANY MORE.
    --
    -- This used to return false whenever the aircraft was in GROUND mode, which made the
    -- per-light `ground` factor dead code: the position lights were set to ground = 1.0 and
    -- could never appear on the tarmac, because the whole rig was switched off first. That is
    -- why they only ever showed while hovering.
    --
    -- Whether a light is drawn on the ground is a decision for that light, and scaledRadius
    -- already makes it - returning 0 for anything with ground = 0. So the only question here
    -- is whether the aircraft's lights are switched on at all.
    return true
end

-- ADD THE NEW LIGHT BEFORE REMOVING THE OLD ONE.
--
-- This used to remove first and add second, which leaves a window - at least one rendered
-- frame - where the light simply does not exist. Standing still that never shows, but while
-- taxiing the tile changes constantly, so the gap recurs several times a second and the
-- aircraft appears to FLICKER. Overlapping the two for an instant is invisible; a hole is not.
-- MOVE DEADBAND. A light is REBUILT whenever its tile changes, and the tile comes from
-- rounding a float position - so an aircraft sitting near a tile boundary flips between two
-- tiles on sub-pixel jitter and the light is destroyed and recreated every single tick. That
-- is the flicker: worst while taxiing, and present even in a hover, because a hover is exactly
-- the case where the position hovers around one spot instead of moving decisively past it.
--
-- Rounding harder cannot fix it - every threshold has a boundary. What fixes it is hysteresis:
-- remember where the light was actually PLACED, and leave it there until the aircraft has
-- moved most of a tile away. Then a boundary can only be crossed once, in one direction.
-- SPEED-SCALED DEADBAND.
--
-- A fixed deadband is wrong at one end of the speed range whichever value you pick, and both
-- mistakes have now been made:
--
--   0.85 tiles - followed beautifully in the air, but while taxiing the aircraft creeps across
--                the threshold constantly, so the pool rebuilt over and over at walking pace
--                and every rebuild is a flicker.
--   3.0 tiles  - fixed taxiing, and made FLIGHT worse: at cruise you cross three tiles in a
--                moment, so instead of many small steps you get many LARGE ones, and the light
--                visibly lags and then lurches. That is the "not following as good at max
--                altitude" report.
--
-- What actually matters is how big each jump looks RELATIVE to how fast the world is moving.
-- Standing still, any jump is glaring - so hold position hard. At speed, a one-tile correction
-- is invisible against the motion - so follow closely and let it update often.
--
-- Hence: large deadband when slow, small when fast.
local DEADBAND_SLOW   = 3.0     -- tiles, at a standstill
local DEADBAND_FAST   = 0.45    -- tiles, at cruise and above
local DEADBAND_FULL_SPEED_KMH = 90   -- speed at which DEADBAND_FAST is reached

local function deadbandFor(vehicle)
    local kmh = 0
    pcall(function()
        local v = vehicle:getCurrentSpeedKmHour()
        if type(v) == "number" and v == v then kmh = math.abs(v) end
    end)
    local t = kmh / DEADBAND_FULL_SPEED_KMH
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return DEADBAND_SLOW + (DEADBAND_FAST - DEADBAND_SLOW) * t
end

-- REBUILD, BECAUSE MOVING DOES NOT WORK.
--
-- IsoLightSource exposes setX/setY/setZ, so the obvious fix for rebuild churn was to create
-- each light once and move it. Tried, and it does not relocate a light that is already
-- registered with the cell - PZ evidently caches the position when addLamppost is called, so
-- the pool simply stopped following the aircraft. Reverted.
--
-- So a tile change means a genuine rebuild, and rebuild churn is what causes the flicker. The
-- only lever left is to rebuild FAR LESS OFTEN, which is what the large deadband below does:
-- the light holds position until the aircraft is well clear of it, then makes one jump. A
-- large soft pool lagging a couple of tiles behind is barely perceptible; the same pool
-- rebuilding several times a second is very perceptible indeed.
--
-- WORTH KNOWING: AviationCore hit this same wall and gave up on it. Its own
-- HelicopterCarLightSet.lua says coloured IsoLightSource navigation lights "are not enabled
-- for the public beta; moving point lights do not remain visually stable on B42 vehicles".
-- That is an independent confirmation that a smoothly-moving point light is not something
-- this engine does - so the goal here is to make the steps rare and unobtrusive, not to
-- eliminate them.
local function placeLight(rec, key, x, y, z, spec, radius, fx, fy, deadband)
    radius = radius or spec.radius
    local e = rec[key]

    if e then
        if e.x == x and e.y == y and e.z == z and e.radius == radius then return end
        if e.z == z and e.radius == radius and e.fx and e.fy then
            local dx, dy = fx - e.fx, fy - e.fy
            if (dx * dx + dy * dy) < (deadband * deadband) then return end
        end
    end

    pcall(function()
        local cell = getCell()
        if not cell or not IsoLightSource then return end

        local light = IsoLightSource.new(x, y, z, spec.r, spec.g, spec.b, radius)
        if not light then
            if not reportedFail then
                reportedFail = true
                print("[Cessna172][LIGHT] IsoLightSource.new returned nil for '" .. key ..
                      "' (radius " .. tostring(radius) .. ").")
            end
            return                      -- keep the old light rather than going dark
        end
        cell:addLamppost(light)
        if e and e.light then
            retiring[#retiring + 1] = { light = e.light, dueAt = nowMs() + RETIRE_MS }
        end
        rec[key] = { light = light, x = x, y = y, z = z, radius = radius, fx = fx, fy = fy }
        created = created + 1
        if not reportedOk then
            reportedOk = true
            print(("[Cessna172][LIGHT] rig live (first: '%s' at %d,%d,%d radius %d)")
                :format(key, x, y, z, radius))
        end
    end)
end

local function updateOne(vehicle)
    local id
    local okId = pcall(function() id = vehicle:getId() end)
    if not okId or not id then return end

    if not shouldLight(vehicle) then
        dropAll(id)
        return
    end

    local vx, vy, vz
    pcall(function()
        vx, vy, vz = vehicle:getX(), vehicle:getY(), math.floor(vehicle:getZ())
    end)
    if not (vx and vy and vz) then return end

    -- The level the aircraft is DRAWN at. vz is its LOGICAL level - the engine's own (1.9.0;
    -- over open ground the surface level, as the Java build's pin made it) - and is not
    -- touched here. The visual level is derived instead from the Bullet body height: c172GetBodyHeight
    -- reports physics-vertical units and there are 2.44949 of them per tile level, the same
    -- constant C172Physics uses for exactly this conversion.
    -- STALE OBJECT GUARD. Keying only by id is not enough: a vehicle can be removed and a new
    -- one can later carry the same id, and the cached entry would then be compared against a
    -- different aircraft and judged "hasn't moved" - leaving a light stranded at the old spot
    -- and none at the new one. The reference service guards this the same way, by remembering
    -- the vehicle OBJECT alongside the position.
    local rec = active[id]
    if rec and rec.__vehicle ~= vehicle then
        dropAll(id)
        rec = nil
    end
    if not rec then
        active[id] = { __vehicle = vehicle }
        rec = active[id]
    end

    -- CLAMPED AND HYSTERETIC, both for the same reason: churn.
    --
    -- Raw body height converts to a tile level that changes constantly during a climb, and it
    -- wobbles by a level even in level flight because the physics height is never perfectly
    -- steady. Every change destroys and recreates two lights, so at altitude the position
    -- lights were being rebuilt many times a second - which is the "laggy / glitchy higher up"
    -- report. Low down the level rarely changes, which is why it looked fine for the first
    -- quarter of the climb.
    --
    -- Two guards:
    --   CLAMP    PZ's world is only a handful of levels tall and its lighting is tile-based.
    --            A light placed above MAX_LIGHT_LEVEL has no geometry to fall on and renders
    --            unreliably, so the position lights stop climbing there and simply ride at the
    --            ceiling. They stay visible instead of flickering in and out.
    --   STICKY   a level change must exceed one full level before it is accepted, so a height
    --            hovering on a boundary cannot oscillate the lights between two levels.
    -- REAL HYSTERESIS, ON THE FRACTIONAL HEIGHT.
    --
    -- The previous version rounded the height to a whole level and then accepted a change
    -- whenever it differed by 1 or more. Both values are integers, so that condition is true
    -- for EVERY single-level flip - it was not hysteresis at all. With the aircraft sitting
    -- near a level boundary the height rounds to N one frame and N+1 the next, so both
    -- position lights were destroyed and recreated every frame. Rebuilding a light forces PZ
    -- to recompute that square's lighting, and the aircraft model is lit from its square -
    -- which is why the whole aeroplane pulsed, in the air and on the ground, rather than just
    -- the pools moving.
    --
    -- The comparison is now against the UNROUNDED height, and a level is only left once the
    -- aircraft is 0.65 of a level clear of it. A height hovering exactly on a boundary can no
    -- longer flip anything.
    local airZ = rec.__airZ or vz
    pcall(function()
        local bodyHeight = javaFn("c172GetBodyHeight")
        if not bodyHeight then return end
        local h = bodyHeight(vehicle)
        if type(h) ~= "number" or h <= 0 then return end
        local raw = h / 2.44949                       -- fractional levels, not rounded
        if raw - airZ > LEVEL_HYSTERESIS then
            airZ = math.floor(raw)
        elseif airZ - raw > LEVEL_HYSTERESIS then
            airZ = math.floor(raw + 0.5)
        end
        if airZ < vz then airZ = vz end
        if airZ > MAX_LIGHT_LEVEL then airZ = MAX_LIGHT_LEVEL end
    end)

    -- Unit heading, and the lateral (right-hand) unit perpendicular to it.
    local fx, fy = 0, 0
    local fwdX, fwdY = javaFn("c172ForwardX"), javaFn("c172ForwardY")
    if fwdX and fwdY then pcall(function() fx, fy = fwdX(vehicle) or 0, fwdY(vehicle) or 0 end) end
    local len = math.sqrt(fx * fx + fy * fy)
    local haveHeading = len > 0.2
    if haveHeading then fx, fy = fx / len, fy / len end
    -- (-fy, fx) is the aircraft's STARBOARD (right) unit, not port: with forward pointing
    -- east (1,0) it evaluates to (0,1), which in PZ world coordinates is south - the right
    -- hand side of an eastbound aeroplane. So a POSITIVE `lat` places a light to starboard,
    -- which is why the red port light and the green starboard light were initially on the
    -- wrong wings. navL is therefore negative and navR positive.
    local lx, ly = -fy, fx

    rec.__airZ = airZ
    local deadband = deadbandFor(vehicle)

    for _, spec in ipairs(RIG) do
        local directional = (spec.fwd ~= 0 or spec.lat ~= 0)
        if directional and not haveHeading then
            -- No trustworthy heading this tick: drop the directional lights rather than
            -- planting them in an arbitrary direction.
            dropOne(rec, spec.key)
        else
            -- ROUND, do not floor. floor() biases every light half a tile toward the origin,
            -- which on a pool meant to sit centred under the aircraft is a visible offset.
            -- The reference implementation rounds for the same reason.
            local levels = airZ - vz
            local r = scaledRadius(spec, levels)
            local align = VISUAL_ALIGN * levels
            if align > VISUAL_ALIGN_MAX then align = VISUAL_ALIGN_MAX end
            local px = vx + fx * spec.fwd + lx * spec.lat - align
            local py = vy + fy * spec.fwd + ly * spec.lat - align
            -- r == 0 means this light is not drawn at this altitude (see scaledRadius).
            -- No goto here: Kahlua is Lua 5.1 and has no goto/continue at all.
            if r <= 0 then
                dropOne(rec, spec.key)
            else
                -- A small light needs a small deadband. The base value is tuned for the big
                -- pools, where a 3-tile hold is invisible; on a radius-3 position light the
                -- same hold is the light sitting a whole light-width behind the wingtip. So it
                -- is capped to half the light's own radius.
                local db = math.min(deadband, r * 0.5)
                -- ON THE ROOF, NOT UNDER IT (09-25). Jay: "when flying over buildings light isnt
                -- lighting up its black". A light on level 0 under a building lights its
                -- ground-floor interior and the roof stays dark, so each pool goes on the
                -- highest floor below its own spot. Raising it L levels already moves it up the
                -- screen by L levels, so that much of the altitude alignment is given back.
                local lz = spec.atAircraft and airZ or vz
                if not spec.atAircraft and levels >= 0.5 then
                    local surfaceLevel = javaFn("c172SurfaceLevelAt")
                    local okL, L = false, nil
                    if surfaceLevel then
                        okL, L = pcall(function()
                            return surfaceLevel(math.floor(px + 0.5), math.floor(py + 0.5), airZ)
                        end)
                    end
                    if okL and type(L) == "number" and L > vz then
                        local back = math.min(align, VISUAL_ALIGN * (L - vz))
                        px, py = px + back, py + back
                        lz = L
                    end
                end
                placeLight(rec, spec.key,
                           math.floor(px + 0.5), math.floor(py + 0.5),
                           lz, spec, r, px, py, db)
            end
        end
    end
end

-- THE TICK. This function was silently deleted by an over-wide edit in a previous revision,
-- leaving Events.OnTick.Add(onTick) registering a NIL handler - which is why the lights
-- stopped working entirely. Nothing was running, at any radius. Restored here.
--
-- CHEAP GATE FIRST. c172IsAirborne() is a single volatile boolean in C172Physics that is true
-- only while one of THIS mod's aircraft is actually flying - the same gate every Java patch
-- uses before doing any work. Without it this ran a world-wide vehicle scan five times a
-- second, for every player, forever, whether or not a Cessna existed anywhere in the save.
-- With it, the cost when nothing is flying is one boolean read.
--
-- The scan itself is c172ScanNearbyAircraft: Cessna-only, and it walks vehicles in JAVA.
-- Enumerating vehicles from Lua is unsafe - VehicleManager can be null and takes pcall down
-- with it - which is why this mod never does that.
local function removeRetired(t)
    if #retiring == 0 then return end
    local cell = getCell()
    local keep = {}
    for i = 1, #retiring do
        local r = retiring[i]
        if t >= r.dueAt or not cell then
            if cell then pcall(function() cell:removeLamppost(r.light) end) end
        else
            keep[#keep + 1] = r
        end
    end
    retiring = keep
end

local function onTick()
    local t = nowMs()
    if (t - lastTick) < TICK_MS then return end
    lastTick = t
    pcall(removeRetired, t)

    -- LIGHTS STAY ON WHEN YOU GET OUT (09-25). Jay: "leaving cessna with lights on should keep
    -- lights on". On the ground this used to serve only the Cessna you were sitting in and
    -- dropped every other light, so stepping out switched the rig off while the aircraft's
    -- headlights were still on. Every Cessna in range with its lights on is now served, in the
    -- air or not - the nearby scan below, which used to run only while something was flying.
    -- (The grounded fast path below is kept but can no longer be taken.)
    local flying = true

    -- GROUNDED FAST PATH. Nothing of ours is flying, but the player may be sitting in a lit
    -- Cessna on the tarmac. Handling just their own vehicle costs one getVehicle() call and
    -- avoids the world-wide scan entirely, so taxiing is lit without reintroducing the
    -- per-tick cost the airborne gate exists to prevent.
    if not flying then
        local handled = false
        pcall(function()
            local player = getPlayer()
            local v = player and player:getVehicle()
            if not v then return end
            local okN, nm = pcall(function() return v:getScriptName() end)
            if not (okN and C172Variants.isName(nm)) then return end
            updateOne(v)
            handled = true
        end)
        if handled then return end
    end

    if not flying then
        -- NO next() HERE. Kahlua's BaseLib does not register `next`, so calling it is
        -- "Object tried to call nil" - it threw on the first tick of every load. pairs() is
        -- registered and is all that was needed: the loop is simply a no-op on an empty table,
        -- so the emptiness check it was guarding was never necessary in the first place.
        --
        -- Ids are collected before dropping, because dropAll() sets active[id] = nil and
        -- mutating a table while pairs() walks it is not something to rely on.
        local ids = nil
        for id in pairs(active) do
            ids = ids or {}
            ids[#ids + 1] = id
        end
        if ids then
            for i = 1, #ids do dropAll(ids[i]) end
        end
        return
    end

    pcall(function()
        local player = getPlayer()
        if not player then return end
        local n = scanNearby(player:getX(), player:getY(), 60)
        local seen = {}
        for i = 0, n - 1 do
            local v = nearbyAircraft(i)
            if v then
                local id
                pcall(function() id = v:getId() end)
                if id then seen[id] = true end
                updateOne(v)
            end
        end
        -- Anything we were lighting that is no longer nearby: let it go, or its light is
        -- stranded in the cell forever.
        local stale = nil
        for id in pairs(active) do
            if not seen[id] then
                stale = stale or {}
                stale[#stale + 1] = id
            end
        end
        if stale then
            for i = 1, #stale do dropAll(stale[i]) end
        end
    end)
end

Events.OnTick.Add(onTick)

-- Leaving the world must not strand a light in the cell - including any still waiting to be
-- retired, which would otherwise sit lit forever with nothing owning them.
if Events.OnPlayerDeath then Events.OnPlayerDeath.Add(function()
    local ids = nil
    for id in pairs(active) do
        ids = ids or {}
        ids[#ids + 1] = id
    end
    if ids then for i = 1, #ids do dropAll(ids[i]) end end
end) end

print("[Cessna172] airborne ground-light installed (client-side, airborne + lights-on only).")
