-- RE9-only motorcycle audio. Reads engine state; never changes vehicle physics.
-- Samples adapted from the user-supplied Backcountry ATV archive; see CREDITS.
-- Native one-shots remain in the vehicle sound block. Loops are mixed locally
-- because file clips do not contain an FMOD RPM-parameter graph.
if isServer and isServer() then return end
EmreRE9 = EmreRE9 or {}
if EmreRE9.Audio then return EmreRE9.Audio end
local A = {}
EmreRE9.Audio = A

A.Layers = {
    {sound="EMRE_RE9EngineL1", rpm=1762, gain=0.85},
    {sound="EMRE_RE9EngineL2", rpm=3095, gain=0.70},
    {sound="EMRE_RE9EngineL3", rpm=4811, gain=0.48},
}
local MASTER, RANGE_SQ, DISCOVERY_MS = 0.82, 65*65, 250
local states = {}
local retryAt = setmetatable({}, {__mode="k"})
local lastScan, lastTick = -1000, nil
local warned = false

local function clamp(value, lo, hi) return math.max(lo, math.min(hi, value)) end
-- Compress only the upper rev range for audio. Native limiter RPM swings
-- should not turn the loop into a repeated pitch/volume knock at full speed.
-- This never changes the actual engine RPM or driving physics.
function A.AudioRPM(rpm)
    rpm = clamp(rpm, 900, 7000)
    if rpm > 5200 then rpm = 5200 + (rpm-5200)*0.35 end
    return rpm
end
local function warn(message)
    if not warned then
        warned = true
        print("[EmreRE9 0.2.15] audio unavailable: " .. tostring(message))
    end
end

function A.Mix(rpm, throttle)
    rpm = clamp(rpm, 900, 7000)
    local layers, weights, pitches = A.Layers, {0,0,0}, {}
    if rpm <= layers[1].rpm then
        weights[1] = 1
    elseif rpm >= layers[3].rpm then
        weights[3] = 1
    else
        for i=1,2 do
            if rpm >= layers[i].rpm and rpm <= layers[i+1].rpm then
                local t = (rpm-layers[i].rpm)/(layers[i+1].rpm-layers[i].rpm)
                weights[i], weights[i+1] = math.sqrt(1-t), math.sqrt(t)
                break
            end
        end
    end
    local loudness = 0.55 + 0.15*clamp(rpm/7000,0,1) + 0.30*clamp(math.abs(throttle),0,1)
    for i, layer in ipairs(layers) do
        pitches[i] = clamp(rpm/layer.rpm, 0.50, 2.00)
        weights[i] = weights[i]*layer.gain*MASTER*loudness
    end
    return weights, pitches
end

local function stopOn(vehicle)
    local state = states[vehicle]
    if state then
        for _, handle in pairs(state.handles) do
            -- Only our local handles. Never stop the horn, starter or another mod.
            pcall(function() state.emitter:stopSoundLocal(handle) end)
        end
        state.emitter:tick()
        state.world:returnOwnershipOfEmitter(state.emitter)
    end
    states[vehicle] = nil
end

function A.StopAll()
    for vehicle in pairs(states) do stopOn(vehicle) end
    retryAt = setmetatable({}, {__mode="k"})
    lastScan, lastTick = -1000, nil
end

