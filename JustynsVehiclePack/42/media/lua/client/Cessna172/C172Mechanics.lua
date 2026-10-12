--[[
    C172Mechanics - the Cessna's Vehicle Mechanics screen.

    ============================ WHAT THIS SCREEN IS =============================

    Pick a SYSTEM, see its components, pick one, act on it. Eight system rows with condition
    bars on the left; the selected system's components on the right; the selected
    component's detail and its right-click actions where vanilla already puts them. The
    aircraft schematic is the other way in: click a part on the aeroplane and it selects the
    system AND the part, in the same two lists.

    IT USED TO SHOW ALL FORTY-ONE COMPONENTS AT ONCE. That is what a car's mechanics panel
    does and it works there because a car has a dozen parts; an aeroplane has too many, and
    the result was a wall of thirty-plus bars with no shape to it. The underlying parts are
    unchanged and all of them are still individually inspectable, repairable, removable and
    installable - only the number competing for attention at any one moment changed.

    ============================ THE PATCHING CONTRACT ===========================

    EVERY OVERRIDE IS GATED ON THIS ONE VEHICLE AND CALLS THROUGH OTHERWISE:

        local original = ISVehicleMechanics.foo
        function ISVehicleMechanics:foo(...)
            if not isC172(self) then return original(self, ...) end
            ...
        end

    so a vanilla car, a Workshop car, the VX-9, the MiG and every other vehicle run the
    ORIGINAL function having never entered this file's logic.

    PATCHED LATE, NOT AT REQUIRE TIME. ISVehicleMechanics is nil while mod Lua is loading,
    so a top-level patch binds to nothing. install() is idempotent and runs on OnGameBoot
    and OnGameStart.

    ============================ NOTHING MAY OVERLAP =============================

    The previous build drew eleven lines of header into a rectangle sized for nine, so
    "Empty Weight", the hour meters and the condition key ran straight through the first
    rows of the parts list. The cause was two places computing the same height and
    disagreeing.

    There is now ONE function, layout(), and it is the only thing in this file that decides
    any coordinate. createChildren calls it to SIZE the header rectangle and position the
    lists; render calls it to DRAW into that rectangle; updateLayout calls it every frame
    and re-applies it if anything moved. They cannot disagree, because none of them owns a
    number.

    layout() also reads font heights LIVE from getTextManager() rather than caching them at
    file load, so changing the UI scale or the font size re-flows the panel instead of
    leaving text sized for the old metrics inside a box sized for the new ones. Vanilla
    caches them at load and does not survive that.

    ============================ NAMES ARE NOT TRANSLATION KEYS ==================

    Vanilla labels a part with getText("IGUI_VehiclePart" .. id), a GLOBAL key: overriding
    IGUI_VehiclePartTireRearLeft would rename that tyre on every car in the game. All labels
    come from C172Parts.LIST and are applied only while rendering THIS vehicle's panel.

    ============================ THE SCHEMATIC ===================================

    Registering into ISCarMechanicsOverlay is the same route the VX-9 uses. Three tables,
    three different blast radii, all additive:

      CarList["Base.Cessna172"]             one new key.
      CarList[...].PartList[id] = {img=..}  PER-VEHICLE image override, read only while
                                            drawing this vehicle - how a vanilla part id
                                            draws an AIRCRAFT shape without changing what
                                            any other vehicle draws.
      PartList[id].vehicles["c172_"]        PER-IMGPREFIX hitbox, vanilla's own mechanism
                                            for "4door_", "van_" and the rest.

    A part with no region in the generated hotspot table gets no PartList entry at all, so
    it is neither drawn nor hit-tested. That is deliberate: the schematic shows only things
    that are visibly ON the aeroplane, and the internals (oil, starter, alternator, battery,
    fuel system, electrical bus, radio) are reached through the systems list. An earlier
    build drew them as seven empty boxed callouts around the airframe, which in game were
    seven unlabelled rectangles nobody could identify - worse than not drawing them.

    CONDITION COLOUR IS VANILLA'S. renderCarOverlay tints each part layer by
    getConditionRGB(part:getCondition()) and flashes it below 10% or when missing. Only the
    selected-part outline is added here, because vanilla has no concept of one.
]]

require "Cessna172/C172Parts"
require "Cessna172/C172MechanicsHotspots"

C172Mechanics = C172Mechanics or {}

local C172_SCRIPT = "Base.Cessna172"
local PREFIX = "c172_"

local function log(msg) print("[Cessna172][MECH] " .. msg) end

local function call0(obj, name)
    if type(obj) ~= "userdata" and type(obj) ~= "table" then return false, nil end
    local ok, fn = pcall(function() return obj[name] end)
    if not ok or type(fn) ~= "function" then return false, nil end
    return pcall(function() return fn(obj) end)
end

local function isC172(panel)
    if not panel or not panel.vehicle then return false end
    local ok, name = call0(panel.vehicle, "getScriptName")
    return ok and name == C172_SCRIPT
end

