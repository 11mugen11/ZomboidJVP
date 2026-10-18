require "Cessna172/C172Variants"
--[[
    C172Phys - the Cessna's own physics access, in Lua (1.9.0).

    ===================================================================================
    WHAT THIS REPLACES
    ===================================================================================
    Up to 1.8.1 the flight controller (C172Flight.lua) reached the physics engine through
    Cessna172.jar - Java loaded by ZombieBuddy - via c172-prefixed globals. 1.9.0 has NO JAVA:
    every one of those jobs is done here with calls the game already gives Lua, so the mod
    works with ZombieBuddy on, off or not installed. The functions keep their old c172* names
    (as fields of this table, NOT globals) so every caller changed by one lookup only.

    HOW LUA MOVES THE AIRCRAFT (read from the 42.21 jar, flown on the MH-92 Nightfang):
      BaseVehicle.applyImpulseGeneric(x, y, z, dirX, dirY, dirZ, size) queues a push at a
      world point. Before the next physics step the engine adds the queue up and hands the
      physics library  force = sum x 30  and  torque = sum(arm x push) x 30  for ONE 0.01 s
      substep. A push at the centre has no arm and only moves the body; pushes either side
      of it turn it. This is the SAME channel the Java build's lift and drive already used,
      so those two are line-for-line ports. The orientation is the one real change:

    TURNING NO LONGER TELEPORTS. Java turned the aircraft by rewriting its rotation
    (Bullet.teleportVehicle) up to 60 times a second, which zeroed its velocity every time and
    had to put the speed back afterwards - the root of "turning kills speed", the takeoff
    flips (an over-sized restore) and the flicker in turns. Here a TORQUE turns the body
    toward the heading, bank and pitch the flight model asks for, like a real aeroplane, so
    nothing is ever thrown away and there is nothing to restore. The same hold keeps the
    airframe from wandering when the pilot lets go (the old "auto-straightening" teleports).

    Engine facts used below, measured on the game's own physics library (libPZBullet
    1.0.0.28, tools/tests): gravity is exactly 10, no linear or angular damping, height =
    getWorldPos(0,0,0):z() x 2.44949, heading = atan2(forward.x, forward.z), and a RIGHT turn
    is a FALLING heading.

    NOTHING HERE TOUCHES ANOTHER VEHICLE. Every entry point is handed a vehicle the caller
    has already confirmed is Base.Cessna172, and the two script-level changes (the ground
    footprint and the propeller part) are made to this aircraft's script only.
]]

C172Phys = C172Phys or {}
local P = C172Phys

P.SCRIPT = "Base.Cessna172"
local Z_M  = 2.44949     -- metres (Bullet height units) per tile level
local STEP = 0.01        -- one physics substep
local GAIN = 30          -- the engine multiplies the queued impulse sum by this

local sqrt, abs, floor, max, min = math.sqrt, math.abs, math.floor, math.max, math.min
local sin, cos, acos, deg = math.sin, math.cos, math.acos, math.deg
-- Kahlua has math.atan2; desktop Lua 5.3+ (the test harness) has only two-argument atan.
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
P.atan2 = atan2

local function num(x, fallback)
    if type(x) ~= "number" then x = tonumber(tostring(x)) end
    if not x or x ~= x or x == math.huge or x == -math.huge then return fallback end
    return x
end
P.num = num

local function clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

-- One scratch vector for every read; nothing below holds it across a call.
local scratch = nil
local function vec()
    if not scratch then scratch = Vector3f.new() end
    return scratch
end

-- ---------------------------------------------------------------- attitude tuning
-- Per-axis spring and damper on the airframe's rotation, as an ANGULAR ACCELERATION, then
-- times the body's measured rotational inertia - so these numbers are the same however heavy
-- the aircraft is loaded. Critically damped (KD = 2 x sqrt(KP)): it settles on the heading
-- without overshooting, so a turn rolls out clean instead of wagging. The yaw limit leaves
-- room for the fastest turn entry the flight model can ask for (55 deg/s eased in at
-- TURN_SMOOTH 9/s = 8.6 rad/s^2).
P.ATT = {
    KP            = 12.0,   -- 1/s^2  angle error -> angular acceleration
    KD            = 7.0,    -- 1/s    rate error  -> angular acceleration
    ACCEL_MAX     = 6.0,    -- rad/s^2, pitch and roll
    YAW_ACCEL_MAX = 10.0,   -- rad/s^2
    SAMPLE        = 0.04,   -- s; turn rates are measured over at least this much time
    -- Rotational inertia per kg about the body's side / up / nose axes. The physics library
    -- takes the collision box's bounding box (physicsChassisShape 0.85 x 0.70 x 1.50 x the
    -- 1.75 model scale = 1.4875 x 1.225 x 2.625 m): I = m/12 (a^2 + b^2). MEASURED with this
    -- script on the real library (tools/tests/native_engine_facts.lua).
    INERTIA       = { 0.280218816, 0.500718816, 0.31053744 },
}

