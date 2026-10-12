require "Vehicles/TimedActions/ISEnterVehicle"
require "Vehicles/TimedActions/ISExitVehicle"
require "Vehicles/TimedActions/ISStopVehicle"
require "Vehicles/TimedActions/ISPathFindAction"
require "Vehicles/TimedActions/ISHotwireVehicle"
require "Vehicles/ISUI/ISVehicleMenu"
require "emre_re9_settling"
EmreRE9 = EmreRE9 or {}
if EmreRE9.Rider then return EmreRE9.Rider end
local R = {}; EmreRE9.Rider = R
local mounted, anchored, lastSide = setmetatable({}, {__mode="k"}), setmetatable({}, {__mode="k"}), setmetatable({}, {__mode="k"})
function R.IsBike(v)
    local s = v and v:getScript()
    return s and s:getFullName() == "Base.EMRE_RE9"
end
function R.Prime(c, v, seat)
    seat = seat or v:getSeat(c)
    if seat < 0 then return end
    if mounted[c] == nil then mounted[c] = c:isHideWeaponModel() end
    c:setVariable("EMRE_RE9Type", seat == 0 and "RE90" or "RE91")
    c:setVariable("EMRE_RE9Passenger", v:getCharacter(seat == 0 and 1 or 0) and "stop" or "none")
    local speed = v:getCurrentSpeedKmHour()
    c:setVariable("EMRE_RE9Motion", speed > 1 and "forward" or speed < -1 and "backward" or "stop")
    c:setHideWeaponModel(true)
end
function R.Clear(c)
    anchored[c] = nil
    if mounted[c] == nil then return end
    for _, k in ipairs({"EMRE_RE9Type", "EMRE_RE9Passenger", "EMRE_RE9Motion", "EMRE_RE9Side"}) do c:clearVariable(k) end
    c:setHideWeaponModel(mounted[c]); mounted[c] = nil
end
function R.Update(c)
    if not c then return end
    local v = c:getVehicle()
    if not R.IsBike(v) then R.Clear(c); return end
    EmreRE9.Settling.DriverUpdate(v, c)
    if c:getVariableString("bEnteringVehicle") == "true" or c:getVariableString("bExitingVehicle") == "true" then return end
    local seat = v:getSeat(c); R.Prime(c, v, seat)
    local prev = anchored[c]
    if seat >= 0 and (not prev or prev.vehicle ~= v or prev.seat ~= seat) then
        v:setCharacterPosition(c, seat, "inside"); v:transmitCharacterPosition(seat, "inside")
        anchored[c] = {vehicle=v, seat=seat}
    end
end
function R.NearestSide(c, v, seat)
    local p, dist = Vector3f.new(), {}
    for _, side in ipairs({"left", "right"}) do
        v:getPassengerPositionWorldPos(v:getPassengerPosition(seat, side == "right" and "outside2" or "outside"), p)
        dist[side] = (c:getX()-p:x())^2 + (c:getY()-p:y())^2
    end
    return dist.right < dist.left and "right" or "left"
end
-- Both entrances are inside vanilla's two-metre outside2 shortcut. Select the
-- nearest side, then retain native installed/occupied/obstructed-seat checks.
local oldOnEnter = ISVehicleMenu.onEnter
function ISVehicleMenu.onEnter(c, v, seat)
    if not R.IsBike(v) or v:isSeatOccupied(seat) then return oldOnEnter(c, v, seat) end
    if isShiftKeyDown() and seat ~= 0 then seat = 0 end
    if v:isSeatOccupied(seat) then return oldOnEnter(c, v, seat) end
    local menu = getPlayerRadialMenu(c:getPlayerNum())
    if menu and menu:isReallyVisible() then menu:undisplay() end
    if R.NearestSide(c, v, seat) == "right" then return ISVehicleMenu.processEnter2(c, v, seat) end
    return ISVehicleMenu.processEnter(c, v, seat)
end
local function queueEntry(c, v, seat, right)
    local slot = seat == 0 and "Front" or "Rear"
    ISTimedActionQueue.add(ISPathFindAction:pathToVehicleArea(c, v, "Seat"..slot..(right and "Right" or "Left")))
    local a = ISEnterVehicle:new(c, v, seat)
    a.emreRE9Side = right and "right" or "left"; a.emreRE9Outside = right and "outside2" or "outside"
    ISTimedActionQueue.add(a)
