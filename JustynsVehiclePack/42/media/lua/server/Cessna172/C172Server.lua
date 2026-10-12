--[[
    C172Server - relays this mod's simulated flight state between clients.

    WHAT IS AND IS NOT RELAYED. Real BaseVehicle netcode already replicates position,
    orientation, engine state, damage, fuel container amount and seat occupancy
    automatically. None of that is touched here - re-sending any of it would be a
    duplication and desync source, not a fix. What vanilla cannot replicate is this
    mod's own bolt-on state (simulated altitude, the GROUND/AIRBORNE mode, the
    canopy-clear threshold), because there is no generic transmitModData() on
    BaseVehicle - only per-part transmitPartModData. That, and only that, goes through
    here.

    Propeller phase and engine audio are deliberately NOT relayed either: every client
    derives them locally from isEngineRunning() and getCurrentAbsoluteSpeedKmHour(),
    which vanilla already keeps live for every vehicle. That is why there is no
    per-frame traffic in this mod at all - the only message is one throttled flight
    update every 0.5 s per airborne aircraft.

    THE SERVER IS AUTHORITATIVE ABOUT WHO MAY SEND WHAT. Relaying `args` unchecked would
    let any client claim any altitude for any vehicle id, and every other client would
    apply it - and altitude feeds a collision-relevant decision (isAboveCanopy), so this
    is not merely untidy. Every message is confirmed against the SERVER's own view
    before being relayed: the sender must actually be the driver of the specific vehicle
    they are reporting on, and every value must be a finite number in a plausible range.
    A message that fails validation is dropped and logged, never relayed and never
    thrown - consistent with how every other failure in this mod degrades.

    RUNS ON: the dedicated server in MP, and the in-process internal server in single
    player. Never on an MP client. This is the standard media/lua/server contract and is
    why no client-only API is referenced anywhere in this file.
]]

require "Cessna172/C172Systems"
require "Cessna172/C172ServerContacts"

local MAX_PLAUSIBLE_ALTITUDE = 60     -- the aircraft's own ceiling is 4.0; huge margin
local MAX_PLAUSIBLE_AIRSPEED = 300    -- generous margin above MAX_AIRSPEED_KMH (118)
local VALID_MODES = { GROUND = true, TAKEOFF = true, AIR = true, LANDING = true }

local function isFiniteNumber(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function isPlayerFlyingVehicle(player, vehicleId)
    if not player or not isFiniteNumber(vehicleId) then return false end
    local okVeh, vehicle = pcall(function() return player:getVehicle() end)
    if not okVeh or not vehicle then return false end
    local okId, id = pcall(function() return vehicle:getId() end)
    if not okId or id ~= vehicleId then return false end
    -- Second gate: it must actually be this aircraft, so a client cannot use this
    -- channel to push aircraft state onto a car it happens to be driving.
    local okName, name = pcall(function() return vehicle:getScriptName() end)
    if not okName or name ~= "Base.Cessna172" then return false end
    local okDrv, isDriver = pcall(function() return vehicle:isDriver(player) end)
    return okDrv and isDriver == true
end


-- ------------------------------------------------------- airframe hour meter
--
-- Integrates real airborne time from the flightUpdate stream, which by the time this runs
-- has already been proven to come from the confirmed driver of that specific Cessna.
--
-- THE CLOCK IS getWorldAgeHours(), NOT WALL TIME. That is a monotonic in-game hour count,
-- so the difference between two samples is game hours directly - no conversion through
-- minutesPerDay, no getMultiplier(), and it stays correct when the player fast-forwards
-- time or the server tick rate wobbles. Converting wall seconds by hand would have been
-- three chances to get the units wrong in a number whose only job is to be trustworthy.
--
-- A gap larger than MAX_GAP_HOURS - a disconnect, a chunk unload, the pilot getting out -
-- is DISCARDED rather than counted. A meter that jumps because somebody's connection
-- dropped is worse than one that quietly misses that interval.
local lastAgeHours = {}
local MAX_GAP_HOURS = 0.1      -- 6 game minutes; the publish interval is 0.5 real seconds

local function worldAgeHours()
    local ok, h = pcall(function() return getGameTime():getWorldAgeHours() end)
    if ok and type(h) == "number" and h == h then return h end
    return nil
end

local function trackAirborneTime(vehicleId, mode)
    local now = worldAgeHours()
    if not now then return end
    local prev = lastAgeHours[vehicleId]
    lastAgeHours[vehicleId] = now
    if not prev then return end
    local dt = now - prev
    if dt <= 0 or dt > MAX_GAP_HOURS then return end
    if not mode or mode == "GROUND" then return end
    if type(C172Systems) ~= "table" or type(C172Systems.addAirframeMinutes) ~= "function" then
        return
    end
    -- Looked up with the game's own getVehicleById global (what vanilla's VehicleCommands
    -- uses; it answers on the Java side), never through VehicleManager.instance from Lua:
    -- that is null during load and indexing it goes straight THROUGH pcall. This only runs
    -- on a client's packet, so the world exists. (Up to 1.8.1 it was the Java bridge.)
    if type(vehicleId) ~= "number" or not getVehicleById then return end
    local okV, vehicle = pcall(getVehicleById, vehicleId)
    if not (okV and vehicle) then return end
    local okN, name = pcall(function() return vehicle:getScriptName() end)
    if not (okN and name == "Base.Cessna172") then return end
    C172Systems.addAirframeMinutes(vehicle, dt * 60.0)
