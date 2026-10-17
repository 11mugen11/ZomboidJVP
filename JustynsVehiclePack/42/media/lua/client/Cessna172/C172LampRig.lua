require "Cessna172/C172LightSpecs"
C172LampRig = {}
local L = C172LampRig
local records = {}
function L.register(v)
    local id=v:getId()
    if records[id] and records[id].vehicle==v then return end
    records[id]={vehicle=v}
    -- Refresh saved aircraft too. The old rear/reversing light sources are
    -- black and negligible-range; navigation emission now comes only from the lenses.
    for name,spec in pairs(C172LightSpecs) do
        local part=v:getPartById(name)
        if part then part:createSpotLightColor(spec.x,spec.y,spec.dist,spec.intensity,spec.dot,0,spec.r,spec.g,spec.b) end
    end
    if C172Contacts then C172Contacts.aimIfSmall(v) end
end
function L.update(v)
    -- Viewpoint renders standard vehicle emission switches, not custom shaders.
    -- Reuse the Cessna's otherwise unused stop-lamp texture channels for the
    -- engine-on wing lenses. This is only a visual switch, never brake input.
    v:setStoplightsOn(v:isEngineRunning())
    for _,id in ipairs({"HeadlightRearLeft","HeadlightRearRight"}) do
        local part=v:getPartById(id)
        if part and part:getLight() and part:getLight():getActive() then part:setLightActive(false) end
    end
end
function L.frame()
    for id,r in pairs(records) do
        if r.vehicle:isRemovedFromWorld() then records[id]=nil else L.update(r.vehicle) end
    end
end
Events.OnRenderTick.Add(L.frame)
Events.OnGameStart.Add(function() records={} end)
return L
