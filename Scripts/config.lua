-- All tunable constants live here. Edit values, reload save, no other file
-- needs to change.

return {
    VERSION       = "0.5.5",

    -- Master switches. EnablePickup gates the SN2PickupItem harvest;
    -- EnableCuttable gates the multitool-style break+pickup; EnableV1Hook
    -- enables support for the basic (V1) Sonic Resonator alongside V2.
    EnablePickup   = true,
    EnableCuttable = true,
    EnableV1Hook   = true,

    -- Per-burst cap for cuttables (separate from MaxPerBurst since
    -- cuttables produce N drops each — a small forest can flood inventory).
    -- 0 = no cap.
    MaxCuttablesPerBurst = 8,

    -- Stagger between successive cuttable harvests in ms.
    CuttableStaggerMs = 80,

    -- Only harvest plants whose UWEPlantGrowerComponent reports growth
    -- >= this fraction (1.0 = fully grown). Covers plants like
    -- BP_Freesia_CuttableRegrowingFlower_C where the cuttable IS the
    -- growing thing. Doesn't cover fruit-on-parent plants (Necrolei,
    -- Cherimoya) — those use the location dedup below.
    -- Actors with no UWEPlantGrowerComponent are always considered ready.
    MinGrowthPct  = 1.0,

    -- World-space dedup for harvested locations. After we harvest a
    -- cuttable at (X,Y,Z), any future scan that finds another actor
    -- within HarvestLocRadiusCm of that point is skipped for
    -- HarvestLocTtlMs.
    --
    -- Why this exists: fruit-on-parent plants (Necrolei, Cherimoya) spawn
    -- a new fruit at the same world slot a second or two after harvest.
    -- The fruit has no growth component, so MinGrowthPct can't gate it;
    -- but its location matches the slot we just emptied, so this does.
    --
    -- Radius is per growbed slot — each plant slot is well spaced (~50cm
    -- minimum), so 30cm catches respawns without bleeding into neighbors.
    -- TTL of 60s is the rough natural regrowth interval; after that the
    -- player has presumably moved on.
    HarvestLocRadiusCm = 30.0,
    HarvestLocTtlMs    = 60000,

    -- Stagger between successive pickups inside one Pop, in milliseconds.
    -- 0 fires them all in the same tick (faster but riskier for the
    -- inventory system; a 24-item Penta cluster slams everything at once).
    -- 30–80ms feels instant to the player and gives the game time to
    -- process each pickup individually.
    PickupStaggerMs = 50,

    -- Max items harvested per burst. Stops a single Pop from emptying a
    -- whole biome. 0 = no cap. With dedup landed in v0.4 we no longer
    -- need a low cap to mask re-pickups.
    MaxPerBurst   = 0,

    -- UE4SS's RegisterHook fires multiple times per RPC invocation
    -- (pre/post). Without this guard we'd pick every actor twice (once
    -- per hook fire). 500ms is well above the observed ~20ms gap between
    -- the paired calls and well below any reasonable rate of fire.
    PopDebounceMs = 500,

    -- Cross-burst dedup window. PickupActor is a server RPC and the actor
    -- may stay in FindAllOf for some time after the call — without this,
    -- the very next shot would re-pick the same actor. Window is generous
    -- because we'd rather skip a real new actor than double-pick.
    PickDedupMs   = 3000,

    -- V2 harvest radius (cm). Priority:
    --   1. RadiusOverride if > 0
    --   2. The CDO default of BP_SonicBubbleProjectile_C (vanilla game value)
    --   3. FallbackRadius
    -- We deliberately read the CDO, NOT the spawned projectile's field —
    -- other mods (e.g. Permafrost) inflate the live projectile's
    -- SonicBubblePopRadius to enlarge their effect, which would also bloat
    -- our harvest area. The CDO stays vanilla.
    FallbackRadius = 250.0,

    -- > 0 to force a specific V2 radius regardless of CDO / Permafrost.
    RadiusOverride = 0.0,

    -- V1 (basic Sonic Resonator) blast radius (cm). V1 fires a close-range
    -- blast (no traveling projectile) via the GameplayCue
    -- `GameplayCue.Tools.SonicResonator.Blast`; we hook the AbilitySystem
    -- component's RPC dispatch and run the harvest at the player's location.
    V1Radius     = 200.0,

    LOG_PREFIX    = "[FloraResonator]",
}