-- ============================================================ measurements
-- Bars scale with the font so the panel stays proportioned at any UI scale.
local function fontH(f) return getTextManager():getFontHeight(f) end
local function textW(s) return getTextManager():MeasureStringX(UIFont.Small, s) end

local function barW() return math.max(48, math.floor(fontH(UIFont.Small) * 4.2)) end
local function barH() return math.max(5, math.floor(fontH(UIFont.Small) * 0.5)) end

-- Extra height a SYSTEM heading row occupies beyond a normal row.
--
-- THIS MUST BE ADDED TO THE ROW'S OWN item.height AS WELL AS CONSUMED BY doDrawItem.
-- ISScrollingListBox DRAWS by threading the y returned from doDrawItem and HIT-TESTS with
-- rowAt(), which walks item.height. A row that draws taller than its recorded height puts
-- every row below it out of step with where it is painted, and the error accumulates.
-- (Vanilla's own doDrawItem has this bug - it adds 5 for a category row and never tells the
-- item - which is why this file sets the height explicitly instead of copying the shape.)
local function catExtra() return math.max(3, math.floor(fontH(UIFont.Small) * 0.35)) end

-- ================================================================== layout
--
-- THE ONLY PLACE IN THIS FILE THAT DECIDES A COORDINATE. See the header.
--
-- Returns a plain table; callers read it and never recompute anything themselves. It is
-- cheap (a few font-metric getters) and is called once per frame from updateLayout.
local function layout(panel)
    local small  = fontH(UIFont.Small)
    local medium = fontH(UIFont.Medium)

    local L = {}
    L.small, L.medium = small, medium
    L.rectX  = panel.xCarTexOffset
    L.rectW  = panel:getWidth() - panel.xCarTexOffset - 10
    L.rectY  = panel:titleBarHeight() + 10
    L.padX, L.padY = 6, 5

    -- Header rows, in order. Six is the whole summary; anything a player only needs while
    -- looking at one component lives in that component's detail panel instead.
    L.headerRows = 6
    -- The script id is DEBUG ONLY. It used to be shown whenever the unstable-script-name
    -- sandbox option was on, which is on by default in unstable builds - so it was in front
    -- of ordinary players. getCore():getDebug() is the correct gate.
    L.showDebugLine = getCore():getDebug()

    -- THE RECTANGLE MUST FIT BOTH COLUMNS, NOT JUST MINE. Vanilla's renderPartDetail draws
    -- into the RIGHT half from the same origin, and its length depends on which component is
    -- selected - a door is the longest at six lines (item, weight, open, locked, lock
    -- broken, and the debug XP line). Sizing the box to my six header rows alone would let a
    -- door's detail run out of the bottom of it and into the lists, which is the same class
    -- of bug as the header overflow this layout function exists to prevent, just in the
    -- other column. Eight rows covers the worst case with slack for a larger font.
    L.detailRows = 8
    L.contentRows = math.max(L.headerRows, L.detailRows)

    -- Title + optional debug line + the rows, then the timed-action progress bar.
    L.headerTextH = L.padY + medium
                  + (L.showDebugLine and small or 0)
                  + L.contentRows * small
    L.progressH = small
    L.progressPad = 4
    L.rectH = L.headerTextH + L.padY + L.progressH + L.progressPad

    L.progressY = L.rectY + L.rectH - L.progressPad - L.progressH

    -- The header occupies the LEFT half of the rectangle; vanilla's renderPartDetail draws
    -- into the right half from the same origin, so the split is a hard boundary and the two
    -- can never run into each other.
    L.colSplit  = L.rectX + math.floor(L.rectW / 2)
    L.labelX    = L.rectX + L.padX
    L.valueX    = L.labelX + math.min(math.floor(L.rectW / 2) - 60, textW("Overall Condition") + 14)

    -- Lists start below the rectangle and run to the bottom of the window.
    local rh = panel.resizable and panel:resizeWidgetHeight() or 0
    L.listY = L.rectY + L.rectH + 10
    L.listH = panel:getHeight() - rh - 10 - L.listY
    return L
end

-- Widths for the two lists, measured from the widest content they will actually hold, so
-- nothing is ever clipped and neither list is wider than it needs to be.
local function listWidths(panel)
    local sysW, partW = 150, 170
    local scroll = panel.listbox.vscroll:getWidth()
    local pad = 14 + barW() + 8 + textW("100%") + scroll + 8
    for _, sys in ipairs(C172Parts.SYSTEMS) do
        sysW = math.max(sysW, textW(sys.label) + pad)
    end
    for _, e in ipairs(C172Parts.LIST) do
        partW = math.max(partW, textW(e.name) + pad + catExtra())
    end
    return sysW, partW
end

-- ============================================================ overlay tables

