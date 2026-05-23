-- Flora Resonator — probe.lua
-- ─────────────────────────────────────────────────────────────────────────
-- Phase 1 reconnaissance for stage-2 (craftable Flora Resonator upgrade).
--
-- Architecture decisions confirmed via UE4SS_ObjectDump.txt grep + peer
-- mod source (Permafrost, ExtraPassiveBiomodSlots):
--
--   • Recipes are UWECraftingRecipe data assets, registered via the
--     UWECrafterComponent.AdditionalAllowedRecipes array on each crafter
--     (Fabricator, ModificationStation, etc.). Append to that array →
--     recipe appears in the station's UI.
--
--   • Crafting completion fires UWECrafterComponent:NotifyCraftingCompleted.
--     Hook it, check the recipe identity, take action.
--
--   • Persistence across saves is handled by the game's built-in
--     UWEEventTracker via GameplayTag (tag, scope) → int. No save-file
--     plumbing needed — write a "PermanentUpgrades.FloraResonator" value
--     and the game persists it.
--
-- This probe READS ONLY — no mutation yet. We just confirm we can reach
-- the crafter component and read its arrays, AND that the EventTracker
-- statics are available. Mutation comes in the next iteration.
--
-- v3 had a crash from a bulk pawn field-shotgun loop. Lesson: per-field
-- pcall isolation. Lesson applied here.

local U = require("util")

local M = {}

-- ── Pop projectile capture (kept from v3) ───────────────────────────────

local pending_capture = false

function M.arm_pop_capture()
    pending_capture = true
    U.logf("[recon] armed: next Pop will dump projectile Owner/Instigator")
end

function M.capture_from_projectile(proj)
    if not pending_capture then return end
    if not U.is_valid(proj) then return end
    pending_capture = false
    U.logf("── CAPTURE: projectile Owner/Instigator on Pop ──")
    local owner = U.try(function() return proj:GetOwner() end)
    if U.is_valid(owner) then
        U.logf("  Owner       = %s", U.try(function() return owner:GetFullName() end) or "?")
        U.logf("  Owner.class = %s",
            U.try(function() return owner:GetClass():GetFullName() end) or "?")
    end
end

-- ── Array reader (handles TArray quirks) ────────────────────────────────
-- TArrays exposed by UE4SS may respond to `#arr` and 1-based indexing,
-- to `:Num()` + zero-based `:Get(i)`, or to neither. Try all forms.