end

-- Rate limit for the "not the driver" rejection log, keyed by username. A rejected packet
-- is always dropped; this only stops the REPORTING of it from flooding a dedicated server.
local rejectLoggedAt = {}
local REJECT_LOG_INTERVAL_MS = 30000

local C172_SCRIPT = "Base.Cessna172"

-- The one gate both debug commands share. Kept as a named function so there is exactly one
-- copy of the rule and no way for a second command to be added with a weaker check.
local function mayDebugCheat(player, what)
    local name = tostring(player:getUsername() or "?")
    local access = "?"
    pcall(function() access = tostring(player:getAccessLevel()) end)

    if not isDebugEnabled() then
        print(("[Cessna172][server] %s from %s REFUSED: this server was not launched with -debug.")
            :format(what, name))
        return false
    end
    if not (access == "admin" or access == "moderator" or isCoopHost()) then
        print(("[Cessna172][server] %s from %s REFUSED: access level '%s' is not admin.")
            :format(what, name, access))
        return false
    end
    return true
end

-- ============================================== debug: set the Aviation level
--
-- WHY THIS HAS TO BE ON THE SERVER. Skills are server-authoritative in multiplayer. A client
-- that calls setPerkLevelDebug on its own character sees the level change and then sees it
-- reverted on the next stat sync - which is exactly the "the debug menu says Aviation 10 and
-- the aircraft still refuses to rotate" symptom. In singleplayer the client write sticks and
-- C172DebugItems does it directly; in MP it has to happen here or it does not happen at all.
--
-- TWO GATES, BOTH REQUIRED, in keeping with this file's rule that the server never takes args
-- on faith:
--   1. The server PROCESS must have been launched with -debug. A normal dedicated server was
--      not, so on a real server this command does not exist at all.
--   2. The SENDER must be an admin (or the coop host). So even on a debug server an ordinary
--      client cannot grant itself a skill by forging the packet.
-- The level itself is clamped to 0-10 before anything is written.
--
-- SET WITH level0() + LevelPerk(), NOT by writing XP. LevelPerk is the call vanilla's own
-- scenarios use to raise a skill, so whatever PZ does on a level-up still happens; computing
-- an XP delta instead would be at the mercy of the server's XP multiplier and would land on
-- the wrong level.
local MAX_PERK_LEVEL = 10

