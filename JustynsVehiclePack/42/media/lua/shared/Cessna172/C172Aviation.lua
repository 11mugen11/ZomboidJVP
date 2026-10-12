--[[
    C172Aviation - the Cessna's registration with the shared Aviation framework.

    THIS IS THE WHOLE OF THE CESSNA'S SKILL INTEGRATION, and it is deliberately tiny. Every
    aircraft-agnostic mechanism - the perk, the XP curve, the books, the loot, the level
    query, the refusal wording - lives in Aviation/AviationFramework.lua and knows nothing
    about this aeroplane. What is Cessna-specific is exactly what is below: which vehicle,
    what it is called, and what level it takes to fly.

    A FUTURE AIRCRAFT MOD COPIES THIS FILE AND CHANGES FOUR LINES. It does not touch the
    framework, and it does not touch this mod. That is the entire integration contract:

        require "Aviation/AviationFramework"
        Aviation.registerAircraft{
            id = "Base.YourAircraft", name = "Your Aircraft",
            minLevel = 5, mod = "YourMod", apiVersion = 1,
        }

    WHY LEVEL 2. Volume 1 of the aviation manuals covers levels 1 and 2, so one book that a
    player can realistically find is exactly enough to earn the Cessna - the intended loop is
    "find the aeroplane, then find the book that lets you fly it", not "grind five levels". A
    172 is also the aircraft real students learn on, so a low bar is the honest one; heavier
    and faster aircraft are where the framework's higher levels are meant to be spent.

    DEGRADED-MODE BEHAVIOUR. If the framework file is missing (a partial install, or someone
    deleting the Aviation folder) this file does nothing at all and the aircraft flies exactly
    as it did before the skill existed. An aircraft mod must not be bricked by the absence of
    its training system.
]]

if not Aviation then
    local ok = pcall(function() require "Aviation/AviationFramework" end)
    if not ok or not Aviation then
        print("[Cessna172] Aviation framework not present - the skill requirement is disabled " ..
              "and the aircraft flies unrestricted.")
        return
    end
end

C172Aviation = C172Aviation or {}

C172Aviation.AIRCRAFT_ID = "Base.Cessna172"
C172Aviation.MIN_LEVEL   = 2

local function register()
    if C172Aviation.registered then return end
    local ok = Aviation.registerAircraft{
        id         = C172Aviation.AIRCRAFT_ID,
        name       = "Cessna 172",
        minLevel   = C172Aviation.MIN_LEVEL,
        mod        = "Cessna172",
        apiVersion = 1,
        -- The default wording is already correct; this exists to point the player at what to
        -- do about it, which a bare number does not.
        deniedText = function(ctx)
            return ("You do not know how to fly the Cessna 172 yet.  " ..
                    "Aviation %d, level %d required - read an aviation manual.")
                :format(ctx.current or 0, ctx.required or 0)
        end,
    }
    C172Aviation.registered = ok and true or false
end

register()
if Events then
    if Events.OnGameBoot then Events.OnGameBoot.Add(register) end
    if Events.OnGameStart then Events.OnGameStart.Add(register) end
    if Events.OnServerStarted then Events.OnServerStarted.Add(register) end
end

-- Convenience wrapper so the flight controller does not have to know the id string.
function C172Aviation.canFly(character)
    if not Aviation then return true, nil end
    return Aviation.canFly(character, C172Aviation.AIRCRAFT_ID)
end

return C172Aviation
