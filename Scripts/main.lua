
local Config = require("config")
local U      = require("util")


local mapGen          = 0
local isShuttingDown  = false
local hookInstalled   = false

local lastPopMs       = 0

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
            return r
        end
    end
    return nil
end

local pickedRecent    = {}

local recentLocs      = {}

local function now_ms()
    return math.floor(os.clock() * 1000)
end

local function actor_key(actor)
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


local plantGrowerClass = nil

local function get_plant_grower_class()
    if U.is_valid(plantGrowerClass) then return plantGrowerClass end
    local c = U.try(function()
        return StaticFindObject("/Script/UWEFarming.UWEPlantGrowerComponent")
    end)
    if U.is_valid(c) then plantGrowerClass = c end
    return c
end

local function plant_ready(actor)
    if (Config.MinGrowthPct or 0) <= 0 then return true end
    local cls = get_plant_grower_class()
    if not U.is_valid(cls) then return true end
    local grower = U.try(function() return actor:GetComponentByClass(cls) end)
    if not U.is_valid(grower) then return true end
    local pct = U.try(function() return grower:GetGrowthPercentage() end)
    if type(pct) == "number" then
        return pct >= (Config.MinGrowthPct or 1.0), pct
    end
    local grown = U.try(function() return grower:IsFullyGrown() end)
    if grown == nil then return true end
    return grown == true
end


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
                if d2 and d2 <= r2 and not loc_is_recent(loc) and plant_ready(a) then
                    table.insert(hits, { actor = a, dist2 = d2, loc = loc })
                end
            end
        end
    end
    table.sort(hits, function(x, y) return x.dist2 < y.dist2 end)
    return hits
end


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
                if d2 and d2 <= r2 and not loc_is_recent(loc) then
                    local ok = false
                    pcall(function() ok = sn2:IsActorCuttable(a) end)
                    if ok and plant_ready(a) then
                        table.insert(hits, { actor = a, dist2 = d2 })
                    end
                end
            end
        end
    end
    table.sort(hits, function(x, y) return x.dist2 < y.dist2 end)
    return hits
end

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

    return {
        Translation = { X = loc.X, Y = loc.Y, Z = loc.Z },
        Rotation    = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
        Scale3D     = scale,
    }
end

local function resolve_soft_class(soft)
    if soft == nil then return nil end

    local ksl = get_kismet_sys_lib()
    if U.is_valid(ksl) then
        local c
        pcall(function() c = ksl:LoadClassAsset_Blocking(soft) end)
        if U.is_valid(c) then return c end
    end

    local c = U.try(function() return soft:LoadSynchronous() end)
    if U.is_valid(c) then return c end
    c = U.try(function() return soft:Get() end)
    if U.is_valid(c) then return c end

    local path = U.try(function() return soft:ToString() end)
    if type(path) == "string" and path ~= "" then
        c = U.try(function() return StaticFindObject(path) end)
        if U.is_valid(c) then return c end
    end

    return nil
end

local function read_cuttable_info(actor, sn2)
    local data = U.try(function() return sn2:GetCuttableDataForActor(actor) end)
    if not U.is_valid(data) then return nil, 1, nil end
    local hits = U.try(function() return data.NumHitsToBreak end)
    if type(hits) ~= "number" or hits < 1 then hits = 1 end
    local res_soft = U.try(function() return data.ResourceClass end)
    local res_cls  = resolve_soft_class(res_soft)
    return data, hits, res_cls
end

local function harvest_one_cuttable(cuttable, pawn, router, sn2)
    if not U.is_valid(cuttable) then return false end

    local data, n_hits, res_cls = read_cuttable_info(cuttable, sn2)
    if not data then return false end
    if not U.is_valid(res_cls) then return false end

    local transform = build_actor_transform(cuttable)
    if not transform then return false end

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

    dedup_remember(cuttable)
    do
        local hloc = U.actor_location(cuttable)
        if hloc then remember_loc(hloc) end
    end
    pcall(function() cuttable:K2_DestroyActor() end)

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

    local function step(i)
        if isShuttingDown or gen ~= mapGen then return end
        if i > total then return end
        local c = cuttables[i]
        if c and U.is_valid(c.actor) and not dedup_is_picked(c.actor) then
            harvest_one_cuttable(c.actor, pawn, router, sn2)
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


local function try_pickup(router, actor)
    if not U.is_valid(router) or not U.is_valid(actor) then return false end
    local hit = {}
    local ok = pcall(function() router:PickupActor(actor, hit) end)
    return ok
end

