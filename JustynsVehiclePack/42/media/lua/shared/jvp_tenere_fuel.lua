-- Tenere-only fuel callbacks. VehicleParts invokes update on the server/SP,
-- with elapsed GAME minutes; Bullet road speed is km per REAL hour.
EmreRE9 = EmreRE9 or {}
EmreRE9.TenereFuel = {}
local F = EmreRE9.TenereFuel
local function isTenere(vehicle)
    local name = vehicle:getScript():getFullName()
    return name == "Base.JVP_Tenere" or name == "Base.JVP_TenereCarrier"
        or name == "Base.JVP_TenereAircraft"
end

function F.InitTank(vehicle, part)
    if not isTenere(vehicle) then return end
    local item = part:getInventoryItem()
    if not item then return end
    -- Upgrade saved 18L tanks in place: retain identity, condition and fuel.
    -- Native getContainerCapacity reads the installed item's max capacity;
    -- setContainerCapacity alone does not change a liquid vehicle tank.
    if item:getMaxCapacity() ~= 23 then
        item:setMaxCapacity(23)
        if not isClient() then vehicle:transmitPartItem(part) end
    end
end

function F.CreateTank(vehicle, part)
    Vehicles.Create.GasTank(vehicle, part)
    F.InitTank(vehicle, part)
end

function F.UpdateTank(vehicle, part, elapsedMinutes)
    if isClient() or not isTenere(vehicle) then return end
    F.InitTank(vehicle, part)
    if vehicle:getScript():getFullName() ~= "Base.JVP_Tenere" then return end
    if not part:getInventoryItem() or elapsedMinutes <= 0
        or not vehicle:isEngineRunning() then return end
    local amount = part:getContainerContentAmount()
    if amount <= 0 then return end

    -- 235.214583 / 50 MPG = 4.70429 L/100km. Convert game minutes
    -- back to real hours so changing day length does not change road range.
    local hours = elapsedMinutes * getGameTime():getMinutesPerDay() / 86400
    local speed = math.abs(vehicle:getCurrentSpeedKmHour())
    local litersPerKm = 235.214583 / 50 / 100
    local highway = 1 + math.max(0, speed - 80) / 600
    local wear = 1 + math.max(0, 75 - vehicle:getEngineQuality()) / 750
    local litersPerHour = math.max(0.4, speed * litersPerKm * highway) * wear
    local used = litersPerHour * hours * SandboxVars.CarGasConsumption

    -- Retain the native damaged-tank leak independently of road economy.
    if part:getCondition() < 70 and ZombRand(part:getCondition() * 2) == 0 then
        used = used + 0.01
    end
    part:setContainerContentAmount(math.max(0, amount - used), false, true)
    local precision = (part:getContainerContentAmount() < 0.5) and 2 or 1
    if VehicleUtils.compareFloats(amount, part:getContainerContentAmount(), precision) then
        vehicle:transmitPartModData(part)
    end
end
