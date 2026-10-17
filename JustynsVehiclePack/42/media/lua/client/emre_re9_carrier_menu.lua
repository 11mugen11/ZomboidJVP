require "emre_re9_carrier"
require "Vehicles/ISUI/ISVehicleMenu"
require "Vehicles/TimedActions/ISEnterVehicle"
require "emre_re9_carrier_network"
local C = EmreRE9.Carrier
local function notify(player,ok,reason)
    if not ok and player then player:Say(reason or "Unable to use motorcycle carrier") end
end
local function load(player,car,bike)
    local ok,reason = C.Request(player,"load",car,bike)
    notify(player,ok,reason)
end
local function unload(player,car,bike)
    local ok,reason = C.Request(player,"unload",car,bike)
    notify(player,ok,reason)
end
local originalMenu = ISVehicleMenu.doTowingMenu
local function carrierMenu(player,vehicle,menu)
    local record = C.Record(vehicle)
    if record then
        local pair = C.Pair(vehicle)
        if pair and pair.car and pair.bike then
            menu:addSlice((C.IsPlane(pair.car) and "Unload Tenere behind aircraft" or "Unload motorcycle from rear carrier"),getTexture("media/ui/ZoomOut.png"),unload,player,pair.car,pair.bike)
        else
            menu:addSlice("Carrier partner is not loaded",getTexture("media/ui/ZoomOut.png"),nil)
        end
        return true
    end
    if C.IsCar(vehicle) or C.IsBike(vehicle) then
        local other = C.Near(vehicle)
        if other then
            local car,bike = vehicle,other
            if C.IsBike(vehicle) then car,bike = other,vehicle end
            menu:addSlice((C.IsPlane(car) and "Mount Tenere under aircraft" or "Load motorcycle onto rear carrier"),getTexture("media/ui/ZoomIn.png"),load,player,car,bike)
            -- This exact pair uses the carrier instead of the native tow rope.
            return true
        end
    end
    return false
end
function ISVehicleMenu.doTowingMenu(player,vehicle,menu)
    local ok,handled = pcall(carrierMenu,player,vehicle,menu)
    if ok and handled then return end
    -- Keep the native V menu available even if the carrier cannot be queried.
    return originalMenu(player,vehicle,menu)
end
local originalEnter = ISEnterVehicle.isValid
function ISEnterVehicle:isValid()
    if C.IsMounted(self.vehicle) then return false end
    return originalEnter(self)
end
local warned = false
Events.OnTick.Add(function()
    local ok,err = pcall(C.Tick)
    if not ok and not warned then
        warned = true
        print("[EmreRE9] rear carrier update failed: "..tostring(err))
    end
end)
Events.OnGameStart.Add(function() warned=false; C.Reset() end)
if Events.OnRenderTick then Events.OnRenderTick.Add(function()
    local ok,err=pcall(C.Render)
    if not ok and not warned then
        warned=true
        print("[EmreRE9] rear carrier render failed: "..tostring(err))
    end
end) end
if Events.OnSave then Events.OnSave.Add(function() pcall(C.Tick) end) end
