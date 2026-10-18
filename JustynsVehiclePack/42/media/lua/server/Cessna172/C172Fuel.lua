require "Cessna172/C172Variants"
--[[
    C172Fuel - the Cessna's own gas-tank consumption model.

    WHY THIS EXISTS, AND WHY IT IS STRUCTURAL RATHER THAN A TUNING VALUE.
    Vanilla's Vehicles.Update.GasTank computes its burn rate from two things that are
    both meaningless for this aircraft while it is flying:

      1. vehicle:getEngineSpeed() - the burn is scaled by (engineSpeed / 2500). That
         value is only ever written by CarController.update(), which the 1.8.x Java build
         skipped for the whole flight, freezing it at the top of the rev range from the
         takeoff roll. Since 1.9.0 (no Java) it moves again - but it is a CAR's gearbox and
         wheel revs, which still mean nothing in the air, so the flat model below stays.

      2. The gear/transmission-speed curve. The flight model moves the body by teleport
         plus queued impulses rather than through the wheels, so "what gear are we in and
         how close to the next shift" has no sensible value in the air either (the flight
         model pushes the body directly; the wheels are out of the physics up there).

    Rather than fight either of those, this aircraft gets its own update function, pointed
    at by its own vehicle script, and vanilla's is left completely alone for every other
    vehicle in the game.

    THE MODEL: one flat, deterministic rate - a full tank lasts
    TARGET_REAL_MINUTES_PER_TANK of engine-running time. Nothing else feeds into it.
      * FRAME-RATE INDEPENDENT BY CONSTRUCTION. `elapsedMinutes` is handed to us by
        vanilla's VehicleParts.updatePart(), which derives it from
        GameTime.getWorldAgeHours() - a game-CLOCK delta, not a frame or tick count.
        Nothing here reads FPS, tick counts or render state, so 20 fps and 200 fps burn
        identically. That is also why the burn stays correct across time acceleration
        and sleeping.
      * NO JUMPS. The rate is a constant for a given tank; there is no RPM term, no speed
        term and no branch that can step the rate discontinuously mid-flight.
      * REAL-TIME CALIBRATED. elapsedMinutes is in GAME minutes, and how much real time a
        game minute is depends entirely on the world's Day Length sandbox setting. The
        rate is derived from that at call time, so "a full tank is about N real minutes of
        engine time" holds on a 15-minute day and a 12-hour day alike, instead of silently
        meaning 16x more or less flight time per server.
      * 25 REAL MINUTES PER TANK, against the MiG's 10. A 172 carries 200 litres and burns
        about 34 l/h; endurance is its whole character, where a fighter's is not.
      * MP / DEDICATED-SERVER SAFE. This runs through exactly the same path vanilla's own
        GasTank update does, which VehicleParts.update() only ever runs when
        `!GameClient.client` - i.e. the SERVER is authoritative and MP clients never run
        it at all. Clients receive the result through the same transmitPartModData() call
        vanilla uses, which is also what keeps the HUD's getRemainingFuelPercentage()
        readout live for everyone. Two clients can therefore never disagree about, or
        fight over, fuel.
      * SP SAFE. In single player the internal server runs this in-process, exactly as it
        already runs C172Server.lua next to this file.

    SCOPE: only ever reached for a vehicle whose script points its GasTank part's
    `lua { update = ... }` here, which is only vehicle_cessna172.txt. The script-name
    check below is a second, belt-and-braces guard, and it FALLS THROUGH TO VANILLA
    rather than returning, so even a mis-wired script cannot silently stop some other
    vehicle's fuel from being consumed at all.
]]
C172Fuel = C172Fuel or {}

