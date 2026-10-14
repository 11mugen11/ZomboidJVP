require "emre_re9_bikes"
-- RE9 grounded parking assist. A local keyboard driver's actual input wakes
-- the body BEFORE native throttle is computed, including zero-power/idle bikes.
-- Never suspend a moving/falling bike or another client's physics body.
EmreRE9 = EmreRE9 or {}
if EmreRE9.Settling then return EmreRE9.Settling end
local S = {}
EmreRE9.Settling = S
local states = setmetatable({}, {__mode="k"})
local held = setmetatable({}, {__mode="k"})
local lastScan = 0
local warned = false
local velocity
local SCAN_MS, QUIET_MS, MIN_SAMPLES, MAX_GAP_MS = 250, 750, 4, 1000
-- getZ() is in world floor units; velocity:y() is the physics vertical axis.
local MAX_Z_SPAN = 0.01
local MAX_VERTICAL = 0.15

local function debugLog(message)
    if isDebugEnabled and isDebugEnabled() then
        print("[EmreRE9 0.2.15] " .. message)
    end
end

function S.HasDriveInput(vehicle)
    local driver = vehicle:getDriver()
    if driver and driver:isLocalPlayer() and vehicle:isKeyboardControlled()
        and vehicle:getJoypad() == -1 and getCore and isKeyDown then
        local core = getCore()
        for _, key in ipairs({"Forward", "Backward", "Left", "Right"}) do
            if isKeyDown(core:getKey(key)) then return true, true end
        end
        -- getThrottle() may still be positive after the key is released.
        -- It is an output of the native controller, not current user intent.
        return false, true
    end
    return math.abs(vehicle:getThrottle()) > 0.01, false
end

local function canControl(vehicle)
    local script = vehicle and vehicle:getScript()
    if not script or not EmreRE9.Bikes.IsNormal(script:getFullName()) then return false end
    local engine = vehicle:getPartById("Engine")
    if engine and engine:getModData().emreRE9Carrier then return false end
    if not isClient() then return true end
    local driver = vehicle:getDriver()
    return driver and driver:isLocalPlayer() and vehicle:isLocalPhysicSim()
end

function S.Wake(vehicle)
    if not canControl(vehicle) then return end
    local state = states[vehicle]
    held[vehicle] = nil
    -- Native physics may have slept the body since our last release, or a
    -- loaded vehicle may have no entry in this session's weak state table.
    -- Inspect the real body instead of treating our cached flag as authority.
    if not vehicle:isPhysicsActive() then vehicle:setPhysicsActive(true) end
    if state then
        if state.asleep then
            debugLog("idle hold released")
        end
        state.asleep = false
        state.quietSince = nil
        state.samples = 0
    end
end

function S.ReleaseExit(vehicle)
    if not canControl(vehicle) then return end
    states[vehicle] = states[vehicle] or {asleep=false, samples=0}
    states[vehicle].exitUntil = nil
    states[vehicle].awakeUntil = getTimestampMs() + 1000
    S.Wake(vehicle)
end

function S.IsHeld(vehicle) return held[vehicle] == true end

function S.FinishExit(vehicle)
    -- The character has already left. Keep a supported, settled bike parked
    -- instead of waking it for another rollback as the dismount completes.
    if not canControl(vehicle) then held[vehicle], states[vehicle] = nil, nil; return end
    if states[vehicle] then states[vehicle].exitUntil = nil end
end

function S.DriverUpdate(vehicle, character)
    if not canControl(vehicle) or vehicle:getDriver() ~= character then return end
    return S.UpdateVehicle(vehicle, getTimestampMs())
end

local function realTiresPresent(vehicle)
    for _, id in ipairs({"TireFrontLeft", "TireRearRight"}) do
        local part = vehicle:getPartById(id)
        if not part or not part:getInventoryItem() then return false end
    end
    return true
end

