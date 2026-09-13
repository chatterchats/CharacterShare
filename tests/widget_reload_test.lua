-- Verify surviving controls are adopted before any clone/layout path is reached.
-- Run: luajit tests/widget_reload_test.lua "<Scripts directory>"
local scripts = assert(arg[1])
local file = assert(io.open(scripts .. "/main.lua", "r"))
local main = file:read("*a")
file:close()
local function object(name)
    return { name = name, IsValid = function() return true end,
        GetParent = function() return {} end }
end
local button, glyph, overlay, spacer = object("button"), object("glyph"), object("overlay"), object("spacer")
local registered = 0
local function valid(value) return value ~= nil and value:IsValid() end
local function try_call(callback)
    local ok, value = pcall(callback)
    if ok then return value end
    return nil, value
end
local env = setmetatable({
    log = function() end, try_call = try_call, unwrap = function(value) return value end,
    uobject_is_valid = valid, object_name = function(value) return value.name end,
    register_folder_button = function(value)
        assert(value == button)
        registered = registered + 1
    end,
    style_create_folder_icon_button = function(_, value) assert(value == button) end,
    set_folder_icon_color = function() end,
    CREATE_FOLDER_BUTTON_MARKER = "button",
    find_tree_widget = function(_, name)
        if name == "button" then return button end
        if name == "EnhancedDatabank_FolderPlusCanvas" then return glyph end
        return overlay
    end,
    register_attached_databank_button = function(value)
        assert(value == button)
        registered = registered + 1
    end,
    CharacterShareLayout = {
        uobject_is_valid = valid,
        find_widget = function(_, name)
            if name:find("Button", 1, true) then return button end
            if name:find("Canvas", 1, true) then return glyph end
            return spacer
        end,
        set_clone_label = function(value, text) assert(value == button and text == "") end,
        hide_single_clone_image = function(value) assert(value == button) end,
        initialize_share_visual = function(value) assert(value == button) end,
    },
}, { __index = _G })
local function extract(name, stop)
    local begin_pos = assert(main:find("local function " .. name .. "(", 1, true))
    local end_pos = assert(main:find(stop, begin_pos, true))
    local chunk = assert(loadstring(main:sub(begin_pos, end_pos - 1)
        .. '\nerror("surviving control reached clone path")\nend\nreturn ' .. name))
    setfenv(chunk, env)
    return chunk()
end
if main:find("local function ensure_create_folder_control(", 1, true) then
    local ensure = extract("ensure_create_folder_control", "    local create_new =")
    for _ = 1, 2 do
        env.folder_ui_state = {} -- simulate fresh Lua UI state on every reload
        assert(ensure(object("page")))
        assert(env.folder_ui_state.iconCanvas == glyph)
    end
    assert(registered == 2)
else
    local import = extract("install_import_button", "    local create_new =")
    local share = extract("install_share_button", "    local edit =")
    for _ = 1, 2 do
        local state = {}
        assert(import(object("page"), state))
        assert(share(object("page"), state))
        assert(state.importInstalled and state.shareInstalled and state.shareButton == button)
    end
    assert(registered == 4)
end
print("widget reload adoption tests passed")
