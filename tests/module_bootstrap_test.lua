-- Load every production factory through main.lua, then repeat same-state reload.
-- Run: luajit tests/module_bootstrap_test.lua "<Scripts directory>"
-- LuaJIT stubs codec (Lua 5.3 bit operators); Lua 5.4 loads every real helper.
local scripts = assert(arg[1])
package.path = scripts .. "/?.lua;" .. package.path
if _VERSION == "Lua 5.1" then package.loaded.codec = {} end
local hooks, keys, commands, queue, cancelled = {}, {}, {}, {}, {}
local next_id, unregister_count, clear_count = 0, 0, 0
function RegisterHook(path, pre, post)
    assert(hooks[path] == nil, "duplicate hook: " .. path)
    next_id = next_id + 2
    hooks[path] = { pre = pre, post = post, pre_id = next_id - 1, post_id = next_id }
    return next_id - 1, next_id
end
function UnregisterHook(path, pre, post)
    local hook = assert(hooks[path], "unknown hook")
    assert(hook.pre_id == pre and hook.post_id == post)
    hooks[path] = nil
    unregister_count = unregister_count + 1
end
function RegisterKeyBind(key, modifiers, callback)
    local name = key .. ":" .. table.concat(modifiers, ",")
    assert(not keys[name], "duplicate keybind")
    keys[name] = callback
end
function RegisterConsoleCommandHandler(name, callback)
    assert(not commands[name], "duplicate console command")
    commands[name] = callback
end
Key = { F7 = 7, F8 = 8, F9 = 9 }
ModifierKey = { CONTROL = 1, SHIFT = 2 }
function MakeActionHandle() next_id = next_id + 1; return next_id end
function ExecuteInGameThreadWithDelay(handle, delay, callback)
    assert(type(handle) == "number" and type(delay) == "number")
    queue[handle] = callback
end
RetriggerableExecuteInGameThreadWithDelay = ExecuteInGameThreadWithDelay
function CancelDelayedAction(handle) cancelled[handle] = true; return true end
function IsValidDelayedActionHandle(handle) return not cancelled[handle] end
IsDelayedActionActive = IsValidDelayedActionHandle
function ClearAllDelayedActions() clear_count = clear_count + 1; return 0 end
function FindFirstOf() return nil end
function FindAllOf() return {} end
function StaticFindObject() return nil end
function FName(value) return value end
function FText(value) return value end
-- Do not create a production log while exercising the real logging factory.
local original_open, original_print = io.open, print
io.open = function() return nil, "disabled by test" end
local logs = {}
print = function(line) logs[#logs + 1] = tostring(line) end
local first = assert(loadfile(scripts .. "/main.lua"))()
assert(type(first) == "table" and first.runtime.alive)
local hook_count = 0
for _ in pairs(hooks) do hook_count = hook_count + 1 end
assert(hook_count > 0, "startup must register hooks")
local old_queue = queue
queue = {}
local second = assert(loadfile(scripts .. "/main.lua"))()
assert(not first.runtime.alive and second.runtime.alive)
assert(first.state ~= second.state and first.popup ~= second.popup)
assert(first.common.try_call ~= second.common.try_call, "factories must be fresh on reload")
assert(unregister_count == hook_count)
for handle in pairs(first.runtime.actions) do error("retired action retained: " .. handle) end
for handle, callback in pairs(old_queue) do
    assert(cancelled[handle], "pending work not cancelled")
    callback() -- Dispatched-before-teardown callbacks must be harmless.
end
-- Run only this snapshot of the current queue, never an unbounded retry loop.
local initial_queue = queue
queue = {}
for _, callback in pairs(initial_queue) do callback() end
assert(second.runtime.alive)
if second.layout then
    assert(CharacterShareLayout == second.layout)
    assert(second.layout ~= first.layout)
    assert(type(second.state.ensure_native_dialog_result_hook) == "function")
    assert(type(second.state.handle_native_dialog_result) == "function")
    assert(next(second.import_workflow) ~= nil)
else
    assert(EnhancedDatabankActions == second.actions.api)
    assert(second.state.folder_ui_state ~= first.state.folder_ui_state)
    assert(type(second.state.show_move_character_dialog) == "function")
end
second.runtime:teardown("test complete")
for _, line in ipairs(logs) do
    assert(not line:find("attempt to", 1, true), line)
end
io.open, print = original_open, original_print
assert(clear_count == 4, "startup and teardown each clear current-mod actions")
print("module bootstrap, wiring, and same-state reload tests passed (" .. hook_count .. " hooks)")