local C172_SCRIPT = "Base.Cessna172"
local TARGET_REAL_MINUTES_PER_TANK = 25.0
local FALLBACK_MINUTES_PER_DAY = 90
local GAME_MINUTES_PER_DAY     = 24 * 60
-- Cap on how much time a single call may bill for. Sleeping or a long time-acceleration
-- can hand over an enormous elapsedMinutes in one go; without this, a parked aircraft
-- left running could drain a whole tank in one update and it would read as a bug.
local MAX_BILLABLE_GAME_MINUTES = 30
-- The most any ONE update may consume, as a fraction of tank capacity. A safety rail, not a
-- rate: normal calls are far below it, so it does not change how long a tank lasts in flight.
-- 0.05 since 10-06 (was 0.01): the game bills about one GAME minute per call, which on a day length over
-- six hours is more than 1% of a tank in steady running, so 1% under-billed long days. Bursts are the real-
-- time limit's job now; this stays only as a rail against arithmetic surprises.
local MAX_BURN_FRACTION_PER_CALL = 0.05

-- REAL-TIME RATE LIMIT (1.10.0). A multiplayer report, 2026-10-06 (dedicated server, two passengers and a
-- full trunk): "Took off at ~90%. Landed at ~70%. Was not able to start again at all. Unloaded plane, loaded
-- it again, it says no fuel. Where did the other 70% go?" The game bills a tank for ALL the game time since
-- its last update in one call (VehicleParts.updatePart: (world age - last updated) x 60 game minutes, 42.21),
-- so an aircraft coming back into range with its engine on is handed the whole time away, and the per-call
-- ceiling below still lets a run of such calls empty a tank. So each call may bill only as much GAME time as
-- really passed on the server's clock (getTimestampMs): RATE_LIMIT x, with at most MAX_GAP_GAME_MINUTES of
-- credit after a pause, so time away is never billed at once. Counted in game minutes - the day length and
-- the game speed (fast-forward, sleep) are in it - because the game bills about one game minute per call:
-- on a long day that is many real seconds apart. (The first cut counted 2 REAL seconds of credit, which
-- under-billed every call on day lengths over two hours.) Steady running is billed exactly as before.
local RATE_LIMIT = 3.0
local MAX_GAP_GAME_MINUTES = 2.0
local lastBurnAt = {}           -- vehicle id -> server ms of its last update
local noted = {}                -- vehicle id -> what was already logged this session (limited, unattended, empty)

local function gameMinutesPerRealSecond()
    local ok, mpd = pcall(function() return getGameTime():getMinutesPerDay() end)
    if not ok or type(mpd) ~= "number" or mpd ~= mpd or mpd <= 0 then mpd = FALLBACK_MINUTES_PER_DAY end
    local okS, speed = pcall(function() return getGameTime():getTrueMultiplier() end)
    if not okS or type(speed) ~= "number" or speed ~= speed or speed < 1 then speed = 1 end
    return GAME_MINUTES_PER_DAY / (mpd * 60) * speed
end

-- UNATTENDED ENGINE (1.10.1). A player report, 2026-10-07 (multiplayer): "engine state not synced across
-- server and clients. For me the plane's engine was stopped (at least it looked so). I pulled off the key
-- ... and went far from the plane. The engine still was running on the server side, so fuel just burned
-- out." The client-side cause is fixed in C172Flight (its engine-off hold no longer touches the engine in
-- multiplayer); this is the server's own net under it, whatever the cause: an engine running with nobody
-- in the pilot's seat for UNATTENDED_SEC real seconds is switched off HERE, on the server, where the engine
-- lives - BaseVehicle.onEngineStateChanged then transmits it to every client (transmitEngine). Same in
-- single player: a parked Cessna left idling stops after a minute instead of burning its tank.
local UNATTENDED_SEC = 60
local unattendedSince = {}      -- vehicle id -> server ms when its running engine was first seen with no pilot
C172Fuel.UNATTENDED_SEC = UNATTENDED_SEC

-- 1.10.4: the delay is the sandbox's EngineAutoOff (a Workshop request, 10-09: "a sandbox setting for
-- automatic engine shutdown - 0 disables the engine immediately, -1 does not disable it"). Default 60,
-- what this has done since 1.10.1. Read on every check, so the admin panel applies at once.
function C172Fuel.unattendedSec()
    local sv = SandboxVars and SandboxVars.Cessna172
    local d = sv and tonumber(sv.EngineAutoOff)
    if d == nil or d ~= d then return UNATTENDED_SEC end
    return d
