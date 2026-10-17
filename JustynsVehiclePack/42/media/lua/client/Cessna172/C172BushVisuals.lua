require "Cessna172/C172Phys"
require "Cessna172/C172GroundHandling"
require "Cessna172/C172WheelSpin"
require "Cessna172/C172LampRig"
local ids = {"C172BushDetail1","C172BushDetail2","C172BushDetail3","C172BushDetail4","C172BushDetail5"}
local mountedIds = {"C172MountedBike1","C172MountedBike2","C172MountedBike3","C172MountedBike4","C172MountedBike5","C172MountedBike6","C172MountedBike7","C172MountedBike8","C172MountedBike9","C172MountedBike10","C172MountedBike11","C172MountedBike12","C172MountedBike13","C172MountedBike14","C172MountedBike15","C172MountedBike16","C172MountedBike17","C172MountedBike18","C172MountedBike19","C172MountedBike20","C172MountedBike21","C172MountedBike22"}
local seen, nextScan = {}, 0
local function setModels(v,ids,visible)
    for _,partId in ipairs(ids) do
        local part=v:getPartById(partId)
        if part then part:setModelVisible("fixed",visible) end
    end
end
local function tick()
    local now=getTimestampMs()
    if now<nextScan then return end
    nextScan=now+250
    local player=getSpecificPlayer(0)
    if not player then return end
    local count=C172Phys.c172ScanNearbyAircraft(player:getX(),player:getY(),70)
    local keep={}
    for i=0,count-1 do
        local v=C172Phys.c172NearbyAircraft(i)
        if v and not v:isRemovedFromWorld() then
            C172GroundHandling.parking(v)
            C172WheelSpin.register(v)
            C172LampRig.register(v)
            C172LampRig.update(v)
            local id=v:getId();keep[id]=seen[id]
            local state=seen[id]
            if not state or state.vehicle~=v then
                state={vehicle=v};keep[id]=state
                setModels(v,ids,true)
            end
            local on=v:isEngineRunning()
            if state.navigation~=on then
                setModels(v,{"C172NavPort","C172NavStarboard"},on)
                state.navigation=on
            end
            local part=v:getPartById("TruckBed")
            local carrier=EmreRE9 and EmreRE9.Carrier
            local record
            if carrier then record=carrier.Record(v)
            else record=part and part:getModData().emreRE9Carrier end
            local mounted=record and record.role=="car" and record.token~=nil or false
            if state.mounted~=mounted then
                setModels(v,mountedIds,mounted);state.mounted=mounted
            end
        end
    end
    seen=keep
end
Events.OnTick.Add(tick)
Events.OnGameStart.Add(function() seen={};nextScan=0 end)