end
local oldAux, oldAux2 = ISVehicleMenu.onEnterAux, ISVehicleMenu.onEnterAux2
function ISVehicleMenu.onEnterAux(c, v, seat)
    if R.IsBike(v) then return queueEntry(c, v, seat, false) end
    return oldAux(c, v, seat)
end
function ISVehicleMenu.onEnterAux2(c, v, seat)
    if R.IsBike(v) then return queueEntry(c, v, seat, true) end
    return oldAux2(c, v, seat)
end
local enterStart, enterUpdate = ISEnterVehicle.start, ISEnterVehicle.update
local enterPerform, enterStop = ISEnterVehicle.perform, ISEnterVehicle.stop
local function releaseTransition(action, entering)
    -- Release ONLY this transition's action flag, before the native perform
    -- starts the next queued action. Do not clear a character-wide lock or
    -- cancel an unrelated repair, hotwire or inventory action.
    if action.action then action.action:setBlockMovementEtc(false) end
    action.character:clearVariable(entering and "bEnteringVehicle" or "bExitingVehicle")
    action.character:clearVariable(entering and "EnterAnimationFinished" or "ExitAnimationFinished")
end
function ISEnterVehicle:start()
    if R.IsBike(self.vehicle) then
        anchored[self.character] = nil
        self.emreRE9Side = self.emreRE9Side or R.NearestSide(self.character, self.vehicle, self.seat)
        self.emreRE9Outside = self.emreRE9Side == "right" and "outside2" or "outside"
        R.Prime(self.character, self.vehicle, self.seat)
        self.character:setVariable("EMRE_RE9Side", self.emreRE9Side); self.emreRE9Start = getTimestampMs()
    end
    local result = enterStart(self)
    if self.emreRE9Start and self.vehicle:getCharacter(self.seat) == self.character then
        self.vehicle:setCharacterPosition(self.character, self.seat, self.emreRE9Outside)
        self.vehicle:transmitCharacterPosition(self.seat, self.emreRE9Outside)
    end
    return result
end
function ISEnterVehicle:update()
    if self.emreRE9Start then
        if self.vehicle:getCharacter(self.seat) ~= self.character then self:forceStop(); return end
        if getTimestampMs()-self.emreRE9Start > 5000 then self.character:setVariable("EnterAnimationFinished", "true") end
        local done = self.character:getVariableString("EnterAnimationFinished") == "true"
        self.vehicle:setCharacterPosition(self.character, self.seat, done and "inside" or self.emreRE9Outside)
    end
    return enterUpdate(self)
end
function ISEnterVehicle:perform()
    if self.emreRE9Start then
        releaseTransition(self, true)
        EmreRE9.Settling.ReleaseExit(self.vehicle)
    end
    local result = enterPerform(self)
    if self.emreRE9Start then
        lastSide[self.character] = {vehicle=self.vehicle, seat=self.seat, side=self.emreRE9Side}
        R.Prime(self.character, self.vehicle, self.seat); self.emreRE9Start = nil
    end
    return result
end
function ISEnterVehicle:stop()
    local ours = self.emreRE9Start ~= nil
    if ours then releaseTransition(self, true); EmreRE9.Settling.ReleaseExit(self.vehicle) end
    local result = enterStop(self)
    if ours then R.Clear(self.character); self.emreRE9Start = nil end
    return result
end
function R.ExitBlocked(c, v, seat, side)
    if side == "right" then return v:isExitBlocked2(seat) end
    return v:isExitBlocked(c, seat)
end
-- Wait for the real native stopped condition before starting the existing
-- dismount animation. Small rollback can otherwise invalidate ISExitVehicle
-- between the click and the first animation tick.
local StopForExit = ISStopVehicle:derive("ISRE9StopForExit")
function StopForExit:isValid()
    return self.character:getVehicle() == self.emreRE9Vehicle
        and self.emreRE9Vehicle:isDriver(self.character)