local function listeners()
    local result = {}
    local count = getNumActivePlayers and getNumActivePlayers() or 1
    for i=0,count-1 do
        local player = getSpecificPlayer and getSpecificPlayer(i) or (i==0 and getPlayer())
        if player and not player:isDead() then result[#result+1] = player end
    end
    return result
end

local function near(vehicle, players)
    local x,y,z = vehicle:getX(), vehicle:getY(), vehicle:getZ()
    for _,player in ipairs(players) do
        local dx,dy,dz = x-player:getX(), y-player:getY(), (z-player:getZ())*3
        if dx*dx+dy*dy+dz*dz <= RANGE_SQ then return true end
    end
    return false
end

local function startOn(vehicle,now)
    local world = getWorld()
    local emitter = world:getFreeEmitter(vehicle:getX(),vehicle:getY(),vehicle:getZ())
    if not emitter then error("no engine audio emitter") end
    world:takeOwnershipOfEmitter(emitter)
    local state = {world=world, emitter=emitter, handles={}, startedAt={}, fade=0, throttle=0,
        rpm=A.AudioRPM(vehicle:getEngineSpeed())}
    -- Store before creating handles, so a partially failed start can be cleaned up.
    states[vehicle] = state
    for i,layer in ipairs(A.Layers) do
        local handle = emitter:playSoundLoopedImpl(layer.sound)
        if not handle or handle == 0 then error("cannot start " .. layer.sound) end
        state.handles[i] = handle
        state.startedAt[i] = now
        emitter:setVolume(handle,0)
        emitter:setPitch(handle,clamp(state.rpm/layer.rpm,0.50,2.00))
    end
    emitter:tick()
    print("[EmreRE9] engine audio started for vehicle "..tostring(vehicle:getId()))
end

local function discover(cell, players, now)
    local vehicles = cell:getVehicles()
    if not vehicles then A.StopAll(); return end
    local seen = {}
    local function visit(vehicle)
        if not vehicle then return end
        local script = vehicle:getScript()
        if not script or script:getFullName() ~= "Base.EMRE_RE9" or not near(vehicle,players) then return end
        seen[vehicle] = true
        if not states[vehicle] and vehicle:isEngineRunning()
            and (not retryAt[vehicle] or now>=retryAt[vehicle]) then
            startOn(vehicle,now); retryAt[vehicle]=nil
        end
    end
    -- The ridden bike is discovered directly too, even during chunk/vehicle
    -- registration changes. Audio never depends solely on a cell collection.
    for _,player in ipairs(players) do visit(player:getVehicle()) end
    local iterator = vehicles:iterator()
    while iterator:hasNext() do
        local vehicle = iterator:next()
        local ok,err = pcall(function()
            visit(vehicle)
        end)
        if not ok then
            stopOn(vehicle)
            retryAt[vehicle] = now+2000
            warn(err)
        end
    end
    for vehicle in pairs(states) do
        if not seen[vehicle] then stopOn(vehicle) end
    end
end

local function updateOn(vehicle,state,dt,now)
    local emitter = state.emitter
    if vehicle:isRemovedFromWorld() then
        stopOn(vehicle)
        return
    end
    emitter:setPos(vehicle:getX(),vehicle:getY(),vehicle:getZ())
    local running = vehicle:isEngineRunning()
    local target = running and A.AudioRPM(vehicle:getEngineSpeed()) or 900
    local response = target > 5200 and 3 or 8
    state.rpm = state.rpm+(target-state.rpm)*(1-math.exp(-response*dt))
    local throttle = running and vehicle:getThrottle() or 0
    state.throttle = state.throttle+(throttle-state.throttle)*(1-math.exp(-8*dt))
    state.fade = running and math.min(1,state.fade+dt/0.65) or math.max(0,state.fade-dt/0.35)
    if state.fade <= 0 and not running then stopOn(vehicle); return end
    local volume,pitch = A.Mix(state.rpm,state.throttle)
    for i,layer in ipairs(A.Layers) do
        local handle = state.handles[i]
        -- A just-created handle can still be queued until the native emitter
        -- ticks. Do not start duplicate loops while waiting for that first tick.
        if now-state.startedAt[i] >= 250 and not emitter:isPlaying(handle) then
            handle = emitter:playSoundLoopedImpl(layer.sound)
            if not handle or handle == 0 then error("cannot restart " .. layer.sound) end
            state.handles[i] = handle
            state.startedAt[i] = now
        end
        emitter:setVolume(handle,volume[i]*state.fade)
        emitter:setPitch(handle,pitch[i])
    end
    -- This emitter belongs only to the RE9 mix. Explicitly tick its queued
    -- file loops so vehicle sound updates and other mods cannot mute/stall it.
    emitter:tick()
end

function A.Tick()
    local cell = getCell()
    local players = listeners()
    if not cell or #players == 0 then A.StopAll(); return end
    local now = getTimestampMs()
    local dt = lastTick and (now-lastTick)/1000 or 1/45
    lastTick = now
    if dt <= 0 then return end
    dt = math.min(dt,0.10) -- do not jump through a fade after pause/loading
    if now-lastScan >= DISCOVERY_MS then
        lastScan = now
        discover(cell,players,now)
    end
    for vehicle,state in pairs(states) do
        local ok,err = pcall(updateOn,vehicle,state,dt,now)
        if not ok then
            stopOn(vehicle)
            retryAt[vehicle] = now+2000
            warn(err)
        end
    end
end

Events.OnTick.Add(function()
    local ok,err = pcall(A.Tick)
    if not ok then A.StopAll(); warn(err) end
end)
Events.OnGameStart.Add(A.StopAll)
-- This event is present in the normal game; keep it optional for tools/servers.
if Events.OnMainMenuEnter then Events.OnMainMenuEnter.Add(A.StopAll) end
return A
