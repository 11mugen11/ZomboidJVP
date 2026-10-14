require "Vehicles/ISUI/ISVehicleSeatUI"
require "Vehicles/ISUI/emre_re9_overlay"

-- Use the Yamaha image only during seat rendering; mechanics keeps its
-- existing part hitboxes and overlay textures.
local render = ISVehicleSeatUI.render
function ISVehicleSeatUI:render()
    local vehicle = self.vehicle
    local script = vehicle and vehicle:getScript()
    if not script or script:getFullName() ~= "Base.JVP_Tenere" then
        return render(self)
    end
    local overlayName = script:getCarMechanicsOverlay() or vehicle:getScriptName()
    local previous = ISCarMechanicsOverlay.CarList[overlayName]
    ISCarMechanicsOverlay.CarList[overlayName] = {imgPrefix="JVP_Tenere_", x=10, y=0}
    local ok, result = pcall(render, self)
    ISCarMechanicsOverlay.CarList[overlayName] = previous
    if not ok then error(result) end
    return result
end