end

function C172Fuel.shutOffUnattended(vehicle)
    local okId, vid = pcall(function() return vehicle:getId() end)
    if not okId or vid == nil then return false end
    local okD, driver = pcall(function() return vehicle:getDriver() end)
    if not okD or driver ~= nil then
        unattendedSince[vid] = nil
        return false
    end
    local limit = C172Fuel.unattendedSec()
    if limit < 0 then                -- -1: never switched off automatically
        unattendedSince[vid] = nil
        return false
    end
    local now = getTimestampMs()
    local since = unattendedSince[vid] or now
    unattendedSince[vid] = since
    if now - since < limit * 1000 then return false end
    unattendedSince[vid] = nil
    local okOff = pcall(function() vehicle:shutOff() end)
    print(("[Cessna172][ENGINE] aircraft %s: engine running with nobody in the pilot's seat for %.0fs - " ..
           "switched off by the server (ok=%s)"):format(tostring(vid), (now - since) / 1000, tostring(okOff)))
    return okOff
end

local function realMinutesPerGameMinute()
    local ok, mpd = pcall(function() return getGameTime():getMinutesPerDay() end)
    if not ok or type(mpd) ~= "number" or mpd ~= mpd or mpd <= 0 then
        mpd = FALLBACK_MINUTES_PER_DAY
    end
    return mpd / GAME_MINUTES_PER_DAY
end

