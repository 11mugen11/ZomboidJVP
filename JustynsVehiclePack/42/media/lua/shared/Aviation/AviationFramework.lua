--[[
    ==========================================================================================
    AVIATION FRAMEWORK - a shared, aircraft-agnostic piloting skill for Project Zomboid mods.
    ==========================================================================================

    THIS FILE KNOWS NOTHING ABOUT ANY PARTICULAR AIRCRAFT. It owns a real PZ skill, a registry
    of aircraft that require it, and the question "may this character fly that?". Every
    aircraft-specific number, name and message lives in the aircraft mod's own registration
    file - for the Cessna that is Cessna172/C172Aviation.lua, which is the worked example.

    ------------------------------------------------------------------ VENDORED, NOT A DEPENDENCY

    Ship this whole `Aviation/` directory inside your aircraft mod. Several mods carrying it is
    the intended case, not a conflict: PZ loads exactly one copy of a given require() path, and
    the copies are interchangeable because the API below is versioned and additive. The guard
    at the bottom of this file means the FIRST copy loaded wins and later copies stand down,
    unless a later copy is NEWER, in which case it upgrades in place and keeps the aircraft
    that already registered.

    That is why there is no hard mod dependency, no load-order requirement, and no way for one
    aircraft mod to break another's registration.

    -------------------------------------------------------------------------- THE PUBLIC API

    Aviation.VERSION            integer, the API contract version. Compare, do not assume.
    Aviation.SKILL_ID           "Aviation" - the stable, documented perk id. Use this string,
                                not a captured Perk object, when persisting anything.
    Aviation.perk()             the PerkFactory Perk, or nil if the skill could not register.

    Aviation.registerAircraft(def)      -> ok, err
        def = {
            id        = "Base.Cessna172",  -- REQUIRED. Vehicle script full name; the key.
            name      = "Cessna 172",      -- REQUIRED. Shown in refusal messages.
            minLevel  = 3,                 -- REQUIRED. 0-10. Level needed to fly it.
            mod       = "Cessna172",       -- optional. Diagnostics only.
            apiVersion = 1,                -- optional. Refused if newer than Aviation.VERSION.
            deniedText = function(ctx) end -- optional. Custom refusal text.
        }
        Registering the same id twice from the same mod updates it. Registering an id another
        mod already owns is REFUSED and logged, so a future aircraft can never silently
        overwrite an existing one.

    Aviation.registerSkill(def)         -> ok, err
        For a future mod that wants a SECOND skill in the Aviation group (say "Rotorcraft").
        Additive; it cannot modify or replace the Aviation skill itself.

    Aviation.registerBook(def)          -> ok, err
        Declares that an item is an aviation manual, so the framework can report which books
        exist. The XP itself comes from PZ's own SkillBook system (see registerSkillBook
        below) - this is a catalogue, not a second progression system.

    Aviation.getLevel(character)        -> integer 0-10 (0 if the skill is unavailable)
    Aviation.canFly(character, scriptName) -> allowed, ctx
        ctx = { aircraft=, required=, current=, reason= }. `reason` is one of
        "ok", "unregistered", "skill-unavailable", "too-low", "no-character".
    Aviation.deniedMessage(ctx)         -> the player-facing sentence for a refusal.
    Aviation.addXP(character, amount)   -> adds Aviation XP through the normal XP system.

    ------------------------------------------------------------------------ WHY A REAL PERK

    This is a genuine PerkFactory perk, not a flag on the mod data. That means PZ owns it:
    levels and XP save and load with the character, replicate to clients, survive reconnects,
    show up in the skills panel with a progress bar, respond to XP multipliers and to skill
    books, and reset on death exactly like every vanilla skill. Nothing here re-implements any
    of that, and there is no mod-side "unlocked" boolean anywhere.

    PerkFactory keeps a 256-slot index array against roughly thirty vanilla perks, and
    PerkById is keyed by string id - so an added perk is what the engine expects, not a trick.

    ---------------------------------------------------------------------------- FAIL OPEN

    If the skill cannot be registered for any reason, canFly() returns TRUE for everything and
    says so in the log. An aircraft mod whose skill system failed to initialise should be an
    aircraft you can fly, not a permanently grounded ornament.
]]

local FRAMEWORK_VERSION = 1

-- Stand down if a copy of the same age or newer is already loaded. A NEWER copy upgrades in
-- place below, carrying the existing registrations across.
if Aviation and Aviation.VERSION and Aviation.VERSION >= FRAMEWORK_VERSION then return Aviation end

local carriedAircraft = (Aviation and Aviation.aircraft) or {}
local carriedBooks    = (Aviation and Aviation.books) or {}

Aviation = Aviation or {}
Aviation.VERSION  = FRAMEWORK_VERSION
Aviation.SKILL_ID = "Aviation"
Aviation.GROUP_ID = "AviationGroup"
Aviation.aircraft = carriedAircraft
Aviation.books    = carriedBooks

local function log(msg) print("[Aviation] " .. msg) end

-- ============================================================== the skill itself

-- Same pace as vanilla Carpentry. Deliberately not faster: the whole point is that finding an
-- aircraft is the beginning of being able to fly it rather than the end.
local XP_CURVE = { 50, 100, 200, 500, 1000, 2000, 3000, 4000, 5000, 6000 }

local skillPerk, groupPerk = nil, nil
local skillReady = false