-- ---------------------------------------------------------------- per-vehicle samples
local bodies = {}          -- vehicle id -> { quaternion + time of the last turn sample, rates }
P._bodies = bodies

local function body(v)
    local id = v:getId()
    local b = bodies[id]
    if not b then
        b = { wx = 0, wy = 0, wz = 0 }
        bodies[id] = b
    end
    return b
end

-- Forget the samples for one aircraft (it was put back on its wheels, or it left).
function P.forget(v)
    local ok, id = pcall(function() return v:getId() end)
    if ok and id then bodies[id] = nil end
end

-- ---------------------------------------------------------------- quaternions
-- w, x, y, z as plain values (nothing allocated per tick). Bullet axes: x, y = up, z. The
-- aircraft's own axes in that frame: +x its LEFT side, +y up, +z its nose.
local function qnorm(w, x, y, z)
    local l = sqrt(w * w + x * x + y * y + z * z)
    if l < 1e-6 then return 1, 0, 0, 0 end
    return w / l, x / l, y / l, z / l
end

local function qmul(aw, ax, ay, az, bw, bx, by, bz)
    return aw * bw - ax * bx - ay * by - az * bz,
           aw * bx + ax * bw + ay * bz - az * by,
           aw * by - ax * bz + ay * bw + az * bx,
           aw * bz + ax * by - ay * bx + az * bw
end

local function qrot(w, x, y, z, vx, vy, vz)
    local tx = 2 * (y * vz - z * vy)
    local ty = 2 * (z * vx - x * vz)
    local tz = 2 * (x * vy - y * vx)
    return vx + w * tx + y * tz - z * ty,
           vy + w * ty + z * tx - x * tz,
           vz + w * tz + x * ty - y * tx
end

-- Heading about up, then pitch about the body's left axis (positive = nose DOWN), then roll
-- about the nose (positive = RIGHT wing down).
local function fromYawPitchRoll(yaw, pitch, roll)
    local cy, sy = cos(yaw / 2), sin(yaw / 2)
    local cp, sp = cos(pitch / 2), sin(pitch / 2)
    local cr, sr = cos(roll / 2), sin(roll / 2)
    return cy * cp * cr + sy * sp * sr,
           cy * sp * cr + sy * cp * sr,
           sy * cp * cr - cy * sp * sr,
           cy * cp * sr - sy * sp * cr
end
P._fromYawPitchRoll = fromYawPitchRoll

-- From the engine's forward and up vectors (unit length, at right angles).
local function fromBasis(fx, fy, fz, ux, uy, uz)
    local lx, ly, lz = uy * fz - uz * fy, uz * fx - ux * fz, ux * fy - uy * fx
    local trace = lx + uy + fz
    local w, x, y, z
    if trace > 0 then
        local s = sqrt(trace + 1) * 2
        w, x, y, z = s / 4, (uz - fy) / s, (fx - lz) / s, (ly - ux) / s
    elseif lx > uy and lx > fz then
        local s = sqrt(1 + lx - uy - fz) * 2
        w, x, y, z = (uz - fy) / s, s / 4, (ux + ly) / s, (fx + lz) / s
    elseif uy > fz then
        local s = sqrt(1 + uy - lx - fz) * 2
        w, x, y, z = (fx - lz) / s, (ux + ly) / s, s / 4, (fy + uz) / s
    else
        local s = sqrt(1 + fz - lx - uy) * 2
        w, x, y, z = (ly - ux) / s, (fx + lz) / s, (fy + uz) / s, s / 4
    end
    return qnorm(w, x, y, z)
end

-- The rotation as axis x angle (radians), the short way round.
local function rotationVector(w, x, y, z)
    local sign = (w < 0) and -1 or 1
    local l = sqrt(x * x + y * y + z * z)
    local k = 2
    if l > 1e-5 then k = 2 * atan2(l, abs(w)) / l end
    k = k * sign
    return k * x, k * y, k * z
end

-- ---------------------------------------------------------------- reads
function P.c172PhysicsAvailable()
    return Vector3f ~= nil
end

-- The nose, in world x / y (tiles east / south) and up.
function P.forward(v)
    local out = v:getForwardVector(vec())
    return num(out:x(), 0), num(out:z(), 0), num(out:y(), 0)
end
function P.c172ForwardX(v) local x = P.forward(v); return x end
function P.c172ForwardY(v) local _, y = P.forward(v); return y end