local function onDebugSetAviation(player, args)
    if not player then return end
    if type(args) ~= "table" then return end

    if not mayDebugCheat(player, "debugSetAviation") then return end

    local level = tonumber(args.level)
    if not isFiniteNumber(level) then return end
    level = math.floor(level)
    if level < 0 or level > MAX_PERK_LEVEL then return end

    if not (Aviation and Aviation.isSkillAvailable and Aviation.isSkillAvailable()) then
        print("[Cessna172][server] debugSetAviation: the Aviation skill is NOT registered on " ..
              "the server side, so there is no level to set - and the flight gate is failing " ..
              "OPEN, which means the aircraft should already fly for everyone.")
        return
    end
    local perk = Aviation.perk()
    if not perk then return end

    -- setPerkLevelDebug, because it is one of only two methods that CONSTRUCTS the character's
    -- missing PerkInfo for a mod-added perk (the other being the two-argument LevelPerk).
    -- level0 and the one-argument LevelPerk both read getPerkInfo first and no-op when it is
    -- null, which is every character that existed before this skill did.
    -- Aviation.setLevel writes the ModData authority and mirrors the perk. Setting the perk
    -- alone would be the half PZ does not persist.
    if Aviation.setLevel then
        pcall(function() Aviation.setLevel(player, level) end)
    else
        pcall(function() player:setPerkLevelDebug(perk, level) end)
    end
    local guard = 0

    -- `name` is recomputed here rather than reused: the username/access lookup moved into
    -- mayDebugCheat when the two debug commands were given one shared gate, and leaving the
    -- reference behind made this print raise "missing argument #2 to 'format'" - which, being
    -- inside the handler, killed the whole command. Kahlua reports the format arity failure,
    -- not the nil, so the traceback points at string.format and not at the real mistake.
    local now = Aviation.getLevel(player)
    local who = "?"
    pcall(function() who = tostring(player:getUsername() or "?") end)
    print(("[Cessna172][server] debugSetAviation: %s Aviation -> %d (asked for %d)")
        :format(who, now, level))
    if now ~= level then
        print("[Cessna172][server] WARNING: the level did not land. LevelPerk ran " ..
              tostring(guard) .. " times without reaching the target, which means the perk " ..
              "this server registered is not the one the character carries.")
    end
    -- Still sent, because on a DEDICATED server this is the only way the client hears back.
    -- On a coop host the caller invoked this directly and uses the return value instead - the
    -- host's own client/server messages are not delivered to itself in either direction.
    sendServerCommand(player, "cessna172", "debugAviationSet", { level = now })
    return now
end

-- ============================================== debug: spawn an aircraft, with its key
--
-- WHY NOT JUST /addvehicle. Vanilla's debug spawner sends that command and it works, but it
-- hands nothing back, so the client cannot then ask for the key - which leaves a locked
-- aeroplane and a second trip through the vanilla spawner's Get Key button. Doing the spawn
-- here means the key is created and delivered in the same step, the way the menu promises.
--
-- THE SQUARE COMES FROM THE CLIENT AND IS CHECKED, NOT TRUSTED. The client picks the spot
-- because it is the side that knows what is outdoors and clear around the player; the server
-- confirms the spot is real and is within SPAWN_MAX_TILES of the sender before creating
-- anything, so the command cannot be used to drop aircraft anywhere on the map.
local SPAWN_MAX_TILES = 8

