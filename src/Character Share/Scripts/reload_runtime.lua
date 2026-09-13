-- Per-mod ownership for same-state script reloads. UE4SS also cleans up when
-- destroying a Lua state; persistent widgets must still be adopted by name.
local M = {}

function M.start(key, options)
    options = options or {}
    assert(type(UnregisterHook) == "function", "UE4SS UnregisterHook is required")
    local previous = rawget(_G, key)
    if previous then previous:teardown("script reload") end

    local self = {
        alive = true, hooks = {}, actions = {},
        bindings = previous and previous.bindings or {},
        pending_ui = previous and previous.pending_ui or {},
        resume = previous and previous.resume or nil,
        clear_all = options.clear_all ~= false,
    }

    function self:guard(callback)
        return function(...)
            if self.alive then return callback(...) end
        end
    end

    function self:register_hook(path, pre, post)
        assert(self.alive, "cannot register a hook after teardown")
        -- A partial lazy installation may retry an already installed path.
        local prior = self.hooks[path]
        if prior then return prior.pre_id, prior.post_id end
        local pre_id, post_id = RegisterHook(path, self:guard(pre),
            post and self:guard(post) or nil)
        assert(pre_id ~= nil and post_id ~= nil,
            "RegisterHook must return both IDs for " .. path)
        self.hooks[path] = { path = path, pre_id = pre_id, post_id = post_id }
        return pre_id, post_id
    end

    function self:track_action(handle)
        if handle ~= nil then self.actions[handle] = true end
        return handle
    end

    function self:finish_action(handle)
        if handle ~= nil then self.actions[handle] = nil end
    end

    -- Keybind/console registrations do not offer the same hook ID pair.
    -- One persistent dispatcher per binding routes to the current instance.
    function self:bind(id, register, callback)
        local binding = self.bindings[id]
        if binding == nil then
            binding = {}
            register(function(...)
                if binding.callback then return binding.callback(...) end
            end)
            self.bindings[id] = binding
        end
        binding.callback = self:guard(callback)
    end

    function self:register_keybind(keycode, modifiers, callback)
        local parts = { tostring(keycode) }
        for _, modifier in ipairs(modifiers or {}) do
            parts[#parts + 1] = tostring(modifier)
        end
        self:bind("key:" .. table.concat(parts, ":"), function(dispatch)
            RegisterKeyBind(keycode, modifiers, dispatch)
        end, callback)
    end

    function self:register_console(name, callback)
        self:bind("console:" .. name, function(dispatch)
            RegisterConsoleCommandHandler(name, dispatch)
        end, callback)
    end

    function self:cleanup_ui()
        -- Call only from an owned game-thread action after reinitialization.
        local pending = self.pending_ui
        self.pending_ui = {}
        for _, cleanup in ipairs(pending) do
            local ok, err = pcall(cleanup)
            if not ok then print("[" .. key .. "] UI cleanup failed: " .. tostring(err) .. "\n") end
        end
    end

    function self:teardown(reason)
        self.alive = false
        for _, binding in pairs(self.bindings) do binding.callback = nil end
        for handle in pairs(self.actions) do
            local ok = pcall(CancelDelayedAction, handle)
            if ok then self.actions[handle] = nil end
        end
        if self.clear_all and type(ClearAllDelayedActions) == "function" then
            local ok, err = pcall(ClearAllDelayedActions)
            if not ok then error("Delayed-action cleanup failed: " .. tostring(err)) end
        end
        -- Keep failed entries for a later teardown retry. Never silently
        -- register replacements while a native hook could still be installed.
        local failures = {}
        for path, hook in pairs(self.hooks) do
            local ok, err = pcall(UnregisterHook, path, hook.pre_id, hook.post_id)
            if ok then
                self.hooks[path] = nil
            else
                failures[#failures + 1] = path .. ": " .. tostring(err)
            end
        end
        if #failures > 0 then error(table.concat(failures, "\n")) end
        if self.on_teardown then
            local cleanup = self.on_teardown
            self.on_teardown = nil
            cleanup(reason)
        end
        if self.ui_cleanup then
            self.pending_ui[#self.pending_ui + 1] = self.ui_cleanup
            self.ui_cleanup = nil
        end
    end

    -- Current-mod scope only; never clears another mod's actions. Useful when
    -- upgrading from a version which did not retain every action handle.
    if self.clear_all and type(ClearAllDelayedActions) == "function" then
        ClearAllDelayedActions()
    end
    rawset(_G, key, self)
    return self
end

return M
