--[[
    C172PropSpin - the spinning propeller, without Java (1.9.0).

    Replaces the propeller half of Patch_ModelTransform. One propeller model, turned for real
    every drawn frame - never a flipbook of poses, so a ghost or missing blade cannot happen.

    HOW. A part model is drawn at the `offset` and `rotate` of its script block, and Lua can
    write those. Writing the SHARED script would spin every Cessna at once, so each aircraft
    gets a private copy of the propeller-carrier part (the turret trick from the M1 Abrams, the
    rotors on the MH-92) and only its own copy turns. The carrier is C172PropSpin, a
    `nodisplay` part in vehicle_cessna172.txt; the Propeller PART (the item you fit, damage
    and repair) keeps all of that and simply no longer carries the mesh.

    THE PIVOT. The blades are a sub-mesh of the airframe file, so they turn about their hub at
    raw mesh (x, y) = HUB, not about the mesh origin. The engine draws a part model as
        v' = (-offset.x, offset.y, offset.z) + R (s v),  R = rotationXYZ(rx, -ry, -rz) degrees
    (42.21 BaseVehicle.updateTransform; s = the model's scale, 1.75 here). Turning by p about
    the hub is v' = s (HUB + Rz(p) (v - HUB)), so rotate.z = -p and the offset carries
    s (HUB - Rz(p) HUB). At p = 0 both are zero - exactly how the propeller was drawn before.

    Driven by measured wall-clock time on every DRAWN frame (the logic tick runs slower than
    the screen and a propeller stepped on it stutters), from the angle and rate the flight
    controller publishes. Any error switches the spin off for the session; the propeller then
    simply stands still.
]]

require "Cessna172/C172Phys"

local P = C172Phys
local S = {}
C172PropSpin = S

local PART = "C172PropSpin"
local OWN = "spinOwn"                   -- the private copy's model id (the shared one is "spin")
local HUB_X, HUB_Y = -0.0023, -0.1278   -- raw mesh units: the blades' 2-fold symmetry centre
local MESH_SCALE = 1.0                  -- part offset is scaled by the parent vehicle transform
local TWO_PI = math.pi * 2
local sin, cos, floor, deg = math.sin, math.cos, math.floor, math.deg

S.props = {}          -- vehicle id -> { vehicle, part, model, angle, rate, shown }

local function log(msg) print("[Cessna172] " .. msg) end

local function definition()
    return "vehicle C172PropRender {\n"
        .. " part " .. PART .. " {\n"
        .. "  category = nodisplay,\n"
        .. "  model " .. OWN .. " { file = Cessna172_Prop, offset = 0.0 0.0 0.0, rotate = 0.0 0.0 0.0, }\n"
        .. " }\n"
        .. "}"
end

local function ids(v)
    local ok, id = pcall(function() return v:getId() end)
    if ok then return id end
    return nil
end

-- Give this aircraft its own carrier part. Returns the record, or nil if this build cannot
-- (then the propeller just stands still - nothing else depends on it).
local function install(v, id)
    local part = v:getPartById(PART)
    if not part then return nil end
    local sp = part:getScriptPart()
    local model = sp and sp:getModelById(OWN)
    if not model then
        local owned = VehicleScript.new()
        owned:setModule(v:getScript():getModule())
        owned:InitLoadPP("C172PropRender")
        owned:Load("C172PropRender", definition())
        local mine = owned:getPartById(PART)
        if not mine then return nil end
        part:setAllModelsVisible(false)
        part:setScriptPart(mine)
        model = mine:getModelById(OWN)
        if not model then return nil end
        S.keep = S.keep or {}
        S.keep[id] = owned             -- the script object must outlive this call
    end
    local r = { vehicle = v, part = part, model = model, angle = 0, rate = 0, shown = nil }
    S.props[id] = r
    return r
end

local function record(v)
    local id = ids(v)
    if not id then return nil end
    local r = S.props[id]
    -- ids are unique among vehicles in the world; one that left it is re-installed when it
    -- comes back (a new object, with the shared script part again)
    if r and not r.vehicle:isRemovedFromWorld() then return r end
    if S.disabled then return nil end
    local ok, got = pcall(install, v, id)
    if ok and got then return got end
    S.disabled = true
    log("propeller spin unavailable on this build: " .. tostring(got))
    return nil
end

-- Show the blades only while a propeller is fitted. Written only on a CHANGE: showing or
-- hiding a model rebuilds the vehicle's render model, and churning that has crashed games.
function S.setFitted(v, fitted)
    local r = record(v)
    if not r then return end
    if r.shown == fitted then return end
    r.part:setAllModelsVisible(fitted == true)
    r.shown = fitted == true
end

-- PORT OF c172SetPropRate: the rate the flight controller publishes. The PHASE is owned here,
-- by the drawn frames - the controller's own angle (c172SetPropAngle) is no longer needed,
-- and writing it back each logic tick would only make the blades jump.
function P.c172SetPropAngle() end
function P.c172SetPropRate(v, radPerSec)
    local r = S.props[ids(v) or -1]
    if r then r.rate = radPerSec or 0 end
end

local function pose(r)
    local p = r.angle
    local c, s = cos(p), sin(p)
    local tx = MESH_SCALE * (HUB_X - (c * HUB_X - s * HUB_Y))
    local ty = MESH_SCALE * (HUB_Y - (s * HUB_X + c * HUB_Y))
    r.model:getOffset():set(-tx, ty, 0)
    r.model:getRotate():set(0, 0, -deg(p))
end

local lastMs = nil
local function frame()
    local now = getTimestampMs()
    local dt = lastMs and (now - lastMs) / 1000 or 0
    lastMs = now
    if dt < 0 or dt > 0.1 then dt = 0 end
    if isGamePaused() then dt = 0 end
    for id, r in pairs(S.props) do
        if r.vehicle:isRemovedFromWorld() then
            S.props[id] = nil
            if S.keep then S.keep[id] = nil end
        elseif r.shown and (r.rate ~= 0 or r.posed ~= r.angle) then
            r.angle = r.angle + r.rate * dt
            r.angle = r.angle - floor(r.angle / TWO_PI) * TWO_PI
            pose(r)
            r.posed = r.angle
        end
    end
end

function S.frame()
    if S.off then return end
    local ok, err = pcall(frame)
    if not ok then
        S.off = true
        log("PROPELLER ERROR, spin switched off: " .. tostring(err))
    end
end

-- PARKED CESSNAS TOO (1.9.3 - Jay: "cessna missing propeller"). The carrier part is nodisplay with no
-- item, so nothing in the game ever shows its model; until 1.9.3 only the flight controller did, and
-- only for the aircraft someone was flying - every parked Cessna stood there without a propeller. Once
-- a second, every Cessna within SCAN_RADIUS of this player gets its blades shown while a Propeller is
-- fitted (hidden when one is removed). setFitted writes only on a change, so a Cessna already right
-- costs a getPartById and a comparison. Client-side drawing only: each client does its own.
local SCAN_EVERY_MS, SCAN_RADIUS = 1000, 60
local nextScan = 0
local function scanParked()
    local player = getSpecificPlayer(0)
    if not player then return end
    local n = P.c172ScanNearbyAircraft(player:getX(), player:getY(), SCAN_RADIUS)
    for i = 0, n - 1 do
        local v = P.c172NearbyAircraft(i)
        if v then
            local part = v:getPartById("Propeller")
            S.setFitted(v, part ~= nil and part:getInventoryItem() ~= nil)
        end
    end
end
S._scanParked = scanParked

function S.tick()
    if S.off or S.disabled then return end
    local now = getTimestampMs()
    if now < nextScan and nextScan - now <= SCAN_EVERY_MS then return end
    nextScan = now + SCAN_EVERY_MS
    local ok, err = pcall(scanParked)
    if not ok then
        S.off = true
        log("PROPELLER ERROR, spin switched off: " .. tostring(err))
    end
end

Events.OnPostRender.Add(S.frame)
Events.OnTick.Add(S.tick)
Events.OnGameStart.Add(function()
    S.props, S.keep, S.disabled, S.off, lastMs, nextScan = {}, {}, false, false, nil, 0
end)

return S
