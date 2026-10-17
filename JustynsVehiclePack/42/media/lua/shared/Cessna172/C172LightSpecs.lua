--[[
    C172LightSpecs - the four light parts' beams, in one place (1.9.0).

    Read by C172Lights (server/, where the parts are built) and by C172Contacts (client/,
    which re-aims them while the ground footprint is shrunk for flight - a part light sits at
    its offset x HALF the script extents, so the footprint change would otherwise throw the
    beams behind the aircraft). The numbers and their reasons are unchanged; see C172Lights.

    Keyed by part id. x / y are multiples of half the extents (x = across, +x the pilot's left;
    y = along, +y forward).
]]
C172LightSpecs = C172LightSpecs or {}

C172LightSpecs.HeadlightLeft = { x =  0.34, y =  0.10, dist = 110, intensity = 2.80, dot = 0.25,
                                 r = 1.00, g = 0.97, b = 0.90 }   -- landing light
C172LightSpecs.HeadlightRight = { x = -0.34, y =  0.10, dist = 90, intensity = 2.40, dot = 0.20,
                                  r = 1.00, g = 0.96, b = 0.85 }  -- taxi light
C172LightSpecs.HeadlightRearLeft = { x =  0.00, y =  0.00, dist = 0.1, intensity = 0.00, dot = 0.90,
                                     r = 0.00, g = 0.00, b = 0.00 }   -- red nav light, port
C172LightSpecs.HeadlightRearRight = { x =  0.00, y =  0.00, dist = 0.1, intensity = 0.00, dot = 0.90,
                                      r = 0.00, g = 0.00, b = 0.00 }  -- green nav light, starboard

return C172LightSpecs
