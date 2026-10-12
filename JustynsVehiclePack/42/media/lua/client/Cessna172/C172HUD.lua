--[[
    C172HUD - the Cessna's instrument panel.

    Replaces the vanilla car dashboard while PILOTING THIS AIRCRAFT, and only then. A
    passenger, another vehicle, a vanilla car, the MiG, the VX-9 and simply walking
    around all leave it hidden - see the visibility tick at the bottom, which re-checks
    the script name and the driver seat every tick rather than latching.

    IDENTITY: warm amber on near-black, laid out as round analogue instruments. That is
    deliberate and is not a reskin of another aircraft's palette - the MiG's panel is a
    cyan fighter HUD and the Wraith's is green avionics. Three aircraft, three cockpits,
    so a player always knows which one they are sitting in at a glance. This is a
    SEPARATE class in a SEPARATE file with its own module-local state; it reads nothing
    from and writes nothing to either of the others.

    LAYOUT
      LEFT   ENGINE - live part condition, one row per component that actually exists on
                      this airframe, read from VehiclePart.getCondition().
      CENTRE FLIGHT - artificial horizon that banks and pitches with the controls, with
                      the airspeed and altitude readouts over it and a heading tape above.
      RIGHT  NAV    - the real minimap embedded as a child element (see C172NavDisplay),
                      plus fuel, throttle, propeller RPM and ground/air state.

    THE COLLAPSE CONTROL ACTUALLY WORKS. Clicking the chevron at the top right collapses
    the panel to a single compact strip that still shows speed, altitude, fuel and engine
    state, and clicking it again restores the full panel. The choice is remembered for the
    session, including across getting out and back in.
]]

require "ISUI/ISPanel"
require "Cessna172/C172Parts"

-- ISPanel:derive REPLACES the global table it is assigned to, so anything added to
-- C172HUD before this line would silently vanish and crash later as "call a nil value".
-- Derive FIRST, add members after. This is a real bug that has been shipped before.
C172HUD = ISPanel:derive("C172HUD")

local C172_SCRIPT = "Base.Cessna172"

local function log(msg) print("[Cessna172][HUD] " .. msg) end
local function err(msg) print("[Cessna172][HUD][ERROR] " .. msg) end

local function isC172(vehicle)
    if not vehicle then return false end
    local ok, name = pcall(function() return vehicle:getScriptName() end)
    return ok and name == C172_SCRIPT
end

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

-- ------------------------------------------------------------------ palette
local C_AMB  = { 1.00, 0.72, 0.24 }   -- primary amber - instrument faces, needles
local C_LBL  = { 0.78, 0.58, 0.28 }   -- field labels
local C_UNIT = { 0.55, 0.42, 0.22 }   -- unit suffixes
local C_VAL  = { 0.98, 0.94, 0.86 }   -- primary numeric readouts
local C_OFF  = { 0.36, 0.30, 0.22 }   -- dim / inactive
local C_WARN = { 1.00, 0.60, 0.15 }
local C_BAD  = { 0.95, 0.32, 0.24 }
local C_GOOD = { 0.55, 0.85, 0.40 }
local C_SKY  = { 0.16, 0.30, 0.44 }
local C_GND  = { 0.30, 0.20, 0.10 }

local function band(value, warnBelow, badBelow)
    if value < badBelow  then return C_BAD[1],  C_BAD[2],  C_BAD[3]  end
    if value < warnBelow then return C_WARN[1], C_WARN[2], C_WARN[3] end
    return C_GOOD[1], C_GOOD[2], C_GOOD[3]
end

-- ------------------------------------------------------------------ layout
local BASE_W = 780
-- PANEL_H is MEASURED, not typed - see computeLayout below. 188 only holds until the first
-- measurement.
local PANEL_W, PANEL_H = BASE_W, 188
local COLLAPSED_H = 30

local LEFT_X,   LEFT_W   = 8,   186
local CENTER_X, CENTER_W = 202, 316
local RIGHT_X,  RIGHT_W  = 526, 246
local NAV_SIZE = 106

local function mx() return math.floor((PANEL_W - BASE_W) / 2) end

-- THE HUD AND THE MECHANICS PANEL NOW READ THE SAME LIST.
--
-- These rows used to be a hand-written set of six, written when the aircraft still had
-- only car parts and wings/tail/controls genuinely did not exist as parts. They do now
-- (see vehicle_cessna172.txt), so the panel is no longer showing a different aeroplane
-- from the mechanics screen. Every row below is a SYSTEM from C172Parts.SYSTEMS and its
-- number is C172Parts.systemCondition() - the worst part in that system, read live off
-- VehiclePart:getCondition(). There is no second condition value anywhere in this mod: if
-- the mechanics panel says the left aileron is at 41%, FLT CTRL here reads 41%, and the
-- flight model degrades roll authority by the amount 41% implies, because all three ask
-- the same object the same question. See C172Parts.lua's header.
--
-- Short labels because the pane is 186 px wide; the mechanics screen carries the long
-- ones. Order is cockpit-scan order - what stops you flying first, first.
local PART_ROWS = {
    { label = "ENGINE",   system = "powerplant" },
    { label = "FUEL",     system = "fuelsystem" },
    { label = "AIRFRAME", system = "airframe" },
    { label = "FLT CTRL", system = "flightcontrols" },
    { label = "GEAR",     system = "landinggear" },
    { label = "ELEC",     system = "avionics" },
    -- CHARGE, not condition. Every other row is part condition; this one is the battery's
    -- actual charge, because they are different things and only one of them stops the engine
    -- starting. An undamaged battery reads 100% condition while completely flat, which is why
    -- "every bar is green but it will not start" was impossible to diagnose from this panel.
    { label = "BATT",     system = "avionics", battery = true },
}

