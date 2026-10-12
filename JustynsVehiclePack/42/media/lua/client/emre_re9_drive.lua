-- Native ignition integration, speed tuning and diagnostics for the RE9 only.
-- No forced hotwire success, fuel/charge refill, engine-state mutation or
-- replacement driving input. The game's start action owns the attempt.
require "Vehicles/TimedActions/ISStartVehicleEngine"
require "Vehicles/TimedActions/ISHotwireVehicle"
require "TimedActions/ISTimedActionQueue"
require "emre_re9_settling"
EmreRE9 = EmreRE9 or {}
if EmreRE9.Drive then return EmreRE9.Drive end
local D = {}; EmreRE9.Drive = D
local states = setmetatable({}, {__mode="k"})
local function bike(v)
    return v and v:getScript() and v:getScript():getFullName() == "Base.EMRE_RE9"
end
local function read(object, method, ...)
    if not object then return "absent" end
    local args = {...}
    local ok, value = pcall(function()
        if not object[method] then return "unavailable" end
        return object[method](object, unpack(args))
    end)
    return ok and tostring(value) or "unavailable"
end
local function input(c, v)
    local f, b = false, false
    if c:isLocalPlayer() and v:isKeyboardControlled() and getCore and isKeyDown then
        f = isKeyDown(getCore():getKey("Forward"))
        b = isKeyDown(getCore():getKey("Backward"))
    end
    return f, b
end
-- B42 divides maxSpeed by the gear count when choosing automatic shifts.
-- Keep the old 45 km/h value through 40 km/h, preserving the original
-- low-speed gears and torque. Blend only above that; engine power, mass,
-- throttle and braking stay native. The native 20 km/h force taper gives
-- an 80 mph (128.74752 km/h) ceiling without chopping the throttle.
function D.SpeedLimit(speed)
    local t = math.max(0, math.min(1, (speed - 40) / 20))
    t = t*t*(3-2*t)
    return 45 + (108.74752 - 45)*t
end
function D.TuneSpeed(c, v)
    if v:getSeat(c) ~= 0 then return end
    local speed = v:getCurrentSpeedKmHour()
    local limit = D.SpeedLimit(math.max(0, speed))
    -- Speed Demon otherwise extends the native limit by 15%. Ease out
    -- that extension at high speed without affecting the trait's launch.
    if CharacterTrait and CharacterTrait.SPEED_DEMON and c:hasTrait(CharacterTrait.SPEED_DEMON) then
        local t = math.max(0, math.min(1, (speed - 80) / 20))
        t = t*t*(3-2*t)
        limit = limit / (1 + 0.15*t)
    end
    v:setMaxSpeed(limit)
end
function D.Snapshot(c, reason)
    local v = c and c:getVehicle()
    if not bike(v) or not c:isLocalPlayer() then return end
    local q = ISTimedActionQueue.getTimedActionQueue(c)
    local action = q and q.queue and q.queue[1]
    local tank, battery, engine = v:getPartById("GasTank"), v:getPartById("Battery"), v:getPartById("Engine")
    local f, b = input(c, v)
    local values = {
        "reason="..reason, "vehicle="..read(v,"getId"), "seat="..read(v,"getSeat",c),
        "blocked="..read(c,"isBlockMovement"), "action="..tostring(action and action.Type or "none"),
        "ignoreDirection="..read(c,"isIgnoreInputsForDirection"),
        "aiming="..read(c,"isAiming"), "loading="..read(c,"getVariableString","isLoading"),
        "enter="..read(c,"getVariableString","bEnteringVehicle"),
        "exit="..read(c,"getVariableString","bExitingVehicle"),
        "hotwired="..read(v,"isHotwired"), "keys="..read(v,"isKeysInIgnition"),
        "starting="..read(v,"isEngineStarted"), "running="..read(v,"isEngineRunning"),
        "rpm="..read(v,"getEngineSpeed"), "throttle="..read(v,"getThrottle"),
        "forward="..tostring(f), "backward="..tostring(b),
        "gas="..read(v,"isGasPedalPressed"), "brake="..read(v,"isBrakePedalPressed"),
        "physics="..read(v,"isPhysicsActive"), "localPhysics="..read(v,"isLocalPhysicSim"),
        "operational="..read(v,"isOperational"), "engineWorking="..read(v,"isEngineWorking"),
        "fuel="..read(tank,"getContainerContentAmount"), "charge="..read(v,"getBatteryCharge"),
        "batteryItem="..tostring(battery and battery:getInventoryItem() ~= nil),
        "engineCondition="..read(engine,"getCondition"), "power="..read(v,"getEnginePower"),
        "speed="..read(v,"getCurrentSpeedKmHour")
    }
    print("[EmreRE9 0.2.15] drive "..table.concat(values," "))
