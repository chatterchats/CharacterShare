-- Character Share: actions.
-- Initialized once per mod instance; shared references use explicit ctx fields.
-- Context: common, layout, logging, runtime.
return function(ctx)
    if type(ExecuteInGameThreadWithDelay) ~= "function"
        or type(MakeActionHandle) ~= "function"
        or type(CancelDelayedAction) ~= "function"
        or type(IsValidDelayedActionHandle) ~= "function"
        or type(IsDelayedActionActive) ~= "function" then
        error(
            "Character Share requires the UE4SS delayed game-thread action system"
        )
    end

    ctx.layout = { actionGroups = {}, runtime = ctx.runtime }

    function ctx.layout.uobject_is_valid(value)
        local object =
            ctx.common.unwrap_hook_value(value)

        if object == nil then
            return false
        end

        local valid, valid_err =
            ctx.common.try_call(function()
                return object:IsValid()
            end)

        return valid_err == nil
            and valid == true
    end

    function ctx.layout.popup_context_uobjects_valid(context)
        if type(context) ~= "table" then
            return true
        end

        for _, match in ipairs(context.matches or {}) do
            if type(match) == "table"
                and match.vm ~= nil
                and not ctx.layout
                    .uobject_is_valid(match.vm) then
                return false
            end
        end

        return true
    end

    function ctx.layout.cancel_action_group(
        group,
        reason
    )
        local actions =
            ctx.layout.actionGroups[group]

        if actions == nil then
            return 0
        end

        ctx.layout.actionGroups[group] = nil

        local cancelled = 0
        local active = 0

        for handle in pairs(actions) do
            local valid =
                select(
                    1,
                    ctx.common.try_call(function()
                        return IsValidDelayedActionHandle(handle)
                    end)
                )

            local is_active =
                select(
                    1,
                    ctx.common.try_call(function()
                        return IsDelayedActionActive(handle)
                    end)
                )

            if is_active == true then
                active = active + 1
            end

            if valid == true then
                local did_cancel =
                    select(
                        1,
                        ctx.common.try_call(function()
                            return CancelDelayedAction(handle)
                        end)
                    )

                if did_cancel == true then
                    cancelled = cancelled + 1
                    ctx.runtime:finish_action(handle)
                end
            end
        end

        if cancelled > 0 then
            ctx.logging.log(
                string.format(
                    "Cancelled delayed-action group '%s': cancelled=%d active=%d reason=%s",
                    tostring(group),
                    cancelled,
                    active,
                    tostring(reason or "session ended")
                )
            )
        end

        return cancelled
    end

    function ctx.layout.cancel_all_action_groups(reason)
        local groups = {}

        for group in pairs(ctx.layout.actionGroups) do
            table.insert(groups, group)
        end

        local cancelled = 0

        for _, group in ipairs(groups) do
            cancelled =
                cancelled
                + ctx.layout.cancel_action_group(
                    group,
                    reason
                )
        end

        return cancelled
    end

    function ctx.layout.schedule_after(
        group,
        delay_ms,
        callback,
        ...
    )
        local runtime = ctx.runtime
        if not runtime.alive then return nil end
        local captured_count =
            select("#", ...)

        local captured_uobjects = {
            ...,
        }

        local handle = MakeActionHandle()
        local actions = nil

        if group ~= nil then
            actions =
                ctx.layout.actionGroups[group]
                    or {}
            ctx.layout.actionGroups[group] =
                actions
            actions[handle] = true
        end

        local function invoke()
            runtime:finish_action(handle)
            if not runtime.alive then return end
            if actions ~= nil then
                actions[handle] = nil

                if next(actions) == nil
                    and ctx.layout.actionGroups[group]
                        == actions then
                    ctx.layout.actionGroups[group] = nil
                end
            end

            for index = 1, captured_count do
                if not ctx.layout
                    .uobject_is_valid(
                        captured_uobjects[index]
                    ) then
                    ctx.logging.log(
                        "Skipped delayed action: captured UObject #"
                            .. tostring(index)
                            .. " is no longer valid."
                    )
                    return
                end
            end

            callback()
        end

        runtime:track_action(handle)
        ExecuteInGameThreadWithDelay(
            handle,
            math.max(0, tonumber(delay_ms) or 0),
            invoke
        )
        return handle
    end

    function ctx.layout.run_after(
        delay_ms,
        callback,
        ...
    )
        return ctx.layout.schedule_after(
            nil,
            delay_ms,
            callback,
            ...
        )
    end

    function ctx.layout.run_group_after(
        group,
        delay_ms,
        callback,
        ...
    )
        return ctx.layout.schedule_after(
            group,
            delay_ms,
            callback,
            ...
        )
    end
end
