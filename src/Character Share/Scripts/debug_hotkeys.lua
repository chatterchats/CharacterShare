-- Character Share: debug hotkeys.
-- Initialized once per mod instance; shared references use explicit ctx fields.
-- Context: debug_hotkeys, logging, runtime.
return function(ctx)
    ctx.debug_hotkeys.debug_hotkeys_enabled = false

    local function debug_hotkey_state_text()
        if ctx.debug_hotkeys.debug_hotkeys_enabled then
            return "enabled"
        end

        return "disabled"
    end

    local function emit_console_status(output_device, message)
        ctx.logging.log(message)

        if output_device ~= nil then
            pcall(function()
                output_device:Log(message)
            end)
        end
    end

    local function set_debug_hotkeys_enabled(enabled, output_device)
        ctx.debug_hotkeys.debug_hotkeys_enabled = enabled == true

        emit_console_status(
            output_device,
            string.format(
                "Debug hotkeys %s: CTRL+SHIFT+F7 raw JSON, CTRL+SHIFT+F8 ZC1 export, CTRL+SHIFT+F9 Import.",
                debug_hotkey_state_text()
            )
        )
    end

    function ctx.debug_hotkeys.register_debug_hotkey_console_command()
        local ok, err = pcall(function()
            ctx.runtime:register_console(
                "zcs_debug_hotkeys",
                function(full_command, _, output_device)
                    local argument =
                        tostring(full_command or "")
                            :match("^%S+%s*(.-)%s*$")
                            :lower()

                    if argument == "" or argument == "toggle" then
                        set_debug_hotkeys_enabled(
                            not ctx.debug_hotkeys.debug_hotkeys_enabled,
                            output_device
                        )
                    elseif argument == "on"
                        or argument == "1"
                        or argument == "true"
                        or argument == "enable"
                        or argument == "enabled" then
                        set_debug_hotkeys_enabled(true, output_device)
                    elseif argument == "off"
                        or argument == "0"
                        or argument == "false"
                        or argument == "disable"
                        or argument == "disabled" then
                        set_debug_hotkeys_enabled(false, output_device)
                    elseif argument == "status" then
                        emit_console_status(
                            output_device,
                            "Debug hotkeys are "
                                .. debug_hotkey_state_text()
                                .. "."
                        )
                    else
                        emit_console_status(
                            output_device,
                            "Usage: zcs_debug_hotkeys [on|off|status|toggle]"
                        )
                    end

                    return true
                end
            )
        end)

        if not ok then
            ctx.logging.log(
                "WARNING: zcs_debug_hotkeys console command registration failed: "
                    .. tostring(err)
            )
            return false
        end

        ctx.logging.log(
            "Debug hotkeys disabled by default. UE4SS console: zcs_debug_hotkeys [on|off|status|toggle]."
        )
        return true
    end
end
