local function info()

	ISCarMechanicsOverlay.CarList["Base.lrdisco1"] = {imgPrefix = "suv_", x=10,y=0};
	ISCarMechanicsOverlay.CarList["Base.lrdisco1camel"] = {imgPrefix = "suv_", x=10,y=0};
	ISCarMechanicsOverlay.CarList["Base.lrdisco1bbar"] = {imgPrefix = "suv_", x=10,y=0};

end


Events.OnInitWorld.Add(info);