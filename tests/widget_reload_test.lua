-- Exercise real UI factories; surviving controls must never reach the clone path.
-- Run: luajit tests/widget_reload_test.lua "<Scripts directory>"
local scripts = assert(arg[1])
local function object(name)
    return { name = name, IsValid = function() return true end,
        GetParent = function() return {} end }
end
local button, glyph, overlay = object("button"), object("glyph"), object("overlay")
local function valid(value) return value ~= nil and value:IsValid() end
local function try_call(callback)
    local ok, value = pcall(callback)
    if ok then return value end
    return nil, value
end
for _ = 1, 2 do
    local ctx = {
        runtime = {}, config = {}, state = {}, common = {}, logging = { log = function() end },
        folder_ui = {}, folder_icons = {}, widget_helpers = {}, databank_ui = {},
        layout = {}, dependencies = {},
    }
    ctx.common.try_call = try_call
    ctx.common.unwrap = function(value) return value end
    ctx.common.uobject_is_valid = valid
    ctx.common.object_name = function(value) return value.name end
    ctx.widget_helpers.clone_widget_like = function() error("must not clone a surviving control") end
    if scripts:find("Enhanced", 1, true) then
        assert(loadfile(scripts .. "/state.lua"))()(ctx)
        ctx.widget_helpers.find_tree_widget = function(_, name)
            if name == ctx.state.CREATE_FOLDER_BUTTON_MARKER then return button end
            if name == "EnhancedDatabank_FolderPlusCanvas" then return glyph end
            return overlay
        end
        ctx.folder_icons.style_create_folder_icon_button = function(_, value) assert(value == button) end
        ctx.folder_icons.set_folder_icon_color = function() end
        assert(loadfile(scripts .. "/folder_ui.lua"))()(ctx)
        assert(ctx.folder_ui.ensure_create_folder_control(object("page")))
        assert(ctx.state.folder_ui_state.iconCanvas == glyph)
        assert(ctx.state.folder_ui_state.button == button)
        assert(ctx.state.folder_ui_state.buttons.button)
    else
        ctx.state.databank_ui_state = { buttons = {} }
        ctx.widget_helpers.databank_widget_identity = function(value) return value.name end
        ctx.widget_helpers.set_databank_button_text = function(value) assert(value == button) end
        ctx.layout.uobject_is_valid = valid
        ctx.layout.find_widget = function(_, name)
            if name:find("Button", 1, true) then return button end
            if name:find("Canvas", 1, true) then return glyph end
            return overlay
        end
        ctx.layout.set_clone_label = function(value, label) assert(value == button and label == "") end
        ctx.layout.hide_single_clone_image = function(value) assert(value == button) end
        ctx.layout.initialize_share_visual = function(value) assert(value == button) end
        ctx.layout.create_user_widget_like = ctx.widget_helpers.clone_widget_like
        assert(loadfile(scripts .. "/databank_ui.lua"))()(ctx)
        local state = {}
        assert(ctx.databank_ui.install_import_button(object("page"), state))
        assert(ctx.state.databank_ui_state.buttons.button.action == "databank_import")
        assert(ctx.state.databank_ui_state.buttons.button.iconCanvas == glyph)
        assert(ctx.databank_ui.install_share_button(object("page"), state))
        assert(ctx.state.databank_ui_state.buttons.button.action == "databank_share")
        assert(state.importInstalled and state.shareInstalled and state.shareButton == button)
    end
end
print("widget reload adoption tests passed")