local function describe(state, speed, planar, vertical, up, z, floor)
    local span = state.minZ and state.maxZ - state.minZ or 0
    return "speed=" .. tostring(speed) .. " planar=" .. tostring(planar)
        .. " vertical=" .. tostring(vertical) .. " up=" .. tostring(up)
        .. " z=" .. tostring(z) .. " floor=" .. tostring(floor)
        .. " zSpan=" .. tostring(span) .. " samples=" .. tostring(state.samples or 0)
end

local function startWindow(state, now, z, floor)
    state.quietSince, state.lastSample = now, now
    state.minZ, state.maxZ, state.floor = z, z, floor
    state.samples = 1
end

function S.UpdateVehicle(vehicle, now, exitRequested)
    local script = vehicle and vehicle:getScript()
    if not script or not EmreRE9.Bikes.IsNormal(script:getFullName()) then return false, "other vehicle" end
    local engine = vehicle:getPartById("Engine")
    if engine and engine:getModData().emreRE9Carrier then
        held[vehicle], states[vehicle] = nil, nil
        return false, "rear carrier owns this body"
    end
    local driver = vehicle:getDriver()
    -- Never write to another client's or the server's vehicle from a client.
    if isClient() and (not driver or not driver:isLocalPlayer() or not vehicle:isLocalPhysicSim()) then
        held[vehicle], states[vehicle] = nil, nil
        return false, "no local physics authority"
    end
    if vehicle:getVehicleTowing() or vehicle:getVehicleTowedBy() or not realTiresPresent(vehicle) then
        S.Wake(vehicle)
        return false, "towing or missing tire"
    end
    local input, observed = S.HasDriveInput(vehicle)
    if input then
        S.ReleaseExit(vehicle)
        return false, "drive input"
    end
    local state = states[vehicle]
    if not state then
        state = {asleep=false, samples=0}
        states[vehicle] = state
    end
    -- Automatic occupied parking is safe only with independently observed
    -- input. Unknown/controller input retains the previous awake policy.
    -- Native starting states and explicit ignition requests stay awake.
    local leaving = state.exitUntil and now < state.exitUntil
    if driver and not exitRequested and not leaving
        and (not observed or (state.awakeUntil and now < state.awakeUntil)
            or vehicle:isEngineStarted()) then
        S.Wake(vehicle)
        return false, "unobserved input, ignition or wake grace"
    end
    velocity = velocity or Vector3f.new()
    vehicle:getLinearVelocity(velocity)
    local speed, planar = vehicle:getCurrentSpeedKmHour(), vehicle:getSpeed2D()
    local vertical, up, z = velocity:y(), vehicle:getUpVectorDot(), vehicle:getZ()
    local square = vehicle:getSquare()
    local floor = square and square:getZ()
    local support = square and square:TreatAsSolidFloor()
        and z >= floor - 0.05 and z <= floor + 0.35
    -- The supplied 11:00 log records ~+0.100 m/s vertically on a level road.
    -- Permit that residual sample, but require a supported, stable HEIGHT over
    -- several observations. Never freeze from one low vertical-speed sample.
    local eligible = math.abs(speed) < 1.0 and planar < 0.30
        and math.abs(vertical) < MAX_VERTICAL and up > 0.98 and support
    if not eligible then
        S.Wake(vehicle)
        if exitRequested or (math.abs(speed) < 1.0
            and (not state.nextDiagnostic or now >= state.nextDiagnostic)) then
            state.nextDiagnostic = now + 5000
            debugLog("idle hold deferred: " .. describe(state, speed, planar, vertical, up, z, floor))
        end
        return false, "motion, tilt or floor"
    end

    if state.asleep then
        -- Floor removal, loading onto a ramp or a vertical impact must release
        -- parking even if the cached velocity sample is momentarily small.
        if floor ~= state.floor or math.abs(z - state.heldZ) > MAX_Z_SPAN then
            S.Wake(vehicle)
            return false, "height changed"
        end
        -- Native engine/part updates can wake the body. Maintain an existing
        -- hold every tick, not only at the 250 ms discovery interval.
        if vehicle:isPhysicsActive() then vehicle:setPhysicsActive(false) end
        if speed ~= 0 then vehicle:setSpeedKmHour(0) end
        if not state.driftReported then
            local dx, dy = vehicle:getX() - state.heldX, vehicle:getY() - state.heldY
            if dx*dx + dy*dy > 0.04*0.04 then
                state.driftReported = true
                debugLog("idle hold residual displacement: dx=" .. tostring(dx)
                    .. " dy=" .. tostring(dy) .. " physicsActive=" .. tostring(vehicle:isPhysicsActive()))
            end
        end
        return true, "already held"
    end

    if not state.quietSince or now < state.lastSample
        or now - state.lastSample > MAX_GAP_MS or floor ~= state.floor then
        startWindow(state, now, z, floor)
    else
        state.minZ, state.maxZ = math.min(state.minZ, z), math.max(state.maxZ, z)
        if state.maxZ - state.minZ > MAX_Z_SPAN then
            startWindow(state, now, z, floor)
        elseif now - state.lastSample >= SCAN_MS then
            state.lastSample = now
            state.samples = state.samples + 1
        end
    end
    if now - state.quietSince < QUIET_MS or state.samples < MIN_SAMPLES then
        if exitRequested then
            debugLog("exit settling waiting: " .. describe(state, speed, planar, vertical, up, z, floor))
        end
        return false, "observing stable height"
    end

    vehicle:setPhysicsActive(false)
    state.asleep = true
    held[vehicle] = true
    state.heldX, state.heldY, state.heldZ = vehicle:getX(), vehicle:getY(), z
    state.driftReported = false
    -- Clear stale speed only AFTER suspending the physical body. The native
    -- dismount check must not read the previous rollback sample.
    vehicle:setSpeedKmHour(0)
    debugLog("idle hold engaged: " .. describe(state, speed, planar, vertical, up, z, floor)
        .. " physicsActive=" .. tostring(vehicle:isPhysicsActive()))
    return true, "grounded hold"
