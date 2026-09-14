-- Character Share: logging.
-- Initialized once per mod instance; shared references use explicit ctx fields.
-- Context: config, logging, runtime, state.
return function(ctx)
    local function source_log_path()
        if not debug or type(debug.getinfo) ~= "function" then return nil end
        local ok, info = pcall(debug.getinfo, 1, "S")
        if not ok or not info or type(info.source) ~= "string" then return nil end
        local source = info.source:gsub("^@", "")
        local script_dir = source:match("^(.*)[/\\][^/\\]+$")
        if not script_dir then return nil end
        local mod_dir = script_dir:match("^(.*)[/\\][Ss]cripts$") or script_dir
        local separator = source:find("\\", 1, true) and "\\" or "/"
        return mod_dir .. separator .. "character_share.log"
    end

    local function try_open(path)
        if type(path) ~= "string" or path == ""
            or type(io) ~= "table" or type(io.open) ~= "function" then
            return nil
        end
        local ok, handle = pcall(io.open, path, "a")
        if not ok or handle == nil then return nil end
        pcall(function() handle:setvbuf("no") end)
        return handle
    end

    local candidates = {}
    local resolved_source_log = source_log_path()
    if resolved_source_log then candidates[#candidates + 1] = resolved_source_log end
    local fallback_candidates = {
        "ue4ss\\Mods\\Character Share\\character_share.log",
        "ue4ss/Mods/Character Share/character_share.log",
        "ue4ss\\Mods\\CharacterShare\\character_share.log",
        "ue4ss/Mods/CharacterShare/character_share.log",
        "Mods\\Character Share\\character_share.log",
        "Mods/Character Share/character_share.log",
        "character_share.log",
    }
    for _, candidate in ipairs(fallback_candidates) do
        candidates[#candidates + 1] = candidate
    end
    local log_file = nil
    ctx.logging.LOG_PATH = nil
    for _, candidate in ipairs(candidates) do
        local handle = try_open(candidate)
        if handle ~= nil then
            log_file = handle
            ctx.logging.LOG_PATH = candidate
            break
        end
    end

    local function timestamp()
        if type(os) == "table" and type(os.date) == "function" then
            local ok, value = pcall(os.date, "!%Y-%m-%dT%H:%M:%SZ")
            if ok and value then return tostring(value) end
        end
        return "time-unavailable"
    end

    local function generation_context()
        local databank = ctx.state.databank_ui_state
        return string.format(
            "runtime=%s databank=%s import=%s",
            tostring(ctx.runtime.generation or 0),
            tostring(databank and databank.generation or 0),
            tostring(ctx.state.pending_import_navigation_generation or 0)
        )
    end

    function ctx.logging.log(message)
        local line = string.format("%s %s", ctx.config.MOD_TAG, tostring(message))
        print(line .. "\n")
        if log_file then
            pcall(function()
                log_file:write(string.format(
                    "%s [%s] %s\n", timestamp(), generation_context(), line
                ))
                log_file:flush()
            end)
        end
    end

    local workflow_states = {}
    function ctx.logging.transition(workflow, next_state, detail)
        workflow = tostring(workflow or "unknown")
        next_state = tostring(next_state or "unknown")
        local previous = workflow_states[workflow] or "idle"
        workflow_states[workflow] = next_state
        local suffix = detail ~= nil and detail ~= ""
            and ("; " .. tostring(detail):gsub("[\r\n]+", " ")) or ""
        ctx.logging.log(string.format(
            "WORKFLOW TRANSITION: %s %s -> %s%s",
            workflow, previous, next_state, suffix
        ))
    end

    ctx.logging.log("Dedicated Character Share session log opened.")

    local prior_teardown = ctx.runtime.on_teardown
    ctx.runtime.on_teardown = function(reason)
        ctx.logging.transition("runtime", "retired", reason or "teardown")
        if log_file then
            pcall(function() log_file:close() end)
            log_file = nil
        end
        if prior_teardown then prior_teardown(reason) end
    end
end
