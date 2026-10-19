-- Restore the current Rover seat after saved/network passenger offsets replace it.
-- Cessna and motorcycle animation variables must not follow a player into a car.
require "Cessna172/C172Variants"
local S = {}
JVPSeatAlignment = S
local rovers = { ["Base.lrdisco1"]=true, ["Base.lrdisco1camel"]=true,
                 ["Base.lrdisco1bbar"]=true }
local poseVars = {"EMRE_RE9Type", "EMRE_RE9Passenger",
                  "EMRE_RE9Motion", "EMRE_RE9Side"}
local localPos

function S.update(c)
    if not c then return end
    local v = c:getVehicle()
    local script = v and v:getScript()
    if not script then return end
    local aircraft = C172Variants.isVehicle(v)
    if not aircraft and not rovers[script:getFullName()] then return end
    for _, key in ipairs(poseVars) do
        if c:getVariableString(key) ~= "" then c:clearVariable(key) end
    end
    if not aircraft then c:clearVariable("C172Pose") end
    if c:getVariableBoolean("bEnteringVehicle") or c:getVariableBoolean("bExitingVehicle") then return end
    local state = c:getAnimationStateName()
    if state == "enter" or state == "exit" then return end
    local seat = v:getSeat(c)
    local pose = aircraft and ({[0]="Front", [1]="Rear"})[seat] or nil
    if pose then
        if c:getVariableString("C172Pose") ~= pose then c:setVariable("C172Pose", pose) end
    elseif aircraft then
        c:clearVariable("C172Pose")
    end
    if aircraft then return end -- C172PilotView owns its animated and elevated roots.
    local passenger = seat >= 0 and script:getPassenger(seat)
    local inside = passenger and passenger:getPositionById("inside")
    if not inside then return end
    localPos = localPos or Vector3f.new()
    local actual = v:getPassengerLocalPos(seat, localPos)
    local p, m = inside:getOffset(), script:getModel():getOffset()
    if not actual or math.abs(actual:x() - p:x() - m:x())
        + math.abs(actual:y() - p:y() - m:y())
        + math.abs(actual:z() - p:z() - m:z()) > 0.01 then
        -- Local repair only: do not send observer corrections back to the owner.
        v:setCharacterPosition(c, seat, "inside")
    end
end

Events.OnPlayerUpdate.Add(S.update)
Events.OnTick.Add(function()
    if not isClient() then return end
    local players = getOnlinePlayers()
    if not players then return end
    for i = 0, players:size() - 1 do
        local c = players:get(i)
        if c and not c:isLocalPlayer() then S.update(c) end
    end
end)
return S