end
function StopForExit:start()
    self.emreRE9Started = getTimestampMs()
    self.emreRE9Vehicle:setForceBrake()
    EmreRE9.Settling.PrepareExit(self.emreRE9Vehicle)
end
function StopForExit:update()
    local v, now = self.emreRE9Vehicle, getTimestampMs()
    if EmreRE9.Settling.HasDriveInput(v) then self:forceStop(); return end
    v:setForceBrake()
    EmreRE9.Settling.UpdateVehicle(v, now, true)
    if v:isStopped() then
        self.emreRE9StoppedSince = self.emreRE9StoppedSince or now
        if EmreRE9.Settling.IsHeld(v) or now - self.emreRE9StoppedSince >= 1000 then
            self:forceComplete(); return
        end
    else self.emreRE9StoppedSince = nil end
    if now - self.emreRE9Started > 15000 then self:forceStop() end
end
function StopForExit:stop()
    EmreRE9.Settling.ReleaseExit(self.emreRE9Vehicle)
    self.emreRE9Vehicle:updateHasExtendOffsetForExitEnd(self.character)
    ISBaseTimedAction.stop(self)
end
function StopForExit:new(c, v)
    local a = ISStopVehicle.new(self, c)
    a.emreRE9Vehicle = v
    a.stopOnAim = false
    return a
end
function R.RequestExit(c, side)
    local v = c and c:getVehicle()
    if not R.IsBike(v) or c:isBlockMovement() then return end
    local seat, explicit = v:getSeat(c), side ~= nil
    if not side then
        local prev = lastSide[c]
        side = prev and prev.vehicle == v and prev.seat == seat and prev.side or (seat == 0 and "left" or "right")
    end
    v:updateHasExtendOffsetForExit(c)
    if R.ExitBlocked(c, v, seat, side) and not explicit then side = side == "left" and "right" or "left" end
    if R.ExitBlocked(c, v, seat, side) then
        HaloTextHelper.addBadText(c, getText("IGUI_RE9_ExitBlocked")); v:updateHasExtendOffsetForExitEnd(c); return
    end
    if seat ~= 0 and not v:isStopped() then
        HaloTextHelper.addBadText(c, getText("IGUI_PlayerText_CanNotExitFromMovingCar")); v:updateHasExtendOffsetForExitEnd(c); return
    end
    v:setForceBrake(); EmreRE9.Settling.PrepareExit(v)
    if seat == 0 and (not EmreRE9.Settling.IsHeld(v) or not v:isStopped()) then
        ISTimedActionQueue.add(StopForExit:new(c, v))
    end
    local menu = getPlayerRadialMenu(c:getPlayerNum())
    if menu and menu:isReallyVisible() then menu:undisplay() end
    local a = ISExitVehicle:new(c); a.emreRE9Side, a.emreRE9Seat = side, seat; ISTimedActionQueue.add(a)
end
local oldExit = ISVehicleMenu.onExit
function ISVehicleMenu.onExit(c, seat)
    if R.IsBike(c and c:getVehicle()) then return R.RequestExit(c) end
    return oldExit(c, seat)
end
local exitStart, exitUpdate, exitValid = ISExitVehicle.start, ISExitVehicle.update, ISExitVehicle.isValid
local exitPerform, exitStop = ISExitVehicle.perform, ISExitVehicle.stop
function ISExitVehicle:isValid()
    if not exitValid(self) then return false end
    if self.emreRE9Side and R.IsBike(self.vehicle) then return not R.ExitBlocked(self.character, self.vehicle, self.emreRE9Seat, self.emreRE9Side) end
    return true
end
function ISExitVehicle:start()
    local v = self.character:getVehicle()
    if R.IsBike(v) then
        self.emreRE9Seat = v:getSeat(self.character)
        self.emreRE9Side = self.emreRE9Side or (self.emreRE9Seat == 0 and "left" or "right")
        self.emreRE9Vehicle = v; R.Prime(self.character, v, self.emreRE9Seat)
        self.character:setVariable("EMRE_RE9Side", self.emreRE9Side); self.emreRE9Start = getTimestampMs(); v:setForceBrake()
    end
    return exitStart(self)
