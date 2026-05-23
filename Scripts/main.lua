-- Flora Resonator — main.lua
-- ─────────────────────────────────────────────────────────────────────────
-- Extends the Sonic Resonator: when the orb pops it auto-harvests every
-- flora pickup-able actor inside the burst radius, plus triggers a full
-- "cuttable" break on multitool-style plants (one shot = all drops).
--
-- Flow per Sonic Resonator burst:
--   1. Hook BP_SonicBubbleProjectile_C:Pop. Inside the callback, extract
--      the orb's location SYNCHRONOUSLY — UE4SS's `self` hook param is
--      only valid for the duration of this callback; touching it from a
--      deferred block crashes the game.
--   2. Defer to the next game-thread tick with plain Lua numbers.
--   3. Run two probes at the pop location:
--        • FindAllOf("SN2PickupItem")       — hand-pickup items (E key)
--        • FindAllOf("Actor") + IsActorCuttable — multitool plants
--   4. Both paths gate on:
--        a) UWEPlantGrowerComponent growth % (covers plants that grow
--           in place, e.g. Freesia)
--        b) world-space slot dedup with TTL (covers fruit-on-parent
--           plants like Necrolei/Cherimoya where a fresh fruit spawns
--           at the same slot a second after harvest)
--   5. Pickups go through router:PickupActor staggered; cuttables
--      spawn N copies of ResourceClass + destroy the source, then pick
--      up the spawned drops.
--
-- Keys (configurable in config.lua):
--   • F7 — manual dump (no shot fired)
--   • F8 — toggle EnablePickup on/off mid-game

local Config = require("config")
local U      = require("util")

-- ── State ────────────────────────────────────────────────────────────────

local mapGen          = 0
local isShuttingDown  = false
local hookInstalled   = false
local enablePickup    = Config.EnablePickup == true

-- Pop debounce: timestamp of the last Pop we accepted. Each Pop call fires
-- our hook twice (pre/post execution), so we ignore the second within
-- PopDebounceMs of the first.
local lastPopMs       = 0

-- Cached SN2Statics CDO. Many of the helpers we need (IsActorCuttable,
-- GetCuttableDataForActor, SpawnItemWithImpulse, PlayerPickupActor) live
-- on /Script/Subnautica2.SN2Statics — a UFunction library. Calling any
-- static UFunction goes through the CDO so we resolve it once and cache.
local sn2StaticsCdo   = nil

local function get_sn2_statics()
    if U.is_valid(sn2StaticsCdo) then return sn2StaticsCdo end
    local c = U.try(function()
        return StaticFindObject("/Script/Subnautica2.Default__SN2Statics")
    end)
    if U.is_valid(c) then sn2StaticsCdo = c; return c end
    c = U.try(function() return FindFirstOf("SN2Statics") end)
    if U.is_valid(c) then sn2StaticsCdo = c; return c end
    return nil
end

-- Cached vanilla SonicBubblePopRadius from the projectile's CDO. We read it
-- once (lazily) and reuse it — Permafrost and similar mods inflate the live
-- projectile's field, but the CDO stays at the game's natural value.
local vanillaRadius   = nil

local function get_vanilla_radius()
    if type(vanillaRadius) == "number" and vanillaRadius > 0 then
        return vanillaRadius
    end
    local cdo = U.try(function()
        return StaticFindObject(
            "/Game/Blueprints/Items/Tools/Resonator/BP_SonicBubbleProjectile.Default__BP_SonicBubbleProjectile_C")
    end)
    if U.is_valid(cdo) then
        local r = U.try(function() return cdo.SonicBubblePopRadius end)
        if type(r) == "number" and r > 0 then
            vanillaRadius = r
            U.logf("vanilla SonicBubblePopRadius (CDO) = %.0f", r)
            return r
        end
    end
    return nil
end

-- Cross-burst dedup: key (actor full-name) -> expiry timestamp in ms.
-- Skip any pickup whose key is still present and not expired. Cleared
-- lazily during scans so we don't need a background timer.
local pickedRecent    = {}

-- World-space dedup: array of { x, y, z, expiry } recording recently
-- harvested points. Catches the case where the game respawns a fresh
-- fruit/plant at the same slot 1–2s after we harvested it — no actor
-- match, but the location is identical. See HarvestLocRadiusCm /
-- HarvestLocTtlMs in config.
local recentLocs      = {}

local function now_ms()
    return math.floor(os.clock() * 1000)
end

local function actor_key(actor)
    -- GetFullName is stable per UObject instance; tostring(actor) also works
    -- but FullName is more readable in logs if we ever need to dump.
    local k = U.try(function() return actor:GetFullName() end)
    if type(k) == "string" and k ~= "" then return k end
    return tostring(actor)
end

local function dedup_remember(actor)
    local k = actor_key(actor)
    pickedRecent[k] = now_ms() + (Config.PickDedupMs or 3000)
end

local function dedup_is_picked(actor)
    local k = actor_key(actor)
    local exp = pickedRecent[k]
    if not exp then return false end
    if now_ms() >= exp then
        pickedRecent[k] = nil
        return false
    end
    return true