local function registerOverlay()
    if type(ISCarMechanicsOverlay) ~= "table" then return false end
    if type(ISCarMechanicsOverlay.CarList) ~= "table" then return false end
    if type(ISCarMechanicsOverlay.PartList) ~= "table" then return false end

    local entry = ISCarMechanicsOverlay.CarList[C172_SCRIPT]
    if not entry then
        entry = { imgPrefix = PREFIX, x = 10, y = 0 }
        ISCarMechanicsOverlay.CarList[C172_SCRIPT] = entry
    end
    entry.PartList = entry.PartList or {}

    -- PASS 1 - DRAWING. Every component gets an image layer, so the schematic still shows all
    -- thirty-four tinted by their own condition. None of this makes anything clickable.
    local added, overridden = 0, 0
    for _, layer in ipairs(C172MechanicsHotspots.LAYERS) do
        local pp = ISCarMechanicsOverlay.PartList[layer.part]
        if not pp then
            -- A part id vanilla has never heard of. Deliberately NO top-level rect: without
            -- one, isMouseOverPart returns false for any vehicle not using the "c172_"
            -- prefix, so this new key cannot produce a stray hitbox on somebody else's
            -- vehicle.
            pp = { img = layer.img, vehicles = {} }
            ISCarMechanicsOverlay.PartList[layer.part] = pp
            added = added + 1
        else
            -- A vanilla part id. Its GLOBAL img is left exactly as it was; the aircraft
            -- shape comes from the per-vehicle override, read only while drawing this one.
            pp.vehicles = pp.vehicles or {}
            if pp.img ~= layer.img then
                entry.PartList[layer.part] = { img = layer.img }
                overridden = overridden + 1
            end
        end
    end

    -- PASS 2 - CLICKING.
    --
    -- READ isMouseOverPart BEFORE CHANGING ANY OF THIS:
    --
    --     local xTest = partProps.x                          -- vanilla's own rect
    --     if partProps.vehicles and partProps.vehicles[props.imgPrefix] then
    --         xTest = partProps.vehicles[props.imgPrefix].x  -- overridden ONLY if present
    --     end
    --
    -- It DEFAULTS to the part's top-level rect and treats `vehicles[prefix]` as an override.
    -- So "give a part no rect and it will not be hit-tested" is TRUE only for a part id
    -- vanilla has never heard of, which starts life with no top-level rect at all. Every
    -- VANILLA id this aircraft reuses - EngineDoor, Battery, Radio, the doors, windows,
    -- seats, brakes, gear legs and lights - already carries a rect from the CAR schematic,
    -- and that rect stays live unless it is explicitly overridden here.
    --
    -- That is precisely what went wrong in 1.5.1: only the twelve zones were overridden, so
    -- the remaining vanilla ids were still being hit-tested against car-shaped rectangles
    -- scattered across the panel. Clicking the aeroplane selected whichever car part's box
    -- happened to sit under the cursor - the "I click something and the wrong part is
    -- selected" bug, and it was mine.
    --
    -- So EVERY drawn part gets an explicit entry: the real rect for a zone, and an
    -- unsatisfiable one for everything else.
    C172Mechanics.zoneByPart = {}
    local zoneOf = {}
    for _, z in ipairs(C172MechanicsHotspots.ZONES) do
        zoneOf[z.part] = z
    end

    -- The containment test is `x >= x1 and x <= x2 and y > y1 and y <= y2`. With y1 == y2
    -- the pair `y > n and y <= n` cannot both hold for any y, so this rect matches NOTHING,
    -- whatever the mouse does. Negative coordinates alone would not be enough - a rect is
    -- also drawn when the Mechanics.Render.Hitbox debug option is on, and this keeps that
    -- harmless too.
    local NO_HIT = { x = -1, y = -1, x2 = -1, y2 = -1 }

    local drawn = {}
    for _, layer in ipairs(C172MechanicsHotspots.LAYERS) do drawn[layer.part] = true end

    local zoned, blocked = 0, 0
    for id, pp in pairs(ISCarMechanicsOverlay.PartList) do
        pp.vehicles = pp.vehicles or {}
        local z = zoneOf[id]
        if z then
            pp.vehicles[PREFIX] = { x = z.x, y = z.y, x2 = z.x2, y2 = z.y2 }
            C172Mechanics.zoneByPart[id] = z
            zoned = zoned + 1
        else
            pp.vehicles[PREFIX] = NO_HIT
            blocked = blocked + 1
            -- AND BLANK ITS PICTURE, if this aircraft inherits the id but does not draw it.
            --
            -- renderCarOverlay builds its texture path as `imgPrefix .. partProps.img`, so a
            -- vanilla entry like Battery (img="battery") sends it looking for
            -- "c172_battery.png" - a file that does not exist, because this aircraft draws no
            -- battery. That was the second half of the same bug: a car's battery, a car's
            -- front-right suspension and a car's front-right wheel were all being asked for by
            -- name on the aeroplane. The per-vehicle override is read ONLY while drawing this
            -- vehicle, so pointing them at a 1x1 transparent PNG makes them draw nothing here
            -- and changes not one pixel on any car.
            if not drawn[id] then entry.PartList[id] = { img = "blank" } end
        end
    end

    log(("schematic: %d drawn layers (%d new ids, %d image overrides), %d clickable zones, " ..
         "%d layers explicitly not hit-tested"):format(#C172MechanicsHotspots.LAYERS, added,
         overridden, zoned, blocked))
    return true
