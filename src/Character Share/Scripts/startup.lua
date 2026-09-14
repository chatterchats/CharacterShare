-- Character Share: startup.
-- Initialized once per mod instance; shared references use explicit ctx fields.
-- Context: button_hooks, config, debug_hotkeys, layout, lifecycle, logging, popup_dispatch, runtime, sharing, widget_helpers.
return function(ctx)
    ctx.layout.cancel_all_action_groups(
        "mod script reloaded"
    )

    ctx.layout.run_after(0, function() ctx.runtime:cleanup_ui() end)

    ctx.logging.transition("runtime", "loading", "version=" .. ctx.config.VERSION)
    if ctx.logging.LOG_PATH then
        ctx.logging.log("Dedicated log: " .. ctx.logging.LOG_PATH)
    else
        ctx.logging.log(
            "WARNING: dedicated character_share.log could not be opened; diagnostics remain available in UE4SS.log."
        )
    end

    ctx.debug_hotkeys.register_debug_hotkey_console_command()

    ctx.logging.log("Import source: native GenericPopupMessage text-entry field (ZC1 only)")

    -- Do not register BP_OnHideDialog during Lua startup. On a fresh launch,
    -- UE4SS may have the Blueprint class loaded before that Blueprint UFunction has
    -- entered the runtime function map. show_native_dialog() handles registration
    -- lazily and retries after the first popup instance is constructed.
    ctx.logging.log(
        "Native GenericPopupMessage result hook registration deferred until first Character Share dialog."
    )

    ctx.button_hooks.register_databank_click_hook()

    ctx.layout.register_databank_hover_hooks()

    ctx.layout.register_databank_deactivation_hook()

    -- Only probe on same-state reload when the previous instance knew a live
    -- Databank master. A cold start still waits for the native submenu click.
    if ctx.runtime.resume ~= nil then
        ctx.layout.run_group_after("databank_entry_install", 1, function()
            local master = ctx.lifecycle.runtime_databank_master_candidate()
            if ctx.layout.uobject_is_valid(master)
                and ctx.widget_helpers.databank_widget_identity(master) == ctx.runtime.resume then
                ctx.lifecycle.begin_databank_session(master)
            end
            ctx.runtime.resume = nil
        end)
    end

    local json_export_key_ok, json_export_key_err = pcall(function()
        ctx.runtime:register_keybind(Key.F7, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
            if not ctx.debug_hotkeys.debug_hotkeys_enabled then
                return
            end

            ctx.layout.run_after(0, function()
                ctx.sharing.export_selected_character_json()
            end)
        end)
    end)

    if not json_export_key_ok then
        ctx.logging.log(
            "WARNING: JSON export hotkey registration failed: "
                .. tostring(json_export_key_err)
        )
    end

    local export_key_ok, export_key_err = pcall(function()
        ctx.runtime:register_keybind(Key.F8, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
            if not ctx.debug_hotkeys.debug_hotkeys_enabled then
                return
            end

            ctx.layout.run_after(0, function()
                ctx.popup_dispatch.handle_export_key()
            end)
        end)
    end)

    if not export_key_ok then
        ctx.logging.log("WARNING: export hotkey registration failed: " .. tostring(export_key_err))
    end

    local preflight_key_ok, preflight_key_err = pcall(function()
        ctx.runtime:register_keybind(Key.F9, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
            if not ctx.debug_hotkeys.debug_hotkeys_enabled then
                return
            end

            ctx.layout.run_after(0, function()
                ctx.popup_dispatch.handle_import_preflight_key()
            end)
        end)
    end)

    if not preflight_key_ok then
        ctx.logging.log("WARNING: import preflight hotkey registration failed: " .. tostring(preflight_key_err))
    end

    ctx.logging.log(
        "Character Share ready. v" .. ctx.config.VERSION .. ". Deferred work uses UE4SS owned delayed game-thread actions; no legacy async timers or hover polling remain."
    )
    ctx.logging.transition("runtime", "ready", "activation-based Databank discovery")
end
