-- Run from repository root: luajit tests/reload_runtime_test.lua "<Scripts directory>"
local scripts = assert(arg[1], "pass the mod Scripts directory")
local Runtime = assert(loadfile(scripts .. "/hook_registry.lua"))()
local hooks, cancelled, keys, consoles = {}, {}, {}, {}
local clear_count, next_id = 0, 0
local fail_unregister = false
function RegisterHook(path, pre, post)
    next_id = next_id + 2
    hooks[path] = { pre_id = next_id - 1, post_id = next_id, pre = pre, post = post }
    return next_id - 1, next_id
end
function UnregisterHook(path, pre_id, post_id)
    if fail_unregister then error("mock unregistration failure") end
    local hook = assert(hooks[path])
    assert(hook.pre_id == pre_id and hook.post_id == post_id, "both IDs must match")
    hooks[path] = nil
end
function CancelDelayedAction(handle) cancelled[handle] = true; return true end
function ClearAllDelayedActions() clear_count = clear_count + 1; return 0 end
function RegisterKeyBind(key, modifiers, callback)
    assert(keys[key] == nil, "keybind duplicated")
    keys[key] = callback
end
function RegisterConsoleCommandHandler(name, callback)
    assert(consoles[name] == nil, "console command duplicated")
    consoles[name] = callback
end

local first = Runtime.start("TestRuntime", { clear_all = false })
local calls, cleaned = 0, 0
local pre, post = first:register_hook("/Script/Test:Event", function() calls = calls + 1 end)
local again_pre, again_post = first:register_hook("/Script/Test:Event", function() error("duplicate") end)
assert(pre == again_pre and post == again_post)
local stale = hooks["/Script/Test:Event"].pre
stale()
assert(calls == 1)
first:register_keybind(7, {}, function() calls = calls + 10 end)
first:register_console("test", function() return "old" end)
first:track_action(10)
first:track_action(11)
first:finish_action(11)
first.ui_cleanup = function() cleaned = cleaned + 1 end

local second = Runtime.start("TestRuntime", { clear_all = false })
assert(not first.alive and second.alive)
assert(hooks["/Script/Test:Event"] == nil and cancelled[10] and not cancelled[11])
assert(cleaned == 0, "UI cleanup must wait for game-thread execution")
second:cleanup_ui()
second:cleanup_ui()
assert(cleaned == 1)
stale()
keys[7]()
assert(calls == 1, "callbacks from a retired runtime must be inert")
second:register_keybind(7, {}, function() calls = calls + 100 end)
second:register_console("test", function() return "new" end)
keys[7]()
assert(calls == 101 and consoles.test() == "new")
assert(clear_count == 0, "optional blanket cleanup must respect configuration")

second:register_hook("/Script/Test:Retry", function() end)
fail_unregister = true
local ok = pcall(Runtime.start, "TestRuntime")
assert(not ok and not second.alive and second.hooks["/Script/Test:Retry"])
fail_unregister = false
local third = Runtime.start("TestRuntime")
assert(third.alive and hooks["/Script/Test:Retry"] == nil and clear_count == 1)

-- Exercise the actual production scheduler with a mock engine queue.
local queue = {}
function MakeActionHandle() next_id = next_id + 1; return next_id end
function ExecuteInGameThreadWithDelay(handle, delay, callback)
    assert(type(handle) == "number" and type(delay) == "number")
    queue[handle] = callback
end
function IsValidDelayedActionHandle(handle) return not cancelled[handle] end
IsDelayedActionActive = IsValidDelayedActionHandle
local ctx = {
    runtime = third, actions = {}, config = { PREFIX = "[test]" },
    logging = { log = function() end },
    common = {
        unwrap_hook_value = function(value) return value end,
        uobject_is_valid = function(value) return value ~= nil and value:IsValid() end,
        try_call = function(callback)
            local ok, value = pcall(callback)
            if ok then return value end
            return nil, value
        end,
    },
}
assert(loadfile(scripts .. "/actions.lua"))()(ctx)
local schedule = (ctx.layout or ctx.actions.api).schedule_after
local fired = 0
local handle = schedule("session", 1, function() fired = fired + 1 end, { IsValid = function() return true end })
assert(third.actions[handle])
queue[handle]()
assert(fired == 1 and third.actions[handle] == nil)
local invalid = schedule(nil, 1, function() error("invalid capture executed") end, nil)
queue[invalid]()
assert(third.actions[invalid] == nil)
local pending = schedule(nil, 1, function() error("retired callback executed") end)
third:teardown("test")
queue[pending]() -- Simulate a callback already dispatched when cancellation ran.
assert(cancelled[pending])
print("reload runtime and scheduler tests passed")
