-- Petrol is stored as litres in a dedicated VehiclePart, never as an item/water tank.
JVPActyFuel = JVPActyFuel or {}
local F = JVPActyFuel
F.SCRIPT = "Base.JVP_ActyFuelTruck"
F.PART = "JVP_ExternalFuelTank"
F.CAPACITY = 2000
F.RANGE = 4 -- vanilla ISVehiclePartMenu.getNearbyFuelPump scans -2..2 on each axis
F.RATE = 8 -- litres per real second; server controls all movement

function F.isTruck(vehicle)
    return vehicle and vehicle:getScriptName() == F.SCRIPT
end

function F.tank(vehicle)
    return F.isTruck(vehicle) and vehicle:getPartById(F.PART) or nil
end

function F.point(vehicle, part)
    if not vehicle or not part then return nil end
    return vehicle:getAreaCenter(part:getArea())
end

function F.inRange(ax, ay, az, bx, by, bz, range)
    return math.floor(az) == math.floor(bz)
        and math.abs(math.floor(ax) - math.floor(bx)) <= range
        and math.abs(math.floor(ay) - math.floor(by)) <= range
end

function F.hoseReaches(truck, vehicle, part)
    local a = F.point(truck, F.tank(truck))
    local b = F.point(vehicle, part)
    return a and b and F.inRange(a:getX(), a:getY(), truck:getZ(),
        b:getX(), b:getY(), vehicle:getZ(), F.RANGE)
end

function F.nearPoint(player, x, y, z)
    return F.inRange(player:getX(), player:getY(), player:getZ(), x, y, z, 2)
end

function F.powered(pump)
    local square = pump and pump:getSquare()
    return square and (square:hasGridPower()
        or (SandboxVars.AllowExteriorGenerator and square:haveElectricity()))
end

function F.findPump(truck)
    local p = F.point(truck, F.tank(truck))
    if not p then return nil end
    for dy = -2, 2 do
        for dx = -2, 2 do
            local square = getCell():getGridSquare(math.floor(p:getX()) + dx,
                math.floor(p:getY()) + dy, math.floor(truck:getZ()))
            if square then
                local objects = square:getObjects()
                for i = 0, objects:size() - 1 do
                    local obj = objects:get(i)
                    if obj:getPipedFuelAmount() > 0 and F.powered(obj) then return obj end
                end
            end
        end
    end
end

function F.InitTank(vehicle, part)
    -- No inventory item, uninstall callback, fluid mixer or engine check is attached.
    part:setModelVisible("Default", true)
end

function F.CreateTank(vehicle, part)
    part:setCondition(100)
    part:setContainerContentAmount(0)
    F.InitTank(vehicle, part)
end

-- Pure arithmetic shared by the authority and regression tests.
function F.transferAmount(available, current, capacity, requested)
    return math.max(0, math.min(available, capacity - current, requested))
end