local function onDebugSpawnCessna(player, args)
    if not player then return end
    if type(args) ~= "table" then return end

    if not mayDebugCheat(player, "debugSpawnCessna") then return end

    local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
    if not (isFiniteNumber(x) and isFiniteNumber(y) and isFiniteNumber(z)) then return end

    local dx = math.abs(x - player:getX())
    local dy = math.abs(y - player:getY())
    if dx > SPAWN_MAX_TILES or dy > SPAWN_MAX_TILES then
        print(("[Cessna172][server] debugSpawnCessna REFUSED: %d,%d is %0.1f/%0.1f tiles from " ..
               "the sender, limit is %d.")
            :format(x, y, dx, dy, SPAWN_MAX_TILES))
        return
    end

    local cell = getCell()
    local square = cell and cell:getGridSquare(math.floor(x), math.floor(y), math.floor(z))
    if not square then
        print("[Cessna172][server] debugSpawnCessna: no such square " ..
              tostring(x) .. "," .. tostring(y) .. "," .. tostring(z))
        return
    end

    local vehicle = addVehicleDebug(C172_SCRIPT, player:getDir(), nil, square)
    if not vehicle then
        print("[Cessna172][server] debugSpawnCessna: addVehicleDebug returned nil - " ..
              C172_SCRIPT .. " is not a registered vehicle script on the SERVER, i.e. this " ..
              "mod's scripts did not load server-side.")
        return
    end

    -- Vanilla's own Commands.getKey pattern: add to the container AND tell the client, or the
    -- key exists on the server and never appears in the player's bag.
    local keyed = "NO KEY"
    local okK, item = pcall(function() return vehicle:createVehicleKey() end)
    if okK and item then
        player:getInventory():AddItem(item)
        pcall(function() sendAddItemToContainer(player:getInventory(), item) end)
        keyed = "key delivered"
    end

    -- Servicing belongs here rather than on the client for the same reason the spawn does:
    -- the server owns the vehicle, and a client-side repair or refuel is reverted the moment
    -- vanilla's vehicle netcode next syncs the part.
    local serviced = ""
    if args.airworthy then
        local notes = {}
        pcall(function() vehicle:repair() end)
        notes[#notes+1] = "repaired"

        local okT, tank = pcall(function() return vehicle:getPartById("GasTank") end)
        if okT and tank then
            local okC, cap = pcall(function() return tank:getContainerCapacity() end)
            if okC and type(cap) == "number" and cap > 0 then
                pcall(function() tank:setContainerContentAmount(cap) end)
                notes[#notes+1] = ("fuel %d/%d"):format(cap, cap)
            else
                notes[#notes+1] = "fuel UNKNOWN CAPACITY"
            end
        else
            notes[#notes+1] = "NO GasTank PART"
        end

        local okB, battery = pcall(function() return vehicle:getPartById("Battery") end)
        local item2 = nil
        if okB and battery then
            local okI, it = pcall(function() return battery:getInventoryItem() end)
            item2 = okI and it or nil
        end
        if item2 then
            pcall(function() item2:setUsedDelta(1.0) end)
            notes[#notes+1] = "battery charged"
        else
            notes[#notes+1] = "BATTERY BAY EMPTY - the engine will not crank"
        end
        serviced = " | " .. table.concat(notes, ", ")
    end

    -- REPORT WHERE IT WENT RELATIVE TO THE PLAYER, not just where it went. "spawned at
    -- 15352,2547" is unfalsifiable on its own - it looks like success whether the aeroplane
    -- landed next to the player or seven tiles away behind a wall. The distance and the
    -- vehicle's own id make the difference visible, and re-reading the id back from the
    -- object proves the vehicle still existed after creation rather than being created and
    -- immediately discarded.
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local vid = "?"
    pcall(function() vid = tostring(vehicle:getId()) end)
    local backX, backY = "?", "?"
    pcall(function() backX = string.format("%.1f", vehicle:getX()) end)
    pcall(function() backY = string.format("%.1f", vehicle:getY()) end)
    print(("[Cessna172][server] debugSpawnCessna: %s id=%s | asked for %d,%d,%d | vehicle " ..
           "reports %s,%s | player at %.1f,%.1f,%.0f | %.1f tiles away | %s%s")
        :format(C172_SCRIPT, vid,
                square:getX(), square:getY(), square:getZ(),
                backX, backY, px, py, pz,
                math.sqrt((square:getX() - px)^2 + (square:getY() - py)^2),
                keyed, serviced))
    sendServerCommand(player, "cessna172", "debugSpawned",
        { keyed = (keyed == "key delivered"), vehicleId = vehicle:getId() })
end

-- Declared before onClientCommand so it sees this local - it is assigned further down. (1.9.1:
-- declared only below, the name here was the nil GLOBAL and every "debugSpawnManuals" command on
-- a dedicated server threw "tried to call nil".)
local onDebugSpawnManuals

local function onClientCommand(module, command, player, args)
    if module ~= "cessna172" then return end
    if command == "debugSetAviation" then return onDebugSetAviation(player, args) end
    if command == "debugSpawnCessna" then return onDebugSpawnCessna(player, args) end
    if command == "debugSpawnManuals" then return onDebugSpawnManuals(player, args) end
    if command ~= "flightUpdate" then return end
    if type(args) ~= "table" then return end

    if not isPlayerFlyingVehicle(player, args.vehicleId) then
        -- THROTTLED PER SENDER. This rejection is exactly the case that can repeat at the
        -- client's send rate - a desynced client that still believes it is flying, or one
        -- deliberately sending rubbish - and an unthrottled print here would fill a
        -- dedicated server's console and log file for as long as it kept sending. The drop
        -- itself is unconditional; only the reporting is rate-limited.
        local nm = tostring(player and player:getUsername() or "?")
        local now = getTimestampMs and getTimestampMs() or 0
        if (now - (rejectLoggedAt[nm] or 0)) >= REJECT_LOG_INTERVAL_MS then
            rejectLoggedAt[nm] = now
            print("[Cessna172][server][WARN] dropping flightUpdate from " .. nm ..
                  ": not the confirmed driver of Cessna vehicleId=" ..
                  tostring(args.vehicleId) .. " (further such warnings from this player " ..
                  "are suppressed for " .. tostring(REJECT_LOG_INTERVAL_MS / 1000) .. "s)")
        end
        return
    end

    if args.altitude ~= nil then
        if not isFiniteNumber(args.altitude) then return end
        if args.altitude < 0 or args.altitude > MAX_PLAUSIBLE_ALTITUDE then return end
    end
    if args.treeClearAltitude ~= nil and not isFiniteNumber(args.treeClearAltitude) then return end
    if args.mode ~= nil and not VALID_MODES[args.mode] then return end
    if args.airSpeed ~= nil then
        if not isFiniteNumber(args.airSpeed) then return end
        if args.airSpeed < 0 or args.airSpeed > MAX_PLAUSIBLE_AIRSPEED then return end
    end
    if args.clear ~= nil and type(args.clear) ~= "boolean" then return end

    -- AIRFRAME HOURS, MULTIPLAYER PATH. This message has just been proven to come from
    -- the confirmed driver of that specific Cessna, and it arrives on a fixed 0.5 s
    -- cadence, so the server can integrate real airborne time from it without trusting
    -- any client-supplied duration. The elapsed value is measured from the SERVER's own
    -- clock and clamped, so a client that stalls, reconnects or floods the channel cannot
    -- inflate the meter - the worst it can do is under-report by stopping.
    --
    -- The singleplayer path is separate and lives in C172Systems.Update.Engine, because
    -- nothing is sent at all in singleplayer (publishFlightState is gated on isClient()).
    -- Both write through C172Systems.addAirframeMinutes so there is one accumulator.
    trackAirborneTime(args.vehicleId, args.mode)

    -- The SERVER's copy of the flight state (1.9.1). Part updates run only here in multiplayer,
    -- so C172Systems' "airborne aircraft are untouchable" zombie gate reads this copy - which
    -- otherwise stayed GROUND forever and let zombies chip a Cessna climbing out or on final.
    -- Same GROUND / AIRBORNE words the flying client writes into its own copy. The sender was
    -- just proven to be driving this Cessna, so getVehicle() is it.
    if args.mode ~= nil then
        pcall(function()
            C172Util.setFlightState(player:getVehicle(), args.altitude or 0,
                args.mode == "GROUND" and "GROUND" or "AIRBORNE")
        end)
    end

    -- 1.10.3: the server's own ground footprint off while this Cessna flies clear of the ground
    -- (C172ServerContacts) - the flying client only ever shrank its own copy.
    pcall(function()
        C172ServerContacts.report(player:getVehicle(), args.clear == true and args.mode ~= "GROUND")
    end)

    sendServerCommand("cessna172", "flightUpdate", args)
end

-- ================= SAME-VM DIRECT ENTRY POINT =================
--
-- Events.OnClientCommand was observed NEVER firing on a coop host, even with this file
-- demonstrably loaded (the boot marker below prints every time). That is consistent with the
-- host short-circuiting its own client->server messages: there is no network hop to carry
-- them, because the host IS the server. Every sendClientCommand from the host's own client
-- therefore went nowhere, silently, which is what made two rounds of debugging look like a
-- broken handler rather than an undelivered message.
--
-- On a coop host and in singleplayer the server Lua shares ONE Lua VM with the client, so the
-- client can simply call these directly. This table is that entry point. It changes nothing
-- for a dedicated server, where the client genuinely is a separate process, this global does
-- not exist client-side, and the OnClientCommand path below is the only route.
--
-- The permission gate lives inside each handler, not here, so calling directly is not a way
-- around it.
--- SPAWNS THE AVIATION MANUALS **SERVER-SIDE**, WHICH IS THE ONLY WAY THAT WORKS IN MP.
---
--- The debug menu used to do this itself with `player:getInventory():AddItem(id)`. In
--- singleplayer that is fine. In multiplayer it creates the book on the CLIENT ONLY: it has an
--- icon, a tooltip and a Read option, and it is not in the server's world at all. The moment it
--- is read the client sends the timed action over, the server rebuilds it through
--- NetTimedAction.parse -> ISReadABook:new(character, item), the item resolves to nil, and
--- vanilla dies at ISReadABook.lua:492 with
---     attempted index: getSkillTrained of non-table: null
--- The read stops partway, nothing is awarded, and the book is gone at next login because the
--- server's inventory never held it.
---
--- sendAddItemToContainer is NOT the fix on its own - it only ever appears in vanilla's
--- server/ClientCommands.lua, because it pushes an item the SERVER has created DOWN to a
--- client. Calling it from client code is the wrong direction and replicates nothing. The item
--- has to be created here, where the server owns it, and then pushed.
onDebugSpawnManuals = function(player, args)
    if not player then return end
    if not mayDebugCheat(player, "debugSpawnManuals") then return end

    local inv = player:getInventory()
    if not inv then return end

    local ids = { "Base.AviationManual1", "Base.AviationManual2", "Base.AviationManual3" }
    local given = 0
    for _, id in ipairs(ids) do
        local item = nil
        pcall(function() item = inv:AddItem(id) end)
        if item then
            given = given + 1
            -- Now that the SERVER holds it, tell the client. Without this the book exists
            -- server-side but never appears in the player's bag.
            pcall(function() sendAddItemToContainer(inv, item) end)
        else
            print("[Cessna172][server] NO SUCH ITEM: " .. id ..
                  " - aviation_books.txt did not load on the server.")
        end
    end
    print(("[Cessna172][server] spawned %d/%d aviation manuals server-side for %s")
        :format(given, #ids, tostring(player:getUsername())))
    return given
end

C172ServerCommands = C172ServerCommands or {}
C172ServerCommands.debugSetAviation = onDebugSetAviation
C172ServerCommands.debugSpawnCessna = onDebugSpawnCessna
C172ServerCommands.debugSpawnManuals = onDebugSpawnManuals

Events.OnClientCommand.Add(onClientCommand)

-- LOAD MARKER. Deliberately unconditional. Every other print in this file is on a failure
-- path, which meant that "the server handler never fired" and "this file never ran at all"
-- looked identical in the log for two rounds of debugging. One line at boot separates them.
print(("[Cessna172][server] server-side Lua LOADED, OnClientCommand registered " ..
       "(isServer=%s, isClient=%s, isCoopHost=%s, isDebugEnabled=%s)")
    :format(tostring(isServer()), tostring(isClient()),
            tostring(isCoopHost()), tostring(isDebugEnabled())))

