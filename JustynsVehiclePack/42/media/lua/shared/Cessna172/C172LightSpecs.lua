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

C172LightSpecs.HeadlightLeft = { x =  1.20, y =  3.20, dist = 38, intensity = 0.62, dot = 0.72,
                                 r = 1.00, g = 0.97, b = 0.90 }   -- landing light
C172LightSpecs.HeadlightRight = { x =  1.45, y =  2.70, dist = 16, intensity = 0.38, dot = 0.42,
                                  r = 1.00, g = 0.96, b = 0.85 }  -- taxi light
C172LightSpecs.HeadlightRearLeft = { x =  3.00, y =  0.10, dist = 2, intensity = 0.06, dot = 0.90,
                                     r = 1.00, g = 0.13, b = 0.13 }   -- red nav light, port
C172LightSpecs.HeadlightRearRight = { x = -3.00, y =  0.10, dist = 2, intensity = 0.06, dot = 0.90,
                                      r = 0.13, g = 1.00, b = 0.25 }  -- green nav light, starboard

return C172LightSpecs