end

function S.PrepareExit(vehicle)
    if not canControl(vehicle) then return false end
    states[vehicle] = states[vehicle] or {asleep=false, samples=0}
    states[vehicle].exitUntil = getTimestampMs() + 6000
    local ok, parked, reason = pcall(S.UpdateVehicle, vehicle, getTimestampMs(), true)
    if not ok then
        print("[EmreRE9 0.2.15] exit settling unavailable: " .. tostring(parked))
        return false
    end
    debugLog("exit settling: held=" .. tostring(parked) .. " reason=" .. tostring(reason))
    return parked
end

local function updateProtected(vehicle, now)
    local ok, err = pcall(S.UpdateVehicle, vehicle, now)
    if not ok then
        -- Stop maintaining a failed hold and attempt to release only a body
        -- whose physics this module previously suspended with local authority.
        local state = states[vehicle]
        if state and state.asleep then
            pcall(function()
                local driver = vehicle:getDriver()
                if not isClient() or (driver and driver:isLocalPlayer() and vehicle:isLocalPhysicSim()) then
                    S.Wake(vehicle)
                end
            end)
        end
        held[vehicle], states[vehicle] = nil, nil
        if not warned then
            warned = true
            print("[EmreRE9 0.2.15] settling unavailable: " .. tostring(err))
        end
    end
end

local function scan()
    local now = getTimestampMs()
    for vehicle in pairs(held) do updateProtected(vehicle, now) end
    if now - lastScan < SCAN_MS then return end
    lastScan = now
    local cell = getCell()
    local vehicles = cell and cell:getVehicles()
    if not vehicles then return end
    -- B42 IsoCell.getVehicles() returns a Set, not an indexed List.
    local iterator = vehicles:iterator()
    while iterator:hasNext() do
        local vehicle = iterator:next()
        if not held[vehicle] then updateProtected(vehicle, now) end
    end
end

Events.OnTick.Add(scan)
Events.OnEnterVehicle.Add(function(character)
    -- Release before waiting for engine RPM/throttle, including hotwired bikes.
    local vehicle = character and character:getVehicle()
    if vehicle then S.ReleaseExit(vehicle) end
end)
return S
