--[[
    C172FlightXP - earns the Aviation skill by FLYING.

    ============================ WHY THIS FILE HAS TO EXIST ============================

    Before this, the manuals were not the main way to level Aviation - they were the ONLY way.
    An audit of every XP award in the mod found exactly two: AviationBookXP (the manuals) and
    the debug menu, which is -debug gated and not a player route at all. Flying awarded nothing.

    Three manuals cap out at Aviation 6, so levels 7-10 could not be reached by any means. The
    skill description shipped on the Workshop page promises them anyway:

        Lvl 7-8 - Seasoned. Heavier and faster aircraft become manageable.
        Lvl 9-10 - Command. Nothing in the air surprises you.

    That is a promise the mod could not keep. It also blocks any future aircraft that wants to
    gate on a level above 6 - the MiG-29 being the obvious one - because there would be no way
    to earn what it asked for.

    Flying is the skill's own activity, the way carpentry is Carpentry's, so flying is what
    pays. The books stay the fast start and the head start; the air is where the rest comes
    from.

    ============================ HOW IT PAYS ============================

    Two awards, both only ever to the PILOT - a passenger earns nothing:

      * TIME AIRBORNE, credited per whole minute of real time actually off the ground.
      * A LANDING BONUS on touchdown, so the loop rewards completing a flight rather than
        idling at altitude with the nose trimmed. It is only paid after a flight long enough
        to be a flight (MIN_FLIGHT_SEC), which stops a runway porpoise from farming it.

    The award goes through Aviation.addXP, which is AddXP - the multiplier-bearing path -
    NOT AddXPNoMultiplier. That is deliberate and it is what finally makes the SkillBook
    multipliers in AviationFramework mean something: reading a manual raises the multiplier,
    and the multiplier then applies to the XP the flying earns. Read, then fly, and the two
    halves compound the way every vanilla skill works.

    ============================ THE RATES ============================

    PZ's cumulative XP thresholds put level 6 at 5,775 and level 10 at 32,775, so the whole
    stretch the books cannot teach is 27,000 XP. At XP_PER_MINUTE that is about ten hours of
    airborne time at a 1x multiplier, and proportionally less once a manual's multiplier is
    running. Ten hours to top out the last four levels of a skill is in the same territory as
    a vanilla skill's upper end, which is the intent - the books get you flying in one sitting,
    mastery does not.

    Numbers are here at the top precisely so they can be retuned without reading the file.

    ============================ WHY IT IS ITS OWN FILE ============================

    C172Flight is the flight controller and is deliberately left alone: it is the one part of
    this mod that must not acquire unrelated responsibilities. This file observes the same
    state from the outside through the public helpers (C172Util.isAircraft, the c172 Java
    bridge) and writes nothing the controller reads, so it cannot perturb flight behaviour.
]]

require "Aviation/AviationFramework"
require "Cessna172/C172Util"

if C172FlightXP then return C172FlightXP end
C172FlightXP = {}

-- ---------------------------------------------------------------------------------- TUNING
local XP_PER_MINUTE   = 45      -- XP per whole minute of real time airborne, pre-multiplier
local XP_PER_LANDING  = 200     -- one-off, on touchdown after a real flight
local MIN_FLIGHT_SEC  = 45      -- a "flight" has to last this long to earn the landing bonus
local AIRBORNE_HEIGHT = 0.75    -- body height (Bullet units) above which we count as flying

-- ------------------------------------------------------------------------------------ STATE
-- Keyed by nothing: there is exactly one local player in a PZ client, so one record is right.
local secondsAirborne = 0       -- carried remainder, so partial minutes are never lost
local flightSeconds   = 0       -- length of the CURRENT flight, for the landing bonus gate
local wasAirborne     = false
local lastStamp       = nil

local function log(msg) print("[Aviation] " .. msg) end

local function nowSec()
    local t = nil
    pcall(function() t = getTimestampMs() end)
    if type(t) == "number" then return t / 1000 end
    return os.time()
end

-- The pilot's aircraft, or nil. Deliberately strict: not in a vehicle, not this aircraft, or
-- sitting in a passenger seat all return nil, and nothing is earned.
local function pilotedAircraft(player)
    if not player then return nil end
    local vehicle = nil
    pcall(function() vehicle = player:getVehicle() end)
    if not vehicle then return nil end
    if not C172Util.isAircraft(vehicle) then return nil end
    local isDriver = false
    pcall(function() isDriver = vehicle:isDriver(player) == true end)
    if not isDriver then return nil end
    return vehicle
end

-- Height is read from the same Java bridge the lights and the HUD use, rather than from the
-- controller's own table, so this file never reaches into C172Flight's state.
local function isAirborne(vehicle)
    local h = nil
    -- 1.9.0: C172Phys (Lua) - see C172AirborneLights
    local bodyHeight = C172Phys and C172Phys.c172GetBodyHeight
    if type(bodyHeight) == "function" then pcall(function() h = bodyHeight(vehicle) end) end
    if type(h) ~= "number" then return false end
    return h > AIRBORNE_HEIGHT
end

local function award(player, amount, why)
    if amount <= 0 then return end
    if not (Aviation and Aviation.isSkillAvailable()) then return end
    Aviation.addXP(player, amount)
    -- Keep the earned level recoverable on a server that has not registered this custom perk.
    -- Same reason as the manuals: see AviationBookXP's multiplayer note.
    pcall(function() Aviation.recordTrained(player, Aviation.getLevel(player)) end)
    log(("+%d XP (%s) -> Aviation %d"):format(amount, why, Aviation.getLevel(player) or 0))
end

local function tick()
    local player = getSpecificPlayer(0)
    if not player then return end
    local dead = false
    pcall(function() dead = player:isDead() end)
    if dead then return end

    local stamp = nowSec()
    local dt = 0
    if lastStamp then dt = stamp - lastStamp end
    lastStamp = stamp
    -- A pause, a load screen or a menu produces a huge or negative delta. Discard it rather
    -- than paying out for time nobody spent flying.
    if dt <= 0 or dt > 5 then return end

    local vehicle = pilotedAircraft(player)
    local flying  = vehicle ~= nil and isAirborne(vehicle)

    if flying then
        secondsAirborne = secondsAirborne + dt
        flightSeconds   = flightSeconds + dt
        while secondsAirborne >= 60 do
            secondsAirborne = secondsAirborne - 60
            award(player, XP_PER_MINUTE, "1 min airborne")
        end
    elseif wasAirborne then
        -- Touchdown, or the pilot left the aircraft in the air. Either way the flight is over.
        if flightSeconds >= MIN_FLIGHT_SEC then
            award(player, XP_PER_LANDING, "landing")
        end
        secondsAirborne = 0
        flightSeconds   = 0
    end

    wasAirborne = flying
end

function C172FlightXP.install()
    if C172FlightXP.installed then return true end
    if not (Events and Events.OnTick) then return false end
    C172FlightXP.installed = true
    Events.OnTick.Add(tick)
    log(("flight XP active: %d XP/min airborne, %d on landing")
        :format(XP_PER_MINUTE, XP_PER_LANDING))
    return true
end

if Events and Events.OnGameStart then Events.OnGameStart.Add(C172FlightXP.install) end

return C172FlightXP
