# Justyns vehicle Pack

A combined Project Zomboid Build 42 mod containing the Yamaha Tenere 700 World Rally and Emre RE9 motorcycles,
Land Rover Discovery variants, and flyable Cessna 172.

[Download the v1.0.29 mod ZIP](JustynsVehiclePack-v1.0.29.zip?raw=1)

## Install

1. Download and extract the ZIP.
2. Copy its `JustynsVehiclePack` folder into `%USERPROFILE%\Zomboid\mods`.
3. Remove any older copy of this pack and disable the separate RE9, Land Rover,
   and Cessna mods, which define the same vehicles.
4. Restart Project Zomboid and enable **Justyns vehicle Pack**. For an existing
   save, enable it in that save's mod selection too.

Expected layout: `Zomboid/mods/JustynsVehiclePack/42/mod.info`.
The pack declares Build 42.20.4 or later; Build 41 is not included.

## Included changes

- **v1.0.29 unloaded Tenere restoration:** rebuilds the normal chassis at rear-release handoff and reconciles fixed body panels and installed tire contacts after late network packets. Preserves missing tires and normal movement. Regression checks pass; live multiplayer riding retest remains pending.

- **v1.0.28 release identity:** preserves native motorcycle IDs across carrier rebuilds, accepts exact server mount/release tokens for already affected bikes, and retries deferred release packets. Includes a regression that fails with the prior handler. Live multiplayer retesting remains pending; existing server protocol retained.

- **v1.0.27 native release cache:** clears buffered multiplayer vehicle movement before rear-release physics resumes. Native seeded-cache and Lua handler checks pass; live two-client retesting remains pending. Existing v1.0.25 server protocol retained.

- **v1.0.26 multiplayer rear release:** uses native physics-to-world conversion when packet map coordinates and the body are out of sync; positions the bike behind the aircraft before normal physics and collision return. Includes a two-second safe hand-off and duplicate-release suppression. Client-side fix compatible with the existing v1.0.25 server. Native and multiplayer Lua regression checks pass; graphical multiplayer retesting remains pending.

- **v1.0.25 multiplayer Cessna repair:** corrected native ownership check and recurring airframe visibility, compatible normal/mounted Tenere model packet layouts, and replicated rear unload recovery. Install on the server and every client, then fully restart both. Native dedicated-server and multiplayer Lua regression checks pass; live graphical two-client verification remains pending.

- **v1.0.24 Cessna lamps/wheels:** engine-on wingtip emission compatible with Viewpoint, modeled lamp origins with stronger forward lighting, and separate ground-only rolling wheels.

- **v1.0.23 Cessna fit:** approved 20% aircraft enlargement, original-size centered Tenere, fitted seats/controls/character poses, rear staging clearance and calibrated parking/taxi handling.

- **v1.0.22 Cessna handling:** engine-controlled wingtip lamps, engine-off parking hold, cabin entry with a mounted Tenere, and momentum-preserving landing roll with brake/throttle takeover.

- **v1.0.21 Cessna gear/propeller fix:** calibrated taildragger suspension and belly clearance, nose-up recovery and ground support, and a centered spinning propeller.

- **v1.0.20 Cessna Tenere carrier:** fitted underside rack and approved mounted display, rear staging/unload, original motorcycle inventory retained, hidden mounted luggage and unchanged aircraft mass. Native Bullet isolation, dedicated-server and handler regression checks pass; graphical flight and a live two-client session remain untested.

- **v1.0.19 apocalypse Cessna:** weathered bush conversion, large main tires and tailwheel, roof cargo and working rack/wingtip lights. Native import, Lua compilation and isolated dedicated-server checks pass; graphical flight and two-client multiplayer validation remain pending.

- **v1.0.18 multiplayer riders:** observing clients apply motorcycle driver and
  passenger poses and seat positions, including riders already seated on join.
  Install the same version on the server and every client, then restart them.
  Kahlua regression checks passed; live multiplayer visual confirmation pending.

- **v1.0.17 Discovery interior:** solid supports below the seat cushions, closed
  spare-wheel mount, steering wheel extended toward the driver, and rear roof
  lining trimmed to the window. Includes the fitted roof, pillars and cargo floor.

- **v1.0.17 Yamaha**: Viewpoint windshield glass mask, black side cases and
  vanilla duffel replacing the top case/rack with the same storage capacity;
  Yamaha driver grips moved up, back and outward.

- **v1.0.11 fender:** front fender clearance matches the source model's
  clearance-to-tire-radius proportion.

- **v1.0.10 Yamaha fixes:** FBX orientation matches the working RE9; original
  wheel surfaces replace the reduced wheel geometry.

- **Yamaha Tenere 700 World Rally:** supplied Yamaha model and textures, sharing
  the RE9's driving, sounds, two riders, repair parts, cargo and rear carrier.
  Admin spawn ID: `Base.JVP_Tenere`.

- **RE9 motorcycle:** 80 mph tuning with low-speed acceleration preserved,
  custom engine audio, front cases 50 each, rear side cases 100 each, rear top
  case 250.
- **Camel Discovery:** black paint, removed Camel side logos and oval hood
  badge, dark steel wheels, trunk capacity 450.
- **All Discovery variants:** pickup-derived dashboard and steering wheel,
  two front seats and a rear bench, floor and inner panels; transparent windows.
  Seat models follow the existing seat parts' install/removal state.
- **Cessna 172:** yellow painted body with black main-wing tips, baggage
  capacity 800, original aviation skill and flight systems retained.
- **Rear motorcycle carrier:** either adventure motorcycle mounts sideways behind the
  Camel Discovery, preserving its installed parts and cargo. Its weight is added
  to the Rover. A separate mounted collision profile prevents its chassis from
  blocking the Rover while reversing; unloading restores normal collision.
  Fixed luggage-case meshes remain visible during loading and unloading.

## Rear carrier

Park the bike near the Camel Discovery, turn its engine off, and dismount.
Stand beside either vehicle and use **V → Load motorcycle onto rear carrier**.

To unload, park the Rover and use **V → Unload motorcycle from rear carrier**.
Leave a clear 3-by-3 area behind the car.

See [carrier instructions](JustynsVehiclePack/42/REAR_CARRIER.txt) for details.

## Multiplayer

Every player and the host/server must install the same pack version.

- Server `Mods` entry: `EmreAdventureVehiclePack_B42`.
- This is a local mod ZIP with no Steam Workshop ID. Do not put its mod ID in
  `WorkshopItems`.
- The internal mod ID is retained from the former Emre Adventure Vehicle Pack
  so existing saves and server settings continue to recognize it.

Native dedicated-server Tenere registration, loading and admin-spawn recovery passed with actual
vehicle APIs. Lua compilation and carrier/client/server regression tests also
passed. Multiplayer driving and streaming still need in-game verification.

## Files and credits

[Installation details and change history](JustynsVehiclePack/INSTALL_AND_USE.txt)
are included in the pack. Original vehicle identities and attribution files
are retained; see [credits](JustynsVehiclePack/CREDITS.txt) and its `credits/`
directory.

- **Additional v1.0.17 Yamaha update**: duffel moved forward 7 cm; player
  hands raised another 2 cm; Yamaha top view in the V-menu seat selector.
  Existing v1.0.17 Rover updates preserved byte-for-byte.
