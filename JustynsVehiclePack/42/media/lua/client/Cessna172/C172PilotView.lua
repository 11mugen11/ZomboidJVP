require "Cessna172/C172Variants"
--[[
    C172PilotView - the people you can see through the Cessna's windows (1.10.0).

    Jay: "i can see myself in mig now can you do the same for cessna currently cant see myself".
    The MiG-29's JetPilotView (seen working in Jay's game), for two seats. The windows are now
    glass (tools/build_glass.py + the Cessna172_vehicle shader) and the two seats the cabin really
    has say showPassenger = true. The mesh is a TANDEM two-seater: seat 0 (the pilot) is drawn on
    the front seat, seat 1 (the right door) on the rear seat; seats 2 and 3 are not drawn.

    Two things in how B42 draws a seated character would still hide them, and this file deals with
    both, every tick, for every Cessna with someone in a shown seat:

    1. DRAW ROOT. A seated character is drawn from his seat's offset (the "root") and depth-sorted
       from that root at the floor of the aircraft's level, while the aircraft is sorted from its
       own body. So the vehicle script puts BOTH shown seats' "inside" root at one point on the
       centre line at ground level, and each seat's pose clip (C172_PilotFront / C172_PilotRear,
       tools/build_pilot_pose.py) carries its body from there onto its own seat - asked for through
       the character variable C172Pose = Front / Rear, which is set again when he changes seat.
       Vanilla's own clips for every other state (aim, eat, read...) know nothing of that, so while
       one runs that seat's root moves to the script's "vanillastates" position, which puts their
       pelvis on the same seat. While getting in, the engine's own "outside" root is left alone.
       Over a building the engine puts the aircraft on that building's storey, and it draws a
       seated character a whole storey higher per level while the aircraft is not moved: the root
       is then lowered by the same amount, in the aircraft's own frame, so he stays in his seat.
       The root is per aircraft (Passenger.offset, set through setCharacterPosition) and drawing
       is all it changes: a character's level comes from the aircraft, not the seat.
    2. DEPTH IN THE AIR. That root is right only while the aircraft sits on the ground. In the air
       it is sorted at its true height and its occupants at their own level, and they would sort
       behind their own cabin. The aircraft's shader moves every model of it (body and propeller)
       in depth to agree with them - by P, worked out here from the same equations the engine uses
       (see PV.depthPush) and sent through the aircraft's paint colour: saturation exactly 0.321
       marks it, hue = 0.5 + P / 40. The skin's alpha is 1 outside the glass, so paint tints nothing.
       Both shown seats share ONE root, so one P fits both occupants; it is worked out for the local
       player's seat when he is aboard. On the ground P is ~0 and the aircraft sorts exactly as
       before; with nobody in a shown seat there is no push at all.

    Client only, drawing only: nothing is sent to the server or to other players, and every client
    works this out for every Cessna it can see. Registered from OnGameStart, so it runs after
    C172Presentation's OnTick (which sets the level the aircraft is drawn on).
    Any error switches it off for the session; the aircraft still flies and draws as before.

    3. THE SEAT WINDOW. Vanilla's seat window (ISVehicleSeatUI - "Switch Seat" inside, "Enter
       Vehicle" outside) draws every seat's icon at its script "inside" offset and picks the seat
       under the mouse from the same numbers. With the two shown seats sharing one root, their
       icons were drawn on top of each other and the pilot's seat could not be clicked. While that
       window draws a Cessna, those two offsets read as the script's "seatui" places instead and
       are put straight back afterwards (see seatWindow below).
]]

require "Cessna172/C172Phys"

C172PilotView = C172PilotView or {}
local PV = C172PilotView

