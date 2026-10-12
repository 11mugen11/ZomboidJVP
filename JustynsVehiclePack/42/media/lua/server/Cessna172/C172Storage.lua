-- Cessna baggage capacity, including aircraft already saved in a world.
-- Keep the native trunk item, access rules, contents and part condition.
C172Storage = C172Storage or {}

function C172Storage.Init(vehicle, part)
    if not vehicle or vehicle:getScriptName() ~= "Base.Cessna172"
        or not part or part:getId() ~= "TruckBed" then return end
    -- Native part-stat updates derive capacity from the installed trunk item.
    -- Change this item's capacity too so repairs cannot restore the old limit.
    local item = part:getInventoryItem()
    if item then item:setMaxCapacity(800) end
    part:setContainerCapacity(800)
end

function C172Storage.Create(vehicle, part)
    Vehicles.Create.Default(vehicle, part)
    C172Storage.Init(vehicle, part)
end