end

local function dedup_gc()
    local t = now_ms()
    for k, exp in pairs(pickedRecent) do
        if t >= exp then pickedRecent[k] = nil end
    end
    for i = #recentLocs, 1, -1 do
        if t >= recentLocs[i].expiry then table.remove(recentLocs, i) end
    end
end

local function remember_loc(loc)
    if not loc or type(loc.X) ~= "number" then return end
    table.insert(recentLocs, {
        x = loc.X, y = loc.Y, z = loc.Z,
        expiry = now_ms() + (Config.HarvestLocTtlMs or 60000),
    })
end

local function loc_is_recent(loc)
    if not loc or type(loc.X) ~= "number" then return false end
    local r2 = (Config.HarvestLocRadiusCm or 30) ^ 2
    if r2 <= 0 then return false end
    local t = now_ms()
    for i = #recentLocs, 1, -1 do
        local rl = recentLocs[i]
        if t >= rl.expiry then
            table.remove(recentLocs, i)
        else
            local dx, dy, dz = loc.X - rl.x, loc.Y - rl.y, loc.Z - rl.z
            if dx*dx + dy*dy + dz*dz <= r2 then return true end
        end
    end
    return false
end

-- ── Common helpers ───────────────────────────────────────────────────────

local function safe_class_name(actor)
    local cn = U.try(function() return actor:GetClass():GetFName():ToString() end)
    if type(cn) == "string" and cn ~= "" then return cn end
    return "?"
end

-- ── Plant growth gate ────────────────────────────────────────────────────

-- Cached UClass for UWEPlantGrowerComponent. Used to find that component
-- on an actor via GetComponentByClass. GrowBed-grown actors have one;
-- wild plants don't.
local plantGrowerClass = nil

local function get_plant_grower_class()
    if U.is_valid(plantGrowerClass) then return plantGrowerClass end
    local c = U.try(function()
        return StaticFindObject("/Script/UWEFarming.UWEPlantGrowerComponent")
    end)
    if U.is_valid(c) then plantGrowerClass = c end
    return c
end

-- True if `actor` is ready to harvest. Returns true for actors without a
-- UWEPlantGrowerComponent (we treat "no grower = always ready" so that
-- wild flora keeps working). For actors with a grower, gates on
-- GetGrowthPercentage >= Config.MinGrowthPct (defaults to 1.0).
local function plant_ready(actor)
    if (Config.MinGrowthPct or 0) <= 0 then return true end
    local cls = get_plant_grower_class()
    if not U.is_valid(cls) then return true end
    local grower = U.try(function() return actor:GetComponentByClass(cls) end)
    if not U.is_valid(grower) then return true end
    -- Prefer the float so we can show % in the log; fall back to the bool.
    local pct = U.try(function() return grower:GetGrowthPercentage() end)
    if type(pct) == "number" then
        return pct >= (Config.MinGrowthPct or 1.0), pct
    end
    local grown = U.try(function() return grower:IsFullyGrown() end)
    if grown == nil then return true end
    return grown == true
end

-- ── Discovery: SN2PickupItem ─────────────────────────────────────────────

local function scan_pickups(center, radius)
    local hits = {}
    if not center or not radius then return hits end
    local r2 = radius * radius
    local all = U.try(function() return FindAllOf("SN2PickupItem") end)
    if not all then return hits end
    for _, a in pairs(all) do
        if U.is_valid(a) then
            local loc = U.actor_location(a)
            if loc then
                local d2 = U.vec_dist_sq(center, loc)
                if d2 and d2 <= r2 then
                    if loc_is_recent(loc) then
                        U.dlogf("  -PICK skip %s (recently harvested at this slot)",
                            safe_class_name(a))
                    else
                        local ready, pct = plant_ready(a)
                        if ready then
                            -- Stash loc so schedule_pickups can record it
                            -- after a successful pickup (the actor may be
                            -- invalidated by then).
                            table.insert(hits, { actor = a, dist2 = d2, loc = loc })
                        else
                            U.dlogf("  -PICK skip %s (growth %.0f%%)",
                                safe_class_name(a), (pct or 0) * 100)
                        end
                    end
                end
            end
        end
    end
    table.sort(hits, function(x, y) return x.dist2 < y.dist2 end)
    return hits
end

-- ── Cuttable scan + harvest ──────────────────────────────────────────────

