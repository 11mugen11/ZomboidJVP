--[[
    C172Presentation - drawing the aircraft right while it flies, without Java (1.9.0).

    Replaces Patch_PinLogicalLevel, Patch_AirborneLighting, Patch_AirborneAmbient,
    Patch_RoofVisibility and Patch_AirborneOnScreen. Same method as the MH-92 Nightfang's.

    WHY IT GOES BLACK OVER BUILDINGS (42.21 source). A vehicle model's light is not the
    colour passed to render(): ModelSlotRenderData.initModel takes its ambient from
    vehicle.getCurrentSquare() every frame. An aircraft high over a building is put on a
    storey of that building by the engine, so its "current square" is a dark room INSIDE it -
    and the whole airframe is lit like that room. The pilot has the same problem: what a
    player can SEE is worked out from their logical square, and from inside that room the
    walls hide the outside (the black fog over rooftops in the 09-26 recording).

    THE FIX. OnTick fires after the world has updated and before it is drawn. There, for the
    aircraft this player is flying:
      * its current square is pointed at an OUTDOOR square - the roof (or open air) at the
        surface level under it, else the nearest outdoor ground - so it is lit by the sky;
      * its own logical level is set to 0 while it is drawn (2026-10-05; it used to be the
        roof's level, so the shadow landed on the roof - now it is under the roof, out of sight).
        The model is placed from level and physics height together, so it does not move, and
        every moving object is drawn in one pass after all the tile levels (FBORenderCell
        .renderMovingObjects), so the level only picks the shadow's floor. WHY: the seated pilot
        is drawn from the aircraft's level PLUS its whole physics height, so on the roof's level
        the pilot view had to re-seat him against it every tick while banking over a tall
        building, and each re-seat of the local player makes the game rebuild what he can see
        for ~40 frames (setCharacterPosition -> dirtyRecalcGridStackTime) - the "glitchy or
        laggy over buildings" Jay saw on the AH-1, which has the same pin;
      * the pilot gets the same level and square, so the roof is seen from above.
    Everything is handed back at the very start of the next frame (OnTickEvenPaused), BEFORE
    the world updates - nothing in the game's own update ever sees the borrowed values.
    (42.21 GameWindow.frameStep: logic [OnTickEvenPaused, world update, OnTick] -> render
    [OnPostRender] -> LightingThread [what each player can see].)

    STILL DRAWN AT HEIGHT. The engine draws a vehicle only when its GROUND footprint is on
    screen; zoomed in near the ceiling it is not. Then, and only then, the engine's own draw
    call is repeated after the world is drawn (BaseVehicle.render is public).

    MULTIPLAYER TOO (1.10.3; it was single player only). Jay, 10-08, co-op: "name doesnt stay above
    player when flying in mp also very glitchy / disappears when zoomed in", "still a bit glitchy
    zoomed out", and earlier "dimming issue when going over stuff". The worry that kept this out of
    multiplayer was the borrowed level reaching the server. Read from the 42.21 jar (10-08), it
    cannot: the player's position goes out from IsoPlayer.update -> updateInternal1 ->
    GameClient.sendPlayer2 -> PlayerPacket.set(player), and the aircraft's from BaseVehicle.update ->
    updatePhysicsNetwork - both inside IsoWorld.update, which runs after OnTickEvenPaused has handed
    everything back. What runs while it is borrowed (GameClient.update at the very start of the
    frame, before OnTickEvenPaused: incoming packets, request lists, voice) sends no position of
    either. Still never on a server (isServer()), and only the aircraft THIS client flies is pinned.
    The extra draw below (render only) now covers other players' Cessnas in the air as well
    (C172Phys.eachRemoteFlying, from the flight updates the server relays).

    NAME TAGS (multiplayer only - the game draws none in single player). The engine draws an
    occupant's name from BaseVehicle.getNameCoordForPlayer, which projects the VEHICLE's x, y and
    logical level (rebuildNameCoordCache -> IsoGameCharacter.getNameCoords(getX(), getY(), getZ(), ...))
    - its floor, not its height: on the ground under the aircraft, jumping a storey over every
    building, off screen when zoomed in. That position is cached ONCE per frame (nameCoordFrame vs
    IsoCamera.frameState.frameCount, which GameWindow.frameStep advances BEFORE the frame's logic)
    and the method is public.
    1.10.3 (first try) built that cache in OnTick at the aircraft's real height. Jay, co-op: "name tag
    staying but very glitchy". The tag's position includes PlayerCamera.fixJigglyModels - where the 3D
    models land against the 2D camera - and Core.StartFrame works that out for each frame only when
    the frame starts drawing, AFTER OnTick: the cache carried the last frame's, and at flying speed it
    changes every frame, so the name shook round the aircraft. Lua cannot reach the camera to work it
    out sooner (PlayerCamera is not exposed).
    So now the cache is built in OnTick with the level far ABOVE the screen (the engine's own tag is
    drawn out of sight for that frame), and the tag is drawn from here after the world is drawn
    (OnPostRender), when this frame's camera is final: IsoGameCharacter.getNameCoords - the engine's
    own projection, public and static, offsets included - at the aircraft's height, the occupants laid
    out as BaseVehicle.layoutPassengerNameCoords lays them out, each name through the engine's own
    text batch (TextDrawObject.AddBatchedDraw, drawn in IngameState.renderframetext after
    OnPostRender), shown only when the engine's own rules would show it (updateUserName / renderlast:
    the "show your username" option, the server's DisplayUserName / ShowFirstAndLastName /
    MouseOverToSeeDisplayName, invisible players, what the viewer can see) and with the faction tag.
    Not while a 3D camera mod draws the world (a 2D name lands flat on its view): the engine's own
    tag then stays as it is.
    Any error switches this off for the session; the aircraft still flies.
]]

require "Cessna172/C172Phys"

local P = C172Phys
local V = {}
C172Presentation = V

local Z_M = 2.44949
local floor, abs = math.floor, math.abs

V.pinLevels = {}      -- vehicle id -> the surface level the flight controller asked to draw on
V.pins = {}           -- vehicle id -> what was borrowed this frame
V.sky = {}            -- vehicle id -> { key, square } (the outdoor-square search is cached)

local function log(msg) print("[Cessna172] " .. msg) end

local function sameVehicle(a, b)
    if a == nil or b == nil then return false end
    local okA, ia = pcall(function() return a:getId() end)
    local okB, ib = pcall(function() return b:getId() end)
    return okA and okB and ia == ib
end

-- PORT OF c172SetPinLevel: the flight controller names the roof it is over.
function P.c172SetPinLevel(v, level)
    local ok, id = pcall(function() return v:getId() end)
    if ok and id then V.pinLevels[id] = level end
end
-- Java eased the airframe's light itself; here the outdoor square does it. Kept as a no-op.
function P.c172UpdateAirborneLight() return true end

-- An outdoor square to light the aircraft by: the surface it is over and the levels just
-- above (open air over a flat roof), then the ground straight below, then the nearest
-- outdoor ground square. The Java build's outdoorSquareNear, square for square.
local function skySquare(cell, x, y, level, top)
    local last = math.min(level + 3, top + 1)
    for z = level, last do
        local sq = cell:getGridSquare(x, y, z)
        if sq and sq:isOutside() then return sq end
    end
    local g = cell:getGridSquare(x, y, 0)
    if g and g:isOutside() then return g end
    for r = 1, 6 do
        for dx = -r, r do
            for dy = -r, r do
                if abs(dx) == r or abs(dy) == r then
                    local q = cell:getGridSquare(x + dx, y + dy, 0)
                    if q and q:isOutside() then return q end
                end
            end
        end
    end
    return nil
end
V._skySquare = skySquare

local function pinOne(id, v, cell, player)
    local level = V.pinLevels[id] or 0
    local x, y = floor(v:getX()), floor(v:getY())
    local h = P.c172GetBodyHeight(v) or 0
    local top = floor(h / Z_M)
    local key = x * 1000003 + y * 64 + level
    local c = V.sky[id]
    if not c then c = {}; V.sky[id] = c end
    if c.key ~= key then
        c.key = key
        c.square = skySquare(cell, x, y, level, top)
    end
    local sq = c.square
    local engineZ, engineSq = v:getZ(), v:getCurrentSquare()
    local moveSq = sq ~= nil and sq ~= engineSq
    local moveZ = floor(engineZ) ~= 0       -- drawn on level 0 (see the top)
    if not (moveSq or moveZ) then return end
    local pin = { vehicle = v, z = engineZ, sq = engineSq }
    V.pins[id] = pin
    if moveZ then v:setZ(0) end
    if moveSq then v:setCurrent(sq) end
    if player and sq and sameVehicle(player:getVehicle(), v) then
        pin.player, pin.pz, pin.psq = player, player:getZ(), player:getCurrentSquare()
        player:setZ(level)
        player:setCurrent(sq)
    end
end

local function pin()
    if isServer() then return end
    local cell = getCell()
    if not cell then return end
    local player = getSpecificPlayer(0)
    for id, v in pairs(P.flying) do
        if not V.pins[id] and not v:isRemovedFromWorld() then pinOne(id, v, cell, player) end
    end
end

-- Give every aircraft back the level and square the engine gave it. While the game is
-- paused the world does not update and nothing is re-pinned, so the borrowed ones stay and
-- the paused frame still looks right.
function V.unpin()
    if isGamePaused() then return end
    for id, p in pairs(V.pins) do
        V.pins[id] = nil
        if not p.vehicle:isRemovedFromWorld() then
            p.vehicle:setZ(p.z)
            p.vehicle:setCurrent(p.sq)
        end
        if p.player then
            p.player:setZ(p.pz)
            p.player:setCurrent(p.psq)
        end
    end
end

-- The square the ENGINE gave this vehicle, whether or not it is borrowed for drawing now.
-- UI code that asks "is the vehicle still on its square?" must ask this, not getSquare().
function V.engineSquare(v)
    local ok, id = pcall(function() return v:getId() end)
    local p = ok and V.pins[id] or nil
    if p then return p.sq end
    return v:getSquare()
end

function V.pin()
    if V.disabled then return end
    local ok, err = pcall(pin)
    if not ok then
        V.disabled = true
        log("RENDER ERROR, roof lighting switched off: " .. tostring(err))
        pcall(V.unpin)
    end
end

function V.safeUnpin()
    local ok, err = pcall(V.unpin)
    if not ok then
        V.disabled = true
        log("RENDER ERROR, roof lighting switched off: " .. tostring(err))
    end
end

-- ---- name tags at the aircraft's height (multiplayer) ----
-- Body origin height over its surface when it rests on its wheels (C172Flight's gear datum, 1.53 m
-- measured): the tag of a parked Cessna is where the engine puts it, one in the air rises with it.
V.TAG_DATUM_M = 1.53
V.TAG_HIDE_LEVELS = 1000      -- where the engine's own tag goes for the frame: far above the screen
V.tagged = {}                 -- the aircraft whose names this frame are drawn from here
local hideVec, tagVec = nil, nil
local tdos = setmetatable({}, { __mode = "k" })   -- player -> { tdo =, text = } (our name text)

local function firstOccupant(v)
    for seat = 0, v:getMaxPassengers() - 1 do
        local c = v:getCharacter(seat)
        if c then return c end
    end
    return nil
end

-- The level the name is projected from: the aircraft's height off its wheels, or nil when that is
-- not above the level the engine already uses (on the ground its own tag is right).
local function tagLevel(v)
    local h = P.c172GetBodyHeight(v)
    if not h then return nil end
    local tagZ = (h - V.TAG_DATUM_M) / Z_M
    if tagZ <= v:getZ() then return nil end
    return tagZ
end
V._tagLevel = tagLevel

-- OnTick: the engine's own tag for this frame, sent out of sight.
local function hideOne(v, zoom)
    local c = firstOccupant(v)
    if not c or not tagLevel(v) then return end
    if not hideVec then hideVec = Vector2.new() end
    local z = v:getZ()
    v:setZ(V.TAG_HIDE_LEVELS)
    local ok, err = pcall(function() return v:getNameCoordForPlayer(c, zoom, hideVec) end)
    v:setZ(z)
    if not ok then error(err) end
    V.tagged[#V.tagged + 1] = v
end
V._hideOne = hideOne

local function tags()
    for i = #V.tagged, 1, -1 do V.tagged[i] = nil end
    if not isClient() then return end
    if V._cameraModDraws and V._cameraModDraws() then return end
    local zoom = getCore():getZoom(0)
    for _, v in pairs(P.flying) do
        if not v:isRemovedFromWorld() then hideOne(v, zoom) end
    end
    P.eachRemoteFlying(function(_, v) hideOne(v, zoom) end)
end

-- After the pin (registered after it), before the frame is drawn.
function V.tags()
    if V.tagsOff then return end
    local ok, err = pcall(tags)
    if not ok then
        V.tagsOff = true
        for i = #V.tagged, 1, -1 do V.tagged[i] = nil end
        log("name tags at height switched off: " .. tostring(err))
    end
end

-- The name the engine would show over `who` (an IsoPlayer) for the viewer `me` (IsoGameCharacter.updateUserName and
-- renderlast, 42.21), or nil when it would show none.
local function nameText(who, me, index, canSeeAll)
    if not instanceof(who, "IsoPlayer") then return nil end
    local isSelf = who:isLocalPlayer()
    if not isSelf and who:isInvisible() and not canSeeAll then return nil end
    local opts = getServerOptions()
    if not (opts:getBoolean("DisplayUserName") or opts:getBoolean("ShowFirstAndLastName") or canSeeAll) then return nil end
    if isSelf and not getCore():isShowYourUsername() then return nil end
    if not isSelf and not canSeeAll then
        if opts:getBoolean("MouseOverToSeeDisplayName") then return nil end      -- the engine shows those on mouse-over only
        local sq = who:getCurrentSquare()
        if not (sq and sq:getCanSee(index)) then return nil end
    end
    local name = who:getDisplayName() or ""
    local f = Faction.getPlayerFaction(who)
    if f and (who:isShowTag() or isSelf or Faction.getPlayerFaction(me) == f) then
        local tag = f:getTag()
        local col = f:getTagColor() or who:getTagColor()
        if tag and tag ~= "" and col then
            name = string.format("[col=%d,%d,%d][%s][/] %s", math.floor(col:getR() * 255), math.floor(col:getG() * 255),
                math.floor(col:getB() * 255), tag, name)
        end
    end
    return name
end
V._nameText = nameText

-- Our text object for this player, holding `text` (rebuilt only when it changes).
local function textFor(c, text)
    local rec = tdos[c]
    if not rec then
        rec = { tdo = TextDrawObject.new(255, 255, 255, true, true, true, true, true, true), text = nil }
        tdos[c] = rec
    end
    if rec.text ~= text then
        rec.tdo:ReadString(UIFont.Small, text, -1)
        rec.text = text
    end
    return rec.tdo
end

-- OnPostRender: this aircraft's names, where the engine would put them at its height, this frame.
local function drawNames(v, me, index, canSeeAll, zoom, rise)
    local tagZ = tagLevel(v)
    if not tagZ then return end
    if not tagVec then tagVec = Vector2.new() end
    IsoGameCharacter.getNameCoords(v:getX(), v:getY(), tagZ, 0, rise, zoom, tagVec)
    local x, y, total = tagVec:getX(), tagVec:getY(), 0
    local rows = {}
    -- BaseVehicle.layoutPassengerNameCoords: seats in pairs, side by side; a row as tall as its
    -- taller name; then the whole block centred (centerPassengerNameCoords: + total / 2)
    local n = v:getMaxPassengers()
    for seat = 0, n - 1, 2 do
        local a = v:getCharacter(seat)
        local b = seat + 1 < n and v:getCharacter(seat + 1) or nil
        if a or b then
            local row, h = {}, 0
            for k, c in ipairs({ a or false, b or false }) do
                if c then
                    local text = nameText(c, me, index, canSeeAll)
                    local tdo = textFor(c, text or "")
                    h = math.max(h, tdo:getHeight())
                    if text then
                        -- the seat beside it (not "(k == 1) and b or a": a nil b would give a)
                        local other
                        if k == 1 then other = b else other = a end
                        local dx, align = 0, "center"
                        if other then
                            if k == 1 then dx, align = -4, "right" else dx, align = 4, "left" end
                        end
                        row[#row + 1] = { tdo = tdo, x = x + dx, y = y, align = align }
                    end
                end
            end
            rows[#rows + 1] = row
            y = y + h
            total = total + h
        end
    end
    local shift = total / 2
    for _, row in ipairs(rows) do
        for _, e in ipairs(row) do
            e.tdo:setHorizontalAlign(e.align)
            e.tdo:AddBatchedDraw(e.x, e.y + shift - e.tdo:getHeight(), true)
        end
    end
end
V._drawNames = drawNames

local function drawTags()
    if #V.tagged == 0 or not isClient() then return end
    local me = getSpecificPlayer(0)
    if not me then return end
    local index = me:getPlayerNum()
    local canSeeAll = me:canSeeAll()
    local zoom = getCore():getZoom(index)
    local rise = math.floor(160 / math.floor(2 / Core.getTileScale()))   -- the engine's 160 / (2 / tileScale), in ints
    for _, v in ipairs(V.tagged) do
        if not v:isRemovedFromWorld() then drawNames(v, me, index, canSeeAll, zoom, rise) end
    end
end

function V.drawTags()
    if V.tagsOff then return end
    local ok, err = pcall(drawTags)
    if not ok then
        V.tagsOff = true
        log("name tags at height switched off: " .. tostring(err))
    end
end

-- ---- the extra draw, for when the engine skips it ----
local function draw(v, player, index)
    if v:isRemovedFromWorld() then return end
    local mine = sameVehicle(player:getVehicle(), v)
    local home = v:getSquare()
    local lit = v:getCurrentSquare() or home
    if not lit then return end
    -- Someone else's view of it: the engine's own rule is "only if its square has been seen", and it
    -- reads that square without checking it exists.
    local seen = mine or (home ~= nil and home:isCouldSee(index))
    -- The aircraft, unless the engine drew it this frame (BaseVehicle.isOnScreen: its whole footprint).
    if not v:isOnScreen() and seen then
        v:setAlpha(index, 1)
        v:setTargetAlpha(index, 1)
        v:render(v:getX(), v:getY(), v:getZ(), lit:getLightInfo(index), true, false, nil)
    end
    -- (10-07: checked whether or not the aircraft itself was drawn - Jay, "mig and blackhawk still have
    -- character disappearing". A vehicle counts as on screen when any of its footprint is, a seated character
    -- only when his own square is; on the big airframes the engine drew the aircraft and skipped the pilot.)
    -- The crew. The engine skips a seated character whose own square is off screen exactly as it skips
    -- the aircraft (zoomed in at height, the ground under it is), and BaseVehicle.render draws no
    -- passengers - so this brought back the aircraft alone. Jay 10-06: "only zoomed out, when i zoom in
    -- player disappears". IsoGameCharacter.render is public too: each occupant the engine did not draw
    -- this frame is drawn here, in his seat as the engine would. Its own off switch, so a failure here
    -- never takes the aircraft's extra draw with it. Every seat (10-06 later): the back seat shows since
    -- 1.10.0 too, and render() checks each seat's showPassenger itself.
    -- (1.10.3: another player's aircraft too, once its square has been seen - multiplayer.)
    if seen and not V.crewDrawOff then
        for seat = 0, v:getMaxPassengers() - 1 do
            local c = v:getCharacter(seat)
            if c and not c:isOnScreen() then
                local ok, err = pcall(function()
                    c:render(c:getX(), c:getY(), c:getZ(), lit:getLightInfo(index), true, false, nil)
                end)
                if not ok then
                    V.crewDrawOff = true
                    log("crew extra draw switched off: " .. tostring(err))
                end
            end
        end
    end
end

-- A 3D camera mod draws the world instead of the game (10-07, a Project Viewpoint player's video of the MiG-29,
-- which had this same draw: a flat 2D aircraft on top of Viewpoint's cockpit view, and "stuck in the vanilla
-- view mode"). A draw from here lands flat over its 3D view, so there is none while PZ3D's camera is on
-- (PZ3D.cameraMode() ~= 0) or Project Viewpoint is loaded (its Lua table can't say whether its view is on) -
-- the helicopters' rule. Neither mod is required or written to.
local function cameraModDraws()
    local pz = PZ3D
    if pz ~= nil and pz.cameraMode ~= nil then
        local ok, m = pcall(pz.cameraMode)
        if ok and type(m) == "number" and m ~= 0 then return true end
    end
    local vp = Viewpoint
    return vp ~= nil and vp.Mouse ~= nil
end
V._cameraModDraws = cameraModDraws

local function frame()
    if isServer() then return end
    if cameraModDraws() then return end
    local player = getSpecificPlayer(0)
    if not player then return end
    local index = player:getPlayerNum()
    for _, v in pairs(P.flying) do draw(v, player, index) end
    P.eachRemoteFlying(function(_, v) draw(v, player, index) end)
end

function V.frame()
    if V.drawOff then return end
    local ok, err = pcall(frame)
    if not ok then
        V.drawOff = true
        log("RENDER ERROR, extra drawing switched off: " .. tostring(err))
    end
end

-- A vehicle that stopped flying is let go of on the next unpin; forget its caches too.
function V.release(v)
    local ok, id = pcall(function() return v:getId() end)
    if ok and id then V.pinLevels[id], V.sky[id] = nil, nil end
end

Events.OnGameStart.Add(function()
    V.pins, V.pinLevels, V.sky = {}, {}, {}
    V.disabled, V.drawOff, V.crewDrawOff, V.tagsOff = false, false, false, false
end)
-- Start of the frame, before the world updates: hand everything back.
Events.OnTickEvenPaused.Add(V.safeUnpin)
-- After the world update, before it is drawn: borrow for this frame's drawing. (Registered
-- from this file, which loads after C172Flight - so the flight tick has already run.)
Events.OnTick.Add(V.pin)
-- Then the name tags, on this frame's pinned values.
Events.OnTick.Add(V.tags)
-- Once per drawn frame, straight after the world is drawn.
Events.OnPostRender.Add(V.frame)
-- And the names, on this frame's camera (drawn in the text pass right after).
Events.OnPostRender.Add(V.drawTags)

return V
