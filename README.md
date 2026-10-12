# Justyns vehicle Pack

A combined Project Zomboid Build 42 mod containing the Emre RE9 motorcycle,
Land Rover Discovery variants, and flyable Cessna 172.

[Download the v1.0.4 mod ZIP](JustynsVehiclePack-v1.0.4.zip?raw=1)

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

- **RE9 motorcycle:** 80 mph tuning with low-speed acceleration preserved,
  custom engine audio, front cases 50 each, rear side cases 100 each, rear top
  case 250.
- **Camel Discovery:** black paint, removed Camel side logos and oval hood
  badge, dark steel wheels, trunk capacity 450.
- **All Discovery variants:** permanently opaque, black-tinted windows.
- **Cessna 172:** yellow painted body with black main-wing tips, baggage
  capacity 800, original aviation skill and flight systems retained.
- **Rear motorcycle carrier:** the original bike mounts sideways behind the
  Camel Discovery, preserving its installed parts and cargo. Its weight is added
  to the Rover. A separate mounted collision profile prevents its chassis from
  blocking the Rover while reversing; unloading restores normal collision.

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

Lua compilation and carrier/client/server regression tests passed against the
installed Build 42 runtime with mocked vehicle/network APIs. Native reverse
driving and multiplayer streaming still require in-game verification.

## Files and credits

[Installation details and change history](JustynsVehiclePack/INSTALL_AND_USE.txt)
are included in the pack. Original vehicle identities and attribution files
are retained; see [credits](JustynsVehiclePack/CREDITS.txt) and its `credits/`
directory.