-- Iterate every Actor in range and ask SN2Statics:IsActorCuttable for each.
-- More expensive than the SN2PickupItem probe (no narrow class filter on
-- the FindAllOf side), but the distance gate filters most of them out
-- before we make the UFunction call.
local function scan_cuttables(center, radius)
    local hits = {}
    if not center or not radius then return hits end
    local sn2 = get_sn2_statics()
    if not sn2 then return hits end
    local r2 = radius * radius
    local all = U.try(function() return FindAllOf("Actor") end)
    if not all then return hits end
    for _, a in pairs(all) do
        if U.is_valid(a) then
            local loc = U.actor_location(a)
            if loc then
                local d2 = U.vec_dist_sq(center, loc)
                if d2 and d2 <= r2 then
                    local ok = false
                    pcall(function() ok = sn2:IsActorCuttable(a) end)
                    if ok == true then
                        if loc_is_recent(loc) then
                            U.dlogf("  -CUT  skip %s (recently harvested at this slot)",
                                safe_class_name(a))
                        else
                            local ready, pct = plant_ready(a)
                            if ready then
                                table.insert(hits, { actor = a, dist2 = d2 })
                            else
                                U.dlogf("  -CUT  skip %s (growth %.0f%%)",
                                    safe_class_name(a), (pct or 0) * 100)
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(hits, function(x, y) return x.dist2 < y.dist2 end)
    return hits
end

-- Cached KismetSystemLibrary CDO. LoadClassAsset_Blocking lives here and is
-- the canonical UE way to resolve a TSoftClassPtr synchronously.
local kismetSysLibCdo = nil

local function get_kismet_sys_lib()
    if U.is_valid(kismetSysLibCdo) then return kismetSysLibCdo end
    local c = U.try(function()
        return StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    end)
    if U.is_valid(c) then kismetSysLibCdo = c; return c end
    c = U.try(function() return FindFirstOf("KismetSystemLibrary") end)
    if U.is_valid(c) then kismetSysLibCdo = c; return c end
    return nil
end

local kismetMathLibCdo = nil

local function get_kismet_math_lib()
    if U.is_valid(kismetMathLibCdo) then return kismetMathLibCdo end
    local c = U.try(function()
        return StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    end)
    if U.is_valid(c) then kismetMathLibCdo = c; return c end
    c = U.try(function() return FindFirstOf("KismetMathLibrary") end)
    if U.is_valid(c) then kismetMathLibCdo = c; return c end
    return nil
end

-- Build an FTransform at `actor`'s current location. We use the canonical
-- KismetMathLibrary:MakeTransform UFunction because direct
-- actor:GetActorTransform() returns nothing in UE4SS Lua (struct return is
-- consumed somewhere). Falls back to a plain Lua-table FTransform if even
-- MakeTransform is unavailable — UE4SS marshals tables to structs by name.
local function build_actor_transform(actor)
    local loc = U.try(function() return actor:K2_GetActorLocation() end)
    if not loc or type(loc.X) ~= "number" then return nil end
    local rot = U.try(function() return actor:K2_GetActorRotation() end)
        or { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }
    local scale = { X = 1.0, Y = 1.0, Z = 1.0 }

    local kml = get_kismet_math_lib()
    if U.is_valid(kml) then
        local t
        pcall(function() t = kml:MakeTransform(loc, rot, scale) end)
        if t then return t end
    end

    -- Fallback: plain table with FTransform field names. Rotation here is a
    -- FQuat (identity) because FTransform stores rotation as quat, not
    -- FRotator. UE4SS may or may not marshal this — but it's a free shot.
    return {
        Translation = { X = loc.X, Y = loc.Y, Z = loc.Z },
        Rotation    = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
        Scale3D     = scale,
    }
end

-- SoftClassPtr → loaded UClass. Tries multiple paths and logs which one
-- worked (or what state we ended up in) so we can iterate when something
-- doesn't load. Primary path is KismetSystemLibrary:LoadClassAsset_Blocking,
-- the canonical UE blocking loader for TSoftClassPtr.
local function resolve_soft_class(soft, label)
    if soft == nil then
        U.dlogf("    soft class is nil (%s)", label or "?")
        return nil
    end

    -- 1. KismetSystemLibrary:LoadClassAsset_Blocking — preferred.
    local ksl = get_kismet_sys_lib()
    if U.is_valid(ksl) then
        local c
        pcall(function() c = ksl:LoadClassAsset_Blocking(soft) end)
        if U.is_valid(c) then return c end
    end

    -- 2. Direct TSoftClassPtr methods (covers UE4SS exposing them as Lua
    --    instance methods on the userdata).
    local c = U.try(function() return soft:LoadSynchronous() end)
    if U.is_valid(c) then return c end
    c = U.try(function() return soft:Get() end)
    if U.is_valid(c) then return c end

    -- 3. String path → StaticFindObject (works if asset is already loaded).
    local path = U.try(function() return soft:ToString() end)
    if type(path) == "string" and path ~= "" then
        c = U.try(function() return StaticFindObject(path) end)
        if U.is_valid(c) then return c end
    end

    -- Diagnostic: dump what little we know so we can iterate.
    U.dlogf("    soft class unresolved (%s) repr=%s path=%s",
        label or "?", tostring(soft), tostring(path))
    return nil
end

