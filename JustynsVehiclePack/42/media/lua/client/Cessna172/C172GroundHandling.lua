require "Cessna172/C172Phys"
local P = C172Phys
local G = {}
C172GroundHandling = G
local held = setmetatable({}, { __mode = "k" })

function G.beginRollout(v, st)
    local vx, _, vz = P.velocity(v)
    local speed = math.sqrt(vx * vx + vz * vz)
    st.rollout = speed > .5 and { speed = speed, elapsed = 0 } or nil
end

-- A bounded coast assist replaces vanilla's abrupt no-throttle automobile
-- braking during the landing roll. Pedal/brake input immediately takes over.
function G.rollout(v, st, dt, throttle, brake)
    local roll = st.rollout
    if not roll then return false end
    roll.elapsed = roll.elapsed + dt
    local vx, _, vz = P.velocity(v)
    local speed = math.sqrt(vx * vx + vz * vz)
    if throttle or brake or roll.elapsed > 40 or roll.speed < .4
       or (roll.elapsed > .5 and speed < roll.speed * .35) then
        st.rollout = nil
        return false
    end
    roll.speed = math.max(0, roll.speed - .65 * dt)
    if speed > .1 and speed < roll.speed then
        local mass = v:getMass()
        P.c172DriveHorizontal(v, vx / speed * roll.speed, vz / speed * roll.speed,
                             mass, mass * .35, dt * 60, 0, dt, mass)
    end
    return true
end

-- Acquire only at rest. Once acquired, latch until an explicit engine,
-- towing, flying, or authority change; solver jitter must not release the hold.
local function owns(v)
    if not isClient() then return true end
    local player = getSpecificPlayer(0)
    return player ~= nil and v:getNetPlayerId() == player:getOnlineID()
end
local function freeze(v)
    -- A native/controller wake can leave its cached enable flag stale. Toggle
    -- atomically before the next simulation step so the native static state is
    -- reasserted even when setPhysicsActive(false) would otherwise early-return.
    v:setPhysicsActive(true)
    v:setPhysicsActive(false)
    v:setSpeedKmHour(0)
end
local function releaseWanted(v)
    return v:isEngineRunning() or v:getVehicleTowedBy() or v:getVehicleTowing() or P.isFlying(v)
end
function G.parking(v)
    if v:getScriptName() ~= P.SCRIPT then return end
    if not owns(v) then held[v] = nil; return end
    if held[v] then
        if releaseWanted(v) then v:setPhysicsActive(true); held[v] = nil
        else freeze(v) end
        return
    end
    if v:isEngineRunning() and not v:isPhysicsActive() then v:setPhysicsActive(true) end
    if releaseWanted(v) then return end
    local h = P.c172GetBodyHeight(v)
    local ground = P.c172SurfaceHeightBelow(v)
    local _, vy = P.velocity(v)
    if h ~= nil and h - ground < 1.9 and h - ground > -.1
       and math.abs(vy) < .5 and math.abs(v:getCurrentSpeedKmHour()) < 1 then
        freeze(v); held[v] = true
    end
end
function G.enforceParking()
    for v in pairs(held) do
        if not owns(v) or (v.isRemovedFromWorld and v:isRemovedFromWorld()) then held[v] = nil
        elseif releaseWanted(v) then v:setPhysicsActive(true); held[v] = nil
        else freeze(v) end
    end
end
if Events and Events.OnRenderTick then Events.OnRenderTick.Add(G.enforceParking) end

function G.isParked(v) return held[v] == true end
return G