-- Returns an existing perk with this ID, or nil.
--
-- ================= DO NOT USE PerkFactory.getPerkFromName() HERE =================
-- Despite the name it does NOT look up by id. Its bytecode is a single lookup in
-- `PerkByName`, a HashMap keyed by the perk's DISPLAY NAME - and AddPerk sets that display
-- name from Translator.getText("IGUI_perks_" .. name). Both of this mod's IGUI_perks_ keys
-- translated to the same string, "Aviation", so:
--
--   1. the GROUP was created first and registered in PerkByName under "Aviation";
--   2. makePerk("Aviation", ...) then asked getPerkFromName("Aviation") and got the GROUP;
--   3. it concluded the skill already existed and never created it.
--
-- skillPerk was therefore the GROUP header for the entire life of the mod, which produced
-- every reported symptom at once and made them look like four unrelated bugs: no Aviation
-- row in the skills panel (the real perk was never in PerkList), getPerkLevel permanently 0,
-- setPerkLevelDebug appearing to succeed and never persisting (it was writing a level onto a
-- group header the character does not carry), and canFly() refusing forever.
--
-- Perks.FromString is no better - it is the same name-keyed lookup and returns Perks.MAX for
-- a miss. So the id is matched against getId() by walking PerkList, which is exactly what the
-- skills panel itself walks and is the only lookup that is genuinely id-based.
local function existingPerk(id)
    local found = nil
    pcall(function()
        local list = PerkFactory.PerkList
        if not list then return end
        for i = 0, list:size() - 1 do
            local p = list:get(i)
            if p and tostring(p:getId()) == id then
                found = p
                return
            end
        end
    end)
    return found
end

local function makePerk(id, name, parent)
    local found = existingPerk(id)
    if found then return found end
    local ok, perk = pcall(function() return Perk.new(id) end)
    if not ok or not perk then return nil end
    pcall(function() perk:setCustom() end)
    local ok2 = pcall(function()
        if parent then
            PerkFactory.AddPerk(perk, name, parent,
                XP_CURVE[1], XP_CURVE[2], XP_CURVE[3], XP_CURVE[4], XP_CURVE[5],
                XP_CURVE[6], XP_CURVE[7], XP_CURVE[8], XP_CURVE[9], XP_CURVE[10])
        else
            PerkFactory.AddPerk(perk, name,
                XP_CURVE[1], XP_CURVE[2], XP_CURVE[3], XP_CURVE[4], XP_CURVE[5],
                XP_CURVE[6], XP_CURVE[7], XP_CURVE[8], XP_CURVE[9], XP_CURVE[10])
        end
    end)
    if not ok2 then return nil end
    return perk
end

-- Wires the skill into PZ's book system. SkillBook is a plain Lua table keyed by the
-- `SkillTrained = ...` string in the item script; the multipliers are the reading bonus at
-- each level of the book's own progression, matching vanilla's values exactly.
local function registerSkillBook()
    if type(SkillBook) ~= "table" then return false end
    if SkillBook[Aviation.SKILL_ID] then return true end
    SkillBook[Aviation.SKILL_ID] = {
        perk = skillPerk,
        maxMultiplier1 = 3,
        maxMultiplier2 = 5,
        maxMultiplier3 = 8,
        maxMultiplier4 = 12,
        maxMultiplier5 = 16,
    }
    return true
end

local function initSkill()
    if skillReady then return true end
    if type(PerkFactory) ~= "table" and type(PerkFactory) ~= "userdata" then return false end

    -- The GROUP is a perk whose parent is None. ISCharacterInfo.loadPerk builds the skills
    -- panel by bucketing every perk under its parent and never looks at a fixed list, so a
    -- new group renders on its own. Future aviation skills hang off this same group.
    groupPerk = groupPerk or makePerk(Aviation.GROUP_ID, "AviationGroup", nil)
    if not groupPerk then return false end
    skillPerk = skillPerk or makePerk(Aviation.SKILL_ID, "Aviation", groupPerk)
    if not skillPerk then return false end

    -- THE GUARD FOR THE BUG ABOVE. If the skill and the group ever resolve to the same perk
    -- again, the skill does not exist and everything downstream silently misbehaves rather
    -- than failing. Refuse instead, which makes the framework fail OPEN - the aircraft flies
    -- unrestricted and says why - rather than fail closed and ground it forever.
    if skillPerk == groupPerk then
        log("FATAL: the Aviation skill resolved to the Aviation GROUP, so the skill was " ..
            "never created. Almost certainly an IGUI_perks_ display-name collision - see " ..
            "the note on existingPerk(). Failing OPEN: the aircraft will fly unrestricted.")
        skillPerk = nil
        return false
    end

    skillReady = true
    registerSkillBook()
    log(("skill ready (id=%s, group=%s, framework v%d)")
        :format(Aviation.SKILL_ID, Aviation.GROUP_ID, FRAMEWORK_VERSION))
    return true
end

function Aviation.perk()
    if not skillReady then initSkill() end
    return skillPerk
end

function Aviation.isSkillAvailable()
    if not skillReady then initSkill() end
    return skillReady
end

-- =============================================================== aircraft registry

