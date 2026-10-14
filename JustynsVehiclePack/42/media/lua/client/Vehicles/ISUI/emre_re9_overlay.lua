require "Vehicles/ISUI/ISCarMechanicsOverlay"
ISCarMechanicsOverlay.CarList["Base.EMRE_RE9"]={imgPrefix="EMRE_RE9_",x=10,y=0}
local layout={
    Battery={img="battery",x=14,y=150,x2=60,y2=182},
    SuspensionFrontLeft={img="suspension_front_left",x=14,y=57,x2=54,y2=94},
    SuspensionRearRight={img="suspension_rear_right",x=14,y=200,x2=54,y2=238},
    BrakeFrontLeft={img="brake_front_left",x=14,y=94,x2=54,y2=132},
    BrakeRearRight={img="brake_rear_right",x=14,y=238,x2=54,y2=274},
    Engine={img="engine",x=196,y=57,x2=268,y2=100},
    HeadlightLeft={img="headlight_left",x=128,y=114,x2=153,y2=132},
    Muffler={img="muffler",x=232,y=245,x2=268,y2=315},
    TireFrontLeft={img="wheel_moto_front",x=132,y=57,x2=149,y2=77},
    TireRearRight={img="wheel_moto_rear",x=14,y=274,x2=54,y2=313},
    GasTank={img="gastank",x=206,y=192,x2=268,y2=232},
}
for id,values in pairs(layout) do
    local part=ISCarMechanicsOverlay.PartList[id]
    if part then
        part.vehicles=part.vehicles or {}
        part.vehicles["EMRE_RE9_"]=values
    end
end

ISCarMechanicsOverlay.CarList["Base.JVP_Tenere"]={imgPrefix="EMRE_RE9_",x=10,y=0}
