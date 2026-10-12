--[[
    C172IgnitionKey - the Cessna always has its key in the ignition when you get in.

    WHY: vanilla gates the radial "Start Engine" slice behind a key check and, when that
    check fails, shows NOTHING AT ALL - no greyed-out option, no explanation. A player
    who finds an aircraft and cannot see any way to start it reads that as the mod being
    broken. Key spawning is a property of the ZONE a vehicle spawns in, not of the
    vehicle, so there is no way to guarantee it from the vehicle script; this is the
    targeted fix.

    SCOPE: fires only on the LOCAL player entering a vehicle whose script name is this
    aircraft's. Every other vehicle in the game, including the MiG and the Wraith, is
    untouched - each of those mods has its own equivalent and they do not interact.
]]

require "Cessna172/C172Util"
require "Cessna172/C172Phys"

C172IgnitionKey = C172IgnitionKey or {}

local function ensureKeyInIgnition(character)
    if character == nil then return end
    local okPlayer, isPlayer = pcall(function()
        return instanceof(character, "IsoPlayer") and character:isLocalPlayer()
    end)
    if not okPlayer or not isPlayer then return end

    local okVeh, vehicle = pcall(function() return character:getVehicle() end)
    if not okVeh or not vehicle then return end
    if not C172Util.getConfig(vehicle) then return end

    local okHas, hasKey = pcall(function()
        return vehicle:isKeysInIgnition()
            or character:getInventory():haveThisKeyId(vehicle:getKeyId())
    end)
    if okHas and hasKey then return end

    local okSet = pcall(function() vehicle:setKeysInIgnition(true) end)
    print("[Cessna172][IGNITION] key placed in ignition = " .. tostring(okSet))
end

Events.OnEnterVehicle.Add(ensureKeyInIgnition)
C172IgnitionKey.ensure = ensureKeyInIgnition

-- ==================== W STARTS THE ENGINE (09-25) ====================
-- Jay: "i want all my aircraft to be able to start with w instead of just using radial wheel".
-- Vanilla's own press-W-to-start stays blocked (by the guard below since 1.9.0; by a Java patch
-- before): it fires whenever Forward is merely HELD with the engine idle - in the air too -
-- which is what restarted an engine switched off in flight. This is the deliberate version. A FRESH press of the Forward
-- key (released, then pressed) while this client's pilot sits ON THE GROUND with the engine
-- off, the engine able to run and the key available - the same conditions under which
-- vanilla's radial offers Start Engine - runs that same radial action
-- (ISVehicleMenu.onStartEngine -> ISStartVehicleEngine), so the key, starter, battery and
-- multiplayer handling are all vanilla's. Holding Forward through an engine-off landing still
-- does nothing; let go and press it again to start.
local wStart = { down = true, at = 0 }   -- "held" until seen released, so a key already down at load is not a press

-- ==================== START INTENT (1.9.0, replaces Patch_StartIntent) ====================
-- When did the player last ASK for this aircraft's engine? Every deliberate start - the radial
-- menu, the start-engine key, the dashboard, and the W press below - runs through
-- ISVehicleMenu.onStartEngine, so a pass-through wrapper on it records the time for Cessnas
-- (and does nothing at all for any other vehicle). The flight controller's engine hold reads
-- it (C172Phys.c172StartRequested), and the guard below uses it to tell a deliberate start
-- from vanilla's throttle auto-start (CarController starts an idle engine whenever Forward
-- produces engine force - which the Java build switched off for this aircraft).
local INTENT_SEC = 2.5
C172IgnitionKey.intent = C172IgnitionKey.intent or {}

local function noteIntent(vehicle)
    local ok, id = pcall(function() return vehicle:getId() end)
    if ok and id then C172IgnitionKey.intent[id] = getTimestampMs() end
end
C172IgnitionKey.noteIntent = noteIntent

function C172IgnitionKey.startRequested(vehicle)
    local ok, id = pcall(function() return vehicle:getId() end)
    local at = ok and C172IgnitionKey.intent[id] or nil
    return at ~= nil and (getTimestampMs() - at) <= INTENT_SEC * 1000
end
if C172Phys then
    C172Phys.c172StartRequested = function(vehicle) return C172IgnitionKey.startRequested(vehicle) end
end

local function wrapStartEngine()
    if not (ISVehicleMenu and type(ISVehicleMenu.onStartEngine) == "function") then return end
    if ISVehicleMenu.__c172StartIntent then return end
    ISVehicleMenu.__c172StartIntent = true
    local original = ISVehicleMenu.onStartEngine
    ISVehicleMenu.onStartEngine = function(playerObj, ...)
        pcall(function()
            local v = playerObj and playerObj:getVehicle()
            if v and C172Util.getConfig(v) then noteIntent(v) end
        end)
        return original(playerObj, ...)
    end