local function validate(def)
    if type(def) ~= "table" then return false, "definition must be a table" end
    if type(def.id) ~= "string" or def.id == "" then return false, "missing id" end
    if type(def.name) ~= "string" or def.name == "" then return false, "missing name" end
    if type(def.minLevel) ~= "number" or def.minLevel < 0 or def.minLevel > 10 then
        return false, "minLevel must be a number 0-10"
    end
    if def.apiVersion and def.apiVersion > FRAMEWORK_VERSION then
        return false, ("needs Aviation API v%d, this is v%d - update the framework copy")
            :format(def.apiVersion, FRAMEWORK_VERSION)
    end
    return true
end

function Aviation.registerAircraft(def)
    local ok, err = validate(def)
    if not ok then
        log("registerAircraft REFUSED: " .. tostring(err))
        return false, err
    end
    local prev = Aviation.aircraft[def.id]
    -- Re-registration by the SAME mod is an update (a reload, or a newer version of that mod).
    -- Re-registration by a DIFFERENT mod is refused: one aircraft mod must never be able to
    -- silently change another's requirements.
    if prev and prev.mod and def.mod and prev.mod ~= def.mod then
        local msg = ("%s is already registered by mod '%s'; '%s' refused")
            :format(def.id, tostring(prev.mod), tostring(def.mod))
        log("registerAircraft REFUSED: " .. msg)
        return false, msg
    end
    Aviation.aircraft[def.id] = {
        id = def.id, name = def.name, minLevel = def.minLevel,
        mod = def.mod, deniedText = def.deniedText,
    }
    log(("aircraft registered: %s (%s) needs %s %d [%s]")
        :format(def.name, def.id, Aviation.SKILL_ID, def.minLevel, tostring(def.mod or "?")))
    return true
end

function Aviation.getAircraft(scriptName)
    return scriptName and Aviation.aircraft[scriptName] or nil
end

-- A future mod wanting its own skill in the Aviation group - "Rotorcraft", say. Purely
-- additive: it cannot touch the Aviation skill or any registered aircraft.
function Aviation.registerSkill(def)
    if type(def) ~= "table" or type(def.id) ~= "string" or def.id == "" then
        return false, "missing id"
    end
    if def.id == Aviation.SKILL_ID or def.id == Aviation.GROUP_ID then
        return false, "reserved id"
    end
    if not Aviation.isSkillAvailable() then return false, "aviation skill unavailable" end
    local p = makePerk(def.id, def.name or def.id, groupPerk)
    if not p then return false, "could not create perk" end
    log("extra skill registered in the Aviation group: " .. def.id)
    return true, p
end

function Aviation.registerBook(def)
    if type(def) ~= "table" or type(def.item) ~= "string" then return false, "missing item" end
    Aviation.books[def.item] = {
        item = def.item, mod = def.mod,
        levels = def.levels, name = def.name or def.item,
    }
    return true
end

-- ================================================================== queries

-- ================= MODDATA IS THE AUTHORITY, NOT THE PERK =================
--
-- This is the third attempt at making an Aviation level stick, and the first two failed for
-- the same underlying reason, which is worth stating plainly: PZ DOES NOT RELIABLY PERSIST A
-- MOD-ADDED PERK'S LEVEL. IsoGameCharacter's save path writes no perk data, and a character
-- only carries a PerkInfo for perks that existed when its perk list was built - so on every
-- load, and on every rebuild of the character from the server in multiplayer, the level is
-- gone. Writing it back merely restarts the same loop, which is what produced both the log
-- spam and "it starts at 0 every load".
--
-- So the roles are inverted. The character's own ModData - which PZ genuinely saves and
-- replicates - holds the real level. The PERK is now a MIRROR of that, kept in step purely so
-- the skills panel and anything else reading getPerkLevel show the right number. Nothing
-- depends on the perk holding a value any more.
--
-- getLevel returns the HIGHER of the two, so XP earned the normal way (which raises the perk,
-- not the ModData) is never lost: reconcile then copies that gain into the ModData on its next
-- pass. Progress in either direction is picked up; neither can silently overwrite the other.
local MIRROR_KEY_LEVEL = "AviationLevelMirror"
-- The original store, kept as a name so old saves can be migrated (see storedLevel).
local TRAINED_KEY = "aviationTrainedLevel"

-- TWO STORES, BECAUSE ONE OF THEM WAS NOT SURVIVING A RELOAD.
--
-- The character's own getModData() is the natural home for a per-character value, and it is
-- written first. But observed behaviour is that the level was correctly saved in-session and
-- read back as 0 on the next load, so on this setup that store is not making it to disk for
-- the player character - plausibly because a coop host's character is rebuilt from the server
-- side on load, before anything here runs.
--
-- ModData.getOrCreate is PZ's own global persistent table - it is what vanilla itself uses to
-- remember unique vehicle spawns across sessions (ProfessionVehicles.lua) - and it is saved
-- with the WORLD rather than with the character. Keyed by username, it gives the same
-- per-player value with a persistence path that does not depend on the character object at
-- all. Both are written; the higher of the two is believed.
local GLOBAL_TABLE = "C172AviationLevels"
local loggedFirstWrite = false

