-- Character Share: state.
-- Initialized once per mod instance; shared references use explicit ctx fields.
-- Context: dependencies, runtime, state.
return function(ctx)
    -- ---------------------------------------------------------------------------
    -- Native Character Share dialogs
    --
    -- v0.5.13 removes the hand-built WBP_ModalBase composition entirely.
    --
    -- Zero Company already has a complete message-box stack:
    --
    --   UBitReactorMessagingSubsystem
    --       -> UBitReactorGameDialogDescriptor
    --       -> WBP_GenericPopupMessage
    --
    -- We now let that system own:
    --   * the modal frame
    --   * spacing / layout
    --   * button creation
    --   * hover / click behavior
    --   * button labels
    --   * activation / deactivation
    --
    -- Character Share only injects its text-entry widgets into GenericPopupMessage's
    -- existing AboveText / BelowText named slots.
    -- ---------------------------------------------------------------------------

    ctx.state.popup_state =
        ctx.dependencies.UI.new_popup_state()

    ctx.state.pending_import_code = nil

    ctx.state.pending_import_payload = nil

    ctx.state.pending_name_override = nil

    ctx.state.pending_name_override_code = nil

    ctx.state.pending_import_navigation_generation = 0

    ctx.state.last_export_code = nil

    ctx.state.databank_ui_state =
        ctx.dependencies.UI.new_databank_state()

    ctx.state.databank_button_click_hook_registered = false

    ctx.state.databank_entry_probe_generation = 0

    ctx.state.databank_entry_probe_candidate_identity = nil

    ctx.state.databank_session_active = false

    ctx.runtime.on_teardown = function()
        ctx.runtime.resume = ctx.state.databank_session_active
            and ctx.state.databank_ui_state.activeMasterIdentity or nil
    end

    ctx.state.native_dialog_result_hook_registered = false

    ctx.state.ensure_native_dialog_result_hook = nil

    ctx.state.handle_native_dialog_result = nil
end
