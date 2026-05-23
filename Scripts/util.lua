-- Small helpers used everywhere: error-swallowing pcalls, validity probes
-- that survive FWeakObjectPtr, player accessors via UEHelpers.

local Config = require("config")

local M = {}

function M.logf(fmt, ...)
    print(string.format(Config.LOG_PREFIX .. " " .. fmt .. "\n", ...))
end

function M.try(fn)
    local ok, r = pcall(fn)
    if ok then return r end
end

function M.is_valid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o.IsValid and o:IsValid() end)
    return ok and v == true
end

local UEHelpers = (function()
    local ok, mod = pcall(require, "UEHelpers")
    if ok and type(mod) == "table" then return mod end
    return {}
end)()

function M.get_pc()
    if UEHelpers.GetPlayerController then
        local pc = M.try(function() return UEHelpers:GetPlayerController() end)
        if M.is_valid(pc) then return pc end
    end
    return M.try(function() return FindFirstOf("PlayerController") end)
end

function M.get_pawn()
    local pc = M.get_pc()
    if not M.is_valid(pc) then return nil end
    return M.try(function() return pc:K2_GetPawn() end)
        or M.try(function() return pc.Pawn end)
end

function M.actor_location(a)
    local loc = M.try(function() return a:K2_GetActorLocation() end)
    if not loc then return nil end
    if type(loc.X) ~= "number" then return nil end
    return loc
end

function M.vec_dist_sq(a, b)
    if not a or not b then return nil end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return dx * dx + dy * dy + dz * dz
end

function M.class_name(actor)
    local ok, v = pcall(function() return actor:GetClass():GetFName():ToString() end)
    if ok and type(v) == "string" and v ~= "" then return v end
    return M.try(function() return actor:GetFullName() end) or "?"
end

-- Returns the player's UWEInventoryRouterComponent. The component is exposed
-- as a UObject property `InventoryRouterComponent` on BP_Character_01_C (and
-- on the SN2PlayerCharacter parent), so a plain field read works.
function M.get_inventory_router(pawn)
    pawn = pawn or M.get_pawn()
    if not M.is_valid(pawn) then return nil end
    local rc = M.try(function() return pawn.InventoryRouterComponent end)
    if M.is_valid(rc) then return rc end
    return nil
end

return M