-- THE TABLE MUST BE CREATED IN OnInitGlobalModData OR IT IS NEVER SAVED.
--
-- This is why the level vanished on every reload even after both stores were added: the
-- startup diagnostic read "character ModData says nil | world ModData says nil", i.e. the
-- writes were fine in-session and simply were not on disk. A global ModData table that is
-- first touched mid-session is not part of the save; PZ only persists tables that exist when
-- the world's global mod data is initialised. Vanilla does exactly this in
-- ProfessionVehicles.lua for its unique-vehicle record.
--
-- Registering it here also means the table EXISTS before anything reads it, so the read path
-- no longer has to cope with a nil table on a fresh world.
if Events and Events.OnInitGlobalModData then
    Events.OnInitGlobalModData.Add(function(isNewGame)
        -- LOGGED, because this link has now been guessed at twice. If the level still resets,
        -- this line says whether the table was created at all and what survived in it - which
        -- separates "never registered" from "registered but not written" from "written but not
        -- saved". Those are three different bugs and they look identical from the outside.
        local ok, t = pcall(function() return ModData.getOrCreate(GLOBAL_TABLE) end)
        local n = 0
        if ok and type(t) == "table" then
            for _ in pairs(t) do n = n + 1 end
        end
        log(("global store init: ok=%s newGame=%s entries restored=%d (isServer=%s isClient=%s)")
            :format(tostring(ok), tostring(isNewGame), n,
                    tostring(isServer and isServer()), tostring(isClient and isClient())))
    end)
end

local function usernameOf(character)
    if not character then return nil end
    local ok, name = pcall(function() return character:getUsername() end)
    if ok and type(name) == "string" and name ~= "" then return name end
    return nil
end

-- PREFER THE SERVER-SIDE STORE. AviationStore lives in media/lua/server/ and is therefore the
-- only side whose global ModData writes are actually saved - the instrumented run proved a
-- shared/-side write is a client copy that is discarded ("entries restored=0" after a write
-- that reported success). In singleplayer and on a coop host the server VM is this VM and the
-- global is directly callable; on a dedicated server it is absent here and the debugSetAviation
-- command already carries the write to the right side.
--
-- The direct table access below remains as a fallback so a read never fails outright, but it
-- is explicitly NOT relied on for persistence.
local function globalStore()
    local ok, t = pcall(function() return ModData.getOrCreate(GLOBAL_TABLE) end)
    return (ok and type(t) == "table") and t or nil
end

local function serverStore()
    if type(AviationStore) == "table"
       and type(AviationStore.get) == "function"
       and type(AviationStore.set) == "function" then
        return AviationStore
    end
    return nil
end

local function clamp10(v)
    v = tonumber(v)
    if type(v) ~= "number" or v ~= v or v < 0 then return 0 end
    if v > 10 then return 10 end
    return math.floor(v)
end

-- Reads all THREE historical stores and takes the highest, which is what makes this a
-- migration rather than a reset:
--   aviationTrainedLevel  the ORIGINAL key, written by AviationBookXP when a manual is read.
--                         Any existing save carries progress only under this name.
--   AviationLevelMirror   the per-character mirror added later.
--   C172AviationLevels    the world-level table, the only one proven to survive a reload
--                         (and only once registered in OnInitGlobalModData - see above).
-- Taking the max means a player who earned the skill before any of this existed keeps it, and
-- no store can ever silently lower another. Everything WRITES all of them (writeStores), so
-- they converge after the first save.
local function storedLevel(character)
    if not character then return 0 end

    local fromChar = 0
    local ok, md = pcall(function() return character:getModData() end)
    if ok and md then
        fromChar = clamp10(md[MIRROR_KEY_LEVEL])
        local legacy = clamp10(md[TRAINED_KEY])
        if legacy > fromChar then fromChar = legacy end
    end

    -- The SERVER store is the only one whose writes survive a reload, so it is consulted
    -- too and the highest of the three wins - which is what makes this a migration rather
    -- than a reset for anyone who already had a level under an older key.
    local fromServer = 0
    local ss = serverStore()
    if ss then
        local nm = usernameOf(character)
        if nm then
            local okS, v = pcall(function() return ss.get(nm) end)
            if okS and type(v) == "number" then fromServer = clamp10(v) end
        end
    end

    local fromWorld = 0
    local name = usernameOf(character)
    local g = name and globalStore()
    if g then fromWorld = clamp10(g[name]) end

    local best = fromChar
    if fromWorld  > best then best = fromWorld  end
    if fromServer > best then best = fromServer end
    return best
end

-- Writes BOTH stores. Called from every path that changes the level.
local function writeStores(character, level)
    level = clamp10(level)
    pcall(function()
        local md = character:getModData()
        md[MIRROR_KEY_LEVEL] = level
        -- Kept in step so any code still reading the original key sees the truth.
        if clamp10(md[TRAINED_KEY]) < level then md[TRAINED_KEY] = level end
    end)
    local name = usernameOf(character)

    -- Authoritative path first.
    local ss = name and serverStore()
    if ss then
        pcall(function() ss.set(name, level) end)
    end

    local g = name and globalStore()
    if g then
        g[name] = level
        -- Global ModData is only written to disk if the table is marked for transmit/save.
        pcall(function() ModData.transmit(GLOBAL_TABLE) end)
        if not loggedFirstWrite then
            loggedFirstWrite = true
            log(("global store first write: [%s] = %d (table present, transmit sent)")
                :format(tostring(name), level))
        end
    elseif not loggedFirstWrite then
        loggedFirstWrite = true
        log(("global store UNAVAILABLE on write (username=%s) - the world-level store is not " ..
             "reachable from this side, so only the per-character keys can persist.")
            :format(tostring(name)))
    end
    return level
end

local function perkLevel(character)
    if not character then return 0 end
    local perk = Aviation.perk()
    if not perk then return 0 end
    local ok, lvl = pcall(function() return character:getPerkLevel(perk) end)
    return (ok and type(lvl) == "number") and lvl or 0
