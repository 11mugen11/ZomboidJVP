--[[
    C172DebugItems - a testing shortcut for spawning the aircraft and clearing its skill gate.

    ============================ THIS CANNOT REACH A PLAYER ============================

    Every entry added here is behind `getCore():getDebug()`, which is only true when the game
    was launched with -debug. On a normal client, a normal server and a normal dedicated
    server that is false, this file adds nothing to any menu, and the event handler returns on
    its first line. There is no keybind, no sandbox option and no chat command, so there is
    nothing to leave switched on by accident - which is the same standard the MiG's debug
    spawn key was held to when it was removed.

    ============================ WHY IT EXISTS ============================

    The gameplay loop is "find an aircraft, find a manual, read it, fly". Testing that loop
    end to end otherwise means waiting for loot to roll a book that is deliberately rare, and
    then reading it through several in-game hours - twice, once either side of the skill gate.
    This makes both halves of that test immediate.

    THE VANILLA DEBUG SPAWNERS ALREADY WORK for both the aircraft and the books - the vehicle
    is Base.Cessna172 (listed under B, not C, unless "Real names" is ticked) and the books are
    Base.AviationManual1, 2 and 3. This exists because hunting either out of a list of
    thousands is the tedious part, because the vanilla vehicle spawner hands over no key, and
    because reaching the required level directly is the only quick way to test the FAR side of
    the gate without reading anything.

    ======================= TWO WAYS TO CLEAR THE GATE, ON PURPOSE =======================

    Both are offered because they test different things, and only one of them is a shortcut.

      SET LEVEL   character:setPerkLevelDebug(perk, n) - the same call vanilla's own debug
                  stats panel (ISStatsAndBody) makes. It skips XP entirely and lands on an
                  exact level. Use it when you want to test the AIRCRAFT and do not care how
                  you got airborne. This is the entry you want almost every time, so it is
                  first in the menu.

      GRANT XP    Aviation.addXP -> character:getXp():AddXP(perk, amount) - the same path a
                  book takes. It exercises the REAL progression: XP multipliers, the level-up
                  itself, persistence and replication. If any of that is broken it breaks
                  here in exactly the way it would break for a player. Use it to test the
                  SYSTEM rather than the aeroplane.

    THE REQUIRED LEVEL IS NOT HARDCODED. It is read out of Aviation.aircraft[], which is the
    same table canFly() consults, so the menu can never drift out of step with the gate it
    exists to clear - change C172Aviation.MIN_LEVEL and this menu follows on the next load.

    EVERY WRITE IS READ BACK. setPerkLevelDebug and AddXP are Java calls that can succeed and
    do nothing (an unregistered perk, a null XP map). Each action logs the level it actually
    observes afterwards, because a debug tool that silently fails is worse than none.
]]

-- 1.9.0: the old Java bridge functions now live in this mod's own C172Phys table (Lua, no
-- ZombieBuddy). Still looked up by name, so a missing one is a nil, never a call error.
require "Cessna172/C172Phys"
local function javaFn(name)
    local fn = C172Phys and C172Phys[name]
    if type(fn) == "function" then return fn end
    return nil
end
local function scanNearby(x, y, r)
    local scan = javaFn("c172ScanNearbyAircraft")
    if not scan then return 0 end
    return scan(x, y, r) or 0
end
local function nearbyAircraft(i)
    local get = javaFn("c172NearbyAircraft")
    if not get then return nil end
    return get(i)
end

local AIRCRAFT_ID = "Base.Cessna172"
local MANUALS = { "Base.AviationManual1", "Base.AviationManual2", "Base.AviationManual3" }

-- TWO FLAGS, NOT ONE. getCore():getDebug() and isDebugEnabled() are separate values and they
-- do not always agree - a session logged `isDebugEnabled=true` while this whole menu was
-- invisible, because only the other flag was consulted. Accepting either removes an entire
-- class of "the debug menu is missing" confusion, and neither flag is reachable without the
-- player having launched with -debug in the first place, so the gate is no weaker.
local function debugOn()
    local ok, on = pcall(function() return getCore():getDebug() end)
    if ok and on == true then return true end
    local ok2, on2 = pcall(function() return isDebugEnabled() end)
    return ok2 and on2 == true
end

-- The registry is preferred over C172Aviation.MIN_LEVEL because the registry is what the gate
-- actually reads; MIN_LEVEL is only the declaration that seeded it. Returns nil when the
-- aircraft never registered, which is itself the finding worth surfacing.
local function requiredLevel()
    if Aviation and Aviation.aircraft then
        local craft = Aviation.aircraft[AIRCRAFT_ID]
        if craft and type(craft.minLevel) == "number" then return craft.minLevel end
    end
    if C172Aviation and type(C172Aviation.MIN_LEVEL) == "number" then
        return C172Aviation.MIN_LEVEL
    end
    return nil
end

local function currentLevel(player)
    if not (player and Aviation and Aviation.getLevel) then return 0 end
    return Aviation.getLevel(player)
end

-- Shared precondition for anything that touches the skill. Returns the Perk, or nil after
-- logging precisely which of the two failure modes happened - they need different fixes.
local function readyPerk()
    if not Aviation then
        print("[Cessna172][DEBUG] Aviation framework not loaded - nothing to grant.")
        return nil
    end
    if not Aviation.isSkillAvailable() then
        print("[Cessna172][DEBUG] the Aviation skill did not register - the flight gate is " ..
              "failing OPEN, so the aircraft will fly regardless of level.")
        return nil
    end
    local perk = Aviation.perk()
    if not perk then print("[Cessna172][DEBUG] Aviation.perk() returned nil.") end
    return perk
end

local function halo(player, text)
    pcall(function() HaloTextHelper.addGoodText(player, text) end)
end

