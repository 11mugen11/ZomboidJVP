if isClient() then return end
require "JVPActyFuel"
local F = JVPActyFuel
F.sessions = {}

local function key(player)
    return player:getOnlineID()
end

local function objectAt(args, className)
    if type(args.x) ~= "number" or type(args.y) ~= "number" or type(args.z) ~= "number"
        or type(args.index) ~= "number" then return nil end
    local sq = getCell():getGridSquare(args.x, args.y, args.z)
    if not sq or args.index < 0 or args.index >= sq:getObjects():size() then return nil end
    local obj = sq:getObjects():get(args.index)
    if className and not instanceof(obj, className) then return nil end
    return obj
end

local function active(s)
    local player, truck = s.player, s.truck
    local tank = F.tank(truck)
    if not tank or player:isDead() or player:getVehicle() or not truck:getSquare()
        or math.abs(truck:getCurrentSpeedKmHour()) > 1 then return false end
    local inlet = F.point(truck, tank)
    if not inlet then return false end
    if s.mode == "load" then
        return s.pump and s.pump:getObjectIndex() ~= -1 and F.powered(s.pump)
            and s.pump:getPipedFuelAmount() > 0
            and F.inRange(inlet:getX(), inlet:getY(), truck:getZ(),
                s.pump:getX(), s.pump:getY(), s.pump:getZ(), 2)
            and F.nearPoint(player, inlet:getX(), inlet:getY(), truck:getZ())
            and tank:getContainerContentAmount() < F.CAPACITY
    end
    if not truck:isEngineRunning() or tank:getContainerContentAmount() <= 0 then return false end
    if s.mode == "vehicle" then
        local v, p = s.target, s.part
        if v == truck or not v:getSquare() or v:isEngineStarted()
            or math.abs(v:getCurrentSpeedKmHour()) > 1 or not p:getInventoryItem()
            or p:getId() ~= "GasTank" or p:getContainerContentType() ~= "Gasoline" then return false end
        local point = F.point(v, p)
        return point and F.hoseReaches(truck, v, p)
            and F.nearPoint(player, point:getX(), point:getY(), v:getZ())
            and p:getContainerContentAmount() < p:getContainerCapacity()
    elseif s.mode == "generator" then
        local g = s.generator
        return g and g:getObjectIndex() ~= -1 and not g:isActivated()
            and F.inRange(inlet:getX(), inlet:getY(), truck:getZ(), g:getX(), g:getY(), g:getZ(), F.RANGE)
            and F.nearPoint(player, g:getX(), g:getY(), g:getZ())
            and g:getFuel() < g:getMaxFuel()
    end
    return false
end

function F.serverCommand(player, command, args)
    if command == "stop" then F.sessions[key(player)] = nil; return end
    if command == "keepalive" then
        local session = F.sessions[key(player)]
        if session then session.alive = getTimestampMs() end
        return
    end
    if command ~= "start" or type(args) ~= "table" or type(args.truck) ~= "number" then return end
    local truck = getVehicleById(args.truck)
    if not F.isTruck(truck) then return end
    local now = getTimestampMs()
    local s = { player = player, truck = truck, mode = args.mode, last = now, alive = now }
    if args.mode == "load" then
        s.pump = objectAt(args)
    elseif args.mode == "vehicle" and type(args.target) == "number" then
        s.target = getVehicleById(args.target)
        s.part = s.target and s.target:getPartById("GasTank")
        if not s.part then return end
    elseif args.mode == "generator" then
        s.generator = objectAt(args, "IsoGenerator")
    else return end
    if active(s) then F.sessions[key(player)] = s end
end

-- Accessible to the offline regression harness; only the server calls this in game.
F.sessionValid = active
function F.tick()
    local now = getTimestampMs()
    for id, s in pairs(F.sessions) do
        if now - s.alive > 3000 or not active(s) then
            F.sessions[id] = nil
        elseif now - s.last >= 250 then
            local requested = F.RATE * math.min(0.5, (now - s.last) / 1000)
            s.last = now
            local tank = F.tank(s.truck)
            local stored = tank:getContainerContentAmount()
            local moved = 0
            if s.mode == "load" then
                -- Identical units to ISRefuelFromGasPump: 8 pump units / jerrycan.
                local unitLitres = Vehicles.JerryCanLitres / 8
                local units = s.pump:getPipedFuelAmount()
                moved = F.transferAmount(units * unitLitres, stored, F.CAPACITY, requested)
                s.pump:setPipedFuelAmount(units - moved / unitLitres)
                tank:setContainerContentAmount(stored + moved)
                s.pump:transmitModData()
            elseif s.mode == "vehicle" then
                local amount = s.part:getContainerContentAmount()
                moved = F.transferAmount(stored, amount, s.part:getContainerCapacity(), requested)
                tank:setContainerContentAmount(stored - moved)
                s.part:setContainerContentAmount(amount + moved)
                s.target:transmitPartModData(s.part)
            elseif s.mode == "generator" then
                local g = s.generator
                moved = F.transferAmount(stored, g:getFuel(), g:getMaxFuel(), requested)
                tank:setContainerContentAmount(stored - moved)
                g:setFuel(g:getFuel() + moved)
                g:sync()
            end
            s.truck:transmitPartModData(tank)
            if moved <= 0 then F.sessions[id] = nil end
        end
    end
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module == "JVPActyFuel" then F.serverCommand(player, command, args) end
end)
Events.OnTick.Add(F.tick)