function C172Fuel.UpdateGasTank(vehicle, part, elapsedMinutes)
    if not vehicle or not part then return end

    local okName, name = pcall(function() return vehicle:getScriptName() end)
    if not okName or not C172Variants.isName(name) then
        if Vehicles and Vehicles.Update and Vehicles.Update.GasTank then
            return Vehicles.Update.GasTank(vehicle, part, elapsedMinutes)
        end
        return
    end

    -- A VirtualVehicle - an aircraft out of everyone's range, still updated in the background
    -- (VirtualVehicleManager -> VehicleParts.updatePart, 42.21) - is no BaseVehicle: no shutOff(), most
    -- calls missing (see C172Systems). 1.10.1 (Jay's debug game stopped on it: "Object tried to call nil",
    -- shutOff on one): nothing is done for it, and nothing burned - nobody can be in an aircraft nobody is
    -- near, and once it is loaded again the unattended check below switches a running engine off.
    if not instanceof(vehicle, "BaseVehicle") then return end
    if not part:getInventoryItem() then return end
    if type(elapsedMinutes) ~= "number" or elapsedMinutes ~= elapsedMinutes then return end
    if elapsedMinutes <= 0 then return end

    local okRun, running = pcall(function() return vehicle:isEngineRunning() end)
    if not okRun or running ~= true then
        local okV, v = pcall(function() return vehicle:getId() end)
        if okV and v ~= nil then unattendedSince[v] = nil end
        return
    end
    if C172Fuel.shutOffUnattended(vehicle) then return end

    local amount = part:getContainerContentAmount()
    if type(amount) ~= "number" or amount <= 0 then return end
    local capacity = part:getContainerCapacity()
    if type(capacity) ~= "number" or capacity <= 0 then return end

    local amountOld = amount
    local billable  = math.min(elapsedMinutes, MAX_BILLABLE_GAME_MINUTES)
    local realMins  = billable * realMinutesPerGameMinute()
    local burned    = capacity * (realMins / TARGET_REAL_MINUTES_PER_TANK)

    -- Respect the sandbox fuel-consumption slider, exactly as vanilla does.
    local mult = SandboxVars and SandboxVars.CarGasConsumption
    if type(mult) == "number" and mult > 0 then burned = burned * mult end
    if burned ~= burned or burned <= 0 then return end

    -- the real-time rate limit (see RATE_LIMIT at the top)
    local okId, vid = pcall(function() return vehicle:getId() end)
    local nowMs = getTimestampMs()
    if okId and vid ~= nil then
        local last = lastBurnAt[vid]
        lastBurnAt[vid] = nowMs
        if not last then return end                   -- the first update only starts the clock
        local credit = math.min(MAX_GAP_GAME_MINUTES, math.max(0, nowMs - last) / 1000 * gameMinutesPerRealSecond())
        local allowedMinutes = RATE_LIMIT * credit
        if billable > allowedMinutes then
            local allowed = burned * allowedMinutes / billable
            -- logged only for a real burst (half a percent or more held back), not a tick's rounding
            if burned - allowed > capacity * 0.005 and not (noted[vid] and noted[vid].limited) then
                noted[vid] = noted[vid] or {}
                noted[vid].limited = true
                print(("[Cessna172][FUEL] aircraft %s: an update tried to burn %.2f%% of the tank for %.1f game-min " ..
                       "(%.2f real s since the last); held to %.3f%%. Reported once per aircraft per session.")
                    :format(tostring(vid), 100 * burned / capacity, elapsedMinutes, (nowMs - last) / 1000,
                            100 * allowed / capacity))
            end
            burned = allowed
        end
        if burned <= 0 then return end
        -- running with nobody in the pilot's seat: legal (as a car left running), but logged once, so a
        -- tank found empty later can be explained from the server's console
        local okD, driver = pcall(function() return vehicle:getDriver() end)
        if okD and driver == nil and not (noted[vid] and noted[vid].unattended) then
            noted[vid] = noted[vid] or {}
            noted[vid].unattended = true
            print(("[Cessna172][FUEL] aircraft %s: engine running with nobody in the pilot's seat, fuel %.0f%% - " ..
                   "it keeps burning until shut off (logged once)"):format(tostring(vid), 100 * amount / capacity))
        end
    end

    -- HARD CEILING ON A SINGLE CALL.
    --
    -- MAX_BILLABLE_GAME_MINUTES caps the elapsed TIME, but not the fuel that time converts to:
    -- the burn is scaled by real-minutes-per-game-minute, which follows the sandbox day length,
    -- so on a long day length one call can legitimately compute a large fraction of the tank.
    -- After a period with the vehicle unloaded the engine can also be handed a very large
    -- elapsed value, and several catch-up calls in a row can then empty a tank between one
    -- session and the next - which is exactly the "spawned in and the fuel was zero" report.
    --
    -- No single update should ever cost more than a sliver, whatever the arithmetic says. The
    -- long-run rate is unaffected in normal play because a normal call is far below this.
    local ceiling = capacity * MAX_BURN_FRACTION_PER_CALL
    if burned > ceiling then
        if not C172Fuel.reportedClamp then
            C172Fuel.reportedClamp = true
            print(("[Cessna172][FUEL] a single update tried to burn %.1f%% of the tank " ..
                   "(elapsed %.1f game-min, day length gives %.4f real-min per game-min); " ..
                   "clamped to %.1f%%. Reported once.")
                :format(100 * burned / capacity, elapsedMinutes,
                        realMinutesPerGameMinute(), 100 * MAX_BURN_FRACTION_PER_CALL))
        end
        burned = ceiling
    end

    amount = amount - burned

    -- Vanilla's own damaged-tank leak, kept verbatim so a shot-up tank still behaves the
    -- way a player expects from every other vehicle.
    if part:getCondition() < 70 then
        if ZombRand(part:getCondition() * 2) == 0 then
            amount = amount - 0.01
        end
    end

    part:setContainerContentAmount(amount, false, true)
    amount = part:getContainerContentAmount()
    if amount <= 0 and okId and vid ~= nil and not (noted[vid] and noted[vid].empty) then
        noted[vid] = noted[vid] or {}
        noted[vid].empty = true
        local okD, driver = pcall(function() return vehicle:getDriver() end)
        print(("[Cessna172][FUEL] aircraft %s: tank ran dry (pilot aboard: %s, consumption x%s)")
            :format(tostring(vid), tostring(okD and driver ~= nil), tostring(mult or 1)))
    end

    local precision = (amount < 0.5) and 2 or 1
    if VehicleUtils.compareFloats(amountOld, amount, precision) then
        vehicle:transmitPartModData(part)
    end
end

return C172Fuel
