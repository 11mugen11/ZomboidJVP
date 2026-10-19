from pathlib import Path
import sys, re, json, hashlib
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / '.test-runtime'))
from lupa.lua51 import LuaRuntime
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
PACK = ROOT / 'JustynsVehiclePack'
MEDIA = PACK / '42/media'
lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute('''
require = function() end
isClient = function() return false end
isServer = function() return false end
Events = setmetatable({}, {__index=function(t,k) local v={Add=function() end}; rawset(t,k,v); return v end})
SandboxVars = {AllowExteriorGenerator=true}
Vehicles = {JerryCanLitres=10}
now=1000
getTimestampMs=function() return now end
vehicles={}
getVehicleById=function(id) return vehicles[id] end
instanceof=function(obj, kind) return obj.class == kind end
function point(x,y) return {getX=function() return x end,getY=function() return y end} end
function list(items)
    return {size=function() return #items end, get=function(_,i) return items[i+1] end}
end
objects={}
square={hasGridPower=function() return true end,haveElectricity=function() return true end,
    getObjects=function() return list(objects) end}
getCell=function() return {getGridSquare=function() return square end} end
function player(id)
    return {x=0,y=0,z=0,dead=false,
    getOnlineID=function() return id end,isDead=function(s) return s.dead end,
    getVehicle=function() return nil end,getX=function(s) return s.x end,
    getY=function(s) return s.y end,getZ=function(s) return s.z end}
end
function part(id, capacity, amount, fueltype)
    return {id=id,capacity=capacity,amount=amount,fueltype=fueltype,condition=100,
    getCondition=function(s) return s.condition end,getVehicle=function() return truck end,
    getId=function(s) return s.id end,getArea=function(s) return s.id end,
    getInventoryItem=function() return {} end,getContainerContentType=function(s) return s.fueltype end,
    getContainerCapacity=function(s) return s.capacity end,getContainerContentAmount=function(s) return s.amount end,
    setContainerContentAmount=function(s,n) assert(n>=-0.00001 and n<=s.capacity+0.00001); s.amount=n end}
end
function vehicle(id,script,x,y)
    local v={id=id,script=script,x=x,y=y,z=0,running=true,speed=0,started=false,parts={},syncs=0}
    v.getId=function(s) return s.id end
    v.getScriptName=function(s) return s.script end
    v.getPartById=function(s,k) return s.parts[k] end
    v.getAreaCenter=function(s) return point(s.x,s.y) end
    v.getZ=function(s) return s.z end
    v.getSquare=function() return square end
    v.getCurrentSpeedKmHour=function(s) return s.speed end
    v.isEngineRunning=function(s) return s.running end
    v.isEngineStarted=function(s) return s.started end
    v.transmitPartModData=function(s,p) s.syncs=s.syncs+1 end
    vehicles[id]=v
    return v
end
function reset()
    now=1000
    JVPActyFuel.sessions={}
    truck=vehicle(1,JVPActyFuel.SCRIPT,0,0)
    truck.parts[JVPActyFuel.PART]=part(JVPActyFuel.PART,2000,100,"JVP_PetrolOnly")
    truck.parts.GasTank=part("GasTank",40,30,"Gasoline")
    target=vehicle(2,"Base.SmallCar",4,4)
    target.parts.GasTank=part("GasTank",50,0,"Gasoline")
    p1=player(1); p1.x=4;p1.y=4
    p2=player(2); p2.x=4;p2.y=4
    generator={class="IsoGenerator",fuel=0,capacity=12,activated=false,
        getObjectIndex=function() return 0 end,getX=function() return 4 end,
        getY=function() return 4 end,getZ=function() return 0 end,
        isActivated=function(s) return s.activated end,
        getFuel=function(s) return s.fuel end,getMaxFuel=function(s) return s.capacity end,
        setFuel=function(s,f) s.fuel=f end,sync=function() end}
    pump={units=100,getObjectIndex=function() return 0 end,
        getSquare=function() return square end,getX=function() return 0 end,
        getY=function() return 0 end,getZ=function() return 0 end,
        getPipedFuelAmount=function(s) return s.units end,
        setPipedFuelAmount=function(s,n) s.units=n end,transmitModData=function() end}
    objects={generator}
end
function start(p,mode)
    JVPActyFuel.serverCommand(p,"start",{truck=1,target=2,mode=mode or "vehicle",x=0,y=0,z=0,index=0})
end
function tick(ms) now=now+(ms or 250); JVPActyFuel.tick() end
function near(a,b) assert(math.abs(a-b)<0.000001, tostring(a).." ~= "..tostring(b)) end
''')
for rel in ('lua/shared/JVPActyFuel.lua','lua/server/JVPActyFuelServer.lua'):
    lua.execute((MEDIA / rel).read_text())

