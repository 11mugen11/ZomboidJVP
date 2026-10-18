require "Cessna172/C172Phys"
require "Cessna172/C172Parking"
local P = C172Phys
local G = {}
C172GroundHandling = G

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

-- Parking is shared with the server and remote clients, so an unattended
-- plane keeps its saved anchor through native ownership changes.
function G.parking(v) C172Parking.update(v) end
function G.enforceParking() C172Parking.tick() end
function G.isParked(v) return C172Parking.isParked(v) end
return G