end

function Aviation.getLevel(character)
    if not character then return 0 end
    local a, b = storedLevel(character), perkLevel(character)
    return (a > b) and a or b
end

-- The one way to deliberately set a level. Writes the authority FIRST, then mirrors it onto
-- the perk for display; if the perk write does not stick, the level is still correct.

-- ============================================== making the PANEL agree
--
-- WHY THE SKILLS CHART STAYED GREY. setPerkLevelDebug writes a LEVEL and nothing else, so the
-- perk ends up at level N with ZERO experience behind it. Anything that recomputes a level
-- from its XP - a stat sync, a reload, PZ's own bookkeeping - then finds 0 XP and drops the
-- level straight back to 0. That is what kept resetting it, and it is why re-writing the level
-- on a timer only produced a number that flickered between N and 0.
--
-- So the level is now BACKED BY REAL XP. Perk.getTotalXpForLevel(n) is the engine's own answer
-- for how much experience level n requires, and AddXPNoMultiplier puts exactly that much in
-- without the sandbox XP multiplier distorting it. Once the XP is there, every recalculation
-- arrives at the same level instead of zero, and the chart lights up on its own.
--
-- setPerkLevelDebug is still called FIRST, because it is one of only two calls that creates
-- the character's missing PerkInfo for a mod-added perk - without that slot there is nothing
-- for the XP to be added to.
local syncReports = 0

-- ============================ EVERY PERK WRITE IS A NETWORK PACKET ============================
--
-- IsoGameCharacter.setPerkLevelDebug ends with, in its own bytecode:
--
--     getstatic GameClient.client:Z
--     ifeq      <return>
--     instanceof IsoPlayer
--     invokestatic GameClient.sendPerks(IsoPlayer)
--
-- and GameClient.sendPerks opens a UdpConnection packet, writes a SyncPerks payload and
-- SENDS IT, every call. So in any networked session - a dedicated server client, and a coop
-- host too, because GameClient.client is true there as well - correcting the perk is not a
-- local write. It is a packet.
--
-- That matters because this correction CANNOT SUCCEED in multiplayer: the server owns skills
-- and zeroes a mod-added perk back again, which is exactly what the instrumented run
-- recorded (level before=0 after every pass, forever). So the condition that triggers the
-- correction is permanently true, and a correction on the tick path therefore means a
-- SyncPerks packet on the tick path - two per tick, about 120 a second per player, for as
-- long as the character is logged in. It is silent, it never stops, and none of it helps:
-- sendPerks only carries Sneak, Strength and Fitness, so the Aviation level it is fighting
-- over is not even in the packet.
--
-- Singleplayer sends nothing at all (GameClient.client is false), which is why this is
-- invisible on a developer's machine and only reaches players on servers.
--
-- SO THE CADENCE IS CONDITIONAL, exactly as the cost is. In singleplayer the write is free
-- and stays responsive, so the skills panel reads correctly the moment it is opened. In a
-- networked session it is backed right off: the panel may briefly show a low Aviation level
-- there, which is cosmetic and already the documented reality of a mod-added perk in
-- multiplayer, and is a far better trade than flooding the server.
--
-- A DELIBERATE set - a manual finished, a debug grant - passes `force` and is never delayed.
local PERK_WRITE_MIN_MS_SP = 100
local PERK_WRITE_MIN_MS_MP = 3000
local lastPerkWriteAt = 0

local function networked()
    local ok, v = pcall(function() return isClient and isClient() end)
    return ok and v == true
end