tests = {
    'vehicle transfer and separate engine reserve': '''reset(); start(p1); tick(); near(target.parts.GasTank.amount,2); near(truck.parts[JVPActyFuel.PART].amount,98); near(truck.parts.GasTank.amount,30); assert(truck.syncs>0 and target.syncs>0)''',
    'two players share one source without duplication': '''reset(); truck.parts[JVPActyFuel.PART].amount=3; start(p1);start(p2);tick();near(target.parts.GasTank.amount,3);near(truck.parts[JVPActyFuel.PART].amount,0)''',
    'target capacity clamp': '''reset();target.parts.GasTank.amount=49.5;start(p1);tick();near(target.parts.GasTank.amount,50);near(truck.parts[JVPActyFuel.PART].amount,99.5)''',
    'empty source cannot use engine tank': '''reset();truck.parts[JVPActyFuel.PART].amount=0;start(p1);tick();near(target.parts.GasTank.amount,0);near(truck.parts.GasTank.amount,30)''',
    'engine off at start': '''reset();truck.running=false;start(p1);assert(next(JVPActyFuel.sessions)==nil)''',
    'engine stops mid-transfer': '''reset();start(p1);tick();truck.running=false;tick();near(target.parts.GasTank.amount,2);assert(next(JVPActyFuel.sessions)==nil)''',
    'exact doubled square range': '''reset();assert(JVPActyFuel.hoseReaches(truck,target,target.parts.GasTank));target.x=5;start(p1);assert(next(JVPActyFuel.sessions)==nil)''',
    'range revalidated mid-transfer': '''reset();start(p1);tick();target.x=5;tick();near(target.parts.GasTank.amount,2)''',
    'different floor denied': '''reset();target.z=1;start(p1);assert(next(JVPActyFuel.sessions)==nil)''',
    'generator real litre capacity and sync': '''reset();start(p1,"generator");tick();near(generator.fuel,2);near(truck.parts[JVPActyFuel.PART].amount,98)''',
    'generator running denied': '''reset();generator.activated=true;start(p1,"generator");assert(next(JVPActyFuel.sessions)==nil)''',
    'generator capacity clamp': '''reset();generator.fuel=11.9;start(p1,"generator");tick();near(generator.fuel,12);near(truck.parts[JVPActyFuel.PART].amount,99.9)''',
    'disconnect keepalive timeout': '''reset();start(p1);tick(3100);near(target.parts.GasTank.amount,0);assert(next(JVPActyFuel.sessions)==nil)''',
    'explicit cancellation': '''reset();start(p1);JVPActyFuel.serverCommand(p1,"stop",{});tick();near(target.parts.GasTank.amount,0)''',
    'walking away stops transfer': '''reset();start(p1);p1.x=20;tick();near(target.parts.GasTank.amount,0)''',
    'invalid truck rejected': '''reset();truck.script="Base.89actytruck";start(p1);assert(next(JVPActyFuel.sessions)==nil)''',
    'self engine cannot be destination': '''reset();JVPActyFuel.serverCommand(p1,"start",{truck=1,target=1,mode="vehicle"});assert(next(JVPActyFuel.sessions)==nil)''',
    'receiver engine running denied': '''reset();target.started=true;start(p1);assert(next(JVPActyFuel.sessions)==nil)''',
    'non petrol destination denied': '''reset();target.parts.GasTank.fueltype="Water";start(p1);assert(next(JVPActyFuel.sessions)==nil)''',
    'moving truck denied': '''reset();truck.speed=10;start(p1);assert(next(JVPActyFuel.sessions)==nil)''',
    'legacy custom station command is disabled': '''reset();start(p1,"load");assert(next(JVPActyFuel.sessions)==nil)''',
}
passed=[]
for name, code in tests.items():
    lua.execute(code)
    passed.append(name)
    print('PASS:', name)

# Compile new Lua against Lua 5.1, matching PZ's Lua language subset.
for p in (MEDIA / 'lua').rglob('*JVPActy*.lua'):
    lua.execute('assert(loadstring(...))', p.read_text())

