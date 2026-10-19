require "JVPActyFuel"
require "Vehicles/ISUI/ISVehicleMenu"
require "Vehicles/ISUI/ISVehiclePartMenu"
require "Vehicles/ISUI/ISVehicleMechanics"
require "TimedActions/ISBaseTimedAction"
require "TimedActions/ISTimedActionQueue"
require "Vehicles/TimedActions/ISPathFindAction"

local F = JVPActyFuel
local function vehicleSnapshot()
    -- Build 42 returns a Set; indexed get() exists only on the snapshot.
    local snapshot = ArrayList.new()
    snapshot:addAll(getCell():getVehicles())
    return snapshot
end
local function command(player, name, args)
    if isClient() then sendClientCommand(player, "JVPActyFuel", name, args or {})
    else F.serverCommand(player, name, args or {}) end
end

JVPActyFuelAction = ISBaseTimedAction:derive("JVPActyFuelAction")
function JVPActyFuelAction:isValid()
    local tank = F.tank(self.truck)
    if not tank or self.character:getVehicle() or math.abs(self.truck:getCurrentSpeedKmHour()) > 1 then return false end
    if self.args.mode == "load" then
        return tank:getContainerContentAmount() < F.CAPACITY and F.powered(self.object)
            and self.object:getPipedFuelAmount() > 0
    end
    if not self.truck:isEngineRunning() or tank:getContainerContentAmount() <= 0 then return false end
    if self.args.mode == "vehicle" then
        local p = self.object:getPartById("GasTank")
        return p and p:getInventoryItem() and not self.object:isEngineStarted()
            and F.hoseReaches(self.truck, self.object, p)
            and p:getContainerContentAmount() < p:getContainerCapacity()
    end
    return self.object:getObjectIndex() ~= -1 and not self.object:isActivated()
        and self.object:getFuel() < self.object:getMaxFuel()
end
function JVPActyFuelAction:waitToStart()
    self.character:faceThisObject(self.object)
    return self.character:shouldBeTurning()
end
function JVPActyFuelAction:start()
    self:setActionAnim("fill_container_tap")
    self:setOverrideHandModels(nil, nil)
    self.sound = self.character:playSound("VehicleAddFuelFromGasPump")
    command(self.character, "start", self.args)
    self.lastKeepalive = getTimestampMs()
end
function JVPActyFuelAction:update()
    self.character:faceThisObject(self.object)
    if getTimestampMs() - self.lastKeepalive > 750 then
        command(self.character, "keepalive")
        self.lastKeepalive = getTimestampMs()
    end
end
function JVPActyFuelAction:stop()
    command(self.character, "stop")
    if self.sound then self.character:stopOrTriggerSound(self.sound) end
    ISBaseTimedAction.stop(self)
end
function JVPActyFuelAction:perform()
    command(self.character, "stop")
    if self.sound then self.character:stopOrTriggerSound(self.sound) end
    ISBaseTimedAction.perform(self)
end
function JVPActyFuelAction:new(player, truck, mode, object)
    local o = ISBaseTimedAction.new(self, player)
    o.truck, o.object = truck, object
    o.args = { truck = truck:getId(), mode = mode }
    if mode == "vehicle" then o.args.target = object:getId()
    else
        o.args.x, o.args.y, o.args.z = object:getX(), object:getY(), object:getZ()
        o.args.index = object:getObjectIndex()
    end
    o.maxTime = -1
    return o
end

function F.queue(player, truck, mode, object)
    if player:getVehicle() then ISVehicleMenu.onExit(player) end
    if mode == "vehicle" then
        ISTimedActionQueue.add(ISPathFindAction:pathToVehicleArea(player, object, object:getPartById("GasTank"):getArea()))
    elseif mode == "load" then
        ISTimedActionQueue.add(ISPathFindAction:pathToVehicleArea(player, truck, F.tank(truck):getArea()))
    else
        if not luautils.walkAdj(player, object:getSquare()) then return end
    end
    ISTimedActionQueue.add(JVPActyFuelAction:new(player, truck, mode, object))
end

local function entry(context, slice, label, callback, player, truck, mode, object, enabled)
    if slice then
        if enabled then
            slice:addSlice(label, getTexture("media/ui/vehicles/vehicle_refuel_from_pump.png"), callback, player, truck, mode, object)
        end
    else
        local option = context:addOption(label, player, callback, truck, mode, object)
        option.notAvailable = not enabled
        return option
    end
end

local function canDispense(truck)
    local tank = F.tank(truck)
    return tank and truck:isEngineRunning() and math.abs(truck:getCurrentSpeedKmHour()) <= 1
        and tank:getContainerContentAmount() > 0
end

local function addVehicleSource(context, slice, player, truck, vehicle)
    local part = vehicle:getPartById("GasTank")
    if vehicle == truck or not part or not part:getInventoryItem() or not F.hoseReaches(truck, vehicle, part) then return end
    local label = "Pump from Acty EXTERNAL bed tank -> " .. getText("IGUI_VehicleName" .. vehicle:getScript():getName())
    entry(context, slice, label, F.queue, player, truck, "vehicle", vehicle,
        canDispense(truck) and not vehicle:isEngineStarted()
            and part:getContainerContentAmount() < part:getContainerCapacity())
end