end
function ISExitVehicle:update()
    if self.emreRE9Start then
        local v = self.character:getVehicle()
        if not R.IsBike(v) then self:forceStop(); return end
        v:setForceBrake()
        if getTimestampMs()-self.emreRE9Start > 5000 then self.character:setVariable("ExitAnimationFinished", "true") end
    end
    return exitUpdate(self)
end
function ISExitVehicle:perform()
    local v, seat, side = self.emreRE9Vehicle, self.emreRE9Seat, self.emreRE9Side
    if v then releaseTransition(self, false) end
    local result = exitPerform(self)
    if v then
        EmreRE9.Settling.FinishExit(v)
        v:setCharacterPosition(self.character, seat, side == "right" and "outside2" or "outside")
        R.Clear(self.character); self.emreRE9Start = nil
    end
    return result
end
function ISExitVehicle:stop()
    if self.emreRE9Vehicle then
        releaseTransition(self, false)
        EmreRE9.Settling.ReleaseExit(self.emreRE9Vehicle)
    end
    local result = exitStop(self)
    if self.emreRE9Vehicle then
        self.emreRE9Vehicle:updateHasExtendOffsetForExitEnd(self.character)
        self.emreRE9Start = nil; R.Update(self.character)
    end
    return result
end
-- Use the actual native timed action, including server complete()/tryHotwire().
-- Do not cancel it when the player looks around on an open vehicle.
local hotwireNew = ISHotwireVehicle.new
function ISHotwireVehicle:new(c)
    local a = hotwireNew(self, c)
    if R.IsBike(c:getVehicle()) then a.stopOnAim = false end
    return a
end
function R.CanHotwire(c, v)
    return v:isDriver(c) and not v:isHotwired() and not v:isEngineStarted() and not v:isEngineRunning()
        and not SandboxVars.VehicleEasyUse and not v:isKeysInIgnition() and not c:getInventory():haveThisKeyId(v:getKeyId())
end
local radial = ISVehicleMenu.showRadialMenu
function ISVehicleMenu.showRadialMenu(c)
    local result = radial(c); local v = c and c:getVehicle()
    if not R.IsBike(v) then return result end
    local menu = getPlayerRadialMenu(c:getPlayerNum())
    if not menu or not menu:isReallyVisible() then return result end
    local texture = getTexture("media/ui/vehicles/vehicle_exit.png")
    menu:addSlice(getText("IGUI_RE9_ExitLeft"), texture, R.RequestExit, c, "left")
    menu:addSlice(getText("IGUI_RE9_ExitRight"), texture, R.RequestExit, c, "right")
    if R.CanHotwire(c, v) then
        local found = false
        for _, s in ipairs(menu.slices or {}) do
            if s.text == getText("ContextMenu_VehicleHotwire") or s.text == getText("ContextMenu_VehicleHotwireSkill") then found = true end
        end
        if not found then
            local skilled = (c:getPerkLevel(Perks.Electricity) >= 1 and c:getPerkLevel(Perks.Mechanics) >= 2) or c:hasTrait(CharacterTrait.BURGLAR)
            menu:addSlice(getText(skilled and "ContextMenu_VehicleHotwire" or "ContextMenu_VehicleHotwireSkill"), getTexture("media/ui/vehicles/vehicle_ignitionON.png"), skilled and ISVehicleMenu.onHotwire or nil, c)
        end
    end
    return result
end
Events.OnPlayerUpdate.Add(R.Update)
Events.OnCreatePlayer.Add(function(index, c) R.Update(c) end)
Events.OnEnterVehicle.Add(R.Update)
Events.OnExitVehicle.Add(function(c) if c then R.Clear(c) end end)
Events.OnRefreshInventoryWindowContainers.Add(function(page, stage)
    if stage ~= "buttonsAdded" or not page or not page.backpacks or #page.backpacks > 0 then return end
    local c = getSpecificPlayer(page.player); local v = c and c:getVehicle()
    if not R.IsBike(v) then return end
    local part = v:getPartById("RE9CaseFrontLeft"); local container = part and part:getItemContainer()
    if container then
        local title = getText("IGUI_VehiclePartRE9CaseFrontLeft")
        local button = page:addContainerButton(container, nil, title, title)
        if button and page.inventoryPane then page.inventoryPane.inventory = container end
    end
end)
return R
