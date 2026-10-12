-- C172NoAirExit - no getting out while it is in the air, and no NPC damage while flying (09-26).
--
-- Jay: "make sure you can never exit aircraft while in air, I noticed it happened for one of
-- them". Vanilla's ISExitVehicle:isValid only asks vehicle:isStopped() - and an aircraft
-- hovering, or slowed right down, IS stopped as far as the car code knows, so the Exit slice
-- and the E key let you step out in mid-air. Two wrappers close every route:
--   * ISVehicleMenu.onExit (radial Exit slice, the E key, the seat UI, the mechanics window):
--     refuses with a halo note, so no door opens and nothing is queued;
--   * ISExitVehicle:isValid - the one thing every exit path ends in - refuses too, so a
--     queued or third-party exit can never complete in the air.
-- "In the air" = this aircraft's own flight model says airborne. A height test was tried and
-- dropped: an aircraft parked on a roof, or the MiG's tall resting body, would read as airborne
-- and lock the player INSIDE a parked aircraft - far worse than the gap it covered (an MP
-- passenger whose client does not run the flight model). Only the Cessna is affected; every other vehicle calls straight through.
-- Installed on OnGameBoot/OnGameStart (ISUI globals are nil at file load); the flag on the
-- class keeps it to one wrap per session, and each aircraft mod wraps the previous function,
-- so the three chain in any load order.

local function airborne(v)
    if not v or not (C172Util and C172Util.getConfig(v) ~= nil) then return false end
    local ok, a = pcall(function() return C172Flight and C172Flight.isAirborne(v) end)
    return ok and a == true
end

-- NOBODY CAN HURT YOU WHILE YOU FLY (09-26). Jay: "bandits npc easily killed me while i was
-- hovering still in air, they shouldnt be able to kill me ever while airborne". The Bandits mod
-- (Workshop 3268487204) does not use PZ's combat code on players at all: BanditUtils.Hit calls
-- PlayerDamageModel.BulletHit / MeleeHit / BareHandHit, which send a 'PlayerDamage' client
-- command, and BanditServer.Commands.PlayerDamage then writes the wounds and health loss
-- straight into BodyDamage - so nothing in the aircraft (collision patches, height) stops it.
-- All four are wrapped: a player sitting in this aircraft while it is airborne is skipped,
-- everyone else goes straight through. Only installed if the Bandits mod is loaded. (setGodMod
-- would also work but it is an admin cheat that an MP server can revert or flag.)
local function protectedPlayer(p)
    local ok, v = pcall(function() return instanceof(p, "IsoPlayer") and p:getVehicle() end)
    return ok and v and airborne(v) or false
end

local function wrapBanditDamage()
    local P = PlayerDamageModel
    if type(P) == "table" and not P.__c172AirSafe then
        P.__c172AirSafe = true
        local bullet, bare, melee = P.BulletHit, P.BareHandHit, P.MeleeHit
        if bullet then P.BulletHit = function(shooter, item, player, ...)
            if protectedPlayer(player) then return end
            return bullet(shooter, item, player, ...)
        end end
        if bare then P.BareHandHit = function(shooter, player, ...)
            if protectedPlayer(player) then return end
            return bare(shooter, player, ...)
        end end
        if melee then P.MeleeHit = function(shooter, player, item, ...)
            if protectedPlayer(player) then return end
            return melee(shooter, player, item, ...)
        end end
    end
    local C = type(BanditServer) == "table" and BanditServer.Commands
    if type(C) == "table" and C.PlayerDamage and not C.__c172AirSafe then
        C.__c172AirSafe = true
        local apply = C.PlayerDamage
        C.PlayerDamage = function(player, args, ...)
            if protectedPlayer(player) then return end
            return apply(player, args, ...)
        end
    end
end

local function refuse(player)
    pcall(function()
        HaloTextHelper.addBadText(player, "Land before you get out")
    end)
end

local function install()
    if not (ISExitVehicle and ISVehicleMenu) or ISExitVehicle.__c172NoAirExit then return end
    ISExitVehicle.__c172NoAirExit = true
    local baseValid = ISExitVehicle.isValid
    function ISExitVehicle:isValid()
        local v = self.character and self.character:getVehicle()
        if airborne(v) then return false end
        return baseValid(self)
    end
    local baseOnExit = ISVehicleMenu.onExit
    ISVehicleMenu.onExit = function(playerObj, seatFrom, ...)
        local v = playerObj and playerObj:getVehicle()
        if airborne(v) then refuse(playerObj) return end
        return baseOnExit(playerObj, seatFrom, ...)
    end
end

Events.OnGameBoot.Add(install)
Events.OnGameStart.Add(install)
-- The Bandits server file (BanditServer.Commands) loads with the server Lua, after OnGameBoot,
-- so the damage wrap is retried at game start too; the flags keep it to one wrap each.
Events.OnGameBoot.Add(function() pcall(wrapBanditDamage) end)
Events.OnGameStart.Add(function() pcall(wrapBanditDamage) end)