local oldFill = ISVehicleMenu.FillPartMenu
function ISVehicleMenu.FillPartMenu(playerIndex, context, slice, vehicle)
    local player = getSpecificPlayer(playerIndex)
    if not F.isTruck(vehicle) then
        oldFill(playerIndex, context, slice, vehicle)
        local vehicles = vehicleSnapshot()
        for i = 0, vehicles:size() - 1 do
            local truck = vehicles:get(i)
            if F.isTruck(truck) then addVehicleSource(context, slice, player, truck, vehicle) end
        end
        return
    end
    if player:DistToProper(vehicle) >= 4 then return end
    local internal = vehicle:getPartById("GasTank")
    local tank = F.tank(vehicle)
    if not tank then return end
    local internalMenu, externalMenu = context, context
    if not slice then
        local a = context:addOption(string.format("ENGINE fuel tank (%.1f / %.1f L)",
            internal:getContainerContentAmount(), internal:getContainerCapacity()), nil, nil)
        internalMenu = ISContextMenu:getNew(context)
        context:addSubMenu(a, internalMenu)
        local b = context:addOption(string.format("EXTERNAL bed tank - PETROL ONLY (%.1f / 2000 L)",
            tank:getContainerContentAmount()), nil, nil)
        externalMenu = ISContextMenu:getNew(context)
        context:addSubMenu(b, externalMenu)
        local status = externalMenu:addOption("Pump requires Acty engine running | Hose reach: 4 tiles", nil, nil)
        status.notAvailable = true
    end
    if internal:getInventoryItem() and not vehicle:isEngineStarted() then
        if slice then
            slice:addSlice("Fill ENGINE fuel tank from can", getTexture("media/ui/vehicles/gas_refuel.png"),
                ISVehiclePartMenu.onAddGasoline, player, internal)
        else ISVehiclePartMenu.doAddFuelMenu(player, internal, internalMenu) end
        local enginePump = ISVehiclePartMenu.getNearbyFuelPump(vehicle)
        if enginePump and F.powered(enginePump) then
            entry(internalMenu, slice, "Fill ENGINE fuel tank from station", function(p)
                ISVehiclePartMenu.onPumpGasoline(p, internal)
            end, player, vehicle, nil, nil, true)
        end
    end
    local pump = F.findPump(vehicle)
    if pump then
        entry(externalMenu, slice, "Fill EXTERNAL 2000 L bed tank from station", F.queue,
            player, vehicle, "load", pump, tank:getContainerContentAmount() < F.CAPACITY)
    end
    local vehicles = vehicleSnapshot()
    for i = 0, vehicles:size() - 1 do
        addVehicleSource(externalMenu, slice, player, vehicle, vehicles:get(i))
    end
    local inlet = F.point(vehicle, tank)
    if inlet then
        for y = -F.RANGE, F.RANGE do
            for x = -F.RANGE, F.RANGE do
                local sq = getCell():getGridSquare(math.floor(inlet:getX()) + x,
                    math.floor(inlet:getY()) + y, math.floor(vehicle:getZ()))
                if sq then
                    local objects = sq:getObjects()
                    for j = 0, objects:size() - 1 do
                        local g = objects:get(j)
                        if instanceof(g, "IsoGenerator") then
                            entry(externalMenu, slice, "Pump EXTERNAL fuel -> generator", F.queue,
                                player, vehicle, "generator", g, canDispense(vehicle)
                                    and not g:isActivated() and g:getFuel() < g:getMaxFuel())
                        end
                    end
                end
            end
        end
    end
end

Events.OnFillWorldObjectContextMenu.Add(function(playerIndex, context, worldobjects, test)
    if test then return end
    local player = getSpecificPlayer(playerIndex)
    local seen = {}
    for _, obj in ipairs(worldobjects) do
        local sq = obj:getSquare()
        if sq then
            local objects = sq:getObjects()
            for j = 0, objects:size() - 1 do
                local g = objects:get(j)
                if instanceof(g, "IsoGenerator") and not seen[g] then
                    seen[g] = true
                    local vehicles = vehicleSnapshot()
                    for i = 0, vehicles:size() - 1 do
                        local truck = vehicles:get(i)
                        local inlet = F.point(truck, F.tank(truck))
                        if inlet and F.inRange(inlet:getX(), inlet:getY(), truck:getZ(), g:getX(), g:getY(), g:getZ(), F.RANGE) then
                            entry(context, nil, "Refuel generator from Acty EXTERNAL bed tank", F.queue,
                                player, truck, "generator", g, canDispense(truck)
                                    and not g:isActivated() and g:getFuel() < g:getMaxFuel())
                        end
                    end
                end
            end
        end
    end
end)

-- Scope the name change to this truck; do not rename every vanilla GasTank.
local oldInitParts = ISVehicleMechanics.initParts
function ISVehicleMechanics:initParts(...)
    oldInitParts(self, ...)
    if F.isTruck(self.vehicle) then
        for _, list in ipairs({ self.listbox, self.bodyworklist }) do
            for _, item in ipairs(list.items) do
                local row = item.item
                if row.part and row.part:getId() == "GasTank" then
                    row.name = "Engine fuel tank (driving only)"
                    item.text = row.name
                end
            end
        end
    end
end

Events.OnInitWorld.Add(function()
    ISCarMechanicsOverlay.CarList[F.SCRIPT] = { imgPrefix = "JVP_Acty_", x = 10, y = 0 }
end)
