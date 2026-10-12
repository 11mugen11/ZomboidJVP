require "emre_re9_carrier"
local C=EmreRE9.Carrier
local serial,pending,releases=0,{},{}
function C.Request(player,command,car,bike)
    if not car or not bike then return false,"Vehicles are not loaded" end
    if not isClient() then return (command=="load" and C.Load or C.Unload)(player,car,bike) end
    serial=serial+1
    local request=tostring(player:getPlayerNum())..":"..tostring(serial)
    local record=C.Record(car)
    local args={car=car:getId(),bike=bike:getId(),token=record and record.token,request=request}
    -- Some hosted sessions share their Lua VM with server handlers. Dedicated
    -- clients have no ServerCommand function and use the normal network hop.
    if isCoopHost and isCoopHost() and C.ServerCommand then
        return C.ServerCommand(player,command,args)
    end
    pending[request]={player=player,untilMs=getTimestampMs()+10000}
    sendClientCommand(player,C.NET,command,args)
    return true
end
local function apply(pose)
    local car,bike=getVehicleById(pose.car),getVehicleById(pose.bike)
    if not bike then return false end
    -- Network vehicle IDs can be reused after a vehicle is unloaded; persistent
    -- mechanical IDs prevent delayed releases from affecting a different bike.
    if not C.IsBike(bike) or bike:getMechanicalID()~=pose.bikeKey then return true end
    if car and (not C.IsCar(car) or car:getMechanicalID()~=pose.carKey) then return true end
    C.ApplyRelease(car,bike,pose)
    return true
end
Events.OnServerCommand.Add(function(module,command,args)
    if module~=C.NET or type(args)~="table" then return end
    if command=="result" then
        local p=pending[args.request]
        if p then
            if not args.ok then p.player:Say(args.reason or "Carrier request rejected") end
            pending[args.request]=nil
        end
    elseif command=="release" then
        if not apply(args) then releases[#releases+1]={pose=args,untilMs=getTimestampMs()+30000} end
    end
end)
Events.OnTick.Add(function()
    if not isClient() then return end
    local now=getTimestampMs()
    for request,p in pairs(pending) do
        if now>=p.untilMs then
            p.player:Say("Carrier request timed out; check that the server has the same mod version")
            pending[request]=nil
        end
    end
    for i=#releases,1,-1 do
        local r=releases[i]
        if apply(r.pose) or now>=r.untilMs then table.remove(releases,i) end
    end
end)
Events.OnGameStart.Add(function() pending,releases={},{} end)
