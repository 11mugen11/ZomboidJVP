--[[
    C172NavDisplay - the moving map embedded in the Cessna's panel.

    WHY IT IS BUILT THIS WAY. The obvious approach - add a whole ISMiniMapOuter to the UI
    manager as its own top-level window and position it next to the HUD - was tried in
    the MiG mod and produced two problems that are vanilla ISMiniMapOuter behaviour and
    are NOT avoidable while using that class:
      * ISMiniMapOuter:prerender() calls self:setPosition() EVERY frame, which re-clamps
        the window to the player's screen rect and moves it out from under any docking
        applied to it.
      * The same prerender() calls setAdornmentsVisible(true) whenever the mouse is over
        it, which un-hides a title bar and a row of M / - / + / settings / X buttons AND
        changes the window's own Y and height while doing so.
    The result reads as a stray floating vanilla window with buttons, sitting near the
    instrument panel rather than being part of it.

    THE FIX: skip ISMiniMapOuter entirely and embed ISMiniMapInner - the class that
    actually renders the map and owns the UIWorldMap and its mapAPI - directly as a CHILD
    of this mod's own panel. ISMiniMapOuter itself does exactly this internally
    (`self.inner = ISMiniMapInner:new(...)` then `self:addChild(self.inner)`), so this is
    the same parenting vanilla already relies on, just with the instrument panel as the
    parent. The inner has no title bar, no button row and no setPosition() of its own, so
    none of the above can happen: it renders inside the panel's rect, clipped to the
    child's bounds, and moves with it.

    Mouse handlers are stubbed to return false so the map cannot swallow clicks meant for
    the panel behind it, or be dragged/zoomed out of place.

    This is an independent implementation. It reads nothing from, and changes nothing
    about, the MiG's or the Wraith's own nav displays.
]]

require "ISUI/Maps/ISMiniMap"

C172NavDisplay = C172NavDisplay or {}

local inner       = nil     -- ISMiniMapInner instance, parented to the HUD panel
local buildFailed = false

local function log(msg) print("[Cessna172][NAV] " .. msg) end

function C172NavDisplay.attach(parentPanel, x, y, size)
    if buildFailed or not parentPanel then return inner end
    if inner then
        inner:setX(x); inner:setY(y)
        if inner:getWidth()  ~= size then inner:setWidth(size)  end
        if inner:getHeight() ~= size then inner:setHeight(size) end
        return inner
    end

    -- Building the map data is EXPENSIVE (it walks every lot directory), so it happens
    -- exactly once, lazily, on the first frame the panel is actually shown - never at
    -- load and never for a player who does not fly.
    local ok, err = pcall(function()
        inner = ISMiniMapInner:new(x, y, size, size, 0)
        parentPanel:addChild(inner)   -- instantiates it (creates the UIWorldMap)

        local API  = inner.mapAPI
        local dirs = getLotDirectories()
        for i = 1, dirs:size() do
            local file = "media/maps/" .. dirs:get(i - 1) .. "/worldmap.xml"
            if fileExists(file) then API:addData(file) end
            API:endDirectoryData()
            API:addImages("media/maps/" .. dirs:get(i - 1))
        end
        API:setBoundsFromWorld()
        API:setZoom(19)
        API:setBoolean("HideUnvisited", true)
        API:setBoolean("Players", true)
        if isClient() then
            API:setBoolean("RemotePlayers", true)
            -- PLAYER NAMES OFF, DELIBERATELY. The map renderer sizes a player name against the
            -- map's own scale, and this panel is pinned at setZoom(19) so that a useful amount
            -- of ground fits in a small cockpit instrument. At that scale the name is drawn
            -- enormous - it covered the display in the first MP test - and there is no
            -- name-scale knob on the map API to turn it down (WorldMapRenderer exposes only
            -- setBoolean/setDouble/getWorldScale; nothing addresses the label size).
            -- RemotePlayers stays ON, so other aircraft and players still show as markers,
            -- which is the part that actually matters in the air.
            API:setBoolean("PlayerNames", false)
        end
        API:setBoolean("Symbols", false)
        API:setBoolean("MiniMapSymbols", true)
        API:setBoolean("ImagePyramid", false)
        MapUtils.initDefaultStyleV1(inner)

        inner.onMouseDown        = function() return false end
        inner.onMouseUp          = function() return false end
        inner.onMouseMove        = function() end
        inner.onMouseMoveOutside = function() end
        inner.onRightMouseDown   = function() return false end
        inner.onRightMouseUp     = function() return false end
        inner.onMouseWheel       = function() return false end
    end)

    if not ok then
        -- One failure disables it permanently for the session rather than retrying every
        -- frame. The panel draws a "NAV OFFLINE" placeholder in its place; the aircraft
        -- is entirely flyable without it.
        buildFailed = true
        if inner then pcall(function() inner:removeFromUIManager() end) end
        inner = nil
        log("navigation display unavailable: " .. tostring(err))
        return nil
    end

    log("navigation display built and embedded in the panel (" .. tostring(size) .. "px).")
    return inner
end

function C172NavDisplay.update()
    if not inner then return end
    pcall(function() inner:prerenderHack() end)
end

function C172NavDisplay.setVisible(visible)
    if not inner then return end
    pcall(function() inner:setVisible(visible) end)
end

-- Torn down across save reloads: the UIWorldMap is bound to the loaded world, so a stale
-- one carried into a new session renders nothing useful and leaks a javaObject.
Events.OnGameStart.Add(function()
    if inner then
        pcall(function() inner:removeFromUIManager() end)
        pcall(function() inner:detachFromParent() end)
    end
    inner = nil
    buildFailed = false
end)

return C172NavDisplay
