--[[
    C172BuildStamp - prints, at game start, WHICH physical copy of this mod actually
    loaded and what version it is.

    WHY THIS EXISTS. A mod that is being developed locally and also staged for Workshop
    upload ends up with more than one copy on disk carrying the SAME id and the SAME
    display name, and PZ will happily load whichever it finds first. An entire test round
    has previously been run against a stale copy of a sibling mod, with edits going to one
    directory while the game loaded another - and "the mod works" is not evidence the
    edited build loaded, because the old build works too. This line makes the loaded path
    unambiguous, so a test result can be trusted.

    Also a reminder of the second half of that same confusion: LUA IS READ AT STARTUP.
    Project Zomboid must be fully restarted after any edit - reloading a save is not
    enough.
]]
Events.OnGameStart.Add(function()
    local ok, info = pcall(function() return getModInfoByID("EmreAdventureVehiclePack_B42") end)
    local dir = (ok and info) and info:getDir() or "unknown"
    local ver = "unknown"
    if ok and info then
        local okV, v = pcall(function() return info:getModVersion() end)
        if okV and v then ver = tostring(v) end
    end
    print(("[Cessna172 BUILD] v%s  loaded from: %s"):format(ver, tostring(dir)))
    -- 1.9.0: no Java. The flight physics is this mod's own Lua (C172Phys).
    local okB, avail = pcall(function() return C172Phys and C172Phys.c172PhysicsAvailable() end)
    print("[Cessna172 BUILD] Lua flight physics (no Java, no ZombieBuddy needed) ready = " ..
          tostring(okB and avail == true))
end)
