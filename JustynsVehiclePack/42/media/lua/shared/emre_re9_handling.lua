-- The part lua block replaces the inherited callback map. v0.2.14 had only
-- init, so native Create.Engine never assigned power/quality on new bikes.
-- The vehicle script now restores ALL native engine callbacks. This init
-- repairs already-saved zero-power bikes without rerolling part condition.
EmreRE9 = EmreRE9 or {}
EmreRE9.Handling = {}

function EmreRE9.Handling.InitEngine(vehicle, part)
    if isClient() or not vehicle or vehicle:getScript():getFullName() ~= "Base.EMRE_RE9" then return end
    local script = vehicle:getScript()
    local quality = vehicle:getEngineQuality()
    local factor = math.max(0.6, math.min(100, quality * 1.6) / 100)
    local oldPower = vehicle:getEnginePower()
    local target = script:getEngineForce()
    if target > 0 and (oldPower <= 0 or math.abs(oldPower - 2200 * factor) <= 1
        or math.abs(oldPower - 700 * factor) <= 1) then
        if oldPower <= 0 and quality <= 0 then quality = script:getEngineQuality() end
        factor = math.max(0.6, math.min(100, quality * 1.6) / 100)
        -- Supply the same unscaled loudness input as Vehicles.Create.Engine;
        -- getEngineLoudness() is already scaled internally, so do not roundtrip it.
        local loudness = (script:getEngineLoudness() or 100)
            * ((SandboxVars and SandboxVars.ZombieAttractionMultiplier) or 1)
        vehicle:setEngineFeature(quality, loudness, math.floor(target * factor))
        vehicle:transmitEngine()
        print("[EmreRE9 0.2.15] engine feature restored: power=" .. tostring(oldPower)
            .. " -> " .. tostring(vehicle:getEnginePower()) .. " quality=" .. tostring(quality))
    end
    -- Update only the old stock chassis. updateTotalMass adds the actual
    -- installed parts and cargo; neither their weight nor contents are reset.
    if math.abs(vehicle:getInitialMass() - 200) < 0.1 then
        vehicle:setInitialMass(vehicle:getScript():getMass())
        vehicle:updateTotalMass()
    end
end