local function read_cuttable_info(actor, sn2)
    local data = U.try(function() return sn2:GetCuttableDataForActor(actor) end)
    if not U.is_valid(data) then return nil, 1, nil, nil end
    local hits = U.try(function() return data.NumHitsToBreak end)
    if type(hits) ~= "number" or hits < 1 then hits = 1 end
    local res_soft = U.try(function() return data.ResourceClass end)
    local class_label = U.try(function() return actor:GetClass():GetFName():ToString() end) or "?"
    local res_cls  = resolve_soft_class(res_soft, class_label)
    local res_name = res_cls and U.try(function() return res_cls:GetFName():ToString() end) or "?"
    return data, hits, res_cls, res_name
end

-- Trigger a full cuttable break: spawn NumHitsToBreak copies of ResourceClass
-- at the actor's transform, route each into the player's inventory, then
-- destroy the cuttable. This bypasses the damage-on-hit flow entirely —
-- we don't need to know the right multitool damage tag.
local function harvest_one_cuttable(cuttable, pawn, router, sn2)
    if not U.is_valid(cuttable) then return false end
    local cn = safe_class_name(cuttable)

    local data, n_hits, res_cls, res_name = read_cuttable_info(cuttable, sn2)
    if not data then
        U.dlogf("  -CUT  %s (no CuttableData)", cn)
        return false
    end
    if not U.is_valid(res_cls) then
        U.dlogf("  -CUT  %s (could not resolve ResourceClass, hits=%d)", cn, n_hits)
        return false
    end

    local transform = build_actor_transform(cuttable)
    if not transform then
        U.dlogf("  -CUT  %s (no transform — K2_GetActorLocation failed)", cn)
        return false
    end

    -- Small upward impulse so dropped items don't immediately clip terrain.
    local impulse = { X = 0.0, Y = 0.0, Z = 100.0 }
    local spawned = {}
    for _ = 1, n_hits do
        local item
        pcall(function()
            item = sn2:SpawnItemWithImpulse(pawn, res_cls, transform, impulse)
        end)
        if U.is_valid(item) then
            table.insert(spawned, item)
            dedup_remember(item)
        end
    end

    U.dlogf("  +CUT  %s spawned=%d/%d resource=%s", cn, #spawned, n_hits, res_name)

    -- Remember the cuttable itself (FullName) AND the world location.
    -- FullName covers the case where DestroyActor hasn't propagated yet
    -- and the same actor shows up in the next scan. Location covers the
    -- fruit-on-parent case (Necrolei, Cherimoya) where the parent spawns
    -- a fresh actor at the same slot a second later — different actor,
    -- different FullName, same location.
    dedup_remember(cuttable)
    do
        local hloc = U.actor_location(cuttable)
        if hloc then remember_loc(hloc) end
    end
    pcall(function() cuttable:K2_DestroyActor() end)

    -- Pick each spawned item up after a short delay, staggered so the
    -- inventory side doesn't see N simultaneous PickupActor RPCs.
    for i, item in ipairs(spawned) do
        local capturedGen = mapGen
        ExecuteWithDelay(80 * i, function()
            ExecuteInGameThread(function()
                if isShuttingDown or capturedGen ~= mapGen then return end
                if U.is_valid(item) then
                    pcall(function() router:PickupActor(item, {}) end)
                end
            end)
        end)
    end

    return true
end

local function schedule_cuttable_harvest(cuttables, pawn, router, sn2, gen)
    local stagger = Config.CuttableStaggerMs or 80
    local cap     = Config.MaxCuttablesPerBurst or 0
    local total   = (cap > 0 and math.min(cap, #cuttables)) or #cuttables
    local done    = 0
    local skipped = 0

    local function step(i)
        if isShuttingDown or gen ~= mapGen then return end
        if i > total then
            U.logf("cuttable burst done: harvested=%d skipped=%d (of %d)", done, skipped, total)
            return
        end
        local c = cuttables[i]
        if c and U.is_valid(c.actor) then
            if dedup_is_picked(c.actor) then
                skipped = skipped + 1
                U.dlogf("  -CUT  %s (dedup, d=%.0f)", safe_class_name(c.actor), math.sqrt(c.dist2))
            elseif harvest_one_cuttable(c.actor, pawn, router, sn2) then
                done = done + 1
            else
                skipped = skipped + 1
            end
        else
            skipped = skipped + 1
        end

        if stagger <= 0 then
            step(i + 1)
        else
            ExecuteWithDelay(stagger, function()
                ExecuteInGameThread(function() step(i + 1) end)
            end)
        end
    end

    step(1)
end

-- ── Extra diagnostic probes (only when Config.ExtraProbes = true) ───────

local function probe_all_actors(center, r2)
    local hits = {}
    local all = U.try(function() return FindAllOf("Actor") end)
    if not all then return hits end
    for _, a in pairs(all) do
        if U.is_valid(a) then
            local loc = U.actor_location(a)
            if loc then
                local d2 = U.vec_dist_sq(center, loc)
                if d2 and d2 <= r2 then table.insert(hits, { actor = a, dist2 = d2 }) end
            end
        end
    end
    return hits
end

local function probe_interface(center, r2)
    local hits = {}
    local interface = U.try(function()
        return StaticFindObject("/Script/UWEInterfaces.UWEInventoryItemInterface")
    end)
    if not U.is_valid(interface) then return hits end
    local gps = U.try(function() return StaticFindObject("/Script/Engine.Default__GameplayStatics") end)
    if not U.is_valid(gps) then return hits end
    local pawn = U.get_pawn()
    if not U.is_valid(pawn) then return hits end
    local out = {}
    local ok = pcall(function() gps:GetAllActorsWithInterface(pawn, interface, out) end)
    if not ok then return hits end
    for _, a in pairs(out) do
        if U.is_valid(a) then
            local loc = U.actor_location(a)
            if loc then
                local d2 = U.vec_dist_sq(center, loc)
                if d2 and d2 <= r2 then table.insert(hits, { actor = a, dist2 = d2 }) end
            end
        end
    end
    return hits
end

local function log_class_tally(label, hits, extra)
    local by_class, total = {}, 0
    for _, h in ipairs(hits) do
        local cn = safe_class_name(h.actor)
        by_class[cn] = (by_class[cn] or 0) + 1
        total = total + 1
    end
    local rows = {}
    for cn, n in pairs(by_class) do table.insert(rows, { cn = cn, n = n }) end
    table.sort(rows, function(a, b) return a.n > b.n end)
    U.logf("%s: %d actor(s)%s", label, total, extra and (" " .. extra) or "")
    local cap = Config.MaxLogPerScan or 30
    for i, r in ipairs(rows) do
        if cap > 0 and i > cap then
            U.logf("  ...(+%d more classes)", #rows - cap)
            break
        end
        U.logf("  ×%d  %s", r.n, r.cn)
    end
end

-- ── Pickup ───────────────────────────────────────────────────────────────

-- Try to pick up a single actor. Returns true on success. All UE calls
-- are pcall-wrapped so one bad actor never breaks the rest of the burst.
local function try_pickup(router, actor)
    if not U.is_valid(router) or not U.is_valid(actor) then return false end
    local hit = {}  -- zero-filled FHitResult — fine for synthetic pickups
    local ok = pcall(function() router:PickupActor(actor, hit) end)
    return ok
end

-- Schedule pickups staggered across game-thread ticks. We keep no weak refs
-- — by the time a delayed pickup runs the actor may have been destroyed by
-- a previous pickup in the same burst, so we re-check is_valid every time.
local function schedule_pickups(router, hits, gen)
    local stagger = Config.PickupStaggerMs or 0
    local cap     = Config.MaxPerBurst or 0
    local picked  = 0
    local failed  = 0
    local total   = (cap > 0 and math.min(cap, #hits)) or #hits

    local function step(i)
        if isShuttingDown or gen ~= mapGen then return end
        if i > total then
            U.logf("burst done: picked=%d failed=%d (of %d)", picked, failed, total)
            return
        end
        local h = hits[i]
        if h and U.is_valid(h.actor) then
            local cn = safe_class_name(h.actor)
            if dedup_is_picked(h.actor) then
                failed = failed + 1
                U.dlogf("  -DUP   %s (recently picked, d=%.0f)", cn, math.sqrt(h.dist2))
            elseif try_pickup(router, h.actor) then
                picked = picked + 1
                dedup_remember(h.actor)
                -- Use the loc captured at scan time — the actor may already
                -- be invalidated by PickupActor by this point.
                if h.loc then remember_loc(h.loc) end
                U.dlogf("  +PICK %s (d=%.0f)", cn, math.sqrt(h.dist2))
            else
                failed = failed + 1
                U.dlogf("  -FAIL %s (pcall errored)", cn)
            end
        else
            failed = failed + 1
            U.dlogf("  -GONE  (actor invalid)")
        end

        if stagger <= 0 then
            step(i + 1)
        else
            ExecuteWithDelay(stagger, function()
                ExecuteInGameThread(function() step(i + 1) end)
            end)
        end
    end

    step(1)
end

-- ── Per-burst handler ────────────────────────────────────────────────────

local function on_burst(center, radius, toolName, playerLoc)
    -- One-line tag identifying which resonator fired and how far the pop
    -- happened from the player. V1 fires the orb at the player's hand and
    -- pops close; V2 lobs it and pops far. Behavior differences (cuttable
    -- silently failing, pickups getting ejected) correlate with version.
    local distStr = "?"
    if playerLoc then
        local d2 = U.vec_dist_sq(center, playerLoc)
        if d2 then distStr = string.format("%.0f", math.sqrt(d2)) end
    end
    U.logf("Pop: tool=%s pop@(%.0f,%.0f,%.0f) playerDist=%s r=%.0f",
        tostring(toolName or "?"), center.X, center.Y, center.Z, distStr, radius)

    -- Pickup probe (SN2PickupItem — proven path)
    local hits = scan_pickups(center, radius)
    log_class_tally(string.format("Pop @ r=%.0f", radius), hits)

    -- Cuttable probe (UWECuttable — multitool-style plants)
    local cuttables = scan_cuttables(center, radius)
    if #cuttables > 0 then
        log_class_tally("Pop [Cuttable]", cuttables)
    end

    if Config.ExtraProbes then
        local r2 = radius * radius
        log_class_tally("Pop [Actor]",     probe_all_actors(center, r2))
        log_class_tally("Pop [Interface]", probe_interface(center, r2))
    end

    if not enablePickup then
        U.dlogf("EnablePickup=false — no pickup attempted (toggle with PickupToggleKey)")
        return
    end

    if #hits == 0 and #cuttables == 0 then return end

    local pawn = U.get_pawn()
    if not U.is_valid(pawn) then U.logf("burst: no pawn"); return end
    local router = U.get_inventory_router(pawn)
    if not U.is_valid(router) then U.logf("burst: no InventoryRouterComponent"); return end

    if #hits > 0 then
        schedule_pickups(router, hits, mapGen)
    end

    if Config.EnableCuttable and #cuttables > 0 then
        local sn2 = get_sn2_statics()
        if sn2 then
            schedule_cuttable_harvest(cuttables, pawn, router, sn2, mapGen)
        else
            U.dlogf("EnableCuttable=true but SN2Statics CDO unavailable")
        end
    end
end

-- ── Pop hook ─────────────────────────────────────────────────────────────

local POP_PATH =
    "/Game/Blueprints/Items/Tools/Resonator/BP_SonicBubbleProjectile.BP_SonicBubbleProjectile_C:Pop"

-- The UE4SS `self` hook param is only valid synchronously inside this
-- callback. We extract location & radius as plain Lua numbers first, then
-- defer the heavy work. Never touch `self` from inside ExecuteInGameThread.
local function on_pop_sync(self)
    if isShuttingDown then return end

    -- Pop debounce. UE4SS RegisterHook fires our callback twice per Pop
    -- call (pre/post execution). The two calls land ~20ms apart, so any
    -- debounce above ~50ms collapses them while staying well below human
    -- rate of fire.
    local t = now_ms()
    if t - lastPopMs < (Config.PopDebounceMs or 500) then
        U.dlogf("Pop suppressed (within debounce, dt=%dms)", t - lastPopMs)
        return
    end
    lastPopMs = t

    local cx, cy, cz
    local toolName, playerLoc
    pcall(function()
        local proj = self:get()
        if not (proj and proj:IsValid()) then return end
        local loc = proj:K2_GetActorLocation()
        if loc and type(loc.X) == "number" then cx, cy, cz = loc.X, loc.Y, loc.Z end
        -- Capture the firing tool's class so logs distinguish V1 from V2.
        -- Must be done sync while `self` is valid — defer-then-read would
        -- read stale memory.
        local owner = U.try(function() return proj:GetOwner() end)
        if U.is_valid(owner) then
            toolName = U.try(function() return owner:GetClass():GetFName():ToString() end)
        end
    end)

    if not cx then return end

    -- Capture player location too, so the burst log can show how far the
    -- pop happened from the player (V1 pops close, V2 pops far).
    do
        local pawn = U.get_pawn()
        if U.is_valid(pawn) then
            local pl = U.actor_location(pawn)
            if pl then playerLoc = pl end
        end
    end

    -- Radius priority: explicit override → CDO vanilla → fallback.
    -- Deliberately ignore proj.SonicBubblePopRadius because Permafrost &
    -- friends mutate that field on the live projectile.
    local radius
    if (Config.RadiusOverride or 0) > 0 then
        radius = Config.RadiusOverride
    else
        radius = get_vanilla_radius() or (Config.FallbackRadius or 250.0)
    end

    dedup_gc()

    local capturedGen = mapGen
    ExecuteWithDelay(0, function()
        ExecuteInGameThread(function()
            if isShuttingDown or capturedGen ~= mapGen then return end
            on_burst({ X = cx, Y = cy, Z = cz }, radius, toolName, playerLoc)
        end)
    end)
end

local function register_pop_hook()
    local ok, err = pcall(function()
        RegisterHook(POP_PATH, function(self) on_pop_sync(self) end)
    end)
    if ok then
        U.logf("hooked %s", POP_PATH)
    else
        U.logf("FAILED to hook Pop: %s", tostring(err))
    end
end

local function try_install_pop_hook(attempt, gen)
    attempt = attempt or 1
    gen     = gen or mapGen
    if isShuttingDown or gen ~= mapGen or hookInstalled then return end
    local cls = U.try(function()
        return StaticFindObject(
            "/Game/Blueprints/Items/Tools/Resonator/BP_SonicBubbleProjectile.BP_SonicBubbleProjectile_C")
    end)
    if U.is_valid(cls) then
        register_pop_hook()
        hookInstalled = true
        return
    end
    if attempt >= 60 then
        U.logf("gave up waiting for BP_SonicBubbleProjectile class after %d tries", attempt)
        return
    end
    ExecuteWithDelay(1000, function()
        ExecuteInGameThread(function() try_install_pop_hook(attempt + 1, gen) end)
    end)
end

-- ── V1 blast hook ────────────────────────────────────────────────────────
-- V1 (BP_SonicResonator_C) does NOT spawn BP_SonicBubbleProjectile_C — it
-- triggers a close-range blast via a GameplayCue (no traveling projectile).
-- (V2 / Upgraded uses GC_SonicResonator_SecondaryBlast and the projectile
-- path, so the two don't collide.)
--
-- Hook target: `GameplayCueNotify_Static:OnExecute` — the cue manager's
-- one-shot dispatch entry. UWE's `OnBurst` (one level closer to the BP)
-- looked promising but never fires here; OnExecute is the real entry.
-- This catches EVERY one-shot cue in the game, so we filter by class
-- FName on the cue notify instance.
--
-- V1 is close-range so the player's location is a fine approximation of
-- the blast center — no need to extract precise coords from cue params.
-- We share `lastPopMs` with the Pop hook so V2 doesn't double-trigger if
-- it happens to fire a SonicResonator cue too.

-- The cue notify dispatch (OnExecute/OnActive on GameplayCueNotify_*)
-- isn't hookable for this class — GC_SonicResonator_Blast_C has no
-- UFunctions and the C++ side reads its struct properties directly
-- without a ProcessEvent call. So we hook UPSTREAM of the cue notify:
-- the AbilitySystemComponent's NetMulticast_InvokeGameplayCueExecuted
-- RPCs, which carry the GameplayCueTag (FGameplayTag struct with a
-- TagName FName).
--
-- The expected tag for V1's blast follows UE's convention of mapping
-- a cue notify class GC_X_Y_Z_C to tag GameplayCue.X.Y.Z. Diagnostic
-- logging surfaces the actual tag if the convention differs.

-- Cue tag confirmed by in-game probe: `GameplayCue.Tools.SonicResonator.Blast`
-- fires when V1's close-range blast goes off. (The `.Tools.` namespace is
-- the SN2 grouping convention — not the bare `GameplayCue.SonicResonator.*`
-- we initially guessed.)
local V1_BLAST_TAG = "GameplayCue.Tools.SonicResonator.Blast"
local v1HookInstalled = false

local function on_v1_blast_sync(self, GameplayCueTag)
    if isShuttingDown then return end
    if not (Config.EnableV1Hook == true) then return end

    -- Extract tag name. UE4SS hands FGameplayTag as a LocalUnrealParam
    -- userdata — direct field access works after pcall. Keep a couple of
    -- fallbacks in case a future build changes the binding shape.
    local tagName
    pcall(function() tagName = GameplayCueTag.TagName:ToString() end)
    if not tagName then
        pcall(function() tagName = GameplayCueTag:get().TagName:ToString() end)
    end
    if not tagName or tagName == "" then return end

    if tagName ~= V1_BLAST_TAG then return end

    -- Share debounce with the Pop path. UE4SS often fires hooks twice
    -- (pre/post); a shared window also suppresses an accidental V2 cue
    -- firing right after its own Pop.
    local t = now_ms()
    if t - lastPopMs < (Config.PopDebounceMs or 500) then
        U.dlogf("V1 blast suppressed (within debounce, dt=%dms)", t - lastPopMs)
        return
    end
    lastPopMs = t

    -- Player location = burst center. V1 is close-range.
    local cx, cy, cz
    do
        local pawn = U.get_pawn()
        if not U.is_valid(pawn) then return end
        local loc = U.actor_location(pawn)
        if not loc then return end
        cx, cy, cz = loc.X, loc.Y, loc.Z
    end

    local radius = (Config.V1Radius and Config.V1Radius > 0)
        and Config.V1Radius
        or 350.0

    dedup_gc()

    local capturedGen = mapGen
    local playerLoc   = { X = cx, Y = cy, Z = cz }
    ExecuteWithDelay(0, function()
        ExecuteInGameThread(function()
            if isShuttingDown or capturedGen ~= mapGen then return end
            on_burst(playerLoc, radius, "V1_Blast", playerLoc)
        end)
    end)
end

-- Multiple cue dispatch entry points. We don't know which one V1 uses;
-- hook each with a distinct `src` tag so the diagnostic shows which path
-- actually fires.
-- Hook the ASC's RPC dispatch points. Each carries a GameplayCueTag (or
-- container) we can read from the Lua callback args. Different SN2 paths
-- may use different overloads — register all three with `src` tags.
local V1_HOOK_PATHS = {
    { path = "/Script/GameplayAbilities.AbilitySystemComponent:NetMulticast_InvokeGameplayCueExecuted_WithParams", src = "ASC:Cue+Params" },
    { path = "/Script/GameplayAbilities.AbilitySystemComponent:NetMulticast_InvokeGameplayCueExecuted",            src = "ASC:Cue"        },
    { path = "/Script/GameplayAbilities.AbilitySystemComponent:NetMulticast_InvokeGameplayCueExecuted_FromSpec",   src = "ASC:CueFromSpec"},
}

local function register_v1_blast_hook()
    for _, h in ipairs(V1_HOOK_PATHS) do
        local ok, err = pcall(function()
            -- UE4SS Lua hook arg unpacking: (self, arg1, arg2, ...). For
            -- these RPCs the first arg is the FGameplayTag.
            RegisterHook(h.path, function(self, GameplayCueTag)
                on_v1_blast_sync(self, GameplayCueTag)
            end)
        end)
        if ok then
            U.logf("hooked %s (src=%s)", h.path, h.src)
        else
            U.logf("FAILED hook %s: %s", h.path, tostring(err))
        end
    end
    U.logf("V1 cue tag diag active (target tag: %s)", V1_BLAST_TAG)
end

local function try_install_v1_blast_hook(attempt, gen)
    attempt = attempt or 1
    gen     = gen or mapGen
    if isShuttingDown or gen ~= mapGen or v1HookInstalled then return end
    if not (Config.EnableV1Hook == true) then return end
    -- AbilitySystemComponent is native (GAS module), always loaded early.
    local cls = U.try(function()
        return StaticFindObject("/Script/GameplayAbilities.AbilitySystemComponent")
    end)
    if U.is_valid(cls) then
        register_v1_blast_hook()
        v1HookInstalled = true
        return
    end
    if attempt >= 60 then
        U.logf("gave up waiting for AbilitySystemComponent after %d tries", attempt)
        return
    end
    ExecuteWithDelay(1000, function()
        ExecuteInGameThread(function() try_install_v1_blast_hook(attempt + 1, gen) end)
    end)
end

-- ── Map lifecycle ────────────────────────────────────────────────────────

pcall(function()
    RegisterLoadMapPreHook(function() isShuttingDown = true end)
end)

RegisterLoadMapPostHook(function()
    package.loaded["config"] = nil
    Config       = require("config")
    enablePickup = Config.EnablePickup == true

    isShuttingDown   = true
    mapGen           = mapGen + 1
    hookInstalled    = false
    v1HookInstalled  = false
    lastPopMs        = 0
    pickedRecent     = {}
    recentLocs       = {}
    isShuttingDown   = false

    try_install_pop_hook(1, mapGen)
    try_install_v1_blast_hook(1, mapGen)
end)

-- ── Manual dump ─────────────────────────────────────────────────────────

local function manual_dump()
    local pawn = U.get_pawn()
    if not U.is_valid(pawn) then U.logf("dump: no pawn"); return end
    local loc = U.actor_location(pawn)
    if not loc then U.logf("dump: no pawn location"); return end
    local radius = (Config.RadiusOverride or 0) > 0
        and Config.RadiusOverride
        or (Config.FallbackRadius or 600.0)

    local hits = scan_pickups(loc, radius)
    log_class_tally(string.format("Dump @ r=%.0f", radius), hits)

    local cuttables = scan_cuttables(loc, radius)
    if #cuttables > 0 then
        log_class_tally("Dump [Cuttable]", cuttables)
        -- Also surface the per-actor CuttableData so we can read NumHitsToBreak
        -- and ResourceClass without firing the resonator.
        local sn2 = get_sn2_statics()
        if sn2 then
            local cap = Config.MaxLogPerScan or 30
            for i, c in ipairs(cuttables) do
                if cap > 0 and i > cap then break end
                local _, n, _, res = read_cuttable_info(c.actor, sn2)
                U.logf("  d=%.0f %s hits=%d resource=%s",
                    math.sqrt(c.dist2), safe_class_name(c.actor), n, tostring(res))
            end
        end
    end

    if Config.ExtraProbes then
        local r2 = radius * radius
        log_class_tally("Dump [Actor]",     probe_all_actors(loc, r2))
        log_class_tally("Dump [Interface]", probe_interface(loc, r2))
    end
end

do
    local keyName = Config.DebugDumpKey or ""
    if keyName ~= "" then
        local keyEnum = Key[keyName]
        if keyEnum then
            pcall(function()
                RegisterKeyBind(keyEnum, function()
                    ExecuteInGameThread(function() manual_dump() end)
                end)
            end)
            U.logf("debug dump key: %s", keyName)
        else
            U.logf("unknown DebugDumpKey %q — skipping", tostring(keyName))
        end
    end
end

do
    local keyName = Config.PickupToggleKey or ""
    if keyName ~= "" then
        local keyEnum = Key[keyName]
        if keyEnum then
            pcall(function()
                RegisterKeyBind(keyEnum, function()
                    enablePickup = not enablePickup
                    U.logf("EnablePickup = %s (toggled via %s)", tostring(enablePickup), keyName)
                end)
            end)
            U.logf("pickup toggle key: %s", keyName)
        else
            U.logf("unknown PickupToggleKey %q — skipping", tostring(keyName))
        end
    end
end

U.logf("loaded v%s — EnablePickup=%s (toggle: %s)",
    Config.VERSION, tostring(enablePickup),
    Config.PickupToggleKey ~= "" and Config.PickupToggleKey or "config only")
try_install_pop_hook(1, mapGen)
try_install_v1_blast_hook(1, mapGen)
