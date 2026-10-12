--[[
    C172Recovery - this aircraft's radial-menu entries.

      Land Aircraft    the normal, controlled way to end a flight. Only shown while
                       genuinely airborne. An explicit menu selection is deliberate
                       intent, so it needs none of the accidental-input protection a
                       held key would - see C172Flight.requestLanding.
      RIGHT AIRCRAFT   returns a flipped, stuck or misbehaving aircraft to a normal
                       upright GROUND state roughly where it already is. A second,
                       independent escape hatch that works regardless of what the
                       landing controller is doing. Also bound to [ .

    ===================================================================================
    COEXISTING WITH THE OTHER AIRCRAFT MODS' OWN RADIAL WRAPPERS
    ===================================================================================
    ISVehicleMenu.showRadialMenu is a single vanilla global, and the MiG-29 and VX-9
    mods each wrap it with the same "capture whatever is currently installed, call
    through, then append our own slices" pattern used here. Whichever mod's Lua loads
    last captures the others' already-installed wrapper as its own `orig`, so all of
    them compose into one correct call chain regardless of load order. Nothing here
    replaces or reorders anything: the original is always called first and unmodified,
    and slices are only ever APPENDED.

    RADIAL POLLUTION IS GATED AT THE TOP. addRecoverySlice returns immediately unless
    the vehicle's script name is this aircraft's, so these options can never appear on
    the MiG, the Wraith, a vanilla car, or another mod's vehicle.
]]

require "Cessna172/C172Util"
require "Cessna172/C172Phys"
require "Cessna172/C172Flight"

C172Recovery = C172Recovery or {}

local COOLDOWN_SEC = 3.0
local lastUseAt = {}

local function log(msg) print("[Cessna172][RECOVERY] " .. msg) end

local function methodExists(obj, name)
    if obj == nil then return false end
    local ok, m = pcall(function() return obj[name] end)
    return ok and m ~= nil
end
local function call0(obj, name)
    if not methodExists(obj, name) then return false, nil end
    return pcall(function() return obj[name](obj) end)
end
local function call1(obj, name, a)
    if not methodExists(obj, name) then return false, nil end
    return pcall(function() return obj[name](obj, a) end)
end
local function call3(obj, name, a, b, c)
    if not methodExists(obj, name) then return false, nil end
    return pcall(function() return obj[name](obj, a, b, c) end)
end

local function nowSec()
    local ok, ms = pcall(function() return getTimestampMs() end)
    if ok and type(ms) == "number" then return ms / 1000 end
    return 0
end

local function isC172(vehicle)
    if vehicle == nil then return false end
    local cfg = C172Util.getConfig(vehicle)
    return cfg ~= nil and cfg.category == "prop"
end

function C172Recovery.rightAircraft(playerObj, vehicle)
    vehicle = vehicle or (playerObj and playerObj:getVehicle())
    if not isC172(vehicle) then return end

    local id = vehicle:getId()
    local t = nowSec()
    if lastUseAt[id] and (t - lastUseAt[id]) < COOLDOWN_SEC then
        log(("ignored - cooldown (%.1fs remaining)"):format(COOLDOWN_SEC - (t - lastUseAt[id])))
        return
    end
    lastUseAt[id] = t
    log("RIGHT AIRCRAFT selected")

    call1(vehicle, "setSpeedKmHour", 0)
    call0(vehicle, "setForceBrake")

    if C172Flight and C172Flight.forceGroundMode then
        C172Flight.forceGroundMode(vehicle, "RIGHT AIRCRAFT recovery")
    end

    -- Roll and pitch are zeroed; the existing HEADING is deliberately KEPT, so the aircraft
    -- ends up upright but still pointing where the player left it rather than snapping
    -- to an arbitrary compass heading under them.
    --
    -- 1.9.0 (no Java): C172Phys.c172RecoverToGround levels it with BaseVehicle.setAngles,
    -- the heading taken from the airframe's real forward vector (the old getAngleY read is an
    -- Euler angle, which past 90 degrees comes back mirrored), then seats it at vanilla's own
    -- resting height for the storey it is in with BaseVehicle.setDebugZ - exactly where a
    -- freshly spawned one would sit. (Java could also pull a body back from UNDER the map;
    -- setDebugZ can only move it within its storey, so that one case is no longer covered.)
    call1(vehicle, "setPhysicsActive", false)
    local okR, recovered = pcall(C172Phys.c172RecoverToGround, vehicle)
    if not (okR and type(recovered) == "number" and recovered >= 0) then recovered = nil end

    call0(vehicle, "setCurrentSquareFromPosition")
    call1(vehicle, "setPhysicsActive", true)
    call1(vehicle, "setActiveInBullet", true)
    call1(vehicle, "setCollidable", true)

    if recovered then
        log(("levelled (heading kept) and seated at %.2f m - vanilla's resting height"):format(recovered))
    else
        log("level/seat UNAVAILABLE on this build - velocity and flight state were still cleared.")
    end
    log("recovery complete")
