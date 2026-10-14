require "VehicleZoneDefinition"

-- Add this vehicle to existing suitable pools; never create parking zones or
-- change vanilla zone-wide spawnRate/quality settings. Values are weights.
EmreRE9Spawn = EmreRE9Spawn or {}
local S = EmreRE9Spawn
local id = "Base.EMRE_RE9"
S.weights = {
    parkingstall=4, bad=4, struggling=4, medium=3, good=2,
    trailerpark=5, farm=5, junkyard=2,
    trafficjamn=1, trafficjame=1, trafficjamw=1, trafficjams=1,
}
local multipliers = {0.35, 1.0, 3.0}

function S.apply()
    if type(VehicleZoneDistribution) ~= "table" then return 0 end
    local options = SandboxVars and SandboxVars.EmreRE9 or {}
    local enabled = options.EnableSpawns ~= false
    local multiplier = multipliers[tonumber(options.SpawnFrequency)] or 1.0
    local count = 0
    for zone, weight in pairs(S.weights) do
        local pool = VehicleZoneDistribution[zone]
        if type(pool) == "table" and type(pool.vehicles) == "table" then
            pool.vehicles[id] = enabled and {index=-1, spawnChance=weight*multiplier} or nil
            pool.vehicles["Base.JVP_Tenere"] = enabled and {index=-1, spawnChance=weight*multiplier} or nil
            count = count+1
        end
    end
    return count
end

-- File load handles early native consumers. Later hooks reapply after vanilla
-- tables and world-specific SandboxVars have loaded. Assign, do not accumulate.
S.apply()
if not S.registered then
    S.registered = true
    Events.OnGameBoot.Add(S.apply)
    Events.OnPreDistributionMerge.Add(S.apply)
    Events.OnInitGlobalModData.Add(function()
        local count = S.apply()
        local options = SandboxVars and SandboxVars.EmreRE9 or {}
        print("[EmreRE9 0.2.15] spawn pools=" .. tostring(count)
            .. " enabled=" .. tostring(options.EnableSpawns ~= false)
            .. " frequency=" .. tostring(options.SpawnFrequency or 2))
    end)
end
return S
