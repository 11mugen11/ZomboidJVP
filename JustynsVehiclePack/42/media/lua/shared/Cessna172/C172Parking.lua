require "Cessna172/C172Variants"
-- Persistent parking authority. Map/render coordinates and the native body
-- must agree before a newly seated player takes over multiplayer simulation.
local B = {}
C172Parking = B
B.KEY = "c172ParkingBrake"
local HEIGHT_M = 2.44949
local known = setmetatable({}, {__mode="k"})
local latest = setmetatable({}, {__mode="k"})
local frozen = setmetatable({}, {__mode="k"})

local function finite(n)
    return type(n)=="number" and n==n and math.abs(n)<math.huge
end
local function plane(v) return C172Variants.isVehicle(v) end
local function part(v) return v:getPartById("Engine") end
local function towing(v) return v:getVehicleTowedBy() or v:getVehicleTowing() end
local function flying(v)
    local data=v:getModData().C172FlightData
    return data and data.mode and data.mode~="GROUND"
end
function B.record(v)
    if not plane(v) then return nil end
    local p=part(v)
    local r=p and p:getModData()[B.KEY]
    local old=latest[v]
    if r and finite(r.rev) and (not old or r.rev>old.rev) then latest[v]=r;old=r end
    return old
end
function B.isParked(v)
    local r=B.record(v)
    return r~=nil and r.active==true
end

-- Only an actually settled aircraft may acquire an anchor. Flight metadata can
-- survive a disconnect, so height and velocity are checked as well as the mode.
function B.canPark(v)
    if not plane(v) or towing(v) or flying(v) then return false end
    local vel=v:getLinearVelocity(Vector3f.new())
    if math.abs(v:getCurrentSpeedKmHour())>=1 or math.abs(vel:y())>=.5
        or vel:x()*vel:x()+vel:z()*vel:z()>=.09 then return false end
    local w=v:getWorldPos(0,0,0,Vector3f.new())
    local h=w:z()*HEIGHT_M
    local level=math.floor(v:getZ())
    local above=h-level*HEIGHT_M
    return above>.25 and above<1.9 and v:getUpVector(Vector3f.new()):y()>.85
end

local function capture(v)
    local w=v:getWorldPos(0,0,0,Vector3f.new())
    -- Map x/y are the replicated parked location. Use the body's actual height
    -- and orientation, without letting a hidden horizontal body drift set it.
    return {x=v:getX(),y=v:getY(),z=w:z(),
        rx=v:getAngleX(),ry=v:getAngleY(),rz=v:getAngleZ()}
end

function B.enforce(v,r)
    r=r or B.record(v)
    if not r or not r.active then return end
    -- Derive world streaming offsets from two conversions of the same native
    -- origin; getX/getY can already belong to a newer network packet.
    local t=v:getWorldTransform(BaseVehicle.allocTransform())
    local o=t:getOrigin()
    local w=v:getWorldPos(0,0,0,Vector3f.new())
    local ox,oy=w:x()-o:x(),w:y()-o:z()
    BaseVehicle.releaseTransform(t)
    v:setPhysicsActive(true);v:setPhysicsActive(false)
    -- +360 defeats setAngles' equal-angle early return and clears native
    -- velocity through teleportVehicle even on the server, where static is
    -- deliberately skipped by setPhysicsActive.
    v:setAngles(r.rx,r.ry+360,r.rz)
    t=v:getWorldTransform(BaseVehicle.allocTransform())
    t:getOrigin():set(r.x-ox,r.z*HEIGHT_M,r.y-oy)
    v:setWorldTransform(t);BaseVehicle.releaseTransform(t)
    v:setX(r.x);v:setY(r.y);v:setZ(r.z)
    v:setLastX(r.x);v:setLastY(r.y)
    v:setCurrentSquareFromPosition(r.x,r.y,r.z)
    v:setSpeedKmHour(0)
    frozen[v]=true
end

local function publish(v,r)
    local p=part(v)
    p:getModData()[B.KEY]=r
    latest[v]=r
    v:transmitPartModData(p)
    if isServer() then
        sendServerCommand("cessna172","parkingState",{
            vehicleId=v:getId(),vehicleKey=v:getMechanicalID(),state=r})
    end
end

