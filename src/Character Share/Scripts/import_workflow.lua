-- Character Share: import workflow.
-- Initialized once per mod instance; shared references use explicit ctx fields.
-- Context: character_staging, common, import_dialogs, import_validation, import_workflow, layout, logging, popup, state.
return function(ctx)
    local function character_list_page_for_type(master, character_type)
        if master == nil then
            return nil
        end

        if character_type == "astromech" then
            return select(1, ctx.common.read_property(master, "AstromechCharacterList"))
        end

        return select(1, ctx.common.read_property(master, "OtherCharacterList"))
    end

    local function active_new_character_session(databank_vm)
        if databank_vm == nil then
            return nil, nil
        end

        local new_vm, new_vm_err =
            ctx.common.read_property(databank_vm, "DatabankNewCharacterVM")

        if new_vm_err ~= nil or new_vm == nil then
            return nil, nil
        end

        local character_vm, character_vm_err =
            ctx.common.read_property(new_vm, "CharacterVM")

        if character_vm_err ~= nil or character_vm == nil then
            return new_vm, nil
        end

        local live_type, live_slot_count, _ =
            ctx.character_staging.detect_live_creator_type(character_vm)

        if live_type ~= nil then
            return new_vm, {
                vm = character_vm,
                characterType = live_type,
                slotCount = live_slot_count,
            }
        end

        return new_vm, nil
    end

    local function wait_for_new_character_to_close(
        databank_vm,
        on_closed,
        on_failed
    )
        local attempts = 0

        local function poll()
            attempts = attempts + 1

            local _, active = active_new_character_session(databank_vm)

                if active == nil then
                    ctx.logging.log(
                        string.format(
                            "OVERWRITE: Create New session closed after %d check(s).",
                            attempts
                        )
                    )
                    on_closed()
                    return
                end

                if attempts >= 20 then
                    on_failed(
                        "Create New remained active after cancellation."
                    )
                    return
                end

            ctx.layout.run_group_after(
                "overwrite_verification",
                100,
                poll,
                databank_vm
            )
        end

        ctx.layout.run_group_after(
            "overwrite_verification",
            100,
            poll,
            databank_vm
        )
    end

    function ctx.import_workflow.close_active_new_character_before_overwrite(
        databank_vm,
        on_closed,
        on_failed
    )
        local new_vm, active =
            active_new_character_session(databank_vm)

        if active == nil then
            on_closed()
            return
        end

        ctx.logging.log(
            string.format(
                "OVERWRITE: active Create New editor detected (%s, %d live slots); cancelling it before opening Edit.",
                ctx.character_staging.creator_name(active.characterType),
                active.slotCount or 0
            )
        )

        local _, cancel_err = ctx.common.try_call(function()
            new_vm:CancelNewCharacter()
        end)

        if cancel_err ~= nil then
            on_failed(
                "CancelNewCharacter failed: " .. tostring(cancel_err)
            )
            return
        end

        wait_for_new_character_to_close(
            databank_vm,
            on_closed,
            on_failed
        )
    end

    local function cancel_auto_created_new_character(
        new_vm,
        reason
    )
        if new_vm == nil then
            return
        end

        local _, cancel_err = ctx.common.try_call(function()
            new_vm:CancelNewCharacter()
        end)

        if cancel_err ~= nil then
            ctx.logging.log(
                "AUTO IMPORT cleanup warning: CancelNewCharacter failed after "
                    .. tostring(reason)
                    .. ": "
                    .. tostring(cancel_err)
            )
        else
            ctx.logging.log(
                "AUTO IMPORT cleanup: cancelled temporary Create New session after "
                    .. tostring(reason)
                    .. "."
            )
        end
    end

    local function auto_import_fail(
        title,
        message,
        new_vm
    )
        ctx.layout.cancel_action_group(
            "import_create",
            "automatic import failed"
        )

        ctx.logging.log(
            "AUTO IMPORT FAILED: "
                .. tostring(message)
        )
        ctx.logging.transition("import", "failed", message)

        if new_vm ~= nil then
            cancel_auto_created_new_character(
                new_vm,
                message
            )
        end

        ctx.popup.show_notice_popup(
            title or "IMPORT FAILED",
            ctx.import_validation.friendly_import_failure(
                message
            ),
            5200
        )
    end

    local function stage_auto_import_into_character_vm(
        payload,
        character_vm,
        source_label,
        allow_live_name_override
    )
        if payload == nil
            or character_vm == nil then
            return false, "payload/editor unavailable"
        end

        -- IMPORTANT:
        -- A creator that Character Share just opened automatically still contains
        -- the game's own generated/default name (for example P1-O5 on Astromech).
        -- That is not a player edit and must not supersede the validated payload
        -- name.
        --
        -- Live-name adoption is therefore allowed only when the creator was
        -- already open before this automatic import began. The legacy manual
        -- Validate/Stage paths keep their existing v0.6.10 behavior.
        if allow_live_name_override then
            ctx.character_staging.adopt_manual_creator_name(
                payload,
                character_vm,
                source_label or "AUTO IMPORT"
            )
        else
            ctx.logging.log(
                string.format(
                    "%s: preserving validated payload name '%s' over automatic creator default.",
                    source_label or "AUTO IMPORT",
                    ctx.import_validation.payload_full_name(payload)
                )
            )
        end

        local databank_vm =
            ctx.common.find_first(
                "BrunoCharacterDatabankViewModel"
            )

        if databank_vm == nil then
            return false,
                "Character Databank ViewModel disappeared before staging"
        end

        local matches, unreadable =
            ctx.import_validation.find_duplicate_characters(
                databank_vm,
                payload
            )

        if #matches > 0 then
            ctx.import_validation.log_duplicate_summary(
                matches,
                unreadable,
                payload
            )

            ctx.import_dialogs.show_duplicate_resolution_popup(
                payload,
                matches,
                unreadable
            )

            return false,
                "duplicate name appeared before staging"
        end

        if unreadable > 0 then
            return false,
                "duplicate-name verification became incomplete before staging"
        end

        return ctx.character_staging.stage_payload_to_character_vm(
            payload,
            character_vm,
            source_label or "AUTO IMPORT"
        )
    end

    local function wait_for_native_create_new_then_stage(
        payload,
        navigation_generation,
        attempt,
        previous_slot_count,
        stable_checks
    )
        if navigation_generation
            ~= ctx.state.pending_import_navigation_generation then
            ctx.logging.log(
                "SAFE IMPORT wait cancelled because the pending import changed."
            )
            return
        end

        attempt =
            attempt or 1

        ctx.layout.run_group_after("import_create", 0, function()
            if navigation_generation
                ~= ctx.state.pending_import_navigation_generation then
                return
            end

            local databank_vm =
                ctx.common.find_first(
                    "BrunoCharacterDatabankViewModel"
                )

            if databank_vm ~= nil then
                local _, active =
                    active_new_character_session(
                        databank_vm
                    )

                if active ~= nil then
                    if active.characterType
                        ~= payload.characterType then
                        ctx.popup.show_notice_popup(
                            "WRONG CREATOR OPEN",
                            "Character Share is waiting for "
                                .. ctx.character_staging.creator_name(payload.characterType)
                                .. ", but the game currently has "
                                .. ctx.character_staging.creator_name(active.characterType)
                                .. " Create New open. Cancel/back out of that creator and open the matching one.",
                            5200
                        )

                        ctx.logging.log(
                            "SAFE IMPORT stopped because the wrong native Create New editor was opened."
                        )
                        return
                    end

                    local live_type,
                        live_slot_count,
                        live_type_err =
                            ctx.character_staging.detect_live_creator_type(
                                active.vm
                            )

                    if live_type
                        == payload.characterType then
                        local current_count =
                            live_slot_count or 0

                        if previous_slot_count
                            == current_count then
                            stable_checks =
                                (stable_checks or 0) + 1
                        else
                            stable_checks = 0
                        end

                        if stable_checks < 1 then
                            ctx.logging.log(
                                string.format(
                                    "SAFE IMPORT creator detected but still settling: %s (%d live slots).",
                                    ctx.character_staging.creator_name(live_type),
                                    current_count
                                )
                            )

                            ctx.layout.run_group_after(
                                "import_create",
                                100,
                                function()
                                    wait_for_native_create_new_then_stage(
                                        payload,
                                        navigation_generation,
                                        attempt + 1,
                                        current_count,
                                        stable_checks
                                    )
                                end
                            )
                            return
                        end

                        ctx.logging.log(
                            string.format(
                                "SAFE IMPORT native creator verified stable after %d check(s): %s (%d live slots).",
                                attempt,
                                ctx.character_staging.creator_name(live_type),
                                current_count
                            )
                        )

                        local staged, stage_err =
                            stage_auto_import_into_character_vm(
                                payload,
                                active.vm,
                                "SAFE IMPORT",
                                false
                            )

                        if staged then
                            ctx.popup.show_notice_popup(
                                "IMPORT STAGED",
                                string.format(
                                    "%s has been loaded into the game's native %s creator. Review it, then use the game's Save button.",
                                    ctx.import_validation.payload_full_name(payload),
                                    ctx.character_staging.creator_name(payload.characterType)
                                ),
                                4600
                            )

                            ctx.logging.log(
                                "SAFE IMPORT COMPLETE: native Create New was user/game-owned; payload staged; final Save remains manual."
                            )
                        elseif stage_err
                            ~= "duplicate name appeared before staging" then
                            auto_import_fail(
                                "IMPORT STAGING FAILED",
                                tostring(stage_err),
                                nil
                            )
                        end

                        return
                    elseif live_type_err ~= nil then
                        ctx.logging.log(
                            "SAFE IMPORT waiting for native creator slot tree: "
                                .. tostring(live_type_err)
                        )
                    end
                end
            end

            if attempt >= 300 then
                ctx.popup.show_notice_popup(
                    "IMPORT READY",
                    string.format(
                        "%s is still pending. Open Create New under %s, then retry Import if the automatic staging window expired.",
                        ctx.import_validation.payload_full_name(payload),
                        ctx.character_staging.creator_name(payload.characterType)
                    ),
                    5200
                )

                ctx.logging.log(
                    "SAFE IMPORT wait expired after 30 seconds without a matching native Create New editor."
                )
                return
            end

            ctx.layout.run_group_after(
                "import_create",
                100,
                function()
                    wait_for_native_create_new_then_stage(
                        payload,
                        navigation_generation,
                        attempt + 1,
                        previous_slot_count,
                        stable_checks
                    )
                end
            )
        end)
    end

    function ctx.import_workflow.make_empty_tag_requirements()
        -- FGameplayTagRequirements:
        --   RequireTags : FGameplayTagContainer
        --   IgnoreTags  : FGameplayTagContainer
        --   TagQuery    : FGameplayTagQuery
        --
        -- The native create flow uses this struct for ConfirmNewDatabankCharacter.
        -- A zero/empty requirement set is the least permissive *filter state* in
        -- the sense that it imposes no additional tag requirements.
        return {
            RequireTags = {
                GameplayTags = {},
                ParentTags = {},
            },
            IgnoreTags = {
                GameplayTags = {},
                ParentTags = {},
            },
            TagQuery = {},
        }
    end

    local function snapshot_type_pool_identities(
        databank_vm,
        character_type
    )
        local identities = {}

        for _,
            pool in ipairs(
                ctx.import_validation.collect_character_pools(
                    databank_vm
                )
            ) do
            if pool.characterType
                == character_type then
                local character_vms,
                    characters_err =
                        ctx.common.read_property(
                            pool.vm,
                            "PoolCharacterViewModels"
                        )

                if characters_err == nil
                    and character_vms ~= nil then
                    ctx.import_validation.for_each_counted_array(
                        character_vms,
                        function(
                            _,
                            character_vm
                        )
                            identities[
                                ctx.import_validation.array_object_identity(
                                    character_vm
                                )
                            ] =
                                true
                        end
                    )
                end
            end
        end

        return identities
    end

    local function scan_new_type_pool_entries(
        databank_vm,
        character_type,
        baseline_identities
    )
        local entries = {}
        local unreadable = 0

        baseline_identities =
            baseline_identities or {}

        for _,
            pool in ipairs(
                ctx.import_validation.collect_character_pools(
                    databank_vm
                )
            ) do
            if pool.characterType
                == character_type then
                local character_vms,
                    characters_err =
                        ctx.common.read_property(
                            pool.vm,
                            "PoolCharacterViewModels"
                        )

                if characters_err == nil
                    and character_vms ~= nil then
                    ctx.import_validation.for_each_counted_array(
                        character_vms,
                        function(
                            _,
                            character_vm
                        )
                            local identity =
                                ctx.import_validation.array_object_identity(
                                    character_vm
                                )

                            if not baseline_identities[
                                identity
                            ] then
                                local candidate_name,
                                    candidate_err =
                                        ctx.import_validation.get_pool_character_display_name(
                                            character_vm
                                        )

                                if candidate_err ~= nil
                                    or candidate_name == nil then
                                    unreadable =
                                        unreadable + 1
                                else
                                    table.insert(
                                        entries,
                                        {
                                            name = candidate_name,
                                            identity = identity,
                                            vm = character_vm,
                                            pool = pool.source,
                                        }
                                    )
                                end
                            end
                        end
                    )
                end
            end
        end

        return entries,
            unreadable
    end

    local function verify_headless_created_character(
        databank_vm,
        payload,
        baseline_identities,
        attempt
    )
        attempt =
            attempt or 1

        local expected_name =
                ctx.import_validation.payload_full_name(
                    payload
                )

            local normalized_expected =
                ctx.import_validation.normalize_character_name(
                    expected_name
                )

            local new_entries,
                unreadable =
                    scan_new_type_pool_entries(
                        databank_vm,
                        payload.characterType,
                        baseline_identities
                    )

            for _,
                entry in ipairs(
                    new_entries
                ) do
                if ctx.import_validation.normalize_character_name(
                    entry.name
                ) ==
                    normalized_expected then
                    ctx.logging.log(
                        string.format(
                            "NATIVE CREATE VERIFIED: '%s' appeared in the %s pool after %d check(s).",
                            expected_name,
                            ctx.character_staging.creator_name(
                                payload.characterType
                            ),
                            attempt
                        )
                    )

                    ctx.import_validation.clear_pending_import()

                    ctx.popup.show_notice_popup(
                        "IMPORT COMPLETE",
                        string.format(
                            "%s was added to Character Databank.",
                            expected_name
                        ),
                        4200
                    )

                    return
                end
            end

            if #new_entries > 0
                and (
                    attempt == 1
                    or attempt == 5
                    or attempt == 10
                ) then
                local observed_names = {}

                for _,
                    entry in ipairs(
                        new_entries
                    ) do
                    table.insert(
                        observed_names,
                        entry.name
                    )
                end

                ctx.logging.log(
                    string.format(
                        "NATIVE CREATE VERIFY: new %s pool entry observed, but name does not yet match payload (expected='%s' observed='%s').",
                        ctx.character_staging.creator_name(
                            payload.characterType
                        ),
                        expected_name,
                        table.concat(
                            observed_names,
                            "', '"
                        )
                    )
                )
            end

            if unreadable > 0
                and (
                    attempt == 1
                    or attempt == 10
                ) then
                ctx.logging.log(
                    string.format(
                        "NATIVE CREATE VERIFY WARNING: %d newly-created candidate(s) were unreadable on check %d.",
                        unreadable,
                        attempt
                    )
                )
            end

            if attempt < 20 then
                ctx.layout.run_group_after(
                    "import_create",
                    100,
                    function()
                        verify_headless_created_character(
                            databank_vm,
                            payload,
                            baseline_identities,
                            attempt + 1
                        )
                    end,
                    databank_vm
                )
                return
            end

            -- A native pool identity delta is stronger evidence of successful
            -- creation than an exact display-name match. In particular, Astromech
            -- characters only persist the game's single native name field; a
            -- synthetic/imported payload containing a separate LastName can be
            -- normalized by the native commit to the FirstName.
            if #new_entries > 0 then
                local observed_names = {}

                for _,
                    entry in ipairs(
                        new_entries
                    ) do
                    table.insert(
                        observed_names,
                        entry.name
                    )
                end

                local observed =
                    table.concat(
                        observed_names,
                        "', '"
                    )

                ctx.logging.log(
                    string.format(
                        "NATIVE CREATE VERIFIED WITH NAME CHANGE: native pool entry was created, but expected='%s' observed='%s'.",
                        expected_name,
                        observed
                    )
                )

                ctx.import_validation.clear_pending_import()

                ctx.popup.show_notice_popup(
                    "IMPORT COMPLETE - NAME ADJUSTED",
                    string.format(
                        "The character was imported as '%s'. The game did not keep the requested name '%s'.",
                        observed,
                        expected_name
                    ),
                    6500
                )

                return
            end

            ctx.logging.log(
                "NATIVE CREATE VERIFY UNCERTAIN: Confirm returned success, but no new character identity was observed in the target pool within 2 seconds."
            )

        ctx.popup.show_notice_popup(
                "IMPORT STATUS UNCERTAIN",
                "The native create transaction returned success, but Character Share could not observe a new character entry in the target Databank pool. Check the list before retrying so you do not create a duplicate.",
                6000
            )
    end

    local function wait_for_headless_draft_then_stage(
        databank_vm,
        new_vm,
        payload,
        baseline_identities,
        attempt,
        previous_slot_count,
        stable_checks
    )
        attempt =
            attempt or 1

        stable_checks =
            stable_checks or 0

        local character_vm,
                character_vm_err =
                    ctx.common.read_property(
                        new_vm,
                        "CharacterVM"
                    )

            if character_vm_err == nil
                and character_vm ~= nil then
                local live_type,
                    live_slot_count,
                    live_type_err =
                        ctx.character_staging.detect_live_creator_type(
                            character_vm
                        )

                if live_type == payload.characterType then
                    local current_count =
                        live_slot_count or 0

                    if previous_slot_count == current_count then
                        stable_checks =
                            stable_checks + 1
                    else
                        stable_checks = 0
                    end

                    if stable_checks >= 1 then
                        ctx.logging.log(
                            string.format(
                                "NATIVE CREATE DRAFT READY: %s (%d live slots) after %d check(s).",
                                ctx.character_staging.creator_name(live_type),
                                current_count,
                                attempt
                            )
                        )

                        local staged,
                            stage_err =
                                stage_auto_import_into_character_vm(
                                    payload,
                                    character_vm,
                                    "NATIVE CREATE",
                                    false
                                )

                        if not staged then
                            auto_import_fail(
                                "NATIVE IMPORT FAILED",
                                "Native draft staging failed: "
                                    .. tostring(
                                        stage_err
                                    ),
                                new_vm
                            )
                            return
                        end

                        ctx.logging.log(
                            "NATIVE CREATE STAGED: calling native ConfirmNewDatabankCharacter with empty GameplayTagRequirements."
                        )

                        local confirmed,
                            confirm_err =
                                ctx.common.try_call(
                                    function()
                                        return new_vm:ConfirmNewDatabankCharacter(
                                            ctx.import_workflow.make_empty_tag_requirements()
                                        )
                                    end
                                )

                        if confirm_err ~= nil then
                            auto_import_fail(
                                "NATIVE IMPORT FAILED",
                                "ConfirmNewDatabankCharacter call failed: "
                                    .. tostring(
                                        confirm_err
                                    ),
                                new_vm
                            )
                            return
                        end

                        if confirmed ~= true then
                            auto_import_fail(
                                "NATIVE IMPORT FAILED",
                                "ConfirmNewDatabankCharacter returned "
                                    .. tostring(
                                        confirmed
                                    )
                                    .. ".",
                                new_vm
                            )
                            return
                        end

                        ctx.logging.log(
                            "NATIVE CREATE CONFIRMED: native ConfirmNewDatabankCharacter returned true."
                        )

                        verify_headless_created_character(
                            databank_vm,
                            payload,
                            baseline_identities,
                            1
                        )

                        return
                    end

                    ctx.layout.run_group_after(
                        "import_create",
                        100,
                        function()
                            wait_for_headless_draft_then_stage(
                                databank_vm,
                                new_vm,
                                payload,
                                baseline_identities,
                                attempt + 1,
                                current_count,
                                stable_checks
                            )
                        end,
                        databank_vm,
                        new_vm
                    )

                    return
                elseif live_type ~= nil then
                    auto_import_fail(
                        "NATIVE IMPORT FAILED",
                        "Native draft initialized as "
                            .. ctx.character_staging.creator_name(live_type)
                            .. " instead of "
                            .. ctx.character_staging.creator_name(payload.characterType)
                            .. ".",
                        new_vm
                    )
                    return
                elseif live_type_err ~= nil then
                    ctx.logging.log(
                        "NATIVE CREATE waiting for draft type/slot initialization: "
                            .. tostring(
                                live_type_err
                            )
                    )
                end
            end

            if attempt >= 30 then
                auto_import_fail(
                    "NATIVE IMPORT FAILED",
                    "The native draft CharacterVM did not become ready within 3 seconds.",
                    new_vm
                )
                return
            end

        ctx.layout.run_group_after(
                "import_create",
                100,
                function()
                    wait_for_headless_draft_then_stage(
                        databank_vm,
                        new_vm,
                        payload,
                        baseline_identities,
                        attempt + 1,
                        previous_slot_count,
                        stable_checks
                    )
                end,
                databank_vm,
                new_vm
            )
    end

    function ctx.import_workflow.begin_new_import_stage(payload)
        ctx.logging.transition(
            "import",
            "creating",
            payload and ctx.import_validation.payload_full_name(payload)
                or "missing payload"
        )
        ctx.popup.safe_remove_popup()

        ctx.layout.cancel_action_group(
            "import_create",
            "new native import started"
        )
        ctx.layout.cancel_action_group(
            "overwrite_verification",
            "new native import started"
        )

        if payload == nil then
            ctx.popup.show_notice_popup(
                "IMPORT FAILED",
                "No validated Character Share payload is pending.",
                3200
            )
            return
        end

        ctx.state.pending_import_payload =
            payload

        local databank_vm =
            ctx.common.find_first(
                "BrunoCharacterDatabankViewModel"
            )

        if databank_vm == nil then
            auto_import_fail(
                "NATIVE IMPORT FAILED",
                "Character Databank is not ready.",
                nil
            )
            return
        end

        local existing_new_vm,
            existing_active =
                active_new_character_session(
                    databank_vm
                )

        if existing_active ~= nil then
            ctx.popup.show_notice_popup(
                "NATIVE IMPORT BLOCKED",
                "A native Create New session is already active. Save or cancel it before importing this character.",
                4600
            )
            return
        end

        local baseline_identities =
            snapshot_type_pool_identities(
                databank_vm,
                payload.characterType
            )

        local baseline_count = 0

        for _,
            _ in pairs(
                baseline_identities
            ) do
            baseline_count =
                baseline_count + 1
        end

        ctx.logging.log(
            string.format(
                "NATIVE CREATE START: '%s' -> %s; editor UI will not be opened. Baseline pool identities=%d.",
                ctx.import_validation.payload_full_name(payload),
                ctx.character_staging.creator_name(payload.characterType),
                baseline_count
            )
        )

        local _,
            create_err =
                ctx.common.try_call(
                    function()
                        databank_vm:CreateNewDatabankCharacter()
                    end
                )

        if create_err ~= nil then
            auto_import_fail(
                "NATIVE IMPORT FAILED",
                "CreateNewDatabankCharacter failed: "
                    .. tostring(
                        create_err
                    ),
                nil
            )
            return
        end

        local new_vm,
            new_vm_err =
                ctx.common.read_property(
                    databank_vm,
                    "DatabankNewCharacterVM"
                )

        if new_vm_err ~= nil
            or new_vm == nil then
            auto_import_fail(
                "NATIVE IMPORT FAILED",
                "DatabankNewCharacterVM was unavailable after CreateNewDatabankCharacter.",
                nil
            )
            return
        end

        local type_value =
            payload.characterType == "astromech"
                and 2
                or 1

        ctx.logging.log(
            string.format(
                "NATIVE CREATE TYPE: SetDatabankCharacterType(%d) for %s.",
                type_value,
                ctx.character_staging.creator_name(payload.characterType)
            )
        )

        local _,
            type_err =
                ctx.common.try_call(
                    function()
                        new_vm:SetDatabankCharacterType(
                            type_value
                        )
                    end
                )

        if type_err ~= nil then
            auto_import_fail(
                "NATIVE IMPORT FAILED",
                "SetDatabankCharacterType failed: "
                    .. tostring(
                        type_err
                    ),
                new_vm
            )
            return
        end

        wait_for_headless_draft_then_stage(
            databank_vm,
            new_vm,
            payload,
            baseline_identities,
            1,
            nil,
            0
        )
    end
end
