require "Vehicles/VehicleDistributions"
local empty={rolls=0,items={}}
VehicleDistributions.EmreRE9Cases={
    RE9CaseFrontLeft=empty,RE9CaseFrontRight=empty,
    RE9CaseRearLeft=empty,RE9CaseRearRight=empty,
    SeatFrontLeft=empty,
}
if VehicleDistributions[1] then
    VehicleDistributions[1].EMRE_RE9={Normal=VehicleDistributions.EmreRE9Cases}
    VehicleDistributions[1].JVP_Tenere=VehicleDistributions[1].EMRE_RE9
end
