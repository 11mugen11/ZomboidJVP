-- RE9-only wheel maintenance. Native vehicle actions remain responsible for items.
EmreRE9 = EmreRE9 or {}
EmreRE9.Tires = {}
local T = EmreRE9.Tires
local pairsById = { TireFrontLeft="TireFrontRight", TireRearRight="TireRearLeft" }
local sourceById = { TireFrontRight="TireFrontLeft", TireRearLeft="TireRearRight" }
local shown = setmetatable({}, {__mode="k"})
-- A native physics/model rebuild drops visible model instances even though
-- these same part objects still own their original installed tire items.
function T.Invalidate(vehicle)
    for i=0,vehicle:getPartCount()-1 do shown[vehicle:getPartByIndex(i)]=nil end
end

function T.Refresh(vehicle, part)
    local present = part:getInventoryItem() ~= nil
    if shown[part] == nil or shown[part] ~= present then
        part:setAllModelsVisible(false)
        if pairsById[part:getId()] then
            part:setModelVisible("InflatedTirePlusWheel", present)
        end
        shown[part] = present
    end
    local index = part:getWheelIndex()
    if index >= 0 then vehicle:setTireRemoved(index, not present) end
end

-- Two hidden contact points stabilize the native four-wheel physics chassis.
-- They mirror the real tires and never create a removable spare or extra weight.
function T.SyncSupport(vehicle, real)
    local aux = vehicle:getPartById(pairsById[real:getId()])
    if not aux then return end
    if not isClient() then
        local changed = false
        if real:getInventoryItem() then
            if not aux:getInventoryItem() then
                VehicleUtils.createPartInventoryItem(aux)
                changed = true
            end
            if aux:getCondition() ~= real:getCondition() then
                aux:setCondition(real:getCondition())
                changed = true
            end
            if aux:getContainerContentAmount() ~= real:getContainerContentAmount() then
                aux:setContainerContentAmount(real:getContainerContentAmount(), false, true)
                vehicle:transmitPartModData(aux)
            end
        elseif aux:getInventoryItem() then
            aux:setInventoryItem(nil)
            changed = true
        end
        if changed then vehicle:transmitPartItem(aux) end
    end
    T.Refresh(vehicle, aux)
end

function T.Create(vehicle, part)
    Vehicles.Create.Tire(vehicle, part)
    T.Init(vehicle, part)
end

function T.Init(vehicle, part)
    T.Refresh(vehicle, part)
    T.SyncSupport(vehicle, part)
end

function T.Update(vehicle, part, elapsedMinutes)
    Vehicles.Update.Tire(vehicle, part, elapsedMinutes)
    T.Init(vehicle, part)
end

function T.Support(vehicle, part)
    local source = vehicle:getPartById(sourceById[part:getId()])
    if source then T.SyncSupport(vehicle, source) else T.Refresh(vehicle, part) end
end

function T.BlockMaintenance() return false end

return T