# Load the real client module with lightweight UI doubles and exercise menu hooks.
lua.execute('''
ISVehicleMenu={FillPartMenu=function() end}
ISVehiclePartMenu={doAddFuelMenu=function(p,part,context) context:addOption("Add fuel from can",nil,nil) end,
    getNearbyFuelPump=function() return nil end}
ISVehicleMechanics={initParts=function() end}
ISBaseTimedAction={}
function ISBaseTimedAction:derive(name)
    local t={};t.__index=t;return setmetatable(t,{__index=self})
end
function ISBaseTimedAction:new(player) return setmetatable({character=player},{__index=self}) end
ISTimedActionQueue={queued={},add=function(action) table.insert(ISTimedActionQueue.queued,action) end}
ISPathFindAction={pathToVehicleArea=function(player,vehicle,area) return {path=true,vehicle=vehicle,area=area} end}
getSpecificPlayer=function() return p1 end
getTexture=function() return {} end
getText=function(s) return s end
ISContextMenu={getNew=function() return menu() end}
ArrayList={new=function()
    local s={}
    s.addAll=function(self,collection) self.values=collection.values end
    s.size=function(self) return #self.values end
    s.get=function(self,i) return self.values[i+1] end
    return s
end}
function menu()
    local m={options={}}
    m.addOption=function(s,label,target,callback,...)
        local o={label=label,target=target,callback=callback,args={...}}
        table.insert(s.options,o);return o
    end
    m.addSubMenu=function(s,option,sub) option.sub=sub end
    return m
end
''')
GAME=Path(r'C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid\media')
lua.execute((GAME/'lua/shared/Vehicles/TimedActions/ISRefuelFromGasPump.lua').read_text())
lua.execute((MEDIA/'lua/client/JVPActyFuelClient.lua').read_text())
lua.execute('''
reset()
truck.DistToProper=function() return 1 end
p1.DistToProper=function() return 1 end
truck.getScript=function() return {getName=function() return "JVP_ActyFuelTruck" end} end
target.getScript=function() return {getName=function() return "SmallCar" end} end
getCell=function() return {getGridSquare=function() return nil end,
    getVehicles=function() return {values={truck,target}} end} end
local context=menu()
ISVehicleMenu.FillPartMenu(0,context,nil,truck)
assert(string.find(context.options[1].label,"ENGINE fuel tank",1,true))
assert(string.find(context.options[2].label,"EXTERNAL bed tank",1,true))
function noSiphon(menu)
    for _,o in ipairs(menu.options) do
        assert(not string.find(string.lower(o.label),"siphon",1,true))
        if o.sub then noSiphon(o.sub) end
    end
end
noSiphon(context)
assert(context.options[2].sub.options[2].args[2]=="vehicle")
assert(context.options[2].sub.options[2].args[1]==truck)
local receiver=menu()
ISVehicleMenu.FillPartMenu(0,receiver,nil,target)
assert(string.find(receiver.options[1].label,"EXTERNAL bed tank",1,true))
truck.running=false
local off=menu()
ISVehicleMenu.FillPartMenu(0,off,nil,target)
assert(off.options[1].notAvailable)
reset()
local tank=truck.parts[JVPActyFuel.PART]
tank.amount=0
local stationAction=ISRefuelFromGasPump:new(p1,tank,pump)
assert(stationAction.maxTime==6250 and stationAction.tankTarget==125)
stationAction.getJobDelta=function() return 1 end
stationAction.character={setMetabolicTarget=function() end}
Metabolics={HeavyDomestic=1}
stationAction:update()
near(pump.units,0)
assert(stationAction:complete())
near(tank.amount,125)
pump.units=100
F=JVPActyFuel
F.queue(p1,truck,"load",pump)
assert(#ISTimedActionQueue.queued==2)
assert(ISTimedActionQueue.queued[1].path)
local queued=ISTimedActionQueue.queued[2]
assert(getmetatable(queued).__index==ISRefuelFromGasPump)
assert(queued.part==tank and queued.maxTime>0)
tank.amount=1000;tank.condition=73
assert(F.tankLabel(tank)=="Gas Tank EXTERNAL - 50% - 73%")
local rendered={}
UIFont={Small=1}
local view={parent={vehicle=truck,partRGB={r=1,g=1,b=1,a=1}},itemheight=20,
    drawText=function(self,text) table.insert(rendered,text) end,drawRect=function() end,
    getWidth=function() return 500 end}
local row={item={part=tank},itemindex=2,height=20}
assert(ISVehicleMechanics.doDrawItem(view,0,row,false)==20)
assert(#rendered==1 and rendered[1]=="Gas Tank EXTERNAL - 50% - 73%")
tank.amount=1500;tank.condition=69
ISVehicleMechanics.doDrawItem(view,0,row,false)
assert(rendered[2]=="Gas Tank EXTERNAL - 75% - 69%")
F.currentAction={character=p1}
F.clientStatus({player=1,state="accepted"})
assert(F.currentAction.confirmed)
F.clientStatus({player=1,state="rejected",message="Engine off"})
assert(F.currentAction.rejected=="Engine off")
F.currentAction=nil
now=6000
local timedOut=false
HaloTextHelper={addBadText=function(player,message) timedOut=string.find(message,"no server response",1,true)~=nil end}
p1.faceThisObject=function() end
local waiting={character=p1,object=target,confirmed=false,requestTime=0,
    forceStop=function(self) self.stopped=true end}
JVPActyFuelAction.update(waiting)
assert(waiting.stopped and timedOut)
local savedCell=getCell
objects={pump}
getCell=function() return {getGridSquare=function(self,x,y,z)
    if x==4 and y==0 and z==0 then return square end
end} end
assert(F.findPump(truck)==pump)
getCell=function() return {getGridSquare=function(self,x,y,z)
    if x==5 and y==0 and z==0 then return square end
end} end
assert(F.findPump(truck)==nil)
getCell=savedCell
''')
print('PASS: client menus; finite vanilla station action; native action queued for bed; live fuel/durability line; server acknowledgement/rejection')