-- ------------------------------------------------------------ measured layout (1.8.0)
-- THE BUG: "the battery gauge is cut off at the bottom". The panel height came from the
-- screen (16.5% of it, clamped 158..184) while the rows under it were fixed pixels - seven
-- rows 20 px apart put BATT at y=160, so on any window under ~1000 px tall (Jay's Mac:
-- 1512x859, panel 158) the whole BATT row was drawn below the panel. The 1080p default font
-- also stacked the big speed/altitude digits onto KM/H and FT AGL, and at 1280x720 the
-- panel was narrower than the layout, pushing the left pane off its edge.
--
-- THE FIX: every vertical position that holds text comes from the game's real font heights
-- (PZ's Font Size option changes them: Small is 16/19/26/33/38 px), and the panel is as
-- tall as its contents need - never shorter. Proven for every font size with the harness in
-- AircraftMod/tools/tests/hud (fwrun.sh matrix), which checks text overlaps and anything
-- drawn outside its pane. Ink offsets below are the measured PZ fonts: glyph tops sit at
-- ~24.5% of the line height and the baseline at ~75%.
local L = {}
local KEY_W, KEY_H = 26, 26            -- ignition key; the dial ring is 0.7 x this
local function textW(s)
    local ok, w = pcall(function() return getTextManager():MeasureStringX(UIFont.Small, s) end)
    if ok and type(w) == "number" then return w end
    return #s * 8
end
local function computeLayout()
    local fh, fl = 19, 33
    pcall(function()
        fh = getTextManager():getFontHeight(UIFont.Small)
        fl = getTextManager():getFontHeight(UIFont.Large)
    end)
    if type(fh) ~= "number" or fh <= 0 then fh = 19 end
    if type(fl) ~= "number" or fl <= 0 then fl = 33 end
    local top,  base  = math.floor(fh * 0.245 + 0.5), math.floor(fh * 0.75 + 0.5)
    local topL, baseL = math.floor(fl * 0.245 + 0.5), math.floor(fl * 0.75 + 0.5)
    L.fh    = fh
    L.lblDy = -math.floor((top + base) / 2 + 0.5)       -- centres Small caps on a line

    -- AIRFRAME rows: text is centred on each bar; the first row clears the bay title (drawn
    -- at y=19), the pitch clears one row of caps, and the bay ends 4 px under the last row.
    local rowTy = 3 + L.lblDy
    L.rowTop = math.max(40, 23 + base + 1 - rowTy - top)
    L.pitch  = math.max(15, base - top + 7)
    local longest = 0
    for _, row in ipairs(PART_ROWS) do longest = math.max(longest, textW(row.label)) end
    L.barX = math.max(92, 8 + longest + 6)
    L.barW = LEFT_W - 7 - textW("100%") - 5 - L.barX
    -- At the largest font sizes the labels leave no room: drop the bar, keep the coloured %.
    L.noBar = L.barW < 16
    local rowsNeed = L.rowTop + (#PART_ROWS - 1) * L.pitch + math.max(7, rowTy + base + 1) + 4 + 6

    -- CENTRE, top down: heading tape, IAS/ALT labels, then the horizon holding the two big
    -- readouts. Bottom up: ignition key, dial ring, then the PWR/RPM bars clear of the ring
    -- (the key used to be drawn straight over them).
    L.tapeTop  = math.max(50, 38 + base)
    L.tapeLblY = L.tapeTop - 2 - (base + 1)
    L.kmhDy    = -3 - base                              -- KM/H's ink ends on its baseline
    L.spdDy    = L.kmhDy + top - 2 - baseL
    L.altDy    = 3 - topL
    L.ftDy     = L.altDy + baseL + 2 - top
    local readout = 2 * math.max(-(L.spdDy + topL), L.ftDy + base + 1) + 4
    L.barPitch = math.max(9, base - top + 3)
    L.statBarDy = math.max(11, base + 1)                -- NAV column: bar clear of its label
    L.statTop   = math.max(32, 24 + base - top)         -- first NAV row clears the bay title
    L.statPitch = math.max(25, L.statBarDy + 11 - top) -- label+bar rows
    L.statRow   = math.max(18, base - top + 5)          -- label-only rows
    L.keyBottomGap = 8                                  -- key box ends 2 px inside the bay
    local ringTop  = L.keyBottomGap + KEY_H / 2 + KEY_W * 0.7   -- measured up from PANEL_H
    L.barYUp   = math.ceil(ringTop) + 2 + 6 + L.barPitch      -- bar 1's top, up from PANEL_H
    local centreNeed = L.tapeTop + readout + L.barYUp + 3

    -- LAND button: fits either label so it never changes size mid-flight.
    L.landW = math.max(textW("LAND"), textW("ABORT")) + 14
    L.landH = math.min(COLLAPSED_H - 6, fh + 6)

    PANEL_H = math.max(150, rowsNeed, centreNeed)
    -- The centre usually sets the height; spread the rows into the room it leaves, up to the
    -- original 20 px spacing, rather than bunching them at the top of a taller pane.
    local spread = math.floor((PANEL_H - 6 - 4 - math.max(7, rowTy + base + 1) - L.rowTop)
                              / math.max(1, #PART_ROWS - 1))
    L.pitch = math.max(L.pitch, math.min(20, spread))
    local sw = 1920
    pcall(function() sw = getCore():getScreenWidth() end)
    -- Never narrower than the layout (that is what pushed the left pane off the panel at 720p).
    PANEL_W = math.max(BASE_W, math.min(960, math.floor(sw * 0.52)))
end

local function partCondition(vehicle, row)
    if row.battery then
        -- Read the charge off the battery part's own item - the same path C172Systems uses.
        -- Deliberately NOT vehicle:getBatteryCharge(), which does not exist on BaseVehicle in
        -- this build and throws every call.
        local pct = nil
        pcall(function()
            local part = vehicle:getPartById("Battery")
            if not part then return end
            local item = part:getInventoryItem()
            if not item then return end
            local c = item:getCurrentUsesFloat()
            if type(c) == "number" and c == c then pct = math.floor(c * 100 + 0.5) end
        end)
        return pct
    end
    return C172Parts.systemCondition(vehicle, row.system)
end

local function conditionColour(pct)
    if pct < 20 then return C_BAD[1],  C_BAD[2],  C_BAD[3]  end
    if pct < 50 then return C_WARN[1], C_WARN[2], C_WARN[3] end
    return C_GOOD[1], C_GOOD[2], C_GOOD[3]
end

-- Part conditions are read at 4 Hz, not per frame: getPartById plus getCondition for six
-- rows every frame is real work for values that change on the timescale of a crash.
local CONDITION_REFRESH_SEC = 0.25
local condCache, condCacheAt, condCacheVehicle = {}, 0, nil

local function refreshConditions(v)
    local now = getTimestampMs() / 1000
    if v == condCacheVehicle and (now - condCacheAt) < CONDITION_REFRESH_SEC then
        return condCache
    end
    condCacheAt, condCacheVehicle = now, v
    for i, row in ipairs(PART_ROWS) do
        condCache[i] = partCondition(v, row)
    end
    return condCache
end

-- ------------------------------------------------------------- ignition dial
local iconIgnition, iconIgnitionKey, iconIgnitionStarted, iconIgnitionHotwired
local function ignitionIcons()
    if not iconIgnition then
        iconIgnition         = getTexture("media/ui/vehicles/ignition.png")
        iconIgnitionKey      = getTexture("media/ui/vehicles/ignition_key_off.png")
        iconIgnitionStarted  = getTexture("media/ui/vehicles/ignition_key_on.png")
        iconIgnitionHotwired = getTexture("media/ui/vehicles/ignition_hotwired.png")
    end
    return iconIgnition, iconIgnitionKey, iconIgnitionStarted, iconIgnitionHotwired
end

-- KEY_W/KEY_H live with the measured layout above, which stacks the bars on top of them.
local function keyholeRect()
    local cx = CENTER_X + mx() + CENTER_W / 2
    return cx - KEY_W / 2, PANEL_H - L.keyBottomGap - KEY_H, KEY_W, KEY_H
end

local COLLAPSE_W, COLLAPSE_H = 20, 14
local function collapseRect()
    return PANEL_W - COLLAPSE_W - 6, 3, COLLAPSE_W, COLLAPSE_H
end

-- LAND BUTTON (1.8.0) - Jay: "add a land button on hud somewhere". Beside the ignition in the
-- full panel, beside the chevron in the collapsed strip, so it is there in both. It calls the
-- same C172Flight.requestLanding the "Land Aircraft" radial option does - no second landing
-- path. Panel-local rect; render and onMouseUp both read it from here.
function C172HUD.landButtonRect(panel)
    local bw, bh = L.landW, L.landH
    if panel and panel.collapsed then
        local cx = collapseRect()
        return cx - 8 - bw, math.floor((COLLAPSED_H - bh) / 2), bw, bh
    end
    local _, ky, _, kh = keyholeRect()
    return CENTER_X + mx() + CENTER_W - 8 - bw, math.floor(ky + kh / 2 - bh / 2), bw, bh
end

-- ------------------------------------------------------------------- panel
function C172HUD.getHUDRect(collapsed)
    local sw = getCore():getScreenWidth()
    local sh = getCore():getScreenHeight()
    local h  = collapsed and COLLAPSED_H or PANEL_H
    return (sw - PANEL_W) / 2, sh - h - 14, PANEL_W, h
end

function C172HUD:new(x, y, w, h)
    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self); self.__index = self
    o.backgroundColor = { r = 0.045, g = 0.035, b = 0.025, a = 0.92 }
    o.borderColor     = { r = 0.55, g = 0.40, b = 0.18, a = 0.85 }
    o.moveWithMouse   = false
    o.collapsed       = false
    return o
end

function C172HUD:bay(x, y, w, h, title)
    self:drawRect(x, y, w, h, 0.55, 0.08, 0.06, 0.04)
    self:drawRectBorder(x, y, w, h, 0.45, 0.42, 0.30, 0.14)
    if title then
        self:drawTextCentre(title, x + w / 2, y + 3, C_LBL[1], C_LBL[2], C_LBL[3], 1, UIFont.Small)
    end
end

function C172HUD:hbar(x, y, w, h, frac, r, g, b)
    frac = math.max(0, math.min(1, frac or 0))
    self:drawRect(x, y, w, h, 0.5, 0.12, 0.10, 0.08)
    self:drawRect(x, y, w * frac, h, 0.95, r, g, b)
    self:drawRectBorder(x, y, w, h, 0.5, 0.38, 0.30, 0.20)
end

-- drawLine2 is the ONE PZ draw call that does NOT apply the element's absolute offset -
-- every other draw* on ISPanel is panel-relative. Passing panel-relative coordinates to
-- it strays the lines across the world instead of into the panel, so every call site
-- here adds getAbsoluteX/Y explicitly.
local function line(panel, x1, y1, x2, y2, a, r, g, b)
    local ox, oy = panel:getAbsoluteX(), panel:getAbsoluteY()
    panel:drawLine2(ox + x1, oy + y1, ox + x2, oy + y2, a, r, g, b)
end

local function drawRing(panel, cx, cy, radius, startDeg, endDeg, segments, a, r, g, b)
    local prevX, prevY
    for i = 0, segments do
        local rad = math.rad(startDeg + (endDeg - startDeg) * (i / segments))
        local px, py = cx + math.sin(rad) * radius, cy - math.cos(rad) * radius
        if prevX then line(panel, prevX, prevY, px, py, a, r, g, b) end
        prevX, prevY = px, py
    end
end

-- A small nose-on light-aircraft silhouette: high wing, strut, fixed gear. Nothing about
-- it is shared with the jet glyph in the MiG mod.
local function drawPlaneGlyph(panel, cx, cy, size, a, r, g, b)
    local h = size / 2
    local function ln(x1, y1, x2, y2) line(panel, x1, y1, x2, y2, a, r, g, b) end
    ln(cx - h,        cy - h * 0.35, cx + h,        cy - h * 0.35)  -- wing
    ln(cx,            cy - h * 0.35, cx,            cy + h * 0.45)  -- fuselage
    ln(cx - h * 0.55, cy - h * 0.30, cx - h * 0.16, cy + h * 0.10)  -- left strut
    ln(cx + h * 0.55, cy - h * 0.30, cx + h * 0.16, cy + h * 0.10)  -- right strut
    ln(cx - h * 0.40, cy + h * 0.45, cx + h * 0.40, cy + h * 0.45)  -- gear axle
    ln(cx - h * 0.30, cy - h * 0.75, cx + h * 0.30, cy - h * 0.75)  -- tailplane
end

function C172HUD:tape(x, y, w, h, value, lo, hi, step, r, g, b)
    self:drawRect(x, y, w, h, 0.5, 0.10, 0.08, 0.06)
    self:drawRectBorder(x, y, w, h, 0.5, 0.38, 0.30, 0.20)
    local span = math.max(1, hi - lo)
    local v = math.max(lo, math.min(hi, value))
    local mark = lo
    while mark <= hi do
        local ty = y + h - ((mark - lo) / span) * h
        local tickW = ((mark % (step * 2)) == 0) and 8 or 4
        self:drawRect(x + w - tickW, ty, tickW, 1, 0.7, r, g, b)
        mark = mark + step
    end
    local py = y + h - ((v - lo) / span) * h
    self:drawRect(x - 3, py - 1, w + 3, 2, 1, C_VAL[1], C_VAL[2], C_VAL[3])
end

-- ------------------------------------------------------------------- input
function C172HUD:onMouseUp(x, y)
    ISPanel.onMouseUp(self, x, y)

    -- COLLAPSE / RESTORE. Checked first and always available, including while collapsed -
    -- otherwise the control that hides the panel could not bring it back, which is the
    -- classic way a "minimise" button ends up not working.
    local cx, cy, cw, ch = collapseRect()
    if x >= cx and x <= cx + cw and y >= cy and y <= cy + ch then
        self.collapsed = not self.collapsed
        self:setHeight(self.collapsed and COLLAPSED_H or PANEL_H)
        local px, py = C172HUD.getHUDRect(self.collapsed)
        self:setX(px); self:setY(py)
        if C172NavDisplay then C172NavDisplay.setVisible(not self.collapsed) end
        return
    end

    local v = self.vehicle
    if not v then return end

    -- LAND, in either state. Only acts while airborne and not already landing - on the ground
    -- the button is greyed and the click does nothing, same as the radial option being absent.
    local lx, ly, lw, lh = C172HUD.landButtonRect(self)
    if x >= lx and x <= lx + lw and y >= ly and y <= ly + lh then
        if getGameSpeed() == 0 then return end
        local st = C172Flight and C172Flight.getState and C172Flight.getState(v)
        if not (st and st.isAirborne) then return end
        -- 1.10.4: clicking it again during the approach is a go-around (Workshop request).
        local fn = st.mode == "LANDING" and C172Flight.abortLanding or C172Flight.requestLanding
        local okL, landErr = pcall(fn, v, "HUD LAND button")
        if not okL then err("LAND button failed: " .. tostring(landErr)) end
        return
    end
    if self.collapsed then return end

    local kx, ky, kw, kh = keyholeRect()
    if x < kx or x > kx + kw or y < ky or y > ky + kh then return end
    if getGameSpeed() == 0 then return end
    if getGameSpeed() > 1 then setGameSpeed(1) end
    local ok, callErr = pcall(function()
        if v:isEngineRunning() then
            ISVehicleMenu.onShutOff(getPlayer())
        elseif not v:isEngineStarted() then
            v:setKeysInIgnition(not v:isKeysInIgnition())
        end
    end)
    if not ok then err("ignition click failed: " .. tostring(callErr)) end
end

-- ------------------------------------------------------------------ panes
function C172HUD:renderLeftEngine(x, v)
    self:bay(x, 16, LEFT_W, PANEL_H - 22, "AIRFRAME")
    local conds = refreshConditions(v)
    local yy = L.rowTop
    local barX = x + L.barX
    local barW = L.barW
    -- Text sits centred on its 7 px bar, so the row reads as one line at any font size.
    local ty = 3 + L.lblDy
    for i, row in ipairs(PART_ROWS) do
        local pct = conds[i]
        if pct then
            local r, g, b = conditionColour(pct)
            self:drawText(row.label, x + 8, yy + ty, C_LBL[1], C_LBL[2], C_LBL[3], 1, UIFont.Small)
            if not L.noBar then self:hbar(barX, yy, barW, 7, pct / 100, r, g, b) end
            self:drawTextRight(("%d%%"):format(pct), x + LEFT_W - 7, yy + ty, r, g, b, 1, UIFont.Small)
        else
            self:drawText(row.label, x + 8, yy + ty, C_OFF[1], C_OFF[2], C_OFF[3], 1, UIFont.Small)
            if not L.noBar then self:hbar(barX, yy, barW, 7, 0, C_OFF[1], C_OFF[2], C_OFF[3]) end
            self:drawTextRight("--", x + LEFT_W - 7, yy + ty, C_OFF[1], C_OFF[2], C_OFF[3], 1, UIFont.Small)
        end
        yy = yy + L.pitch
    end
end

-- Top of the altitude tape, in displayed feet, derived from the flight tuning so it can
-- never disagree with the actual ceiling.
local function altTapeMax()
    local maxAlt, scale, mult = 8.0, 1.7, 3.0
    if C172Flight and C172Flight.getTune then
        local t = C172Flight.getTune()
        if t then
            maxAlt = t.MAX_ALTITUDE or maxAlt
            scale  = t.LIFT_HEIGHT_SCALE or scale
            mult   = t.HUD_ALT_MULT or mult
        end
    end
    local top = maxAlt * scale * 3.28084 * mult
    return math.max(30, math.ceil(top / 30) * 30)   -- tidy up to a multiple of 30
end

function C172HUD:renderCenter(x, v, st, spdKmh, feet, hdg, card, bankDeg, pitchPx)
    self:bay(x, 16, CENTER_W, PANEL_H - 22, nil)
    bankDeg = bankDeg or 0
    pitchPx = pitchPx or 0

    -- HEADING TAPE
    local tapeX, tapeY, tapeW, tapeH = x + 44, 22, CENTER_W - 88, 12
    local tapeCx = tapeX + tapeW / 2
    self:drawRect(tapeX, tapeY, tapeW, tapeH, 0.5, 0.10, 0.08, 0.06)
    local PX_PER_DEG, HALF_SPAN = 2.0, 48
    for mark = 0, 330, 30 do
        -- Floored, not %: Kahlua's % keeps the dividend's sign, which dropped marks near north.
        local d = (mark - hdg + 180) - math.floor((mark - hdg + 180) / 360) * 360 - 180
        if d >= -HALF_SPAN and d <= HALF_SPAN then
            local names = { [0] = "N", [90] = "E", [180] = "S", [270] = "W" }
            self:drawTextCentre(names[mark] or ("%d"):format(mark),
                                tapeCx + d * PX_PER_DEG, tapeY - 2,
                                C_VAL[1], C_VAL[2], C_VAL[3], 1, UIFont.Small)
        end
    end
    self:drawRect(tapeCx - 1, tapeY, 2, tapeH, 1, C_AMB[1], C_AMB[2], C_AMB[3])
    self:drawRectBorder(tapeX, tapeY, tapeW, tapeH, 0.5, 0.38, 0.30, 0.20)
    self:drawTextCentre(("%03d %s"):format((math.floor(hdg + 0.5) % 360 + 360) % 360, card),
                        x + CENTER_W / 2, tapeY + tapeH + 1,
                        C_AMB[1], C_AMB[2], C_AMB[3], 1, UIFont.Small)

    -- Vertical positions from the measured layout (computeLayout): the tapes end where the
    -- PWR/RPM bars begin, and those sit above the ignition dial instead of under the key.
    local tapeTop = L.tapeTop
    local barY    = PANEL_H - L.barYUp
    local tapeBot = barY - 3
    self:tape(x + 12, tapeTop, 12, tapeBot - tapeTop, spdKmh, 0, 140, 20,
              C_AMB[1], C_AMB[2], C_AMB[3])
    self:drawTextCentre("IAS", x + 18, L.tapeLblY, C_LBL[1], C_LBL[2], C_LBL[3], 1, UIFont.Small)

    local altTapeX = x + CENTER_W - 24
    -- DERIVED from the flight tuning, not a literal: this used to be a hardcoded feet
    -- range that had to be hand-edited every time the ceiling moved, and it silently went
    -- stale twice. altTapeMax() rounds the real ceiling up to a tidy number.
    self:tape(altTapeX, tapeTop, 12, tapeBot - tapeTop, feet, 0, altTapeMax(), altTapeMax() / 6,
              C_AMB[1], C_AMB[2], C_AMB[3])
    self:drawTextCentre("ALT", altTapeX + 6, L.tapeLblY, C_LBL[1], C_LBL[2], C_LBL[3], 1, UIFont.Small)

    -- ARTIFICIAL HORIZON. The sky/ground split is drawn as vertical columns whose
    -- boundary follows the bank slope, which is how a tilted horizon is produced without
    -- a rotated-quad draw call PZ does not expose. Purely decorative: it reads state, it
    -- never writes any, so it cannot desync the aircraft's real position or attitude.
    local horizX, horizW = x + 32, CENTER_W - 64
    local midX = x + CENTER_W / 2
    local midY = (tapeTop + tapeBot) / 2
    local slope = math.tan(math.rad(bankDeg))
    local COLS = 22
    local colW = horizW / COLS
    for col = 0, COLS - 1 do
        local colX = horizX + col * colW
        local lineY = midY + pitchPx + (colX + colW / 2 - midX) * slope
        lineY = math.max(tapeTop, math.min(tapeBot, lineY))
        self:drawRect(colX, tapeTop, colW + 1, lineY - tapeTop, 0.34, C_SKY[1], C_SKY[2], C_SKY[3])
        self:drawRect(colX, lineY, colW + 1, tapeBot - lineY, 0.34, C_GND[1], C_GND[2], C_GND[3])
    end
    local half = horizW / 2
    line(self, midX - half, midY + pitchPx - half * slope,
               midX + half, midY + pitchPx + half * slope,
               0.85, C_VAL[1], C_VAL[2], C_VAL[3])

    -- Fixed aircraft reference, so bank reads against something that does not move.
    self:drawRect(midX - 26, midY - 1, 12, 2, 1, C_AMB[1], C_AMB[2], C_AMB[3])
    self:drawRect(midX + 14, midY - 1, 12, 2, 1, C_AMB[1], C_AMB[2], C_AMB[3])
    self:drawRect(midX - 2, midY - 2, 4, 4, 1, C_AMB[1], C_AMB[2], C_AMB[3])

    self:drawTextCentre(("%.0f"):format(spdKmh), midX, midY + L.spdDy, C_VAL[1], C_VAL[2], C_VAL[3], 1, UIFont.Large)
    self:drawTextCentre("KM/H", midX, midY + L.kmhDy, C_UNIT[1], C_UNIT[2], C_UNIT[3], 1, UIFont.Small)
    self:drawTextCentre(("%.0f"):format(feet), midX, midY + L.altDy, C_VAL[1], C_VAL[2], C_VAL[3], 1, UIFont.Large)
    self:drawTextCentre("FT AGL", midX, midY + L.ftDy, C_UNIT[1], C_UNIT[2], C_UNIT[3], 1, UIFont.Small)

    -- POWER + PROP RPM strip.
    -- PWR is the fraction of maximum airspeed currently being commanded - i.e. how much
    -- of the aircraft's performance is in use. It is deliberately NOT read from the audio
    -- mixer's idle-loop volume, which is what an earlier draft did: that number tracks a
    -- sound level, not the aeroplane, and a panel whose whole job is telling the truth
    -- about the aircraft must not show a mixer value labelled as a flight instrument.
    local maxSpd = 118
    if C172Flight and C172Flight.getTune then
        local tn = C172Flight.getTune()
        if tn and tn.MAX_AIRSPEED_KMH then maxSpd = tn.MAX_AIRSPEED_KMH end
    end
    local pwr = math.max(0, math.min(1, (st.airSpeed or 0) / math.max(1, maxSpd)))
    local barW, barH = CENTER_W - 150, 6
    local barX = x + 62
    self:hbar(barX, barY, barW, barH, pwr, C_AMB[1], C_AMB[2], C_AMB[3])
    self:drawTextRight("PWR", barX - 4, barY + 3 + L.lblDy, C_LBL[1], C_LBL[2], C_LBL[3], 1, UIFont.Small)
    self:hbar(barX, barY + L.barPitch, barW, barH, st.propRPM or 0, C_WARN[1], C_WARN[2], C_WARN[3])
    self:drawTextRight("RPM", barX - 4, barY + L.barPitch + 3 + L.lblDy, C_LBL[1], C_LBL[2], C_LBL[3], 1, UIFont.Small)

    -- IGNITION DIAL.
    local kx, ky, kw, kh = keyholeRect()
    local dialCx, dialCy, dialR = kx + kw / 2, ky + kh / 2, kw * 0.7
    drawRing(self, dialCx, dialCy, dialR, -130, 130, 22, 0.55, C_LBL[1], C_LBL[2], C_LBL[3])
    self:drawTextRight("OFF", dialCx - dialR - 4, dialCy + L.lblDy, C_OFF[1], C_OFF[2], C_OFF[3], 1, UIFont.Small)
    self:drawText("RUN", dialCx + dialR + 4, dialCy + L.lblDy, C_GOOD[1], C_GOOD[2], C_GOOD[3], 1, UIFont.Small)

    local icon, iconKey, iconStarted, iconHot = ignitionIcons()
    local tex, needleDeg = icon, -110
    local okKI, keysIn   = pcall(function() return v:isKeysInIgnition() end)
    local okHW, hotwired = pcall(function() return v:isHotwired() end)
    local okST, started  = pcall(function() return v:isEngineStarted() or v:isStarting() end)
    if okST and started then       tex, needleDeg = iconStarted, 110
    elseif okHW and hotwired then  tex, needleDeg = iconHot, 60
    elseif okKI and keysIn then    tex, needleDeg = iconKey, 0 end

    local nr = math.rad(needleDeg)
    line(self, dialCx, dialCy,
               dialCx + math.sin(nr) * dialR * 0.8,
               dialCy - math.cos(nr) * dialR * 0.8,
               0.9, C_AMB[1], C_AMB[2], C_AMB[3])
    if tex then self:drawTextureScaled(tex, kx, ky, kw, kh, 1, 1, 1, 1) end
end

local TOUCHDOWN_FLASH_SEC = 3.0

function C172HUD:renderRightNav(x, st, engineOn, fuel, navOk, modeText)
    self:bay(x, 16, RIGHT_W, PANEL_H - 22, "NAV")
    local navX, navY = x + 6, 30
    self:drawRectBorder(navX - 1, navY - 1, NAV_SIZE + 2, NAV_SIZE + 2, 0.6, 0.50, 0.36, 0.16)
    if not navOk then
        self:drawRect(navX, navY, NAV_SIZE, NAV_SIZE, 0.5, 0.09, 0.07, 0.05)
        self:drawTextCentre("NAV OFFLINE", navX + NAV_SIZE / 2, navY + NAV_SIZE / 2 - 6,
                            C_OFF[1], C_OFF[2], C_OFF[3], 1, UIFont.Small)
    end

    local sx = navX + NAV_SIZE + 10
    local sw = x + RIGHT_W - sx - 8
    local yy = math.max(navY + 2, L.statTop)

    self:drawText("FUEL", sx, yy - 3, C_LBL[1], C_LBL[2], C_LBL[3], 1, UIFont.Small)
    self:drawTextRight(fuel >= 0 and ("%d%%"):format(fuel) or "--", sx + sw, yy - 3,
                       C_VAL[1], C_VAL[2], C_VAL[3], 1, UIFont.Small)
    self:hbar(sx, yy + L.statBarDy, sw, 6, math.max(0, fuel) / 100, band(fuel, 25, 10))
    yy = yy + L.statPitch

    self:drawText("RPM", sx, yy - 3, C_LBL[1], C_LBL[2], C_LBL[3], 1, UIFont.Small)
    self:drawTextRight(("%d%%"):format((st.propRPM or 0) * 100), sx + sw, yy - 3,
                       C_VAL[1], C_VAL[2], C_VAL[3], 1, UIFont.Small)
    self:hbar(sx, yy + L.statBarDy, sw, 6, st.propRPM or 0, C_AMB[1], C_AMB[2], C_AMB[3])
    yy = yy + L.statPitch

    -- TOUCHDOWN ANNUNCIATOR. For a few seconds after the wheels are actually on the
    -- ground, STATE flashes "TOUCHDOWN" instead of the steady mode text, so the player can
    -- SEE the moment the aircraft hands over from the flight model to the drivetrain
    -- rather than having to infer it from the way the controls feel.
    local stateText, sr, sg, sb = modeText, C_AMB[1], C_AMB[2], C_AMB[3]
    if st.touchdownAt then
        local since = (getTimestampMs() / 1000) - st.touchdownAt
        if since >= 0 and since < TOUCHDOWN_FLASH_SEC then
            -- ~3 Hz blink, so it reads as an annunciator rather than a static label.
            if math.floor(since * 6) % 2 == 0 then
                stateText = "TOUCHDOWN"
                sr, sg, sb = C_GOOD[1], C_GOOD[2], C_GOOD[3]
            end
        end
    end
    -- At large font sizes "STATE" and "APPROACH" do not both fit the column; the value alone
    -- (CRUISE / APPROACH / GROUND) still reads, so the label is the part that gives way.
    if textW("STATE") + 6 + textW(stateText) <= sw then
        self:drawText("STATE", sx, yy - 3, C_LBL[1], C_LBL[2], C_LBL[3], 1, UIFont.Small)
    end
    self:drawTextRight(stateText, sx + sw, yy - 3, sr, sg, sb, 1, UIFont.Small)
    yy = yy + L.statRow

    -- LIGHTS (1.10.4, Workshop request: "a dashboard indicator showing whether the lights are
    -- on or off"). Takes the old GEAR / FIXED row, which never changed.
    local lightsOn = false
    pcall(function() lightsOn = self.vehicle and self.vehicle:getHeadlightsOn() == true end)
    local lc = lightsOn and C_GOOD or C_OFF
    self:drawText("LIGHTS", sx, yy - 3, C_LBL[1], C_LBL[2], C_LBL[3], 1, UIFont.Small)
    self:drawTextRight(lightsOn and "ON" or "OFF", sx + sw, yy - 3, lc[1], lc[2], lc[3], 1, UIFont.Small)
    yy = yy + L.statRow

    self:drawText("ENG", sx, yy - 3, C_LBL[1], C_LBL[2], C_LBL[3], 1, UIFont.Small)
    local er = engineOn and C_GOOD or C_OFF
    self:drawTextRight(engineOn and "RUN" or "OFF", sx + sw, yy - 3, er[1], er[2], er[3], 1, UIFont.Small)

    -- Glyph spaced off the measured name, so a larger font cannot run the text into it.
    drawPlaneGlyph(self, x + RIGHT_W - 6 - textW("CESSNA 172") - 14, PANEL_H - 24, 15,
                   0.85, C_LBL[1], C_LBL[2], C_LBL[3])
    self:drawTextRight("CESSNA 172", x + RIGHT_W - 6, PANEL_H - 30,
                       C_LBL[1], C_LBL[2], C_LBL[3], 1, UIFont.Small)
end

function C172HUD:renderCollapsed(v, st, engineOn, spdKmh, feet, fuel)
    self:drawText(("IAS %3.0f km/h"):format(spdKmh), 10, 7, C_VAL[1], C_VAL[2], C_VAL[3], 1, UIFont.Small)
    self:drawText(("ALT %4.0f ft"):format(feet), 120, 7, C_VAL[1], C_VAL[2], C_VAL[3], 1, UIFont.Small)
    self:drawText(("FUEL %s"):format(fuel >= 0 and (("%d%%"):format(fuel)) or "--"),
                  225, 7, C_VAL[1], C_VAL[2], C_VAL[3], 1, UIFont.Small)
    local er = engineOn and C_GOOD or C_OFF
    self:drawText(engineOn and "ENGINE RUN" or "ENGINE OFF", 320, 7, er[1], er[2], er[3], 1, UIFont.Small)
    self:drawText("CESSNA 172", 440, 7, C_LBL[1], C_LBL[2], C_LBL[3], 1, UIFont.Small)
end

-- Three states, never hidden: LAND (airborne - click to start the approach), ABORT (the
-- approach is running - click to go around, 1.10.4) and a greyed LAND on the ground, where
-- the click does nothing.
function C172HUD:renderLandButton(st)
    local bx, by, bw, bh = C172HUD.landButtonRect(self)
    local landing = st.mode == "LANDING"
    local c = landing and C_GOOD or (st.isAirborne and C_AMB or C_OFF)
    self:drawRect(bx, by, bw, bh, 0.6, 0.10, 0.08, 0.06)
    if landing then self:drawRect(bx, by, bw, bh, 0.28, c[1], c[2], c[3]) end
    self:drawRectBorder(bx, by, bw, bh, (landing or st.isAirborne) and 0.9 or 0.5, c[1], c[2], c[3])
    self:drawTextCentre(landing and "ABORT" or "LAND", bx + bw / 2,
                        by + math.floor((bh - L.fh) / 2), c[1], c[2], c[3], 1, UIFont.Small)
end

-- ------------------------------------------------------------------ frame
function C172HUD:prerender()
    ISPanel.prerender(self)
    if not self.vehicle or self.collapsed then return end
    if C172NavDisplay and C172NavDisplay.attach then
        local navX, navY = RIGHT_X + mx() + 6, 30
        self.navOk = C172NavDisplay.attach(self, navX, navY, NAV_SIZE) ~= nil
        if self.navOk then C172NavDisplay.update() end
    end
end

-- Exponential ease, framed in real seconds so the smoothing rate does not change with
-- frame rate. Purely a display filter: it never feeds back into flight state.
local function ease(cur, target, rate, dt)
    if cur == nil then return target end
    return cur + (target - cur) * (1 - math.exp(-rate * dt))
end

local MAX_HUD_BANK_DEG = 14   -- gentler than the jet's 18: this is a 172, not a fighter
local BANK_EASE_RATE   = 2.2
local MAX_HUD_PITCH_PX = 9
local PITCH_VS_REF     = 0.30 -- verticalSpeed that reaches full deflection
local PITCH_EASE_RATE  = 1.8
local READOUT_EASE_RATE = 5.0

local MODE_TEXT = {
    GROUND  = "GROUND",
    TAKEOFF = "CLIMB",
    AIR     = "CRUISE",
    LANDING = "APPROACH",
}

function C172HUD:render()
    local v = self.vehicle
    if not v then return end
    ISPanel.render(self)

    local st = (C172Flight and C172Flight.getState) and C172Flight.getState(v) or nil
    if not st then return end

    local engineOn = false
    pcall(function() engineOn = v:isEngineRunning() == true end)

    -- Both figures are READ FROM THE FLIGHT TUNING rather than duplicated here, so the
    -- HUD cannot drift out of step with the ceiling the way it did when the tape range was
    -- a hardcoded literal. Defaults match the tuning table and only apply if the flight
    -- module has not loaded.
    local liftScale, altMult = 1.7, 3.0
    if C172Flight and C172Flight.getTune then
        local t = C172Flight.getTune()
        if t and t.LIFT_HEIGHT_SCALE then liftScale = t.LIFT_HEIGHT_SCALE end
        if t and t.HUD_ALT_MULT then altMult = t.HUD_ALT_MULT end
    end

    local spdKmh = st.airSpeed or 0
    -- HUD_ALT_MULT is a DISPLAY scale, matching the VX-9's own so the two aircraft read on
    -- the same instrument scale. PZ's vertical world is compressed - the real ceiling is
    -- 13.6 m because that is the renderer's limit, not an aviation figure - so the raw
    -- 45 ft would mean nothing to a player. Physics never sees this number.
    -- REAL height (1.8.0), not the commanded one: C172Flight measures the airframe above its
    -- gear datum as st.realAltitude. The altimeter used to show the TARGET, so a climb that was
    -- failing still read as climbing ("altitude just stays at 50" on the Workshop).
    local altUnits = st.altitude or 0
    if st.isAirborne and st.realAltitude then altUnits = st.realAltitude end
    local feet   = altUnits * liftScale * 3.28084 * altMult
    local hdg    = math.deg(st.heading or 0)
    hdg = ((hdg % 360) + 360) % 360
    local pts  = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
    local card = pts[(math.floor((hdg + 22.5) / 45) % 8) + 1]

    local now = getTimestampMs() / 1000
    local dt = self.lastAnimAt and math.min(0.25, now - self.lastAnimAt) or 0
    self.lastAnimAt = now

    self.dispSpd = ease(self.dispSpd, spdKmh, READOUT_EASE_RATE, dt)
    self.dispAlt = ease(self.dispAlt, feet, READOUT_EASE_RATE, dt)

    local fuel = -1
    local okF, f = call0(v, "getRemainingFuelPercentage")
    if okF and type(f) == "number" then fuel = f end

    -- COLLAPSE CHEVRON. Drawn in both states so the control that hid the panel can
    -- always bring it back.
    local cx, cy, cw, ch = collapseRect()
    self:drawRect(cx, cy, cw, ch, 0.45, 0.14, 0.11, 0.08)
    self:drawRectBorder(cx, cy, cw, ch, 0.6, 0.50, 0.36, 0.16)
    local mcx, mcy = cx + cw / 2, cy + ch / 2
    if self.collapsed then
        line(self, mcx - 5, mcy + 2, mcx, mcy - 3, 1, C_AMB[1], C_AMB[2], C_AMB[3])
        line(self, mcx, mcy - 3, mcx + 5, mcy + 2, 1, C_AMB[1], C_AMB[2], C_AMB[3])
    else
        line(self, mcx - 5, mcy - 2, mcx, mcy + 3, 1, C_AMB[1], C_AMB[2], C_AMB[3])
        line(self, mcx, mcy + 3, mcx + 5, mcy - 2, 1, C_AMB[1], C_AMB[2], C_AMB[3])
    end

    if self.collapsed then
        self:renderCollapsed(v, st, engineOn, self.dispSpd, self.dispAlt, fuel)
        self:renderLandButton(st)
        return
    end

    self.dispBank = ease(self.dispBank, -(st.turnInput or 0) * MAX_HUD_BANK_DEG,
                         BANK_EASE_RATE, dt)
    local pitchTarget = math.max(-1, math.min(1, (st.verticalSpeed or 0) / PITCH_VS_REF))
                        * MAX_HUD_PITCH_PX
    self.dispPitch = ease(self.dispPitch, pitchTarget, PITCH_EASE_RATE, dt)
    self.dispHdg = self.dispHdg or hdg
    do
        -- FLOORED WRAPS, never a bare %: in Kahlua -81 % 360 is -81, so the eased heading went
        -- negative and the HUD read "-279 E" (seen in Jay's 09-26 recording).
        local d = (hdg - self.dispHdg + 180) - math.floor((hdg - self.dispHdg + 180) / 360) * 360 - 180
        self.dispHdg = self.dispHdg + ease(0, d, READOUT_EASE_RATE, dt)
        self.dispHdg = self.dispHdg - math.floor(self.dispHdg / 360) * 360
    end

    local MX = mx()
    self:renderLeftEngine(LEFT_X + MX, v)
    self:renderCenter(CENTER_X + MX, v, st, self.dispSpd, self.dispAlt, self.dispHdg, card,
                      self.dispBank, self.dispPitch)
    self:renderRightNav(RIGHT_X + MX, st, engineOn, fuel, self.navOk,
                        MODE_TEXT[st.mode or "GROUND"] or "GROUND")
    self:renderLandButton(st)
end

-- ============================================================ vanilla dashboard
-- The car dashboard is hidden for THIS vehicle only. The original setVehicle is always
-- called first and unmodified, so every other vehicle - vanilla, the MiG, the Wraith,
-- any other mod's - keeps its dashboard exactly as it was. Installed once.
local dashPatched = false
local function patchDashboard()
    if dashPatched then return end
    if type(ISVehicleDashboard) ~= "table" then
        err("ISVehicleDashboard not found - the car dashboard will stay visible.")
        return
    end
    local original = ISVehicleDashboard.setVehicle
    if type(original) ~= "function" then
        err("ISVehicleDashboard.setVehicle missing - the car dashboard will stay visible.")
        return
    end
    dashPatched = true
    ISVehicleDashboard.setVehicle = function(self, vehicle, ...)
        original(self, vehicle, ...)
        pcall(function()
            if vehicle and isC172(vehicle) then
                self:setVisible(false)
                self:removeFromUIManager()
            end
        end)
    end
    log("car dashboard hidden for the Cessna 172 (other vehicles unaffected).")
end

-- The mechanics window closes when the player walks more than 6 tiles from the vehicle
-- ORIGIN. This airframe is 6.4 units across, so a player standing at a wingtip is
-- already most of the way to that limit and the window snaps shut while they are working
-- on it. Raised for this vehicle only; every other vehicle falls straight through to the
-- untouched original, including on any error.
local MECHANICS_RANGE = 6 * 2.0
local mechPatched = false
local function patchMechanicsRange()
    if mechPatched then return end
    if type(ISVehicleMechanics) ~= "table" then return end
    local orig = ISVehicleMechanics.update
    if type(orig) ~= "function" then return end
    mechPatched = true
    ISVehicleMechanics.update = function(self, ...)
        local ours = false
        pcall(function() ours = (self.vehicle ~= nil) and isC172(self.vehicle) end)
        if not ours then return orig(self, ...) end
        local ok = pcall(function()
            if self.chr:DistTo(self.vehicle:getX(), self.vehicle:getY()) > MECHANICS_RANGE then
                self:close()
            elseif not self.vehicle:getSquare()
                or self.vehicle:getSquare():getMovingObjects():indexOf(self.vehicle) < 0 then
                self:close()
            else
                self:recalculGeneralCondition()
            end
        end)
        if not ok then return orig(self, ...) end
    end
    log(("mechanics window range raised to %.0f tiles for the Cessna 172 (other vehicles unaffected)."):format(MECHANICS_RANGE))
end

-- ================================================================== lifecycle
local hud = nil

local function positionHUD()
    if not hud then return end
    local x, y = C172HUD.getHUDRect(hud.collapsed)
    hud:setX(x)
    hud:setY(y)
end

-- Re-measure for the current font + screen and apply it. Run at creation, each time the
-- panel is shown (so a Font Size change in Options is picked up on the next boarding) and
-- on a window resize.
function C172HUD.relayout(panel)
    computeLayout()
    if panel then
        panel:setWidth(PANEL_W)
        panel:setHeight(panel.collapsed and COLLAPSED_H or PANEL_H)
    end
    positionHUD()
end

Events.OnGameStart.Add(function()
    patchDashboard()
    patchMechanicsRange()
    if hud then return end
    computeLayout()
    hud = C172HUD:new(0, 0, PANEL_W, PANEL_H)
    hud:initialise()
    hud:addToUIManager()
    hud:setVisible(false)
    positionHUD()
    log(("Cessna 172 panel created (bottom centre, %dx%d, font %d px)."):format(PANEL_W, PANEL_H, L.fh))
end)

Events.OnResolutionChange.Add(function()
    if hud then pcall(C172HUD.relayout, hud) end
end)

-- VISIBILITY IS RE-EVALUATED EVERY TICK, never latched. Three conditions, all required:
-- the player is in a vehicle, that vehicle is this aircraft, and the player is its
-- DRIVER. Walking, riding as a passenger, and every other vehicle in the game
-- (including the MiG and the Wraith) fail at least one of them, so the panel simply
-- never appears.
Events.OnTick.Add(function()
    if not hud then return end
    local player = getPlayer()
    local v = player and player:getVehicle()
    local show = (v ~= nil) and isC172(v)
    if show then
        local okD, isDrv = pcall(function() return v:isDriver(player) end)
        show = (okD and isDrv) == true
    end

    if show then
        hud.vehicle = v
        if not hud:getIsVisible() then
            C172HUD.relayout(hud)
            hud:setVisible(true)
            if C172NavDisplay then C172NavDisplay.setVisible(not hud.collapsed) end
        end
        -- The dashboard can be re-created by vanilla after our setVehicle wrapper has
        -- run, so it is re-hidden here rather than assumed gone.
        local dash = nil
        if getPlayerVehicleDashboard then
            local okD, d = pcall(getPlayerVehicleDashboard, 0)
            if okD then dash = d end
        end
        if dash then
            pcall(function()
                if dash.getIsVisible and dash:getIsVisible() then
                    dash:setVisible(false)
                    if dash.removeFromUIManager then dash:removeFromUIManager() end
                end
            end)
        end
    elseif hud:getIsVisible() then
        hud.vehicle = nil
        if C172NavDisplay then C172NavDisplay.setVisible(false) end
        hud:setVisible(false)
    end
end)
