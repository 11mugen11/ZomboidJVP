require "emre_re9_carrier"
local C = EmreRE9.Carrier
local throttle = setmetatable({}, {__mode="k"})
local function id(value)
    return type(value)=="number" and value>=-32768 and value<=32767 and value~=-1 and value==math.floor(value)
end
local function reply(player,request,ok,reason)
    if isServer() then
        sendServerCommand(player,C.NET,"result",{request=request or "",ok=ok,reason=reason or ""})
    end
end
function C.ServerCommand(player,command,args)
    if command ~= "load" and command ~= "unload" then return false,"Unknown carrier command" end
    if not player or player:isDead() or type(args) ~= "table" or not id(args.car) or not id(args.bike) then
        return false,"Invalid carrier request"
    end
    local now = getTimestampMs()
    if now<(throttle[player] or 0) then return false,"Wait a moment before using the carrier again" end
    throttle[player]=now+500
    local car,bike=getVehicleById(args.car),getVehicleById(args.bike)
    if not C.IsCar(car) or not C.IsBike(bike) then return false,"Those vehicles are not available" end
    if command=="unload" then
        local r=C.Record(car)
        if not r or type(args.token) ~= "string" or r.token~=args.token then
            return false,"Carrier changed; reopen the vehicle menu"
        end
    end
    local previous=C._serverDispatch
    C._serverDispatch=true
    local executed,ok,reason,pose=pcall(command=="load" and C.Load or C.Unload,player,car,bike)
    C._serverDispatch=previous
    if not executed then
        print("[EmreRE9] carrier command failed: "..tostring(ok))
        return false,"Carrier load/unload failed (JVP 1.0.25); see the server log: "..tostring(ok):sub(1,120)
    end
    if ok and command=="unload" and isServer() then
        pose.car,pose.bike=car:getId(),bike:getId()
        pose.carKey,pose.bikeKey=car:getMechanicalID(),bike:getMechanicalID()
        sendServerCommand(C.NET,"release",pose)
    end
    return ok,reason
end
Events.OnClientCommand.Add(function(module,command,player,args)
    if module~=C.NET then return end
    local ok,reason=C.ServerCommand(player,command,args)
    reply(player,type(args)=="table" and args.request,ok,reason)
end)
Events.OnTick.Add(function()
    if not isServer() then return end
    local previous=C._serverDispatch
    C._serverDispatch=true
    local ok,err=pcall(C.Tick)
    C._serverDispatch=previous
    if not ok then
        if not C.serverWarned then print("[EmreRE9] server carrier tick failed: "..tostring(err)) end
        C.serverWarned=true
    end
end)
Events.OnGameStart.Add(function() throttle=setmetatable({}, {__mode="k"}); C.serverWarned=false; C.Reset() end)
if Events.OnSave then Events.OnSave.Add(function() if isServer() then C.Tick() end end) end