local Z = 2.44949          -- physics units per level (and per unit of getWorldPos's z)
local K = 1.22474          -- depth of one tile of x or y, in physics height units: (CHUNK_DEPTH / 16) / (LEVEL_DEPTH / Z)
local BIAS = 0.0848        -- the engine draws characters 0.0001 of depth nearer: 0.0001 / 0.0011786
local SIGNAL_SAT, SIGNAL_VAL = 0.321, 0.5
local P_MAX = 19.9         -- hue = 0.5 + P / 40 stays inside 0..1
local POSE_VAR = "C172Pose"
local POSES = { [0] = "Front", [1] = "Rear" }    -- shown seat -> the clip that seats him
local SHOWN = { 0, 1 }
local OWN_STATES = { idle = true, exit = true }
local SCAN_SEC, SCAN_RADIUS = 0.5, 60            -- 60: the radius C172PropSpin and C172Contacts scan, so the cache is shared
local EXIT_LIMIT_MS = 3000
PV.Z, PV.K, PV.BIAS, PV.POSES = Z, K, BIAS, POSES

local floor, abs = math.floor, math.abs

local function log(msg) print("[Cessna172] " .. msg) end

local A, B, LP
local function vecs()
    if not A then A, B, LP = Vector3f.new(), Vector3f.new(), Vector3f.new() end
end

local marked = setmetatable({}, { __mode = "k" })     -- character -> the pose he was asked for
local placed = {}                                      -- vehicle id -> seat -> { char =, root =, wx =, wy =, wz = }
local sent = {}                                        -- vehicle id -> last P sent through the paint
local exitSince = setmetatable({}, { __mode = "k" })
local near = { list = {}, at = -1 }
local was = { v = nil, id = nil }                      -- the Cessna this player sat in last tick
PV._placed, PV._sent, PV._marked = placed, sent, marked

local function isCessna(v)
    return v ~= nil and C172Variants.isVehicle(v)
end

-- Model.CharacterModelCameraBegin draws a seated character from (x, y, getZ) + comY, where comY
-- is the aircraft's FULL physics height - so on a building's storey (getZ = L) he is drawn L
-- storeys higher than the aircraft, which is drawn from its height alone. This is the drawn-frame
-- vector that takes him back down: L * Z straight down, expressed along the aircraft's own axes.
local function levelShift(v, L)
    vecs()
    v:getWorldPos(0, 0, 0, A)
    local base = A:z()
    v:getWorldPos(1, 0, 0, B); local ux = B:z() - base
    v:getWorldPos(0, 1, 0, B); local uy = B:z() - base
    v:getWorldPos(0, 0, 1, B); local uz = B:z() - base
    local d = -L * Z
    return ux * d, uy * d, uz * d
end
PV._levelShift = levelShift

-- How far (physics height units, + = toward the camera) the aircraft must move in depth so that
-- the character c in `seat`, drawn from his current root, agrees with it. 42.21 (javap:
-- ModelSlotRenderData.initModel / init, Model.CharacterModelCameraBegin, IsoDepthHelper):
--   a model's depth = its anchor's square depth + each point's depth from the model's draw origin
--   aircraft:  anchor (x, y, H / Z) - its position and physics height; origin = the body
--   character: anchor = his OWN (x, y, z), which BaseVehicle.update puts at his root's world x, y and
--              the floor of the vehicle's level (C172Presentation pins the local player's z to the
--              roof he is over); origin = his root, drawn from the vehicle's x, y and level
--   square depth = getChunkDepthData + calculateDepth, and the chunk term's -minLevel cancels
--              calculateDepth's +minLevel: LINEAR in z, no step every two levels
-- => P = BIAS - H - d_up + K * ((cx - x - dx) + (cy - y - dy)) + Z * (cz - vz),
--    (dx, dy, d_up) = getWorldPos(root) - getWorldPos(0, 0, 0); the middle term is 0 once his
--    position has caught up with his root (it is there for the frame after a re-seat).
-- 2026-10-06, Jay: "player still disappears a lot from cockpit when flying". 1.10.0 took the
-- level-pair step of calculateDepth alone (the MiG's 0.6.0 form): right parked and below two
-- storeys, but higher up the aircraft went two storeys of depth too far toward the camera for every
-- two levels it climbed - in front of its own occupants. (The UH-60's form, from its 0.1.3.)
function PV.depthPush(v, seat, c)
    vecs()
    local lp = v:getPassengerLocalPos(seat, LP)
    if not lp or not c then return 0 end
    v:getWorldPos(0, 0, 0, A)
    local H = A:z() * Z
    v:getWorldPos(-lp:x(), lp:y(), lp:z(), B)
    local dx, dy, dup = B:x() - A:x(), B:y() - A:y(), B:z() - A:z()
    local lag = (c:getX() - v:getX() - dx) + (c:getY() - v:getY() - dy)
    return BIAS - H - dup + K * lag + Z * (c:getZ() - v:getZ())
end

-- Only on a change (a repaint costs nothing, but the engine copies the colour to the shader
-- every frame anyway), or when the aircraft no longer carries the signal - a vehicle streamed
-- in again in multiplayer comes back with the server's paint.
local function signal(v, P)
    local id = v:getId()
    if P > P_MAX then P = P_MAX elseif P < -P_MAX then P = -P_MAX end
    local last = sent[id]
    -- (a push of exactly 0 - nobody aboard, both climbing in - is always sent exactly: sorts as before)
    if last and abs(last - P) < 0.02 and (P ~= 0 or last == 0) and abs(v:getColorSaturation() - SIGNAL_SAT) < 0.0005 then return end
    sent[id] = P
    v:setColorHSV(0.5 + P / 40, SIGNAL_SAT, SIGNAL_VAL)
end
PV._signal = signal

-- Put this aircraft's root for `seat` at the script position `root`, moved by the drawn-frame
-- vector (wx, wy, wz). setCharacterPosition copies the script position into the aircraft's own
-- seat, so the shared script offset is moved for that one call and put straight back.
local function placeRoot(v, c, seat, root, wx, wy, wz)
    local script = v:getScript()
    local pas = script and script:getPassenger(seat)
    local pos = pas and pas:getPositionById(root)
    if not pos then return false end
    if wx == 0 and wy == 0 and wz == 0 then
        v:setCharacterPosition(c, seat, root)
        return true
    end
    local o = pos:getOffset()
    local ox, oy, oz = o:x(), o:y(), o:z()
    o:set(ox - wx, oy + wy, oz + wz)          -- drawn x is -inX
    v:setCharacterPosition(c, seat, root)
    o:set(ox, oy, oz)
    return true
end

local function rootWanted(v, seat, root, wx, wy, wz)
    local script = v:getScript()
    local pas = script and script:getPassenger(seat)
    local pos = pas and pas:getPositionById(root)
    if not pos then return nil end
    local o = pos:getOffset()
    return o:x() - wx, o:y() + wy, o:z() + wz
end

-- One occupant of a shown seat. Returns the root he is drawn from ("inside" / "vanillastates"),
-- or nil while he is getting in.
local function poseSeat(v, seat, c, wx, wy, wz)
    local id = v:getId()
    local seats = placed[id]
    local state = c:getAnimationStateName()
    if state == "enter" then
        -- drawn from the seat's OUTSIDE root, which the engine sets; nothing here applies
        if seats then seats[seat] = nil end
        return nil
    end
    local want = POSES[seat]
    if marked[c] ~= want then                  -- new aboard, or moved to the other shown seat
        c:setVariable(POSE_VAR, want)
        marked[c] = want
    end
    local root = (state == nil or state == "" or OWN_STATES[state]) and "inside" or "vanillastates"
    if not seats then seats = {}; placed[id] = seats end
    -- re-seat when the root changes, or the aircraft's own seat no longer holds what was put
    -- there (the engine and the network both call setCharacterPosition)
    local p = seats[seat]
    local again = p == nil or p.char ~= c or p.root ~= root
        or abs(p.wx - wx) + abs(p.wy - wy) + abs(p.wz - wz) > 0.05
    if not again then
        vecs()
        local lp = v:getPassengerLocalPos(seat, LP)
        local x, y, z = rootWanted(v, seat, root, wx, wy, wz)
        again = lp == nil or x == nil or abs(lp:x() - x) + abs(lp:y() - y) + abs(lp:z() - z) > 0.01
    end
    if again and placeRoot(v, c, seat, root, wx, wy, wz) then
        seats[seat] = { char = c, root = root, wx = wx, wy = wy, wz = wz }
    end
    return root
end

-- An aircraft with nobody in a shown seat sorts exactly like before.
local function unpose(v)
    local id = v:getId()
    placed[id] = nil
    local last = sent[id]
    if last == 0 then return end
    if last == nil then
        -- first sight this session: only a push saved in the paint (a save made with somebody
        -- aboard in flight) is put back to 0 - any other paint is left exactly as it is
        sent[id] = 0
        if abs(v:getColorSaturation() - SIGNAL_SAT) >= 0.0005 then return end
        if abs(v:getColorHue() - 0.5) * 40 < 0.02 then return end
        sent[id] = nil
    end
    signal(v, 0)
end

-- Every shown seat of one aircraft, then its one push: from a seat drawn from the shared "inside"
-- root (the local player's when he is in one), else from one in vanilla's own states (aim, eat... -
-- the push fits any root), else none (getting in or out).
local function serve(v, player)
    local L = floor(v:getZ())
    local wx, wy, wz = 0, 0, 0
    local any, inside, other = false, nil, nil
    for _, seat in ipairs(SHOWN) do
        local c = v:getCharacter(seat)
        if c then
            if not any and L ~= 0 then wx, wy, wz = levelShift(v, L) end
            any = true
            local root = poseSeat(v, seat, c, wx, wy, wz)
            if root == "inside" then
                if inside == nil or c == player then inside = seat end
            elseif root == "vanillastates" and other == nil then
                other = seat
            end
        else
            local seats = placed[v:getId()]
            if seats then seats[seat] = nil end
        end
    end
    local from = inside or other
    if not any then
        unpose(v)
    elseif from ~= nil then
        signal(v, PV.depthPush(v, from, v:getCharacter(from)))
    else
        signal(v, 0)
    end
end

-- The exit clip is ours while the pose is on; ISExitVehicle waits for its End event. If it has
-- not come well after the 0.4 s clip, hand vanilla the variable it waits for, so nobody can ever
-- be stranded in the seat (BackcountryATV's and the MiG's watchdog). Local player only.
local function watchExit(player)
    if not player:getVariableBoolean("bExitingVehicle") then
        exitSince[player] = nil
        return
    end
    local now = getTimestampMs()
    local since = exitSince[player]
    if not since then exitSince[player] = now; return end
    if since > 0 and now - since > EXIT_LIMIT_MS then
        exitSince[player] = -1
        player:SetVariable("ExitAnimationFinished", "true")
        log("seat exit animation did not finish in " .. EXIT_LIMIT_MS .. " ms - completing it")
    end
end

function PV.tick()
    local player = getPlayer()
    if not player then return end
    local t = getTimestampMs() / 1000
    if t - near.at >= SCAN_SEC or t < near.at then
        near.at = t
        local list = {}                     -- copied now: C172Phys reuses its own list
        local n = C172Phys.c172ScanNearbyAircraft(player:getX(), player:getY(), SCAN_RADIUS)
        for i = 0, n - 1 do
            local v = C172Phys.c172NearbyAircraft(i)
            if v then list[#list + 1] = v end
        end
        near.list = list
    end
    local own = player:getVehicle()
    if not isCessna(own) then own = nil end
    local ownId = own and own:getId() or nil
    local seen = {}
    if own then
        seen[ownId] = true
        serve(own, player)
    end
    -- just got out (or changed aircraft): serve the one he left once more, so its push goes back
    -- to 0 even before the nearby scan has picked it up
    local left = was.v
    if left and was.id ~= ownId and not seen[was.id] and not left:isRemovedFromWorld() then
        seen[was.id] = true
        serve(left, player)
    end
    was.v, was.id = own, ownId
    for _, v in ipairs(near.list) do
        local id = v:getId()
        if not seen[id] and not v:isRemovedFromWorld() then
            seen[id] = true
            serve(v, player)
        end
    end
    -- anyone who has left a shown seat stops asking for its clips (collected first: the table is
    -- not changed while it is being walked)
    local gone
    for c, pose in pairs(marked) do
        local v = c:getVehicle()
        if c:isDead() or not isCessna(v) or POSES[v:getSeat(c)] ~= pose then
            gone = gone or {}
            gone[#gone + 1] = c
        end
    end
    if gone then
        for _, c in ipairs(gone) do
            c:clearVariable(POSE_VAR)
            marked[c] = nil
        end
    end
    if own and POSES[own:getSeat(player)] then watchExit(player) end
end

-- ---- the seat window ----
-- ISVehicleSeatUI:render reads script:getPassenger(seat):getPositionById("inside"):getOffset() for
-- every seat, to draw its icon and to find the one under the mouse. For the length of that one
-- call, the shown seats' shared "inside" offsets hold their "seatui" places; then they are put
-- back. No game logic runs while a UI element draws, so nothing else ever reads the swapped
-- values - and if a draw stops half way (an error in it), the swap is undone at the start of
-- the next frame (OnTickEvenPaused, before the world updates), before the engine or this file
-- reads a seat.
local swapped = nil                 -- { { o =, x =, y =, z = }, ... } while the window draws

local function seatWindowRestore()
    local s = swapped
    if not s then return end
    swapped = nil
    for i = 1, #s do
        local e = s[i]
        e.o:set(e.x, e.y, e.z)
    end
end
PV._seatWindowRestore = seatWindowRestore

local function seatWindowSwap(v)
    seatWindowRestore()
    if not isCessna(v) then return end
    local script = v:getScript()
    if not script then return end
    local s = {}
    swapped = s                     -- recorded as it goes, so a half-done swap is still undone
    for _, seat in ipairs(SHOWN) do
        local pas = script:getPassenger(seat)
        local inside = pas and pas:getPositionById("inside")
        local ui = pas and pas:getPositionById("seatui")
        if inside and ui then
            local o, u = inside:getOffset(), ui:getOffset()
            s[#s + 1] = { o = o, x = o:x(), y = o:y(), z = o:z() }
            o:set(u:x(), u:y(), u:z())
        end
    end
end

-- Wrapped once, late (vanilla's file can load after this one), keeping whatever was there.
local function seatWindow()
    local UI = ISVehicleSeatUI
    if not UI or UI.__c172SeatWindow or type(UI.render) ~= "function" then return end
    UI.__c172SeatWindow = true
    local base = UI.render
    UI.render = function(self, ...)
        seatWindowSwap(self.vehicle)
        base(self, ...)
        seatWindowRestore()
    end
end
PV._seatWindow = seatWindow
Events.OnGameBoot.Add(seatWindow)
-- the start of every frame, paused or not, before the world updates: no swap survives into it
Events.OnTickEvenPaused.Add(seatWindowRestore)

function PV.safeTick()
    seatWindowRestore()
    if PV.off then return end
    local ok, err = pcall(PV.tick)
    if not ok then
        PV.off = true
        log("PILOT VIEW ERROR, switched off for this session: " .. tostring(err))
    end
end

-- Registered once a game is running, so it runs after C172Presentation's OnTick (registered when
-- its file loads) and reads the level the aircraft will be drawn on.
Events.OnGameStart.Add(function()
    seatWindowRestore()
    seatWindow()
    for k in pairs(placed) do placed[k] = nil end
    for k in pairs(sent) do sent[k] = nil end
    near.list, near.at = {}, -1
    was.v, was.id = nil, nil
    PV.off = false
    if not PV.registered then
        PV.registered = true
        Events.OnTick.Add(PV.safeTick)
    end
end)

return PV
