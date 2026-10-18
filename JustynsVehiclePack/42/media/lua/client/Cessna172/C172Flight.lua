require "Cessna172/C172GroundHandling"
require "Cessna172/C172Altitude"
--[[
    C172Flight - Cessna 172 flight controller.

    ===================================================================================
    WHAT THIS IS, AND WHAT IT DELIBERATELY IS NOT
    ===================================================================================
    This is the MiG-29 mod's proven flight PIPELINE with a light-aircraft FLIGHT MODEL
    on top. The pipeline is reused because it is the part that took real work to get
    right; the numbers are all this aircraft's own, because a 172 must not read as a
    slower jet. Everything that follows is either (a) a mechanism copied because it is
    known-correct and hard-won, each with its reason restated so it is not "fixed" back
    into a bug, or (b) a Cessna-specific behaviour that has no MiG equivalent.

    NOTHING HERE TOUCHES ANOTHER MOD. Every physics call goes through this mod's own
    C172Phys table (C172Phys.lua); every Lua global, module path, modData key, sound name
    and network module is unique to this mod. The MiG-29 and VX-9 / MH-92 mods are
    reference-only and are not read, written or required.

    NO JAVA SINCE 1.9.0. Up to 1.8.1 this file reached the engine through Cessna172.jar,
    loaded by ZombieBuddy. Every one of those jobs is now done in Lua (C172Phys,
    C172Contacts, C172Presentation, C172PropSpin) with calls the game already exposes, so
    the aircraft flies with ZombieBuddy on, off or not installed. The notes below that
    describe how the Java build did something are kept where the reason still matters.

    ===================================================================================
    MECHANISMS INHERITED FROM THE WORKING JET - AND WHY EACH ONE EXISTS
    ===================================================================================
    MOVEMENT IS QUEUED PUSHES (1.9.0). A BaseVehicle's authoritative position is its
    native Bullet transform, and setX/setY/setSpeedKmHour do not move it. What does is
    BaseVehicle.applyImpulseGeneric - the queue a collision uses - which the Java build's
    lift and drive ALSO used; it was once written off from Lua only because its argument
    order is unusual (point x, y, z, then direction x, world-y, UP). Drive and lift are
    line-for-line ports. HEADING IS THE ONE REAL CHANGE: Java rewrote the rotation with
    Bullet.teleportVehicle and then had to give the speed back; now pushes either side of
    the centre TURN the airframe (C172Phys.holdAttitude), so a turn costs no speed at all.

    HEADING IS SEEDED FROM THE ENGINE'S OWN FORWARD VECTOR, never from an angle getter
    and never from observed motion. Reading heading from getForwardDirectionX/Y and
    writing it back with setAngles uses two different conventions and snaps the aircraft
    to a mirrored angle; deriving it from atan2(dy, dx) of observed taxi motion is
    unambiguous but feeds the OPPOSITE axis pairing into the yaw quaternion, which wants
    worldForward = (sin(yaw), cos(yaw)). Both bugs were shipped and both were fixed the
    same way: read c172ForwardX/Y. The drive target vector below uses the same
    (sin, cos) pairing for the same reason - if the two ever disagree, the aircraft
    accelerates somewhere other than where its nose points.

    TIRES COME OUT OF PHYSICS WHILE AIRBORNE (BaseVehicle.setTireRemoved, public), and this
    is not cosmetic. A PZ vehicle is
    a Bullet RAYCAST vehicle: each wheel casts toward the ground and its suspension
    pushes the chassis back to ride height. Leave the tires in and the suspension simply
    wins - the body stays pinned no matter how much lift is applied. It also fixes a
    second problem for free: with no wheel touching anything, the vanilla drivetrain's
    engine force and steering have nothing to act through, so car controls stop fighting
    the flight forces. That is what makes it safe to leave vanilla ground physics fully
    intact for taxi and the takeoff roll. Called on the GROUND<->AIR edge only, never
    per tick.

    THE SPEED CAP NEVER APPLIES. Vanilla's updateVelocityMultiplier() scales a vehicle back
    past a HARDCODED ~34 m/s (122 km/h). The Java build skipped it (Patch_NoSpeedCap); this
    aircraft's ceiling is MAX_AIRSPEED_KMH 95, well under it, so without Java nothing
    changes. Nothing in this file touches the speed cap.

    NO ERROR IS EVER ALLOWED TO REACH THE DEBUGGER. pcall() does NOT stop PZ opening the
    Lua error window: Kahlua's KahluaUtil.fail() dumps a stack trace and triggers it even
    from inside pcall. So this file never CALLS a method without checking it exists
    first - see the call0/call1/call2 layer immediately below.

    ===================================================================================
    WHAT IS THIS AIRCRAFT'S OWN
    ===================================================================================
    * A piston flight model: low thrust authority, a long gentle speed ramp, soft
      speed-scaled turn rates, climb rate coupled to excess airspeed, and a stall model
      that sinks the aircraft rather than dropping it. See TUNE, below, where every
      number carries its own reason.
    * A real rotating PROPELLER driven by measured wall-clock time, published to Java as
      an angle plus an angular RATE so it stays smooth between logic ticks.
    * Four-stage piston engine audio (start / idle / power / shutdown) rather than the
      jet's main+afterburner pair.
    * A nearby-aircraft sweep, so OTHER players' Cessnas get a spinning propeller and
      engine audio in multiplayer with no per-frame packets at all - both are derived
      from state vanilla already replicates.
    * FIXED landing gear: nothing retracts, so no model is ever hidden or shown and the
      ghost/duplicate-model artifact class cannot occur.

    ===================================================================================
    CONTROLS - TWO MUTUALLY EXCLUSIVE STATES
    ===================================================================================
    TAXI (grounded): W/S/A/D are 100% vanilla car controls. This file writes NOTHING to
      the vehicle while grounded, so there is no separate taxi handler to keep in sync -
      vanilla wheel physics IS taxi, and that is deliberate (see the vehicle script's
      GROUND HANDLING note).
    FLIGHT (airborne): the SAME keys, so there is only one control scheme to learn.
      W      throttle open. Speed builds slowly; past the level-flight band the extra
             energy becomes CLIMB. Releasing it does not brake - airspeed bleeds off
             gently and the aircraft settles back into level flight.
      S      throttle closed. Sheds speed faster than drag alone, and below the
             level-flight band that speed deficit becomes DESCENT. This is how you come
             down without requesting a landing.
      Hands off W and S, at a speed inside the level band, is STABLE CRUISE - the
             aircraft holds its altitude. Altitude is not a separate lever: it is bought
             and sold with airspeed, which is how a fixed-pitch light aircraft actually
             behaves.
      A / D  yaw left / right. Turning REDIRECTS the aircraft's existing momentum
             rather than erasing and rebuilding it, so a sustained turn keeps real
             forward speed. Thrust and turn are two independent per-tick values feeding
             ONE combined drive call - there is no branch anywhere that makes them
             mutually exclusive, which is the specific bug ("turning interrupts forward
             flight") that had to be structurally designed out rather than tuned around.
    LANDING is requested from the vehicle's radial menu ("Land Aircraft", added by
      C172Recovery.lua), not from a held key - an explicit menu selection is deliberate
      intent and needs none of the accidental-input protection a held key would.
    onTick dispatches to EXACTLY ONE of the GROUND block or updateFlight() per tick,
      never both, via st.isAirborne - which only enterAirMode and enterGroundMode ever
      change, and neither is called off a single questionable frame of ground contact.
]]

require "Cessna172/C172Config"
require "Cessna172/C172Util"
require "Cessna172/C172Parts"
require "Cessna172/C172Aviation"
require "Cessna172/C172Phys"
require "Cessna172/C172Contacts"
require "Cessna172/C172PropSpin"

C172Flight = C172Flight or {}

-- ------------------------------------------------------- safe engine call layer
local function methodExists(obj, name)
    if obj == nil then return false end
    local ok, m = pcall(function() return obj[name] end)
    return ok and m ~= nil
end

local function call0(obj, name)
    if not methodExists(obj, name) then return false, nil end
    return pcall(function() return obj[name](obj) end)
end

local function call1(obj, name, a)
    if not methodExists(obj, name) then return false, nil end
    return pcall(function() return obj[name](obj, a) end)
end

local function call2(obj, name, a, b)
    if not methodExists(obj, name) then return false, nil end
    return pcall(function() return obj[name](obj, a, b) end)
end

-- ------------------------------------------------------- physics bridge (Lua, 1.9.0)
-- Thin local wrappers around this mod's own C172Phys table. The names and return shapes are
-- the old Java bridge's, so the flight logic below reads exactly as it did; C172Phys.lua
-- documents how each one is done without Java. Nothing here can reach the MiG's or the
-- MH-92's code by construction: they are other tables in other files.

-- Call t[name](...) guarded: a missing module or function is (false), never an error - the
-- argument list of a plain pcall(t.f, ...) would itself index a missing table.
local function tcall(t, name, ...)
    if type(t) ~= "table" then return false end
    local f = t[name]
    if type(f) ~= "function" then return false end
    return pcall(f, ...)
end

local function bridgeAvailable()
    local ok, yes = tcall(C172Phys, "c172PhysicsAvailable")
    return ok and yes == true
end

-- A bridge function by its old name, or nil.
local function bridgeFn(name)
    local fn = C172Phys and C172Phys[name]
    if type(fn) == "function" then return fn end
    return nil
end

-- HORIZONTAL: force toward a target velocity, plus the turn carry (C172Phys). Touches no
-- wheel, no throttle and no steering - it pushes the rigid body.
local function javaDriveHorizontal(v, tvx, tvy, gain, maxForce, frameScale, yawRate, dt, mass)
    local ok, applied = tcall(C172Phys, "c172DriveHorizontal", v, tvx, tvy, gain, maxForce,
                              frameScale, yawRate, dt, mass)
    return ok and applied == true
end

local function javaNum1(name, v)
    local fn = bridgeFn(name)
    if not fn then return nil end
    local ok, r = pcall(fn, v)
    if ok and type(r) == "number" and r == r then return r end
    return nil
end

local function javaForwardX(v) return javaNum1("c172ForwardX", v) or 0 end
local function javaForwardY(v) return javaNum1("c172ForwardY", v) or 0 end

-- VERTICAL: a PD controller toward a real target height in metres, gravity-compensated.
local function javaLiftBody(v, targetH, kp, kd, gravity, mass, maxForce, errUp, errDown)
    local ok, applied = tcall(C172Phys, "c172LiftBody", v, targetH, kp, kd, gravity, mass,
                              maxForce, errUp, errDown)
    return ok and applied == true
end

local function javaSetFlightState(v, value) tcall(C172Phys, "c172SetFlightState", v, value) end

-- Height of the highest solid floor at or below the aircraft, in the same unit the lift
-- controller works in (0 = ordinary ground). Fails to 0 - "flat world", never worse.
local function javaSurfaceHeight(v)
    local h = javaNum1("c172SurfaceHeightBelow", v)
    if h and h >= 0 then return h end
    return 0
end

local function javaSetPropRate(v, radPerSec) tcall(C172Phys, "c172SetPropRate", v, radPerSec) end

local function javaSetTiresRemoved(v, removed)
    local ok, applied = tcall(C172Phys, "c172SetTiresRemoved", v, removed)
    return ok and applied == true
end

local function javaWheelsOnGround(v) return nil end

local function javaBodyHeight(v) return javaNum1("c172GetBodyHeight", v) end
-- Total airframe tilt (pitch + roll), degrees.
local function javaBodyTilt(v) return javaNum1("c172BodyTiltDeg", v) end

-- REAL horizontal velocity of the physics body, m/s, read now.
local function javaVelX(v) return javaNum1("c172GetVelX", v) or 0 end
local function javaVelY(v) return javaNum1("c172GetVelY", v) or 0 end

-- Level, heading kept, seated at the storey's resting height (C172Phys); forced with -1.
local function javaLevelGround(v, maxTiltDeg, level)
    local ok, r = tcall(C172Phys, "c172LevelGroundAttitude", v, maxTiltDeg, level)
    if ok and type(r) == "number" then return r end
    return nil
end

-- ------------------------------------------------------------------- input
--
-- INPUT ISOLATION IS STRICT AND IS THE FIRST THING EVERY PATH DOES.
-- A raw Keyboard.isKeyDown() poll reports a key as down even while that same keystroke
-- is going into a text field, so without the guard below a player typing in chat while
-- seated would also be flying the aircraft. It FAILS OPEN - any error, or a build with
-- no ISChat, returns "input allowed" and never grounds the pilot mid-flight.
--
-- Beyond that, no key is even READ unless the local player is currently the DRIVER of a
-- vehicle whose script name is this aircraft's. Walking, riding as a passenger, driving
-- a vanilla car, flying the MiG and flying the Wraith all fail that test before any
-- key poll happens at all - see onTick.
local W_KEY = Keyboard.KEY_W
local S_KEY = Keyboard.KEY_S
local A_KEY = Keyboard.KEY_A
local D_KEY = Keyboard.KEY_D

local function textEntryHasFocus()
    local ok, focused = pcall(function()
        local chat = ISChat and ISChat.instance
        local entry = chat and chat.textEntry
        if entry and entry.isFocused and entry:isFocused() then return true end
        return false
    end)
    return ok and focused == true
end

local function keyDown(key)
    if textEntryHasFocus() then return false end
    return Keyboard.isKeyDown(key)
end