end

local function landAircraft(playerObj, vehicle)
    if not (C172Flight and C172Flight.requestLanding) then return end
    C172Flight.requestLanding(vehicle, "Land Aircraft radial option")
end

-- 1.10.4 (Workshop request): during the approach the same slot calls the landing off.
local function abortLanding(playerObj, vehicle)
    if not (C172Flight and C172Flight.abortLanding) then return end
    C172Flight.abortLanding(vehicle, "Abort Landing radial option")
end

-- Vanilla hides the whole "Start Engine" slice when the engine cannot run and gives no
-- reason. This adds a read-only slice naming the actual failing component, which is
-- otherwise invisible to the player.
local ENGINE_FAULT_TEXT = {
    GasTank = "No fuel",
    Engine  = "Engine destroyed",
}

local function engineFaultReasons(vehicle)
    local reasons = {}
    local ok = pcall(function()
        for i = 1, vehicle:getPartCount() do
            local part = vehicle:getPartByIndex(i - 1)
            if part then
                local fn = part:getLuaFunction("checkEngine")
                if fn and not VehicleUtils.callLua(fn, vehicle, part) then
                    local pid = tostring(part:getId())
                    table.insert(reasons, ENGINE_FAULT_TEXT[pid]
                        or ("Required engine component damaged: " .. pid))
                end
            end
        end
    end)
    if not ok then return nil end
    return reasons
end

-- Second line of defence against duplicates. Even with the wrap guard above, another mod
-- could legitimately wrap OUR wrapper and cause it to run twice, so nothing this file adds
-- is ever added to a menu that already contains it. Matching on our own English slice text
-- is safe here precisely because it is OURS - it is never run through getText().
local function menuHasSlice(menu, text)
    local ok, found = pcall(function()
        local slices = menu.slices
        if type(slices) ~= "table" then return false end
        for i = 1, #slices do
            if type(slices[i]) == "table" and slices[i].text == text then return true end
        end
        return false
    end)
    return ok and found
end

