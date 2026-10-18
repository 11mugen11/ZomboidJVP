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
    -- Hosted clients use the same authoritative network hop as other clients.
    pending[request]={player=player,untilMs=getTimestampMs()+10000}
    print("[JVP RELEASE 1.0.28] request="..request.." command="..command.." car="..tostring(args.car).." bike="..tostring(args.bike).." token="..tostring(args.token))
    sendClientCommand(player,C.NET,command,args)
    return true
end
local function apply(pose)
    local car,bike=getVehicleById(pose.car),getVehicleById(pose.bike)
    if not bike then return false end
    -- Rebuilds can change native mechanical IDs on old clients. An exact
    -- replicated mount/release token still identifies the same real bike.
    -- Wait for pairing packets instead of silently consuming a rejected pose.
    if not C.ReleaseMatches(bike,pose) then return false end
    if car and (not C.IsCar(car) or car:getMechanicalID()~=pose.carKey) then
        local record=C.Record(car)
        if not record or record.token~=pose.token then car=nil end
    end
    return C.ApplyRelease(car,bike,pose)
end
Events.OnServerCommand.Add(function(module,command,args)
    if module~=C.NET or type(args)~="table" then return end
    if command=="result" then
        print("[JVP RELEASE 1.0.28] result="..tostring(args.request).." ok="..tostring(args.ok).." reason="..tostring(args.reason))
        local p=pending[args.request]
        if p then
            if not args.ok then p.player:Say(args.reason or "Carrier request rejected") end
            pending[args.request]=nil
        end
    elseif command=="release" then
        local bike=getVehicleById(args.bike)
        print("[JVP RELEASE 1.0.28] received token="..tostring(args.token).." bike="..tostring(args.bike).." serverKey="..tostring(args.bikeKey).." localKey="..tostring(bike and bike:getMechanicalID()))
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
        if apply(r.pose) then table.remove(releases,i)
        elseif now>=r.untilMs then
            print("[JVP RELEASE 1.0.28] expired unresolved token="..tostring(r.pose.token))
            table.remove(releases,i)
        end
    end
end)
Events.OnGameStart.Add(function() pending,releases={},{} end)
