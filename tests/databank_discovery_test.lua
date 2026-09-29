-- The first entry check may precede construction of the Databank master.
-- UE4SS returns an invalid UObject wrapper here, not necessarily nil.
local scripts = assert(arg[1], "pass the Character Share Scripts directory")
local ctx = { common = {}, popup = {}, widget_helpers = {}, layout = {}, logging = {} }
assert(loadfile(scripts .. "/common.lua"))()(ctx)
assert(loadfile(scripts .. "/widget_helpers.lua"))()(ctx)
local candidate, class_reads = nil, 0
ctx.popup.current_databank_host = function() return candidate end
assert(ctx.widget_helpers.find_live_databank_master() == nil)
candidate = {
    IsValid = function() return false end,
    GetClass = function() class_reads = class_reads + 1; error("native null dereference") end,
}
assert(ctx.widget_helpers.find_live_databank_master() == nil)
assert(class_reads == 0, "invalid wrapper must be rejected BEFORE GetClass")
candidate.IsValid = function() error("stale object") end
assert(ctx.widget_helpers.find_live_databank_master() == nil)
assert(class_reads == 0, "failed validity read must not reach GetClass")

local class_valid, class_name_reads = false, 0
candidate = {
    IsValid = function() return true end,
    GetClass = function()
        class_reads = class_reads + 1
        return {
            IsValid = function() return class_valid end,
            GetFullName = function()
                class_name_reads = class_name_reads + 1
                return "WidgetBlueprintGeneratedClass /Game/Test.WBP_CharacterBank_Master_C"
            end,
        }
    end,
    GetParent = function() return {} end,
    IsVisible = function() return true end,
}
ctx.common.popup_widget_identity = function()
    return "WBP_CharacterBank_Master_C /Engine/Transient.GameEngine_0.TestMaster"
end
assert(ctx.widget_helpers.find_live_databank_master() == nil)
assert(class_name_reads == 0, "invalid class must not reach GetFullName")
class_valid = true
assert(ctx.widget_helpers.find_live_databank_master() == candidate,
    "valid, attached and visible master must remain discoverable")
print("Character Share Databank discovery validity tests passed")
