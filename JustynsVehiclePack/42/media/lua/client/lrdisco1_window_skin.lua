-- Viewpoint uses mask colours to select its transparent vehicle-glass pass.
-- Both retained skin indices use opaque, black-tinted glazing at all times.
LRDiscoWindowSkin = LRDiscoWindowSkin or {}
local W = LRDiscoWindowSkin
local kinds = { ["Base.lrdisco1"]=true, ["Base.lrdisco1camel"]=true, ["Base.lrdisco1bbar"]=true }
local last = -1000
function W.Apply(v)
    local script = v and v:getScript()
    if not script or not kinds[script:getFullName()] then return end
    local index = 0
    if v:getSkinIndex() ~= index then v:setSkinIndex(index); v:updateSkin() end
end
function W.Tick()
    local now=getTimestampMs()
    if now-last<100 then return end
    last=now
    local cell=getCell()
    local vehicles=cell and cell:getVehicles()
    if not vehicles then return end
    local iterator=vehicles:iterator()
    while iterator:hasNext() do W.Apply(iterator:next()) end
end
Events.OnTick.Add(W.Tick)
Events.OnGameStart.Add(function() last=-1000; W.Tick() end)
