-- Tunable constants. Edit, reload save.

return {
    VERSION       = "1.1.0",
    LOG_PREFIX = "[FloraResonator]",

    -- Master switches. Both harvest mechanics are on by default — covering
    -- both is the whole point of the mod.
    EnablePickup   = true,    -- "press E" harvest (SN2PickupItem)
    EnableCuttable = true,    -- multitool-style break + grab (coral, anemone, etc.)
    EnableV1Hook   = true,    -- support basic (V1) Sonic Resonator

    -- Per-burst caps. 0 = no cap.
    MaxPerBurst          = 0,
    MaxCuttablesPerBurst = 8,

    -- Stagger between pickups / cuttable harvests inside one burst, in ms.
    PickupStaggerMs   = 50,
    CuttableStaggerMs = 80,

    -- Growth gate: harvest only plants whose UWEPlantGrowerComponent reports
    -- growth >= this fraction. 1.0 = fully grown only. 0.9 tolerates the
    -- common case of a plant reporting 0.999... due to float math.
    MinGrowthPct = 0.9,

    -- Location dedup for respawning fruit (Necrolei, Cherimoya): once we
    -- harvest at (X,Y,Z), skip any future hit within RadiusCm for TtlMs.
    HarvestLocRadiusCm = 30.0,
    HarvestLocTtlMs    = 60000,

    -- Debounce: UE4SS fires each hook 2-3× per RPC invocation. Collapse
    -- pairs landing within this window.
    PopDebounceMs = 500,

    -- Cross-burst dedup: skip actors picked up this recently (ms).
    PickDedupMs = 3000,

    -- V2 harvest radius (cm). Priority: RadiusOverride > CDO vanilla > Fallback.
    -- We read the CDO (not the live projectile field) so other mods that
    -- inflate the projectile's SonicBubblePopRadius don't bloat our area.
    FallbackRadius = 250.0,
    RadiusOverride = 0.0,    -- > 0 forces a specific V2 radius

    -- V1 blast radius (cm). 0 = match V2 vanilla (V1's own value lives in
    -- TunableData and isn't statically readable). > 0 to override.
    V1Radius = 0.0,

    -- Cap on the retry loop that polls for the target classes to become
    -- loaded. One attempt per second. Bounded to keep the loop from
    -- outliving a session where the class never appears.
    HookInstallMaxAttempts = 30,
}
