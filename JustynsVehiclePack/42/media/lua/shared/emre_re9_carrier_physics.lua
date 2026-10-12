-- Scoped native physics rebuild for carrier loading/unloading.
-- B42 scriptReloaded clears part items, so suppress creation/initialization
-- for this exact bike while retaining and restoring its real item/container refs.
EmreRE9 = EmreRE9 or {}
local P={NORMAL="Base.EMRE_RE9",MOUNTED="Base.EMRE_RE9Carrier",busy=setmetatable({}, {__mode="k"})}
EmreRE9.CarrierPhysics=P
local applied=setmetatable({}, {__mode="k"})

local function protectCallback(path,bike,changes,parents)
    if not path or path=="" or changes[path] then return end
    local names={}
    for key in string.gmatch(path,"[^.]+") do names[#names+1]=key end
    local parent=_G
    for i=1,#names-1 do
        local key=names[i]
        if parent[key]==nil then
            parents[#parents+1]={parent=parent,key=key}
            parent[key]={}
        end
        parent=parent[key]
    end
    local key=names[#names]
    local original=parent[key]
    changes[path]={parent=parent,key=key,original=original}
    parent[key]=function(v,part,...)
        if v==bike then return end
        if original then return original(v,part,...) end
    end
end
local function restoreCallbacks(changes,parents)
    for _,change in pairs(changes) do change.parent[change.key]=change.original end
    for i=#parents,1,-1 do parents[i].parent[parents[i].key]=nil end
end
local function restoreParts(bike,saved)
    for _,state in ipairs(saved.parts) do
        local part=bike:getPartById(state.id)
        if not part then error("Carrier rebuild lost part "..state.id) end
        part:setInventoryItem(state.item)
        if state.container then part:setItemContainer(state.container) end
        part:setCondition(state.condition)
        part:setContainerCapacity(state.capacity)
        part:setContainerContentAmount(state.amount)
    end
    bike:setInitialMass(saved.mass); bike:updateTotalMass()
    -- Native B42 VehicleEngine.setFeatures stores floor(input * 0.37037036).
    -- getEngineLoudness is that stored output, so undo the scaling first.
    bike:setEngineFeature(saved.quality,math.ceil(saved.loudness/0.37037035822868347),saved.power)
end
local function initParts(bike,saved)
    for _,state in ipairs(saved.parts) do
        if state.init and state.init~="" then
            local f=_G
            for key in string.gmatch(state.init,"[^.]+") do f=f and f[key] end
            if f then f(bike,bike:getPartById(state.id)) end
        end
    end
end
function P.Apply(bike,mounted)
    local target=mounted and P.MOUNTED or P.NORMAL
    local original=bike:getScript():getFullName()
    if original==target and (not applied[bike] or applied[bike]==target) then applied[bike]=target; return end
    if original~=P.NORMAL and original~=P.MOUNTED then error("Wrong carrier physics vehicle") end
    -- Dedicated servers have no local Bullet vehicle body to rebuild. Keep
    -- the authoritative script/serialized identity consistent without calling
    -- the client physics reload path on a server thread.
    if isServer() then bike:setScript(target); applied[bike]=target; return end
    local saved={parts={},mass=bike:getInitialMass(),quality=bike:getEngineQuality(),
        loudness=bike:getEngineLoudness(),power=bike:getEnginePower()}
    local changes,parents={},{}
    for i=0,bike:getPartCount()-1 do
        local part=bike:getPartByIndex(i)
        local state={id=part:getId(),item=part:getInventoryItem(),container=part:getItemContainer(),
            condition=part:getCondition(),capacity=part:getContainerCapacity(),
            amount=part:getContainerContentAmount(),init=part:getLuaFunction("init")}
        saved.parts[#saved.parts+1]=state
        protectCallback(part:getLuaFunction("create"),bike,changes,parents)
        protectCallback(state.init,bike,changes,parents)
    end
    P.busy[bike]=true
    local ok,err=pcall(function()
        bike:setScript(target)
        bike:scriptReloaded()
    end)
    if not ok then
        -- Roll back the script/body while callbacks remain protected, then
        -- always restore the original physical items and callback definitions.
        pcall(function() bike:setScript(original); bike:scriptReloaded() end)
    end
    local restored,restoreErr=pcall(restoreParts,bike,saved)
    restoreCallbacks(changes,parents)
    P.busy[bike]=nil
    if not restored then error(restoreErr) end
    if not ok then error(err) end
    if EmreRE9.Tires and EmreRE9.Tires.Invalidate then EmreRE9.Tires.Invalidate(bike) end
    initParts(bike,saved)
    -- Initialization may refresh stats/visibility. Preserve contents/condition
    -- and engine tuning once more after those callbacks have run.
    restoreParts(bike,saved)
    if mounted then
        -- A rebuilt controller can start disabled while its Bullet body is
        -- still dynamic. Force the transition that establishes a static mount.
        bike:setPhysicsActive(true); bike:setPhysicsActive(false)
    end
    applied[bike]=target
end
return P
