-- Character Share: button hooks.
-- Initialized once per mod instance; shared references use explicit ctx fields.
-- Context: button_hooks, common, import_validation, layout, lifecycle, logging, popup, popup_dispatch, runtime, sharing, state, widget_helpers.
return function(ctx)
    local function handle_databank_button_click(
        button_value
    )
        local button =
            ctx.common.unwrap_hook_value(button_value)

        if button == nil then
            return
        end

        if ctx.popup_dispatch.handle_popup_topnav_action(
            button
        ) then
            return
        end

        -- The Character Databank entry point itself is a
        -- WBP_AnimatedSubMenuListButton_C. Probe that click first.
        ctx.lifecycle.handle_strategy_submenu_click(
            button
        )

        local identity =
            ctx.widget_helpers.databank_widget_identity(button)

        local entry =
            ctx.state.databank_ui_state.buttons[identity]

        if identity ~= nil
            and string.find(
                identity,
                "WBP_CharacterDataBank_TopNavButton_C",
                1,
                true
            ) then
            ctx.logging.log(
                string.format(
                    "Databank TopNav click observed: mapped=%s identity=%s",
                    tostring(entry ~= nil),
                    tostring(identity)
                )
            )
        end

        if entry == nil then
            return
        end

        ctx.logging.log(
            string.format(
                "Databank button clicked: %s -> %s",
                entry.label,
                entry.action
            )
        )

        if entry.action == "databank_import" then
            -- The injected IMPORT control is a cloned native Databank button and,
            -- like WBP_BoundActionButton, still has native click work to finish
            -- after CommonButtonBase:HandleButtonClicked enters this hook. Opening
            -- a pooled CommonUI modal synchronously from that hook was normally
            -- tolerated, but the error-code stress pass eventually crashed inside
            -- UE4SS immediately after IMPORT SESSION and before the popup could be
            -- constructed. Defer the entire modal/session transition one tick so
            -- the native click can unwind first.
            if ctx.state.databank_ui_state.importDispatchPending then
                ctx.logging.log(
                    "Databank IMPORT click ignored: deferred dispatch already pending."
                )
                return
            end

            ctx.state.databank_ui_state.importDispatchPending = true

            local expected_generation =
                ctx.state.databank_ui_state.generation
            local expected_identity = identity

            ctx.logging.log(
                "Databank IMPORT queued until native button click unwinds."
            )

            ctx.layout.run_group_after("import_create", 1, function()
                    ctx.state.databank_ui_state.importDispatchPending = false

                    if expected_generation
                        ~= ctx.state.databank_ui_state.generation then
                        ctx.logging.log(
                            "Databank IMPORT deferred dispatch cancelled: Databank generation changed."
                        )
                        return
                    end

                    local current_entry =
                        ctx.state.databank_ui_state.buttons[
                            expected_identity
                        ]

                    if current_entry == nil
                        or current_entry.action
                            ~= "databank_import" then
                        ctx.logging.log(
                            "Databank IMPORT deferred dispatch cancelled: button mapping is no longer live."
                        )
                        return
                    end

                    if ctx.popup.popup_is_open() then
                        ctx.popup.safe_remove_popup()
                    end

                    ctx.import_validation.clear_pending_import()

                    ctx.logging.log(
                        "Databank IMPORT dispatch after native click unwind."
                    )
                    ctx.logging.log(
                        "IMPORT SESSION: Databank Import button started a fresh session."
                    )

                    ctx.popup.show_import_popup()
            end)
        elseif entry.action == "databank_share" then
            -- WBP_BoundActionButton runs additional native work after
            -- CommonButtonBase:HandleButtonClicked returns. Opening the Character
            -- Share modal from inside this hook changes CommonUI focus/layer state
            -- while that native click is still unwinding; dev versions log reached
            -- EXPORT COMPLETE and then the process died before another Lua line.
            --
            -- Keep the now-correct native-looking SHARE button, but defer the
            -- export/modal work to the next tick so the BoundActionButton click can
            -- finish first. The pending flag prevents a double-click from queuing
            -- two share dialogs during that tiny window.
            if ctx.state.databank_ui_state.shareDispatchPending then
                ctx.logging.log(
                    "Databank SHARE click ignored: deferred dispatch already pending."
                )
                return
            end

            ctx.state.databank_ui_state.shareDispatchPending = true

            local expected_generation =
                ctx.state.databank_ui_state.generation
            local expected_identity = identity

            ctx.logging.log(
                "Databank SHARE queued until native BoundActionButton click unwinds."
            )

            ctx.layout.run_group_after("popup_retirement", 1, function()
                    ctx.state.databank_ui_state.shareDispatchPending = false

                    if expected_generation
                        ~= ctx.state.databank_ui_state.generation then
                        ctx.logging.log(
                            "Databank SHARE deferred dispatch cancelled: Databank generation changed."
                        )
                        return
                    end

                    local current_entry =
                        ctx.state.databank_ui_state.buttons[
                            expected_identity
                        ]

                    if current_entry == nil
                        or current_entry.action
                            ~= "databank_share" then
                        ctx.logging.log(
                            "Databank SHARE deferred dispatch cancelled: button mapping is no longer live."
                        )
                        return
                    end

                    if ctx.popup.popup_is_open() then
                        ctx.popup.safe_remove_popup()
                    end

                    ctx.logging.log(
                        "Databank SHARE dispatch after native click unwind."
                    )

                    ctx.sharing.export_selected_character()
            end)
        end
    end

    function ctx.button_hooks.register_databank_click_hook()
        if ctx.state.databank_button_click_hook_registered then
            return true
        end

        local hook_ok, hook_err = pcall(function()
            ctx.runtime:register_hook(
                "/Script/CommonUI.CommonButtonBase:HandleButtonClicked",
                function(self)
                    handle_databank_button_click(self)
                end
            )
        end)

        if not hook_ok then
            ctx.logging.log(
                "WARNING: Character Databank button click hook failed: "
                    .. tostring(hook_err)
            )
            return false
        end

        ctx.state.databank_button_click_hook_registered = true

        ctx.logging.log(
            "Character Databank button click hook registered."
        )

        return true
    end
end
