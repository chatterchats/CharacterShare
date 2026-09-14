-- Character Share: overwrite workflow.
-- Initialized once per mod instance; shared references use explicit ctx fields.
-- Context: character_staging, common, dependencies, import_validation, import_workflow, layout, logging, overwrite_workflow, popup, sharing.
return function(ctx)
    function ctx.overwrite_workflow.begin_overwrite_stage(payload, match)
        ctx.logging.transition(
            "overwrite",
            "starting",
            payload and ctx.import_validation.payload_full_name(payload)
                or "missing payload"
        )
        ctx.popup.safe_remove_popup()

        ctx.layout.cancel_action_group(
            "import_create",
            "transitioned to overwrite"
        )
        ctx.layout.cancel_action_group(
            "overwrite_verification",
            "new overwrite started"
        )

        local aux_vm =
            ctx.common.find_first(
                "CharacterBankAuxVM_C"
            )

        local databank_vm =
            ctx.common.find_first(
                "BrunoCharacterDatabankViewModel"
            )

        if aux_vm == nil
            or databank_vm == nil
            or match == nil
            or match.vm == nil then
            ctx.popup.show_notice_popup(
                "OVERWRITE FAILED",
                "Character Databank overwrite state is not ready. No SavePoolCharacter call was made.",
                3800
            )
            return
        end

        local function fail(message)
            ctx.layout.cancel_action_group(
                "overwrite_verification",
                "overwrite failed"
            )

            ctx.logging.log(
                "NATIVE OVERWRITE FAILED: "
                    .. tostring(
                        message
                    )
            )
            ctx.logging.transition("overwrite", "failed", message)

            ctx.popup.show_notice_popup(
                "OVERWRITE FAILED",
                tostring(
                    message
                ),
                5200
            )
        end

        local function payload_code_for_compare(candidate)
            if candidate == nil then
                return nil,
                    "candidate payload is nil"
            end

            -- Codec.encode() returns:
            --   success: code, stats_table
            --   failure: nil, error_string
            --
            -- v0.3.0 incorrectly treated the second success value (stats_table)
            -- as an error, causing every verification code to become nil and
            -- forcing an unnecessary rollback even after SavePoolCharacter
            -- completed successfully.
            local code,
                stats_or_err =
                    ctx.dependencies.Codec.encode(
                        candidate
                    )

            if code == nil then
                return nil,
                    tostring(
                        stats_or_err
                    )
            end

            return code,
                nil
        end

        local function begin_direct_saved_vm_overwrite()
            if not ctx.layout.uobject_is_valid(aux_vm)
                or not ctx.layout.uobject_is_valid(databank_vm)
                or not ctx.layout.uobject_is_valid(match.vm) then
                fail(
                    "Overwrite was cancelled because a captured Databank ViewModel is no longer valid."
                )
                return
            end

            ctx.logging.log(
                string.format(
                    "NATIVE OVERWRITE START: '%s' -> existing %s '%s'; using the selected saved CharacterVM directly.",
                    ctx.import_validation.payload_full_name(payload),
                    ctx.character_staging.creator_name(payload.characterType),
                    match.name or "<unnamed>"
                )
            )

            local _,
                select_err =
                    ctx.common.try_call(
                        function()
                            match.vm:OnSelected()
                        end
                    )

            if select_err ~= nil then
                fail(
                    "Could not select the existing character: "
                        .. tostring(
                            select_err
                        )
                )
                return
            end

            local attempt =
                0

            local previous_slot_count =
                nil

            local stable_checks =
                0

            local function wait_for_selected_vm()
                attempt =
                    attempt + 1

                        local character_vm,
                            character_vm_err =
                                ctx.common.read_property(
                                    aux_vm,
                                    "CharacterVM"
                                )

                        if character_vm_err == nil
                            and character_vm ~= nil
                            and not ctx.sharing.is_in_progress_character_vm(
                                databank_vm,
                                character_vm
                            ) then
                            local live_type,
                                slot_count,
                                live_type_err =
                                    ctx.character_staging.detect_live_creator_type(
                                        character_vm
                                    )

                            if live_type ~= nil
                                and live_type
                                    ~= payload.characterType then
                                fail(
                                    "Selected saved CharacterVM is "
                                        .. ctx.character_staging.creator_name(
                                            live_type
                                        )
                                        .. " instead of "
                                        .. ctx.character_staging.creator_name(
                                            payload.characterType
                                        )
                                        .. "."
                                )
                                return
                            end

                            if live_type
                                == payload.characterType then
                                local current_count =
                                    slot_count or 0

                                if previous_slot_count
                                    == current_count then
                                    stable_checks =
                                        stable_checks + 1
                                else
                                    stable_checks = 0
                                end

                                previous_slot_count =
                                    current_count

                                if stable_checks >= 1 then
                                    local selected_name =
                                        ctx.common.text_value(
                                            select(
                                                1,
                                                ctx.common.read_property(
                                                    character_vm,
                                                    "FullName"
                                                )
                                            )
                                        )

                                    if selected_name ~= ""
                                        and match.name ~= nil
                                        and selected_name
                                            ~= match.name then
                                        fail(
                                            "Selection changed while preparing overwrite (expected '"
                                                .. tostring(
                                                    match.name
                                                )
                                                .. "', got '"
                                                .. tostring(
                                                    selected_name
                                                )
                                                .. "')."
                                        )
                                        return
                                    end

                                    ctx.logging.log(
                                        string.format(
                                            "NATIVE OVERWRITE SAVED VM READY: %s (%d live slots) after %d check(s).",
                                            ctx.character_staging.creator_name(
                                                live_type
                                            ),
                                            current_count,
                                            attempt
                                        )
                                    )

                                    -- Capture a complete rollback image before the
                                    -- first mutation. This uses the same proven
                                    -- saved-character capture path as Share/F7.
                                    local original_payload =
                                        ctx.sharing.capture_selected_character_payload()

                                    if original_payload == nil then
                                        fail(
                                            "Could not capture the existing character for rollback; overwrite was not attempted."
                                        )
                                        return
                                    end

                                    local original_code,
                                        original_code_err =
                                            payload_code_for_compare(
                                                original_payload
                                            )

                                    local desired_code,
                                        desired_code_err =
                                            payload_code_for_compare(
                                                payload
                                            )

                                    if original_code == nil then
                                        fail(
                                            "Could not encode the rollback payload for verification: "
                                                .. tostring(
                                                    original_code_err
                                                )
                                        )
                                        return
                                    end

                                    if desired_code == nil then
                                        fail(
                                            "Could not encode the imported payload for verification: "
                                                .. tostring(
                                                    desired_code_err
                                                )
                                        )
                                        return
                                    end

                                    local function rollback_and_resave(
                                        reason
                                    )
                                        ctx.logging.log(
                                            "NATIVE OVERWRITE ROLLBACK START: "
                                                .. tostring(
                                                    reason
                                                )
                                        )

                                        local rolled_back,
                                            rollback_err =
                                                ctx.character_staging.stage_payload_to_character_vm(
                                                    original_payload,
                                                    character_vm,
                                                    "NATIVE OVERWRITE ROLLBACK"
                                                )

                                        if not rolled_back then
                                            ctx.logging.log(
                                                "NATIVE OVERWRITE ROLLBACK FAILED: "
                                                    .. tostring(
                                                        rollback_err
                                                    )
                                            )
                                            return false
                                        end

                                        local _,
                                            restore_save_err =
                                                ctx.common.try_call(
                                                    function()
                                                        databank_vm:SavePoolCharacter(
                                                            match.vm,
                                                            ctx.import_workflow.make_empty_tag_requirements()
                                                        )
                                                    end
                                                )

                                        if restore_save_err ~= nil then
                                            ctx.logging.log(
                                                "NATIVE OVERWRITE ROLLBACK SAVE FAILED: "
                                                    .. tostring(
                                                        restore_save_err
                                                    )
                                            )
                                            return false
                                        end

                                        ctx.logging.log(
                                            "NATIVE OVERWRITE ROLLBACK COMPLETE."
                                        )

                                        return true
                                    end

                                    local staged,
                                        stage_err =
                                            ctx.character_staging.stage_payload_to_character_vm(
                                                payload,
                                                character_vm,
                                                "NATIVE OVERWRITE"
                                            )

                                    if not staged then
                                        rollback_and_resave(
                                            "import staging failed"
                                        )

                                        fail(
                                            "Direct saved-character staging failed: "
                                                .. tostring(
                                                    stage_err
                                                )
                                        )
                                        return
                                    end

                                    ctx.logging.log(
                                        "NATIVE OVERWRITE STAGED: selected saved CharacterVM matches the imported payload; calling SavePoolCharacter(existingVM, empty GameplayTagRequirements)."
                                    )

                                    local _,
                                        save_err =
                                            ctx.common.try_call(
                                                function()
                                                    databank_vm:SavePoolCharacter(
                                                        match.vm,
                                                        ctx.import_workflow.make_empty_tag_requirements()
                                                    )
                                                end
                                            )

                                    if save_err ~= nil then
                                        rollback_and_resave(
                                            "SavePoolCharacter call failed"
                                        )

                                        fail(
                                            "SavePoolCharacter failed: "
                                                .. tostring(
                                                    save_err
                                                )
                                        )
                                        return
                                    end

                                    ctx.logging.log(
                                        "NATIVE OVERWRITE SAVE CALL COMPLETE: native SavePoolCharacter returned without an exposed error."
                                    )

                                    -- Re-select through the PoolCharacterVM and
                                    -- recapture through the normal Share path. This
                                    -- is not a disk-reload proof, but it does verify
                                    -- that the Databank's selected saved model still
                                    -- resolves to the imported state after Save.
                                    ctx.layout.run_group_after(
                                        "overwrite_verification",
                                        150,
                                        function()
                                                    ctx.common.try_call(
                                                        function()
                                                            match.vm:OnSelected()
                                                        end
                                                    )

                                                    local saved_payload =
                                                        ctx.sharing.capture_selected_character_payload()

                                                    local saved_code,
                                                        saved_code_err =
                                                            payload_code_for_compare(
                                                                saved_payload
                                                            )

                                                    if saved_code == nil then
                                                        ctx.logging.log(
                                                            "NATIVE OVERWRITE VERIFY ENCODE FAILED: "
                                                                .. tostring(
                                                                    saved_code_err
                                                                )
                                                        )
                                                    end

                                                    if saved_code ~= nil
                                                        and saved_code
                                                            == desired_code then
                                                        ctx.logging.transition(
                                                            "overwrite",
                                                            "complete",
                                                            ctx.import_validation.payload_full_name(payload)
                                                        )
                                                        ctx.logging.log(
                                                            "NATIVE OVERWRITE VERIFIED: re-selected saved CharacterVM exactly matches the imported payload after SavePoolCharacter."
                                                        )

                                                        ctx.import_validation.clear_pending_import()

                                                        ctx.popup.show_notice_popup(
                                                            "OVERWRITE COMPLETE",
                                                            string.format(
                                                                "%s was overwritten successfully.",
                                                                ctx.import_validation.payload_full_name(payload)
                                                            ),
                                                            6200
                                                        )

                                                        return
                                                    end

                                                    local restored =
                                                        rollback_and_resave(
                                                            "post-save verification mismatch"
                                                        )

                                                    ctx.logging.log(
                                                        string.format(
                                                            "NATIVE OVERWRITE VERIFY FAILED: desiredCode=%s savedCode=%s rollback=%s originalCode=%s",
                                                            tostring(
                                                                desired_code
                                                            ),
                                                            tostring(
                                                                saved_code
                                                            ),
                                                            tostring(
                                                                restored
                                                            ),
                                                            tostring(
                                                                original_code
                                                            )
                                                        )
                                                    )

                                                    fail(
                                                        "SavePoolCharacter returned, but the re-selected saved character did not match the imported payload. The branch attempted to restore the original character."
                                                    )
                                        end,
                                        databank_vm,
                                        match.vm,
                                        character_vm
                                    )

                                    return
                                end
                            elseif live_type_err ~= nil then
                                ctx.logging.log(
                                    "NATIVE OVERWRITE waiting for selected saved VM type/slots: "
                                        .. tostring(
                                            live_type_err
                                        )
                                )
                            end
                        end

                        if attempt < 30 then
                            ctx.layout.run_group_after(
                                "overwrite_verification",
                                100,
                                wait_for_selected_vm,
                                aux_vm,
                                databank_vm,
                                match.vm
                            )
                        else
                            fail(
                                "The selected saved CharacterVM did not become ready."
                            )
                        end
            end

            ctx.layout.run_group_after(
                "overwrite_verification",
                50,
                wait_for_selected_vm,
                aux_vm,
                databank_vm,
                match.vm
            )
        end

        ctx.import_workflow.close_active_new_character_before_overwrite(
            databank_vm,
            begin_direct_saved_vm_overwrite,
            function(reason)
                fail(
                    tostring(
                        reason
                    )
                )
            end
        )
    end
end