end
Events.OnGameStart.Add(wrapStartEngine)

local function wStartTyping()
    local ok, focused = pcall(function()
        local chat = ISChat and ISChat.instance
        local entry = chat and chat.textEntry
        return entry and entry.isFocused and entry:isFocused() or false
    end)
    return ok and focused == true
end

local function wStartForwardDown()
    if wStartTyping() then return false end
    local code, alt = nil, nil
    pcall(function() code = getCore():getKey("Forward") end)
    if type(code) ~= "number" or code <= 0 then code = Keyboard.KEY_W end
    if Keyboard.isKeyDown(code) then return true end
    pcall(function() alt = getCore():getAltKey("Forward") end)
    return type(alt) == "number" and alt > 0 and Keyboard.isKeyDown(alt) or false
end

local function wStartTick()
    local player = getPlayer()
    local down = player ~= nil and wStartForwardDown()
    local fresh = down and not wStart.down
    wStart.down = down
    if not fresh then return end
    local vehicle = player:getVehicle()
    if not (vehicle and C172Util.getConfig(vehicle)) then return end
    if not vehicle:isDriver(player) then return end
    if (C172Flight and C172Flight.isAirborne and C172Flight.isAirborne(vehicle)) then return end
    -- A fresh press on the ground IS a request, even when vanilla's own throttle start already
    -- got there first this frame (it runs in the world update, before this) - so it is noted
    -- before the "already starting" check, and the guard below lets that start through.
    noteIntent(vehicle)
    if vehicle:isEngineRunning() or vehicle:isEngineStarted() then return end
    if not vehicle:isEngineWorking() then return end
    local keyOk = (SandboxVars and SandboxVars.VehicleEasyUse) or vehicle:isHotwired()
                  or vehicle:isKeysInIgnition()
                  or player:getInventory():haveThisKeyId(vehicle:getKeyId())
    if not keyOk then return end
    local now = getTimestampMs()
    if now - wStart.at < 2000 then return end
    wStart.at = now
    if ISVehicleMenu and ISVehicleMenu.onStartEngine then
        ISVehicleMenu.onStartEngine(player)
        print("[Cessna172][IGNITION] Forward pressed on the ground - starting the engine")
    end
end

-- ==================== THROTTLE AUTO-START GUARD (1.9.0) ====================
-- An engine that comes on while Forward is held and nobody asked for it is vanilla's throttle
-- auto-start: switched straight back off (key left in), exactly as the Java build refused it.
-- The decision waits a few ticks after the start, so a W press noted later in the same frame
-- (wStartTick runs after the world update) counts. Only this client's own Cessna, only with
-- Forward held - any start without Forward held (other mods, a server command) is left alone.
local guard = { id = nil, was = nil, edgeAt = nil }
local GUARD_WAIT_MS = 150

local function guardTick()
    local player = getPlayer()
    local vehicle = player and player:getVehicle()
    if not (vehicle and C172Util.getConfig(vehicle) and vehicle:isDriver(player)) then
        guard.id, guard.was, guard.edgeAt = nil, nil, nil
        return
    end
    local id = vehicle:getId()
    local on = vehicle:isEngineStarted() or vehicle:isEngineRunning()
    if guard.id ~= id then guard.id, guard.was, guard.edgeAt = id, on, nil end
    if on and not guard.was and wStartForwardDown() then guard.edgeAt = getTimestampMs() end
    if not on then guard.edgeAt = nil end
    guard.was = on
    if guard.edgeAt and getTimestampMs() - guard.edgeAt >= GUARD_WAIT_MS then
        guard.edgeAt = nil
        if not C172IgnitionKey.startRequested(vehicle) then
            if isClient() then
                -- multiplayer: the engine is the server's - ask through vanilla's own shut-off
                -- action (its complete() runs on the server in B42)
                ISVehicleMenu.onShutOff(player)
            else
                local keysWereIn = vehicle:isKeysInIgnition()
                vehicle:shutOff()
                if keysWereIn then vehicle:setKeysInIgnition(true) end
            end
            guard.was = false
            print("[Cessna172][IGNITION] throttle auto-start refused (Forward held, no start asked for)")
        end
    end
end

Events.OnTick.Add(function() pcall(wStartTick) end)
Events.OnTick.Add(function() pcall(guardTick) end)

return C172IgnitionKey
