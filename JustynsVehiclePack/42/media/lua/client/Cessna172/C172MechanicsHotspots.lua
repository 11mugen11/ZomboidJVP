--[[
    C172MechanicsHotspots - GENERATED FILE. Do not edit by hand.

    Produced by tools/build_mechanics_overlay.py, which emits this file and the schematic PNGs
    from one source, so the picture and the coordinates cannot drift apart.

    TWO TABLES, AND THE DIFFERENCE MATTERS.

      LAYERS  every component that is DRAWN on the schematic - all of them, each tinted by
              its own condition, so the aeroplane still shows a worn tyre or a damaged
              aileron at a glance.

      ZONES   the few components that are CLICKABLE. Vanilla separates these cleanly:
              renderCarOverlay draws from `partProps.img`, while the hit test in
              isMouseOverPart reads `partProps.vehicles[prefix]`. A part with an img and no
              vehicles rect is drawn and never hit-tested.

    Making all thirty-four drawn parts clickable was the mistake this replaces - half of them
    were under 15 px across, which is a minefield rather than precision. Nine large zones that
    each obviously are a part of an aeroplane is how a maintenance diagram should read; every
    individual component is still in the list beside it, fully serviceable.

    Coordinates are PANEL space - image pixels plus the CarList entry's (10, 0) offset,
    matching every vanilla schematic. Zones are verified disjoint at build time, because
    getMouseOverPart() returns the FIRST rect containing the cursor and overlaps would make
    selection depend on declaration order.

    Regenerate with:  python3 tools/build_mechanics_overlay.py
]]

C172MechanicsHotspots = C172MechanicsHotspots or {}

-- The image prefix these belong to. Only this key is ever added to a vanilla part's
-- `vehicles` table, so every other vehicle keeps its own hitboxes untouched.
C172MechanicsHotspots.PREFIX = "c172_"

-- Every DRAWN component: part id -> image layer.
C172MechanicsHotspots.LAYERS = {
    { part = "DoorFrontLeft", img = "door_left" },
    { part = "DoorFrontRight", img = "door_right" },
    { part = "Elevator", img = "elevator" },
    { part = "Engine", img = "engine" },
    { part = "EngineDoor", img = "cowling" },
    { part = "Fuselage", img = "fuselage" },
    { part = "GasTank", img = "gastank" },
    { part = "HeadlightRearLeft", img = "light_nav_left" },
    { part = "HeadlightRearRight", img = "light_nav_right" },
    { part = "HorizontalStabilizer", img = "hstab" },
    { part = "LeftAileron", img = "aileron_left" },
    { part = "LeftWing", img = "wing_left" },
    { part = "Propeller", img = "propeller" },
    { part = "RightAileron", img = "aileron_right" },
    { part = "RightWing", img = "wing_right" },
    { part = "Rudder", img = "rudder" },
    { part = "SeatFrontLeft", img = "seat_left" },
    { part = "SeatFrontRight", img = "seat_right" },
    { part = "SuspensionFrontLeft", img = "strut_nose" },
    { part = "SuspensionRearLeft", img = "gearleg_left" },
    { part = "SuspensionRearRight", img = "gearleg_right" },
    { part = "TailAssembly", img = "fin" },
    { part = "TireFrontLeft", img = "wheel_nose" },
    { part = "TireRearLeft", img = "wheel_main_left" },
    { part = "TireRearRight", img = "wheel_main_right" },
    { part = "TruckBed", img = "baggage" },
    { part = "TrunkDoor", img = "baggage_door" },
    { part = "WindowFrontLeft", img = "window_left" },
    { part = "WindowFrontRight", img = "window_right" },
    { part = "Windshield", img = "windshield" },
}

-- The CLICKABLE zones. `part` is what a click selects; `label` is what the tooltip says.
C172MechanicsHotspots.ZONES = {
    { part = "Propeller", label = "Propeller", x = 110, y = 128, x2 = 174, y2 = 154 },
    { part = "TireFrontLeft", label = "Nose Landing Gear", x = 116, y = 160, x2 = 158, y2 = 188 },
    { part = "LeftWing", label = "Left Wing", x = 36, y = 190, x2 = 110, y2 = 236 },
    { part = "Windshield", label = "Cabin & Cockpit", x = 111, y = 190, x2 = 172, y2 = 237 },
    { part = "RightWing", label = "Right Wing", x = 173, y = 190, x2 = 247, y2 = 236 },
    { part = "TireRearLeft", label = "Left Main Gear", x = 74, y = 238, x2 = 116, y2 = 274 },
    { part = "TruckBed", label = "Baggage Compartment", x = 120, y = 238, x2 = 168, y2 = 272 },
    { part = "TireRearRight", label = "Right Main Gear", x = 170, y = 238, x2 = 212, y2 = 274 },
    { part = "Elevator", label = "Tail & Elevator", x = 98, y = 278, x2 = 186, y2 = 312 },
    { part = "GasTank", label = "Fuel System", x = 86, y = 388, x2 = 142, y2 = 408 },
    { part = "Rudder", label = "Fin & Rudder", x = 198, y = 386, x2 = 265, y2 = 424 },
    { part = "Engine", label = "Engine & Powerplant", x = 24, y = 410, x2 = 74, y2 = 442 },
}

return C172MechanicsHotspots
