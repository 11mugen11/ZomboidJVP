-- Rear-mounted RE9 carrier for the Camel Discovery, B42 single/multiplayer.
-- The actual bike stays in the world: no inventory snapshots or cloned vehicles.
EmreRE9 = EmreRE9 or {}
require "emre_re9_carrier_physics"
if EmreRE9.Carrier then return EmreRE9.Carrier end
local C = {}; EmreRE9.Carrier = C
C.CAR, C.BIKE = "Base.lrdisco1camel", "Base.EMRE_RE9"
C.KEY = "emreRE9Carrier"
C.NET = "emreRE9Carrier"
C.HEIGHT_M = 2.44949
C.Offset = {x=0, y=0.35, z=-2.30}
local vehicles, pairsByToken, lastScan = {}, {}, -1000
local releasedTokens, followed = {}, setmetatable({}, {__mode="k"})
local packetAt = setmetatable({}, {__mode="k"})
local orphans = setmetatable({}, {__mode="k"})
local atan2 = math.atan2
local function name(v)
    return v and v:getScript() and v:getScript():getFullName()
end
C.PLANE="Base.Cessna172"
-- The approved motorcycle is a conditional aircraft render model. Its real
-- inventory-bearing vehicle follows at the aircraft origin, with its tiny
-- placeholder body safely outside the fuselage; never a towing constraint.
C.AircraftOffset={x=0,y=0,z=0}
function C.IsPlane(v) return name(v)==C.PLANE end
function C.IsCar(v) return name(v) == C.CAR or C.IsPlane(v) end
local function offset(car) return C.IsPlane(car) and C.AircraftOffset or C.Offset end

function C.IsBike(v) return EmreRE9.Bikes.profiles[name(v)] ~= nil end
local function part(v)
    return v and v:getPartById(C.IsCar(v) and "TruckBed" or "Engine")
end
function C.Record(v)
    if not C.IsCar(v) and not C.IsBike(v) then return nil end
    local p = part(v)
    local r = p and p:getModData()[C.KEY]
    return r and not releasedTokens[r.token] and r or nil
end
function C.IsMounted(v)
    local r = C.Record(v)
    return C.IsBike(v) and r and r.role == "bike" or false
end
local function write(v, value)
    local p = part(v)
    p:getModData()[C.KEY] = value
    v:transmitPartModData(p)