local function schedule_pickups(router, hits, gen)
    local stagger = Config.PickupStaggerMs or 0
    local cap     = Config.MaxPerBurst or 0
    local total   = (cap > 0 and math.min(cap, #hits)) or #hits

    local function step(i)
        if isShuttingDown or gen ~= mapGen then return end
        if i > total then return end
        local h = hits[i]
        if h and U.is_valid(h.actor) and not dedup_is_picked(h.actor) then
            if try_pickup(router, h.actor) then
                dedup_remember(h.actor)
                if h.loc then remember_loc(h.loc) end
            end
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


local function on_burst(center, radius)
    if not Config.EnablePickup then return end

    local hits      = scan_pickups(center, radius)
    local cuttables = scan_cuttables(center, radius)
    if #hits == 0 and #cuttables == 0 then return end

    local pawn = U.get_pawn()
    if not U.is_valid(pawn) then return end
    local router = U.get_inventory_router(pawn)
    if not U.is_valid(router) then return end

    if #hits > 0 then
        schedule_pickups(router, hits, mapGen)
    end

    if Config.EnableCuttable and #cuttables > 0 then
        local sn2 = get_sn2_statics()
        if sn2 then
            schedule_cuttable_harvest(cuttables, pawn, router, sn2, mapGen)
        end
    end
end


local POP_PATH =
    "/Game/Blueprints/Items/Tools/Resonator/BP_SonicBubbleProjectile.BP_SonicBubbleProjectile_C:Pop"

local function on_pop_sync(self)
    if isShuttingDown then return end

    local t = now_ms()
    if t - lastPopMs < (Config.PopDebounceMs or 500) then return end
    lastPopMs = t

    local cx, cy, cz
    pcall(function()
        local proj = self:get()
        if not (proj and proj:IsValid()) then return end
        local loc = proj:K2_GetActorLocation()
        if loc and type(loc.X) == "number" then cx, cy, cz = loc.X, loc.Y, loc.Z end
    end)

    if not cx then return end

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
            on_burst({ X = cx, Y = cy, Z = cz }, radius)
        end)
    end)
end

local function register_pop_hook()
    local ok, err = pcall(function()
        RegisterHook(POP_PATH, function(self) on_pop_sync(self) end)
    end)
    if ok then
        U.logf("V2 hook installed")
    else
        U.logf("FAILED to install V2 hook: %s", tostring(err))
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
    if attempt >= 60 then return end
    ExecuteWithDelay(1000, function()
        ExecuteInGameThread(function() try_install_pop_hook(attempt + 1, gen) end)
    end)
end



local V1_BLAST_TAG = "GameplayCue.Tools.SonicResonator.Blast"
local v1HookInstalled = false

local function on_v1_blast_sync(self, GameplayCueTag)
    if isShuttingDown then return end
    if not (Config.EnableV1Hook == true) then return end

    local tagName
    pcall(function() tagName = GameplayCueTag.TagName:ToString() end)
    if not tagName then
        pcall(function() tagName = GameplayCueTag:get().TagName:ToString() end)
    end
    if not tagName or tagName == "" then return end

    if tagName ~= V1_BLAST_TAG then return end

    local t = now_ms()
    if t - lastPopMs < (Config.PopDebounceMs or 500) then return end
    lastPopMs = t

    local pawn = U.get_pawn()
    if not U.is_valid(pawn) then return end
    local loc = U.actor_location(pawn)
    if not loc then return end
    local center = { X = loc.X, Y = loc.Y, Z = loc.Z }

    local radius = (Config.V1Radius and Config.V1Radius > 0)
        and Config.V1Radius
        or 350.0

    dedup_gc()

    local capturedGen = mapGen
    ExecuteWithDelay(0, function()
        ExecuteInGameThread(function()
            if isShuttingDown or capturedGen ~= mapGen then return end
            on_burst(center, radius)
        end)
    end)
end

local V1_HOOK_PATH =
    "/Script/GameplayAbilities.AbilitySystemComponent:NetMulticast_InvokeGameplayCueExecuted_WithParams"

local function register_v1_blast_hook()
    local ok, err = pcall(function()
        RegisterHook(V1_HOOK_PATH, function(self, GameplayCueTag)
            on_v1_blast_sync(self, GameplayCueTag)
        end)
    end)
    if ok then
        U.logf("V1 hook installed")
    else
        U.logf("FAILED to install V1 hook: %s", tostring(err))
    end
end

local function try_install_v1_blast_hook(attempt, gen)
    attempt = attempt or 1
    gen     = gen or mapGen
    if isShuttingDown or gen ~= mapGen or v1HookInstalled then return end
    if not (Config.EnableV1Hook == true) then return end
    local cls = U.try(function()
        return StaticFindObject("/Script/GameplayAbilities.AbilitySystemComponent")
    end)
    if U.is_valid(cls) then
        register_v1_blast_hook()
        v1HookInstalled = true
        return
    end
    if attempt >= 60 then return end
    ExecuteWithDelay(1000, function()
        ExecuteInGameThread(function() try_install_v1_blast_hook(attempt + 1, gen) end)
    end)
end


pcall(function()
    RegisterLoadMapPreHook(function() isShuttingDown = true end)
end)

RegisterLoadMapPostHook(function()
    package.loaded["config"] = nil
    Config       = require("config")

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

U.logf("v%s loaded", Config.VERSION)
try_install_pop_hook(1, mapGen)
try_install_v1_blast_hook(1, mapGen)
