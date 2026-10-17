-- Separate visual wheel assemblies; native wheel/suspension physics is unchanged.
require "Cessna172/C172Phys"
C172WheelSpin = {}
local W, P = C172WheelSpin, C172Phys
local D = 3.1922 / 11
local parts = {
    { id = "C172WheelPort", cy = -1.35 * D, cz = .12 * D, radius = .58 * D },
    { id = "C172WheelStarboard", cy = -1.35 * D, cz = .12 * D, radius = .58 * D },
    { id = "C172WheelTail", cy = -.55 * D, cz = -5.05 * D, radius = .20 * D },
}
local records, lastMs = {}, nil
W.records = records
local function install(v)
    local id = v:getId()
    local existing = records[id]
    if existing and existing.vehicle == v then return existing end
    local owned = VehicleScript.new()
    owned:setModule(v:getScript():getModule())
    owned:InitLoadPP("C172WheelRender")
    local definition = "vehicle C172WheelRender {"
    for _,spec in ipairs(parts) do
        definition = definition .. " part " .. spec.id .. " { category = nodisplay, model rolling { file = "
            .. spec.id .. ", offset = 0 0 0, rotate = 0 0 0, } }"
    end
    owned:Load("C172WheelRender", definition .. " }")
    local r = { vehicle = v, script = owned, wheels = {} }
    for _,spec in ipairs(parts) do
        local part = v:getPartById(spec.id)
        local mine = owned:getPartById(spec.id)
        if part and mine then
            part:setAllModelsVisible(false)
            part:setScriptPart(mine)
            part:setAllModelsVisible(true)
            r.wheels[#r.wheels+1] = { spec = spec, model = mine:getModelById("rolling"), angle = 0 }
        end
    end
    if #r.wheels ~= 3 then return nil end
    records[id] = r
    return r
end
function W.register(v) return install(v) end
function W.advance(r, dt)
    local v = r.vehicle
    if C172GroundHandling and C172GroundHandling.isParked(v) then return end
    local remote = P.remoteFlying and P.remoteFlying[v:getId()]
    if P.isFlying(v) or (remote and getTimestampMs()-remote.at<P.REMOTE_FRESH_MS) then return end
    local h = P.c172GetBodyHeight(v)
    if not h or h-P.c172SurfaceHeightBelow(v)>P.restingHeight(v,0)+.35 then return end
    local vx, _, vz = P.velocity(v)
    local fx, fz = P.forward(v)
    local speed = vx*fx+vz*fz
    if math.abs(speed)<.025 then return end
    local scale = v:getScript():getModelScale()
    for _,wheel in ipairs(r.wheels) do
        local spec = wheel.spec
        wheel.angle = (wheel.angle + speed*dt/(spec.radius*scale)) % (2*math.pi)
        local c,s = math.cos(wheel.angle),math.sin(wheel.angle)
        -- Model X rotation is positive; its Y/Z translation is not mirrored.
        -- Compensation keeps the complete wheel's hub fixed on its axle.
        wheel.model:getRotate():set(math.deg(wheel.angle),0,0)
        wheel.model:getOffset():set(0,spec.cy-(c*spec.cy-s*spec.cz),spec.cz-(s*spec.cy+c*spec.cz))
    end
end
function W.frame()
    local now = getTimestampMs()
    local dt = lastMs and (now-lastMs)/1000 or 0
    lastMs = now
    if dt<=0 or dt>.1 or isGamePaused() then return end
    for id,r in pairs(records) do
        if r.vehicle:isRemovedFromWorld() then records[id]=nil else W.advance(r,dt) end
    end
end
Events.OnRenderTick.Add(W.frame)
Events.OnGameStart.Add(function() records={};W.records=records;lastMs=nil end)
return W
