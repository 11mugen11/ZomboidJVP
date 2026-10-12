--[[
    C172Spawn - where a Cessna 172 turns up in a world that generated itself.

    ============================ WHAT CHANGED AND WHY ============================

    IT USED TO SPAWN IN ORDINARY CAR PARKS. The first version added the aircraft to
    "parkingstall", "good" and "professional" at spawnChance 2 - which is to say, in the
    zones the game uses for supermarket bays, nice suburban driveways and white-collar
    commuter parking. A light aircraft standing in a driveway is not a rare find, it is a
    joke, and it is the single thing most likely to make the mod feel unserious. Those three
    entries are now actively REMOVED (see the pruning pass below), not merely left alone,
    because an existing install carries them.

    IT NOW SPAWNS WHERE AN AEROPLANE WOULD BE. Airport service zones first - the map
    genuinely has them - then a thin scatter across heavy, industrial and derelict zones
    where a light aircraft could plausibly have been parked, hangared, salvaged or abandoned.
    Nothing residential, nothing commuter, nothing on an ordinary street.

    HOW RARE IT ACTUALLY IS. spawnChance is a WEIGHT WITHIN ITS ZONE, not a percentage of the
    world; a zone's entries conventionally total 100. So 8 in airportservice means roughly one
    aircraft per twelve vehicles that zone rolls, and 2 in junkyard is about one in fifty -
    and both are multiplied by how seldom the zone itself appears on the map, which for
    airport and industrial zones is seldom indeed. The result is an aeroplane you come across
    a few times in a long run, in a place that makes sense, which is what "significant" means.

    1.9.1 - RARE AT THE AIRPORT (Jay 2026-10-02: "make sure spawns at air port rare"). Counted on
    the vanilla map with the engine's own stall rule (IsoChunk.AddVehicles_OnZone: 3-tile bays,
    each rolling the zone's spawnRate): airportservice is 46 stalls at Louisville Intl and
    airportshuttle 56, both rate 32 (23% a stall at the default Car Spawn Rate Low). Weights 8 +
    3 gave about 1.1 Cessnas per world at the airport; airportservice 3 (the MH-92's weight) and
    no airportshuttle (vanilla also uses it for the Havisham hotel - the MiG and MH-92 leave it
    out for that reason) give about 0.3: one Cessna in three worlds. The industrial and junkyard
    weights stay (about 0.16 a world, mostly wrecks). A sure Cessna is the Knox Air Guard Station
    map's job: it parks them in its own stalls.
    ============================ COMPATIBILITY =============================

    ADDITIVE, AND IT ONLY EVER TOUCHES ITS OWN KEY. Each zone's table is checked for this
    vehicle's id and written only if absent; no other mod's entry is read, replaced, reordered
    or re-weighted, so load order against other vehicle mods does not matter. A zone this file
    does not recognise is skipped rather than created, so a modded or trimmed
    VehicleZoneDefinition cannot be corrupted by it.

    The pruning pass removes ONLY "Base.Cessna172" and only from the zones this mod itself
    once put it in. It cannot touch another mod's vehicle even by accident.

    EXISTING SAVES. Vehicle zones are rolled when a chunk is first generated, so already
    explored parts of an existing save keep whatever they already spawned - including, on an
    install that ran an earlier version, any aircraft already sitting in a car park. Newly
    generated chunks use the table below. That is the normal, unavoidable behaviour of PZ's
    vehicle distribution and not something a mod can retroactively fix.

    SP / MP / DEDICATED. Vehicle distribution is evaluated by whichever side owns world
    generation - the host in singleplayer and listen-server play, the server process on a
    dedicated box. This file is in shared/ and registers on both boot events, so that side
    always has the table regardless of which one it is. No client-only state is involved.

    NO DEBUG SPAWN KEY, deliberately - the MiG's was removed at Jay's explicit request and the
    same reasoning applies. The debug vehicle spawner already exists for testing.
]]
local C172_ID = "Base.Cessna172"

-- Zones this aircraft belongs in, and its weight against that zone's own vehicles.
local ZONES = {
    -- Aviation. The map defines these around the airfield, and they are where the aircraft
    -- is genuinely meant to be found.
    { zone = "airportservice",  chance = 3 },
    -- Heavy and industrial. A works aircraft, or one that was being moved or stored.
    { zone = "mccoy",           chance = 2 },   -- logging company yard
    { zone = "massgenfac",      chance = 2 },   -- factory
    { zone = "knoxdisti",       chance = 2 },   -- industrial plant
    { zone = "ranger",          chance = 2 },   -- park service - a spotter aircraft
    -- Derelict. The wreck you were not expecting.
    { zone = "junkyard",        chance = 2 },
}

-- Zones an earlier version of this mod wrote into, which it should never have. Removing our
-- own key is safe; nothing else in these tables is read or touched.
local PRUNE = { "parkingstall", "good", "professional", "airportshuttle" }

local function addAircraftSpawns()
    if not VehicleZoneDistribution then return end

    local pruned = 0
    for _, name in ipairs(PRUNE) do
        local zone = VehicleZoneDistribution[name]
        if zone and zone.vehicles and zone.vehicles[C172_ID] then
            zone.vehicles[C172_ID] = nil
            pruned = pruned + 1
        end
    end

    local added, missing = 0, 0
    for _, entry in ipairs(ZONES) do
        local zone = VehicleZoneDistribution[entry.zone]
        if zone and zone.vehicles then
            if not zone.vehicles[C172_ID] then
                zone.vehicles[C172_ID] = { index = -1, spawnChance = entry.chance }
                added = added + 1
            end
        else
            missing = missing + 1
        end
    end

    if added > 0 or pruned > 0 then
        print(("[Cessna172][SPAWN] registered in %d aviation/industrial zones%s%s")
            :format(added,
                    pruned > 0 and (", removed %d stale car-park entries"):format(pruned) or "",
                    missing > 0 and (", %d zones absent in this install"):format(missing) or ""))
    end
end

Events.OnGameBoot.Add(addAircraftSpawns)
Events.OnGameStart.Add(addAircraftSpawns)
if Events.OnServerStarted then Events.OnServerStarted.Add(addAircraftSpawns) end
