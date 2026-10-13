-- Fitted pickup-derived cabin; removable seats use the native Seat part models.
JVPDiscoveryInterior = JVPDiscoveryInterior or {}
function JVPDiscoveryInterior.Init(vehicle,part)
    part:setModelVisible("Default",true)
end