-- ------------------------------------------------------------------- tuning
--
-- Grouped into ONE table rather than left as ~50 file-level locals on purpose: Kahlua
-- caps a closure at 60 upvalues, and a flat constant list plus the helpers above walks
-- straight into that ceiling. Homebrew's luac (5.5) does NOT report this - it needs a
-- real Lua 5.1.5 to catch - so the cheap structural fix is used instead of relying on a
-- pre-flight check.
--
-- THESE ARE THE NUMBERS THAT MAKE THIS A CESSNA. The MiG's equivalents are quoted
-- beside each one, because "not simply a slower MiG" is a specific, checkable claim and
-- these are where it is actually delivered.
local TUNE = {
    -- ---- speed -----------------------------------------------------------------
    -- Cruise ceiling in simulated airspeed. MiG: 175. A 172 tops out well under half a
    -- fighter's game speed, and this is the single most visible difference in the air.
    -- SLOWED IN 0.1.12 at Jay's request - it should read as a light aircraft next to the
    -- MiG, which runs 175. 95 is 54% of the jet, and against the real pair (a 172 cruises
    -- ~226 km/h, a MiG-29 ~2400) the game's ratio is far kinder to the Cessna than reality
    -- would be, which is the right call for something you actually have to fly around.
    MAX_AIRSPEED_KMH   = 95,
    -- Floor, so the aircraft can never command a zero-length drive vector.
    LOW_SPEED_FLOOR_KMH = 12,
    -- Throttle authority, km/h gained per SECOND with W held. MiG: 24. At 6.5 it takes
    -- roughly ten seconds to go from rotation speed to cruise - a real, felt spool-up
    -- rather than a jet's shove. This is where "much lower acceleration" and "no instant
    -- acceleration" actually come from; the drive FORCE below is left with full
    -- authority so that combined thrust-and-turn still converges properly.
    AIRSPEED_RATE      = 6.5,
    -- Drag bleed with the throttle closed, km/h per second. MiG: 8. A 172 has a glide
    -- ratio of about 9:1 - it slows gently and keeps flying, so this is deliberately
    -- soft. It is also what stops the aircraft feeling like it hits a brake in mid-air.
    DRAG_DECEL_RATE    = 4.0,
    -- Hands-off recovery toward the level-flight speed with the engine running. Slower
    -- than either the throttle (6.5) or drag (4.0), so it reads as the aircraft settling
    -- rather than as an autopilot taking over.
    CRUISE_RECOVER_RATE = 2.5,
    -- S IN THE AIR = BRAKE (09-25). Jay: "s should act as a brake almost for cessna, i was
    -- trying to slow it down and couldnt". It could not, and not because the rate was low:
    -- this used to be THROTTLE_DOWN_RATE = 9.0, and the audio block further down defines its
    -- own THROTTLE_DOWN_RATE = 0.55 (throttle-lever units/s). In one Lua table constructor the
    -- LATER key wins, so the airspeed model was braking at 0.55 km/h per second - nothing.
    -- Renamed so the two can never collide again, and made the MiG's air brake: holding S
    -- sheds speed at AIR_BRAKE_RATE down to AIR_BRAKE_FLOOR_KMH (above the 39.6 stall, below
    -- the 55 rotation speed), so braking slows and settles it but never stalls it; let go and
    -- cruise power brings it back.
    -- 12 -> 6 (09-26, Jay: "i never want s to fully land the aircraft just act as a small
    -- controlled brake"): half the bite, so S trims speed rather than stamping on it.
    AIR_BRAKE_RATE     = 6.0,   -- km/h per second while S is held (MiG: 9)
    -- 45 -> 62 (09-26, Jay: "cessna just dropped alt to ground"). 45 was above the stall but
    -- BELOW the level band (LEVEL_FLIGHT_KMH 70 - LEVEL_BAND_KMH 8 = 62): speed under the band
    -- descends, and under the 55 rotation speed lift authority fades too, so holding S sank the
    -- aeroplane ~1 m/s and "stalled back onto the ground" within seconds. S now brakes to the
    -- bottom of the band and HOLDS HEIGHT there; descending stays with the Land option / engine.
    AIR_BRAKE_FLOOR_KMH = 62,
    -- Automatic deceleration once LANDING is requested. MiG: 15.
    LANDING_DECEL_RATE = 4.5,
    -- Simulated airspeed is handed to the real drivetrain on touchdown, capped here.
    -- High enough that the rollout is a real rollout the player steers and brakes through.
    TOUCHDOWN_SPEED_CAP = 70,

    -- ---- energy: the speed at which the aircraft flies LEVEL ---------------------
    -- This is what makes climb, cruise and descent all fall out of one control.
    --
    -- A light aircraft's vertical behaviour is energy management: with a fixed-pitch
    -- prop, excess speed becomes climb and a speed deficit becomes descent. So altitude
    -- here is driven by airspeed relative to LEVEL_FLIGHT_KMH rather than by a separate
    -- up/down lever:
    --      faster than the band -> climbs, proportionally
    --      inside the band      -> holds altitude (this is CRUISE)
    --      slower than the band -> descends, proportionally
    -- The band exists so level flight is actually HOLDABLE with a keyboard. Without it,
    -- level flight would be a single exact speed the pilot could only ever pass through,
    -- and "stable cruising" would not exist as a state.
    --
    -- This also fixes a real bug rather than only adding a feature: with vertical speed
    -- keyed off "is the throttle held", releasing the throttle at cruise still commanded
    -- a full-rate CLIMB (climbRatio was 1.0 at any speed at or above rotation speed), so
    -- the aircraft climbed to its ceiling and STAYED there - there was no way to descend
    -- at all short of requesting a landing or stalling it. Verified by simulating the
    -- kinematics: 15 seconds of closed throttle left vertical speed still positive.
    -- Lowered with MAX_AIRSPEED_KMH above, keeping the same shape: the level band
    -- (70 +- 8 = 62..78) stays comfortably above the 39.6 stall (minTakeoffSpeedKmh 55 x
    -- STALL_SPEED_RATIO 0.72) and comfortably below the 95 ceiling, so climb, cruise and
    -- descent are all still reachable with room either side.
    LEVEL_FLIGHT_KMH   = 70,
    LEVEL_BAND_KMH     = 8,

    -- ---- stall -----------------------------------------------------------------
    -- Stall speed as a fraction of rotation speed, and how fast the aircraft sinks with
    -- no lift authority left. It MUSHES downward rather than dropping a wing: a
    -- departure would be realistic and would also be unrecoverable with three keys.
    STALL_SPEED_RATIO  = 0.72,
    STALL_SINK_RATE    = 0.55,

    -- ---- turning ---------------------------------------------------------------
    -- Degrees per second at/below LOW_SPEED_FLOOR and at/above MAX_AIRSPEED.
    -- MiG: 100 / 64. Roughly 40% of the jet's authority, which is what "softer turns"
    -- and "noticeably slower yaw response" mean in practice - a 172 is flown in wide,
    -- lazy arcs, and this is the number that makes it feel that way.
    -- RAISED IN 0.1.12 at Jay's request (was 42/27, which he found too slow). The MiG
    -- runs 100/64; 70/48 is noticeably quicker than before while still reading as an
    -- aeroplane being flown rather than a fighter. Per the jet mod's own note, turn rate
    -- is unrelated to YAW_RESTORE_GAIN's stability - it does not feed that loop - so
    -- these two can be moved independently.
    -- Lowered for a light prop aircraft (was 70/48). The brief asked for "noticeably
    -- slower yaw response" and these were still jet-like; they also fed the takeoff flip,
    -- since a fast commanded yaw means a bigger heading delta for the momentum restore to
    -- chase every tick.
    TURN_RATE_LOW_DEG  = 55,
    TURN_RATE_HIGH_DEG = 38,
    -- How fast turn input eases in and out. MiG: 12.0. Lower is softer on entry and
    -- exit, so a turn rolls in gradually instead of snapping.
    -- Raised 4.5 -> 6.5 with the turn rates above: a higher rate that still eases in
    -- slowly just feels laggy on the stick. MiG uses 12.0.
    -- Raised 6.5 -> 9.0. This is how fast turn INPUT ramps in, and at 6.5 there was a
    -- noticeable lag between pressing A/D and the aircraft actually starting to come round,
    -- which reads as unresponsive rather than as a heavy aeroplane. Still eased, not
    -- instant - the smoothing is what keeps simultaneous throttle and turn from fighting.
    TURN_SMOOTH        = 9.0,
    -- Turn authority ramps from TURN_EASE_IN_FLOOR to full over this long after leaving
    -- the ground, so the first moment of flight - when the tires have just come out of
    -- physics and there is nothing holding the airframe flat - cannot be met with full
    -- yaw authority. This SCALES the rate; it never gates the input. That distinction
    -- matters: the MiG once had a hard 3-second straight-flight LOCK here and it had to be
    -- removed because "turning during takeoff does nothing" is a worse bug than the one it
    -- was papering over. Input is always read, always smoothed, always does something.
    TURN_EASE_IN_SEC   = 1.6,
    TURN_EASE_IN_FLOOR = 0.35,
    -- ATTITUDE HOLD (1.9.0). The Java build CENTRED the airframe by teleporting it back onto
    -- the commanded heading whenever it drifted past a tolerance (2 deg low, 1 deg at cruise),
    -- at most every 0.12 s - the "auto-straightening" Jay felt, and a teleport each time. Now a
    -- torque holds the commanded heading, pitch and bank continuously (C172Phys.holdAttitude;
    -- its spring/damper numbers live in C172Phys.ATT), so there is nothing to snap back.
    -- The one guard kept from that design: the commanded heading may never run more than this
    -- far ahead of the real nose (a knock from a building, a slow body). Unchecked, the hold
    -- would later unwind the whole difference as a spin.
    HEADING_LEAD_MAX_RAD = 0.6,
    -- Ground contacts (bushes, fences, zombies - C172Contacts) are switched off while the
    -- airframe is this far above where it sits on its wheels, and back on below it.
    CONTACTS_CLEAR_M = 1.0,
    -- EMERGENCY PITCH GUARD. How far the airframe itself may pitch off level in the air
    -- before it is put back level by hand (C172Phys.levelKeepHeading - a teleport that keeps
    -- heading and height). The torque hold aims for at most 8 degrees nose-up (the takeoff
    -- rotation), so this never fires in healthy flight; it exists because the identical
    -- runaway is documented on the GROUND (9.8 -> 89.8 degrees in one second, ending in
    -- vanilla's "Forward Direction cannot be zero length vector" exit), and an emergency
    -- catch costs nothing while it does not fire. Must stay well under the ~78 degrees at
    -- which the forward vector stops yielding a usable heading.
    BODY_PITCH_MAX_DEG = 15.0,
    -- Parked body height above the surface, measured across logged landings (1.47-1.74) and
    -- matching RIGHT AIRCRAFT's 1.53 spawn height. The gear datum measured at takeoff is
    -- clamped into this band so one bad reading cannot aim a landing into the ground.
    GEAR_DATUM_MIN = 0.75,
    GEAR_DATUM_MAX = 1.55,

    -- ---- vertical --------------------------------------------------------------
    -- Altitude units per second. MiG: 0.7 / 0.8. A 172 climbs at about 700 fpm against
    -- a fighter's tens of thousands, and the game-scale equivalent is this much slower.
-- CLIMB. Raised again 2026-08-31 (0.32 -> 0.42 -> 0.80) because the climb-out was
    -- still a long wait: at 0.42 the new 8.0 ceiling would have taken ~19 s. At 0.80 it is
    -- ~10 s, which reads as a real climb without the aircraft leaping. The responsiveness
    -- comes from VS_RAMP as much as from this number - see there.
    CLIMB_RATE         = 1.50, -- 2.55 real metres/second
    DESCEND_RATE       = 1.30, -- 2.21 real metres/second, eased into the flare
    -- How fast vertical speed eases toward its target. MiG: 3.0. Halved, so pitch
    -- changes are gradual and the nose does not snap up the instant W is pressed.
    -- How fast vertical speed converges on its target - this, not CLIMB_RATE, is what
    -- "accelerates naturally into a climb" actually means. 2.2 gives a ~0.45 s time
    -- constant: the nose comes up over about half a second instead of the aircraft
    -- stepping instantly to full climb rate (which is what a high value would do) or
    -- taking 2 s to respond (1.5, the previous value).
    VS_RAMP            = 2.2,
    -- Fixed world-height cruise, above the standard 32-storey map envelope.
    -- The old low ceiling kept the model near a terrain-pinned camera. Presentation
    -- now tracks the physical height continuously, with matching occupant depth range.
    CRUISE_BODY_H      = 86.0,
    MAX_ALTITUDE       = 52.0, -- altitude units; also within the server's 60-unit limit
    CRUISE_ALTITUDE    = 1.3,   -- TAKEOFF -> AIR above this
    TREE_CLEAR_ALTITUDE = 1.2,  -- above this the airframe is treated as over the canopy
    FLARE_ALTITUDE     = 0.9,
    FLARE_MIN_RATIO    = 0.22,

    -- ---- lift controller (real metres, fed to the Java PD controller) -----------
    LIFT_HEIGHT_SCALE  = 1.7,   -- metres of REAL body height per altitude unit
    -- Display-only multiplier; physical cruise height is CRUISE_BODY_H.
    HUD_ALT_MULT       = 3.0,
    -- SURFACE AWARENESS (roof / elevated-structure protection).
    ROOF_CLEARANCE_M   = 2.5,   -- minimum body height above any solid surface, airborne (2.2 -> 2.5 09-25, the MiG's value)
    ROOF_CLEARANCE_CAP_M = 2.0, -- clearance may lift it at most this far above the ceiling (MiG)
    ROOF_LOOKAHEAD_SEC = 2.0,   -- roofs are looked for this much flight time ahead (MiG)
    HARD_MAX_BODY_H    = 90.0,
    TARGET_RISE_M_SEC  = 3.0,
    TARGET_FALL_M_SEC  = 2.5,
    SURFACE_SAMPLE_SEC = 0.06,  -- how often the surface below is re-probed (~15 Hz)
    -- How fast the SMOOTHED surface height may follow the raw probe. The probe is a step
    -- function at every roof edge; without this the commanded height jumps metres in one
    -- tick and the aircraft visibly lurches. Comfortably faster than any climb rate, so it
    -- never becomes the limiting factor in normal flight.
    SURFACE_RATE_M_PER_SEC = 9.0,
    -- HIGH-ALTITUDE FAILURE PROTECTION. If the real Bullet body ends up this far BELOW the
    -- height we commanded, for this long, something outside this mod moved it - vanilla's
    -- own fall-out-of-the-world recovery, a collision, or a chunk load. Rather than let the
    -- lift controller fight an engine-side reposition (which is what "the aircraft becomes
    -- broken" looked like), we adopt reality and carry on from there.
    ALT_DESYNC_M       = 4.0,
    ALT_DESYNC_SEC     = 0.5,
    SURFACE_HOLD_KP    = 3.2,   -- gentle PD used to hold the aircraft on an elevated
    SURFACE_HOLD_KD    = 3.0,   -- surface while parked/taxiing on it
    LIFT_KP            = 5.0,   -- MiG: 6.0 - a touch softer, so height settles rather
    LIFT_KD            = 4.2,   --            than snapping to the commanded value
    LIFT_GRAVITY       = 9.81,
    LIFT_MASS          = 1000,  -- fallback only; real mass is read from the vehicle
    LIFT_MAX_FORCE     = 56000, -- MiG: 64000, scaled for this airframe's lower mass
    LIFT_ERR_UP        = 3.5,
    LIFT_ERR_DOWN      = 2.5,

    -- ---- horizontal drive authority --------------------------------------------
    -- NOT reduced from the MiG's values, on purpose. These govern how fast the body
    -- converges on the COMMANDED velocity; the commanded velocity itself is what ramps
    -- slowly (AIRSPEED_RATE above). Cutting them would not make the aircraft feel
    -- lighter - it would make it feel mushy and unresponsive, and specifically it would
    -- reintroduce the combined thrust-plus-turn convergence gap that DRIVE_MAX_FORCE was
    -- raised to 6000 to close (a simultaneous speed error and direction error is one
    -- bigger error vector needing both corrections at once).
    DRIVE_GAIN         = 280,
    DRIVE_MAX_FORCE    = 6000,
    -- Closed-loop speed authority, see applyFlightForces. Inert in straight flight.
    -- Written for the Java build, whose teleport turns threw the speed away 45 times a second
    -- and had to have it put back: this compares the body's REAL speed with the commanded
    -- one and gives the drive proportionally more authority while it is behind. Turns no
    -- longer lose speed (1.9.0: torque turns plus the turn carry in the drive), so it is now
    -- simply a backstop - after a bump, a building, a slow climb-out - and inert otherwise.
    SPEED_DEFICIT_TOL_MS = 0.25,  -- m/s of shortfall tolerated before boosting at all
    DRIVE_BOOST_PER_MS   = 2.4,   -- extra authority per m/s of shortfall
    DRIVE_BOOST_MAX      = 9.0,   -- hard ceiling, so this can never become a catapult
    -- (YAW_RESTORE_GAIN / YAW_RESTORE_MAX_FORCE are gone with the teleport turns they
    -- tuned: there is no momentum to restore when the heading is never rewritten.)

    -- ---- state machine ---------------------------------------------------------
    -- EMERGENCY tilt guard, not an attitude controller. At 4.0 (0.1.9) this fired
    -- continuously, and because it teleports the body it overwrote the physics engine
    -- every tick and the aircraft could not build speed at all. The tail-sit is fixed at
    -- source now (main gear moved aft in vehicle_cessna172.txt, margin 3.15x -> 8.86x),
    -- so this should never fire in normal driving. 25 degrees is far past anything
    -- ordinary and still far short of the ~90 at which vanilla throws a zero-length
    -- forward vector and the game exits. If the log shows it firing while taxiing, the
    -- ground geometry has regressed - fix that, do not lower this.
    -- ATTITUDE - since 1.9.0 the REAL airframe's, held by torque (C172Phys.holdAttitude); up
    -- to 1.8.1 it was drawn on by the Java render patch over a body kept level.
    -- Nose-up at rotation, which then WASHES OUT over PITCH_TAKEOFF_DECAY_SEC instead of
    -- being held for the whole climb. Holding it was the "yaw up on takeoff sits at max and
    -- has to auto-straighten" complaint: a real aircraft rotates, then settles to a shallow
    -- climb attitude - it does not fly the entire climb-out with the nose pinned up.
    PITCH_TAKEOFF_DEG  =  8.0,
    PITCH_TAKEOFF_DECAY_SEC = 3.0,
    PITCH_TAKEOFF_RESIDUAL  = 0.30,  -- fraction of the rotation attitude it settles to
    -- Lowered 9 -> 5: a steady climb should read as a gentle nose-up, not a maximum-pitch
    -- attitude held for the entire ascent.
    PITCH_MAX_UP_DEG   =  5.0,
    PITCH_MAX_DOWN_DEG = 8.0,   -- nose-down is deliberately shallower than nose-up
    PITCH_FLARE_DEG    = 7.0,   -- nose-up during the landing flare
    PITCH_EASE_RATE    = 1.8,   -- per second; low so the nose settles rather than snaps
    -- BANK. Two values now, not one: a light aircraft manoeuvring at taxi speed barely
    -- leans, and the same aircraft turning at cruise is properly banked over. Scaling the
    -- target with airspeed is what makes the two read differently, and it is also what a
    -- real aeroplane does - bank angle for a given RATE of turn rises with speed.
    --
    -- 1.9.0: the airframe really banks (the torque hold aims for st.bank); 1.8.x only drew
    -- it. Lift is applied straight up and the drive along the heading whatever the bank, so
    -- banking never pulls the aircraft sideways or down - it is the look of the turn, and
    -- the hold keeps it far from the ~78 degrees where vanilla's "Forward Direction cannot
    -- be zero length vector" lives.
    --
    -- 26 degrees at cruise is a normal-category turn, not aerobatics, and it is reached
    -- only at the speed ceiling with the input fully deflected. The easing is unchanged
    -- in kind and slightly slower in rate, so roll-in and roll-out stay smooth: bank
    -- follows st.turnInput, which is ITSELF already eased by TURN_SMOOTH, so there are two
    -- first-order lags between the key and the wing and no way for it to snap.
    BANK_MIN_DEG       = 7.0,   -- full deflection at the low-speed floor
    BANK_MAX_DEG       = 26.0,  -- full deflection at MAX_AIRSPEED_KMH
    BANK_EASE_RATE     = 2.2,
    GROUND_MAX_TILT_DEG = 25.0,

    MODE_COOLDOWN_SEC  = 1.5,   -- blocks instant re-toggling between ground and air
    TAKEOFF_LOCKOUT_SEC = 3.0,  -- TAKEOFF climbs on its own for at least this long
    -- Hard guarantee against ever being stuck airborne. Raised with the ceiling: a
    -- descent from 8.0 units plus the flare is ~14 s, and this must stay comfortably
    -- above a legitimate landing or the safety net would start firing during normal ones.
    LANDING_TIMEOUT_SEC = 100,
    -- How far above the surface the REAL airframe may still be when a landing is allowed to
    -- finish, in metres of body height. Measured, not guessed: across every logged Cessna
    -- landing the body read 1.47-1.71 m above the surface at "landing complete" (a parked or
    -- rolling airframe sits at 1.47-1.74 on its wheels), while the two landings that dropped
    -- the aircraft finished with it at 5.80 and 4.88 m. 2.5 sits clear of both groups.
    LANDING_BODY_ARRIVED_M = 2.5,
    -- REAL TOUCHDOWN, MEASURED FROM THE GEAR (09-25). With the 1.8.0 gear datum the airframe
    -- is ~1.47 m up when it sits on its wheels, so the 2.5 m test above released it a full
    -- metre in the air: Jay's 09-25 landing logged "touchdown: airframe 2.49 m above the
    -- surface (gear datum 1.47)", the tires came back mid-air, it dropped, and it had to be
    -- RIGHT AIRCRAFT-ed out of the ground. It now completes within this much of the datum -
    -- the MiG's rule (0.3 altitude units, ~0.5 m), which Jay reports lands cleanly - and the
    -- final approach aims this far BELOW the datum so the body actually reaches that band
    -- instead of creeping toward it.
    TOUCHDOWN_DATUM_M = 0.08,
    -- 0.25 -> 0.05 (09-25 second log): aiming a quarter-metre under the gear made the final
    -- metres a 1.5-2 m/s drop. The touchdown seat now removes any leftover sink anyway.
    LANDING_FINAL_SINK_M = 0.05,
    -- Coming down from the air within this much of its gear datum, a landing seats the
    -- airframe on its wheels (see enterGroundMode). Above that it is NOT teleported down.
    TOUCHDOWN_SEAT_MAX_M = 1.5,
    -- A final approach that still has not reached the gear band after this long (something
    -- under it, a slope) completes anyway; the settle check below then seats it.
    TOUCHDOWN_WAIT_SEC = 8.0,
    -- Hold the airframe dead level on the landing approach, not merely under
    -- BODY_PITCH_MAX_DEG: a tail-low body is what the wheels come back onto.
    LANDING_LEVEL_DEG = 3.0,
    -- TOUCHDOWN SETTLE. For this long after touchdown, an airframe that is tipped past
    -- TOUCHDOWN_MAX_TILT_DEG or sunk more than TOUCHDOWN_SUNK_M below its datum, for longer
    -- than TOUCHDOWN_BAD_SEC, is put back on its wheels exactly as RIGHT AIRCRAFT does (level,
    -- vanilla resting height, heading kept). At most twice per landing.
    TOUCHDOWN_SETTLE_SEC = 5.0,
    TOUCHDOWN_MAX_TILT_DEG = 18.0,
    TOUCHDOWN_SUNK_M = 0.35,
    TOUCHDOWN_BAD_SEC = 0.4,
    -- How long after touchdown the "the pilot shut it down in flight" latch keeps asserting
    -- the engine OFF. Long enough to outlast whatever re-enables it as the vehicle rejoins
    -- vanilla's ground path, short enough that a deliberate restart a moment later is the
    -- player's and is left alone.
    -- How long the engine must have been continuously running before a shutdown counts as
    -- deliberate. Below this it is treated as ignition-state noise and ignored - see the note
    -- on the engine-off latch in onTick.
    ENGINE_SETTLED_SEC = 2.5,
    -- How long after a shutdown the hold may still act. Vanilla's spurious restart lands
    -- within a moment of the ground transition; anything later is the pilot.
    HOLD_WINDOW_SEC = 2.5,
    MP_PUBLISH_INTERVAL_SEC = 0.5,

    -- ---- propeller -------------------------------------------------------------
    -- Revolutions per second, idle and full power. Chosen against the frame rate, not by
    -- eye: a two-blade propeller is 180-degree symmetric, so it becomes ambiguous (and
    -- visually reverses) past 90 degrees of rotation per RENDERED frame. 11 rev/s is
    -- 66 deg/frame at 60 FPS and 33 at 120, so it stays unambiguous even on a slow
    -- machine while still reading as a fast blur. It is also driven from measured
    -- wall-clock time, not a per-tick constant, so the real rate does not scale with
    -- frame rate - which is exactly the bug that made the VX-9's rotor look "wobbly".
    PROP_IDLE_HZ       = 4.5,
    PROP_FULL_HZ       = 11.0,
    PROP_SPOOL_UP_SEC  = 3.2,   -- engine start -> idle RPM
    PROP_SPOOL_DOWN_SEC = 4.5,  -- shutdown -> stopped, windmilling down

    -- ---- audio -----------------------------------------------------------------
    -- Master volume for everything this mod plays on the vehicle's emitter: both engine
    -- loops and both one-shots. Lowered to 0.60 in 0.1.11 at Jay's request - the engine
    -- bed was louder than the rest of the game. This is the ONE number to change if it
    -- needs to move again; the individual mix ratios below stay as they are, so the
    -- balance between idle, power, start and shutdown is unchanged, just quieter.
    MASTER_VOLUME      = 0.60,

    AUDIO_EASE_RATE    = 2.4,   -- volume ease per second

    -- ---- THROTTLE MODEL (2026-08-31) -------------------------------------------
    -- REPLACES the previous "RPM is a direct function of which keys are down this tick"
    -- scheme, which is what produced "at maximum speed it keeps replaying an
    -- acceleration section instead of settling". The mechanism was exact and worth
    -- recording: RPM was computed from airspeed, then HARD-CAPPED to
    -- RPM_NO_THRUST_CAP = 0.62 on any tick W was not held. Cruising at the ceiling with
    -- W tapped rather than pinned - which is how the aircraft is actually flown - swung
    -- the target between 1.00 and 0.62 every time the key changed state, and 0.62 to
    -- 1.00 is most of the MID-to-HIGH crossfade. The engine was not replaying anything;
    -- it was being told to accelerate and decelerate several times a second.
    --
    -- A real light aircraft has a throttle LEVER: it holds its setting when you take your
    -- hand off it. So the model is now a lever position that EASES toward a per-mode
    -- target, and it never returns to idle in flight - hands off means cruise power, not
    -- closed throttle. Key state moves the target; the lever, and therefore the audio,
    -- can only move at a bounded rate.
    THROTTLE_IDLE        = 0.10,  -- running, parked, no input
    THROTTLE_GROUND_OPEN = 0.85,  -- W on the ground: the takeoff roll / a fast taxi
    THROTTLE_CLIMB       = 1.00,  -- W airborne: full power
    THROTTLE_CRUISE      = 0.66,  -- airborne, hands off - the aeroplane keeps flying
    THROTTLE_DESCENT     = 0.38,  -- S airborne: power back
    THROTTLE_LANDING     = 0.30,  -- on final
    -- Asymmetric on purpose. A piston engine picks up revs faster than it sheds them,
    -- and the slow closing rate is also what removes the last of the audible stepping:
    -- the lever physically cannot jump even if the keys do.
    THROTTLE_UP_RATE     = 1.10,  -- lever units per second, opening
    THROTTLE_DOWN_RATE   = 0.55,  -- lever units per second, closing

    -- ---- RPM, DERIVED FROM THE LEVER AND THE AIRSPEED --------------------------
    -- A fixed-pitch propeller unloads as the aircraft speeds up, so RPM rises with
    -- AIRSPEED at a constant throttle as well as with the lever itself. Both terms, so
    -- the sound tracks what the aeroplane is doing and not just what the pilot pressed.
    RPM_THROTTLE_SHARE = 0.62,
    RPM_SPEED_SHARE    = 0.38,  -- must sum to 1.0 with the line above
    RPM_MIN_RUNNING    = 0.08,  -- a running engine is never silent, even parked
    RPM_EASE_RATE      = 2.2,   -- how fast the RPM parameter may move, per second
    -- HARD slew limit on top of the ease, in RPM units per second. The ease alone is
    -- proportional, so a large target change still moves fast on its first tick; this
    -- guarantees a bounded worst case, which is what "no hard transitions between RPM
    -- ranges" means as a property rather than a hope. 0.55 means a full 0 -> 1 sweep
    -- cannot take less than 1.8 s.
    RPM_MAX_STEP_PER_SEC = 0.55,
    RPM_GAIN_FLOOR     = 0.45,  -- overall loudness at idle, rising to 1.0 at full RPM
    -- Deadband on setVolume. Below this the volume is not rewritten at all: at 45 Hz a
    -- stable cruise otherwise pushes three FMOD calls a tick that change nothing.
    VOL_EPSILON        = 0.004,
    STARTUP_LENGTH_SEC = 2.85,  -- real length of C172EngineStart.wav
    SHUTDOWN_LENGTH_SEC = 4.26, -- real length of C172EngineShutdown.wav
    ONESHOT_FADE_PER_SEC = 1.4,

    -- ---- other-aircraft sweep (multiplayer visuals/audio, zero packets) ---------
    SWEEP_INTERVAL_SEC = 0.5,
    SWEEP_RADIUS_TILES = 60,
    -- DISTANCE FADE (1.9.0). The engine loops are file sounds, and FMOD's inverse rolloff on
    -- those never reaches silence - a running Cessna stayed audible right out to the sweep's
    -- edge (the MH-92's "I can still hear it walking far away"). Full volume within
    -- SOUND_FADE_START tiles of the nearest local player, silent by SOUND_FADE_END, smooth in
    -- between. Every client fades for its own players, so it holds in multiplayer too.
    SOUND_FADE_START = 25,
    SOUND_FADE_END   = 60,
}

local KMH_TO_MPH = 0.621371
local TWO_PI     = math.pi * 2

-- An angle wrapped into (-pi, pi]. NOT with %: Kahlua's % keeps the sign of the left side
-- (-7 % 3 is -1 in the game, 2 in desktop Lua), so `(a - b) % (2 * pi)` of a negative
-- difference came back near -2 pi in the game and read as a full turn of "drift". Caught in
-- 1.9.0 by flying this file in the game's own Lua VM (tools/tests/native).
local function wrapPi(a)
    return a - math.floor((a + math.pi) / TWO_PI) * TWO_PI
end

-- Verbose per-second flight telemetry. OFF for release - it is a real per-tick string
-- format and print in the hot path. Flip to true when diagnosing a flight problem.
local FLIGHT_VERBOSE_LOG = false

-- HIGH-ALTITUDE DIAGNOSTIC. Two fixes for the flicker/tower problems have now been shipped
-- on reasoning alone and neither worked, so this build MEASURES instead of guessing again.
-- One line per second while airborne, reporting the things that decide whether the aircraft
-- is drawn and whether it collides:
--   logicalZ  the grid level the engine keeps the vehicle on (C172Presentation borrows a
--             roof level for drawing only, and hands it back before the next update).
--   pinFires  (Java build only - always -1 now)
--   colliding vanilla's own jniIsCollide flag - true means the CHASSIS is in contact with
--             world geometry, i.e. Bullet static collision, which no Java predicate patch
--             can suppress.
-- OFF FOR RELEASE (2026-09-01). Both problems it was built to measure - the high-altitude
-- flicker and the aircraft being drawn as a black shadow over buildings - are fixed and
-- confirmed, and this printed a formatted line every second for the whole time the
-- aircraft was airborne, straight into the console. Turn it back on only to diagnose
-- another rendering or collision problem in flight; it reports the pinned logical level,
-- a Java-side proof that the pin advice actually ran, and vanilla's own jniIsCollide flag.
local ALT_DIAG = false

-- GROUND DIAGNOSTIC. Prints one line per second while the local player is sitting in a
-- grounded Cessna, covering every link in the "engine runs but it will not move" chain:
-- vanilla's own engine/transmission values, whether the wheels are actually finding the
-- ground, and the real Bullet body state. ON for this build because the aircraft does not
-- currently roll and guessing at it from screenshots is slower than measuring it. Set to
-- false once the cause is found.
-- BACK ON in 0.1.13 for the "cannot reverse while taxiing" report, and this is the right
-- tool for it rather than another guess: reverse is entirely vanilla's drivetrain (this
-- mod never reads S on the ground), the vanilla reverse path was decompiled and has no
-- gate this aircraft trips, and every previous ground bug here - the tail-sit, the crash,
-- the buried leveller - was found by this line and not by reasoning from outside.
-- Turn it off again once reverse is settled; it prints a long line every second.
local GROUND_DIAG = false

-- How often the "you cannot fly this" refusal may be shown. The takeoff test runs every tick
-- while the throttle is open and the aircraft is above rotation speed, so this is the
-- difference between one message and forty-five a second.
local REFUSE_MESSAGE_SEC = 5.0

-- WHICH PART IS REFUSING TO OPERATE.
--
-- BaseVehicle.updateControls() - the ONLY thing that turns a held W into
-- clientControls.forward, which is the ONLY thing CarController.update() ever converts
-- into engine force - opens with `if (!this.isOperational()) return;`. isOperational()
-- walks every part, and for each one that declares a `checkOperate` Lua function in its
-- script it calls it; a SINGLE part answering anything other than true disables all
-- driving input for the whole vehicle, silently: no log line, no error, no visible
-- difference other than the vehicle not moving. (Read out of the bytecode, not assumed.)
--
-- Vanilla ships exactly one checkOperate - Vehicles.CheckOperate.Tire - and its body
-- begins `if true then return true end`, so on a stock install this can never be the
-- cause. It becomes possible only when another mod adds or replaces one, and several
-- installed here work on vehicle parts. This probe therefore names the culprit directly
-- rather than leaving "operational=false" as an unattributed dead end.
--
-- Java cannot do this: BaseVehicle.callLuaBoolean is PRIVATE, so the check has to be
-- re-run from the side the functions actually live on. Every step is pcall-wrapped and
-- the whole thing is skipped unless GROUND_DIAG is on, so it costs nothing at release.
local function resolveGlobalFunction(path)
    local node = _G
    for name in string.gmatch(path, "[^%.]+") do
        if type(node) ~= "table" then return nil end
        node = node[name]
    end
    if type(node) == "function" then return node end
    return nil
end

local function probeCheckOperate(vehicle)
    local failing, missing, checked = {}, {}, 0
    local okCount, count = pcall(function() return vehicle:getPartCount() end)
    if not okCount or type(count) ~= "number" then return "partProbe=ERR" end
    for i = 0, count - 1 do
        pcall(function()
            local part = vehicle:getPartByIndex(i)
            if not part then return end
            local fnName = part:getLuaFunction("checkOperate")
            if not fnName or fnName == "" then return end
            checked = checked + 1
            local fn = resolveGlobalFunction(fnName)
            if not fn then
                -- An unresolvable name is itself a hard failure: the engine's own call
                -- returns null for it, which is not TRUE, so the vehicle is not operational.
                table.insert(missing, (part:getId() or "?") .. ":" .. fnName)
                return
            end
            local okCall, result = pcall(fn, vehicle, part)
            if not okCall or result ~= true then
                table.insert(failing, (part:getId() or "?") .. ":" .. fnName
                    .. "=" .. tostring(okCall and result or "ERROR"))
            end
        end)
    end
    if #failing == 0 and #missing == 0 then
        return ("partProbe=OK(%d checkOperate parts)"):format(checked)
    end
    return ("partProbe=BLOCKED failing=[%s] unresolved=[%s]")
        :format(table.concat(failing, " "), table.concat(missing, " "))
end

local function log(msg)  print("[Cessna172] " .. msg) end
local function warn(msg) print("[Cessna172][WARN] " .. msg) end

-- The flight ceiling is a fixed, measured value - see TUNE.MAX_ALTITUDE for how it was
-- arrived at and why it must not be changed without flying it. This accessor exists so the
-- clamps below read one source of truth rather than repeating the constant.
local function maxAltitude()
    return TUNE.MAX_ALTITUDE
end

local function nowSec()
    local ok, ms = pcall(function() return getTimestampMs() end)
    if ok and type(ms) == "number" then return ms / 1000 end
    return 0
end

-- Cached, because the probe walks grid squares and this is a per-tick path. Sampled at
-- ~15 Hz, which at this aircraft's speeds is well under one tile of travel per sample.
local function updateSurfaceHeight(vehicle, st, dt)
    local t = nowSec()
    if st.surfaceRaw == nil or (t - (st.surfaceAt or 0)) >= TUNE.SURFACE_SAMPLE_SEC then
        st.surfaceAt = t
        st.surfaceRaw = javaSurfaceHeight(vehicle)
        -- ROOF AHEAD (09-25, the MiG's rule - Jay: "mig clears more buildings"). The probe
        -- above only looks straight down, so a tall building was only seen once the aircraft
        -- was already over it. In flight, also look ROOF_LOOKAHEAD_SEC of travel ahead.
        st.surfaceAhead = 0
        if st.mode == "LANDING" and bridgeAvailable() then
            local ahead = bridgeFn("c172RoofHeightAhead")
            if ahead then
                local hd = st.driveHeading or st.heading or 0
                local dist = (st.airSpeed or 0) / 3.6 * TUNE.ROOF_LOOKAHEAD_SEC + 4
                local okA, r = pcall(ahead, vehicle, math.sin(hd), math.cos(hd), dist)
                if okA and type(r) == "number" and r == r and r > 0 then st.surfaceAhead = r end
            end
        end
    end

    -- RATE-LIMITED, and this is the fix for "it looks glitchy sometimes".
    --
    -- The raw probe is a STEP FUNCTION: fly across a roof edge and it jumps from 0 to the
    -- roof height in a single sample. Feeding that straight into the lift target moved the
    -- commanded height several metres in one tick, and the PD controller chased it - so
    -- crossing a building edge produced a visible lurch up, then another down at the far
    -- side. Ramping the value at a fixed rate turns each edge into a short, smooth climb
    -- or descent instead, which is also what an aircraft actually does over an obstacle.
    --
    -- Seeded rather than ramped on the first sample, so entering a vehicle already sitting
    -- on a roof does not spend a second climbing up to its own surface.
    local target = math.max(st.surfaceRaw or 0, st.surfaceAhead or 0)
    -- UP AT ONCE, DOWN RAMPED (09-25). An obstacle below or ahead raises the surface
    -- immediately, as on the MiG - the lift controller's own response is what smooths the
    -- climb, and a ramped rise was what let the Cessna reach a building before it had climbed.
    -- Coming off the far side is still ramped, so the descent stays gentle.
    if st.surfaceH == nil or target > st.surfaceH then
        st.surfaceH = target
    else
        local step = TUNE.SURFACE_RATE_M_PER_SEC * (dt or 0.02)
        local delta = target - st.surfaceH
        if math.abs(delta) <= step then
            st.surfaceH = target
        else
            st.surfaceH = st.surfaceH + (delta > 0 and step or -step)
        end
    end
    return st.surfaceH
end

-- MEASURED frame delta, computed ONCE per tick and read by everything that integrates.
-- Not a fixed 1/60: Events.OnTick's real cadence is not 60 Hz and is not even constant,
-- so integrating against a constant makes every rate in this file silently scale with
-- frame rate. That is precisely the bug that made the VX-9's rotor spin at
-- SPIN_HZ * (FPS/60) and read as "wobbly / not spinning evenly". Clamped at both ends so
-- an alt-tab, a load screen or a stall cannot fling the aircraft on the resuming frame.
local lastTickAt = nil
local tickDt = 1 / 60
-- PHYSICS time of the last frame (1.8.0) - GameTime.getPhysicsSecondsSinceLastUpdate, the
-- clock WorldSimulation itself steps by. Used ONLY to size the per-tick lift force; see
-- LIFT FRAME-RATE SCALING at the lift call. Exactly 1/60 at 60 fps.
local physDt = 1 / 60
local PHYS_STEP_SEC = 0.01
local function updatePhysDt()
    local d = nil
    pcall(function() d = getGameTime():getPhysicsSecondsSinceLastUpdate() end)
    if type(d) == "number" and d == d and d > 0 then
        physDt = math.max(1 / 250, math.min(1 / 15, d))
    end
end
local function updateTickDelta()
    updatePhysDt()
    local t = nowSec()
    if lastTickAt then
        local d = t - lastTickAt
        if d > 0 then tickDt = math.max(1 / 240, math.min(1 / 15, d)) end
    end
    lastTickAt = t
end

-- ------------------------------------------------------------------- state
-- Per-vehicle, keyed by vehicle id, so two Cessnas in one world (or one being flown
-- while another is parked nearby with its engine running) never share flight state,
-- audio handles or propeller phase.
local state = {}
local airborneVehicle = nil   -- the ONE vehicle this client is actively flying, if any

-- Dropped from `state` after this long untouched. A vehicle is "touched" every time
-- getState() hands out its table, which happens on every tick it is flown and on every
-- sweep it is within range for - so this only ever expires an aircraft that has been out of
-- range, unflown and unloaded for minutes.
local STATE_TTL_SEC = 300
local statePruneAt = 0

local function getState(vehicle)
    local id = vehicle:getId()
    if state[id] then state[id].lastSeenAt = nowSec() end
    if not state[id] then
        state[id] = {
            mode           = "GROUND",   -- GROUND | TAKEOFF | AIR | LANDING
            isAirborne     = false,
            altitude       = 0,
            verticalSpeed  = 0,
            airSpeed       = 0,
            heading        = 0,
            driveHeading   = 0,
            turnInput      = 0,
            takeoffAt      = 0,
            modeChangedAt  = 0,
            landingRequestedAt = nil,
            landingPhase   = nil,
            netPublishAt   = 0,
            lastSeenAt     = nowSec(),
            wasDriverLastTick = false,
            tiresRemoved   = false,
            yawWritten     = nil,
            propShown      = nil,
            -- propeller
            propAngle      = 0,
            propRPM        = 0,          -- 0..1, spool state
            -- audio: three RPM layers crossfaded by one eased parameter
            lowLoopId      = nil,
            midLoopId      = nil,
            highLoopId     = nil,
            rpm            = 0,
            throttle       = 0,          -- modelled throttle-lever position, 0..1
            lowVol         = nil,        -- last volume actually written (deadband cache)
            midVol         = nil,
            highVol        = nil,
            startId        = nil,
            startVol       = 0,
            startAt        = nil,
            stopId         = nil,
            stopVol        = 0,
            stopAt         = nil,
            lastEngineOn   = nil,
            -- diagnostics
            movedLogAt     = 0,
        }
    end
    return state[id]
end

local function turnRateForSpeed(kmh)
    local t = (kmh - TUNE.LOW_SPEED_FLOOR_KMH)
            / math.max(1, TUNE.MAX_AIRSPEED_KMH - TUNE.LOW_SPEED_FLOOR_KMH)
    t = math.max(0, math.min(1, t))
    return TUNE.TURN_RATE_LOW_DEG + (TUNE.TURN_RATE_HIGH_DEG - TUNE.TURN_RATE_LOW_DEG) * t
end

-- ------------------------------------------------- vanilla wheel models: GONE
--
-- THE CAR WHEELS ARE NO LONGER HIDDEN AT RUNTIME - THEY NO LONGER EXIST.
--
-- This used to be a real function, hideVanillaWheels(), that called
-- setAllModelsVisible(false) on the four tire parts because the vanilla Tire TEMPLATE ends
-- with `model InflatedTirePlusWheel { file = Vehicles_Wheel }` and the aircraft draws its
-- own spatted gear, so a second set of black car wheels was being drawn straight through
-- the aeroplane.
--
-- That workaround was never safe. BaseVehicle.setModelVisible's hide path is not a flag:
--
--     this.models.remove(i);
--     if (this.createdModel) { ModelManager.instance.Remove(this);
--                              ModelManager.instance.addVehicle(this); }
--
-- - a full teardown and rebuild of the vehicle's render model. Re-asserting it on a timer
-- HARD-CRASHED THE GAME TO DESKTOP on vehicle entry (0.1.6), which is why it was reduced
-- to a one-shot latch in 0.1.7 - with the known, shipped cost that anything re-showing a
-- tyre (vanilla's own setInventoryItem does exactly that after any wheel repair) left it
-- visible through the airframe for the rest of the session.
--
-- vehicle_cessna172.txt now declares the four tire parts EXPLICITLY, without that model
-- block, instead of inheriting the template. There is no car wheel model on this vehicle
-- to show, hide, re-show or churn, so the bug, the workaround and the crash risk are all
-- gone together. Every other property of the tire parts is vanilla's, verbatim.
--
-- The propeller is handled below, and is now the only model this mod touches at all.

-- PROPELLER VISIBILITY, AND WHY IT IS NOW STATE-DRIVEN RATHER THAN A ONE-SHOT LATCH.
--
-- The Propeller used to be `category = nodisplay` with no inventory item - a bare visual
-- carrier - so nothing in the game would ever add its model to the render list and it had
-- to be switched on once by hand. It is now a REAL part with a real item, which changes
-- the correct behaviour in both directions: vanilla's VehiclePart.setInventoryItem ends
-- with setAllModelsVisible(item ~= nil), so fitting a propeller shows it and REMOVING one
-- must leave the aeroplane without a propeller drawn on the nose.
--
-- So this follows the fitted state - but ONLY ON A CHANGE. It compares against what it
-- last asserted and calls setModelVisible only when the two disagree, which is exactly the
-- "scan once, write only when actually in the wrong state" rule the crash above produced:
-- an unchanged vehicle costs one getPartById and one comparison per tick and zero model
-- rebuilds. It can never churn, because there is nothing to churn TO unless the player
-- has physically installed or uninstalled the part.
local function showPropeller(vehicle, st)
    local ok, part = call1(vehicle, "getPartById", "Propeller")
    if not (ok and part) then return end
    local okI, item = call0(part, "getInventoryItem")
    local fitted = okI and item ~= nil
    if st.propShown == fitted then return end          -- already in the right state
    -- 1.9.0: the blades are drawn by the C172PropSpin carrier part (it spins them); it is
    -- shown only while a Propeller is fitted, and only on a change.
    if tcall(C172PropSpin, "setFitted", vehicle, fitted) then
        st.propShown = fitted
    end
end

-- ---------------------------------------------------------------- propeller
--
-- ONE model, rotated for real. There is no pose set, nothing is ever hidden or shown,
-- and therefore no frame can exist in which two propeller states are both visible or
-- neither is - which is the entire ghost/duplicate-propeller artifact class, designed
-- out rather than mitigated. C172PropSpin.lua is the rendering half (1.9.0; it was Java).
--
-- This publishes the angular RATE; C172PropSpin advances the phase on every DRAWN frame
-- from it. Advancing it here alone would not be enough: OnTick cannot keep up with the
-- render path, so the propeller would be frozen
-- for a frame or two and then snap forward.
local function updatePropeller(vehicle, st, engineOn, dt)
    local target = engineOn and 1.0 or 0.0
    local rate = engineOn and (1.0 / TUNE.PROP_SPOOL_UP_SEC) or (1.0 / TUNE.PROP_SPOOL_DOWN_SEC)
    if st.propRPM < target then
        st.propRPM = math.min(target, st.propRPM + rate * dt)
    elseif st.propRPM > target then
        st.propRPM = math.max(target, st.propRPM - rate * dt)
    end

    -- THE PROPELLER AND THE ENGINE NOTE ARE NOW THE SAME NUMBER.
    --
    -- This used to derive its own "load" from airspeed alone, which meant the blades and
    -- the engine bed could disagree: opening the throttle at the hold made the engine roar
    -- while the propeller stayed at idle rate, because the speed had not arrived yet.
    -- st.rpm is the eased, slew-limited engine RPM parameter that drives the audio
    -- crossfade (see computeEngineRpm and the THROTTLE_* block in TUNE) - it already
    -- combines throttle lever position and airspeed, and it already cannot step. Using it
    -- here makes the picture and the sound one system, which is also what makes the
    -- STOPPED -> STARTING -> LOW -> MEDIUM -> HIGH -> MAX progression read as intentional
    -- rather than as two things loosely correlated.
    --
    -- st.propRPM (the spool state) still gates it, so shutdown still windmills down over
    -- PROP_SPOOL_DOWN_SEC and start still spools up over PROP_SPOOL_UP_SEC. Two smooth
    -- factors multiplied; no branch, no state machine, and no frame in which the rate can
    -- jump. Falls back to airspeed if st.rpm has not been established yet (a nearby
    -- aircraft seen for the first time), so there is never a frozen propeller.
    local load = st.rpm
    if type(load) ~= "number" then
        load = math.max(0, math.min(1, (st.airSpeed or 0)
                                       / math.max(1, TUNE.MAX_AIRSPEED_KMH)))
    end
    load = math.max(0, math.min(1, load))
    local hz = (TUNE.PROP_IDLE_HZ + (TUNE.PROP_FULL_HZ - TUNE.PROP_IDLE_HZ) * load) * st.propRPM
    local radPerSec = hz * TWO_PI

    st.propAngle = (st.propAngle + radPerSec * dt) % TWO_PI
    -- C172PropSpin turns the blades at this rate on every drawn frame (it owns the phase).
    javaSetPropRate(vehicle, radPerSec)
end

-- ------------------------------------------------------------------- audio
--
-- Four stages, all namespaced to this mod (C172*). Two loops are held open on the
-- vehicle's own emitter and cross-faded by volume; two one-shots are edge-triggered on
-- the engine's on/off transition and faded out rather than cut, so nothing clips.
--
-- maxInstancesPerEmitter = 1 on every clip (see cessna172_sounds.txt) is the hard
-- guarantee against overlapping duplicates: even if a caller somehow asked twice, FMOD
-- itself will not stack a second instance on the same emitter. The edge detection below
-- is the first line of defence and the sound script is the second.
-- ENGINE RPM, 0..1, and the three-layer mix it drives.
--
-- The three loops are the SAME ENGINE recorded at genuinely different RPM (firing
-- fundamentals of roughly 70, 82 and 94 Hz - see tools/build_engine_audio.py). So sweeping
-- a crossfade across them reproduces the real harmonic change of an engine picking up revs,
-- which pitch-shifting one clip cannot do: shifting preserves the harmonic balance and ends
-- up sounding like a synthesiser sweep rather than an engine working harder.
--
-- ONE parameter drives everything, so there is no state machine to jump between and no
-- point at which a layer starts or stops. rpm is built from what the aircraft is actually
-- doing - airspeed against this airframe's own reference speeds, lifted by throttle and by
-- being airborne at all - and then eased, so it can never step.
-- THROTTLE LEVER. Target from mode + key state; the lever itself only ever EASES toward
-- it, at a bounded, direction-dependent rate. See the THROTTLE_* block in TUNE for why
-- this replaced the old "RPM is a function of which keys are down right now" model.
--
-- The critical property is that no target is ever IDLE while airborne. A pilot who stops
-- holding W has not closed the throttle; they have stopped climbing. Returning to idle on
-- key release is what made a cruise at the speed ceiling swing between the MID and HIGH
-- layers several times a second.
local function throttleTarget(st, thrustHeld, descendHeld, engineOn)
    if not engineOn then return 0 end
    if st.mode == "GROUND" then
        return thrustHeld and TUNE.THROTTLE_GROUND_OPEN or TUNE.THROTTLE_IDLE
    end
    if st.mode == "TAKEOFF" then return TUNE.THROTTLE_CLIMB end
    if st.mode == "LANDING" then
        return thrustHeld and TUNE.THROTTLE_CRUISE or TUNE.THROTTLE_LANDING
    end
    -- AIR
    if thrustHeld  then return TUNE.THROTTLE_CLIMB end
    if descendHeld then return TUNE.THROTTLE_DESCENT end
    return TUNE.THROTTLE_CRUISE
end

local function updateThrottle(st, cfg, thrustHeld, descendHeld, engineOn, dt)
    local target = throttleTarget(st, thrustHeld, descendHeld, engineOn)
    local cur = st.throttle or 0
    local rate = (target > cur) and TUNE.THROTTLE_UP_RATE or TUNE.THROTTLE_DOWN_RATE
    local step = rate * dt
    if math.abs(target - cur) <= step then
        cur = target
    else
        cur = cur + (target > cur and step or -step)
    end
    st.throttle = math.max(0, math.min(1, cur))
    return st.throttle
end

-- ENGINE RPM, 0..1, and the three-layer mix it drives.
--
-- Two terms, because a FIXED-PITCH propeller is loaded by airspeed: at a constant throttle
-- setting the engine turns faster as the aeroplane goes faster (the prop unloads), and it
-- turns slower in a climb. Driving the mix from the lever alone would make the sound
-- respond only to the pilot; driving it from airspeed alone (the old model) makes opening
-- the throttle silent until the speed actually arrives. Both, weighted, is what tracks a
-- real engine.
--
-- Nothing here has a discontinuity: throttle is already rate-limited, airspeed is a
-- physical quantity that cannot step, and the result is eased AND slew-limited again by
-- the caller. There is no state machine and no branch that can jump the parameter.
local function computeEngineRpm(st, cfg, throttle, engineOn)
    if not engineOn then return 0 end
    local top = math.max(1, TUNE.MAX_AIRSPEED_KMH)
    local speedFrac = math.max(0, math.min(1, (st.airSpeed or 0) / top))
    local rpm = TUNE.RPM_THROTTLE_SHARE * throttle
              + TUNE.RPM_SPEED_SHARE    * speedFrac
    return math.max(TUNE.RPM_MIN_RUNNING, math.min(1, rpm))
end

-- Equal-power crossfade across three layers on one 0..1 parameter.
--   0.0          all LOW
--   0.5          all MID
--   1.0          all HIGH
-- Equal power (sqrt) not linear: these layers are correlated recordings of one engine, and
-- summing correlated signals with linear ramps dips about 3 dB mid-crossfade, which is
-- audible as a dip in the middle of every RPM sweep.
local function mixForRpm(rpm)
    if rpm <= 0.5 then
        local t = rpm / 0.5
        return math.sqrt(1 - t), math.sqrt(t), 0
    end
    local t = (rpm - 0.5) / 0.5
    return 0, math.sqrt(1 - t), math.sqrt(t)
end

-- 0..1 loudness for how far this aircraft is from the nearest local player (TUNE.SOUND_FADE_*).
-- A storey up or down counts as 3 tiles, as the MH-92 does it.
-- 2026-10-05 (Jay: "heli sounds static going over stuff"): over a building the aircraft is DRAWN on
-- level 0 while its pilot stays on the roof's level (C172Presentation), so comparing logical levels
-- faded the pilot's own engine at every building edge. Whoever sits in it hears it in full; everyone
-- else is measured to its TRUE height (getWorldPos z, in levels).
local AUDIO_POS
local function audioFade(vehicle)
    local best = nil
    local okN, n = pcall(getNumActivePlayers)
    if not (okN and type(n) == "number") then n = 1 end
    AUDIO_POS = AUDIO_POS or Vector3f.new()
    local okV, vx, vy, vz = pcall(function()
        vehicle:getWorldPos(0, 0, 0, AUDIO_POS)
        return vehicle:getX(), vehicle:getY(), AUDIO_POS:z()
    end)
    if not okV then return 1 end
    for i = 0, math.max(0, n - 1) do
        local p = getSpecificPlayer(i)
        if p then
            local okP, px, py, pz, inside = pcall(function() return p:getX(), p:getY(), p:getZ(), p:getVehicle() == vehicle end)
            if okP then
                local dx, dy, dz = px - vx, py - vy, (pz - vz) * 3
                local d = inside and 0 or math.sqrt(dx * dx + dy * dy + dz * dz)
                if not best or d < best then best = d end
            end
        end
    end
    if not best then return 1 end
    local a, b = TUNE.SOUND_FADE_START, TUNE.SOUND_FADE_END
    if best <= a then return 1 end
    if best >= b then return 0 end
    local t = 1 - (best - a) / (b - a)
    return t * t * (3 - 2 * t)
end

local function updateOneShot(emitter, st, idField, volField, atField, lengthSec, dt)
    if not st[idField] then
        st[volField] = 0
        return 0
    end
    local elapsed = nowSec() - (st[atField] or 0)
    if elapsed >= lengthSec then
        st[volField] = math.max(0, (st[volField] or 0) - TUNE.ONESHOT_FADE_PER_SEC * dt)
        if st[volField] <= 0.001 then
            call1(emitter, "stopSoundDelayRelease", st[idField])
            st[idField], st[volField] = nil, 0
            return 0
        end
    end
    call2(emitter, "setVolume", st[idField], st[volField] * TUNE.MASTER_VOLUME * (st.audioFade or 1))
    return st[volField]
end

local function playOneShot(emitter, st, idField, volField, atField, soundName)
    if st[idField] then return end
    -- playSoundLoopedImpl, not playSound: on a multiplayer client playSound on a vehicle
    -- emitter (no parent object) ALSO broadcasts a world sound to every other player, pinned
    -- to that tile and never stopped. Every client voices every Cessna itself (the sweep
    -- below), so the local-only call is the right one; it loops only if the sound script says
    -- loop = true, and these two say false.
    local okId, id = call1(emitter, "playSoundLoopedImpl", soundName)
    if okId and id and id ~= 0 then
        st[idField]  = id
        st[volField] = 1.0
        st[atField]  = nowSec()
        call2(emitter, "setVolume", id, TUNE.MASTER_VOLUME * (st.audioFade or 1))
    end
end

-- DEADBANDED VOLUME WRITE. At 45 Hz a stable cruise otherwise pushes three setVolume
-- calls per tick that change nothing measurable; below VOL_EPSILON the previous value is
-- kept, so a settled aircraft costs zero FMOD calls. That is also what makes a dozen
-- parked Cessnas cost the same as one.
--
-- FILE-SCOPE, not a closure inside updateEngineAudio: that function runs once per tick per
-- aircraft in range, and building three closures a tick for it is exactly the sort of
-- allocation that does not show up until somebody parks six aeroplanes together.
local function setLayerVolume(emitter, st, idField, lastField, v)
    local id = st[idField]
    if not id then st[lastField] = nil return end
    local last = st[lastField]
    if last and math.abs(last - v) < TUNE.VOL_EPSILON then return end
    call2(emitter, "setVolume", id, v)
    st[lastField] = v
end

local function updateEngineAudio(vehicle, st, cfg, thrustHeld, descendHeld, dt)
    local okE, emitter = call0(vehicle, "getEmitter")
    if not (okE and emitter) then return end

    local okEng, engineOn = call0(vehicle, "isEngineRunning")
    engineOn = okEng and engineOn == true
    st.audioFade = audioFade(vehicle)

    -- EDGE DETECTION. st.lastEngineOn starts nil so that simply walking up to an already
    -- running aircraft does not retrigger its start-up clip; the first observation only
    -- records the state.
    if st.lastEngineOn == nil then
        st.lastEngineOn = engineOn
    elseif engineOn and not st.lastEngineOn then
        playOneShot(emitter, st, "startId", "startVol", "startAt", "C172EngineStart")
        st.lastEngineOn = true
    elseif (not engineOn) and st.lastEngineOn then
        playOneShot(emitter, st, "stopId", "stopVol", "stopAt", "C172EngineShutdown")
        st.lastEngineOn = false
    end

    local startVol = updateOneShot(emitter, st, "startId", "startVol", "startAt",
                                   TUNE.STARTUP_LENGTH_SEC, dt)
    local stopVol  = updateOneShot(emitter, st, "stopId", "stopVol", "stopAt",
                                   TUNE.SHUTDOWN_LENGTH_SEC, dt)

    -- ONE eased RPM parameter drives all three layers. Easing the PARAMETER rather than
    -- each layer's volume is what guarantees the mix stays coherent: the three volumes are
    -- always an exact equal-power crossfade of a single value, so they cannot drift apart,
    -- overlap oddly, or leave a layer stranded at the wrong level.
    --
    -- THREE separate rate limits now sit between the keyboard and the mix, which is what
    -- makes "no hard transitions between RPM ranges" a property rather than a hope:
    --   1. the THROTTLE LEVER eases toward its per-mode target at THROTTLE_UP/DOWN_RATE,
    --   2. the RPM parameter eases toward the lever's implied RPM at RPM_EASE_RATE,
    --   3. and the parameter is additionally SLEW-LIMITED to RPM_MAX_STEP_PER_SEC, which
    --      bounds the worst case (the proportional ease alone still moves fast on the
    --      first tick of a large target change).
    local throttle  = updateThrottle(st, cfg, thrustHeld, descendHeld, engineOn, dt)
    local rpmTarget = computeEngineRpm(st, cfg, throttle, engineOn)
    local prevRpm   = st.rpm or 0
    local ease      = math.max(0, math.min(1, TUNE.RPM_EASE_RATE * dt))
    local eased     = prevRpm + (rpmTarget - prevRpm) * ease
    local maxStep   = TUNE.RPM_MAX_STEP_PER_SEC * dt
    if eased - prevRpm >  maxStep then eased = prevRpm + maxStep end
    if eased - prevRpm < -maxStep then eased = prevRpm - maxStep end
    st.rpm = math.max(0, math.min(1, eased))
    local vLow, vMid, vHigh = mixForRpm(st.rpm)

    -- Overall loudness still rises with RPM on top of the crossfade, or the engine would
    -- change character as it revs without ever getting louder.
    --
    -- NOT hard-zeroed on engineOn any more. That was an instantaneous cut on shutdown; it
    -- happened to be inaudible only because the shutdown one-shot ducks the loops to zero
    -- at that exact moment, so it was a silent trap waiting for the duck to change. RPM
    -- already eases to 0 with the engine off (computeEngineRpm returns 0), which IS the
    -- windmill-down, and the loops are released below once it reaches the floor.
    local gain = TUNE.RPM_GAIN_FLOOR + (1 - TUNE.RPM_GAIN_FLOOR) * (st.rpm or 0)
    if (not engineOn) and (st.rpm or 0) <= 0.02 then gain = 0 end

    -- LOOPS ARE ONLY HELD OPEN WHILE NEEDED.
    -- The nearby-aircraft sweep calls this for EVERY Cessna in range, so opening the loops
    -- unconditionally would hold three FMOD voices open forever for every parked aircraft
    -- in the world - inaudible at zero volume but an unbounded voice leak, and exactly what
    -- turns into "background noise that will not stop" once enough of them exist.
    local LOOPS = {
        { id = "lowLoopId",  sound = "C172EngineLow"  },
        { id = "midLoopId",  sound = "C172EngineMid"  },
        { id = "highLoopId", sound = "C172EngineHigh" },
    }
    local wantLoops = engineOn or (st.rpm or 0) > 0.01
    if wantLoops then
        for _, L in ipairs(LOOPS) do
            if not st[L.id] then
                -- local only - see playOneShot
                local okId, id = call1(emitter, "playSoundLoopedImpl", L.sound)
                if okId and id and id ~= 0 then
                    st[L.id] = id
                    call2(emitter, "setVolume", id, 0)   -- never audible on its first frame
                end
            end
        end
    elseif st.lowLoopId or st.midLoopId or st.highLoopId then
        for _, L in ipairs(LOOPS) do
            if st[L.id] then call1(emitter, "stopSoundDelayRelease", st[L.id]) end
            st[L.id] = nil
        end
        -- Clear the deadband cache with the handles. A re-opened loop starts at volume 0
        -- and its first real write would otherwise be swallowed by a stale "last written".
        st.lowVol, st.midVol, st.highVol = nil, nil, nil
        st.rpm = 0
        st.throttle = 0
    end

    -- The start clip already contains its own running tail, and the shutdown its own decay,
    -- so the loops are ducked underneath whichever is playing and swell back in as it
    -- fades. That is what removes the seam at both transitions.
    local duck = math.max(0, 1 - math.max(startVol, stopVol))
    local m = duck * gain * TUNE.MASTER_VOLUME * st.audioFade

    setLayerVolume(emitter, st, "lowLoopId",  "lowVol",  vLow  * m)
    setLayerVolume(emitter, st, "midLoopId",  "midVol",  vMid  * m)
    setLayerVolume(emitter, st, "highLoopId", "highVol", vHigh * m)
end

local function stopEngineAudio(vehicle, st)
    if not (vehicle and st) then return end
    local okE, emitter = call0(vehicle, "getEmitter")
    if okE and emitter then
        for _, f in ipairs({ "lowLoopId", "midLoopId", "highLoopId", "startId", "stopId" }) do
            if st[f] then call1(emitter, "stopSoundDelayRelease", st[f]) end
        end
    end
    st.lowLoopId, st.midLoopId, st.highLoopId = nil, nil, nil
    st.startId, st.stopId = nil, nil
    st.rpm, st.startVol, st.stopVol = 0, 0, 0
    st.throttle = 0
    st.lowVol, st.midVol, st.highVol = nil, nil, nil
    st.lastEngineOn = nil
end

-- ------------------------------------------------------------- mode changes
local function setCollisionBypassed(vehicle, bypassed)
    call1(vehicle, "setPhysicsActive", true)
    call1(vehicle, "setActiveInBullet", true)
    call1(vehicle, "setCollidable", not bypassed)
end

-- Heading from the engine's own forward vector - see the file header for the two
-- separate shipped bugs that came from deriving it any other way. A near-zero vector
-- means "no reliable reading", not "pointing north", so it is treated as a failure.
local function seedHeadingFromVehicle(vehicle)
    local fx, fy = javaForwardX(vehicle), javaForwardY(vehicle)
    local len = math.sqrt(fx * fx + fy * fy)
    if not (len > 0.2) then
        warn("forward-vector read unavailable at rotation - seeding heading to 0 " ..
             "(the Java bridge may be down; every other flight call needs it too)")
        return 0
    end
    return math.atan2(fx / len, fy / len)
end

local function enterGroundMode(vehicle, st, reason)
    local from = st.mode or "?"
    local wasAirborne = st.isAirborne == true
    if wasAirborne then C172GroundHandling.beginRollout(vehicle, st) end
    st.mode          = "GROUND"
    st.isAirborne    = false
    st.contactsClear = false
    st.altitude      = 0
    st.verticalSpeed = 0
    st.flightBaseH, st.flightTargetH = nil, nil
    st.turnInput     = 0
    st.landingRequestedAt = nil
    st.landingPhase  = nil
    st.landingAwaitingBody = nil
    st.finalSince    = nil
    st.finalLowH, st.finalLowAt = nil, nil
    st.settleFixes   = 0          -- touchdown settle check, see the grounded tick
    st.settleBadSince = nil
    st.modeChangedAt = nowSec()

    setCollisionBypassed(vehicle, false)
    javaSetFlightState(vehicle, false)
    -- ground contacts back on, and the drawing pin let go (C172Contacts / C172Presentation)
    tcall(C172Contacts, "release", vehicle)
    tcall(C172Presentation, "release", vehicle)

    -- The final flare approaches the taildragger stance. Healthy touchdown
    -- hands the existing native transform and momentum straight to the wheels.

    -- Remember what we landed ON. If it is an elevated surface, the grounded tick keeps a
    -- gentle hold on it (see the SURFACE HOLD block in onTick) - because PZ gives a parked
    -- vehicle no support up there at all: building floors are not chassis colliders, and
    -- the raycast wheels probe down to the real ground, so an unheld aircraft would settle
    -- to level 0 INSIDE the building. This is the "never sink into a roof" guarantee.
    st.groundSurfaceH = javaSurfaceHeight(vehicle)
    if (st.groundSurfaceH or 0) > 0.1 then
        log(("landed on an elevated surface at %.2f m - holding it there")
            :format(st.groundSurfaceH))
    end
    if airborneVehicle == vehicle then airborneVehicle = nil end

    if st.tiresRemoved then
        local ok = javaSetTiresRemoved(vehicle, false)
        st.tiresRemoved = not ok
        log("tires " .. (ok and "restored to physics (on the ground)"
                            or "RESTORE FAILED - the aircraft may slide; use [ to recover"))
    end

    -- Leave a healthy landing's transform and native momentum untouched.
    -- Only a genuinely sunk/tipped body needs the safety reseat; that path
    -- restores horizontal momentum through a physical impulse.
    if wasAirborne and bridgeAvailable() then
        local h = javaBodyHeight(vehicle)
        local surf = st.groundSurfaceH or 0
        local tilt = javaBodyTilt(vehicle)
        if type(h) == "number" and
           (h - surf < (st.gearDatum or 1) - TUNE.TOUCHDOWN_SUNK_M
            or (type(tilt) == "number" and tilt > TUNE.TOUCHDOWN_MAX_TILT_DEG)) then
            tcall(C172Phys, "reseatRolling", vehicle)
        end
    end

    -- Touchdown annunciator: the HUD reads this and flashes so the player can SEE the
    -- moment the aircraft transitions onto the ground rather than having to infer it.
    st.touchdownAt = nowSec()
    st.airSpeed = 0

    -- DEAD-STICK LANDING: KEEP IT DEAD.
    --
    -- Shutting the engine down in flight and gliding in is a legitimate thing to do, and the
    -- aircraft was starting itself again the moment the wheels touched. Nothing in this mod
    -- ever starts an engine - it only ever READS isEngineRunning - so the restart comes from
    -- the vehicle rejoining vanilla's ground path, where updateControls (skipped for the whole
    -- flight by the Java build) and the rest of the drivetrain resume with whatever engine
    -- state they last saw, which was Running. (1.9.0: vanilla's throttle auto-start - the
    -- other way an engine comes back - is refused by C172IgnitionKey's guard.)
    --
    -- Rather than guess at which vanilla field to fight, the PLAYER'S INTENT is latched: if
    -- the engine was switched off while airborne, that decision is re-asserted with
    -- BaseVehicle.shutOff() across the touchdown boundary. The guard then expires, so a
    -- restart the player performs afterwards is theirs and is never touched.
    if st.engineOffInFlight then
        st.engineHeldOff = true
        -- STAMP IT. The hold is time-boxed against engineHeldAt, and a hold armed without
        -- one is measured from zero - so its age is the whole clock, the window test passes
        -- on the very next tick, and the hold is released before it can catch anything. It
        -- was armed here and at the shutdown edge and stamped at neither, which is why the
        -- engine still restarted itself after landing even though a guard was in place.
        st.engineHeldAt = nowSec()
        st.engineOffInFlight = nil
        log("touched down with the engine deliberately OFF - it stays off until started")
    end

    C172Util.setFlightState(vehicle, 0, "GROUND")
    log(from .. " -> GROUND  (" .. tostring(reason) .. ")")
end

-- TAKEOFF SPEED (10-06; a player asked for a lower one, Jay: "make base takeoff less its to much ... or just do
-- the option for sandbox"). Sandbox > Cessna 172 > Takeoff speed (km/h), default 45 (was a fixed 55). It is
-- also what the stall and the lift authority scale from (x STALL_SPEED_RATIO), so a lower number makes the
-- whole slow end gentler, not only the moment the wheels leave. Read every time, so a server admin's change
-- applies at once; anything unreadable falls back to C172Config's minTakeoffSpeedKmh.
local TAKEOFF_MIN_KMH, TAKEOFF_MAX_KMH = 30, 80
local function takeoffKmh(cfg)
    local S = SandboxVars and SandboxVars.Cessna172
    local kmh = S and tonumber(S.TakeoffSpeed)
    if kmh and kmh == kmh then return math.max(TAKEOFF_MIN_KMH, math.min(TAKEOFF_MAX_KMH, kmh)) end
    return cfg.minTakeoffSpeedKmh
end

local function enterAirMode(vehicle, st, speed, cfg)
    local h = seedHeadingFromVehicle(vehicle)
    st.heading       = h
    st.driveHeading  = h
    st.mode          = "TAKEOFF"
    st.isAirborne    = true
    st.altitude      = 0.0
    -- Start the climb from ZERO vertical speed and let VS_RAMP build it over ~half a
    -- second, instead of snapping to full climb rate on the very first airborne tick. That
    -- snap was a real jolt at the moment the wheels left the ground; ramping makes the
    -- aircraft rotate and fly off rather than leap.
    st.verticalSpeed = 0
    st.turnInput     = 0
    st.airSpeed      = math.max(speed, takeoffKmh(cfg))
    st.modeChangedAt = nowSec()
    st.takeoffAt     = nowSec()
    -- RUNWAY DATUM (1.8.0): where the body sits on its gear right now, above the surface it is
    -- rolling on. The lift target is measured from here, and the HUD shows real height above it.
    do
        local bh = javaBodyHeight(vehicle)
        local surf = st.groundSurfaceH or 0
        local raw = (type(bh) == "number" and bh == bh) and (bh - surf) or nil
        st.gearDatum = math.max(TUNE.GEAR_DATUM_MIN, math.min(TUNE.GEAR_DATUM_MAX, raw or 1.05))
        st.flightBaseH = type(bh) == "number" and math.max(0, bh - st.gearDatum) or surf
        st.flightTargetH = bh or (surf + st.gearDatum)
        log(("gear datum %.2f m (measured %s)"):format(st.gearDatum,
            raw and ("%.2f"):format(raw) or "n/a"))
    end
    st.yawRateCmd    = 0
    -- The takeoff roll leaves the body with whatever rotation the wheels were imparting, and
    -- the instant the tyres come out of physics nothing else damps it - the attitude hold
    -- takes it from the very first airborne tick, on fresh turn-rate samples (stale ones
    -- from the last flight would read as a violent spin).
    tcall(C172Phys, "forget", vehicle)

    log(("GROUND -> TAKEOFF (nose heading %.1f deg, from the engine forward vector)")
        :format(math.deg(h)))

    setCollisionBypassed(vehicle, true)
    javaSetFlightState(vehicle, true)
    airborneVehicle = vehicle

    local okTires = javaSetTiresRemoved(vehicle, true)
    st.tiresRemoved = okTires
    if not okTires then
        warn("TIRE REMOVAL FAILED - the wheels stay in the physics; the lift still raises " ..
             "the airframe off them.")
    end

    C172Util.setFlightState(vehicle, st.altitude, "AIRBORNE")
    return true
end

local function enterLandingPhase(vehicle, st, reason)
    local from = st.mode or "?"
    C172Altitude.resync(st, javaBodyHeight(vehicle), TUNE)
    st.mode = "LANDING"
    st.landingRequestedAt = nowSec()
    st.landingPhase = "DESCENT"
    st.finalSince = nil
    st.finalLowH, st.finalLowAt = nil, nil
    log(from .. " -> LANDING  (" .. tostring(reason) .. ")")
end

-- GO-AROUND (1.10.4). A Workshop request (10-09): "add the ability to abort landing, for example
-- by pressing W during the landing sequence or by pressing the interface button again - it could
-- have saved me quite a few repairs". Only while still in the air: once the wheels are down the
-- landing is over and enterGroundMode has already run. Back to AIR, the normal energy model -
-- the approach bled the speed off, so it is W (power) that climbs it away again.
local function abortLanding(vehicle, st, reason)
    if st.mode ~= "LANDING" or not st.isAirborne then return false end
    C172Altitude.resync(st, javaBodyHeight(vehicle), TUNE)
    st.mode = "AIR"
    st.landingRequestedAt = nil
    st.landingPhase = nil
    st.landingAwaitingBody = nil
    st.finalSince = nil
    st.finalLowH, st.finalLowAt = nil, nil
    log("LANDING -> AIR  (go-around: " .. tostring(reason) .. ")")
    return true
end

-- ------------------------------------------------------------------- network
-- Throttled to MP_PUBLISH_INTERVAL_SEC, not sent per frame. What is relayed is ONLY the
-- state PZ does not already replicate on its own - simulated altitude, the canopy-clear
-- threshold and the flight mode. Position, orientation, engine state, damage, fuel and
-- who is in which seat all replicate through vanilla BaseVehicle netcode already, and
-- duplicating any of that here would be a desync source rather than a fix.
local function publishFlightState(vehicle, st)
    local t = nowSec()
    if not (isClient() and (t - (st.netPublishAt or 0)) >= TUNE.MP_PUBLISH_INTERVAL_SEC) then
        return
    end
    st.netPublishAt = t
    local okId, vid = pcall(function() return vehicle:getId() end)
    local okP, player = pcall(getPlayer)
    if not (okId and okP and player) then return end
    pcall(function()
        sendClientCommand(player, "cessna172", "flightUpdate", {
            vehicleId         = vid,
            altitude          = st.altitude,
            treeClearAltitude = TUNE.TREE_CLEAR_ALTITUDE,
            mode              = st.mode,
            airSpeed          = st.airSpeed,
            -- 1.10.3: clear of the ground (C172Contacts). The server and every other client switch
            -- this aircraft type's ground contacts off while one is clear, as this client does -
            -- in multiplayer the SERVER kept testing the full footprint: fences, bushes and zombies
            -- "hit" under the flight path, and their noises (Jay, 10-08: "seems to hit more stuff
            -- in mp", "hear a lot of noises when flying in areas")
            clear             = st.contactsClear == true and st.mode ~= "GROUND",
        })
    end)
end

-- --------------------------------------------------------------- kinematics
-- Returns (turnDesired, liftAuthority, shouldContinue).
-- VISUAL ATTITUDE. Nose-up on the climb-out, easing back to level once the aircraft is
-- established; a wing-down lean into turns. Since 1.9.0 this is the attitude the REAL
-- airframe is held at (C172Phys.holdAttitude), never more than 8 degrees of pitch and
-- BANK_MAX_DEG of bank - nowhere near the attitudes where vanilla's "Forward Direction
-- cannot be zero length vector" lives.
--
-- The pitch TARGET is derived from vertical speed rather than from the throttle, so it is
-- always telling the truth about what the aircraft is doing: climbing shows nose-up,
-- descending shows nose-down, and level flight shows level. TAKEOFF is the one exception -
-- it holds a fixed rotation attitude, the way a real aircraft is rotated and held until
-- it is established in the climb - and even that is scaled by liftAuthority, so an
-- aircraft mushing along near the stall does not sit there with its nose triumphantly up.
local function updateAttitude(st, cfg, liftAuthority, dt)
    local pitchTarget = 0
    if st.mode == "GROUND" then
        -- Explicitly level, but EASED like every other attitude change, so the aircraft
        -- settles flat after touchdown and is already flat before the next rotation
        -- instead of snapping between states.
        pitchTarget = 0
    elseif st.mode == "TAKEOFF" then
        -- Rotation attitude, decaying toward a shallow residual. The aircraft pitches up as
        -- it leaves the ground and then straightens ITSELF, rather than holding maximum
        -- nose-up until the mode changes.
        local since = nowSec() - (st.takeoffAt or 0)
        local decay = math.max(0, 1 - (since / math.max(0.01, TUNE.PITCH_TAKEOFF_DECAY_SEC)))
        local frac  = TUNE.PITCH_TAKEOFF_RESIDUAL
                    + (1 - TUNE.PITCH_TAKEOFF_RESIDUAL) * decay
        pitchTarget = math.rad(TUNE.PITCH_TAKEOFF_DEG) * frac * liftAuthority
    elseif st.mode == "LANDING" and st.landingPhase == "FLARE" then
        pitchTarget = math.rad(TUNE.PITCH_FLARE_DEG)
    else
        local vs = st.verticalSpeed or 0
        local ref = math.max(0.01, TUNE.CLIMB_RATE)
        local r = math.max(-1, math.min(1, vs / ref))
        pitchTarget = math.rad(r >= 0 and (TUNE.PITCH_MAX_UP_DEG * r)
                                       or (TUNE.PITCH_MAX_DOWN_DEG * r))
    end

    -- turnInput is +1 for a right-hand turn, and the attitude hold takes positive bank as
    -- a right-hand bank (right wing down), so this passes straight through.
    --
    -- The maximum available bank rises with airspeed (BANK_MIN_DEG at the low-speed floor
    -- to BANK_MAX_DEG at the ceiling), so a slow turn is a gentle lean and a fast one is a
    -- proper banked turn. On the GROUND it is forced to zero: a taxiing aeroplane does not
    -- lean, and leaving the wing down through touchdown looked like a wingtip strike.
    local bankTarget = 0
    if st.mode ~= "GROUND" then
        local t = (math.max(0, (st.airSpeed or 0) - TUNE.LOW_SPEED_FLOOR_KMH))
                / math.max(1, TUNE.MAX_AIRSPEED_KMH - TUNE.LOW_SPEED_FLOOR_KMH)
        t = math.max(0, math.min(1, t))
        local maxBank = TUNE.BANK_MIN_DEG + (TUNE.BANK_MAX_DEG - TUNE.BANK_MIN_DEG) * t
        -- Roll authority is a control-surface property, so a damaged aileron visibly rolls
        -- less as well as turning more slowly. Same effect number the turn rate uses, so
        -- the picture and the behaviour cannot disagree.
        bankTarget = math.rad(maxBank) * (st.turnInput or 0) * (st.fxRoll or 1)
    end

    local kp = math.max(0, math.min(1, TUNE.PITCH_EASE_RATE * dt))
    local kb = math.max(0, math.min(1, TUNE.BANK_EASE_RATE * dt))
    st.pitch = (st.pitch or 0) + (pitchTarget - (st.pitch or 0)) * kp
    st.bank  = (st.bank  or 0) + (bankTarget  - (st.bank  or 0)) * kb
end

-- DAMAGE CONSEQUENCES. Sampled once per tick into st.fx* from C172Parts.effects(), which
-- is itself cached for a second - part condition changes on the timescale of a repair or a
-- crash, never within a tick, so this costs one table lookup per tick in the hot path.
--
-- WHY THE VALUES ARE APPLIED AS MULTIPLIERS ON EXISTING TERMS rather than as new terms:
-- every flight constant in TUNE was bracketed against real flights, and an undamaged
-- aircraft must fly EXACTLY as it did before this pass or the maintenance feature is
-- really a nerf. C172Parts.factor() is flat at 1.0 for any part above 70% condition, so a
-- healthy or merely worn aeroplane multiplies everything by exactly 1 and this whole
-- system is arithmetically invisible. Only genuine damage moves anything.
local function sampleDamageEffects(vehicle, st)
    local e = C172Parts.effects(vehicle)
    if not e then
        st.fxThrust, st.fxMaxSpeed, st.fxRoll, st.fxPitch, st.fxYaw = 1, 1, 1, 1, 1
        st.fxPropFitted = true
        return
    end
    st.fxThrust     = e.thrust
    st.fxMaxSpeed   = e.maxSpeed
    st.fxRoll       = e.roll
    st.fxPitch      = e.pitch
    st.fxYaw        = e.yaw
    st.fxGround     = e.ground
    st.fxPropFitted = e.propellerFitted
end

local function updateFlightKinematics(vehicle, st, cfg, wantThrust, wantSlow, engineOn, dt)
    sampleDamageEffects(vehicle, st)
    -- A destroyed or absent propeller means the engine turns and NOTHING is pulled. This
    -- is the one hard consequence in the model: everything else degrades, this one is
    -- binary, because an aeroplane with no propeller genuinely has no thrust and softening
    -- it would be exactly the decorative lie this pass exists to remove. The aircraft
    -- still flies - it glides, steers and can be landed - which is the correct outcome and
    -- not a soft-lock.
    if not st.fxPropFitted then engineOn = false end

    -- SPEED. One branch per state, no interaction with the turn input below.
    if st.mode == "LANDING" then
        st.airSpeed = math.max(TUNE.LOW_SPEED_FLOOR_KMH,
                               st.airSpeed - TUNE.LANDING_DECEL_RATE * dt)
    elseif wantThrust then
        -- THRUST from the engine, propeller, oil system and fuel delivery. Applied to the
        -- ACCELERATION rather than to the speed itself, so a sick engine takes longer to
        -- reach a given speed rather than being clamped out of reaching it - which is what
        -- a real down-on-power engine does, and which keeps a damaged aircraft flyable
        -- (slowly) instead of unflyable.
        st.airSpeed = st.airSpeed + TUNE.AIRSPEED_RATE * (st.fxThrust or 1) * dt
    elseif wantSlow then
        st.airSpeed = math.max(math.min(st.airSpeed, TUNE.AIR_BRAKE_FLOOR_KMH),
                               st.airSpeed - TUNE.AIR_BRAKE_RATE * dt)
    elseif engineOn then
        -- HANDS OFF, ENGINE RUNNING = CRUISE POWER, and airspeed RELAXES TOWARD the
        -- level-flight speed rather than decaying toward zero.
        --
        -- This is what makes "stable cruising" an actual state instead of a speed the
        -- aircraft can only pass through. With a plain decay, 20 seconds of hands-off
        -- flight ran the speed from 118 all the way down through the level band and into
        -- a stall - simulated and measured - so holding altitude meant continuously
        -- tapping the throttle, which is neither stable nor pleasant.
        --
        -- It is also the physically right shape: a fixed throttle setting has an
        -- equilibrium speed, and letting go of the controls means leaving the engine at
        -- cruise power, not shutting it off. Fast aircraft still slow DOWN (at the same
        -- DRAG_DECEL_RATE as before, so nothing about coming off a climb changed), slow
        -- ones recover gently, and neither direction is fast enough to read as an
        -- autopilot.
        local delta = TUNE.LEVEL_FLIGHT_KMH - st.airSpeed
        local rate  = (delta > 0) and TUNE.CRUISE_RECOVER_RATE or TUNE.DRAG_DECEL_RATE
        local stepv = rate * dt
        if math.abs(delta) <= stepv then
            st.airSpeed = TUNE.LEVEL_FLIGHT_KMH
        else
            st.airSpeed = st.airSpeed + (delta > 0 and stepv or -stepv)
        end
    else
        -- ENGINE OFF (or failed): a real glide. Speed decays with nothing to sustain it,
        -- the aircraft drops below the level band and descends, and eventually stalls and
        -- sinks. An engine failure at altitude MUST come down.
        st.airSpeed = st.airSpeed - TUNE.DRAG_DECEL_RATE * dt
    end
    -- The ceiling itself comes down with structural damage: a torn wing or a caved-in
    -- fuselage is draggy, and a damaged airframe should not be flyable to book numbers.
    -- The FLOOR is untouched on purpose - lowering it toward the stall would turn wing
    -- damage into an unrecoverable sink instead of a handling penalty.
    local ceiling = TUNE.MAX_AIRSPEED_KMH * (st.fxMaxSpeed or 1)
    st.airSpeed = math.max(TUNE.LOW_SPEED_FLOOR_KMH,
                           math.min(math.max(TUNE.LOW_SPEED_FLOOR_KMH + 1, ceiling),
                                    st.airSpeed))

    -- LIFT AUTHORITY. 1 at rotation speed and above, falling to 0 at the stall.
    local stallSpeed = takeoffKmh(cfg) * TUNE.STALL_SPEED_RATIO
    local liftAuthority = (st.airSpeed - stallSpeed)
                        / math.max(1, takeoffKmh(cfg) - stallSpeed)
    liftAuthority = math.max(0, math.min(1, liftAuthority))

    -- TURN. Read and computed completely independently of wantThrust - there is no
    -- if/elseif, no early return and no shared flag between the two, which is what makes
    -- "throttle and turn at the same time" work by construction rather than by luck.
    local desired = 0
    local leftHeld  = keyDown(A_KEY)
    local rightHeld = keyDown(D_KEY)
    -- STEERING IS NEVER GATED ON THE ENGINE. It used to be
    --     steeringAllowed = engineOn or st.mode == "LANDING"
    -- which meant that an aircraft whose engine had failed or been destroyed could not be
    -- turned AT ALL in AIR mode - the player could only glide dead straight and watch. That
    -- is both the reported "in the air, descending, could not steer to land" and simply
    -- wrong aerodynamically: an aeroplane's control surfaces work on AIRFLOW, not on engine
    -- power, which is exactly why a real one can be glided to a landing after an engine
    -- failure.
    --
    -- Control authority is instead a function of AIRSPEED, which turnRateForSpeed already
    -- models - so a fast glide steers well, a slow one steers poorly, and a stalled one
    -- barely responds. That is the correct behaviour and it needs no engine term.
    if leftHeld  then desired = -1 end
    if rightHeld then desired =  1 end

    st.turnInput = st.turnInput + (desired - st.turnInput)
                                * math.max(0, math.min(1, TUNE.TURN_SMOOTH * dt))

    -- Turn authority eases in over the first moments after takeoff - see TURN_EASE_IN_SEC.
    -- A multiplier on the RATE, not a gate on the input: st.turnInput still tracks the keys
    -- normally, so the controls always respond, just with less authority for a moment.
    local turnAuth = 1.0
    if st.mode == "TAKEOFF" then
        local since = nowSec() - (st.takeoffAt or 0)
        turnAuth = TUNE.TURN_EASE_IN_FLOOR
                 + (1 - TUNE.TURN_EASE_IN_FLOOR)
                   * math.max(0, math.min(1, since / TUNE.TURN_EASE_IN_SEC))
    end

    -- ROLL AUTHORITY from the ailerons and the wings they hang on. A multiplier on the
    -- RATE, never a gate on the input, so damaged ailerons make the aeroplane turn LAZILY
    -- and never make it unturnable - the same principle as the takeoff ease-in above.
    turnAuth = turnAuth * (st.fxRoll or 1)

    local prevHeading = st.heading
    st.heading = st.heading
               - math.rad(turnRateForSpeed(st.airSpeed)) * st.turnInput * turnAuth * dt
    -- Sanity gate: a heading change far larger than the maximum turn rate could produce
    -- can only be a bad read or a numeric fault, so it is rejected rather than applied.
    local maxStep = math.rad(TUNE.TURN_RATE_LOW_DEG * 4) * dt
    if math.abs(st.heading - prevHeading) > maxStep then
        warn(("rejected an impossible heading jump of %.1f deg in one tick")
            :format(math.deg(math.abs(st.heading - prevHeading))))
        st.heading = prevHeading
    end
    st.driveHeading = st.heading
    -- The commanded turn rate, rad/s (a right turn is a falling heading): the attitude hold's
    -- feed-forward and the drive's turn carry both use it (applyFlightForces).
    st.yawRateCmd = (dt and dt > 0) and ((st.heading - prevHeading) / dt) or 0

    -- Powered cruise converges on one absolute height. Ground probes cannot
    -- change it; engine-off flight still glides and damage/stalls retain authority.
    local vsTarget = 0
    if st.mode == "TAKEOFF" then
        vsTarget = engineOn and TUNE.CLIMB_RATE or 0
    elseif st.mode == "AIR" then
        vsTarget = C172Altitude.cruiseVS(st, TUNE, engineOn)
    elseif st.mode == "LANDING" then
        local altRatio = math.max(TUNE.FLARE_MIN_RATIO,
                                  math.min(1, st.altitude / TUNE.FLARE_ALTITUDE))
        vsTarget = -TUNE.DESCEND_RATE * altRatio
        if st.altitude <= TUNE.FLARE_ALTITUDE and st.landingPhase ~= "FLARE" then
            st.landingPhase = "FLARE"
            log("LANDING: flaring for touchdown")
        end
    end

    -- ELEVATOR / TAILPLANE AUTHORITY. Applied to CLIMB only, never to descent: an
    -- aeroplane with a damaged elevator struggles to hold the nose up, and scaling the
    -- descent as well would make a wrecked tailplane help it stay airborne, which is
    -- backwards. So a damaged elevator climbs weakly and still comes down normally, which
    -- is both the correct physics and the correct gameplay - it can always be landed.
    if vsTarget > 0 then vsTarget = vsTarget * (st.fxPitch or 1) end

    -- Stall: climb authority is scaled away and a sink is added, so the aircraft mushes
    -- down and recovers as soon as speed comes back. LANDING is exempt - the descent
    -- there is intentional and must not be fought.
    if st.mode ~= "LANDING" then
        if vsTarget > 0 then vsTarget = vsTarget * liftAuthority end
        if liftAuthority < 1 then
            vsTarget = vsTarget - (1 - liftAuthority) * TUNE.STALL_SINK_RATE
        end
    end

    st.verticalSpeed = (st.verticalSpeed or 0)
                     + (vsTarget - (st.verticalSpeed or 0))
                       * math.max(0, math.min(1, TUNE.VS_RAMP * dt))
    st.altitude = math.max(0, math.min(maxAltitude(),
                                       st.altitude + st.verticalSpeed * dt))
    -- NEVER COMES ALL THE WAY DOWN BY ITSELF (09-26, Jay: "i dont want it to descend aircraft
    -- fully ever"). In AIR the energy model sinks the aircraft whenever speed is under the level
    -- band - air brake, a stall, an engine-off glide - and it used to sink right onto the
    -- ground ("stalled back onto the ground"). Now AIR can sink only to the height at which the
    -- climb-out ended (TUNE.CRUISE_ALTITUDE, ~2.5 m); touching down is always the player's choice via the Land radial
    -- option (LANDING mode is not clamped). TAKEOFF is left alone so an aborted takeoff still
    -- settles back onto the runway.
    if st.mode == "AIR" and st.altitude < TUNE.CRUISE_ALTITUDE then
        st.altitude = TUNE.CRUISE_ALTITUDE
        if (st.verticalSpeed or 0) < 0 then st.verticalSpeed = 0 end
    end

    -- ZERO THE CLIMB RATE AT EITHER LIMIT. Without this, altitude clamps but
    -- verticalSpeed keeps its old value forever, so at the ceiling the aircraft reports a
    -- permanent climb it is not performing - the HUD shows a climb that never ends, and
    -- (since attitude follows verticalSpeed) the nose stays pitched up at cruise instead
    -- of levelling off. Jay's "stops at a good level" depends on this.
    if st.altitude >= maxAltitude() and (st.verticalSpeed or 0) > 0 then
        st.verticalSpeed = 0
    elseif st.altitude <= 0 and (st.verticalSpeed or 0) < 0 then
        st.verticalSpeed = 0
    end

    -- st.pitch / st.bank are held on the real airframe by applyFlightForces (1.9.0).
    updateAttitude(st, cfg, liftAuthority, dt)
    publishFlightState(vehicle, st)

    if st.mode == "TAKEOFF" then
        local elapsed = nowSec() - (st.takeoffAt or 0)
        if st.altitude >= TUNE.CRUISE_ALTITUDE and elapsed >= TUNE.TAKEOFF_LOCKOUT_SEC then
            st.mode = "AIR"
            log("TAKEOFF -> AIR")
        end
    end

    -- STALLED BACK ONTO THE GROUND. The `verticalSpeed <= 0` half is not a refinement -
    -- without it this fires on the FIRST TICK OF EVERY TAKEOFF and cancels it instantly.
    -- enterAirMode starts at altitude 0, so after one tick the altitude is only
    -- CLIMB_RATE * dt: at 0.32 units/s and 60 FPS that is 0.0053, which is below this
    -- 0.01 threshold. (The MiG survives the identical check purely because its climb rate
    -- is more than twice as fast - 0.7 * 1/60 = 0.0117 - so it clears 0.01 by a hair. Its
    -- margin is an accident of tuning, not a design, and any slower aircraft reusing that
    -- code walks straight into this.) Requiring the aircraft to actually be DESCENDING
    -- makes the test mean what it says, at any climb rate and any frame rate.
    if (st.mode == "AIR" or st.mode == "TAKEOFF")
       and st.altitude <= 0.01 and (st.verticalSpeed or 0) <= 0 then
        enterGroundMode(vehicle, st, "stalled back onto the ground")
        return desired, liftAuthority, false
    end

    return desired, liftAuthority, true
end

-- ------------------------------------------------------------------- forces
local function applyFlightForces(vehicle, st, dt)
    local okM, mass = call0(vehicle, "getFudgedMass")
    if not (okM and type(mass) == "number" and mass > 0) then mass = TUNE.LIFT_MASS end

    -- ATTITUDE (1.9.0) - heading, pitch and bank are HELD BY TORQUE, every tick.
    --
    -- The Java build could only change the airframe's orientation by teleporting it, so it
    -- rewrote the heading when the pilot turned and, when they did not, "centred" it back on
    -- the commanded heading whenever it drifted past a tolerance - every rewrite zeroing the
    -- velocity and putting it back. That cycle is where turning lost speed, where the takeoff
    -- flips came from (an over-sized restore at the moment the tyres left physics), and what
    -- read as the aircraft straightening itself. Its pitch and bank were never real at all:
    -- they were drawn on (Patch_ModelTransform) over a body held dead level.
    --
    -- Now C172Phys.holdAttitude pushes either side of the centre to turn the REAL airframe
    -- toward st.heading, st.pitch and st.bank, with the commanded turn rate as feed-forward -
    -- the same spring-and-damper the MH-92 flies on. Nothing is rewritten and nothing is
    -- restored. The pitch (nose up on the climb-out, the flare) and the bank into turns that
    -- used to be painted on are what the airframe actually does now.
    local realHeading = nil
    do
        local fx, fy = javaForwardX(vehicle), javaForwardY(vehicle)
        local len = math.sqrt(fx * fx + fy * fy)
        -- THE AIRFRAME'S REAL PITCH, FOR FREE: the forward vector is unit length, so the
        -- length of its horizontal part is the cosine of the pitch (roll does not show in it).
        local bodyPitchDeg = math.deg(math.acos(math.max(0, math.min(1, len))))
        st.bodyPitchDeg = bodyPitchDeg
        if len > 0.2 then
            realHeading = math.atan2(fx / len, fy / len)
            local d = wrapPi(st.heading - realHeading)
            st.yawDrift = d
            -- Never let the commanded heading run more than HEADING_LEAD_MAX_RAD ahead of the
            -- real nose (a knock, a slow body): the hold would unwind the rest as a spin.
            local lead = TUNE.HEADING_LEAD_MAX_RAD
            if d > lead then
                st.heading = realHeading + lead
            elseif d < -lead then
                st.heading = realHeading - lead
            end
            st.driveHeading = st.heading
        else
            st.yawDrift = 0
        end

        -- EMERGENCY ONLY: an airframe pitched past BODY_PITCH_MAX_DEG is put back level by
        -- hand (heading and height kept). The hold never asks for more than 8 degrees, so
        -- this is inert in healthy flight - see BODY_PITCH_MAX_DEG.
        if bodyPitchDeg > TUNE.BODY_PITCH_MAX_DEG
           and (nowSec() - (st.pitchFixAt or 0)) >= 1.0 then
            st.pitchFixAt = nowSec()
            tcall(C172Phys, "levelKeepHeading", vehicle)
            log(("airframe had pitched %.1f deg off level in flight - levelled. If this " ..
                 "repeats the attitude hold is being overpowered (a collision?)."):format(bodyPitchDeg))
        end
    end

    -- Flare smoothly into the taildragger tire plane in the final few metres.
    local pitchAim = st.pitch or 0
    if st.mode == "LANDING" and (st.altitude or 0) < .35 then
        local blend = math.max(0, math.min(1, 1 - (st.altitude or 0) / .35))
        pitchAim = pitchAim + (math.rad(C172Phys.PARK_PITCH_DEG) - pitchAim) * blend
    end
    local okA = tcall(C172Phys, "holdAttitude", vehicle, st.heading, pitchAim, st.bank or 0,
                      st.yawRateCmd or 0, 1.0, physDt, mass)
    st.okYaw = okA

    -- ONE combined drive call: direction from the heading, magnitude from the airspeed.
    -- (sin, cos) - not (cos, sin) - because that is the pairing getForwardVector uses
    -- (heading = atan2(forward.x, forward.y)). Getting these two out of step is the "W does
    -- not move toward the visible nose" bug.
    local tvx = math.sin(st.driveHeading) * (st.airSpeed / 3.6)
    local tvy = math.cos(st.driveHeading) * (st.airSpeed / 3.6)

    -- CLOSED-LOOP SPEED AUTHORITY - a backstop: compare the body's real speed with the
    -- commanded one and give the drive proportionally more authority while it is behind.
    -- Inert whenever the aircraft is where it should be, which with torque turns and the
    -- turn carry is nearly always.
    local driveForce = TUNE.DRIVE_MAX_FORCE
    do
        local vx, vy = javaVelX(vehicle), javaVelY(vehicle)
        local actual = math.sqrt(vx * vx + vy * vy)
        local want   = st.airSpeed / 3.6
        st.speedDeficit = want - actual
        if st.speedDeficit > TUNE.SPEED_DEFICIT_TOL_MS then
            local boost = 1 + (st.speedDeficit - TUNE.SPEED_DEFICIT_TOL_MS)
                            * TUNE.DRIVE_BOOST_PER_MS
            driveForce = driveForce * math.min(TUNE.DRIVE_BOOST_MAX, boost)
        end
    end
    -- frame scale: the push lands on ONE physics substep per frame, so its effect used to
    -- grow with the frame time; (physics time x 60) keeps 60 fps exactly as tuned and every
    -- other frame rate converging in the same time. TURN CARRY: the velocity swings round
    -- with the commanded turn (C172Phys) - what a banked wing does - so a turn neither
    -- skids wide nor bleeds speed.
    st.okDrive = javaDriveHorizontal(vehicle, tvx, tvy, TUNE.DRIVE_GAIN, driveForce,
                                     physDt * 60, st.yawRateCmd or 0, physDt, mass)

    -- COMMANDED HEIGHT, SURFACE-AWARE.
    --
    -- Surface probes supply landing support and outdoor lighting. Cruise height
    -- is absolute: roofs, hills and water cannot move its lift target.
    local surfaceH = updateSurfaceHeight(vehicle, st, dt)

    -- The roof level selects an outdoor LIGHTING square only. Presentation
    -- follows continuous body height for the pilot's render-only camera anchor.
    do
        local fn = bridgeFn("c172SetPinLevel")
        if fn then
            local lvl = math.floor((st.surfaceRaw or surfaceH or 0) / 2.44949 + 0.001)
            pcall(fn, vehicle, lvl)
        end
    end
    -- GEAR DATUM (1.8.0). A parked Cessna's body origin sits ~1.5 m above the surface on its
    -- gear, but the target used to be measured from level 0 - so every landing commanded the
    -- body ~1.5 m INTO the ground (the Workshop "landing gear clips through the ground"
    -- report), the whole flight sagged by the same amount, and the altimeter could never read
    -- the true ceiling. Everything is now measured from where the airframe actually rests.
    local datum    = st.gearDatum or 0
    local targetH = C172Altitude.target(st, surfaceH, javaBodyHeight(vehicle), physDt, TUNE)
    st.lastTargetH = targetH
    st.lastSurfaceH = surfaceH
    -- LIFT FRAME-RATE SCALING (1.8.0, ported from MiG29Jet 0.3.0). The lift is queued with
    -- applyImpulseGeneric, and WorldSimulation applies that queue to only the FIRST 0.01 s
    -- substep of each frame while gravity acts on every substep (read from the game's
    -- bytecode). So the lift the body received scaled with the frame rate: fine at 60, about a
    -- metre of sag, and below ~32 fps not enough to beat gravity at all - the Workshop "can't
    -- get off the ground, altitude going up and down" / "altitude just stays at 50" reports.
    -- (The old framerate_test could not see this: its stub copied the commanded height back as
    -- the body height.) Hover term = g * frameTime / step, exact at every rate; PD gains keep
    -- the 60 Hz-normalised scale so the climb and settle feel as tuned.
    local fs    = physDt * 60
    local hover = physDt / PHYS_STEP_SEC
    st.okLift = javaLiftBody(vehicle, targetH, TUNE.LIFT_KP * fs, TUNE.LIFT_KD * fs,
                             TUNE.LIFT_GRAVITY * hover, mass, TUNE.LIFT_MAX_FORCE * hover,
                             TUNE.LIFT_ERR_UP, TUNE.LIFT_ERR_DOWN)
    -- Real height above the gear datum, in altitude units, for the HUD (1.8.0): the
    -- altimeter used to show the COMMANDED altitude, so a failed climb still read as climbing.
    do
        local bh = javaBodyHeight(vehicle)
        if type(bh) == "number" and bh == bh and bh >= 0 then
            st.realAltitude = math.max(0, (bh - datum) / TUNE.LIFT_HEIGHT_SCALE)
        else
            st.realAltitude = nil
        end
    end
end

-- GRACEFUL RECOVERY FROM AN ENGINE-SIDE REPOSITION.
--
-- Reaching the top of the flight envelope must never corrupt the aircraft. Several things
-- outside this mod can move the physics body without telling us - most importantly
-- BaseVehicle.update()'s own "fell out of the world" recovery, which teleports the body to
-- y = 0.2. If we simply kept commanding the old altitude afterwards,
-- the lift controller would fight the engine forever: no control, no descent, a permanently
-- broken aeroplane.
--
-- So: if the body is a long way below where we asked it to be, and stays there, we ADOPT
-- REALITY. Near the ground that means a clean, normal transition to GROUND mode; higher up
-- it means resyncing our simulated altitude to the real height and carrying on flying from
-- there. Either way the player keeps control and can always descend and land.
local function checkAltitudeSanity(vehicle, st, dt)
    local h = javaBodyHeight(vehicle)
    if type(h) ~= "number" or h ~= h then return true end   -- no reading = no opinion

    local want = st.lastTargetH
    if type(want) ~= "number" then return true end

    if (want - h) > TUNE.ALT_DESYNC_M then
        st.altDesyncFor = (st.altDesyncFor or 0) + dt
        if st.altDesyncFor >= TUNE.ALT_DESYNC_SEC then
            st.altDesyncFor = 0
            local surface = st.surfaceH or 0
            -- minus the gear datum (1.8.0): the target is measured from where the airframe rests.
            local realAlt = (h - (st.flightBaseH or 0) - (st.gearDatum or 0)) / TUNE.LIFT_HEIGHT_SCALE
            warn(("altitude desync: commanded %.1fm, body is at %.1fm - adopting reality")
                :format(want, h))
            if h - surface - (st.gearDatum or 0) <= 0.34 then
                enterGroundMode(vehicle, st, "recovered from an engine-side reposition")
                return false
            end
            st.altitude = math.max(0, math.min(maxAltitude(), realAlt))
            st.verticalSpeed = 0
            st.flightTargetH = h
        end
    else
        st.altDesyncFor = 0
    end
    return true
end

local function updateFlight(vehicle, st, cfg, dt)
    -- HARD GUARANTEE that a pilot can never be stranded in the air: if a landing has
    -- been requested and has not completed within the timeout, the ground state is
    -- forced regardless of what the descent controller is doing.
    --
    -- `or st.landingAwaitingBody` matters: a landing whose simulated altitude has reached zero
    -- but whose airframe has not yet come down (see the completion test at the end of this
    -- function) is still a landing in progress, and must still be covered by this guarantee.
    -- Without it, an airframe physically stuck on something would wait forever.
    if st.mode == "LANDING" and (st.altitude > 0.01 or st.landingAwaitingBody)
       and nowSec() - (st.landingRequestedAt or 0) > TUNE.LANDING_TIMEOUT_SEC then
        -- This path does not MOVE the aircraft - it stops holding it up. That is acceptable
        -- ONLY because it is now the last resort: a normal landing no longer finishes until
        -- the airframe is actually down, so reaching here means the body has spent the whole
        -- timeout unable to descend (logged cases show it caught on something, colliding=true).
        local h = javaBodyHeight(vehicle)
        warn(("LANDING TIMEOUT after %.0fs - simulated altitude %.2f, airframe %s m above the " ..
              "surface. Forcing ground mode; if the airframe was stuck up there it will drop.")
             :format(TUNE.LANDING_TIMEOUT_SEC, st.altitude or 0,
                     (type(h) == "number") and ("%.2f"):format(h - (st.lastSurfaceH or 0)) or "?"))

        enterGroundMode(vehicle, st, "landing timeout safety net")
        return
    end

    local okEng, engineOn = call0(vehicle, "isEngineRunning")
    engineOn = okEng and engineOn == true
    local wantThrust = (st.mode ~= "LANDING") and engineOn and keyDown(W_KEY) or false
    -- S is the throttle-down / descend control. It is safe to bind in the air because
    -- vanilla's own S handling is brake/reverse through the WHEELS, and in the air the tyres
    -- are out of the physics (enterAirMode) - nothing for it to act on. On the ground S
    -- stays 100% vanilla reverse/brake.
    local wantSlow   = (st.mode ~= "LANDING") and keyDown(S_KEY) and not wantThrust

    local desired, liftAuthority, cont = updateFlightKinematics(vehicle, st, cfg,
                                                                wantThrust, wantSlow,
                                                                engineOn, dt)
    if not cont then return end

    applyFlightForces(vehicle, st, dt)
    if not checkAltitudeSanity(vehicle, st, dt) then return end
    C172Util.setFlightState(vehicle, st.altitude, "AIRBORNE")

    -- GROUND CONTACTS (C172Contacts): off while the airframe is CONTACTS_CLEAR_M above where
    -- it sits on its wheels over the surface below it, so bushes, fences and zombies under the
    -- flight path are not "hit" by an aircraft flying over them; back on for the last metre.
    do
        local bh = javaBodyHeight(vehicle)
        local above = bh and (bh - (st.surfaceRaw or 0) - (st.gearDatum or 1.5)) or 0
        st.contactsClear = above > TUNE.CONTACTS_CLEAR_M
        tcall(C172Contacts, "report", vehicle, st.contactsClear)
    end

    if ALT_DIAG and nowSec() - (st.altDiagAt or 0) >= 1.0 then
        st.altDiagAt = nowSec()
        -- (logical level, pin count and the collision flags came from the Java build only)
        local lz, pins, coll, cx, cy = -1, -1, "?", 0, 0
        pcall(function() lz = vehicle:getZ() end)
        -- Observed yaw RATE, measured from the airframe's own forward vector rather than
        -- from anything we command. If this is large while turnInput is ~0, the body is
        -- carrying rotation nothing is damping - which is the remaining spin suspect.
        local obsRate = 0
        do
            local fx, fy = javaForwardX(vehicle), javaForwardY(vehicle)
            local len = math.sqrt(fx * fx + fy * fy)
            if len > 0.2 then
                local a = math.atan2(fx / len, fy / len)
                if st.obsHeadingPrev then
                    local d = wrapPi(a - st.obsHeadingPrev)
                    local gap = nowSec() - (st.obsHeadingAt or nowSec())
                    if gap > 0.001 then obsRate = math.deg(d) / gap end
                end
                st.obsHeadingPrev, st.obsHeadingAt = a, nowSec()
            end
        end
        print(("[Cessna172][ALT] mode=%s alt=%.2f wantH=%.1fm realH=%s surf=%.1f logicalZ=%.2f " ..
               "pinFires=%d colliding=%s collideXY=(%.2f,%.2f) engineOn=%s " ..
               "drift=%.1fdeg obsYawRate=%.1fdeg/s turnIn=%.2f")
            :format(st.mode, st.altitude or 0, st.lastTargetH or 0,
                    (type(javaBodyHeight(vehicle)) == "number")
                        and ("%.2f"):format(javaBodyHeight(vehicle)) or "n/a",
                    st.surfaceH or 0, lz, pins, coll, cx, cy, tostring(engineOn),
                    math.deg(st.yawDrift or 0), obsRate, st.turnInput or 0))
    end

    if FLIGHT_VERBOSE_LOG and nowSec() - (st.movedLogAt or 0) >= 1.0 then
        st.movedLogAt = nowSec()
        print(("[Cessna172][AIR] mode=%s hdg=%.0f alt=%.2f wantH=%.1fm realH=%s spd=%.0fmph " ..
               "vspd=%.2f lift=%.2f prop=%.2f tires=%s wheelsOnGround=%s thrust=%s turn=%s drive=%s yaw=%s liftCall=%s")
            :format(st.mode, math.deg(st.heading), st.altitude, st.lastTargetH or 0,
                    (javaBodyHeight(vehicle) and ("%.2fm"):format(javaBodyHeight(vehicle)) or "n/a"),
                    st.airSpeed * KMH_TO_MPH, st.verticalSpeed or 0, liftAuthority,
                    st.propRPM or 0, tostring(st.tiresRemoved),
                    tostring(javaWheelsOnGround(vehicle)),
                    (wantThrust and "W" or "-"),
                    (desired < 0 and "A" or desired > 0 and "D" or "-"),
                    tostring(st.okDrive), tostring(st.okYaw), tostring(st.okLift)))
    end

    -- A LANDING IS COMPLETE WHEN THE AIRCRAFT IS DOWN, NOT WHEN THE SIMULATION SAYS SO.
    --
    -- This used to finish on `st.altitude <= 0.01` alone - the SIMULATED altitude. The body
    -- follows the simulation through a PD controller and can lag it, or be held up by
    -- something under it, so the simulation can reach zero while the real airframe is still
    -- metres up. enterGroundMode then stops holding the body, and the aeroplane falls the
    -- rest of the way. That is the "falls out of the sky when I try to land from high up"
    -- report, and it is in the logs: two landings finished with the airframe at 5.80 m and
    -- 4.88 m above the surface.
    --
    -- So the simulation reaching zero now only means "on final". The lift controller is
    -- still commanding the surface, so the airframe keeps descending under control, and the
    -- landing completes the moment its REAL height is within LANDING_BODY_ARRIVED_M. On a
    -- normal landing that is already true at the same tick as before, so nothing changes;
    -- it only waits in the cases that used to drop the aircraft. No teleport is involved,
    -- so heading and momentum are untouched. With no Java bridge there is no reading, and
    -- the old behaviour applies unchanged.
    --
    -- 09-25: measured from the GEAR DATUM when takeoff recorded one (see TOUCHDOWN_DATUM_M),
    -- with a TOUCHDOWN_WAIT_SEC net so a body held up by something still lands.
    if st.mode == "LANDING" and st.altitude <= 0.01 then
        local h = javaBodyHeight(vehicle)
        local above = (type(h) == "number" and h == h) and (h - (st.lastSurfaceH or 0)) or nil
        local datum = st.gearDatum
        local arrived
        if above == nil then
            arrived = true
        elseif type(datum) == "number" and datum > 0 then
            arrived = (above - datum) <= TUNE.TOUCHDOWN_DATUM_M
        else
            arrived = above <= TUNE.LANDING_BODY_ARRIVED_M
        end
        st.finalSince = st.finalSince or nowSec()
        local waited = nowSec() - st.finalSince
        -- "Held up" = no new low for 3 s. A body that is still coming down, however slowly,
        -- is waited for (LANDING_TIMEOUT_SEC remains the outer net) - releasing it early
        -- is exactly the old drop-from-height bug.
        if type(h) == "number" and h == h then
            if st.finalLowH == nil or h < st.finalLowH - 0.05 or waited < 0.05 then
                st.finalLowH, st.finalLowAt = h, nowSec()
            end
        end
        local heldUp = waited >= TUNE.TOUCHDOWN_WAIT_SEC
                       and (nowSec() - (st.finalLowAt or nowSec())) >= 3.0
        if arrived or heldUp then
            log(("touchdown: airframe %s m above the surface (gear datum %.2f)%s")
                :format(above and ("%.2f"):format(above) or "?", st.gearDatum or 0,
                        arrived and "" or (" - held up for %.0fs, landing anyway"):format(waited)))
            enterGroundMode(vehicle, st, "landing complete")
        elseif not st.landingAwaitingBody then
            st.landingAwaitingBody = true
            log(("LANDING: simulated touchdown, but the airframe is still %.2f m up - holding " ..
                 "the descent until it is actually down"):format(above))
        end
    end
end

-- =================================================================== main tick
local function onTick()
    updateTickDelta()
    local dt = tickDt

    local player = getPlayer()
    if not player then return end

    -- GATE 1: in a vehicle at all. Walking exits here, before any key is polled.
    local vehicle = player:getVehicle()
    if not vehicle then return end

    -- GATE 2: it is THIS aircraft. A MiG, a Wraith, a vanilla car and any other mod's
    -- vehicle all exit here - C172Util.getConfig keys strictly off "Base.Cessna172".
    local cfg = C172Util.getConfig(vehicle)
    if not cfg or cfg.category ~= "prop" then return end

    -- GATE 3: the local player is the DRIVER. Passengers get no controls and no HUD.
    local okDrv, isDrv = call1(vehicle, "isDriver", player)
    if not (okDrv and isDrv) then return end

    local st = getState(vehicle)
    showPropeller(vehicle, st)

    local okEng, engineOn = call0(vehicle, "isEngineRunning")
    engineOn = okEng and engineOn == true

    -- ENGINE-OFF INTENT. Watched here because this is the one place that runs every tick for
    -- the driver in BOTH modes, so the airborne shutdown and the grounded enforcement below
    -- read the same value from the same call.
    -- Track how long the engine has been CONTINUOUSLY running, so a shutdown can be told
    -- apart from the noise of a start sequence.
    if engineOn and not st.engineOnSince then
        st.engineOnSince = nowSec()
    elseif not engineOn then
        st.engineOnSince = nil
    end

    if st.lastEngineOn == true and not engineOn then
        -- ARMED FOR A SHUTDOWN ANYWHERE, not just an airborne one - pilot intent is pilot
        -- intent regardless of altitude.
        --
        -- BUT ONLY FOR A SETTLED ENGINE. isEngineRunning() is not clean during a start: PZ
        -- moves through its ignition states and the flag can read true and then false again
        -- within the same second. Arming on any true->false edge therefore latched DURING a
        -- start, and the guard immediately shut the engine back off - which the player then
        -- retried, producing a start/stop loop that sounds like continuous beeping.
        --
        -- Requiring the engine to have been running for ENGINE_SETTLED_SEC first ignores that
        -- flicker entirely while still catching a genuine shutdown, which by definition comes
        -- after the engine has been running for a while.
        if (st.engineOnSinceLast or 0) >= TUNE.ENGINE_SETTLED_SEC then
            st.engineOffInFlight = true
            st.engineHeldOff = true
            st.engineHeldAt = nowSec()   -- see the note where the hold is armed on touchdown
            st.engineOffReported = nil
            log(("engine shut down (%s) after %.1fs running - held off until the player "
                 .. "starts it"):format(st.isAirborne and "in flight" or "on the ground",
                                        st.engineOnSinceLast or 0))
        end
    end
    -- Remember the settled duration BEFORE it is cleared, so the edge above can read it.
    st.engineOnSinceLast = st.engineOnSince and (nowSec() - st.engineOnSince) or 0
    st.lastEngineOn = engineOn

    -- HOLD IT OFF UNTIL THE PLAYER ASKS FOR IT. NOT FOR A FIXED WINDOW.
    --
    -- This was a 3-second guard from touchdown, on the assumption that vanilla brings the
    -- engine back as the vehicle rejoins the ground path. It does not always happen inside
    -- three seconds - it can come back later, when the aircraft settles or on the next control
    -- input - and once the window had passed there was nothing left holding it. That is the
    -- "still auto-starts after I land" report.
    --
    -- The hold is now open-ended, which is only safe because a DELIBERATE start clears it
    -- instantly: the start intent (C172IgnitionKey since 1.9.0; a Java patch before) records
    -- every deliberate start. So "the player asked for the engine" and "vanilla turned it on
    -- by itself" are distinguishable, and only the second one is refused.
    -- THE HOLD IS STRICTLY TIME-BOXED.
    --
    -- Its whole purpose is to swallow ONE automatic restart, which vanilla performs at the
    -- moment the ground path resumes - immediately after the shutdown, never seconds later.
    --
    -- It used to stay armed until a start-intent signal cleared it. That signal never fired
    -- reliably, and an open-ended hold cannot tell a deliberate start from the automatic one:
    -- the pilot pressed start, the engine caught, the hold shut it straight back off, and what
    -- the pilot heard was the engine dying and then nothing. Three separate problems came out
    -- of it - an ejected ignition key, a consumed start, and an aircraft that could not be
    -- started at all - all to fix a single spurious restart.
    --
    -- So it now simply expires. Anything after HOLD_WINDOW_SEC is the player's and is never
    -- touched, whether or not the intent signal works. Worst case the automatic restart slips
    -- through and you switch it off again; that is a far better failure than a dead aeroplane.
    if st.engineHeldOff then
        local age = nowSec() - (st.engineHeldAt or 0)
        local asked = false
        -- 1.8.1: looked up first - a ground start runs even when ZombieBuddy isn't loading the jar
        local startRequested = bridgeFn("c172StartRequested")
        if startRequested then
            pcall(function() asked = startRequested(vehicle) == true end)
        end

        if asked or age > TUNE.HOLD_WINDOW_SEC then
            st.engineHeldOff = nil
            st.engineHeldAt = nil
            st.engineOffReported = nil
            if asked then log("player asked for the engine - hold released.") end

        elseif engineOn and isClient() then
            -- MULTIPLAYER (1.10.1): the engine is the SERVER's. A player report, 2026-10-07: "engine
            -- state not synced across server and clients - for me the plane's engine was stopped (at
            -- least it looked so) ... the engine was still running on the server side, so fuel just
            -- burned out", mostly after RIGHT AIRCRAFT. BaseVehicle.shutOff() on a client changes that
            -- client's copy only (VehicleEngine.doShuttingDown: no packet), so this hold - armed by any
            -- off flicker the client saw, e.g. RIGHT AIRCRAFT resetting the physics - turned the engine
            -- off for this player alone and left it running on the server with nobody to see it.
            -- Throttle auto-starts are refused through the server by C172IgnitionKey's guard
            -- (ISVehicleMenu.onShutOff, whose complete() runs on the server), so here the hold just
            -- lets go and never touches the engine.
            log(("multiplayer: engine running %.1fs after shutdown - left to the server, hold released.")
                :format(age))
            st.engineHeldOff = nil
            st.engineHeldAt = nil
            st.engineOffReported = nil
        elseif engineOn then
            local keysWereIn = false
            pcall(function() keysWereIn = vehicle:isKeysInIgnition() == true end)
            local okOff = call0(vehicle, "shutOff")
            -- shutOff() returns the key to the driver's inventory, i.e. pulls it OUT of the
            -- ignition. Put it back or the aircraft cannot be started afterwards.
            if keysWereIn then pcall(function() vehicle:setKeysInIgnition(true) end) end

            log(("automatic restart caught %.1fs after shutdown - off again (ok=%s, key=%s). " ..
                 "Hold released."):format(age, tostring(okOff), tostring(keysWereIn)))
            st.engineHeldOff = nil
            st.engineHeldAt = nil
            st.engineOffReported = nil
            engineOn = false
        end
    end

    -- Entering an aircraft that still carries stale airborne state from a previous
    -- session or a crash: reset it rather than inherit it.
    if not st.wasDriverLastTick then
        -- A FRESH ENTRY. Two housekeeping jobs that belong here and nowhere else - this is
        -- a real, bounded event, not a per-tick or timed re-assert. Re-asserting model
        -- visibility on a timer churns ModelManager and has been seen to hard-crash on
        -- vehicle entry, so it is deliberately done exactly once per entry, through the
        -- same latch-and-apply path that already runs correctly on a first-ever entry.

        -- 1. HEAL A STALE AIRBORNE SAVE. If the world was saved, or the player
        --    disconnected, while this aircraft was flying, its modData still says
        --    AIRBORNE but every scrap of live Lua state is gone (OnGameStart clears it)
        --    and the tires are back in physics. Without this the mod would trust that
        --    stale flag. Reconciled to GROUND on the spot, whatever the engine is doing -
        --    the previous version only did this with the engine OFF, which missed the
        --    common case of climbing straight back into a running aircraft.
        local okFS, fs = pcall(C172Util.getFlightState, vehicle)
        local staleAirborne = okFS and fs and fs.mode == "AIRBORNE" and not st.isAirborne
        if staleAirborne or (st.mode ~= "GROUND" or st.isAirborne) then
            warn(("reconciling flight state on entry (live mode %s, saved mode %s)")
                :format(tostring(st.mode), okFS and fs and tostring(fs.mode) or "n/a"))
            enterGroundMode(vehicle, st, "fresh pilot entry, reconciling saved state")
        end
    end
    st.wasDriverLastTick = true

    local thrustHeld = keyDown(W_KEY)
    -- GO-AROUND ON A FRESH W PRESS (1.10.4): W already held when the landing was asked for keeps
    -- its old meaning (power on the approach); pressing it again calls the landing off.
    if thrustHeld and not st.wHeldLastTick and st.mode == "LANDING" and st.isAirborne then
        abortLanding(vehicle, st, "W pressed")
    end
    st.wHeldLastTick = thrustHeld
    -- S is read here purely for the AUDIO throttle model - it lets a commanded descent
    -- pull the power back audibly. The flight model's own use of S is unchanged and lives
    -- in updateFlight; this does not gate, consume or reinterpret the key.
    local descendHeld = keyDown(S_KEY)
    -- ORDER MATTERS: the audio update is what advances st.rpm, and the propeller now reads
    -- st.rpm. Calling them the other way round would draw the blades one tick behind the
    -- engine note - small, but it is exactly the kind of lag that reads as "the propeller
    -- does not match the sound".
    updateEngineAudio(vehicle, st, cfg, thrustHeld, descendHeld, dt)
    updatePropeller(vehicle, st, engineOn, dt)

    -- EXACTLY ONE of these two branches runs per tick, never both.
    if st.isAirborne then
        updateFlight(vehicle, st, cfg, dt)
        return
    end

    -- ---- GROUND MODE. Vanilla wheel physics IS taxi and the takeoff roll: it keeps
    if C172GroundHandling.isParked(vehicle) then
        st.rollout=nil
        return
    end
    -- position, heading, speed and steering. The ONE thing written here is attitude.
    --
    -- KEEP IT LEVEL. PZ drives a vehicle through its wheel contact patches, a long way
    -- below the centre of mass, so throttle pitches this airframe nose-up. With a 0.94
    -- wheelbase carrying a 3.5-unit tail overhang, the nose gear reaches full extension
    -- and stops resisting, and it keeps rotating - a real flight log caught it going
    -- pitchDeg 9.8 -> 89.8 in one second, ending with all four wheels off the ground, the
    -- aircraft standing on its tail half-buried, and vanilla throwing
    -- "Forward Direction cannot be zero length vector" out of IsoPlayer.updateWhileInVehicle,
    -- which exits the game. Four builds of centre-of-mass and spring tuning did not make
    -- that lever safe. Pinning the attitude does, and it is what the aircraft should look
    -- like anyway: level, the way it sits when it spawns.
    --
    -- The leveller (C172Phys) only writes when the tilt actually exceeds GROUND_MAX_TILT_DEG,
    -- so ordinary driving is never written over. It is deliberately NOT applied while
    -- airborne; up there the attitude hold owns the airframe and this would fight it.
    if bridgeAvailable() then
        if not C172GroundHandling.isParked(vehicle) then
            tcall(C172Phys, "holdGroundGear", vehicle, dt)
        end
        do
            local corrected = javaLevelGround(vehicle, TUNE.GROUND_MAX_TILT_DEG, player:getZ())
            local okL = corrected ~= nil
            -- Report at most once a second so a persistent fight is visible in the log
            -- without a per-tick flood.
            if okL and type(corrected) == "number" and corrected > 0
                and nowSec() - (st.levelLogAt or 0) >= 1.0 then
                st.levelLogAt = nowSec()
                log(("ground attitude levelled (was %.1f deg off level)"):format(corrected))
            end
        end
    end

    -- TOUCHDOWN SETTLE (09-25). Jay, twice: "gets stuck in ground landing", both times freed
    -- only by RIGHT AIRCRAFT - once 25 deg nose-up, once after the tires came back a metre up.
    -- For a few seconds after touchdown, an airframe that STAYS tipped or sunk is put back on
    -- its wheels the same way RIGHT AIRCRAFT does (the forced form of the leveller above:
    -- level, vanilla resting height for the storey, heading kept). A normal landing never
    -- trips it; the tilt and height must stay wrong for TOUCHDOWN_BAD_SEC, so the brief
    -- suspension squash of an ordinary touchdown is ignored.
    if st.touchdownAt and (nowSec() - st.touchdownAt) <= TUNE.TOUCHDOWN_SETTLE_SEC
       and (st.settleFixes or 0) < 2 and bridgeAvailable() then
        local tilt = javaBodyTilt(vehicle)
        local h = javaBodyHeight(vehicle)
        local datum = st.gearDatum or 1.5
        local above = (type(h) == "number") and (h - javaSurfaceHeight(vehicle)) or nil
        local tipped = type(tilt) == "number" and tilt > TUNE.TOUCHDOWN_MAX_TILT_DEG
        local sunk = type(above) == "number" and above < datum - TUNE.TOUCHDOWN_SUNK_M
        if tipped or sunk then
            st.settleBadSince = st.settleBadSince or nowSec()
            if nowSec() - st.settleBadSince >= TUNE.TOUCHDOWN_BAD_SEC then
                st.settleFixes = (st.settleFixes or 0) + 1
                st.settleBadSince = nil
                tcall(C172Phys, "reseatRolling", vehicle)
                log(("touchdown settle: airframe was %s%s - put back on its wheels (%d)")
                    :format(tipped and ("%.1f deg tipped"):format(tilt) or "",
                            sunk and ((tipped and ", " or "") .. ("%.2f m up, datum %.2f"):format(above, datum)) or "",
                            st.settleFixes))
            end
        else
            st.settleBadSince = nil
        end
    end

    -- Coast after touchdown until the pilot uses throttle/brakes, or the
    -- aircraft reaches a walking pace. Steering remains vanilla throughout.
    local pedal = false
    pcall(function() pedal = vehicle:isBrakePedalPressed() end)
    C172GroundHandling.rollout(vehicle, st, dt, thrustHeld,
        pedal or keyDown(S_KEY) or keyDown(Keyboard.KEY_SPACE))

    -- SURFACE HOLD. Only ever runs when the aircraft is genuinely standing on something
    -- ABOVE ground level. On ordinary ground this whole block is skipped and vanilla wheel
    -- physics is left completely alone - which matters, because fighting the drivetrain
    -- with a lift controller is exactly how a taxiing aircraft starts behaving strangely.
    --
    -- The target is RE-SAMPLED every tick rather than pinned to the touchdown height, so
    -- taxiing off the edge of a roof lowers the target with the surface and the aircraft
    -- descends under the same PD controller it flies with, instead of dropping or
    -- snapping. Gains are deliberately softer than the flight ones: this is a support, not
    -- a manoeuvre.
    do
        local liveSurface = updateSurfaceHeight(vehicle, st, dt)
        if (st.groundSurfaceH or 0) > 0.1 or liveSurface > 0.1 then
            st.groundSurfaceH = liveSurface
            local okM, mass = call0(vehicle, "getFudgedMass")
            if not (okM and type(mass) == "number" and mass > 0) then mass = TUNE.LIFT_MASS end
            local fs, hover = physDt * 60, physDt / PHYS_STEP_SEC   -- see LIFT FRAME-RATE SCALING
            javaLiftBody(vehicle, liveSurface,
                         TUNE.SURFACE_HOLD_KP * fs, TUNE.SURFACE_HOLD_KD * fs,
                         TUNE.LIFT_GRAVITY * hover, mass, TUNE.LIFT_MAX_FORCE * hover,
                         TUNE.LIFT_ERR_UP, TUNE.LIFT_ERR_DOWN)
        end
    end

    -- Keep easing the visual attitude while grounded so the airframe settles flat after a
    -- landing and is already flat before the next takeoff - a continuous transition in both
    -- directions rather than a snap at the mode boundary.
    -- (On the ground the wheels hold the real airframe; nothing is applied to it here.)
    updateAttitude(st, cfg, 1.0, dt)

    local okS, speed = call0(vehicle, "getCurrentAbsoluteSpeedKmHour")
    st.airSpeed = (okS and type(speed) == "number") and speed or 0
    publishFlightState(vehicle, st)

    if GROUND_DIAG and nowSec() - (st.diagAt or 0) >= 1.0 then
        st.diagAt = nowSec()
        local okSpd, spd = call0(vehicle, "getCurrentSpeedKmHour")
        local okWork, working = call0(vehicle, "isEngineWorking")
        local okStart, started = call0(vehicle, "isEngineStarted")
        local okKeys, keys = call0(vehicle, "isKeysInIgnition")
        local java = "n/a"   -- (the Java build's own ground probe)
        -- Run on every diagnostic line, not only when the Java side reports
        -- operational=false: a checkOperate that only refuses intermittently (one
        -- driven by a fluctuating condition, temperature or fuel value) would be
        -- invisible in a single sample, and the whole point of this build is that one
        -- ten-second recording has to settle the question.
        local parts = "partProbe=skipped"
        local okProbe, probeResult = pcall(probeCheckOperate, vehicle)
        if okProbe and type(probeResult) == "string" then parts = probeResult end

        -- S IS PRINTED TOO as of 0.1.13. The reverse investigation needs to separate
        -- "the mod never sees S" from "the mod sees it but the game does not act on it",
        -- and the previous line printed W/A/D only. Note the mod does NOT read S on the
        -- ground at all - reverse is pure vanilla drivetrain - so S here is purely a
        -- witness that the key is down, to be read against ctlB (the game's own
        -- clientControls.backward) and ctlForce (the drive force it computed) on the same
        -- line. Those three together say exactly where reverse is being lost:
        --   S=false                      -> the keybind is not S, or input is being eaten
        --   S=true, ctlB=false           -> vanilla is not reading the Backward bind
        --   S=true, ctlB=true, ctlForce=0-> input arrived, no reverse force was computed
        --   ctlForce<0 but spd stays 0   -> force applied, wheels not moving it: read
        --                                   skid= (slip) and susp= (load on the drive axle)
        --   chunkB=true                  -> vanilla is force-braking: the chunk behind is
        --                                   not loaded, which blocks reverse by design
        print(("[Cessna172][GROUND] W=%s S=%s A=%s D=%s | absSpd=%.1f spd=%s engineRunning=%s " ..
               "engineWorking=%s engineStarted=%s keysIn=%s | %s | %s")
            :format(tostring(thrustHeld), tostring(keyDown(S_KEY)),
                    tostring(keyDown(A_KEY)), tostring(keyDown(D_KEY)),
                    st.airSpeed,
                    (okSpd and type(spd) == "number") and ("%.1f"):format(spd) or "err",
                    tostring(engineOn),
                    tostring(okWork and working), tostring(okStart and started),
                    tostring(okKeys and keys), java, parts))
    end

    if st.airSpeed >= takeoffKmh(cfg) and thrustHeld and engineOn then
        if nowSec() - (st.modeChangedAt or 0) >= TUNE.MODE_COOLDOWN_SEC then
            -- ================================ THE AVIATION SKILL GATE ================================
            --
            -- HERE, AND NOWHERE ELSE. This one `if` is the single GROUND -> AIR edge in the whole
            -- controller, so gating it is enough to prevent flight, and gating it is all that is
            -- done: the player can still unlock, enter, start, taxi, refuel, inspect and repair the
            -- aircraft without knowing how to fly it. Only ROTATION is refused, which is exactly the
            -- line Jay asked for and also the honest one - taxiing an aeroplane is not flying it.
            --
            -- WHY NOT AT THE IGNITION. Blocking the engine would stop mechanics work, ground testing
            -- and moving the aircraft out of the way, all of which are reasonable things to do with
            -- a machine you cannot fly. It would also be a worse failure in multiplayer, where a
            -- qualified pilot may want a passenger to reposition it.
            --
            -- FAIL OPEN, BY CONSTRUCTION. canFly() returns true when the aircraft is unregistered,
            -- when there is no character, and when the skill could not be created at all - so a
            -- broken or absent framework yields an aeroplane that flies, never one that cannot.
            local allowed, ctx = true, nil
            if C172Aviation and C172Aviation.canFly then
                allowed, ctx = C172Aviation.canFly(getPlayer())
            end
            if not allowed then
                -- Told once every REFUSE_MESSAGE_SEC, not once per tick. At 45 Hz an ungated message
                -- would be forty-five lines of chat a second for as long as the throttle is open.
                if nowSec() - (st.refusedAt or 0) >= REFUSE_MESSAGE_SEC then
                    st.refusedAt = nowSec()
                    local msg = Aviation and Aviation.deniedMessage(ctx)
                        or "Your Aviation skill is too low to fly this aircraft."
                    -- getPlayer() is exactly the right character here: onTick already
                    -- established that this client's player IS the driver of this vehicle
                    -- (isDriver, line ~2163) before any of this runs, so each client gates
                    -- its own pilot and a passenger's client never evaluates the rule at all.
                    --
                    -- addBadText(IsoPlayer, String) - signature read from the jar, not
                    -- assumed. A wrong Java signature is thrown straight THROUGH pcall by
                    -- Kahlua and would take the whole tick handler down with it.
                    local player = getPlayer()
                    if player then
                        pcall(function() HaloTextHelper.addBadText(player, msg) end)
                    end
                end
                -- Deliberately NOT entering air mode, and deliberately not touching speed, throttle
                -- or attitude either. The aircraft keeps rolling exactly as it was; it simply does
                -- not rotate. Braking it or cutting the throttle here would read as a bug.
            else
                enterAirMode(vehicle, st, st.airSpeed, cfg)
            end
        end
    end
end
-- The start intent lives in C172IgnitionKey (1.9.0): a pass-through wrapper on
-- ISVehicleMenu.onStartEngine, which the radial menu, the start key, the dashboard and the
-- W-to-start press all reach. (1.8.x hooked BaseVehicle.tryStartEngine from Java.)

Events.OnTick.Add(onTick)

-- ======================================================= other aircraft nearby
--
-- MULTIPLAYER PROPELLER AND AUDIO, WITH ZERO PACKETS.
-- Everything these two need is state vanilla already replicates: isEngineRunning() and
-- getCurrentAbsoluteSpeedKmHour() are both live on every client for every vehicle. So
-- rather than broadcast propeller phase or audio levels (which would be per-frame
-- traffic AND a desync source), each client derives them locally for every Cessna it can
-- see. A parked Cessna with its engine running in single player gets the same treatment,
-- which is why this is not gated on isClient().
--
-- The vehicle the local player is DRIVING is deliberately skipped - onTick above already
-- owns it, and running both would double-advance its propeller.
local nearbyList = {}
local sweepAt = 0

-- Forward declaration: releaseRemoteVehicle is defined with the rest of the lifecycle
-- handling further down, but the sweep below needs to call it. Declared here so the sweep
-- closes over the eventual value rather than capturing a nil global.
local releaseRemoteVehicle

-- PRUNE ABANDONED FLIGHT STATE.
--
-- `state` is keyed by vehicle id and nothing ever removed from it, so a long session that
-- spawns and destroys aircraft grew it without bound. The leak is small, but the real risk
-- is CORRECTNESS: if PZ ever hands a new vehicle an id a destroyed one used, that vehicle
-- would inherit stale flags - isAirborne, tiresRemoved, a mid-flight mode - and behave like
-- the aeroplane that no longer exists.
--
-- Expiry is purely TIME-BASED and asks the world nothing. Enumerating vehicles from Lua to
-- check which still exist is exactly the call that crashes THROUGH pcall while the world is
-- loading (see the sweep below), so this deliberately does not go near it.
--
-- The vehicle this client is actively flying is never pruned, whatever the clock says.
local function pruneFlightState(t)
    if t - statePruneAt < 60 then return end
    statePruneAt = t
    local keepId = nil
    if airborneVehicle then
        local okId, id = pcall(function() return airborneVehicle:getId() end)
        if okId then keepId = id end
    end
    local dropped = 0
    for id, st in pairs(state) do
        if id ~= keepId and (t - (st.lastSeenAt or 0)) > STATE_TTL_SEC then
            state[id] = nil
            dropped = dropped + 1
        end
    end
    if dropped > 0 then
        log(("released flight state for %d aircraft not seen for %ds"):format(dropped, STATE_TTL_SEC))
    end
end

local function sweepNearbyAircraft()
    local t = nowSec()
    if t - sweepAt < TUNE.SWEEP_INTERVAL_SEC then return end
    sweepAt = t
    pruneFlightState(t)

    local player = getPlayer()
    if not player then nearbyList = {}; return end
    local okPos, px, py = pcall(function() return player:getX(), player:getY() end)
    if not okPos then nearbyList = {}; return end

    local fresh = {}

    -- ENUMERATION HAPPENS IN JAVA. THIS IS NOT A STYLE CHOICE.
    --
    -- This block used to be:
    --     pcall(function() return VehicleManager.instance:getVehicles() end)
    -- VehicleManager.instance is NULL while the world is still loading, and indexing a
    -- null through Kahlua raises "attempted index: instance of non-table: null" - which
    -- pcall DOES NOT CONTAIN. Kahlua's KahluaUtil.fail() dumps a stack trace and opens
    -- PZ's Lua error window straight through any surrounding pcall. It crashed on
    -- load-in, every single time. (getCell():getVehicles() as a fallback was the same bug
    -- twice: getCell() is null just as early.)
    --
    -- There is no Lua-side way to test whether a Java reference is null without indexing
    -- it, which is the very thing that throws - so the scan moved to C172Physics, where
    -- a null check is just a null check. Lua now never touches VehicleManager, IsoWorld
    -- or IsoCell at all, and is only ever handed real, non-null vehicles that are already
    -- confirmed to be this aircraft. Before the world exists the scan simply returns 0.
    if bridgeAvailable() then
        local scan = bridgeFn("c172ScanNearbyAircraft")
        local get  = bridgeFn("c172NearbyAircraft")
        if scan and get then
            local okN, n = pcall(function() return scan(px, py, TUNE.SWEEP_RADIUS_TILES) end)
            if okN and type(n) == "number" and n > 0 then
                for i = 0, n - 1 do
                    local okV, v = pcall(function() return get(i) end)
                    if okV and v then table.insert(fresh, v) end
                end
            end
        end
    end

    -- RELEASE WHAT LEFT RANGE. Without this, an aircraft that drives or is driven out of
    -- the sweep radius keeps whatever audio voices and propeller rate it had at the
    -- moment it dropped off the list, with nothing left to update or stop them. Anything
    -- present last sweep and absent now is shut down explicitly.
    local stillHere = {}
    for i = 1, #fresh do
        local okI, id = pcall(function() return fresh[i]:getId() end)
        if okI and id then stillHere[id] = true end
    end
    for i = 1, #nearbyList do
        local v = nearbyList[i]
        local okI, id = pcall(function() return v:getId() end)
        if okI and id and not stillHere[id] and state[id] then
            releaseRemoteVehicle(v, state[id])
        end
    end

    nearbyList = fresh
end

local function updateNearbyAircraft()
    local dt = tickDt
    local player = getPlayer()

    -- Identified by vehicle ID, not by comparing the two userdata references. Kahlua
    -- hands Lua a wrapper around the Java object and two wrappers for the same vehicle
    -- are not guaranteed to be the same Lua value, so `v ~= ownVehicle` could silently
    -- fail to match - and the cost of that specific miss is the DRIVEN aircraft being
    -- advanced twice per tick, i.e. a propeller spinning at double rate and a doubled
    -- audio update. An integer comparison cannot fail that way.
    local ownId = nil
    if player then
        local okV, v = pcall(function() return player:getVehicle() end)
        if okV and v then
            local okD, isD = call1(v, "isDriver", player)
            if okD and isD then
                local okI, i = pcall(function() return v:getId() end)
                if okI then ownId = i end
            end
        end
    end

    for i = 1, #nearbyList do
        local v = nearbyList[i]
        local okId, id = pcall(function() return v:getId() end)
        if okId and id and id ~= ownId then
            do
                local cfg = C172Util.getConfig(v)
                if cfg then
                    local st = getState(v)
                    showPropeller(v, st)
                    local okEng, engineOn = call0(v, "isEngineRunning")
                    engineOn = okEng and engineOn == true
                    -- Real replicated ground speed drives both the propeller load and
                    -- the audio blend for a remote aircraft. While it is airborne the
                    -- relayed airSpeed from C172Server overrides this (see
                    -- onServerCommand) and this line simply refreshes between relays.
                    if not st.isAirborne then
                        local okS, spd = call0(v, "getCurrentAbsoluteSpeedKmHour")
                        st.airSpeed = (okS and type(spd) == "number") and spd or 0
                    end
                    -- Same ordering rationale as the driven aircraft: audio first, so the
                    -- propeller reads this tick's RPM rather than last tick's.
                    -- thrustHeld is false for a remote aircraft: another player's key
                    -- state is not ours to read, and inventing it would be guesswork. The
                    -- only effect is that the power layer is capped a little lower for
                    -- somebody else's aircraft than for your own, which is inaudible at
                    -- the distance you hear one from.
                    updateEngineAudio(v, st, cfg, false, false, dt)
                    updatePropeller(v, st, engineOn, dt)
                end
            end
        end
    end
end

Events.OnTick.Add(function()
    sweepNearbyAircraft()
    updateNearbyAircraft()
end)

-- ============================================================ server -> client
-- The receive half of publishFlightState. Applies ONLY the simulated values that have no
-- vanilla replication - altitude and the canopy threshold, which the collision patches
-- read - plus the airspeed the local audio/propeller blend uses while a remote aircraft
-- is airborne. It never applies position, orientation or engine state: those are
-- vanilla's, and writing them here is how duplication and desync happen.
local function onServerCommand(module, command, args)
    if module ~= "cessna172" or command ~= "flightUpdate" then return end
    if type(args) ~= "table" then return end

    -- Looked up through the Java bridge, NOT via VehicleManager.instance from Lua. That
    -- was a second instance of the same uncatchable null-index crash that took the game
    -- down on load-in; it just needed a flightUpdate to arrive at the wrong moment.
    if not bridgeAvailable() then return end
    local byId = bridgeFn("c172VehicleById")
    if not byId then return end
    local okVeh, vehicle = pcall(function() return byId(args.vehicleId) end)
    if not okVeh or not vehicle then return end

    -- Re-check identity on receive. A malformed or hostile id must not be able to make
    -- this client apply aircraft state to somebody's van.
    local cfg = C172Util.getConfig(vehicle)
    if not cfg then return end


    local okDrv, isDrv = call1(vehicle, "isDriver", getPlayer())
    if not (okDrv and isDrv) then
        local st = getState(vehicle)
        if type(args.mode) == "string" then
            st.mode = args.mode
            st.isAirborne = (args.mode ~= "GROUND")
        end
        if type(args.airSpeed) == "number" then st.airSpeed = args.airSpeed end
        st.altitude = (type(args.altitude) == "number") and args.altitude or st.altitude
        -- 1.10.3: somebody else's Cessna - drawn when zoomed in, its name tag at its height
        -- (C172Presentation), and ground contacts off while it is clear (C172Contacts)
        tcall(C172Phys, "noteRemoteFlight", vehicle, st.isAirborne == true)
        tcall(C172Contacts, "remoteReport", vehicle, args.clear == true and st.isAirborne == true)
    end
end
Events.OnServerCommand.Add(onServerCommand)

-- ================================================================== lifecycle
-- LOCAL release: the aircraft THIS client was flying. Safe to change flight state,
-- because this client owns it.
local function releaseOwnVehicle(v, st, reason)
    if not (v and st) then return end
    if st.isAirborne then enterGroundMode(v, st, reason) end
    stopEngineAudio(v, st)
    javaSetPropRate(v, 0)
    st.pitch, st.bank = 0, 0
    st.propRPM = 0
    st.wasDriverLastTick = false
end

-- REMOTE release: an aircraft that simply left this client's audible range. It may well
-- still be in the air with another player flying it.
--
-- THIS DELIBERATELY TOUCHES NOTHING BUT LOCAL PRESENTATION. It stops the sounds this
-- client was playing and stops advancing the propeller this client was drawing - nothing
-- else. It must NOT call enterGroundMode, which would clear the airborne registry, put
-- the tires back into physics and write a ground speed onto somebody else's aircraft
-- mid-flight: one player walking away would knock another player out of the sky. The
-- distinction between this and releaseOwnVehicle above is the whole reason there are two
-- functions rather than one with a flag.
releaseRemoteVehicle = function(v, st)
    if not (v and st) then return end
    stopEngineAudio(v, st)
    javaSetPropRate(v, 0)
end

local function onExitVehicle(character)
    local okPlayer, isPlayer = pcall(function()
        return instanceof(character, "IsoPlayer") and character:isLocalPlayer()
    end)
    if not okPlayer or not isPlayer then return end

    -- Only the vehicle this client was actually flying is released. Another player's
    -- Cessna, and any parked one, are left entirely alone - one player leaving a seat
    -- must never touch anybody else's aircraft.
    if airborneVehicle ~= nil then
        local v = airborneVehicle
        local okId, id = pcall(function() return v:getId() end)
        if okId and id and state[id] then
            releaseOwnVehicle(v, state[id], "pilot left the aircraft while airborne")
        end
        airborneVehicle = nil
    end
end
Events.OnExitVehicle.Add(onExitVehicle)

-- Save/reload and disconnect/reconnect both re-run OnGameStart. Simulated flight state
-- is per-session and must NOT survive it: a vehicle reloaded from a save is on the
-- ground by definition (its Bullet body is), so carrying an "airborne" flag across would
-- leave a parked aircraft with collision suppressed and its tires out of physics. Every
-- Java-side registry entry is cleared through the same path that created it.
local function resetAllFlightState()
    for id, st in pairs(state) do
        st.isAirborne = false
        st.mode = "GROUND"
        st.altitude = 0
        st.propRPM = 0
        st.propAngle = 0
        st.lowLoopId, st.midLoopId, st.highLoopId = nil, nil, nil
        st.startId, st.stopId = nil, nil
        state[id] = nil
    end
    nearbyList = {}
    airborneVehicle = nil
    lastTickAt = nil
    -- A dedicated ZERO-ARGUMENT Java call, not setFlightState(nil, false). Kahlua
    -- resolves Java overloads from the argument types it is handed, and a nil where a
    -- BaseVehicle is expected is not reliably matched - and a failed Java dispatch is NOT
    -- something pcall can catch, so getting it wrong here would be a hard exit on every
    -- single game start rather than a caught error. A no-arg method cannot be
    -- mis-resolved. See C172Physics.resetAllFlightState.
    local fn = bridgeFn("c172ResetAllFlightState")
    if fn then pcall(fn) end
end
Events.OnGameStart.Add(resetAllFlightState)

-- ================================================================= public API
-- Consumed by C172Recovery.lua (radial menu) and C172HUD.lua. Deliberately small, and
-- every entry point revalidates rather than trusting its caller.

function C172Flight.isAircraft(vehicle)
    return C172Util.getConfig(vehicle) ~= nil
end

function C172Flight.isAirborne(vehicle)
    if not vehicle then return false end
    local okId, id = pcall(function() return vehicle:getId() end)
    if not okId or not id then return false end
    return state[id] ~= nil and state[id].isAirborne == true
end

function C172Flight.getState(vehicle)
    if not vehicle then return nil end
    if not C172Util.getConfig(vehicle) then return nil end
    return getState(vehicle)
end

function C172Flight.getTune()
    return TUNE
end

-- Emergency escape hatch, and the "RIGHT AIRCRAFT" radial option's worker. Always
-- succeeds in returning the aircraft to a normal ground state, whatever it was doing.
function C172Flight.forceGroundMode(vehicle, reason)
    if not vehicle or not C172Util.getConfig(vehicle) then return false end
    enterGroundMode(vehicle, getState(vehicle), reason or "external recovery")
    return true
end

function C172Flight.abortLanding(vehicle, reason)
    if not vehicle or not C172Util.getConfig(vehicle) then return false end
    return abortLanding(vehicle, getState(vehicle), reason or "abort requested")
end

function C172Flight.requestLanding(vehicle, reason)
    if not vehicle or not C172Util.getConfig(vehicle) then return false end
    local st = getState(vehicle)
    if not st.isAirborne then
        log("Land Aircraft ignored - not currently airborne")
        return false
    end
    if st.mode == "LANDING" then
        log("Land Aircraft ignored - already landing")
        return true
    end
    enterLandingPhase(vehicle, st, reason or "Land Aircraft radial option")
    return true
end

return C172Flight
