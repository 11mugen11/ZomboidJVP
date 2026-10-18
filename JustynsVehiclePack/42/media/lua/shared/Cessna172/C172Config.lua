require "Cessna172/C172Variants"
--[[
    C172Config - the Cessna 172's own stat table.

    ISOLATION, DELIBERATELY. This is an independent file with an independent global name
    (C172Config) at an independent module path (Cessna172/C172Config). Two mods each
    shipping a file at the same relative require() path collide - only one copy actually
    loads - which is exactly why the MiG-29 mod did the same thing when it split from
    AircraftMod. Nothing here reads or writes AircraftConfig (the VX-9 Wraith's) or
    JetConfig (the MiG-29's), and neither of those can see this.

    Keyed by the vehicle's full VehicleScript name so getScriptName() on a spawned
    vehicle can look itself up here. That key is the single gate that decides whether any
    of this mod's flight code runs for a given vehicle: a MiG, a Wraith, a vanilla car
    and a walking player all miss it and every code path returns immediately.
]]
C172Config = C172Config or {}
C172Config.registry = C172Config.registry or {}

C172Config.registry["Base.Cessna172"] = {
    displayName = "Cessna 172",

    -- category = "prop" - C172Flight.lua's light-aircraft flight model. Deliberately a
    -- DIFFERENT string from the MiG's "fixedwing", so that even if some future refactor
    -- ever did put the two registries in reach of each other, neither controller could
    -- pick up the other aircraft: each checks for its own category by name.
    category = "prop",

    -- Simulated altitude, in "flight units". C172Flight.lua maps these onto a real
    -- Bullet body height through LIFT_HEIGHT_SCALE (1.7 m per unit). 4.0 units = 6.8 m
    -- real, plus this airframe's own 1.75-unit height, is 8.55 m against PZ's ~13.7 m
    -- vehicle render-cull threshold - a ~5 m margin, so the aircraft cannot vanish at
    -- its ceiling. Lower than the MiG's 6.0 on purpose: a 172 is not a high flyer.
    -- NOT AUTHORITATIVE, and nothing reads it. The live flight values are the TUNE table
    -- in C172Flight.lua; this registry keeps the same shape as the sibling aircraft mods'
    -- so the shared identification helpers stay interchangeable. Kept in sync by hand so a
    -- reader is not misled - if these two ever disagree, TUNE is the one that flies.
    maxAltitude = 8.5,

    -- A light aircraft climbs slowly. These are the ceiling values the controller eases
    -- toward, not instant rates - see VS_RAMP in C172Flight.lua.
    climbRatePerSecond = 2.4,
    descendRatePerSecond = 3.6,

    -- Ground speed (km/h, read from the vehicle's REAL physics, not simulated) required
    -- before the aircraft will rotate - the default of the Takeoff speed sandbox option, used
    -- when the option cannot be read (C172Flight takeoffKmh). 55 until 10-06; Jay: "its to much".
    minTakeoffSpeedKmh = 45,

    -- Landing succeeds only if, at the moment altitude reaches 0, speed and descent rate
    -- are both under these. Wider tolerances than the MiG's (90 / 10) because a light
    -- aircraft's whole point is that it can be put down slowly and gently.
    maxSafeLandingSpeedKmh = 70,
    maxSafeLandingDescentRate = 8,

    -- Extra fuel (litres/second) burned on top of normal engine consumption while
    -- airborne. Superseded in practice by C172Fuel.lua's flat, real-time-calibrated burn
    -- model - kept for parity with the registry shape the rest of the code reads.
    flightFuelDrainPerSecond = 0.012,

    -- Condition (0-1) knocked off the airframe on a hard or crashed landing, scaled by
    -- how far outside the safe limits above the touchdown was.
    crashConditionLoss = 0.30,
    hardLandingConditionLoss = 0.08,
}

for _,id in ipairs(C172Variants.ids) do C172Config.registry[id]=C172Config.registry["Base.Cessna172"] end

function C172Config.get(scriptName)
    return C172Config.registry[scriptName]
end

-- True only for aircraft this mod's flight controller is allowed to drive.
function C172Config.isProp(scriptName)
    local cfg = C172Config.registry[scriptName]
    return cfg ~= nil and cfg.category == "prop"
end

return C172Config
