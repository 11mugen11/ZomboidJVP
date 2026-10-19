require "VehicleZoneDefinition"
if VehicleZoneDistribution then
    for _, zone in ipairs({ "parkingstall", "medium", "good", "junkyard" }) do
        local distribution = VehicleZoneDistribution[zone]
        if distribution and distribution.vehicles then
            distribution.vehicles["Base.JVP_ActyFuelTruck"] = { index = -1, spawnChance = 2 }
        end
    end
end