end
function D.RequestSnapshot(c)
    if not c then return end
    states[c] = states[c] or {}
    states[c].next = 0
    states[c].changed = true
end
function D.Update(c)
    if not c then return end
    local v = c:getVehicle()
    if not bike(v) or not c:isLocalPlayer() then states[c] = nil; return end
    D.TuneSpeed(c, v)
    local now = getTimestampMs()
    local s = states[c]
    if not s or s.vehicle ~= v then s = {vehicle=v, next=0, changed=true}; states[c] = s end
    if now < s.next then return end
    s.next = now + 1000
    local f,b = input(c,v)
    local q = ISTimedActionQueue.getTimedActionQueue(c)
    local action = q and q.queue and q.queue[1]
    local sig = table.concat({read(v,"getSeat",c), read(c,"isBlockMovement"),
        read(c,"isIgnoreInputsForDirection"),read(c,"isAiming"),read(c,"getVariableString","isLoading"),
        read(v,"isHotwired"),read(v,"isEngineStarted"),read(v,"isEngineRunning"),
        read(v,"isPhysicsActive"), tostring(f),tostring(b),
        tostring(action and action.Type or "none")},"/")
    -- Changes are logged once; a held but unresponsive throttle is sampled
    -- at most once every five seconds. This also works without -debug.
    local silent = (f or b) and math.abs(v:getThrottle()) < .01
    if s.changed or sig ~= s.signature or (silent and now >= (s.nextSilent or 0)) then
        D.Snapshot(c, silent and "input-without-throttle" or "state")
        s.signature, s.changed, s.nextSilent = sig, false, now + 5000
    end
end
local startNew, startBegin = ISStartVehicleEngine.new, ISStartVehicleEngine.start
function ISStartVehicleEngine:new(c)
    local a = startNew(self,c)
    if bike(c:getVehicle()) then a.stopOnAim = false end
    return a
end
function ISStartVehicleEngine:start()
    local v = self.character:getVehicle()
    if bike(v) then
        EmreRE9.Settling.ReleaseExit(v)
        D.Snapshot(self.character,"native-start-request")
        D.RequestSnapshot(self.character)
    end
    return startBegin(self)
end
-- Observe the real timed action; never replace complete()/tryHotwire().
local hotwireStart, hotwirePerform, hotwireStop = ISHotwireVehicle.start, ISHotwireVehicle.perform, ISHotwireVehicle.stop
function ISHotwireVehicle:start()
    local v = self.character:getVehicle()
    if bike(v) then
        EmreRE9.Settling.ReleaseExit(v)
        D.Snapshot(self.character,"native-hotwire-start")
    end
    return hotwireStart(self)
end
function ISHotwireVehicle:perform()
    local v = self.character:getVehicle()
    if bike(v) then EmreRE9.Settling.ReleaseExit(v) end
    local result = hotwirePerform(self)
    if bike(v) then D.RequestSnapshot(self.character) end
    return result
end
function ISHotwireVehicle:stop()
    local v = self.character:getVehicle()
    local result = hotwireStop(self)
    if bike(v) then D.Snapshot(self.character,"native-hotwire-cancelled") end
    return result
end
Events.OnPlayerUpdate.Add(D.Update)
Events.OnEnterVehicle.Add(function(c) D.RequestSnapshot(c) end)
return D