local function syncPerkToLevel(character, level, force)
    local perk = Aviation.perk()
    if not perk or not character then return end

    -- 1.10.4: NEVER AUTOMATICALLY ON A MULTIPLAYER CLIENT. A player report (10-09, a 42.21 server):
    -- "got some errors for the cessna ... seems like a looping one" - 20 errors in one session from
    -- the XP top-up below (AddXPNoMultiplier), one per retry. As documented above, the server owns
    -- skills and zeroes this perk again, so the retry could never win; on 42.21 the client-side XP
    -- write now also errors. Flying is unaffected: the flight gate reads the SAVED level
    -- (Aviation.getLevel), never the perk. A deliberate set (`force`) still runs.
    if networked() and not force then return end

    local nowMs = (getTimestampMs and getTimestampMs()) or 0
    if not force then
        local gap = networked() and PERK_WRITE_MIN_MS_MP or PERK_WRITE_MIN_MS_SP
        if (nowMs - lastPerkWriteAt) < gap then return end
    end
    lastPerkWriteAt = nowMs

    -- MEASURED, NOT ASSUMED. The panel still reads 0 after a correction, and "the write fails"
    -- and "the write succeeds then something reverts it" need completely different fixes. This
    -- records the level immediately before, immediately after the level write, and immediately
    -- after the XP write, plus the XP totals - which separates the two outright. Logged for the
    -- first few corrections only, so it cannot become spam.
    local before = 0
    pcall(function() before = character:getPerkLevel(perk) end)

    -- 1. ensure the character actually carries this perk
    pcall(function() character:setPerkLevelDebug(perk, level) end)

    local afterSet = 0
    pcall(function() afterSet = character:getPerkLevel(perk) end)

    -- 2. and give it the experience that level is worth, so nothing can recalculate it away
    -- TOP THE XP UP UNTIL IT ACTUALLY REACHES THE THRESHOLD.
    --
    -- A single AddXPNoMultiplier call does NOT deposit the amount asked for: the instrumented
    -- run requested 225 (the cost of level 2) and the perk ended up holding 56.25 - exactly a
    -- quarter. Whatever scales it, the result was a level 2 flag sitting on level-1 XP, so
    -- every recalculation PZ did pulled the level back down. THAT is the flicker, and no
    -- amount of re-writing the level faster could have fixed it - the underlying XP was wrong.
    --
    -- So it is added in a bounded loop until the total genuinely covers the level. The guard
    -- is both a pass count and a no-progress check, so a build where AddXP deposits nothing
    -- exits immediately instead of spinning.
    pcall(function()
        local want = perk:getTotalXpForLevel(level)
        local xp   = character:getXp()
        if not xp or type(want) ~= "number" then return end

        -- AIM PAST THE THRESHOLD, AND ALLOW ENOUGH PASSES TO GET THERE.
        --
        -- Each AddXPNoMultiplier deposits roughly a QUARTER of the amount requested, so
        -- repeatedly asking for the exact shortfall closes about 25% of the gap per pass and
        -- approaches the target asymptotically without ever crossing it: 12 passes reached
        -- 217.87 of the 225 that level 2 costs, which is still short, so PZ kept recalculating
        -- the level back down. That was the remaining flicker.
        --
        -- Asking for a 5% overshoot each time means the total genuinely crosses `want`, and
        -- the loop stops the moment it does - so the perk ends up just over the line rather
        -- than inflated. 40 passes is far more than the ~27 the observed deposit rate needs.
        local target = want * 1.05
        local passes = 0
        while passes < 40 do
            local have = xp:getXP(perk)
            if type(have) ~= "number" or have >= want then break end
            xp:AddXPNoMultiplier(perk, target - have)
            local after = xp:getXP(perk)
            if type(after) ~= "number" or after <= have then break end   -- no progress
            passes = passes + 1
        end
    end)

    -- The level is re-asserted AFTER the XP, because topping the XP up can itself trigger a
    -- level recalculation and we want the final word.
    pcall(function() character:setPerkLevelDebug(perk, level) end)

    -- Diagnostic retained but effectively off: at 500ms it would otherwise print twice a
    -- second forever. It answered its question (the write works; the server zeroes it), and
    -- two samples are enough to confirm that again after any future change.
    if syncReports < 2 then
        syncReports = syncReports + 1
        local afterXp, xpNow, xpWant = 0, "?", "?"
        pcall(function() afterXp = character:getPerkLevel(perk) end)
        pcall(function() xpNow  = tostring(character:getXp():getXP(perk)) end)
        pcall(function() xpWant = tostring(perk:getTotalXpForLevel(level)) end)
        log(("perk sync #%d -> target %d | level before=%d afterSetPerkLevelDebug=%d " ..
             "afterXP=%d | xp now=%s needed=%s")
            :format(syncReports, level, before, afterSet, afterXp, xpNow, xpWant))
    end
end

function Aviation.setLevel(character, level)
    if not character then return 0 end
    level = math.floor(tonumber(level) or 0)
    if level < 0 then level = 0 end
    if level > 10 then level = 10 end
    writeStores(character, level)
    -- FORCED. This is a deliberate set - a manual finished, or a debug grant - and it must
    -- land the instant it is asked for. Only the automatic re-assertion is rate-limited.
    syncPerkToLevel(character, level, true)
    return Aviation.getLevel(character)
end

function Aviation.addXP(character, amount)
    if not character or not amount or amount <= 0 then return false end
    local perk = Aviation.perk()
    if not perk then return false end
    return pcall(function() character:getXp():AddXP(perk, amount) end)
end

-- The one question the whole framework exists to answer.
function Aviation.canFly(character, scriptName)
    local craft = Aviation.getAircraft(scriptName)
    -- An unregistered vehicle is none of this framework's business.
    if not craft then return true, { reason = "unregistered" } end
    if not character then return true, { reason = "no-character", aircraft = craft } end
    -- FAIL OPEN. A skill system that failed to initialise must not ground the aircraft.
    if not Aviation.isSkillAvailable() then
        return true, { reason = "skill-unavailable", aircraft = craft }
    end
    local level = Aviation.getLevel(character)
    local ctx = { aircraft = craft, required = craft.minLevel, current = level }
    if level >= craft.minLevel then
        ctx.reason = "ok"
        return true, ctx
    end
    ctx.reason = "too-low"
    return false, ctx
end

function Aviation.deniedMessage(ctx)
    if not ctx or not ctx.aircraft then return "" end
    if ctx.aircraft.deniedText then
        local ok, txt = pcall(ctx.aircraft.deniedText, ctx)
        if ok and type(txt) == "string" then return txt end
    end
    return ("Your Aviation skill is too low to fly the %s.  (Aviation %d / %d required)")
        :format(ctx.aircraft.name, ctx.current or 0, ctx.required or 0)
end