end

-- ============================================================ list building

-- Which system a part belongs to, or nil.
local function systemOf(part)
    local okId, id = call0(part, "getId")
    if not okId or not id then return nil end
    local e = C172Parts.BY_ID[id]
    return e and e.system or nil
end

-- Every part this vehicle actually has, excluding nodisplay internals, keyed by id.
local function presentParts(vehicle)
    local present = {}
    local okCount, count = call0(vehicle, "getPartCount")
    if not (okCount and type(count) == "number") then return present end
    for i = 0, count - 1 do
        local okP, part = pcall(function() return vehicle:getPartByIndex(i) end)
        if okP and part then
            local okId, id = call0(part, "getId")
            local okCat, cat = call0(part, "getCategory")
            if okId and id and not (okCat and cat == "nodisplay") then present[id] = part end
        end
    end
    return present
end

-- Fills the RIGHT list with one system's components. Returns the number added.
local function fillParts(panel, systemKey)
    panel.bodyworklist:clear()
    panel.c172System = systemKey
    local present = panel.c172Present or presentParts(panel.vehicle)
    local n = 0
    for _, e in ipairs(C172Parts.BY_SYSTEM[systemKey] or {}) do
        local part = present[e.id]
        if part then
            panel.bodyworklist:addItem(e.name, { name = e.name, part = part })
            n = n + 1
        end
    end
    if n > 0 then panel.bodyworklist.selected = 1 end
    return n
end

-- ============================================================== panel patches

local installed = false

