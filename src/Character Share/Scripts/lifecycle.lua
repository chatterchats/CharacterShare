-- Character Share: lifecycle.
-- Initialized once per mod instance; shared references use explicit ctx fields.
-- Context: common, databank_ui, layout, lifecycle, logging, popup, runtime, state, widget_helpers.
return function(ctx)
    local function leave_databank_session(reason)
        -- Zero Company reuses the same Character Databank widget instance when the
        -- player backs out and later re-enters it. Therefore the injected children
        -- remain in that WidgetTree too.
        --
        -- Preserve the string action mappings + per-page installed flags here.
        -- Clearing them would cause a second set of IMPORT/SHARE controls to be
        -- appended on the next entry.
        ctx.state.databank_ui_state.generation =
            ctx.state.databank_ui_state.generation + 1

        ctx.layout.cancel_action_group(
            "databank_entry_install",
            "left Character Databank"
        )
        ctx.layout.cancel_action_group(
            "popup_retirement",
            "left Character Databank"
        )
        ctx.layout.cancel_action_group(
            "import_create",
            "left Character Databank"
        )
        ctx.layout.cancel_action_group(
            "overwrite_verification",
            "left Character Databank"
        )

        ctx.state.databank_ui_state.activeMaster = nil
        ctx.state.databank_ui_state.activeMasterIdentity = nil
        ctx.state.databank_ui_state.shareDispatchPending = false
        ctx.state.databank_ui_state.importDispatchPending = false
        ctx.state.databank_session_active = false

        ctx.logging.transition(
            "databank",
            "inactive",
            "generation=" .. tostring(ctx.state.databank_ui_state.generation)
                .. "; reason=" .. tostring(reason or "navigation")
        )
        ctx.logging.log(
            "Character Databank session paused; preserving installed controls for reusable screen. reason="
                .. tostring(reason or "navigation")
        )
    end

    function ctx.layout.register_databank_deactivation_hook()
        if ctx.layout.databankDeactivationHookRegistered then
            return true
        end

        local ok, hook_id = pcall(function()
            return ctx.runtime:register_hook(
                "/Script/CommonUI.CommonActivatableWidget:DeactivateWidget",
                function(context, ...)
                    local widget = ctx.common.unwrap_hook_value(context)
                    local active_master = ctx.state.databank_ui_state.activeMaster

                    if widget ~= nil
                        and active_master ~= nil
                        and ctx.common.same_remote_object(widget, active_master) then
                        leave_databank_session(
                            "Databank master DeactivateWidget"
                        )
                    end
                end
            )
        end)

        if not ok or hook_id == nil then
            ctx.logging.log(
                "WARNING: Character Databank deactivation hook failed: "
                    .. tostring(hook_id)
            )
            return false
        end

        ctx.layout.databankDeactivationHookRegistered = true
        ctx.logging.log("Character Databank deactivation cancellation hook registered.")
        return true
    end

    local function reset_databank_install_state_for_new_master(
        new_master_identity
    )
        local mapped = 0

        for _ in pairs(
            ctx.state.databank_ui_state.buttons
        ) do
            mapped = mapped + 1
        end

        ctx.state.databank_ui_state.generation =
            ctx.state.databank_ui_state.generation + 1

        -- Only Lua-owned strings/booleans are discarded. Never touch widgets from
        -- the previous screen here; Unreal may already be tearing them down.
        ctx.state.databank_ui_state.buttons = {}
        ctx.state.databank_ui_state.installedPages = {}
        ctx.state.databank_ui_state.installedMasterIdentity =
            new_master_identity
        ctx.state.databank_ui_state.activeMaster = nil
        ctx.state.databank_ui_state.activeMasterIdentity = nil
        ctx.state.databank_ui_state.shareDispatchPending = false
        ctx.state.databank_ui_state.importDispatchPending = false
        ctx.state.databank_session_active = false

        ctx.logging.log(
            string.format(
                "Character Databank install state reset for new runtime master; released %d stale mapping(s).",
                mapped
            )
        )
    end

    function ctx.lifecycle.runtime_databank_master_candidate()
        -- FindFirstOf may observe the runtime master while CommonUI is still
        -- transitioning it into the hierarchy. Keep the attached/visible checks,
        -- but do NOT call CommonActivatableWidget:IsActivated() here. The native
        -- access violation seen in v0.7.38 and v0.7.41 happened before the success
        -- log, inside this bounded entry check; a native AV is not catchable by Lua
        -- pcall. Attached + visible, followed by a second stable observation below,
        -- is sufficient readiness for the non-destructive v0.7.36+ UI insertion.
        return ctx.widget_helpers.find_live_databank_master()
    end

    function ctx.lifecycle.begin_databank_session(master)
        if master == nil then
            return
        end

        local master_identity =
            ctx.widget_helpers.databank_widget_identity(master)

        if master_identity == nil then
            return
        end

        ctx.layout.cancel_action_group(
            "databank_entry_install",
            "Databank entry confirmed"
        )

        local same_installed_master =
            ctx.state.databank_ui_state.installedMasterIdentity
                == master_identity

        if not same_installed_master then
            reset_databank_install_state_for_new_master(
                master_identity
            )
        else
            ctx.logging.log(
                "Character Databank reusable runtime master detected; adopting existing Character Share controls."
            )
        end

        ctx.state.databank_ui_state.generation =
            ctx.state.databank_ui_state.generation + 1

        ctx.state.databank_ui_state.activeMaster = master
        ctx.state.databank_ui_state.activeMasterIdentity =
            master_identity
        ctx.state.databank_session_active = true

        local generation =
            ctx.state.databank_ui_state.generation

        ctx.logging.transition(
            "databank",
            "active",
            "generation=" .. tostring(generation)
                .. "; master=" .. tostring(master_identity)
        )
        ctx.logging.log(
            "Character Databank ENTER confirmed after main-menu click: "
                .. tostring(master_identity)
        )

        -- Safe to run on both first entry and re-entry. install_databank_page_ui()
        -- is keyed by persistent page identity and returns true immediately when
        -- that page already received its controls.
        ctx.databank_ui.install_databank_ui_for_active_master(
            master,
            generation
        )
    end

    local function probe_for_databank_after_menu_click(
        probe_generation,
        attempt
    )
        if probe_generation
            ~= ctx.state.databank_entry_probe_generation then
            return
        end

        local master =
            ctx.lifecycle.runtime_databank_master_candidate()

        if master ~= nil then
            local candidate_identity =
                ctx.widget_helpers.databank_widget_identity(master)

            if candidate_identity ~= nil
                and candidate_identity == ctx.state.databank_entry_probe_candidate_identity then
                ctx.logging.log(
                    string.format(
                        "Databank entry probe stabilized on attempt %d; beginning UI integration.",
                        attempt
                    )
                )

                ctx.state.databank_entry_probe_candidate_identity = nil

                ctx.lifecycle.begin_databank_session(
                    master
                )

                return
            end

            ctx.state.databank_entry_probe_candidate_identity =
                candidate_identity

            ctx.logging.log(
                string.format(
                    "Databank entry probe observed live candidate on attempt %d; waiting for one stable re-observation.",
                    attempt
                )
            )
        else
            ctx.state.databank_entry_probe_candidate_identity = nil
        end

        if attempt >= 6 then
            ctx.logging.log(
                "Databank entry probe ended: clicked submenu did not open Character Databank."
            )
            return
        end

        local delays = {
            150,
            150,
            200,
            300,
            450,
            650,
        }

        local delay =
            delays[attempt + 1] or 250

        ctx.layout.run_group_after("databank_entry_install", delay, function()
            if probe_generation
                ~= ctx.state.databank_entry_probe_generation then
                return
            end

            probe_for_databank_after_menu_click(
                probe_generation,
                attempt + 1
            )
        end)
    end

    function ctx.lifecycle.handle_strategy_submenu_click(button)
        if button == nil then
            return
        end

        local identity =
            ctx.widget_helpers.databank_widget_identity(button)

        if identity == nil
            or not string.find(
                identity,
                "WBP_AnimatedSubMenuListButton_C",
                1,
                true
            ) then
            return
        end

        ctx.layout.cancel_action_group(
            "databank_entry_install",
            "Strategy submenu selection changed"
        )

        ctx.state.databank_entry_probe_generation =
            ctx.state.databank_entry_probe_generation + 1

        -- The game reuses the Character Databank widget after backing out. Keep
        -- its action mappings/install flags across Strategy navigation so returning
        -- to the same runtime master adopts the existing controls instead of
        -- appending another set.
        if ctx.state.databank_session_active then
            leave_databank_session(
                "Strategy submenu navigation"
            )
        end

        -- v1.0.0 armed the Databank discovery probe after *every* Strategy submenu
        -- click. On a fresh launch, opening a non-Databank page before the game had
        -- ever instantiated WBP_CharacterBank_Master_C could make UE4SS fault while
        -- FindFirstOf inspected the absent/transitional class. Once Databank had
        -- been visited, Zero Company retained the reusable runtime master and the
        -- same navigation was safe.
        --
        -- WBP_AnimatedSubMenuListButton_C exposes its live ButtonTextBlock. Read
        -- the label from the clicked, known-live button and only arm discovery for
        -- the actual Character Databank entry. Unrelated Strategy navigation now
        -- returns before any Databank UObject lookup occurs.
        local button_text_block =
            ctx.common.unwrap_hook_value(
                select(
                    1,
                    ctx.common.read_property(
                        button,
                        "ButtonTextBlock"
                    )
                )
            )

        local button_label =
            string.upper(
                ctx.popup.read_text_box_value(
                    button_text_block
                )
            )

        if button_label == ""
            or not string.find(
                button_label,
                "DATABANK",
                1,
                true
            ) then
            return
        end

        local probe_generation =
            ctx.state.databank_entry_probe_generation

        ctx.state.databank_entry_probe_candidate_identity = nil

        ctx.logging.log(
            "Character Databank submenu click detected; starting bounded entry check."
        )

        ctx.layout.run_group_after("databank_entry_install", 150, function()
            if probe_generation
                ~= ctx.state.databank_entry_probe_generation then
                return
            end

            probe_for_databank_after_menu_click(
                probe_generation,
                1
            )
        end)
    end
end
