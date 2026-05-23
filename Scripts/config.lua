-- All tunable constants live here so other modules can `require("config")`
-- and read them. Edit values here, restart the mod (or reload save), no
-- other file needs to change.

return {
    VERSION       = "0.5.3",

    -- Verbose logging of every Pop / dump.
    Debug         = true,

    -- Master switch for the actual PickupActor calls. Toggle in-game with
    -- the PickupToggleKey (no console needed), or flip here and reload save.
    EnablePickup  = true,

    -- Multitool-style "cuttable" plant harvest. When true, every Pop also
    -- scans cuttable actors (SN2Statics:IsActorCuttable) in radius, reads
    -- their CuttableData (NumHitsToBreak + ResourceClass), and triggers a
    -- full break — spawning all expected drops at once and routing them
    -- into the player's inventory.
    EnableCuttable    = true,

    -- Per-burst cap for cuttables (separate from MaxPerBurst since
    -- cuttables produce N drops each — a small forest can flood inventory).
    -- 0 = no cap.
    MaxCuttablesPerBurst = 8,

    -- Stagger between successive cuttable harvests in ms.
    CuttableStaggerMs = 80,

    -- Only harvest plants whose UWEPlantGrowerComponent reports growth
    -- >= this fraction (1.0 = fully grown). GrowBed plants regrow at 0%
    -- after harvest; without this gate the next burst sees the fresh
    -- regrowing actors and "harvests" them too, free-farming the player.
    -- Actors with no UWEPlantGrowerComponent (wild plants) are always
    -- considered ready. 1.0 = strict; 0.95 = allow nearly-ripe; 0.0 =
    -- disable the gate.
    MinGrowthPct  = 1.0,

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

    -- UE4SS's RegisterHook fires twice per Pop call (pre/post execution).
    -- Without this guard we'd pick every actor twice (once per hook fire).
    -- 500ms is well above the observed ~20ms gap between the paired calls
    -- and well below any reasonable rate of fire.
    PopDebounceMs = 500,

    -- Cross-burst dedup window. PickupActor is a server RPC and the actor
    -- may stay in FindAllOf for some time after the call — without this,
    -- the very next shot would re-pick the same actor. Window is generous
    -- because we'd rather skip a real new actor than double-pick.
    PickDedupMs   = 3000,

    -- Harvest radius (cm). Priority:
    --   1. RadiusOverride if > 0
    --   2. The CDO default of BP_SonicBubbleProjectile_C (vanilla game value)
    --   3. FallbackRadius
    -- We deliberately read the CDO, NOT the spawned projectile's field —
    -- other mods (e.g. Permafrost) inflate the live projectile's
    -- SonicBubblePopRadius to enlarge their effect, which would also bloat
    -- our harvest area. The CDO stays vanilla.
    FallbackRadius = 250.0,

    -- > 0 to force a specific radius regardless of CDO / Permafrost.
    RadiusOverride = 0.0,

    -- Diagnostic scans: cap classes printed per probe (avoids 500-line
    -- spam in dense biomes). 0 = no cap.
    MaxLogPerScan = 30,

    -- When true, every dump/Pop also runs the broad Actor probe and the
    -- interface probe and logs them alongside SN2PickupItem. Useful while
    -- still investigating; turn off once we trust SN2PickupItem.
    ExtraProbes   = false,

    -- Key for the manual dump (no shot fired).
    DebugDumpKey  = "F7",

    -- Key to toggle EnablePickup at runtime. Logs the new state to UE4SS.log.
    -- Set to "" to disable.
    PickupToggleKey = "F8",

    LOG_PREFIX    = "[Harvester]",
}
