# Harvester

A Subnautica 2 UE4SS mod that extends the Sonic Resonator so its burst also
harvests any pickup-able item (plants, fruit, fragments, small loot) inside
the burst radius — same as if you had walked up and pressed E on each one.

Currently a debug-first v0.1.0: hooks the orb's `Pop` event, scans for
pickupables within `SonicBubblePopRadius`, and routes them through the
player's `UWEInventoryRouterComponent:PickupActor`. Log lines go to
`Subnautica2/Binaries/Win64/ue4ss/UE4SS.log`.

## Console

- `harvest status` — print version / state
- `harvest dump`   — log every pickupable currently within radius of the player (useful while pointing the resonator at a plant)
