-- Emre RE9 storage and fixed-body maintenance. Scoped to this vehicle only.
EmreRE9 = EmreRE9 or {}
EmreRE9.Parts = EmreRE9.Parts or {}
EmreRE9.ContainerAccess = EmreRE9.ContainerAccess or {}
local caps = { RE9CaseFrontLeft=50, RE9CaseFrontRight=50, RE9CaseRearLeft=100, RE9CaseRearRight=100, RE9CaseTop=250 }

function EmreRE9.Parts.InitCargo(vehicle, part)
    part:setModelVisible("Default", true)
end

function EmreRE9.Parts.CreateCase(vehicle, part)
    local cap = caps[part:getId()]
    if cap then
        part:setContainerCapacity(cap)
        part:setCondition(100)
    end
end

function EmreRE9.Parts.InitCase(vehicle, part)
    local cap = caps[part:getId()]
    if cap then part:setContainerCapacity(cap) end
end

function EmreRE9.ContainerAccess.Case(vehicle, part, character)
    if not vehicle or not character then return false end
    if character:getVehicle() == vehicle then return true end
    local dx,dy=character:getX()-vehicle:getX(),character:getY()-vehicle:getY()
    return dx*dx+dy*dy <= 9
end

function EmreRE9.Parts.CreateBodyPart(vehicle, part)
    if not part:getInventoryItem() then VehicleUtils.createPartInventoryItem(part) end
end

function EmreRE9.Parts.InitBodyPart(vehicle, part)
    -- Exhaust geometry is integral to the body; engine mechanics still use its item.
end


function EmreRE9.ContainerAccess.Never() return false end
function EmreRE9.Parts.Door(vehicle, part)
    part:setInventoryItem(nil)
    if part:getDoor() then
        part:getDoor():setLocked(false)
        part:getDoor():setOpen(true)
    end
end

-- A new seat is initialized once on existing saves. Removing it later is
-- respected: the persisted flag prevents a free replacement on every load.
function EmreRE9.Parts.CreatePassengerSeat(vehicle, part)
    VehicleUtils.createPartInventoryItem(part)
    part:getModData().re9PassengerSeatInitialized = true
    part:setModelVisible("Default", part:getInventoryItem() ~= nil)
end
function EmreRE9.Parts.InitPassengerSeat(vehicle, part)
    if isClient() then
        part:setModelVisible("Default", part:getInventoryItem() ~= nil)
        return
    end
    if not part:getModData().re9PassengerSeatInitialized then
        if not part:getInventoryItem() then VehicleUtils.createPartInventoryItem(part) end
        part:getModData().re9PassengerSeatInitialized = true
    end
    part:setModelVisible("Default", part:getInventoryItem() ~= nil)
end
return EmreRE9
