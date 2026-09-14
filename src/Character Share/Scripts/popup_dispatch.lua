-- Character Share: popup dispatch.
-- Initialized once per mod instance; shared references use explicit ctx fields.
-- Context: character_staging, common, import_dialogs, import_validation, import_workflow, layout, logging, overwrite_workflow, popup, popup_dispatch, sharing, state, widget_helpers.
return function(ctx)
    function ctx.popup_dispatch.handle_popup_topnav_action(
        button
    )
        if button == nil
            or ctx.state.popup_state.widget == nil then
            return false
        end

        local identity =
            ctx.widget_helpers.databank_widget_identity(button)

        local action =
            ctx.state.popup_state.customActions[identity]

        if action == nil then
            return false
        end

        local widget =
            ctx.state.popup_state.widget

        local captured_import =
            ctx.state.popup_state.capturedImportCode

        local captured_first =
            ctx.state.popup_state.capturedRenameFirst

        local captured_last =
            ctx.state.popup_state.capturedRenameLast

        if ctx.state.popup_state.mode == "import" then
            captured_import =
                ctx.popup.read_text_box_value(
                    ctx.state.popup_state.textBox
                )
        elseif ctx.state.popup_state.mode == "rename" then
            captured_first =
                ctx.popup.read_text_box_value(
                    ctx.state.popup_state.renameFirstBox
                )

            captured_last =
                ctx.popup.read_text_box_value(
                    ctx.state.popup_state.renameLastBox
                )
        end

        local captured_context =
            ctx.state.popup_state.context

        ctx.logging.log(
            string.format(
                "Popup TopNav click: %s -> %s",
                identity,
                tostring(action)
            )
        )

        -- These are our buttons, not descriptor result buttons. Suppress the
        -- BP_OnHideDialog result path and close/deactivate the popup ourselves.
        ctx.state.popup_state.suppressResult = true

        ctx.popup.detach_character_share_content(
            widget
        )

        local _, close_err = ctx.common.try_call(function()
            widget:OnCloseWindow()
        end)

        if close_err ~= nil then
            ctx.logging.log(
                "Popup TopNav native close warning: "
                    .. tostring(close_err)
            )
        end

        pcall(function()
            widget:DeactivateWidget()
        end)

        ctx.popup.reset_popup_state()

        -- Give CommonUI one short native-outro window before opening the next
        -- Character Share dialog or entering the game's native Edit flow.
        ctx.layout.cancel_action_group(
            "popup_retirement",
            "popup TopNav transition replaced"
        )

        ctx.layout.run_group_after("popup_retirement", 120, function()
                if not ctx.layout
                    .popup_context_uobjects_valid(
                        captured_context
                    ) then
                    ctx.logging.log(
                        "Popup TopNav dispatch cancelled: captured character ViewModel is no longer valid."
                    )
                    return
                end

                ctx.state.popup_state.capturedImportCode =
                    captured_import

                ctx.state.popup_state.capturedRenameFirst =
                    captured_first

                ctx.state.popup_state.capturedRenameLast =
                    captured_last

                ctx.state.popup_state.context =
                    captured_context

                ctx.logging.log(
                    "Popup TopNav dispatch after native close: "
                        .. tostring(action)
                )

                if ctx.popup_dispatch.dispatch_popup_action ~= nil then
                    ctx.popup_dispatch.dispatch_popup_action(
                        action
                    )
                end
        end)

        return true
    end

    function ctx.popup_dispatch.handle_export_key()
        if ctx.popup.popup_is_open("share") then
            ctx.popup.safe_remove_popup()
            ctx.logging.log("Share popup closed.")
            return
        end

        ctx.sharing.export_selected_character()
    end

    local function validate_import_popup()
        local code = ctx.popup.code_from_import_popup()
        if code == nil then
            ctx.logging.log("IMPORT PREFLIGHT FAILED: dialog contains no ZC1 character code")
            ctx.popup.show_notice_popup(
                "INVALID SHARE CODE",
                "Paste a ZC1 character code, then choose Validate.",
                0
            )
            return
        end

        local payload, duplicate_matches, duplicate_unreadable =
            ctx.import_validation.import_preflight()

        if payload == nil then
            return
        end

        ctx.state.pending_import_payload = payload

        -- If Rename was already chosen and a matching Create New editor is open,
        -- Validate should reflect the name the player is actually looking at in
        -- that creator. This prevents an earlier name such as "Tal Rea5" from
        -- becoming sticky after the player changes it again manually.
        local databank_vm =
            ctx.common.find_first(
                "BrunoCharacterDatabankViewModel"
            )

        local active_creator_vm = nil
        local active_creator_err = nil

        if ctx.state.pending_name_override ~= nil
            and databank_vm ~= nil then
            active_creator_vm, active_creator_err =
                ctx.character_staging.matching_active_new_character_vm(
                    databank_vm,
                    payload.characterType
                )

            if active_creator_vm ~= nil
                and ctx.character_staging.adopt_manual_creator_name(
                    payload,
                    active_creator_vm,
                    "IMPORT VALIDATE"
                ) then
                duplicate_matches,
                duplicate_unreadable =
                    ctx.import_validation.find_duplicate_characters(
                        databank_vm,
                        payload
                    )

                ctx.import_validation.log_duplicate_summary(
                    duplicate_matches,
                    duplicate_unreadable,
                    payload
                )
            elseif active_creator_vm == nil then
                ctx.logging.log(
                    "IMPORT VALIDATE name sync skipped: "
                        .. tostring(active_creator_err)
                )
            end
        end

        ctx.state.pending_import_payload = payload
        ctx.popup.safe_remove_popup()

        if duplicate_matches ~= nil and #duplicate_matches > 0 then
            ctx.import_dialogs.show_duplicate_resolution_popup(
                payload,
                duplicate_matches,
                duplicate_unreadable or 0
            )
            return
        end

        if duplicate_unreadable ~= nil and duplicate_unreadable > 0 then
            ctx.popup.show_notice_popup(
                "IMPORT BLOCKED",
                string.format(
                    "The code is valid, but %d existing character%s could not be checked for duplicates.",
                    duplicate_unreadable,
                    duplicate_unreadable == 1 and "" or "s"
                ),
                3600
            )
            return
        end

        ctx.logging.log(
            "IMPORT PREFLIGHT: unique validated payload; starting native create."
        )

        ctx.import_workflow.begin_new_import_stage(
            payload
        )
    end

    function ctx.popup_dispatch.handle_import_preflight_key()
        if ctx.popup.popup_is_open("import") then
            validate_import_popup()
            return
        end

        ctx.popup.show_import_popup()
    end

    ctx.popup_dispatch.dispatch_popup_action = function(action)
        if action == "close_popup" then
            ctx.popup.reset_popup_state()
            return
        end

        if action == "cancel_import" then
            ctx.import_validation.clear_pending_import()
            ctx.popup.reset_popup_state()
            ctx.logging.log("Import cancelled; dialog chain terminated.")
            return
        end

        if action == "validate_import" then
            -- BP_OnHideDialog fires as the native dialog closes. v0.5.16 correctly
            -- captured the text and released the pooled popup before dispatch, but
            -- then incorrectly required that same popup to still be open here.
            --
            -- validate_import_popup() can read popup_state.capturedImportCode, so
            -- validation must run after the native dialog has closed.
            if ctx.state.popup_state.capturedImportCode ~= nil
                or ctx.state.pending_import_code ~= nil then
                validate_import_popup()
            else
                ctx.logging.log("IMPORT PREFLIGHT FAILED: Validate result had no captured code.")
                ctx.popup.show_notice_popup(
                    "INVALID SHARE CODE",
                    "No Character Share code was captured from the Import dialog.",
                    0
                )
            end
            return
        end

        if action == "duplicate_rename" then
            local context = ctx.state.popup_state.context
            if context ~= nil and context.payload ~= nil then
                ctx.import_dialogs.show_rename_popup(context.payload)
            end
            return
        end

        if action == "duplicate_overwrite" then
            local context = ctx.state.popup_state.context
            if context == nil or context.payload == nil then
                return
            end

            local same_type =
                ctx.import_validation.same_type_matches(context.payload, context.matches or {})

            if #same_type == 1 then
                ctx.overwrite_workflow.begin_overwrite_stage(
                    context.payload,
                    same_type[1]
                )
            elseif #same_type == 2 then
                ctx.import_dialogs.show_overwrite_target_popup(
                    context.payload,
                    same_type
                )
            else
                ctx.popup.show_notice_popup(
                    "OVERWRITE UNAVAILABLE",
                    "Overwrite needs one or two matching characters of the same type.",
                    0
                )
            end
            return
        end

        if action == "overwrite_target_1"
            or action == "overwrite_target_2" then
            local context = ctx.state.popup_state.context
            if context == nil
                or context.payload == nil
                or context.matches == nil then
                return
            end

            local index =
                action == "overwrite_target_1"
                    and 1
                    or 2

            local match = context.matches[index]
            if match == nil then
                ctx.popup.show_notice_popup(
                    "OVERWRITE FAILED",
                    "The selected overwrite target is no longer available.",
                    0
                )
                return
            end

            ctx.overwrite_workflow.begin_overwrite_stage(
                context.payload,
                match
            )
            return
        end

        if action == "rename_confirm" then
            local context = ctx.state.popup_state.context
            if context == nil or context.payload == nil then
                return
            end

            local payload = context.payload
            local first =
                ctx.state.popup_state.capturedRenameFirst
                    or ctx.import_dialogs.read_popup_text(ctx.state.popup_state.renameFirstBox)

            local last =
                ctx.state.popup_state.capturedRenameLast
                    or ctx.import_dialogs.read_popup_text(ctx.state.popup_state.renameLastBox)

            first = first:gsub("^%s+", ""):gsub("%s+$", "")
            last = last:gsub("^%s+", ""):gsub("%s+$", "")

            if first == "" then
                ctx.popup.show_notice_popup(
                    "INVALID NAME",
                    payload.characterType == "astromech"
                        and "Astromech name cannot be empty."
                        or "First name cannot be empty.",
                    2600
                )
                return
            end

            if #first > 128 or #last > 128 then
                ctx.popup.show_notice_popup(
                    "INVALID NAME",
                    "The new name is too long.",
                    2600
                )
                return
            end

            local code = ctx.state.pending_import_code
            if code == nil then
                ctx.import_validation.clear_pending_import()
                ctx.popup.safe_remove_popup()
                return
            end

            ctx.state.pending_name_override = {
                first = first,
                last = payload.characterType == "astromech" and "" or last,
            }

            ctx.state.pending_name_override_code =
                code

            local decoded, decode_err = ctx.sharing.decode_share_code(code)
            if decode_err ~= nil or decoded == nil then
                ctx.popup.show_notice_popup(
                    "IMPORT ERROR",
                    "The pending share code could not be decoded again.",
                    3000
                )
                return
            end

            local renamed_payload = decoded.payload

            ctx.import_validation.apply_pending_name_override(
                renamed_payload,
                code
            )

            ctx.state.pending_import_payload = renamed_payload

            local databank_vm = ctx.common.find_first("BrunoCharacterDatabankViewModel")
            local matches = {}
            local unreadable = 0

            if databank_vm ~= nil then
                matches, unreadable =
                    ctx.import_validation.find_duplicate_characters(databank_vm, renamed_payload)
            end

            ctx.popup.safe_remove_popup()

            if #matches > 0 then
                ctx.import_dialogs.show_duplicate_resolution_popup(
                    renamed_payload,
                    matches,
                    unreadable
                )
            elseif unreadable > 0 then
                ctx.popup.show_notice_popup(
                    "IMPORT BLOCKED",
                    "The new name is valid, but duplicate verification was incomplete.",
                    3400
                )
            else
                ctx.logging.log(
                    string.format(
                        "IMPORT RENAMED: '%s' is unique; starting native create.",
                        ctx.import_validation.payload_full_name(renamed_payload)
                    )
                )

                ctx.import_workflow.begin_new_import_stage(
                    renamed_payload
                )
            end

            return
        end
    end

    local function capture_native_dialog_inputs()
        if ctx.state.popup_state.mode == "import" then
            ctx.state.popup_state.capturedImportCode =
                ctx.popup.read_text_box_value(ctx.state.popup_state.textBox)
        elseif ctx.state.popup_state.mode == "rename" then
            ctx.state.popup_state.capturedRenameFirst =
                ctx.popup.read_text_box_value(ctx.state.popup_state.renameFirstBox)

            ctx.state.popup_state.capturedRenameLast =
                ctx.popup.read_text_box_value(ctx.state.popup_state.renameLastBox)
        end
    end

    ctx.state.handle_native_dialog_result = function(widget_value, result_value)
        local widget = ctx.common.unwrap_hook_value(widget_value)
        local result = ctx.common.unwrap_hook_value(result_value)

        if widget == nil
            or ctx.state.popup_state.widget == nil
            or not ctx.common.same_remote_object(widget, ctx.state.popup_state.widget) then
            return
        end

        if ctx.state.popup_state.suppressResult then
            return
        end

        capture_native_dialog_inputs()

        local result_tag = ctx.common.gameplay_tag_value(result)
        local action =
            result_tag ~= nil
                and ctx.state.popup_state.resultActions[result_tag]
                or nil

        if action == nil then
            ctx.logging.log(
                "Native dialog closed with unmapped result: "
                .. tostring(result_tag)
            )
            ctx.popup.finish_native_popup_hide(widget)
            ctx.popup.retire_native_popup(widget, nil)
            return
        end

        ctx.logging.log(
            string.format(
                "Native dialog result: %s -> %s",
                tostring(result_tag),
                action
            )
        )

        -- Preserve values that dispatch_popup_action may need after state reset.
        local captured_import = ctx.state.popup_state.capturedImportCode
        local captured_first = ctx.state.popup_state.capturedRenameFirst
        local captured_last = ctx.state.popup_state.capturedRenameLast
        local captured_context = ctx.state.popup_state.context

        -- Clear Character Share content/state immediately, then explicitly retire
        -- the resolved popup from CommonUI before performing the next action. This
        -- prevents old Import/Duplicate/Notice dialogs from remaining underneath
        -- the native Edit screen and resurfacing when that screen closes.
        ctx.popup.finish_native_popup_hide(widget)

        ctx.popup.retire_native_popup(widget, function()
            ctx.layout.run_group_after("popup_retirement", 0, function()
                if not ctx.layout
                    .popup_context_uobjects_valid(
                        captured_context
                    ) then
                    ctx.logging.log(
                        "Native dialog dispatch cancelled: captured character ViewModel is no longer valid."
                    )
                    return
                end

                ctx.state.popup_state.capturedImportCode = captured_import
                ctx.state.popup_state.capturedRenameFirst = captured_first
                ctx.state.popup_state.capturedRenameLast = captured_last
                ctx.state.popup_state.context = captured_context

                ctx.logging.log(
                    string.format(
                        "Native dialog dispatch after retirement: %s",
                        tostring(action)
                    )
                )

                if ctx.popup_dispatch.dispatch_popup_action ~= nil then
                    ctx.popup_dispatch.dispatch_popup_action(action)
                end
            end)
        end)
    end
end