-- ================================================== earned-training record
--
-- WHY THIS EXISTS. Aviation is a CUSTOM perk, and a custom perk is only as durable as the
-- other side's knowledge of it. In multiplayer the server owns character stats, and a level
-- in a perk the server does not have registered is not merely unsaved - it is actively
-- overwritten on the next stat sync. Observed directly: Aviation went 0 -> 10, satisfied
-- canFly(), and was silently back to 0 twenty seconds later with nothing logged in between.
-- A player who finds a manual, reads it through several in-game hours and then loses the
-- level minutes later has lost the whole point of the progression.
--
-- WHAT THIS IS NOT. It is not a second XP system and it is not an override. It records only
-- what the character has GENUINELY EARNED through the normal path - finishing a manual -
-- and it only ever raises the perk back UP to that recorded level. It can never grant a
-- level that was not earned, never lowers anything, and does nothing at all when the perk
-- already reads at or above the record.
--
-- WHY ModData. IsoPlayer:getModData() is saved with the character and replicated by
-- vanilla's own netcode, so it survives a relog, a server restart and a stat sync - all the
-- things the perk level itself does not survive when the server has no such perk. It is also
-- per-character, so death resets the record exactly as death resets the skill.
--
-- FAIL OPEN, like everything else here: any failure leaves the character untouched.
-- TRAINED_KEY is declared once, near the other store keys at the top of this section.

local function modDataOf(character)
    if not character then return nil end
    local ok, md = pcall(function() return character:getModData() end)
    if not ok or type(md) ~= "table" then return nil end
    return md
end

--- The highest level this character has actually earned, or 0.
function Aviation.trainedLevel(character)
    local md = modDataOf(character)
    if not md then return 0 end
    local v = tonumber(md[TRAINED_KEY])
    if type(v) ~= "number" or v ~= v or v < 0 then return 0 end
    if v > 10 then v = 10 end
    return math.floor(v)
end

--- Records an earned level. Monotonic: it never lowers an existing record.
function Aviation.recordTrained(character, level)
    local md = modDataOf(character)
    if not md then return false end
    level = tonumber(level)
    if type(level) ~= "number" or level ~= level or level <= 0 then return false end
    if level > 10 then level = 10 end
    local prev = Aviation.trainedLevel(character)
    if level <= prev then return true end
    -- ROUTED THROUGH writeStores, not written straight to TRAINED_KEY. This is the NORMAL
    -- progression path - the player read a manual - and it previously wrote only the
    -- per-character key, which is the store that does not survive a reload. Sending it through
    -- the same writer the debug menu and the reconciler use means earned progress and granted
    -- progress persist by exactly the same mechanism, and there is no path that can save to
    -- only one store.
    writeStores(character, math.floor(level))
    log(("earned training recorded: Aviation %d (was %d)"):format(math.floor(level), prev))
    return true
end

--- Raises the perk back to the earned level if something has knocked it down. Returns the
--- level it restored to, or nil when nothing needed doing - which is the overwhelming case.
function Aviation.restoreTrained(character)
    if not character then return nil end
    if not Aviation.isSkillAvailable() then return nil end
    local want = Aviation.trainedLevel(character)
    if want <= 0 then return nil end
    local have = Aviation.getLevel(character)
    if have >= want then return nil end

    local perk = Aviation.perk()
    if not perk then return nil end
    -- LevelPerk is vanilla's own "raise this skill by one" call, so a level-up does whatever
    -- PZ does on a level-up. Bounded by the perk ceiling so a bad record cannot spin.
    local guard = 0
    while guard < 10 and Aviation.getLevel(character) < want do
        pcall(function() character:LevelPerk(perk) end)
        guard = guard + 1
    end
    local now = Aviation.getLevel(character)
    if now > have then
        log(("restored earned Aviation %d (had dropped to %d)"):format(now, have))
        return now
    end
    return nil
end

-- Cheap and rare: one getModData plus one getPerkLevel per in-game minute, and only for the
-- local player. Deliberately NOT OnPlayerUpdate, which runs every tick.
if Events and Events.EveryOneMinute then
    Events.EveryOneMinute.Add(function()
        local ok, player = pcall(function() return getPlayer() end)
        if ok and player then pcall(function() Aviation.restoreTrained(player) end) end
    end)
end


-- ================================================== persistence backstop
--
-- WHY THIS EXISTS. A mod-added perk's level is not reliably persisted. The engine's own
-- character save path writes no perk data, and a character only carries a PerkInfo for a perk
-- that existed when its perk list was built - so an Aviation level can survive a session and
-- be gone after a reload, a rejoin, or anything that rebuilds the character from the server.
-- That is the "my Aviation skill keeps resetting" report, and it is NOT caused by the debug
-- menu: the debug menu writes the same real perk that reading a book writes.
--
-- SO THE LEVEL IS MIRRORED into the character's own ModData, which PZ does save and does
-- replicate, and reconciled once every few seconds:
--
--   perk level HIGHER than the mirror  -> the player progressed. Update the mirror.
--   perk level LOWER  than the mirror  -> something reset the perk. Put it back, and say so.
--
-- The mirror is per-character ModData, so a new character after death starts with none and
-- correctly begins at zero - the backstop cannot resurrect a dead character's skill.
--
-- setPerkLevelDebug is the restore call because it is one of only two methods that CONSTRUCTS
-- the character's missing PerkInfo (the other being the two-argument LevelPerk); level0 and
-- the one-argument LevelPerk both no-op when getPerkInfo is null, which is the whole problem
-- being worked around here.
-- 500ms, not 5000.
--
-- The instrumented run settled what was happening: every pass reported
--     level before=0  afterSetPerkLevelDebug=2  afterXP=2
-- so the write ALWAYS works and something - the server's periodic player-stat sync, which
-- knows nothing about a mod-added perk - zeroes it again between passes. That is the exact
-- opposite of what the earlier "give up, it flickers" reasoning assumed: the bar flickered
-- because the correction was RARE, so the level read 0 for most of every five-second window.
--
-- Correcting ten times more often means the panel is showing the right level almost all the
-- time, which is what makes the bar look solid. The cost is one getPerkLevel per half second
-- and a setPerkLevelDebug only when it has actually been zeroed.
local RECONCILE_MS = 500
local lastReconcileAt = 0
local lastLoggedLevel = nil