# Resolve every namespaced asset in the vehicle scripts, decoding each PNG.
assets = [* (PACK/'42/media').rglob('*'), *(PACK/'common/media').rglob('*')]
paths = {str(p.relative_to(PACK)).replace('\\','/').lower():p for p in assets if p.is_file()}
def asset(folder, name, extensions):
    for prefix in ('42/media/', 'common/media/'):
        for ext in extensions:
            k=(prefix+folder+'/'+name+ext).lower()
            if k in paths: return paths[k]
    raise AssertionError('Missing '+folder+'/'+name)

models={}
scripts=[]
for p in (MEDIA/'scripts/vehicles').glob('*.txt'):
    if 'acty' not in p.name.lower(): continue
    text=p.read_text()
    assert text.count('{') == text.count('}'), p
    scripts.append((p,text))
    for name in re.findall(r'\bmodel\s+(JVP_\w+)\s*\{',text): models[name]=p
    for folder,name in re.findall(r'\b(mesh|texture|textureMask|textureLights|textureDamage\w+|textureRust)\s*=\s*([^,\n]+)',text):
        if 'JVP_' not in name: continue
        name=name.strip().split('|')[0]
        found=asset('models_X' if folder=='mesh' else 'textures',name,['.fbx','.x'] if folder=='mesh' else ['.png'])
        if found.suffix=='.png':
            with Image.open(found) as img: img.load()
    for icon in re.findall(r'\bIcon\s*=\s*(JVP_[^,\n]+)',text): asset('textures','Item_'+icon.strip(),['.png'])
for p,text in scripts:
    for name in re.findall(r'\bfile\s*=\s*(JVP_[^,\n]+)',text): assert name.strip() in models,(p,name)
vehicle=(MEDIA/'scripts/vehicles/vehicle_JVP_Acty.txt').read_text()
assert len(re.findall(r'\bskin\s*\{',vehicle))==1
assert 'JVP_Acty_Shell_yellow' in vehicle
assert 'contentType = JVP_PetrolOnly' in vehicle
assert not re.search(r'^require=',(PACK/'42/mod.info').read_text(),re.M)
print('PASS: namespaced model, texture, icon references; PNG decode; yellow-only skin; no dependencies')
report={'lua_runtime':'Lua 5.1 (Lupa)','server_regression_tests':passed,'asset_checks':'passed',
        'client_regressions':'Native finite station action and fuel debit; station-to-bed 4-tile boundary; live mechanics fuel/durability line; server status acknowledgement/rejection',
        'live_multiplayer_test':'Not run: requires a running server and two game clients',
        'in_game_render_test':'Not run: offline FBX/texture inspection is separate from the game renderer'}
(ROOT/'verification.json').write_text(json.dumps(report,indent=2))