function B.set(v,active,manual)
    if isClient() or not plane(v) then return false end
    local old=B.record(v)
    if active and (not B.canPark(v) or (v:isEngineRunning() and not manual)) then return false end
    local r=active and capture(v) or {}
    r.active=active==true;r.manual=manual==true
    r.rev=(old and old.rev or 0)+1
    r.suppressAuto=not active
    -- Align while still braked before releasing a new owner's native body.
    if not active and old and old.active then B.enforce(v,old) end
    publish(v,r)
    if active then B.enforce(v,r)
    else v:setPhysicsActive(true);frozen[v]=nil end
    known[v]=true
    return true
end

function B.serverCommand(player,args)
    if type(args)~="table" or type(args.active)~="boolean" or not player or player:isDead() then return false end
    local v=player:getVehicle()
    if not plane(v) or v:getId()~=args.vehicleId or not v:isDriver(player) then return false end
    -- The sender chooses intent only. Never accept a client's parked position,
    -- orientation, revision or arbitrary vehicle identity.
    return B.set(v,args.active,true)
end

function B.request(player,v,active)
    if not plane(v) or not v:isDriver(player) then return false end
    if isClient() then
        sendClientCommand(player,"cessna172","parkingBrake",{vehicleId=v:getId(),active=active})
        return true
    end
    return B.serverCommand(player,{vehicleId=v:getId(),active=active})
end

function B.toggle(player,v)
    return B.request(player,v,not B.isParked(v))
end

function B.receive(args)
    if type(args)~="table" or type(args.state)~="table" or not finite(args.vehicleId) then return end
    local v=getVehicleById(args.vehicleId)
    if not plane(v) or v:getMechanicalID()~=args.vehicleKey then return end
    local r=args.state
    if not finite(r.rev) or type(r.active)~="boolean" then return end
    if r.active then
        for _,key in ipairs({"x","y","z","rx","ry","rz"}) do if not finite(r[key]) then return end end
    end
    local old=B.record(v)
    if old and old.rev>=r.rev then return end
    if old and old.active and not r.active then B.enforce(v,old) end
    latest[v]=r;known[v]=true
    if not r.active and frozen[v] then v:setPhysicsActive(true);frozen[v]=nil end
    if r.active then B.enforce(v,r) end
end

function B.update(v)
    if not plane(v) then return end
    known[v]=true
    local r=B.record(v)
    if not isClient() then
        if r and r.active then
            if towing(v) or flying(v) or (not r.manual and v:isEngineRunning()) then
                B.set(v,false,false);return
            end
        elseif v:isEngineRunning() then
            if r and r.suppressAuto then
                r={active=false,manual=false,rev=r.rev+1,suppressAuto=false}
                publish(v,r)
            end
        elseif (not r or not r.suppressAuto) and B.canPark(v) then
            B.set(v,true,false);return
        end
    end
    r=B.record(v)
    if r and r.active and not towing(v) and not flying(v) then B.enforce(v,r)
    elseif frozen[v] then v:setPhysicsActive(true);frozen[v]=nil end
end

local nextScan=0
function B.tick()
    local now=getTimestampMs()
    if now>=nextScan or nextScan-now>250 then
        nextScan=now+250
        local cell=getCell()
        local vehicles=cell and cell:getVehicles()
        if vehicles then
            -- B42 returns a Set, which has no get(index). Snapshot the Collection
            -- before indexed access; native world updates can change the live set.
            local snapshot=ArrayList.new()
            snapshot:addAll(vehicles)
            for i=0,snapshot:size()-1 do
                local v=snapshot:get(i)
                if plane(v) then known[v]=true end
            end
        end
    end
    for v in pairs(known) do
        if v:isRemovedFromWorld() then known[v]=nil;frozen[v]=nil;latest[v]=nil
        else B.update(v) end
    end
end

Events.OnTick.Add(B.tick)
if Events.OnRenderTick then Events.OnRenderTick.Add(function()
    if isServer() then return end
    for v in pairs(frozen) do
        if not v:isRemovedFromWorld() then
            local r=B.record(v)
            if r and r.active and not towing(v) and not flying(v) then B.enforce(v,r) end
        end
    end
end) end
Events.OnEnterVehicle.Add(function(player)
    local v=player and player:getVehicle()
    if plane(v) then B.update(v) end
end)
Events.OnClientCommand.Add(function(module,command,player,args)
    if module=="cessna172" and command=="parkingBrake" then B.serverCommand(player,args) end
end)
Events.OnServerCommand.Add(function(module,command,args)
    if module=="cessna172" and command=="parkingState" then B.receive(args) end
end)
return B
