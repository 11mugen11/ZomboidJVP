-- Native replaceable bulbs, power consumption and headlight switch.
-- One centered front spotlight: shorter reach and a narrower forward cone.
-- Keep native bulb condition, battery drain and the existing rear lamp.
EmreRE9 = EmreRE9 or {}
EmreRE9.Lights = {}
local L = EmreRE9.Lights

function L.Init(vehicle, part)
    if not part:getInventoryItem() then return end
    if part:getId() == "HeadlightLeft" then
        part:createSpotLight(0, 0.49, 24, 0.65, 0.90, 0)
    elseif part:getId() == "HeadlightRearLeft" then
        part:createSpotLightColor(0, -0.88, 3, 0.2, 0.75, 0, 1, 0.15, 0.1)
    end
end

function L.Create(vehicle, part)
    Vehicles.Create.Headlight(vehicle, part)
    L.Init(vehicle, part)
end
return L