local function install()
    if installed then return true end
    if type(ISVehicleMechanics) ~= "table" then return false end
    if not registerOverlay() then return false end

    ------------------------------------------------------------------ initParts
    local origInitParts = ISVehicleMechanics.initParts
    function ISVehicleMechanics:initParts()
        if not isC172(self) then return origInitParts(self) end

        self.listbox:clear()
        self.bodyworklist:clear()
        self.vehiclePart = {}
        self.c172Present = presentParts(self.vehicle)

        -- vanilla's category -> parts index. Nothing in this panel reads it, but
        -- checkEngineFull() walks it every frame and other mods read it, so it is populated
        -- in vanilla's shape over ALL parts - not just the visible system - or every part's
        -- checkEngine would silently stop being evaluated for this vehicle.
        for _, sys in ipairs(C172Parts.SYSTEMS) do
            local rows = {}
            for _, e in ipairs(C172Parts.BY_SYSTEM[sys.key] or {}) do
                local part = self.c172Present[e.id]
                if part then table.insert(rows, { name = e.name, part = part }) end
            end
            if #rows > 0 then
                self.vehiclePart[sys.key] = { name = sys.label, cat = sys.key, parts = rows }
                self.listbox:addItem(sys.label, { name = sys.label, system = sys.key })
            end
        end

        -- ANYTHING THIS FILE DOES NOT KNOW ABOUT STILL APPEARS. If a future script change or
        -- another mod adds a part to this vehicle it lands in OTHER SYSTEMS rather than
        -- vanishing: a part the player cannot see is a part they cannot repair.
        local leftovers = {}
        for id, part in pairs(self.c172Present) do
            if not C172Parts.BY_ID[id] then
                table.insert(leftovers, { name = getText("IGUI_VehiclePart" .. id),
                                          part = part, id = id })
            end
        end
        if #leftovers > 0 then
            table.sort(leftovers, function(a, b) return a.id < b.id end)
            self.c172Leftovers = leftovers
            self.listbox:addItem("OTHER SYSTEMS", { name = "OTHER SYSTEMS", system = "__other" })
        else
            self.c172Leftovers = nil
        end

        -- Keep the system the player was looking at across a repair or an install (vanilla
        -- re-runs initParts after every mechanics action). Falling back to the first system
        -- only when the old one no longer exists.
        local want = self.c172System
        local found = nil
        for i = 1, self.listbox:size() do
            if self.listbox.items[i].item.system == want then found = i break end
        end
        if not found then found = (self.listbox:size() > 0) and 1 or nil end
        if found then
            self.listbox.selected = found
            local key = self.listbox.items[found].item.system
            if key == "__other" then
                self.bodyworklist:clear()
                for _, r in ipairs(self.c172Leftovers or {}) do
                    self.bodyworklist:addItem(r.name, r)
                end
                self.c172System = "__other"
                if self.bodyworklist:size() > 0 then self.bodyworklist.selected = 1 end
            else
                fillParts(self, key)
            end
        end

        self:recalculGeneralCondition()
        self.leftListHasFocus = true
        self:updateLayout()

        -- A repair, install or uninstall lands here, so this is where the cached
        -- performance effects are dropped - the HUD and the flight model then see the
        -- change immediately rather than up to a second later.
        C172Parts.invalidate(self.vehicle)
    end

    ------------------------------------------------------- overall condition
    -- Averages over the parts the panel shows, so the headline figure and the bars beneath
    -- it are answers to the same question. Vanilla averages over every nodisplay internal
    -- as well.
    local origRecalc = ISVehicleMechanics.recalculGeneralCondition
    function ISVehicleMechanics:recalculGeneralCondition()
        if not isC172(self) then return origRecalc(self) end
        local c = C172Parts.overallCondition(self.vehicle)
        self.generalCondition = c and (math.floor(c * 10 + 0.5) / 10) or 0
        self.generalCondRGB = self:getConditionRGB(self.generalCondition)
    end

    ------------------------------------------------------------- updateLayout
    -- Runs every frame from prerender. Recomputes the layout and re-applies it only when
    -- something has actually moved, so a UI-scale or font change re-flows the panel and a
    -- settled panel costs one comparison.
    local origUpdateLayout = ISVehicleMechanics.updateLayout
    function ISVehicleMechanics:updateLayout()
        if not isC172(self) then return origUpdateLayout(self) end

        local sysW, partW = listWidths(self)
        self:setWidth(math.max(800, self.xCarTexOffset + sysW + 20 + partW + 10))

        local L = layout(self)
        self.c172Layout = L
        -- Kept in sync for anything vanilla still reads (renderPartDetail uses rectY).
        self.rectY, self.rectHgt = L.rectY, L.rectH
        self.progressHgt, self.progressPadBottom = L.progressH, L.progressPad
        self.progressY = L.progressY

        self.listbox:setWidth(sysW)
        self.bodyworklist:setWidth(partW)
        self.bodyworklist:setX(self.listbox:getRight() + 20)
        self.listbox.vscroll:setX(self.listbox:getWidth() - 16)
        self.bodyworklist.vscroll:setX(self.bodyworklist:getWidth() - 16)

        if self.listbox:getY() ~= L.listY or self.listbox:getHeight() ~= L.listH then
            self.listbox:setY(L.listY);      self.listbox:setHeight(L.listH)
            self.bodyworklist:setY(L.listY); self.bodyworklist:setHeight(L.listH)
        end

        self.collapseButton:setX(self:getWidth() - 3 - self.collapseButton:getWidth())
        self.pinButton:setX(self:getWidth() - 3 - self.pinButton:getWidth())
    end

    ---------------------------------------------------------------- list rows
    -- Condition BARS, not a "(94%)" suffix: a column of bars can be scanned in one look and
    -- a column of bracketed numbers cannot. Same getConditionRGB ramp as the schematic and
    -- the headline figure, so one colour language runs through the panel.
    --
    -- doDrawItem is a LISTBOX method (createChildren assigns it to both lists), so `self` is
    -- the ISScrollingListBox and the panel is self.parent.
    local origDoDrawItem = ISVehicleMechanics.doDrawItem
    function ISVehicleMechanics:doDrawItem(y, item, alt)
        if not isC172(self.parent) then return origDoDrawItem(self, y, item, alt) end
        local panel = self.parent
        local small = fontH(UIFont.Small)
        local bw, bh = barW(), barH()

        local isSystem = item.item.system ~= nil
        local extra = isSystem and catExtra() or 0
        local rowH = self.itemheight + extra

        if item.itemindex == self.selected then
            self:drawRect(0, y, self:getWidth(), rowH, 0.18, 0.42, 0.66, 1.0)
        elseif item.itemindex == self.mouseoverselected
                and ((panel.context and not panel.context:isVisible()) or not panel.context) then
            self:drawRect(0, y, self:getWidth(), rowH, 0.07, 1.0, 1.0, 1.0)
        end

        local ty = y + extra
        local cond, label, nameCol

        if isSystem then
            cond = (item.item.system == "__other") and 100
                   or C172Parts.systemCondition(panel.vehicle, item.item.system)
            label = item.item.name
            nameCol = { r = 0.78, g = 0.85, b = 0.95 }
        else
            local part = item.item.part
            cond = part:getCondition()
            local missing = (not part:getInventoryItem()) and part:getTable("install") ~= nil
            if missing then cond = 0 end
            label = item.item.name
            nameCol = missing
                and { r = getCore():getBadHighlitedColor():getR(),
                      g = getCore():getBadHighlitedColor():getG(),
                      b = getCore():getBadHighlitedColor():getB() }
                or  { r = panel.partRGB.r, g = panel.partRGB.g, b = panel.partRGB.b }
        end
        cond = cond or 0

        self:drawText(label, 8, ty, nameCol.r, nameCol.g, nameCol.b, 1, UIFont.Small)

        -- The bar and its number are anchored to the RIGHT edge of the list, so they line up
        -- in a column regardless of how long the names are or how the font is scaled.
        local pctW = textW("100%")
        local barX = self:getWidth() - self.vscroll:getWidth() - 6 - pctW - 6 - bw
        local barY = ty + math.floor((small - bh) / 2)
        local rgb = panel:getConditionRGB(cond)
        self:drawRect(barX, barY, bw, bh, 0.40, 0, 0, 0)
        self:drawRect(barX, barY, math.max(1, math.floor(bw * cond / 100)), bh,
                      0.95, rgb.r, rgb.g, rgb.b)
        self:drawRectBorder(barX, barY, bw, bh, 0.30, 1, 1, 1)
        self:drawText(math.floor(cond + 0.5) .. "%", barX + bw + 6, ty,
                      rgb.r, rgb.g, rgb.b, 1, UIFont.Small)

        return y + rowH
    end

    ------------------------------------------------------------ list clicking
    -- Clicking a SYSTEM on the left fills the right list with its components and selects
    -- the first, so there is always something selected and the detail panel is never blank.
    local origListMouseDown = ISVehicleMechanics.onListMouseDown
    function ISVehicleMechanics:onListMouseDown(x, y)
        if not isC172(self.parent) then return origListMouseDown(self, x, y) end
        if UIManager.getSpeedControls():getCurrentGameSpeed() == 0 and not getDebug() then return end
        local panel = self.parent
        local row = self:rowAt(x, y)
        if row < 1 or row > #self.items then return end
        self.selected = row
        local it = self.items[row].item
        if it.system then
            panel.bodyworklist.selected = 0
            if it.system == "__other" then
                panel.bodyworklist:clear()
                for _, r in ipairs(panel.c172Leftovers or {}) do
                    panel.bodyworklist:addItem(r.name, r)
                end
                panel.c172System = "__other"
                if panel.bodyworklist:size() > 0 then panel.bodyworklist.selected = 1 end
            else
                fillParts(panel, it.system)
            end
            panel.leftListHasFocus = true
        else
            panel.leftListHasFocus = false
        end
    end

    -- Right-clicking a SYSTEM has no part to act on, so it must not reach
    -- doPartContextMenu with nil. Vanilla guards on `item.cat`; these rows are selectable
    -- and therefore not cat, so the guard is on the presence of a part instead.
    local origListRightMouseUp = ISVehicleMechanics.onListRightMouseUp
    function ISVehicleMechanics:onListRightMouseUp(x, y)
        if not isC172(self.parent) then return origListRightMouseUp(self, x, y) end
        self:onMouseDown(x, y)
        local it = self.items[self.selected] and self.items[self.selected].item
        if it and it.part then
            self.parent:doPartContextMenu(it.part, self:getX() + x,
                                          self:getY() + self:getYScroll() + y)
        else
            self.parent:onRightMouseUp(self:getX() + x, self:getY() + self:getYScroll() + y)
        end
    end

    -- A controller's A button on a SYSTEM row opens that system, as a click does (1.9.1).
    -- Vanilla's onJoypadDown hands the row's part to doPartContextMenu, and a system row has
    -- none - doPartContextMenu(nil) threw on part:getItemType().
    local origJoypadDown = ISVehicleMechanics.onJoypadDown
    function ISVehicleMechanics:onJoypadDown(button, joypadData)
        if isC172(self) and button == Joypad.AButton then
            local lb = self.leftListHasFocus and self.listbox or self.bodyworklist
            local row = lb.items[lb.selected]
            local it = row and row.item
            if it and not it.part then
                if it.system == "__other" then
                    self.bodyworklist:clear()
                    for _, r in ipairs(self.c172Leftovers or {}) do self.bodyworklist:addItem(r.name, r) end
                    self.c172System = "__other"
                elseif it.system then
                    fillParts(self, it.system)
                end
                if self.bodyworklist:size() > 0 then
                    self.rightListSelection = 1
                    self:onJoypadDirRight()
                end
                return
            end
        end
        return origJoypadDown(self, button, joypadData)
    end

    ---------------------------------------------------- schematic -> lists
    -- The other half of the two-way selection. Vanilla's onMouseDown routes a click on the
    -- diagram through getMouseOverPart to selectPart, so overriding selectPart is enough to
    -- make the aeroplane drive BOTH lists: switch to the part's system, then select the
    -- part inside it. Both views end up reading the same selection state, which is the only
    -- way two views of one thing can be guaranteed not to drift.
    local origSelectPart = ISVehicleMechanics.selectPart
    function ISVehicleMechanics:selectPart(part)
        if not isC172(self) then return origSelectPart(self, part) end
        if not part then return end
        local sys = systemOf(part)
        if not sys then return end
        if self.c172System ~= sys then
            for i = 1, self.listbox:size() do
                if self.listbox.items[i].item.system == sys then
                    self.listbox.selected = i
                    break
                end
            end
            fillParts(self, sys)
        end
        for i = 1, self.bodyworklist:size() do
            if self.bodyworklist.items[i].item.part == part then
                self.bodyworklist.selected = i
                self.bodyworklist:ensureVisible(i)
                self.leftListHasFocus = false
                return
            end
        end
    end

    ---------------------------------------------------------------- tooltip
    -- The tooltip names the ZONE ("Landing Gear"), not the single part whose hitbox happens to
    -- carry it ("Left Main Tire"). Hovering a zone that covers three wheels and calling it one
    -- of them would be a small lie, and it is the kind that makes a player distrust the rest of
    -- the diagram. Parts with no zone are never hovered at all, so they never reach this.
    local origTooltip = ISVehicleMechanics.renderCarOverlayTooltip
    function ISVehicleMechanics:renderCarOverlayTooltip(partProps, part, carType)
        local shown = origTooltip(self, partProps, part, carType)
        if shown and isC172(self) and self.tooltip then
            local okId, id = call0(part, "getId")
            if okId and id then
                local zone = C172Mechanics.zoneByPart and C172Mechanics.zoneByPart[id]
                self.tooltip:setName(zone and zone.label or C172Parts.displayName(id))
            end
        end
        return shown
    end

    ------------------------------------------------------- selected highlight
    local origRenderOverlay = ISVehicleMechanics.renderCarOverlay
    function ISVehicleMechanics:renderCarOverlay()
        origRenderOverlay(self)
        if not isC172(self) then return end
        local sel = C172Mechanics.selectedPart(self)
        if not sel then return end
        local okId, id = call0(sel, "getId")
        if not okId or not id then return end
        -- Only a zone gets an outline. Selecting "Left Aileron" from the list highlights
        -- nothing on the diagram, which is correct: the aileron has no click target to point
        -- at, and drawing a box round a rectangle the player cannot click would imply it is
        -- one. Its condition is still visible - it is drawn and tinted like everything else.
        local zone = C172Mechanics.zoneByPart and C172Mechanics.zoneByPart[id]
        if not zone then return end
        local r = zone
        -- Two nested outlines rather than a fill: a fill would sit on top of the condition
        -- tint and hide the very thing the player selected the part to look at.
        self:drawRectBorder(r.x - 2, r.y - 2, (r.x2 - r.x) + 4, (r.y2 - r.y) + 4,
                            0.95, 0.45, 0.78, 1.0)
        self:drawRectBorder(r.x - 1, r.y - 1, (r.x2 - r.x) + 2, (r.y2 - r.y) + 2,
                            0.45, 0.45, 0.78, 1.0)
    end

    -- renderPartDetail is DELIBERATELY NOT PATCHED. Vanilla's already reports everything an
    -- aircraft component needs - the installed item and its condition, "Missing" when it is
    -- not fitted, container contents for the tank and the baggage bay, door and window
    -- state, wheel friction - and it draws from a fixed origin in the RIGHT half of the
    -- header rectangle, which layout() treats as a hard boundary. Its one debug line is
    -- already gated on getCore():getDebug().

    ------------------------------------------------------------ createChildren
    local origCreateChildren = ISVehicleMechanics.createChildren
    function ISVehicleMechanics:createChildren()
        origCreateChildren(self)
        if not isC172(self) then return end
        self:updateLayout()
        self.minimumHeight = math.max(self.minimumHeight or 0,
                                      (self.c172Layout and self.c172Layout.listY or 0) + 180)
    end

    ------------------------------------------------------------------- render
    -- Replaces vanilla's info block for this vehicle only - vanilla's is a single run of
    -- drawText calls with no seam to append at, so an aircraft header means owning it.
    -- Everything AROUND it is called through in vanilla's own order: window chrome, engine
    -- check, schematic, progress bar, flash, part detail, joypad focus rings.
    local origRender = ISVehicleMechanics.render
    function ISVehicleMechanics:render()
        if not isC172(self) then return origRender(self) end

        ISCollapsableWindow.render(self)
        if self.isCollapsed then return end
        self:checkEngineFull()
        self:renderCarOverlay()

        local L = self.c172Layout or layout(self)
        local v = self.vehicle
        self:drawRectBorder(L.rectX, L.rectY, L.rectW, L.rectH, 1,
                            self.borderColor.r, self.borderColor.g, self.borderColor.b)

        local y = L.rectY + L.padY
        self:drawTextCentre("Cessna 172", L.rectX + L.rectW / 2, y,
                            0.92, 0.95, 1.00, 1, UIFont.Medium)
        y = y + L.medium
        if L.showDebugLine then
            self:drawTextCentre(getText("IGUI_Mechanics_VehicleScript",
                                        v:getScript():getFullType()),
                                L.rectX + L.rectW / 2, y, 0.55, 0.55, 0.55, 1, UIFont.Small)
            y = y + L.small
        end

        -- SIX ROWS, and the count is declared in layout() as L.headerRows so the rectangle
        -- is sized for exactly what is drawn here. Adding a row means changing that number;
        -- the assert below makes forgetting impossible rather than merely unlikely.
        local rows = 0
        local function row(label, text, r, g, b)
            self:drawText(label, L.labelX, y, 0.70, 0.75, 0.83, 1, UIFont.Small)
            self:drawText(text, L.valueX, y, r or 0.95, g or 0.95, b or 0.95, 1, UIFont.Small)
            y = y + L.small
            rows = rows + 1
        end

        local overall = self.generalCondition or 0
        local oc = self:getConditionRGB(overall)
        row("Overall Condition", string.format("%.1f%%", overall), oc.r, oc.g, oc.b)

        local amount, cap, frac = C172Parts.containerLevel(v, "GasTank")
        if amount then
            local c = self:getConditionRGB(math.floor(frac * 100))
            row("Fuel", string.format("%d%%  (%.1f L)", math.floor(frac * 100 + 0.5), amount),
                c.r, c.g, c.b)
        else
            row("Fuel", "--")
        end

        row("Empty Weight", tostring(v:getMass()))

        local bag = v:getPartById("TruckBed")
        if bag and bag:getItemContainer() then
            row("Baggage", string.format("%.0f / %.0f",
                bag:getItemContainer():getCapacityWeight(),
                bag:getContainerCapacity(self.chr)))
        else
            row("Baggage", "--")
        end

        local function hours(h) return h and string.format("%.1f h", h) or "--" end
        row("Engine Hours", hours(C172Parts.engineHours(v)))
        row("Flight Time", hours(C172Parts.airframeHours(v)))

        -- The header can never grow past what layout() reserved: if these ever disagree the
        -- overflow is reported once instead of being drawn through the lists below, which is
        -- exactly the failure this whole layout() arrangement exists to prevent.
        if rows ~= L.headerRows and not self.c172WarnedRows then
            self.c172WarnedRows = true
            log(("HEADER ROW MISMATCH: drew %d rows, layout reserved %d - update " ..
                 "L.headerRows in layout()"):format(rows, L.headerRows))
        end

        -- ---- vanilla's progress bar / flash, unchanged in behaviour ----
        local fgBar = { r = getCore():getGoodHighlitedColor():getR(),
                        g = getCore():getGoodHighlitedColor():getG(),
                        b = getCore():getGoodHighlitedColor():getB(), a = 1 }
        local q = ISTimedActionQueue.getTimedActionQueue(self.chr)
        local progress = false
        if q and q.queue and q.queue[1] and q.queue[1].jobType and q.queue[1].jobType ~= "" then
            self:drawProgressBar(L.labelX, L.progressY, L.rectW - 12, L.progressH,
                                 q.queue[1]:getJobDelta(), fgBar)
            self:drawTextCentre(q.queue[1].jobType, L.rectX + L.rectW / 2, L.progressY,
                                0.8, 0.8, 0.8, 1, UIFont.Small)
            progress = true
        end
        if not progress and self.flashTimer > 0 then
            self.flashTimer = self.flashTimer - 1
            local col = self.flashFailure and { r = 0.5, g = 0.1, b = 0.1, a = self.flashTimerAlpha }
                                          or  { r = 0.1, g = 0.6, b = 0.1, a = self.flashTimerAlpha }
            self:drawProgressBar(L.labelX, L.progressY, L.rectW - 12, L.progressH, 100, col)
            self:drawTextCentre(self.flashFailure and getText("IGUI_Failure")
                                                   or getText("IGUI_Success"),
                                L.rectX + L.rectW / 2, L.progressY, 0.8, 0.8, 0.8, 1, UIFont.Small)
            if self.flashTimerAlphaInc then
                self.flashTimerAlpha = self.flashTimerAlpha + 0.06
                if self.flashTimerAlpha >= 1 then self.flashTimerAlpha = 1; self.flashTimerAlphaInc = false end
            else
                self.flashTimerAlpha = self.flashTimerAlpha - 0.06
                if self.flashTimerAlpha <= 0 then self.flashTimerAlpha = 0; self.flashTimerAlphaInc = true end
            end
        end

        local sel = C172Mechanics.selectedPart(self)
        if sel then self:renderPartDetail(sel) end

        if self.drawJoypadFocus then
            local ui = self.leftListHasFocus and self.listbox or self.bodyworklist
            self:drawRectBorder(ui:getX(), ui:getY(), ui:getWidth(), ui:getHeight(),
                                0.4, 0.2, 1.0, 1.0)
            self:drawRectBorder(ui:getX() + 1, ui:getY() + 1, ui:getWidth() - 2,
                                ui:getHeight() - 2, 0.4, 0.2, 1.0, 1.0)
        end
    end

    installed = true
    log("Vehicle Mechanics overrides installed (Cessna only; every other vehicle runs vanilla).")
    return true
end

-- The selected COMPONENT is always the right-hand list's selection. The left list selects a
-- system, which is not something that can be repaired, so it deliberately does not count.
function C172Mechanics.selectedPart(panel)
    local ri = panel.bodyworklist.items[panel.bodyworklist.selected]
    if ri and ri.item and ri.item.part then return ri.item.part end
    return nil
end

C172Mechanics.install = install

if not install() then Events.OnGameBoot.Add(install) end
Events.OnGameStart.Add(install)

return C172Mechanics