end
function C.Scan(force)
    local now = getTimestampMs()
    if not force and now-lastScan < 250 then return end
    lastScan = now
    vehicles, pairsByToken = {}, {}
    local cell = getCell()
    local list = cell and cell:getVehicles()
    if not list then return end
    local iterator = list:iterator()
    while iterator:hasNext() do
        local v = iterator:next()
        if C.IsCar(v) or C.IsBike(v) then
            vehicles[#vehicles+1] = v
            local r = C.Record(v)
            if r and r.token and (r.role == "car" or r.role == "bike") then
                pairsByToken[r.token] = pairsByToken[r.token] or {}
                pairsByToken[r.token][r.role] = v
            end
        end
    end
end
function C.Pair(v)
    C.Scan(true)
    local r = C.Record(v)
    return r and pairsByToken[r.token]
end
local function distance(a,b)
    local x,y = a:getX()-b:getX(), a:getY()-b:getY()
    return x*x+y*y
end
local point
local function nearPlayer(player,car)
    if C.IsPlane(car) and player.DistToProper then return player:DistToProper(car)<4 end
    return distance(player,car)<=(C.IsPlane(car) and 49 or 25)
end
local function compatible(car,bike)
    local p=EmreRE9.Bikes.profiles[name(bike)]
    if not C.IsPlane(car) then return true end
    if not p or p.normal~="Base.JVP_Tenere" then return false end
    local _,x,y=point(car,0,0,-5.4)
    return (bike:getX()-x)^2+(bike:getY()-y)^2<=4
end
function C.Near(v)
    C.Scan(true)
    local best, d = nil, math.huge
    for _,other in ipairs(vehicles) do
        if other ~= v and not C.Record(other)
            and ((C.IsCar(v) and C.IsBike(other)) or (C.IsBike(v) and C.IsCar(other))) then
            local ds = distance(v,other)
            local car,bike=v,other
            if C.IsBike(v) then car,bike=other,v end
            if ds < d and ds <= (C.IsPlane(car) and 64 or 36) and compatible(car,bike) then best,d = other,ds end
        end
    end
    return best
end
local function unoccupied(v)
    for seat=0,v:getScript():getPassengerCount()-1 do
        if v:getCharacter(seat) then return false end
    end
    return true
end
local function aircraftGrounded(car,player)
    if not C.IsPlane(car) then return true end
    local t=car:getWorldTransform(BaseVehicle.allocTransform())
    local height=t:getOrigin():y()-math.floor(player:getZ())*C.HEIGHT_M
    BaseVehicle.releaseTransform(t)
    return height>=-0.2 and height<=1.9
end
function C.CanLoad(player,car,bike)
    if not C.IsCar(car) or not C.IsBike(bike) or not compatible(car,bike) then return false,"Wrong vehicle pair" end
    if not player or player:isDead() or player:getVehicle() or not nearPlayer(player,car)
        or (not C.IsPlane(car) and distance(player,bike)>36) or distance(car,bike)>36
        or math.abs(player:getZ()-car:getZ())>0.8 or math.abs(car:getZ()-bike:getZ())>0.8 then
        return false,"Stand near the parked vehicles"
    end
    if not aircraftGrounded(car,player) then return false,"Land the aircraft first" end
    if C.Record(car) or C.Record(bike) then return false,"Carrier already in use" end
    if car:getVehicleTowing() or car:getVehicleTowedBy() or bike:getVehicleTowing() or bike:getVehicleTowedBy() then
        return false,"Detach existing tow ropes first"
    end
    if math.abs(car:getCurrentSpeedKmHour())>0.5 or math.abs(bike:getCurrentSpeedKmHour())>0.5 then
        return false,"Park both vehicles first"
    end
    if not unoccupied(bike) then return false,"Dismount the motorcycle first" end
    if bike:isEngineRunning() or bike:isEngineStarted() then return false,"Turn off the motorcycle engine first" end
    return true
end
function C.IsAuthority()
    return not isClient() or C._serverDispatch == true
end
-- Server-owned parked bikes must not retain a nearby player's collision
-- physics lease. Driving ownership of the Land Rover remains entirely native.
function C.RevokeBikeAuthority(bike)
    if not isServer() then return end
    local id = bike:getNetPlayerId()
    if id >= 0 then
        local owner = getPlayerByOnlineID(id)
        if owner then bike:authorizationServerOnSeat(owner,false) end
    end
    -- OnSeat(false) also revokes collision leases belonging to that player.
    -- authorizationServerCollide takes a Java short, for which B42's Lua
    -- bridge has no number converter. A literal -1 throws on dedicated servers.
end
-- Read a car-local point in physics coordinates. Transform's origin already
-- includes the physics world's streaming offset; never infer it from map tiles.
point=function(car,x,y,z)
    local t = car:getWorldTransform(BaseVehicle.allocTransform())
    local origin = t:getOrigin()
    local ox,oy,oz = origin:x(),origin:y(),origin:z()
    local p = Vector3f.new(x,y,z)
    t:transform(p)
    BaseVehicle.releaseTransform(t)
    return p, car:getX()+p:x()-ox, car:getY()+p:z()-oz, p:y()/C.HEIGHT_M
end
-- R_bike = R_car * R_y(90 degrees), so the bike is crosswise and follows
-- the car's pitch/roll as well as its heading. Decompose into native XYZ Euler.
function C.Angles(right,up,forward)
    local ry = math.asin(math.max(-1,math.min(1,right:x())))
    local rx,rz
    -- The matrix's rows are physics x/up/z, not world x/y/floor.
    if math.abs(math.cos(ry)) > 0.0001 then
        rx = atan2(-right:y(),right:z())
        rz = atan2(-up:x(),-forward:x())
    else
        rx = atan2(up:z(),up:y()); rz = 0
    end
    return math.deg(rx),math.deg(ry),math.deg(rz)
end
function C.Place(car,bike,offset,ground)
    local target,x,y,z = point(car,offset.x,offset.y,offset.z)
    local t = car:getWorldTransform(BaseVehicle.allocTransform())
    local origin = t:getOrigin()
    local right,up,forward = Vector3f.new(1,0,0),Vector3f.new(0,1,0),Vector3f.new(0,0,1)
    t:transform(right); right:sub(origin)
    t:transform(up); up:sub(origin)
    t:transform(forward); forward:sub(origin)
    BaseVehicle.releaseTransform(t)
    local rx,ry,rz = C.Angles(right,up,forward)
    if C.IsPlane(car) then
        -- Real hidden bike follows the aircraft basis; display uses baked geometry.
        ry=math.asin(math.max(-1,math.min(1,forward:x())))
        if math.abs(math.cos(ry))>0.0001 then
            rx=atan2(-forward:y(),forward:z()); rz=atan2(-up:x(),right:x())
        else rx=atan2(up:z(),up:y()); rz=0 end
        rx,ry,rz=math.deg(rx),math.deg(ry),math.deg(rz)
    end
    if ground then
        rx,rz = 0,0
        ry = C.IsPlane(car) and math.deg(atan2(forward:x(),forward:z())) or math.deg(atan2(right:x(),right:z()))
        z = ground + 0.08
        target:set(target:x(),z*C.HEIGHT_M,target:z())
    end
    -- Force the first enabled->disabled transition. Native setPhysicsActive
    -- returns early for an already-disabled controller, before setting static.
    if not ground and not followed[bike] then bike:setPhysicsActive(true) end
    bike:setPhysicsActive(false)
    -- Native setAngles skips equal integer angles before marking the footprint
    -- dirty. An equivalent full yaw turn forces that refresh even on a straight
    -- road, so the parked bike's polygon/shadow does not stay at the load point.
    bike:setAngles(rx,ry+360,rz)
    local bt = bike:getWorldTransform(BaseVehicle.allocTransform())
    bt:getOrigin():set(target)
    bike:setWorldTransform(bt)
    BaseVehicle.releaseTransform(bt)
    bike:setX(x); bike:setY(y); bike:setZ(z)
    bike:setLastX(x); bike:setLastY(y)
    bike:setCurrentSquareFromPosition(x,y,z)
    if not ground then
        -- Public native update refreshes the render matrices AND moves the real
        -- vehicle between chunk vehicle lists. Merely setting its square left
        -- that registration at the previous position until the next game tick.
        local cell=getCell()
        local registered=cell and cell:getVehicles()
        -- Native update queues removal if the cell Set does not contain this
        -- object yet. Never invoke that path during a streaming registration gap.
        if registered and registered:contains(bike) then bike:update() end
        -- The native update can wake parked vehicles or quantise map Z to a
        -- floor. Reassert the carrier's static body and continuous render height.
        bike:setPhysicsActive(false)
        if C.IsPlane(car) then EmreRE9.CarrierPhysics.AircraftContacts(bike,true) end
        bike:setX(x); bike:setY(y); bike:setZ(z)
        bike:setLastX(x); bike:setLastY(y)
        bike:setCurrentSquareFromPosition(x,y,z)
    end
    return {x=x,y=y,z=z,rx=rx,ry=ry,rz=rz}
end
function C.UpdatePair(car,bike)
    if car:isRemovedFromWorld() or bike:isRemovedFromWorld() then return end
    local r = C.Record(car)
    if not r then return end
    EmreRE9.CarrierPhysics.Apply(bike,true,C.IsPlane(car))
    if C.IsAuthority() then C.RevokeBikeAuthority(bike) end
    C.Place(car,bike,offset(car))
    followed[bike] = {car=car,baseMass=r.baseMass,token=r.token}
    if r and r.baseMass and not C.IsPlane(car) then
        local bikeMass = C.IsAuthority() and bike:getMass() or (r.bikeMass or bike:getMass())
        if C.IsAuthority() and r.bikeMass ~= bikeMass then
            r.bikeMass = bikeMass
            if isServer() then car:transmitPartModData(part(car)) end
        end
        local mass = r.baseMass+bikeMass
        if math.abs(car:getInitialMass()-mass)>0.1 then
            car:setInitialMass(mass); car:updateTotalMass()
        end
    end
    -- VehicleUpdate always carries its current world position in the header.
    -- Refresh the native part packet at 4 Hz for relevance/streaming; clients
    -- render relative to the car each frame, not these delayed bike positions.
    if isServer() and getTimestampMs() >= (packetAt[bike] or 0) then
        packetAt[bike] = getTimestampMs()+250
        bike:transmitPartModData(part(bike))
    end
end
function C.Load(player,car,bike)
    if not C.IsAuthority() then return false,"Loading is controlled by the server" end
    local ok,reason = C.CanLoad(player,car,bike)
    if not ok then return false,reason end
    local original=bike:getWorldTransform(BaseVehicle.allocTransform())
    local x,y,z=bike:getX(),bike:getY(),bike:getZ()
    local mounted=EmreRE9.Bikes.IsMounted(name(bike))
    -- A rejected preparation must not strand an unpaired collision-free bike.
    local prepared,err=pcall(function()
        EmreRE9.CarrierPhysics.Apply(bike,true,C.IsPlane(car))
        C.RevokeBikeAuthority(bike)
        C.Place(car,bike,offset(car))
    end)
    if not prepared then
        pcall(function()
            EmreRE9.CarrierPhysics.Apply(bike,mounted,mounted and C.IsPlane(car))
            bike:setWorldTransform(original)
            bike:setX(x); bike:setY(y); bike:setZ(z)
            bike:setLastX(x); bike:setLastY(y)
            bike:setCurrentSquareFromPosition(x,y,z)
            bike:setPhysicsActive(true)
        end)
        BaseVehicle.releaseTransform(original)
        error(err)
    end
    BaseVehicle.releaseTransform(original)
    local token = tostring(getTimestampMs())..":"..tostring(ZombRand(1000000000))..":"..tostring(car:getId())
    write(car,{token=token,role="car",baseMass=car:getInitialMass(),bikeMass=bike:getMass()})
    write(bike,{token=token,role="bike",carrier=C.IsPlane(car) and C.PLANE or C.CAR})
    C.UpdatePair(car,bike)
    C.Scan(true)
    return true
end
function C.Unload(player,car,bike)
    if not C.IsAuthority() then return false,"Unloading is controlled by the server" end
    local cr,br = C.Record(car),C.Record(bike)
    if not C.IsCar(car) or not C.IsBike(bike) or not cr or not br
        or cr.role ~= "car" or br.role ~= "bike" or cr.token ~= br.token then return false,"Partner vehicle is not loaded" end
    if not player or player:isDead() or player:getVehicle() or not nearPlayer(player,car)
        or math.abs(player:getZ()-car:getZ())>0.8 then return false,"Stand near the car" end
    if math.abs(car:getCurrentSpeedKmHour())>0.5 then return false,"Park the car first" end
    if not aircraftGrounded(car,player) then return false,"Land the aircraft first" end
    local drop = {x=0,y=0,z=C.IsPlane(car) and -5.4 or -4.2}
    local _,x,y = point(car,drop.x,drop.y,drop.z)
    local floor = math.floor(car:getZ())
    local cell = getCell()
    -- Leave room for the crosswise motorcycle, not just its centre point.
    for dx=-1,1 do for dy=-1,1 do
        local sq = cell:getGridSquare(math.floor(x)+dx,math.floor(y)+dy,floor)
        if not sq or not sq:TreatAsSolidFloor() or not sq:isFree(false) then
            return false,"Leave a clear 3-by-3 area behind the car"
        end
    end end
    if not unoccupied(bike) then return false,"Dismount the motorcycle first" end
    EmreRE9.CarrierPhysics.Apply(bike,false)
    local pose = C.Place(car,bike,drop,floor)
    write(bike,nil); write(car,nil)
    if not C.IsPlane(car) then car:setInitialMass(cr.baseMass); car:updateTotalMass() end
    bike:setPhysicsActive(true)
    followed[bike] = nil
    C.Scan(true)
    pose.token,pose.baseMass = cr.token,cr.baseMass
    return true,nil,pose
end
function C.Tick()
    C.Scan()
    local updated={}
    -- Never clear a saved pair just because its partner's chunk is absent.
    -- Once replicated mod data explicitly clears a mount, restore local mass
    -- and bike physics even if this client missed the immediate release event.
    for bike,state in pairs(followed) do
        if not bike:isRemovedFromWorld() and not C.Record(bike) then
            if not state.car:isRemovedFromWorld() and not C.Record(state.car) and not C.IsPlane(state.car) then
                state.car:setInitialMass(state.baseMass); state.car:updateTotalMass()
            end
            EmreRE9.CarrierPhysics.Apply(bike,false)
            bike:setPhysicsActive(true); followed[bike] = nil
        elseif not bike:isRemovedFromWorld() and not state.car:isRemovedFromWorld() then
            local br,cr=C.Record(bike),C.Record(state.car)
            if br and cr and br.token==state.token and cr.token==state.token then
                -- A temporary gap in the cell Set must not stop a live pair
                -- following, even while the next streamed scan is incomplete.
                C.UpdatePair(state.car,bike)
                updated[bike]=true
            end
        end
    end
    for _,v in ipairs(vehicles) do
        if C.IsMounted(v) then
            v:setPhysicsActive(false)
            if name(v)=="Base.JVP_TenereAircraft" then EmreRE9.CarrierPhysics.AircraftContacts(v,true) end
        end
        local P=EmreRE9.CarrierPhysics
        if EmreRE9.Bikes.IsMounted(name(v)) and not C.Record(v) and not P.busy[v] then
            local state=orphans[v]
            if not state then
                state={at=getTimestampMs(),floor=math.max(0,math.floor(v:getZ()))}
                orphans[v]=state
                v:setPhysicsActive(true); v:setPhysicsActive(false)
            end
            -- Let replicated pairing arrive before repairing an observer's bike.
            if getTimestampMs()-state.at >= (isClient() and 10000 or 1000) then
                P.Apply(v,false)
                local x,y,z=v:getX(),v:getY(),state.floor+0.08
                local t=v:getWorldTransform(BaseVehicle.allocTransform())
                local o=t:getOrigin(); o:set(o:x(),z*C.HEIGHT_M,o:z())
                v:setWorldTransform(t); BaseVehicle.releaseTransform(t)
                v:setZ(z); v:setCurrentSquareFromPosition(x,y,z)
                v:setPhysicsActive(true); orphans[v]=nil
            end
        else orphans[v]=nil end
    end
    for _,pair in pairs(pairsByToken) do
        if pair.car and pair.bike and not updated[pair.bike] then C.UpdatePair(pair.car,pair.bike) end
    end
end
function C.Render()
    -- Render frames can outnumber game ticks. Use the car's latest transform
    -- immediately before drawing so the bike cannot interpolate independently.
    for bike,state in pairs(followed) do
        if not bike:isRemovedFromWorld() and not state.car:isRemovedFromWorld() then
            local br,cr=C.Record(bike),C.Record(state.car)
            if br and cr and br.token==state.token and cr.token==state.token then
                C.Place(state.car,bike,offset(state.car))
            end
        end
    end
end
function C.Reset()
    vehicles, pairsByToken, lastScan = {}, {}, -1000
    releasedTokens,followed = {},setmetatable({}, {__mode="k"})
    packetAt = setmetatable({}, {__mode="k"})
    orphans = setmetatable({}, {__mode="k"})
end
-- The admin spawn list exposes every vehicle script, including our internal
-- mounted profile. Select ordinary physics before a fresh body's construction.
if Events.OnSpawnVehicleStart then Events.OnSpawnVehicleStart.Add(function(v)
    local P=EmreRE9.CarrierPhysics
    if not isClient() and EmreRE9.Bikes.IsMounted(name(v)) and not C.Record(v) and not P.busy[v] then
        v:setScript(EmreRE9.Bikes.profiles[name(v)].normal)
    end
end) end
-- Trusted server release: place on the ground immediately, before stale
-- interpolation or a queued pre-unload part packet can remount this token.
function C.ApplyRelease(car,bike,pose)
    if (car and not C.IsCar(car)) or not C.IsBike(bike) then return false end
    local record = C.Record(bike)
    if record and record.token ~= pose.token then return false end
    local carRecord = car and C.Record(car)
    if carRecord and carRecord.token ~= pose.token then return false end
    EmreRE9.CarrierPhysics.Apply(bike,false)
    releasedTokens[pose.token] = true
    local t = bike:getWorldTransform(BaseVehicle.allocTransform())
    local o = t:getOrigin()
    local px,py = pose.x-(bike:getX()-o:x()),pose.y-(bike:getY()-o:z())
    BaseVehicle.releaseTransform(t)
    bike:setPhysicsActive(false)
    bike:setAngles(pose.rx,pose.ry+360,pose.rz)
    t = bike:getWorldTransform(BaseVehicle.allocTransform())
    t:getOrigin():set(px,pose.z*C.HEIGHT_M,py)
    bike:setWorldTransform(t); BaseVehicle.releaseTransform(t)
    bike:setX(pose.x); bike:setY(pose.y); bike:setZ(pose.z)
    bike:setLastX(pose.x); bike:setLastY(pose.y)
    bike:setCurrentSquareFromPosition(pose.x,pose.y,pose.z)
    if car and not C.IsPlane(car) then car:setInitialMass(pose.baseMass); car:updateTotalMass() end
    followed[bike]=nil; bike:setPhysicsActive(true)
    return true
end
return C