local function addEngineDiagnosticSlice(playerObj, vehicle)
    if not isC172(vehicle) then return end
    local okDriver, isDriver = pcall(function() return vehicle:isDriver(playerObj) end)
    if not (okDriver and isDriver) then return end
    local okWorking, working = pcall(function() return vehicle:isEngineWorking() end)
    if not okWorking or working then return end

    local reasons = engineFaultReasons(vehicle)
    local text = (reasons and #reasons > 0)
        and ("Cannot start:\n" .. table.concat(reasons, "\n"))
        or  "Cannot start:\nEngine unavailable"

    local okMenu, menu = pcall(function()
        return getPlayerRadialMenu(playerObj:getPlayerNum())
    end)
    if not okMenu or not menu then return end
    pcall(function()
        if not menuHasSlice(menu, text) then
            menu:addSlice(text, getTexture("media/ui/vehicles/vehicle_ignitionOFF.png"), nil, playerObj)
        end
    end)
end

-- RADIAL DIAGNOSTIC. The "RIGHT AIRCRAFT" slice is unconditional for this aircraft, yet
-- it did not appear in the v0.1.1 test even though the wrapper reported itself installed.
-- Every step between "the wrapper ran" and "the slice exists" is silent on its own - the
-- identity gate, getting the menu object, and the addSlice call are all pcall-wrapped -
-- so this narrates the whole path once per menu open. Turn off with the ground
-- diagnostic; it costs nothing except while diagnosing.
local RADIAL_DIAG = false

-- RADIAL DECLUTTER, CESSNA ONLY.
--
-- The wheel was unreadable because vanilla adds a lot of car-shaped entries that mean
-- nothing on an aeroplane - and up to SIX mutually exclusive "you cannot sleep because..."
-- variants at once, which is most of the clutter on its own.
--
-- Entries are matched by COMMAND FUNCTION IDENTITY and by TEXTURE PATH, never by their
-- visible text: slice text is run through getText() and is localised, so a text match would
-- silently stop working in any language but English.
--
-- This only ever runs for a Cessna, and it only ever REMOVES from the local menu object
-- that vanilla just built for this one interaction. It does not wrap, replace or reorder
-- any vanilla function, so no other vehicle's radial menu can be affected - the exact
-- same menu object is left completely untouched for every car, the VX-9 and the MiG.
local DROP_TEXTURES = {
    ["media/ui/vehicles/vehicle_sleep.png"]         = true,  -- sleeping in a light aircraft
    ["media/ui/vehicles/vehicle_lightbar.png"]      = true,  -- police lightbar
    ["media/ui/vehicles/vehicle_horn.png"]          = true,  -- a Cessna has no car horn
    ["media/ui/vehicles/vehicle_speakersON.png"]    = true,  -- car radio
    ["media/ui/vehicles/vehicle_speakersOFF.png"]   = true,
    ["media/ui/vehicles/vehicle_windowCLOSED.png"]  = true,  -- wind-down car windows
    ["media/ui/vehicles/vehicle_windowOPEN.png"]    = true,
}

-- Substring matches, so slices added by OTHER mods are caught too - their command functions
-- are not ours to reference, but their icons still name what they are. "hood" covers the
-- vanilla hood entry and the hood-action mods' own icons, which is what was asked for until
-- those mods get a pass of their own.
local DROP_TEXTURE_PATTERNS = { "hood", "speaker", "radio", "window" }

local function dropCommands()
    -- Resolved lazily and defensively: if a future build renames or removes one of these,
    -- the entry is simply not filtered rather than the whole menu erroring.
    local t = {}
    if type(ISVehicleMenu) == "table" then
        t[ISVehicleMenu.onLightbar]     = true
        t[ISVehicleMenu.onHorn]         = true
        t[ISVehicleMenu.onHonk]         = true
        t[ISVehicleMenu.onSignalDevice] = true   -- car radio / device options
    end
    if type(ISVehiclePartMenu) == "table" then
        t[ISVehiclePartMenu.onOpenCloseWindow] = true
    end
    t[nil] = nil
    return t
end

-- FILTERING HAPPENS AT ADD TIME, NEVER AFTER THE MENU IS BUILT.
--
-- The previous version rewrote menu.slices after ISVehicleMenu.showRadialMenu had already
-- returned. That is unsafe and it trapped the player in the aircraft:
-- ISRadialMenu:instantiate() builds the JAVA RadialMenu object from the slice list at
-- addToUIManager() time, so the wedges the player SEES come from the Java object while the
-- commands come from the Lua array. Removing entries from the Lua array afterwards left the
-- two misaligned by however many entries were dropped - so clicking the exit wedge fired
-- whatever had shifted into that index instead. "I hit exit vehicle, I can't exit, and I'm
-- activating the hood mod's cabin filter" is exactly that off-by-N.
--
-- Filtering at addSlice() time means unwanted entries never enter EITHER list, so the two
-- can never disagree. The filter is armed only for the duration of a Cessna's own radial
-- build (see the wrapper below), so every other vehicle's menu is completely untouched.
local filterArmed = false

local function sliceIsUnwanted(text, texture, command)
    local drop = dropCommands()
    if command ~= nil and drop[command] then return true end
    if texture ~= nil then
        local okN, nm = pcall(function() return texture:getName() end)
        if okN and type(nm) == "string" then
            if DROP_TEXTURES[nm] then return true end
            local lower = string.lower(nm)
            for _, pat in ipairs(DROP_TEXTURE_PATTERNS) do
                if string.find(lower, pat, 1, true) then return true end
            end
        end
    end
    return false
end

local sliceFilterInstalled = false

local function installSliceFilter()
    if sliceFilterInstalled then return end
    if type(ISRadialMenu) ~= "table" or type(ISRadialMenu.addSlice) ~= "function" then return end
    sliceFilterInstalled = true
    local origAddSlice = ISRadialMenu.addSlice
    ISRadialMenu.addSlice = function(self, text, texture, command, ...)
        -- Inert unless a Cessna radial is being built right now.
        if filterArmed then
            local ok, unwanted = pcall(sliceIsUnwanted, text, texture, command)
            if ok and unwanted then return end
        end
        return origAddSlice(self, text, texture, command, ...)
    end
    log("radial slice filter installed (armed only while building a Cessna's own menu).")
end

local function addRecoverySlice(playerObj, vehicle)
    if not isC172(vehicle) then
        if RADIAL_DIAG then
            local okName, name = pcall(function() return vehicle and vehicle:getScriptName() end)
            log(("radial: NOT this aircraft (scriptName=%s) - no slice, as intended")
                :format(tostring(okName and name)))
        end
        return
    end
    local okMenu, menu = pcall(function()
        return getPlayerRadialMenu(playerObj:getPlayerNum())
    end)
    if not okMenu or not menu then
        if RADIAL_DIAG then log("radial: getPlayerRadialMenu FAILED - cannot add any slice") end
        return
    end
    if RADIAL_DIAG then
        local okCount, count = pcall(function() return menu.slices and #menu.slices end)
        local okVis, vis = pcall(function() return menu:isReallyVisible() end)
        log(("radial: adding slices (existing slices=%s, menuVisible=%s, hasJavaObject=%s)")
            :format(tostring(okCount and count), tostring(okVis and vis),
                    tostring(menu.javaObject ~= nil)))
    end

    local repairTex = getTexture("media/ui/vehicles/vehicle_repair.png")
    local landTex   = getTexture("media/ui/vehicles/c172_land.png")

    if C172Flight and C172Flight.isAirborne and C172Flight.isAirborne(vehicle) then
        pcall(function()
            local st = C172Flight.getState and C172Flight.getState(vehicle)
            if st and st.mode == "LANDING" then
                if not menuHasSlice(menu, "Abort Landing") then
                    menu:addSlice("Abort Landing", landTex, abortLanding, playerObj, vehicle)
                end
            elseif not menuHasSlice(menu, "Land Aircraft") then
                menu:addSlice("Land Aircraft", landTex, landAircraft, playerObj, vehicle)
            end
        end)
    end
    local okAdd, addErr = pcall(function()
        if not menuHasSlice(menu, "RIGHT AIRCRAFT") then
            menu:addSlice("RIGHT AIRCRAFT", repairTex, C172Recovery.rightAircraft, playerObj, vehicle)
        end
    end)
    if RADIAL_DIAG then
        local okCount, count = pcall(function() return menu.slices and #menu.slices end)
        log(("radial: RIGHT AIRCRAFT addSlice ok=%s err=%s -> slices now %s")
            :format(tostring(okAdd), tostring(addErr), tostring(okCount and count)))
    end
end

local installedInside  = nil
local installedOutside = nil

-- Identifies wrappers this file installed. A weak-keyed table so a discarded wrapper can
-- still be collected.
local C172_RADIAL_MARKER = setmetatable({}, { __mode = "k" })

local function patchRadialMenu()
    if type(ISVehicleMenu) ~= "table" then return false end
    -- Idempotent: if OUR wrapper is still the installed one, nothing to do. If something
    -- else has since wrapped it, this re-wraps on top and calls through to that, which is
    -- the correct composition rather than a fight.
    -- DOUBLE-WRAP GUARD. This used to require that BOTH our inside and outside wrappers
    -- were still the installed ones. If any other mod wrapped either global between our
    -- OnGameBoot and OnGameStart calls, that test failed and we wrapped a SECOND time - our
    -- new wrapper then called our old wrapper, and every slice we add was added twice. That
    -- is the reported duplicate "Land Aircraft" and duplicate "Cannot start" entries.
    --
    -- Our wrapper now carries a marker, so we can recognise our own work no matter what
    -- else has happened around it and simply decline to install again.
    if type(ISVehicleMenu.showRadialMenu) == "function"
       and C172_RADIAL_MARKER[ISVehicleMenu.showRadialMenu] then
        return true
    end

    local origInside = ISVehicleMenu.showRadialMenu
    if type(origInside) ~= "function" then return false end

    local wrappedInside
    wrappedInside = function(playerObj)
        if C172IgnitionKey and C172IgnitionKey.ensure then
            pcall(C172IgnitionKey.ensure, playerObj)
        end
        -- Arm the slice filter ONLY while vanilla is building this menu, and only when the
        -- vehicle is ours. pcall-wrapped and disarmed in all paths, so an error inside
        -- vanilla's builder can never leave the filter armed for another vehicle.
        local okVeh, veh = pcall(function() return playerObj:getVehicle() end)
        local ours = okVeh and veh ~= nil and isC172(veh)
        if ours then installSliceFilter(); filterArmed = true end
        local okBuild, buildErr = pcall(origInside, playerObj)
        filterArmed = false
        if not okBuild then
            log("WARNING: vanilla radial build failed: " .. tostring(buildErr))
        end

        if okVeh and veh then
            addRecoverySlice(playerObj, veh)
            addEngineDiagnosticSlice(playerObj, veh)
        end
    end
    C172_RADIAL_MARKER[wrappedInside] = true
    ISVehicleMenu.showRadialMenu = wrappedInside
    installedInside = wrappedInside

    local origOutside = ISVehicleMenu.showRadialMenuOutside
    if type(origOutside) == "function" then
        local wrappedOutside = function(playerObj)
            origOutside(playerObj)
            local ok, veh = pcall(function() return playerObj:getNearVehicle() end)
            if ok and veh then addRecoverySlice(playerObj, veh) end
        end
        ISVehicleMenu.showRadialMenuOutside = wrappedOutside
        installedOutside = wrappedOutside
    end

    log("radial menu wrappers installed.")
    return true
end

-- ISVehicleMenu may not exist yet at file load - see the memory note that ISUI globals
-- are nil at require time. Patch late, on the boot/start events, and call through.
if not patchRadialMenu() then
    Events.OnGameBoot.Add(patchRadialMenu)
end
Events.OnGameStart.Add(patchRadialMenu)

-- ---------------------------------------------------------------- [ hotkey
-- Same key the MiG mod uses. Both handlers fire, and each one checks the vehicle's own
-- script name first, so exactly one of them ever acts - and neither acts at all unless
-- the player is actually in or beside the matching aircraft. Typing is guarded, so [ in
-- chat does nothing.
local RECOVER_KEY = Keyboard.KEY_LBRACKET

local function textEntryHasFocus()
    local ok, focused = pcall(function()
        local chat = ISChat and ISChat.instance
        local entry = chat and chat.textEntry
        if entry and entry.isFocused and entry:isFocused() then return true end
        return false
    end)
    return ok and focused == true
end

Events.OnKeyStartPressed.Add(function(key)
    if key ~= RECOVER_KEY then return end
    if textEntryHasFocus() then return end
    local player = getSpecificPlayer(0)
    if not player then return end
    local vehicle = player:getVehicle()
    if not vehicle then
        local ok, near = pcall(function() return player:getNearVehicle() end)
        if ok then vehicle = near end
    end
    if isC172(vehicle) then
        C172Recovery.rightAircraft(player, vehicle)
    end
end)

return C172Recovery
