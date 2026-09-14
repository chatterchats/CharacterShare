-- Character Share v1.0.2
-- Bootstrap only: each factory receives a fresh context for this mod instance.
local VERSION = "1.0.2"
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local directory = assert(source:match("^(.*[/\\])"), "Scripts directory unavailable")
package.path = directory .. "?.lua;" .. package.path

local modules = {
    "common",
    "state",
    "logging",
    "actions",
    "popup",
    "sharing",
    "import_validation",
    "import_dialogs",
    "character_staging",
    "import_workflow",
    "overwrite_workflow",
    "widget_helpers",
    "import_icon",
    "databank_ui",
    "lifecycle",
    "popup_dispatch",
    "button_hooks",
    "debug_hotkeys",
    "startup",
}
-- Reload factories, but let the hook registry retire the preceding instance.
for _, name in ipairs(modules) do package.loaded[name] = nil end
package.loaded["hook_registry"] = nil

local runtime = require("hook_registry").start("CharacterShareRuntime", {
    clear_all = CharacterShareClearDelayedActionsOnReload ~= false,
})
local ctx = { runtime = runtime, config = { VERSION = VERSION, MOD_TAG = "[CharacterShare]" } }
ctx.dependencies = { Codec = require("codec"), Character = require("character"), UI = require("ui") }
for _, name in ipairs(modules) do ctx[name] = {} end
for _, name in ipairs(modules) do require(name)(ctx) end
CharacterShareLayout = ctx.layout
return ctx