-- Body origin height, metres above level 0 (the physics library's own up axis).
function P.c172GetBodyHeight(v)
    local ok, h = pcall(function() return v:getWorldPos(0, 0, 0, vec()):z() end)
    h = ok and num(h) or nil
    if not h then return nil end
    return h * Z_M
end

-- Total tilt off level (pitch and roll together), degrees.
function P.c172BodyTiltDeg(v)
    local ok, uy = pcall(function() return v:getUpVector(vec()):y() end)
    uy = ok and num(uy) or nil
    if not uy then return nil end
    return deg(acos(clamp(uy, -1, 1)))
end

-- Body velocity, m/s: world x (east), up, world y (south). The engine's own reading of the
-- physics body, refreshed every frame.
local lastVelX, lastVelY = 0, 0
function P.velocity(v)
    local ok, out = pcall(function() return v:getLinearVelocity(vec()) end)
    if not (ok and out) then return lastVelX, 0, lastVelY end
    local vx, vy, vz = num(out:x(), 0), num(out:y(), 0), num(out:z(), 0)
    lastVelX, lastVelY = vx, vz
    return vx, vy, vz
end
-- Horizontal velocity. With a vehicle, read fresh; without one, the last reading (the Java
-- bridge's behaviour).
function P.c172GetVelX(v) if v then local x = P.velocity(v); return x end return lastVelX end
function P.c172GetVelY(v) if v then local _, _, y = P.velocity(v); return y end return lastVelY end

-- The suspension rest length as the engine runs it (the script's value times the model scale).
function P.c172GetRestLength(v)
    local ok, r = pcall(function() return v:getScript():getSuspensionRestLength() end)
    r = ok and num(r) or nil
    if r and r > 0 then return r end
    return 0.08
end

-- Vanilla's own parked height for this aircraft on a storey, from the script (CarController's
-- spawn arithmetic): level x 2.44949 - min(wheel bottom, chassis bottom).
-- The airframe's real footprint (width, height, length in metres, the script's numbers times
-- the model scale). Read from the script while it is not shrunk for flight (C172Contacts),
-- else these - so a session that ended mid-flight can never feed back a negative one.
P.FULL_EXTENTS = { 1.785, 1.155, 3.15 }
P.WHEEL_RADIUS = 0.16831600           -- wheel 0 in vehicle_cessna172.txt, before the model scale
function P.fullExtents()
    if P.Contacts and P.Contacts.full then return P.Contacts.full end
    return P.FULL_EXTENTS
end

-- The visible tire profile defines the recovery pose, rather than a single
-- suspension connection point. The suspension rays are calibrated separately.
P.PARK_PITCH_DEG = 12.94
function P.restingHeight(v, level)
    local scale = num(v:getScript():getModelScale(), 2.1)
    local a = math.rad(P.PARK_PITCH_DEG)
    local density = 3.1922 / 11
    local main = (1.35 * cos(a) - .12 * sin(a) + .58 * .995) * density * scale
    local tail = (.55 * cos(a) + 5.05 * sin(a) + .20 * .995) * density * scale
    return floor(level or 0) * Z_M + max(main, tail) + .015
end

-- ---------------------------------------------------------------- the push channel
-- One queued push, world force (fx east, fup, fz south) at world tile point (px, py), the
-- vehicle's own level. `scale` turns the force into the queued size.
local function push(v, px, py, pz, fx, fup, fz, scale)
    local size = sqrt(fx * fx + fup * fup + fz * fz)
    if size > 1e-4 and size == size then
        -- argument order is the engine's: point x, y, z, then direction x, y (world Y), z (up)
        v:applyImpulseGeneric(px, py, pz, fx / size, fz / size, fup / size, size * scale)
    end
end

-- Queue a push of `size` (the engine's own impulse units: x30 for one 0.01 s substep) at the
-- body's centre along world (dx east, dy south, dup up). No arm, so it moves and never turns.
local function central(v, dx, dy, dup, size)
    if not (size and size > 1e-4 and size == size) then return end
    v:applyImpulseGeneric(v:getX(), v:getY(), v:getZ(), dx, dy, dup, size)
end

-- ---------------------------------------------------------------- horizontal drive
-- PORT OF C172Physics.driveHorizontal, plus two things the old one could not do.
--   force = (target - velocity) x gain, each axis clamped to maxForce, queued at the centre.
--   frameScale: the push lands on one substep per frame, so its effect scaled with the frame
--     rate; the caller passes (frame physics time x 60), which keeps 60 fps exactly as tuned
--     and makes every other frame rate converge in the same time.
--   yawRate (rad/s, the commanded turn) + dt + mass: TURN CARRY. The velocity is swung round
--     with the nose at the rate the pilot is turning - the centripetal push a banked wing
--     gives a real aeroplane - so a turn keeps its speed and does not skid wide. With
--     teleport turns Java did this by rotating the momentum by hand; here it is a force.
function P.c172DriveHorizontal(v, tvx, tvy, gain, maxForce, frameScale, yawRate, dt, mass)
    tvx, tvy, gain, maxForce = num(tvx), num(tvy), num(gain), num(maxForce)
    if not (tvx and tvy and gain and maxForce) then return false end
    v:setPhysicsActive(true)                       -- a body at rest is asleep; wake it
    local vx, _, vy = P.velocity(v)
    local fx = clamp((tvx - vx) * gain, -maxForce, maxForce)
    local fy = clamp((tvy - vy) * gain, -maxForce, maxForce)
    local fs = num(frameScale, 1)
    fx, fy = fx * fs, fy * fs
    local w = num(yawRate, 0)
    dt, mass = num(dt, 0), num(mass, 0)
    if w ~= 0 and dt > 0 and mass > 0 then
        -- d/dt of (sin h, cos h) x speed = w x (vy, -vx); as a queued size: a x dt x m / 0.3
        local k = w * dt * mass / (GAIN * STEP)
        fx = fx + k * vy
        fy = fy - k * vx
    end
    central(v, fx, fy, 0, sqrt(fx * fx + fy * fy))
    return true
end

-- ---------------------------------------------------------------- vertical lift
-- PORT OF C172Physics.liftBody, unchanged in every number:
--   accel = gravity + kp x err - kd x vertical speed, err clamped to (-errDown, +errUp)
--   force = mass x accel, clamped; queued as force / 30 straight up (or down).
-- The caller already scales gravity and maxForce by the frame's physics time (the 1.8.0
-- frame-rate fix), so this is exactly the Java body.
P.last = { h = 0, vy = 0, force = 0 }
function P.c172LiftBody(v, targetHeight, kp, kd, gravity, mass, maxForce, errUp, errDown)
    targetHeight, kp, kd = num(targetHeight), num(kp), num(kd)
    gravity, mass, maxForce = num(gravity), num(mass), num(maxForce)
    if not (targetHeight and kp and kd and gravity and mass and maxForce) then return false end
    local h = P.c172GetBodyHeight(v)
    if not h then return false end
    local _, vy = P.velocity(v)
    local okM, real = pcall(function() return v:getMass() end)
    real = okM and num(real) or nil
    if real and real > 1 then mass = real end
    local err = targetHeight - h
    errUp, errDown = num(errUp, 0), num(errDown, 0)
    if errUp > 0 and err > errUp then err = errUp end
    if errDown > 0 and err < -errDown then err = -errDown end
    local force = clamp(mass * (gravity + kp * err - kd * vy), -maxForce, maxForce)
    if force ~= force then return false end
    P.last.h, P.last.vy, P.last.force = h, vy, force
    v:setPhysicsActive(true)
    central(v, 0, 0, (force >= 0) and 1 or -1, abs(force) / GAIN)
    return true
end

-- ---------------------------------------------------------------- attitude hold
-- Measure the body's orientation and turn rate (rates from how far it turned over at least
-- ATT.SAMPLE seconds: above ~100 fps some frames run no physics step, and "did not move this
-- frame" is not "stopped").
function P.observe(v, dt)
    local b = body(v)
    local f = v:getForwardVector(vec())
    local fx, fy, fz = num(f:x(), 0), num(f:y(), 0), num(f:z(), 1)
    local u = v:getUpVector(vec())
    local ux, uy, uz = num(u:x(), 0), num(u:y(), 1), num(u:z(), 0)
    local w, x, y, z = fromBasis(fx, fy, fz, ux, uy, uz)
    b.qw, b.qx, b.qy, b.qz = w, x, y, z
    local flat = sqrt(fx * fx + fz * fz)
    if flat > 0.2 then b.heading = atan2(fx / flat, fz / flat) end
    b.upY = uy
    if not b.tw then
        b.tw, b.tx, b.ty, b.tz, b.tt = w, x, y, z, 0
        b.wx, b.wy, b.wz = 0, 0, 0
    else
        b.tt = b.tt + (dt or 0)
        if b.tt >= P.ATT.SAMPLE then
            local cw, cx, cy, cz = b.tw, -b.tx, -b.ty, -b.tz
            local dw, dx, dy, dz = qmul(w, x, y, z, cw, cx, cy, cz)
            local rx, ry, rz = rotationVector(dw, dx, dy, dz)
            b.wx, b.wy, b.wz = rx / b.tt, ry / b.tt, rz / b.tt
            b.tw, b.tx, b.ty, b.tz, b.tt = w, x, y, z, 0
        end
    end
    return b
end

-- Torque (world axes, N m) that turns the airframe toward heading / pitch (nose UP positive) /
-- bank (RIGHT wing down positive), with the commanded yaw rate as the rate to match.
-- authority 0..1 scales it (0 on the ground: the wheels own the attitude there).
function P.attitudeTorque(b, heading, pitchUp, bankRight, yawRate, authority, mass)
    local A = P.ATT
    local dw, dx, dy, dz = fromYawPitchRoll(heading, -pitchUp, bankRight)
    local cw, cx, cy, cz = b.qw, -b.qx, -b.qy, -b.qz
    -- what is left to turn, and the turn rates, all in the body's own axes
    local ex, ey, ez = rotationVector(qmul(cw, cx, cy, cz, dw, dx, dy, dz))
    local wx, wy, wz = qrot(cw, cx, cy, cz, b.wx, b.wy, b.wz)
    local rx, ry, rz = qrot(cw, cx, cy, cz, 0, yawRate or 0, 0)
    local lim, ylim = A.ACCEL_MAX, A.YAW_ACCEL_MAX
    local ax = clamp(A.KP * ex + A.KD * (rx - wx), -lim, lim)
    local ay = clamp(A.KP * ey + A.KD * (ry - wy), -ylim, ylim)
    local az = clamp(A.KP * ez + A.KD * (rz - wz), -lim, lim)
    local k = mass * authority
    return qrot(b.qw, b.qx, b.qy, b.qz, ax * A.INERTIA[1] * k, ay * A.INERTIA[2] * k, az * A.INERTIA[3] * k)
end

-- Turn the airframe: torque (world axes) as three pushes with no net force - two a tile
-- either side along world x and one a tile along world y, all at the vehicle's own level.
-- With arms r1 = (1,0,0), r2 = (-1,0,0), r3 = (0,0,1) in Bullet axes the pushes add up to
-- nothing and r1 x F1 + r2 x F2 + r3 x F3 is the torque.
function P.applyTorque(v, tx, ty, tz, dt)
    if not (tx and ty and tz) then return end
    if tx ~= tx or ty ~= ty or tz ~= tz then return end
    local scale = (dt or 0) / STEP / GAIN
    if scale <= 0 then return end
    local x, y, z = v:getX(), v:getY(), v:getZ()
    push(v, x + 1, y, z, 0, (tx + tz) / 2, -ty / 2, scale)
    push(v, x - 1, y, z, 0, (tx - tz) / 2, ty / 2, scale)
    push(v, x, y + 1, z, 0, -tx, 0, scale)
end

-- The whole hold in one call, for the flight controller.
function P.holdAttitude(v, heading, pitchUp, bankRight, yawRate, authority, dt, mass)
    local b = P.observe(v, dt)
    if not (authority and authority > 0 and b.qw) then return b end
    local tx, ty, tz = P.attitudeTorque(b, heading, pitchUp or 0, bankRight or 0, yawRate or 0,
                                        authority, mass)
    P.applyTorque(v, tx, ty, tz, dt)
    b.lastTorque = sqrt(tx * tx + ty * ty + tz * tz)
    return b
end

-- Taildragger ground support: damp pitch/roll without resisting taxi steering
-- or resetting linear velocity. Flight continues to use its own attitude hold.
function P.holdGroundGear(v, dt)
    local b = P.observe(v, dt)
    if not b.qw then return end
    local fx, fz = P.forward(v)
    local heading = atan2(fx, fz)
    local tx, _, tz = P.attitudeTorque(b, heading, math.rad(P.PARK_PITCH_DEG), 0,
                                     b.wy or 0, 3, v:getMass())
    P.applyTorque(v, tx, 0, tz, dt)

    -- Reverse loads the main springs and unloads the small tail rays. Attitude
    -- torque alone cannot stop the whole body settling through the visible gear.
    -- Catch only penetration below the normal tire plane, allowing 6 cm of
    -- suspension compression. This is unilateral support, never a downward hold
    -- or a transform reset, so steering and reverse momentum remain intact.
    local h = P.c172GetBodyHeight(v)
    if not h then return end
    local surface = P.c172SurfaceHeightBelow(v)
    local target = surface + P.restingHeight(v, 0) - .06
    local depth = target - h
    if depth <= 0 or depth > .5 then return end
    local _, vy = P.velocity(v)
    local mass = v:getMass()
    local force = mass * clamp(80 * depth - 12 * vy, 0, 15)
    central(v, 0, 0, 1, force * max(dt or 0, 0) / (STEP * GAIN))
end

-- ---------------------------------------------------------------- level / reseat
-- Put the airframe level with its heading KEPT, where it is. BaseVehicle.setAngles builds the
-- rotation as rotationXYZ(x, y, z) degrees, and rotationY(t) takes the nose to (sin t, 0,
-- cos t) - so t is exactly atan2(forward.x, forward.z). (Reading getAngleY back instead is
-- an Euler angle, which past 90 degrees comes back mirrored - that is the "snaps to a
-- mirrored heading" bug recorded in C172Flight's header.) Teleports: velocity is zeroed.
function P.levelKeepHeading(v)
    local f = v:getForwardVector(vec())
    local fx, fz, fy = num(f:x(), 0), num(f:z(), 1), num(f:y(), 0)
    local h
    if fx * fx + fz * fz > 1e-6 then
        h = atan2(fx, fz)
    else
        -- nose straight up or down (1.10.0): its bearing is gone, but the roof then points along
        -- it - backwards with the nose up, forwards with the nose down
        local u = v:getUpVector(vec())
        local ux, uz = num(u:x(), 0), num(u:z(), 0)
        if ux * ux + uz * uz > 1e-6 then
            h = (fy >= 0) and atan2(-ux, -uz) or atan2(ux, uz)
        else
            local b = bodies[v:getId()]
            h = (b and b.heading) or 0
        end
    end
    v:setAngles(0, deg(h), 0)
    P.forget(v)
    return h
end

-- Height within the storey it is in, as a fraction of a level (BaseVehicle.setDebugZ keeps x,
-- y and the rotation). Teleports: velocity is zeroed.
function P.setHeightInStorey(v, fraction)
    v:setDebugZ(clamp(fraction, 0, 0.99))
end

-- PORT OF c172LevelGroundAttitude. Tilted past maxTiltDeg (or always, with a negative one):
-- level it, heading kept, and seat it at vanilla's resting height for the storey it is in.
-- Returns the tilt that was corrected, 0 if nothing was touched. `level` is accepted for the
-- old signature; the storey is the one the body is in (that is all setDebugZ can reach).
function P.c172LevelGroundAttitude(v, maxTiltDeg, level)
    local tilt = P.c172BodyTiltDeg(v)
    if not tilt then return 0 end
    if (maxTiltDeg or 0) >= 0 and tilt <= maxTiltDeg then return 0 end
    local heading = P.levelKeepHeading(v)
    -- rotationXYZ must retain the horizontal bearing at every yaw.
    local pitch = math.rad(P.PARK_PITCH_DEG)
    v:setAngles(deg(atan2(-sin(pitch), cos(pitch) * cos(heading))),
                deg(math.asin(clamp(cos(pitch) * sin(heading), -1, 1))),
                deg(atan2(sin(pitch) * sin(heading), cos(heading))))
    P.forget(v)
    local h = P.c172GetBodyHeight(v)
    local storey = h and floor(h / Z_M + 1e-4) or 0
    local rest = P.restingHeight(v, 0)
    if rest and rest > 0 then
        P.setHeightInStorey(v, rest / Z_M)
    end
    pcall(function() v:setCurrentSquareFromPosition() end)
    return math.max(tilt, 0.01), storey
end

-- PORT OF c172RecoverToGround (RIGHT AIRCRAFT). Java teleported to the storey's resting
-- height at any height; Lua can only set the height inside the storey the body is in, so an
-- airframe stuck high up is levelled and seated in its storey and then settles on its own.
-- Returns the height it was put at, or -1.
function P.c172RecoverToGround(v)
    P.c172LevelGroundAttitude(v, -1)
    return P.c172GetBodyHeight(v) or -1
end

-- A necessary landing safety reseat must retain horizontal momentum. The
-- engine's transform setters clear velocity; its speed setter is display-only.
-- Queue the lost momentum through the same one-substep impulse channel as flight.
function P.reseatRolling(v)
    local vx, _, vz = P.velocity(v)
    P.c172LevelGroundAttitude(v, -1)
    local speed = sqrt(vx * vx + vz * vz)
    if speed > .01 then
        v:setPhysicsActive(true)
        central(v, vx / speed, vz / speed, 0, v:getMass() * speed / (GAIN * STEP))
    end
end

-- ---------------------------------------------------------------- tyres
-- PORT OF c172SetTiresRemoved: BaseVehicle.setTireRemoved is public and passes straight to
-- the physics library (a removed wheel stops probing the ground). Client side only - the
-- engine itself skips it on a server.
function P.c172SetTiresRemoved(v, removed)
    local ok = pcall(function()
        local n = v:getScript():getWheelCount()
        for i = 0, n - 1 do v:setTireRemoved(i, removed == true) end
    end)
    return ok
end

-- The Java build read each wheel's suspension; Lua has no reading of it. Only the verbose
-- flight log asked.
function P.c172WheelsOnGround() return nil end

-- ---------------------------------------------------------------- the ground under it
local MAX_PROBE_LEVEL = 12

-- IsoGridSquare.TreatAsSolidFloor (public in 42.21) - what the Java build asked. Called
-- straight: a guarded "try this, then that" would still stop a -debug player's game on the
-- first attempt (Break On Error halts on errors pcall catches).
local function solidFloor(sq)
    return sq:TreatAsSolidFloor() == true
end

-- PORT OF c172SurfaceHeightBelow: the highest solid floor at or below the body, metres.
function P.c172SurfaceHeightBelow(v)
    local cell = getCell()
    if not cell then return 0 end
    local h = P.c172GetBodyHeight(v) or 0
    local top = clamp(floor(h / Z_M), 0, MAX_PROBE_LEVEL)
    local x, y = floor(v:getX()), floor(v:getY())
    for z = top, 1, -1 do
        local sq = cell:getGridSquare(x, y, z)
        if sq and solidFloor(sq) then return z * Z_M end
    end
    return 0
end

-- PORT OF c172RoofHeightAhead: the highest solid floor along `dist` tiles of flight path.
function P.c172RoofHeightAhead(v, dirX, dirY, dist)
    local cell = getCell()
    if not cell then return 0 end
    dirX, dirY, dist = num(dirX, 0), num(dirY, 0), num(dist, 0)
    local len = sqrt(dirX * dirX + dirY * dirY)
    if len < 1e-4 then return 0 end
    local ux, uy = dirX / len, dirY / len
    dist = clamp(dist, 0, 80)
    local best = 0
    local x0, y0 = v:getX(), v:getY()
    for i = 0, 6 do
        local d = dist * i / 6
        local x, y = floor(x0 + ux * d), floor(y0 + uy * d)
        for z = MAX_PROBE_LEVEL, 1, -1 do
            if z * Z_M <= best then break end
            local sq = cell:getGridSquare(x, y, z)
            if sq and solidFloor(sq) then best = z * Z_M; break end
        end
    end
    return best
end

-- PORT OF c172SurfaceLevelAt: highest level <= fromLevel with a solid floor at (x, y).
function P.c172SurfaceLevelAt(x, y, fromLevel)
    local cell = getCell()
    if not cell then return 0 end
    local top = clamp(floor(num(fromLevel, 0)), 0, MAX_PROBE_LEVEL)
    for z = top, 1, -1 do
        local sq = cell:getGridSquare(floor(x), floor(y), z)
        if sq and solidFloor(sq) then return z end
    end
    return 0
end

-- ---------------------------------------------------------------- airborne registry
-- Which Cessnas this client is flying (the Java registry the patches read). Read by the
-- lights, the ground footprint and the drawing pin below.
local flying = {}            -- id -> vehicle
P.flying = flying

function P.c172SetFlightState(v, value)
    local ok, id = pcall(function() return v:getId() end)
    if not (ok and id) then return end
    flying[id] = (value == true) and v or nil
end

function P.isFlying(v)
    local ok, id = pcall(function() return v:getId() end)
    return ok and id ~= nil and flying[id] ~= nil
end

function P.c172IsAirborne()
    for _ in pairs(flying) do return true end
    return false
end

-- OTHER players' Cessnas in the air (1.10.3, multiplayer), from the flight updates the server relays
-- every 0.5 s (C172Flight onServerCommand). `flying` above is only what THIS client flies; the drawing
-- (C172Presentation: zoomed-in redraw, name tags) needs the rest too. An entry is trusted for
-- REMOTE_FRESH_MS after its last update: a pilot who drops out mid-air stops sending.
local REMOTE_FRESH_MS = 2000
local remoteFlying = {}      -- id -> { vehicle =, at = ms of the last update }
P.remoteFlying = remoteFlying
P.REMOTE_FRESH_MS = REMOTE_FRESH_MS

local function nowMs()
    local ok, ms = pcall(getTimestampMs)
    return (ok and type(ms) == "number") and ms or 0
end
P.nowMs = nowMs

function P.noteRemoteFlight(v, airborne)
    local ok, id = pcall(function() return v:getId() end)
    if not (ok and id) then return end
    if airborne and not flying[id] then
        local e = remoteFlying[id]
        if e and e.vehicle == v then e.at = nowMs() else remoteFlying[id] = { vehicle = v, at = nowMs() } end
    else
        remoteFlying[id] = nil
    end
end

-- Calls fn(id, vehicle) for every other player's Cessna heard from in the last REMOTE_FRESH_MS
-- that is still in the world; drops the stale ones.
function P.eachRemoteFlying(fn)
    local now = nowMs()
    for id, e in pairs(remoteFlying) do
        local v = e.vehicle
        local okR, gone = pcall(function() return v:isRemovedFromWorld() end)
        if flying[id] or now - e.at > REMOTE_FRESH_MS or now < e.at or not okR or gone then
            remoteFlying[id] = nil
        else
            fn(id, v)
        end
    end
end

function P.c172ResetAllFlightState()
    for id in pairs(flying) do flying[id] = nil end
    for id in pairs(remoteFlying) do remoteFlying[id] = nil end
    for id in pairs(bodies) do bodies[id] = nil end
    if P.Contacts then P.Contacts.restore() end
end

-- The rest of the old registry setters fed only Java patches; kept as no-ops so a caller
-- that still names them does nothing rather than error.
function P.c172SetVehicleAltitude() end
function P.c172SetVehicleTreeClearAltitude() end
function P.c172SetVehicleNoCollisionAirborne() end
function P.c172StartRequested() return false end

-- ---------------------------------------------------------------- nearby aircraft
-- PORT OF c172ScanNearbyAircraft / c172NearbyAircraft. IsoCell.getVehicles() is the live set
-- the engine itself walks (VehicleManager's list is stale in single player). getCell() is nil
-- while a world loads - checked before anything is indexed. Cached for SCAN_SEC, so the
-- lights (20 Hz) and the flight sweep (2 Hz) share one walk.
local SCAN_SEC = 0.25
local found, foundAt, foundX, foundY, foundR = {}, -1, 0, 0, 0
P._found = found

local function nowSec()
    local ok, ms = pcall(getTimestampMs)
    if ok and type(ms) == "number" then return ms / 1000 end
    return 0
end

function P.c172ScanNearbyAircraft(x, y, radius)
    local t = nowSec()
    if foundAt >= 0 and t - foundAt < SCAN_SEC and abs(x - foundX) < 4 and abs(y - foundY) < 4
       and radius == foundR then
        return #found
    end
    for i = #found, 1, -1 do found[i] = nil end
    foundAt, foundX, foundY, foundR = t, x, y, radius
    local cell = getCell()
    if not cell then return 0 end
    local set = cell:getVehicles()
    if not set then return 0 end
    local r2 = radius * radius
    local it = set:iterator()
    while it:hasNext() do
        local v = it:next()
        if v and C172Variants.isVehicle(v) and not v:isRemovedFromWorld() then
            local dx, dy = v:getX() - x, v:getY() - y
            if dx * dx + dy * dy <= r2 then found[#found + 1] = v end
        end
    end
    return #found
end

function P.c172NearbyAircraft(i)
    return found[(i or 0) + 1]
end

-- PORT OF c172VehicleById, Cessnas only. The game's own getVehicleById global (what vanilla's
-- VehicleCommands uses) answers on the Java side; it is asked only once a world exists.
function P.c172VehicleById(id)
    id = num(id)
    if not id then return nil end
    for i = 1, #found do
        local v = found[i]
        if v:getId() == id then return v end
    end
    if not getCell() then return nil end
    local ok, v = pcall(function() return getVehicleById(id) end)
    if ok and v and C172Variants.isVehicle(v) then return v end
    return nil
end

-- ---------------------------------------------------------------- never vertical with crew
-- 1.10.0 (Jay, 2026-10-06: loaded a save made in the air, came down in woods, "plane glitched
-- out 1 error popped up game went to main menu"). The error was vanilla's "Forward Direction
-- cannot be zero length vector" from IsoPlayer.updateWhileInVehicle, which ends the game: every
-- frame it turns a seated player to the nose's bearing in the horizontal plane (getForwardVector
-- x, z), and a nose pointing straight up or down has none. The ground leveller (C172Flight) runs
-- from the pilot's OnTick, AFTER that player update, and only for the pilot; wedged in trees it
-- was levelling every second and the trees kept knocking it over.
-- OnPlayerUpdate fires inside the same player update, BEFORE updateWhileInVehicle
-- (IsoPlayer.updateInternal2, 42.21), and setAngles writes the transform that call reads at once
-- (BaseVehicle.setWorldTransform), so a nose this close to vertical is put level here, heading
-- kept, for whoever sits in it. On the ground it is also seated at its resting height, as the
-- leveller does; in the air only the rotation changes. Healthy flight never gets near it: the
-- attitude hold keeps the body within BODY_PITCH_MAX_DEG (15).
local VERTICAL_FLAT = 0.26      -- horizontal length of the nose vector at 75 degrees of pitch
P.VERTICAL_FLAT = VERTICAL_FLAT

function P.guardVertical(player)
    local v = player and player:getVehicle()
    if not v or not C172Variants.isVehicle(v) then return false end
    local f = v:getForwardVector(vec())
    local fx, fy, fz = num(f:x(), 0), num(f:y(), 0), num(f:z(), 0)
    local flat = math.sqrt(fx * fx + fz * fz)
    if flat >= VERTICAL_FLAT then return false end
    if P.isFlying(v) then
        P.levelKeepHeading(v)
    else
        P.c172LevelGroundAttitude(v, -1)
    end
    print(("[Cessna172][WARN] aircraft %s had its nose %s (%.0f deg) with someone aboard - put level before the game could crash on it")
        :format(tostring(v:getId()), fy >= 0 and "up" or "down", deg(acos(math.min(flat, 1)))))
    return true
end

Events.OnPlayerUpdate.Add(function(player)
    if player and player:isLocalPlayer() then pcall(P.guardVertical, player) end
end)

-- Migrate a stationary aircraft from the former level gear pose once per
-- streamed vehicle instance, on the owning driver's client. Never reseat a
-- moving aircraft or one being flown by another client.
local gearSeated = setmetatable({}, { __mode = "k" })
Events.OnEnterVehicle.Add(function(player)
    if not player or not player:isLocalPlayer() then return end
    local v = player:getVehicle()
    if not v or not C172Variants.isVehicle(v) or not v:isDriver(player)
       or gearSeated[v] or P.isFlying(v) then return end
    local h = P.c172GetBodyHeight(v)
    local ground = P.c172SurfaceHeightBelow(v)
    local _, vy = P.velocity(v)
    if not h or h - ground > 1.6 or h - ground < -0.1
       or abs(v:getCurrentSpeedKmHour()) > .5 or abs(vy) > .5 then return end
    P.c172LevelGroundAttitude(v, -1)
    P.c172SetTiresRemoved(v, false)
    gearSeated[v] = true
end)

-- ---------------------------------------------------------------- reset
Events.OnGameStart.Add(function()
    for id in pairs(bodies) do bodies[id] = nil end
    for id in pairs(flying) do flying[id] = nil end
    for id in pairs(remoteFlying) do remoteFlying[id] = nil end
    for i = #found, 1, -1 do found[i] = nil end
    foundAt = -1
end)

return P
