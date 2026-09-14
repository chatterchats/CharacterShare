-- Run from repository root: luajit tests/logging_test.lua "src/Character Share/Scripts"
local scripts = assert(arg[1], "pass the mod Scripts directory")
local writes, console = {}, {}
local closed, prior_teardown = false, false
local original_open, original_print = io.open, print

io.open = function(path, mode)
    assert(path:match("character_share%.log$") and mode == "a")
    return {
        setvbuf = function() end,
        write = function(_, value) writes[#writes + 1] = value end,
        flush = function() end,
        close = function() closed = true end,
    }
end
print = function(value) console[#console + 1] = value end

local ctx = {
    config = { MOD_TAG = "[CharacterShare]" },
    logging = {},
    runtime = {
        generation = 7,
        on_teardown = function(reason)
            assert(reason == "test")
            prior_teardown = true
        end,
    },
    state = {
        databank_ui_state = { generation = 11 },
        pending_import_navigation_generation = 13,
    },
}
assert(loadfile(scripts .. "/logging.lua"))()(ctx)
ctx.logging.transition("import", "validating", "line one\nline two")
ctx.logging.log("hello")
ctx.runtime.on_teardown("test")

io.open, print = original_open, original_print
local output = table.concat(writes)
assert(ctx.logging.LOG_PATH and ctx.logging.LOG_PATH:match("character_share%.log$"))
assert(output:find("runtime=7 databank=11 import=13", 1, true))
assert(output:find("WORKFLOW TRANSITION: import idle -> validating; line one line two", 1, true))
assert(output:find("[CharacterShare] hello", 1, true))
assert(#console >= 3 and closed and prior_teardown)
print("dedicated logging and workflow transition tests passed")
