-- The Camel model has no separate roof-rack container: use 450 in its trunk.
-- Existing vehicles receive the capacity on load without replacing their loot.
LRDiscoCamelStorage = LRDiscoCamelStorage or {}

function LRDiscoCamelStorage.Init(vehicle, part)
    if not vehicle or not vehicle:getScript()
        or vehicle:getScript():getFullName() ~= "Base.lrdisco1camel"
        or not part or part:getId() ~= "TruckBed" then return end
    local item = part:getInventoryItem()
    if item then item:setMaxCapacity(450) end
    part:setContainerCapacity(450)
end

function LRDiscoCamelStorage.Create(vehicle, part)
    Vehicles.Create.Default(vehicle, part)
    LRDiscoCamelStorage.Init(vehicle, part)
end