function Aviation.rememberLevel(character)
    if not character then return end
    writeStores(character, Aviation.getLevel(character))
end

-- Keeps the PERK in step with the authority. Deliberately silent unless the number it is
-- pushing actually changes: the previous version logged every single pass, which is the
-- "Aviation level spamming" report - five seconds apart, forever, saying the same thing.
function Aviation.reconcileLevel(character)
    if not character or not Aviation.isSkillAvailable() then return nil end

    local stored = storedLevel(character)
    local live   = perkLevel(character)

    -- Earned normally (a book raised the perk): promote that into the authority.
    if live > stored then
        writeStores(character, live)
        if lastLoggedLevel ~= live then
            lastLoggedLevel = live
            log("Aviation progressed to " .. tostring(live) .. " - saved.")
        end
        return "progressed"
    end

    -- The usual case: the perk lost its level. Putting it back makes the skills panel right -
    -- but ONLY IF IT STAYS PUT. Something on this setup wipes it again within seconds, so
    -- re-writing it every pass made the panel visibly flick between the real level and 0,
    -- which is worse than a panel that is simply wrong. It is therefore attempted a few times
    -- and then left alone for the session.
    --
    -- Nothing is lost by giving up: the FLIGHT GATE reads Aviation.getLevel, which takes the
    -- higher of the two saved stores and never consults the perk. The aircraft flies at the
    -- correct level whether or not the panel agrees.
    if live < stored then
        -- No give-up counter any more. The old one existed because re-writing a bare level
        -- was a fight that could not be won - the level had no XP behind it and was reset
        -- again within seconds. syncPerkToLevel writes the XP too, so a single correction
        -- holds and there is nothing left to flicker.
        syncPerkToLevel(character, stored)
        if lastLoggedLevel ~= stored then
            lastLoggedLevel = stored
            log(("Aviation is %d (saved); the perk had dropped to %d and was re-mirrored for " ..
                 "the skills panel. This is expected - PZ does not persist mod-added perks - " ..
                 "and is logged once per value, not every pass."):format(stored, live))
        end
        return "restored"
    end

    lastLoggedLevel = stored
    return nil
end

-- SPLIT INTO A CHEAP PER-TICK CHECK AND AN OCCASIONAL FULL RECONCILE.
--
-- The XP is now correct - the instrumented run reads 226.27 against the 225 that level 2 costs
-- - and the level is STILL 0 at the start of every pass. So nothing is recalculating the level
-- down from XP; something is explicitly setting it to zero. There is no state to fix, only a
-- race to win, and the only lever left is to correct it more often than it is being zeroed.
--
-- Doing the FULL reconcile every tick would be wasteful: it reads the saved level from disk
-- and ModData. So the saved value is cached and refreshed on the old cadence, while the
-- per-tick work is one getPerkLevel comparison against that cache - and a write only in the
-- ticks where it has actually been zeroed. That is what makes the bar read solid instead of
-- strobing between the real level and 0.
local cachedStored, cachedStoredAt = nil, 0

local function reconcileTick()
    local t = (getTimestampMs and getTimestampMs()) or 0
    local ok, player = pcall(function() return getPlayer() end)
    if not (ok and player) then return end

    -- Full pass on the slow cadence: refreshes the cache and handles progress in either
    -- direction (a book read, a debug grant, a level that needs saving).
    if (t - lastReconcileAt) >= RECONCILE_MS then
        lastReconcileAt = t
        Aviation.reconcileLevel(player)
        cachedStored   = storedLevel(player)
        cachedStoredAt = t
        return
    end

    -- Cheap pass, every other tick: just keep the perk from sitting at zero.
    if cachedStored == nil or cachedStored <= 0 then return end
    if not Aviation.isSkillAvailable() then return end
    if perkLevel(player) >= cachedStored then return end
    syncPerkToLevel(player, cachedStored)
end

if Events then
    if Events.OnTick then Events.OnTick.Add(reconcileTick) end
    -- On load, reconcile immediately rather than waiting for the first tick window, so the
    -- skills panel is already correct the first time the player opens it.
    if Events.OnGameStart then
        Events.OnGameStart.Add(function()
            local ok, player = pcall(function() return getPlayer() end)
            if ok and player then Aviation.reconcileLevel(player) end
        end)
    end
end

-- ================================================================== boot

-- PerkFactory's statics are initialised long before mod Lua runs, so this usually succeeds
-- immediately; the events are the belt and braces for a load order that surprises us, and for
-- a dedicated server where the boot sequence differs. initSkill() and registerSkillBook() are
-- both idempotent, so running them repeatedly costs one table lookup.
local function boot()
    initSkill()
    registerSkillBook()
end

boot()
if Events then
    if Events.OnGameBoot then Events.OnGameBoot.Add(boot) end
    if Events.OnGameStart then Events.OnGameStart.Add(boot) end
    if Events.OnServerStarted then Events.OnServerStarted.Add(boot) end
end

return Aviation