local function array_length(arr)
    local n = U.try(function() return #arr end)
    if type(n) == "number" then return n end
    n = U.try(function() return arr:Num() end)
    if type(n) == "number" then return n end
    n = U.try(function() return arr:GetArrayNum() end)
    if type(n) == "number" then return n end
    return nil
end

local function array_get(arr, i_one_based)
    local v = U.try(function() return arr[i_one_based] end)
    if v ~= nil then return v end
    v = U.try(function() return arr:Get(i_one_based - 1) end)
    if v ~= nil then return v end
    v = U.try(function() return arr:Get(i_one_based) end)
    if v ~= nil then return v end
    return nil
end

local function describe(item)
    if item == nil then return "(nil)" end
    -- SoftObjectPtr → ToString returns the asset path
    local path = U.try(function() return item:ToString() end)
    if type(path) == "string" and path ~= "" then return path end
    -- TSoftObjectPath struct → has AssetPath field
    local ap = U.try(function() return item.AssetPath end)
    if ap then
        local s = U.try(function() return ap:ToString() end)
        if type(s) == "string" and s ~= "" then return s end
    end
    -- UObject → FullName
    local fn = U.try(function() return item:GetFullName() end)
    if type(fn) == "string" and fn ~= "" then return fn end
    return tostring(item)
end

local function dump_array(label, arr, cap)
    cap = cap or 20
    if arr == nil then U.logf("  %s = (nil)", label); return end
    local n = array_length(arr)
    if n == nil then U.logf("  %s = (array, length unreadable)", label); return end
    U.logf("  %s = array, %d entries", label, n)
    for i = 1, math.min(n, cap) do
        local item = array_get(arr, i)
        U.logf("    [%d] %s", i, describe(item))
    end
    if n > cap then U.logf("    ... (+%d more)", n - cap) end
end

-- ── Probe: ModStation UWECrafterComponent ───────────────────────────────

local function find_first_valid(short_class_name)
    local insts = U.try(function() return FindAllOf(short_class_name) end)
    if not insts then return nil end
    for _, x in pairs(insts) do if U.is_valid(x) then return x end end
    return nil
end

local function probe_crafter_component()
    U.logf("── PROBE: ModStation UWECrafterComponent ──")
    local station = find_first_valid("BP_ModificationStation_C")
    if not station then
        U.logf("  no BP_ModificationStation_C found in world")
        return
    end
    U.logf("  station = %s", U.try(function() return station:GetFullName() end) or "?")

    local crafter_class = U.try(function()
        return StaticFindObject("/Script/UWECrafting.UWECrafterComponent")
    end)
    if not U.is_valid(crafter_class) then
        U.logf("  UWECrafterComponent class not loaded yet — skip")
        return
    end

    local crafter = U.try(function()
        return station:GetComponentByClass(crafter_class)
    end)
    if not U.is_valid(crafter) then
        U.logf("  GetComponentByClass returned nothing — trying direct UPROPERTY guesses")
        for _, name in ipairs({ "CrafterComponent", "Crafter", "CraftingComponent" }) do
            local v = U.try(function() return station[name] end)
            if U.is_valid(v) then
                U.logf("  found via station.%s", name)
                crafter = v
                break
            end
        end
    end
    if not U.is_valid(crafter) then
        U.logf("  could not locate crafter component on station")
        return
    end
    U.logf("  crafter = %s", U.try(function() return crafter:GetFullName() end) or "?")

    dump_array("AllowedRecipeCategories",   U.try(function() return crafter.AllowedRecipeCategories end))
    dump_array("AllowedRecipesOverride",    U.try(function() return crafter.AllowedRecipesOverride  end))
    dump_array("AdditionalAllowedRecipes",  U.try(function() return crafter.AdditionalAllowedRecipes end))
end

-- ── Probe: UWEEventTracker reachability ─────────────────────────────────
-- Pattern from ExtraPassiveBiomodSlots. If we can reach the tracker,
-- we have our persistence layer for the "FloraResonatorUnlocked" flag.

local function probe_event_tracker()
    U.logf("── PROBE: UWEEventTracker reachability ──")
    local statics = U.try(function()
        return StaticFindObject("/Script/UWEEventTracker.UWEEventTrackerStatics")
    end)
    if not U.is_valid(statics) then
        U.logf("  UWEEventTrackerStatics not loaded")
        return
    end
    U.logf("  statics = %s",
        U.try(function() return statics:GetClass():GetFullName() end) or "?")

    local getter = U.try(function()
        return StaticFindObject(
            "/Script/UWEEventTracker.UWEEventTrackerStatics:GetLocalPlayerEventTracker")
    end)
    if getter == nil then
        U.logf("  GetLocalPlayerEventTracker function not found")
        return
    end

    local tracker = U.try(function() return getter(statics, statics) end)
    if U.is_valid(tracker) then
        U.logf("  tracker = %s", U.try(function() return tracker:GetFullName() end) or "?")
        U.logf("  tracker.class = %s",
            U.try(function() return tracker:GetClass():GetFullName() end) or "?")
    else
        U.logf("  getter returned invalid tracker (player not loaded yet?)")
    end
end

-- ── Public entry point ──────────────────────────────────────────────────

function M.dump()
    U.logf("════════ RECON DUMP START ════════")
    pcall(probe_crafter_component)
    pcall(probe_event_tracker)
    M.arm_pop_capture()
    U.logf("════════ RECON DUMP END ════════")
end

return M