local function giveManuals(playerNum)
    local player = getSpecificPlayer(playerNum)
    if not player then return end

    -- SPAWN ON THE SERVER WHEN THERE IS ONE. A book added only by this client is not really in
    -- the world: reading it kills the server-side timed action in vanilla code and it vanishes
    -- at next login. See onDebugSpawnManuals in C172Server.lua for the full account.
    --
    -- Same dual route as the Aviation level setter below: on a coop host and in SP the server
    -- Lua shares this VM so C172ServerCommands is a real table and is called directly (a
    -- sendClientCommand from a host to itself was observed never arriving); on a dedicated
    -- server that global is absent here and the message is the only route.
    -- THE NETWORK ROUTE WINS WHENEVER WE ARE A CLIENT, INCLUDING A COOP HOST.
    --
    -- The obvious ordering - "if C172ServerCommands exists, call it directly" - is WRONG here,
    -- and it produced a spawn that logged a confident "server-side ... 3/3" into the CLIENT's
    -- console while the real server never heard of the books.
    --
    -- The reason is that a coop host runs TWO processes. The client process reports
    -- isServer=false isClient=true isCoopHost=true and it loads server/ Lua as well, so
    -- C172ServerCommands is a perfectly real table THERE - it is simply not the authority. The
    -- authority is the separate server process writing DebugLog-server.txt. Calling the local
    -- copy creates the item in the wrong VM, which is the same client-only ghost as before.
    --
    -- For a LEVEL that distinction was survivable, which is why the Aviation setter gets away
    -- with the opposite ordering. For an ITEM it is fatal: the object has to exist in the
    -- process that owns the world, or every timed action against it dies in
    -- NetTimedAction.parse.
    --
    -- So: any client (dedicated or coop host) asks over the network. The direct call is kept
    -- strictly for true singleplayer, where isClient() is false and there is no other process
    -- for the item to live in.
    -- A COOP HOST CANNOT SPAWN A REAL ITEM FROM HERE, AND SAYING SO IS THE HONEST ANSWER.
    --
    -- Both routes are dead ends on a coop host, and each fails in a way that looks like success:
    --
    --   sendClientCommand  - never arrives. Verified across every server log this machine has
    --                        produced: the client prints "asked the SERVER", the server never
    --                        logs a thing. The host does not carry its own client->server
    --                        messages, because there is no network hop to carry them.
    --   C172ServerCommands - present in the CLIENT process too (it loads server/ Lua), so
    --                        calling it "works", prints a confident 3/3, and creates the book
    --                        in the wrong VM. That is the ghost item that crashes the real
    --                        server at ISReadABook.lua:492 the moment you read it.
    --
    -- Silently doing either is worse than refusing, because a ghost book is indistinguishable
    -- from a real one until the read dies halfway through. So on a coop host this refuses and
    -- names the two routes that do produce a genuine, server-owned book.
    if isClient() and isCoopHost() then
        local msg = "Cannot spawn manuals on a coop host - use the admin Item Spawner, or " ..
                    "loot one (they are in 16 container types)"
        print("[Cessna172][DEBUG] " .. msg .. ". A book created from here would exist only on " ..
              "this client: it would look normal, then kill the server-side read at " ..
              "ISReadABook.lua:492 and vanish at next login.")
        pcall(function() HaloTextHelper.addBadText(player, "Use the admin Item Spawner") end)
        return
    end

    if isClient() then
        sendClientCommand(player, "cessna172", "debugSpawnManuals", {})
        print("[Cessna172][DEBUG] asked the SERVER to spawn the aviation manuals " ..
              "(dedicated server) - the confirmation appears in the SERVER log, not here.")
        return
    end

    -- SINGLEPLAYER ONLY from here: no server exists, so a local AddItem IS the real item.
    -- (1.9.1: an in-process call into C172ServerCommands used to sit here first. Its cheat
    -- check refuses every singleplayer character - no access level, not a coop host - so it
    -- spawned nothing and returned before this code.)
    local inv = player:getInventory()
    local given = 0
    for _, id in ipairs(MANUALS) do
        -- AddItem returns nil for an id the script manager never registered, which is the
        -- single most useful thing this can tell us: it means aviation_books.txt did not
        -- load, not that the loot tables are unlucky.
        local item = inv:AddItem(id)
        if item then
            given = given + 1
            -- TELL THE SERVER, or in multiplayer the book exists ONLY on this client.
            --
            -- This is the same call the vehicle-key path below already makes, and leaving it
            -- out here cost hours. A client-only book looks completely normal - it is in the
            -- bag, it has an icon, the Read option appears - right up until you read it. Then
            -- the client sends the timed action to the server, the server rebuilds it through
            -- NetTimedAction.parse -> ISReadABook:new(character, item), CANNOT FIND THE ITEM,
            -- and dies on line 492 with "attempted index: getSkillTrained of non-table: null".
            -- The read stops halfway, no XP is awarded, no level is gained, and because the
            -- server's authoritative inventory never held the book, it is gone on next login.
            --
            -- Every one of those symptoms was reported as a bug in the Aviation skill. None of
            -- them were: the books simply were not really there.
            --
            -- No sendAddItemToContainer here: this branch only runs when there is no server at
            -- all, and that call pushes a SERVER-created item down to a client - the opposite
            -- direction. Replication is handled in onDebugSpawnManuals, server-side.
        else
            print("[Cessna172][DEBUG] NO SUCH ITEM: " .. id)
        end
    end
    print(("[Cessna172][DEBUG] spawned %d/%d aviation manuals"):format(given, #MANUALS))
    if given > 0 then halo(player, ("%d aviation manuals added"):format(given)) end
end

-- The shortcut. setPerkLevelDebug(Perk, int) is a verified signature on IsoGameCharacter and
-- is what vanilla debug uses, so this is not a home-made loop of LevelPerk() calls. Note it
-- is a CLIENT-side write, exactly as vanilla's debug panel is: in multiplayer treat the
-- result as local until the character next saves.

local function nowMs()
    return (getTimestampMs and getTimestampMs()) or 0
end

-- setPerkLevelDebug, NOT level0()+LevelPerk().
--
-- READ THE BYTECODE BEFORE CHANGING THIS. getPerkLevel(perk) is literally
-- `getPerkInfo(perk).level`, returning 0 when getPerkInfo is null - and a character only has
-- a PerkInfo for a perk that existed when its perk list was built. A perk this mod adds at
-- boot is NOT in an existing character's list, so every write silently no-ops and every read
-- says 0.
--
-- Exactly two methods construct the missing PerkInfo: setPerkLevelDebug, and the TWO-argument
-- LevelPerk(perk, boolean). The one-argument LevelPerk and level0 both go through getPerkInfo
-- and no-op when it is null - which is why switching to them turned a working grant into
-- "Aviation reads 0, holding 2" repeating once a second forever. That was a regression, and
-- this is the revert.
-- Goes through Aviation.setLevel, which writes the ModData authority FIRST and then mirrors
-- the number onto the perk for the skills panel. Writing setPerkLevelDebug directly from here
-- would set only the perk - the half that PZ does not persist - which is what made every
-- earlier version of this menu look like it worked and then forget.
local function applyLevelLocally(player, level)
    if not readyPerk() then return nil end
    if Aviation and Aviation.setLevel then
        local ok, lvl = pcall(function() return Aviation.setLevel(player, level) end)
        if ok then return lvl end
    end
    return currentLevel(player)
end

local function setLevel(playerNum, level)
    local player = getSpecificPlayer(playerNum)
    if not player then return end

    local before = currentLevel(player)
    local after = applyLevelLocally(player, level)
    if after == nil then return end

    -- HOLD IT, DO NOT JUST SET IT.
    --
    -- The level was seen going 0 -> 10 and back to 0 with nothing logged in between, which
    -- looked exactly like multiplayer stat-sync clobbering a client-side write. It was not:
    -- the ACTUAL cause was AviationFramework resolving the skill to the Aviation GROUP perk
    -- (an IGUI_perks_ display-name collision - see existingPerk() there), so every write
    -- landed on a header the character does not carry and every read returned 0. Fixed
    -- 2026-09-02. The diagnostic that settled it is dumpPerkState() below.
    --
    -- The hold is KEPT anyway, as a safety net rather than a fix: skills really are
    -- server-authoritative in MP, so a client-side write to a perk a dedicated server has
    -- not registered can still be reverted. It is cheap, it is bounded, and it now says in
    -- the log which of the two situations it is seeing. Setting 0 clears the override rather
    -- than holding it, so "Reset" genuinely resets.

    -- And still ask the server, which is the write that would actually persist. Harmless when
    -- the server has no handler for it - an older build, or server-side Lua that never loaded
    -- - because the watcher covers that case either way.
    -- Reach the server side by whichever route actually exists. On a coop host and in SP the
    -- server Lua is in this same VM and C172ServerCommands is a real table, so call it; a
    -- sendClientCommand from a host to itself was observed never arriving. On a dedicated
    -- server that global is absent here and the message is the only route.
    if C172ServerCommands and C172ServerCommands.debugSetAviation then
        -- Direct call, so the answer comes back as a RETURN VALUE. A coop host does not
        -- deliver its own client/server messages to itself in either direction, so waiting on
        -- the "debugAviationSet" reply here would wait forever.
        local okS, serverLevel = pcall(function()
            return C172ServerCommands.debugSetAviation(player, { level = level })
        end)
        print(("[Cessna172][DEBUG] server side (same VM) returned %s")
            :format(okS and tostring(serverLevel) or "ERROR: " .. tostring(serverLevel)))
    elseif isClient() then
        sendClientCommand(player, "cessna172", "debugSetAviation", { level = level })
    end

    -- TELL THE MIRROR. Without this, a deliberate "Reset Aviation to 0" is silently undone by
    -- the framework's next reconcile, which still believes the old level is the true one.
    -- Setting a level through this menu is an intentional change to the authoritative skill,
    -- so the saved mirror must move with it.
    if Aviation and Aviation.rememberLevel then
        pcall(function() Aviation.rememberLevel(player) end)
    end

    local allowed = Aviation and Aviation.canFly(player, AIRCRAFT_ID)
    print(("[Cessna172][DEBUG] set Aviation %d -> %d (asked %d) | canFly=%s%s")
        :format(before, after, level, tostring(allowed),
                isClient() and " | server also asked" or ""))

    if after ~= level then
        print("[Cessna172][DEBUG] WARNING: the write did not land at all. The perk exists but " ..
              "setPerkLevelDebug did nothing - this character is not carrying the perk this " ..
              "session registered.")
        return
    end
    halo(player, ("Aviation %d"):format(after))
end

-- THE RE-ASSERT WATCHER IS GONE, DELIBERATELY.
--
-- It re-applied a remembered level once a second. Aviation.reconcileLevel in the framework now
-- restores from a saved ModData mirror every five seconds. Two writers on the same value at
-- different rates is exactly what "the skill keeps jumping" looks like: click Reset to 0, and
-- five seconds later the mirror put 2 back. There is now ONE authority - the mirror - and this
-- file's job is only to set the level and tell the mirror what was set.

-- The honest path. Deliberately routed through the framework's own addXP so that what is
-- being tested is the REAL progression: if XP, levels, persistence or replication are broken,
-- this breaks in exactly the same way the books would.
local function grantXP(playerNum, amount)
    local player = getSpecificPlayer(playerNum)
    if not player then return end

    -- Same server-authority problem as setLevel, and there is no server-side "add XP" here on
    -- purpose: an exact level is what the gate reads, and one command that lands on a level is
    -- easier to reason about than two that disagree. In MP this points at the entry that works
    -- rather than quietly doing nothing.
    if isClient() then
        print("[Cessna172][DEBUG] MP: XP granted from a client is reverted by the server's " ..
              "next stat sync. Use \"Set Aviation to N\" instead - it goes through the " ..
              "server and sticks. (The XP path still tests the real book progression in SP.)")
        return
    end

    if not readyPerk() then return end

    local before = currentLevel(player)
    Aviation.addXP(player, amount)
    local after = currentLevel(player)
    print(("[Cessna172][DEBUG] +%d Aviation XP -> level %d (was %d)")
        :format(amount, after, before))
    if after == before then
        print("[Cessna172][DEBUG] note: the level did not change. That is normal if the XP " ..
              "landed part-way through a level - check the skills panel bar, not this line.")
    end
    halo(player, ("Aviation %d"):format(after))
end

-- ============================================== the full perk diagnostic
--
-- WHY THIS IS SO DETAILED. Three symptoms that ought to be one bug turned out to disagree
-- with each other: the framework logs "skill ready", isSkillAvailable() returns true and
-- setPerkLevelDebug reads back correctly - and yet the skill does not appear in the character
-- skills panel and the level does not persist. Those cannot all be true of a healthy perk, so
-- rather than guess again this prints the ACTUAL engine state behind each claim.
--
-- WHAT THE PANEL ACTUALLY DOES (ISCharacterInfo.loadPerk, read from the game's own Lua):
-- it walks PerkFactory.PerkList and keeps every perk whose getParent() ~= Perks.None,
-- bucketed under that parent. So a skill is missing from the panel if and only if it is
-- absent from PerkList, or its parent is None (which makes it a GROUP header, not a skill),
-- or its parent is not itself in PerkList to act as a bucket. Each of those is checked
-- below by name, so the answer is in the log rather than inferred.
local function dumpPerkState(player)
    print("[Cessna172][DEBUG] ================= AVIATION PERK DIAGNOSTIC =================")
    if not Aviation then
        print("[Cessna172][DEBUG] Aviation: FRAMEWORK NOT LOADED - nothing else applies.")
        return
    end
    print(("[Cessna172][DEBUG] framework v%s | isSkillAvailable=%s | isClient=%s | isCoopHost=%s")
        :format(tostring(Aviation.VERSION), tostring(Aviation.isSkillAvailable()),
                tostring(isClient()), (isCoopHost and tostring(isCoopHost()) or "?")))

    local skill = Aviation.perk()
    print("[Cessna172][DEBUG] Aviation.perk() = " .. tostring(skill))

    -- Walk PerkList by hand. This is the list the skills panel reads, so presence here is the
    -- whole question; the id is compared as a STRING because comparing userdata identity is
    -- exactly the assumption under suspicion.
    local found, group, total = nil, nil, 0
    local okList = pcall(function()
        total = PerkFactory.PerkList:size()
        for i = 0, total - 1 do
            local pk = PerkFactory.PerkList:get(i)
            local id = pk and tostring(pk:getId()) or "?"
            if id == Aviation.SKILL_ID then found = { perk = pk, index = i } end
            if id == Aviation.GROUP_ID then group = { perk = pk, index = i } end
        end
    end)
    if not okList then
        print("[Cessna172][DEBUG] could not walk PerkFactory.PerkList at all.")
        return
    end
    print(("[Cessna172][DEBUG] PerkList holds %d perks"):format(total))

    local function describe(label, e)
        if not e then
            print(("[Cessna172][DEBUG]   %s: NOT IN PerkList  <-- this is why it is not in " ..
                   "the skills panel"):format(label))
            return
        end
        local parent, pname, passiv, custom = "?", "?", "?", "?"
        pcall(function() local pp = e.perk:getParent()
              parent = pp and tostring(pp:getId()) or "nil" end)
        pcall(function() pname = tostring(e.perk:getName()) end)
        pcall(function() passiv = tostring(e.perk:isPassiv()) end)
        pcall(function() custom = tostring(e.perk:isCustom()) end)
        local isNone = "?"
        pcall(function() isNone = tostring(e.perk:getParent() == Perks.None) end)
        print(("[Cessna172][DEBUG]   %s: index %d | displayName '%s' | parent %s | " ..
               "parent==Perks.None %s | passive %s | custom %s")
            :format(label, e.index, pname, parent, isNone, passiv, custom))
    end
    describe("Aviation (the skill)", found)
    describe("AviationGroup (the header)", group)

    if found and group then
        print("[Cessna172][DEBUG]   panel verdict: the skill is in PerkList under a group " ..
              "that is also in PerkList - it SHOULD render. If it does not, the panel was " ..
              "built before the perk existed; reopen the character window.")
    end

    -- The CHARACTER's own list is a different thing from PerkFactory's. A perk can exist
    -- engine-wide and still have no slot on this character, which is what a level that reads
    -- back and then reverts looks like.
    if player then
        local n, carries = 0, false
        pcall(function()
            local list = player:getPerkList()
            n = list:size()
            -- (1.9.1: was info.perk - an instance FIELD, which Kahlua never exposes, so this
            -- always said false. getPerkInfo is the public accessor.)
            carries = (skill ~= nil) and (player:getPerkInfo(skill) ~= nil)
        end)
        print(("[Cessna172][DEBUG]   this character carries %d perks; Aviation present on the " ..
               "CHARACTER: %s"):format(n, tostring(carries)))
        -- Print BOTH persistence stores separately. "The level did not save" has two very
        -- different causes - the value was never written, or it was written to a store that
        -- does not survive a reload - and one number cannot tell them apart.
        local fromChar, fromWorld, rawPerk = "?", "?", "?"
        pcall(function() fromChar = tostring(player:getModData().AviationLevelMirror) end)
        pcall(function()
            local g = ModData.getOrCreate("C172AviationLevels")
            fromWorld = tostring(g and g[player:getUsername()])
        end)
        pcall(function() rawPerk = tostring(player:getPerkLevel(Aviation.perk())) end)
        print(("[Cessna172][DEBUG]   Aviation.getLevel = %d  |  perk says %s  |  character " ..
               "ModData says %s  |  world ModData says %s")
            :format(Aviation.getLevel(player), rawPerk, fromChar, fromWorld))
    end

    for id, craft in pairs(Aviation.aircraft) do
        local allowed, ctx = Aviation.canFly(player, id)
        print(("[Cessna172][DEBUG]   %s (%s) needs %d - canFly=%s (%s)")
            :format(craft.name, id, craft.minLevel, tostring(allowed),
                    ctx and ctx.reason or "?"))
    end
    for _, id in ipairs(MANUALS) do
        local script = ScriptManager.instance:getItem(id)
        print(("[Cessna172][DEBUG]   book %s: %s")
            :format(id, script and "registered" or "MISSING FROM SCRIPTS"))
    end
    print("[Cessna172][DEBUG] ============================================================")
end

local function report(playerNum)
    dumpPerkState(getSpecificPlayer(playerNum))
end

-- Run it once, unprompted, shortly after the world is up. The whole point is that Jay should
-- not have to remember to click anything to get the answer.
if Events and Events.OnGameStart then
    Events.OnGameStart.Add(function()
        if debugOn() then dumpPerkState(getPlayer()) end
    end)
end

-- ============================================================== spawning an aircraft

-- NOT A SPAWN KEY. C172Spawn.lua's header records that the MiG's debug spawn KEYBIND was
-- removed at Jay's request and that the same reasoning applies here - that stands. A keybind
-- is live in every session and one mis-press away from a player; this is a context-menu entry
-- inside a submenu that does not exist at all unless the game was launched with -debug. The
-- distinction is the whole point, so do not turn this into a keybind.
--
-- WHY IT IS NEEDED ANYWAY. The distribution is working exactly as designed - the console
-- says "registered in 7 aviation/industrial zones" with none missing - but spawnChance 8 is a
-- WEIGHT inside airportservice, roughly one aircraft per twelve vehicles that zone rolls, and
-- vehicle zones are rolled when a chunk is FIRST generated. An airport you have already
-- visited in this save has therefore already decided, permanently, that it has no aeroplane.
-- Waiting on that is not a test loop.

-- A Cessna is 6.38 units across the wings, so dropping it on the player's own square is a
-- worse idea than it is for a car. Probe outward for a square that exists and is OUTSIDE -
-- an aeroplane spawned indoors is scenery, not a test subject - and only stand it on the
-- player if every candidate fails.
-- NEAREST FIRST. The original order tried +-5 tiles before +-3 and only then the player's own
-- square, so on open ground the FIRST candidate always won and the aeroplane appeared five
-- tiles away - which reads as "it did not spawn" when you are looking at your feet. Three
-- tiles clears the 6.38-unit wingspan comfortably and stays plainly on screen.
local SPAWN_PROBE = {
    {0,-3}, {3,0}, {0,3}, {-3,0},
    {-3,-3}, {3,-3}, {3,3}, {-3,3},
    {0,-5}, {5,0}, {0,5}, {-5,0},
    {0,0},
}

local function spawnSquare(player)
    local cell = getCell()
    if not cell then return nil end
    local px = math.floor(player:getX())
    local py = math.floor(player:getY())
    local pz = math.floor(player:getZ())
    local fallback = nil
    for _, off in ipairs(SPAWN_PROBE) do
        local sq = cell:getGridSquare(px + off[1], py + off[2], pz)
        if sq then
            fallback = fallback or sq
            local ok, outside = pcall(function() return sq:isOutside() end)
            if ok and outside then return sq end
        end
    end
    return fallback
end

-- Guarded calls in the house style of C172Parts: confirm the member is a function BEFORE
-- invoking it. pcall alone does NOT catch a Java call made with the wrong signature - that
-- kills the whole handler - so the existence check is the part doing the work here.
-- Split by arity exactly as C172Parts does, and for the same reason: Kahlua resolves a Java
-- overload from the arguments it is handed, so passing a trailing nil to a zero-argument
-- method is not the same call as passing nothing.
local function call0(obj, name)
    if type(obj) ~= "userdata" and type(obj) ~= "table" then return false, nil end
    local ok, fn = pcall(function() return obj[name] end)
    if not ok or type(fn) ~= "function" then return false, nil end
    return pcall(function() return fn(obj) end)
end

local function call1(obj, name, a)
    if type(obj) ~= "userdata" and type(obj) ~= "table" then return false, nil end
    local ok, fn = pcall(function() return obj[name] end)
    if not ok or type(fn) ~= "function" then return false, nil end
    return pcall(function() return fn(obj, a) end)
end

-- Everything here is reported rather than assumed. A debug spawn that quietly hands you a
-- dry tank and a flat battery costs a whole test flight to discover.
local function makeAirworthy(vehicle)
    local notes = {}

    local okR = call0(vehicle, "repair")
    notes[#notes+1] = okR and "repaired" or "REPAIR FAILED"

    local okT, tank = call1(vehicle, "getPartById", "GasTank")
    if okT and tank then
        local okC, cap = call0(tank, "getContainerCapacity")
        if okC and type(cap) == "number" and cap > 0 then
            call1(tank, "setContainerContentAmount", cap)
            local _, now = call0(tank, "getContainerContentAmount")
            notes[#notes+1] = ("fuel %s/%d"):format(tostring(now), cap)
        else
            notes[#notes+1] = "fuel UNKNOWN CAPACITY"
        end
    else
        notes[#notes+1] = "NO GasTank PART"
    end

    -- ENGINE QUALITY. tryStartEngine() refuses outright when getEngineQuality() <= 0, and its
    -- only feedback is a SayDebug with a "no key" icon - which is why a Cessna with a healthy
    -- engine part, a full battery and the key in hand can silently refuse to start. Quality is
    -- rolled per spawned vehicle, so a debug-spawned airframe can land on 0 and be permanently
    -- unstartable. setEngineFeature(quality, loudness, power) writes VehicleEngine's three
    -- fields directly; loudness and power are read back first so only the broken one changes.
    local okQ, quality = call0(vehicle, "getEngineQuality")
    if okQ and type(quality) == "number" and quality <= 0 then
        local _, loud  = call0(vehicle, "getEngineLoudness")
        local _, power = call0(vehicle, "getEnginePower")
        if type(loud)  ~= "number" or loud  <= 0 then loud  = 55 end   -- script value
        if type(power) ~= "number" or power <= 0 then power = 100 end
        local okSet = pcall(function() vehicle:setEngineFeature(70, loud, power) end)
        local _, now = call0(vehicle, "getEngineQuality")
        notes[#notes+1] = ("engine quality %s -> %s%s")
            :format(tostring(quality), tostring(now), okSet and "" or " (SET FAILED)")
    end

    -- Vanilla's own pattern (Vehicles.lua): the charge lives on the battery ITEM, not the
    -- part, so an empty bay has nothing to charge and must say so rather than silently pass.
    local okB, battery = call1(vehicle, "getPartById", "Battery")
    if okB and battery then
        local okI, item = call0(battery, "getInventoryItem")
        if okI and item then
            call1(item, "setUsedDelta", 1.0)
            notes[#notes+1] = "battery charged"
        else
            notes[#notes+1] = "BATTERY BAY EMPTY - the engine will not crank"
        end
    else
        notes[#notes+1] = "NO Battery PART"
    end

    return table.concat(notes, ", ")
end


-- How far to look for the aircraft /addvehicle just made. It spawns on the player, so this is
-- generous rather than precise; the id snapshot is what actually identifies the new one.
local SPAWN_FIND_RADIUS = 30
local SPAWN_WAIT_MS     = 6000

local pendingSpawn = nil

-- Attaches the key and, when asked, services the aircraft. Split out because both the
-- singleplayer path (which has the vehicle immediately) and the multiplayer watcher (which
-- has to go and find it) need exactly this.
local function keyAndService(player, vehicle, airworthy)
    local keyed = "NO KEY"
    local okK, item = call0(vehicle, "createVehicleKey")
    if okK and item then
        player:getInventory():AddItem(item)
        -- Vanilla's own Commands.getKey also tells the container, or on a server the key
        -- exists but never appears in the bag. Absent client-side in some contexts, hence the
        -- pcall - a nil global is a plain Lua error and IS caught.
        pcall(function() sendAddItemToContainer(player:getInventory(), item) end)
        keyed = "key in inventory"
    end
    local serviced = airworthy and (" | " .. makeAirworthy(vehicle)) or ""
    return keyed, serviced
end

-- Watches for the aircraft /addvehicle created. Runs only while a spawn is pending, gives up
-- after SPAWN_WAIT_MS, and reports either way - "no Lua error" is not evidence of a spawn.
-- OnTick is ~45 Hz and the scan walks every vehicle in the world in Java, so it is polled at
-- 4 Hz rather than per tick. Nothing here runs at all unless a spawn is actually pending.
local SPAWN_POLL_MS = 250
local lastSpawnPollAt = 0

local function watchSpawn()
    if not pendingSpawn then return end
    local t = nowMs()
    if (t - lastSpawnPollAt) < SPAWN_POLL_MS then return end
    lastSpawnPollAt = t

    local player = getSpecificPlayer(pendingSpawn.playerNum) or getPlayer()
    if not player then pendingSpawn = nil return end

    local found = nil
    pcall(function()
        local n = scanNearby(player:getX(), player:getY(), SPAWN_FIND_RADIUS)
        for i = 0, n - 1 do
            local v = nearbyAircraft(i)
            if v then
                local id = tostring(v:getId())
                -- id -1 is the unregistered case this whole path exists to avoid; skip it so
                -- a half-created vehicle is never mistaken for the real one.
                if id ~= "-1" and not pendingSpawn.known[id] then found = v break end
            end
        end
    end)

    if found then
        local keyed, serviced = keyAndService(player, found, pendingSpawn.airworthy)
        local id = "?"
        pcall(function() id = tostring(found:getId()) end)
        print(("[Cessna172][DEBUG] SPAWN (MP): registered aircraft found, id=%s at %.1f,%.1f " ..
               "| %s%s"):format(id, found:getX(), found:getY(), keyed, serviced))
        halo(player, pendingSpawn.airworthy and "Cessna spawned - keyed, fuelled"
                                            or "Cessna spawned - keyed")
        pendingSpawn = nil
        return
    end

    if (nowMs() - pendingSpawn.startedAt) > SPAWN_WAIT_MS then
        print("[Cessna172][DEBUG] SPAWN (MP) FAILED: /addvehicle was sent but no NEW " ..
              "registered Cessna appeared within " .. tostring(SPAWN_FIND_RADIUS) ..
              " tiles in " .. tostring(SPAWN_WAIT_MS / 1000) .. "s. The server did not create " ..
              "it - check that this account is admin and that the vehicle script is loaded " ..
              "SERVER-side (Base.Cessna172 must be in the server's mod list, not just yours).")
        pendingSpawn = nil
    end
end

Events.OnTick.Add(watchSpawn)

local function spawnCessna(playerNum, airworthy)
    local player = getSpecificPlayer(playerNum)
    if not player then return end

    local square = spawnSquare(player)
    if not square then
        print("[Cessna172][DEBUG] no grid square near the player to spawn on.")
        return
    end

    -- ================= MULTIPLAYER MUST GO THROUGH /addvehicle =================
    --
    -- THE REGRESSION, AND WHAT id=-1 MEANT. Creating the aircraft with addVehicleDebug from
    -- this side produced a BaseVehicle at exactly the right coordinates - the server log even
    -- read back "vehicle reports 15464.0,2515.0" for a request of 15464,2515 - and reported
    -- "spawned ... key delivered". It was still invisible, because the same line said id=-1.
    -- A vehicle with id -1 was never registered with the network: it exists as an object,
    -- synchronizes to nobody, renders for nobody, and cannot be entered. Every success
    -- message was true and the aeroplane was still not there.
    --
    -- /addvehicle is vanilla's OWN multiplayer spawn path - it is what ISSpawnVehicleUI sends
    -- when isClient() - and it goes through the server's registration, so the vehicle gets a
    -- real id and syncs. It is also what this menu used on the day spawning last worked.
    --
    -- The command hands nothing back, so the key cannot be attached inline. Instead the
    -- Cessnas already nearby are noted first, the command is sent, and the watcher below picks
    -- up the one that appears and keys and services it. That keeps both buttons doing exactly
    -- what they say while leaving the actual creation to the server.
    if isClient() then
        local known = {}
        local before = 0
        pcall(function()
            before = scanNearby(player:getX(), player:getY(), SPAWN_FIND_RADIUS)
            for i = 0, before - 1 do
                local v = nearbyAircraft(i)
                if v then known[tostring(v:getId())] = true end
            end
        end)

        SendCommandToServer("/addvehicle " .. AIRCRAFT_ID)

        pendingSpawn = {
            known     = known,
            airworthy = airworthy and true or false,
            startedAt = nowMs(),
            playerNum = playerNum,
        }
        print(("[Cessna172][DEBUG] SPAWN (MP): sent /addvehicle %s | player at %.1f,%.1f,%.0f " ..
               "| %d Cessna(s) already within %d tiles | awaiting the new vehicle to key it")
            :format(AIRCRAFT_ID, player:getX(), player:getY(), player:getZ(),
                    before, SPAWN_FIND_RADIUS))
        return
    end

    -- SINGLEPLAYER. No network id to earn, so the direct call is correct here and gives the
    -- vehicle object back immediately - which is why the key can be attached inline.
    local vehicle = addVehicleDebug(AIRCRAFT_ID, player:getDir(), nil, square)
    if not vehicle then
        print("[Cessna172][DEBUG] addVehicleDebug returned nil for " .. AIRCRAFT_ID ..
              " - that means the vehicle SCRIPT is not registered, i.e. " ..
              "scripts/vehicles/vehicle_cessna172.txt did not load. Nothing else in this " ..
              "mod will work either; check the mod is enabled for THIS save.")
        return
    end

    local keyed, serviced = keyAndService(player, vehicle, airworthy)
    print(("[Cessna172][DEBUG] spawned %s at %d,%d,%d | %s%s")
        :format(AIRCRAFT_ID, square:getX(), square:getY(), square:getZ(), keyed, serviced))
    halo(player, airworthy and "Cessna spawned - keyed, fuelled" or "Cessna spawned - keyed")
end


-- Battery charge WITHOUT vehicle:getBatteryCharge(), which does not exist on BaseVehicle or
-- any superclass (checked against the jar) even though vanilla's own Lua calls it. Probing for
-- it throws every time, and "Break On Error" halts on a thrown error whether or not pcall
-- catches it. This is the path C172Systems already uses successfully.
local function batteryCharge(vehicle)
    local charge = nil
    pcall(function()
        local battery = vehicle:getPartById("Battery")
        if not battery then return end
        local item = battery:getInventoryItem()
        if not item then return end
        local c = item:getCurrentUsesFloat()
        if type(c) == "number" and c == c then charge = c end
    end)
    return charge
end

-- ============================================== the aircraft state report
--
-- WHY. "I let zombies hit it, no health stats went down, and now the engine will not start"
-- is two claims that cannot both be checked from the mechanics screen: that screen shows part
-- CONDITION, but an engine refuses to start for reasons that are not conditions at all - a
-- flat battery, an empty tank, a missing key, a part not fitted. Guessing between those wasted
-- a round; this prints all of them at once, from the vehicle itself.
local START_GATES = { "Battery", "Engine", "Starter", "GasTank", "FuelSystem", "ElectricalSystem" }

local function reportAircraft(playerNum)
    local player = getSpecificPlayer(playerNum)
    if not player then return end
    local vehicle = player:getVehicle()
    if not vehicle then
        -- Not sitting in one: use the mod's own Java scan rather than enumerating vehicles
        -- from Lua, which is unsafe (VehicleManager can be null and takes pcall with it).
        pcall(function()
            local n = scanNearby(player:getX(), player:getY(), 20)
            if n > 0 then vehicle = nearbyAircraft(0) end
        end)
    end
    if not vehicle then
        print("[Cessna172][DEBUG] no Cessna within 20 tiles and you are not sitting in one.")
        return
    end

    print("[Cessna172][DEBUG] ============== AIRCRAFT STATE ==============")
    local id = "?"
    pcall(function() id = tostring(vehicle:getId()) end)
    local okRun, running = call0(vehicle, "isEngineRunning")
    print(("[Cessna172][DEBUG] id=%s | engine running = %s")
        :format(id, tostring(okRun and running)))

    -- The things that actually gate a start, each reported separately so the failing one is
    -- named rather than inferred.
    for _, pid in ipairs(START_GATES) do
        local okP, part = call1(vehicle, "getPartById", pid)
        if not (okP and part) then
            print(("[Cessna172][DEBUG]   %-16s PART MISSING FROM THE VEHICLE"):format(pid))
        else
            local cond, item, amount, cap, charge = "?", nil, nil, nil, "n/a"
            pcall(function() cond = tostring(part:getCondition()) end)
            local okI; okI, item = call0(part, "getInventoryItem")
            local okA; okA, amount = call0(part, "getContainerContentAmount")
            local okC; okC, cap = call0(part, "getContainerCapacity")
            -- getCurrentUsesFloat is what C172Systems already uses to read a drainable item.
            -- getUsedDelta/getDelta do not exist on InventoryItem in this build, and
            -- vehicle:getBatteryCharge() does not exist on BaseVehicle - both checked against
            -- the jar rather than assumed.
            if okI and item then
                pcall(function()
                    local d = item:getCurrentUsesFloat()
                    if type(d) == "number" then charge = ("%.0f%%"):format(d * 100) end
                end)
            end
            if pid == "Battery" then
                local bc = batteryCharge(vehicle)
                if bc then charge = ("%.0f%%"):format(bc * 100) end
            end
            print(("[Cessna172][DEBUG]   %-16s condition=%s | fitted=%s | charge/level=%s%s")
                :format(pid, cond, tostring(okI and item ~= nil), charge,
                        (okA and okC and type(amount) == "number" and type(cap) == "number")
                            and ("  container %.1f/%.1f"):format(amount, cap) or ""))
        end
    end

    -- Every other part, so "no health stats went down" can be checked against real numbers
    -- instead of a screen that may simply not show the part a zombie broke.
    if C172Parts and C172Parts.LIST then
        local damaged = 0
        for _, def in ipairs(C172Parts.LIST) do
            local c = C172Parts.condition and C172Parts.condition(vehicle, def.id)
            if type(c) == "number" and c < 100 then
                damaged = damaged + 1
                print(("[Cessna172][DEBUG]   DAMAGED: %-22s %d%%")
                    :format(def.name or def.id, c))
            end
        end
        if damaged == 0 then
            print("[Cessna172][DEBUG]   every listed part is at 100%% - nothing is damaged, " ..
                  "so a refusal to start is NOT damage. Check the battery charge and fuel " ..
                  "above, and that you are holding the key.")
        end
    end

    -- The key. A missing key is the single most common "it will not start" that looks like
    -- a broken aircraft.
    local hasKey = false
    pcall(function()
        hasKey = player:getInventory():haveThisKeyId(vehicle:getKeyId())
    end)
    print(("[Cessna172][DEBUG]   key for this aircraft in inventory: %s"):format(tostring(hasKey)))
    print("[Cessna172][DEBUG] ===========================================")
end


-- ============================================== live watcher: lights + damage
--
-- WHY A WATCHER RATHER THAN MORE GUESSING. Three of the open reports - "lights stop working
-- airborne", "zombies do not damage it on the ground", "HUD bars never move" - are all
-- questions about what changes and WHEN, which a one-shot report cannot answer. This samples
-- the aircraft twice a second and logs only DIFFERENCES, so the log shows the exact moment a
-- light goes out or a part loses condition, next to the state that caused it.
--
-- Vanilla decides a light's state in Vehicles.Update.Headlight:
--     active = vehicle:getHeadlightsOn()
--     if active and (no bulb fitted or getBatteryCharge() <= 0) then active = false end
-- so a light that dies has exactly three possible causes, and all three are sampled here.
local watching = nil
local lastWatchAt = 0
local WATCH_MS = 500
local watchPrev = {}

local function watchTarget(playerNum)
    local player = getSpecificPlayer(playerNum)
    if not player then return nil, nil end
    local v = player:getVehicle()
    if not v then
        pcall(function()
            local n = scanNearby(player:getX(), player:getY(), 25)
            if n > 0 then v = nearbyAircraft(0) end
        end)
    end
    return player, v
end

local function watchTick()
    if not watching then return end
    local t = nowMs()
    if (t - lastWatchAt) < WATCH_MS then return end
    lastWatchAt = t

    local player, vehicle = watchTarget(watching)
    if not vehicle then return end

    local now = {}
    pcall(function() now.headlightsOn = vehicle:getHeadlightsOn() end)
    now.battery = batteryCharge(vehicle)
    pcall(function() now.engine = vehicle:isEngineRunning() end)
    -- The mod's own persisted flight state, which is the same thing the flight controller and
    -- the collision patches read - so "airborne" in this log means exactly what it means to
    -- the rest of the mod, not a second opinion.
    pcall(function()
        local fs = C172Util and C172Util.getFlightState and C172Util.getFlightState(vehicle)
        if fs then now.airborne = tostring(fs.mode or "?") .. "@" .. tostring(fs.altitude or "?") end
    end)

    -- Light parts: fitted bulb, condition, and whether the light itself is active.
    for _, id in ipairs({ "HeadlightLeft", "HeadlightRight",
                          "HeadlightRearLeft", "HeadlightRearRight" }) do
        local okP, part = call1(vehicle, "getPartById", id)
        if okP and part then
            local okL, light = call0(part, "getLight")
            local active = nil
            if okL and light then pcall(function() active = light:getActive() end) end
            local okI, item = call0(part, "getInventoryItem")
            local cond = nil
            pcall(function() cond = part:getCondition() end)
            now["L_" .. id] = tostring(active) .. "/" .. tostring(okI and item ~= nil)
                              .. "/" .. tostring(cond)
        end
    end

    -- Every listed part's condition, so real damage is caught the instant it lands.
    if C172Parts and C172Parts.LIST then
        for _, def in ipairs(C172Parts.LIST) do
            local c = C172Parts.condition and C172Parts.condition(vehicle, def.id)
            if type(c) == "number" then now["P_" .. def.id] = c end
        end
    end

    for k, v in pairs(now) do
        local was = watchPrev[k]
        if was ~= nil and tostring(was) ~= tostring(v) then
            print(("[Cessna172][WATCH] %s: %s -> %s   (headlightsOn=%s battery=%s engine=%s airborne=%s)")
                :format(k, tostring(was), tostring(v),
                        tostring(now.headlightsOn), tostring(now.battery),
                        tostring(now.engine), tostring(now.airborne)))
        end
    end
    watchPrev = now
end

Events.OnTick.Add(watchTick)


-- ============================================== why did Start Engine do nothing?
--
-- THE SYMPTOM: the radial's Start Engine slice is present, clicking it closes the menu, and
-- nothing happens. Vanilla gives no feedback for this at all - onStartEngine queues
-- ISStartVehicleEngine, whose isValid() is just "am I the driver", and a timed action that
-- fails validation is dropped silently.
--
-- Three separate guesses at the cause have now been wrong (the engine-off latch, the radial
-- slice filter, and a 300s state prune that turned out to only clear a Lua cache). So instead
-- of a fourth guess this records the ACTUAL state at the moment of the click, which is the one
-- thing none of the guesses had.
--
-- Wrapped on OnGameStart rather than at file load: ISVehicleMenu is a vanilla ISUI global and
-- is nil while mod files are still being read. It always calls through, and it only logs for
-- this aircraft, so no other vehicle's ignition is affected in any way.
local startProbeInstalled = false

local function installStartProbe()
    if startProbeInstalled then return end
    if type(ISVehicleMenu) ~= "table" or type(ISVehicleMenu.onStartEngine) ~= "function" then
        return
    end
    startProbeInstalled = true
    local orig = ISVehicleMenu.onStartEngine

    ISVehicleMenu.onStartEngine = function(playerObj, ...)
        pcall(function()
            if not debugOn() then return end
            local v = playerObj and playerObj:getVehicle()
            if not v then return end
            local okN, nm = pcall(function() return v:getScriptName() end)
            if not (okN and nm == AIRCRAFT_ID) then return end   -- Cessna only

            local function q(fn)
                local ok, val = pcall(fn)
                return ok and tostring(val) or "err"
            end
            print(("[Cessna172][START] attempt: isDriver=%s engineRunning=%s engineWorking=%s " ..
                   "keysInIgnition=%s haveKey=%s battery=%s engineCond=%s starterCond=%s " ..
                   "engineQuality=%s airborneFlag=%s fuel=%s/%s hotwired=%s")
                :format(
                    q(function() return v:isDriver(playerObj) end),
                    q(function() return v:isEngineRunning() end),
                    q(function() return v:isEngineWorking() end),
                    q(function() return v:isKeysInIgnition() end),
                    q(function() return playerObj:getInventory():haveThisKeyId(v:getKeyId()) end),
                    q(function()
                        local b = v:getPartById("Battery")
                        local it = b and b:getInventoryItem()
                        return it and it:getCurrentUsesFloat() or "no battery item"
                    end),
                    q(function() return v:getPartById("Engine"):getCondition() end),
                    q(function() return v:getPartById("Starter"):getCondition() end),
                    -- THE ONE THAT WAS MISSING. tryStartEngine() requires getEngineQuality() > 0
                    -- and, when it is not, the only feedback in the whole engine is a SayDebug
                    -- with a "no key" icon - invisible in normal play. Every other field can
                    -- read perfectly healthy while this single number silently blocks the start.
                    q(function() return v:getEngineQuality() end),
                    q(function() local f = javaFn("c172IsAirborne"); return f and f() end),
                    -- FUEL, which every previous version of this probe omitted. PZ will not
                    -- start an engine with an empty tank, and an empty tank looks identical to
                    -- a healthy aircraft on every other field here: parts 100%, battery full,
                    -- key in the ignition, engine "working". Reported as amount/capacity so a
                    -- near-empty tank is unmistakable rather than a percentage to interpret.
                    q(function()
                        local t = v:getPartById("GasTank")
                        return t and t:getContainerContentAmount() or "no tank"
                    end),
                    q(function()
                        local t = v:getPartById("GasTank")
                        return t and t:getContainerCapacity() or "?"
                    end),
                    -- Hotwiring bypasses the key entirely; if this is true the key state above
                    -- is not the blocker.
                    q(function() return v:isHotwired() end)))
        end)
        return orig(playerObj, ...)
    end
    print("[Cessna172][START] ignition probe installed (logs Cessna start attempts only).")
end

if Events and Events.OnGameStart then Events.OnGameStart.Add(installStartProbe) end

-- Signature and the test-pass guard both copied from vanilla's own AdminContextMenu.doMenu:
-- the first argument is a player INDEX, not an IsoPlayer, and the menu is built twice - once
-- with test=true purely to ask whether anything wants to add an entry.
local function onFillWorldObjectContextMenu(playerNum, context, worldobjects, test)
    if not debugOn() then return end
    if test and ISWorldObjectContextMenu.Test then return true end

    local player = getSpecificPlayer(playerNum)
    local need = requiredLevel()
    local have = currentLevel(player)

    -- The state goes in the PARENT label so "am I high enough yet?" is answered without
    -- opening the submenu, reading the log, or opening the skills panel.
    local title = "Cessna 172 [DEBUG]"
    if need then title = ("Cessna 172 [DEBUG]  -  Aviation %d / %d"):format(have, need) end

    local sub = context:addOption(title, nil, nil)
    local menu = ISContextMenu:getNew(context)
    context:addSubMenu(sub, menu)

    -- SPAWNING FIRST: without an aeroplane in front of you, nothing else in this menu
    -- matters. Both entries hand over the key, because a locked aircraft you cannot start is
    -- not a test subject.
    menu:addOption("Spawn Cessna 172 here  +  key", nil,
        function() spawnCessna(playerNum, false) end)
    menu:addOption("Spawn Cessna 172 here  +  key, repaired and fuelled", nil,
        function() spawnCessna(playerNum, true) end)

    -- Then the gate. This is the entry that turns a spawned aeroplane into a flyable one.
    if need then
        local label = ("Set Aviation to %d  (the level the Cessna needs)"):format(need)
        if have >= need then label = label .. "  - already cleared" end
        menu:addOption(label, nil, function() setLevel(playerNum, need) end)
    else
        local opt = menu:addOption(
            "Set Aviation to the required level  -  UNAVAILABLE, aircraft not registered",
            nil, nil)
        opt.notAvailable = true
    end

    menu:addOption("Set Aviation to 10 (max)", nil, function() setLevel(playerNum, 10) end)
    menu:addOption("Reset Aviation to 0 (re-test the refusal)", nil,
        function() setLevel(playerNum, 0) end)

    menu:addOption("Spawn aviation manuals (all 3)", nil, function() giveManuals(playerNum) end)
    menu:addOption("Grant 200 Aviation XP  (the real book path)", nil,
        function() grantXP(playerNum, 200) end)
    menu:addOption("Grant 1000 Aviation XP", nil, function() grantXP(playerNum, 1000) end)
    menu:addOption("Report Aviation state to the log", nil, function() report(playerNum) end)
    menu:addOption("Report AIRCRAFT state to the log (why won't it start?)", nil,
        function() reportAircraft(playerNum) end)
    menu:addOption("MAKE THIS AIRCRAFT AIRWORTHY (repair, fuel, battery, engine quality)", nil,
        function()
            local player = getSpecificPlayer(playerNum)
            if not player then return end
            local v = player:getVehicle()
            if not v then
                pcall(function()
                    local n = scanNearby(player:getX(), player:getY(), 20)
                    if n > 0 then v = nearbyAircraft(0) end
                end)
            end
            if not v then
                print("[Cessna172][DEBUG] no Cessna within 20 tiles and you are not in one.")
                return
            end
            print("[Cessna172][DEBUG] serviced: " .. tostring(makeAirworthy(v)))
        end)
    menu:addOption(watching and "STOP watching lights + damage"
                             or "WATCH lights + damage (logs every change)", nil,
        function()
            if watching then
                watching = nil
                watchPrev = {}
                print("[Cessna172][WATCH] stopped.")
            else
                watching = playerNum
                watchPrev = {}
                print("[Cessna172][WATCH] started - sampling twice a second, logging only " ..
                      "CHANGES. Fly, land, switch the lights, and let zombies hit it.")
            end
        end)
end

-- The server's reply to debugSetAviation. Its own handler in C172Flight ignores anything that
-- is not a flight update, so a second listener for this one command is additive and cannot
-- interfere with it.
local function onServerCommand(module, command, args)
    if module ~= "cessna172" then return end
    if not debugOn() then return end
    local player = getPlayer()

    if command == "debugAviationSet" then
        local level = args and tonumber(args.level) or nil
        if not level then return end
        print(("[Cessna172][DEBUG] server confirmed Aviation = %d; the gate now reads canFly=%s")
            :format(level,
                    tostring(Aviation and Aviation.canFly(player, AIRCRAFT_ID) or "?")))
        halo(player, ("Aviation %d"):format(level))

    elseif command == "debugSpawned" then
        local keyed = args and args.keyed
        print(("[Cessna172][DEBUG] server spawned the aircraft (vehicleId=%s, %s)")
            :format(tostring(args and args.vehicleId or "?"),
                    keyed and "key delivered" or "NO KEY - check the server log"))
        halo(player, keyed and "Cessna spawned - keyed" or "Cessna spawned - NO KEY")
    end
end

Events.OnServerCommand.Add(onServerCommand)
Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
