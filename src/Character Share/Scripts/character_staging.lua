-- Character Share: character staging.
-- Initialized once per mod instance; shared references use explicit ctx fields.
-- Context: character_staging, common, dependencies, import_validation, logging, state.
return function(ctx)
    local function current_slot_map(character_vm)
        local map = {}

        local customization_vm, customization_err =
            ctx.common.read_property(character_vm, "CustomizationInstanceVM")
        if customization_err ~= nil or customization_vm == nil then
            return nil, "CustomizationInstanceVM unavailable"
        end

        local slot_vms, slots_err = ctx.common.read_property(customization_vm, "SlotViewModels")
        if slots_err ~= nil or slot_vms == nil then
            return nil, "SlotViewModels unavailable"
        end

        ctx.common.for_each_array(slot_vms, function(_, slot_vm)
            local slot_tag_struct, tag_err = ctx.common.read_property(slot_vm, "SlotTag")
            if tag_err == nil and slot_tag_struct ~= nil then
                local tag = ctx.common.gameplay_tag_value(slot_tag_struct)
                if tag ~= nil and tag ~= "" then
                    map[tag] = slot_vm
                end
            end
        end)

        return map, nil
    end

    local function equipped_asset_for_slot(slot_vm)
        local equipped_vm, equipped_err =
            ctx.common.read_property(slot_vm, "EquippedCustomizationPartViewModel")

        if equipped_err ~= nil or equipped_vm == nil then
            return nil
        end

        local asset_id, asset_err = ctx.common.read_property(equipped_vm, "AssetId")
        if asset_err ~= nil or asset_id == nil then
            return nil
        end

        return ctx.common.primary_asset_id_value(asset_id)
    end

    local function previewed_asset_for_slot(slot_vm)
        local preview_vm, preview_err =
            ctx.common.try_call(
                function()
                    return slot_vm:PreviewedCustomizationPartViewModel()
                end
            )

        if preview_err ~= nil
            or preview_vm == nil then
            return nil,
                preview_err
        end

        local asset_id, asset_err =
            ctx.common.read_property(
                preview_vm,
                "AssetId"
            )

        if asset_err ~= nil
            or asset_id == nil then
            return nil,
                asset_err
        end

        return ctx.common.primary_asset_id_value(asset_id),
            nil
    end

    local function parse_asset_id(asset)
        if asset == nil then
            return nil, nil
        end

        return asset:match("^([^:]+):(.+)$")
    end

    local function get_part_vm_cdo()
        local class_object, class_err = ctx.common.try_call(function()
            return StaticFindObject("/Script/BitReactorGame.BitReactorCustomizationPartViewModel")
        end)

        if class_err ~= nil or class_object == nil then
            return nil, "could not find BitReactorCustomizationPartViewModel class"
        end

        local cdo, cdo_err = ctx.common.try_call(function()
            return class_object:GetCDO()
        end)

        if cdo_err ~= nil or cdo == nil then
            return nil, "could not get BitReactorCustomizationPartViewModel CDO"
        end

        return cdo, nil
    end

    local function get_part_vm_for_asset(world_context, asset)
        if asset == nil then
            local none_vm = ctx.common.find_first("BitReactorNoneCustomizationPartViewModel")
            if none_vm == nil then
                return nil, "could not find game's None customization part ViewModel"
            end
            return none_vm, nil
        end

        local asset_type, asset_name = parse_asset_id(asset)
        if asset_type == nil or asset_name == nil then
            return nil, "invalid asset id: " .. tostring(asset)
        end

        local cdo, cdo_err = get_part_vm_cdo()
        if cdo_err ~= nil then
            return nil, cdo_err
        end

        -- UE4SS supports passing Lua tables for reflected struct parameters.
        local part_id = {
            PrimaryAssetType = {
                Name = FName(asset_type),
            },
            PrimaryAssetName = FName(asset_name),
        }

        local part_vm, part_err = ctx.common.try_call(function()
            return cdo:GetOrCreateCachedCustomizationPartViewModelFromPartId(
                world_context,
                part_id
            )
        end)

        if part_err ~= nil or part_vm == nil then
            return nil, "could not create part ViewModel for " .. asset .. ": " .. tostring(part_err)
        end

        return part_vm, nil
    end

    local function make_primary_asset_id(asset)
        local asset_type,
            asset_name =
                parse_asset_id(
                    asset
                )

        if asset_type == nil
            or asset_name == nil then
            return nil,
                "invalid asset id: "
                    .. tostring(
                        asset
                    )
        end

        return {
            PrimaryAssetType = {
                Name = FName(
                    asset_type
                ),
            },
            PrimaryAssetName = FName(
                asset_name
            ),
        },
            nil
    end

    local function find_core_customization_instance(
        slots
    )
        local slots_examined =
            0

        local fragments_examined =
            0

        local direct_owner_errors =
            0

        local slot_owner_errors =
            0

        local first_direct_error =
            nil

        local first_slot_error =
            nil

        for _,
            candidate_slot in pairs(
                slots
            ) do
            slots_examined =
                slots_examined + 1

            local fragments,
                fragments_err =
                    ctx.common.try_call(
                        function()
                            return candidate_slot:GetFragments()
                        end
                    )

            if fragments_err == nil
                and fragments ~= nil then
                local found_instance =
                    nil

                ctx.common.for_each_array(
                    fragments,
                    function(
                        _,
                        fragment_value
                    )
                        if found_instance ~= nil
                            or fragment_value == nil then
                            return
                        end

                        fragments_examined =
                            fragments_examined + 1

                        local fragment =
                            ctx.common.unwrap_remote_value(
                                fragment_value
                            )

                        -- Some fragment types carry a direct owning-instance link.
                        local instance_value,
                            instance_err =
                                ctx.common.try_call(
                                    function()
                                        return fragment:GetOwningCustomizationInstance()
                                    end
                                )

                        if instance_err == nil
                            and instance_value ~= nil then
                            local instance =
                                ctx.common.unwrap_remote_value(
                                    instance_value
                                )

                            if instance ~= nil then
                                found_instance =
                                    instance

                                return
                            end
                        end

                        if instance_err ~= nil then
                            direct_owner_errors =
                                direct_owner_errors + 1

                            if first_direct_error == nil then
                                first_direct_error =
                                    instance_err
                            end
                        end

                        -- Child fragments may belong to a Core slot rather than
                        -- carrying the CustomizationInstance directly.
                        local owning_slot_value,
                            owning_slot_err =
                                ctx.common.try_call(
                                    function()
                                        return fragment:GetOwningCustomizationSlot()
                                    end
                                )

                        if owning_slot_err ~= nil
                            or owning_slot_value == nil then
                            if owning_slot_err ~= nil then
                                slot_owner_errors =
                                    slot_owner_errors + 1

                                if first_slot_error == nil then
                                    first_slot_error =
                                        owning_slot_err
                                end
                            end

                            return
                        end

                        local owning_slot =
                            ctx.common.unwrap_remote_value(
                                owning_slot_value
                            )

                        local slot_instance_value,
                            slot_instance_err =
                                ctx.common.try_call(
                                    function()
                                        return owning_slot:GetOwningCustomizationInstance()
                                    end
                                )

                        if slot_instance_err == nil
                            and slot_instance_value ~= nil then
                            local slot_instance =
                                ctx.common.unwrap_remote_value(
                                    slot_instance_value
                                )

                            if slot_instance ~= nil then
                                found_instance =
                                    slot_instance

                                return
                            end
                        end

                        if slot_instance_err ~= nil then
                            slot_owner_errors =
                                slot_owner_errors + 1

                            if first_slot_error == nil then
                                first_slot_error =
                                    slot_instance_err
                            end
                        end
                    end
                )

                if found_instance ~= nil then
                    ctx.logging.log(
                        string.format(
                            "MOD-COMPAT CORE OWNER RESOLVED: slots=%d fragments=%d directErrors=%d slotErrors=%d",
                            slots_examined,
                            fragments_examined,
                            direct_owner_errors,
                            slot_owner_errors
                        )
                    )

                    return found_instance,
                        nil
                end
            end
        end

        return nil,
            string.format(
                "could not resolve the Core CustomizationInstance from live slot fragments (slots=%d fragments=%d directErrors=%d slotErrors=%d firstDirect=%s firstSlot=%s)",
                slots_examined,
                fragments_examined,
                direct_owner_errors,
                slot_owner_errors,
                tostring(
                    first_direct_error
                ),
                tostring(
                    first_slot_error
                )
            )
    end

    local function core_slot_asset(
        core_slot
    )
        local asset_id,
            asset_err =
                ctx.common.try_call(
                    function()
                        return core_slot:GetCustomizationPartPrimaryAssetId()
                    end
                )

        if asset_err ~= nil then
            return nil,
                asset_err
        end

        return ctx.common.primary_asset_id_value(
            asset_id
        ),
            nil
    end

    local function restore_core_slot_asset(
        core_instance,
        slot_tag_struct,
        original_asset
    )
        local restore_slot,
            restore_slot_err =
                ctx.common.try_call(
                    function()
                        return core_instance:GetSlotInstance(
                            slot_tag_struct
                        )
                    end
                )

        restore_slot =
            ctx.common.unwrap_remote_value(
                restore_slot
            )

        if restore_slot_err ~= nil
            or restore_slot == nil then
            return false,
                "could not reacquire Core slot for rollback: "
                    .. tostring(
                        restore_slot_err
                    )
        end

        if original_asset == nil then
            local _,
                unequip_err =
                    ctx.common.try_call(
                        function()
                            restore_slot:UnEquip()
                        end
                    )

            if unequip_err ~= nil then
                return false,
                    "rollback UnEquip failed: "
                        .. tostring(
                            unequip_err
                        )
            end
        else
            local original_id,
                original_id_err =
                    make_primary_asset_id(
                        original_asset
                    )

            if original_id_err ~= nil then
                return false,
                    original_id_err
            end

            local _,
                restore_err =
                    ctx.common.try_call(
                        function()
                            restore_slot:SetCustomizationPartPrimaryAssetId(
                                original_id
                            )
                        end
                    )

            if restore_err ~= nil then
                return false,
                    "rollback SetCustomizationPartPrimaryAssetId failed: "
                        .. tostring(
                            restore_err
                        )
            end
        end

        local _,
            refresh_err =
                ctx.common.try_call(
                    function()
                        core_instance:RefreshCustomization()
                    end
                )

        if refresh_err ~= nil then
            return false,
                "rollback RefreshCustomization failed: "
                    .. tostring(
                        refresh_err
                    )
        end

        return true,
            nil
    end

    local function try_core_mod_compat_fallback(
        character_vm,
        tag,
        asset
    )
        if asset == nil then
            return false,
                "Core fallback is only used for non-empty assets"
        end

        local slots,
            slots_err =
                current_slot_map(
                    character_vm
                )

        if slots_err ~= nil then
            return false,
                slots_err
        end

        local target_slot =
            slots[
                tag
            ]

        if target_slot == nil then
            return false,
                "target slot disappeared before Core fallback"
        end

        local slot_tag_struct,
            slot_tag_err =
                ctx.common.read_property(
                    target_slot,
                    "SlotTag"
                )

        if slot_tag_err ~= nil
            or slot_tag_struct == nil then
            return false,
                "could not read target slot GameplayTag for Core fallback"
        end

        local core_instance,
            core_instance_err =
                find_core_customization_instance(
                    slots
                )

        if core_instance_err ~= nil then
            return false,
                core_instance_err
        end

        local core_slot,
            core_slot_err =
                ctx.common.try_call(
                    function()
                        return core_instance:GetSlotInstance(
                            slot_tag_struct
                        )
                    end
                )

        core_slot =
            ctx.common.unwrap_remote_value(
                core_slot
            )

        if core_slot_err ~= nil
            or core_slot == nil then
            return false,
                "Core GetSlotInstance failed: "
                    .. tostring(
                        core_slot_err
                    )
        end

        local original_asset,
            original_asset_err =
                core_slot_asset(
                    core_slot
                )

        if original_asset_err ~= nil then
            return false,
                "could not read original Core slot asset: "
                    .. tostring(
                        original_asset_err
                    )
        end

        local desired_id,
            desired_id_err =
                make_primary_asset_id(
                    asset
                )

        if desired_id_err ~= nil then
            return false,
                desired_id_err
        end

        local prior_unequip_invalid =
            nil

        local prior_value,
            prior_value_err =
                ctx.common.try_call(
                    function()
                        return core_instance:ShouldUnequipInvalidPartsAfterRefresh()
                    end
                )

        if prior_value_err == nil then
            prior_unequip_invalid =
                prior_value
        end

        -- The importer is deliberately setting an option that a compatibility mod
        -- already permits but the vanilla ViewModel rejected. Prevent the Core
        -- refresh from immediately deleting it while this one verified mutation is
        -- in progress. Restore the instance policy immediately afterward.
        local _,
            policy_err =
                ctx.common.try_call(
                    function()
                        core_instance:SetUnequipInvalidPartsAfterRefresh(
                            false
                        )
                    end
                )

        if policy_err ~= nil then
            ctx.logging.log(
                string.format(
                    "MOD-COMPAT CORE POLICY WARNING: %s :: %s",
                    tag,
                    tostring(
                        policy_err
                    )
                )
            )
        end

        ctx.logging.log(
            string.format(
                "MOD-COMPAT CORE ATTEMPT: %s original=%s desired=%s",
                tag,
                tostring(
                    original_asset
                ),
                asset
            )
        )

        local _,
            set_err =
                ctx.common.try_call(
                    function()
                        core_slot:SetCustomizationPartPrimaryAssetId(
                            desired_id
                        )
                    end
                )

        if set_err ~= nil then
            if prior_unequip_invalid ~= nil then
                ctx.common.try_call(
                    function()
                        core_instance:SetUnequipInvalidPartsAfterRefresh(
                            prior_unequip_invalid
                        )
                    end
                )
            end

            return false,
                "Core SetCustomizationPartPrimaryAssetId failed: "
                    .. tostring(
                        set_err
                    )
        end

        local _,
            core_refresh_err =
                ctx.common.try_call(
                    function()
                        core_instance:RefreshCustomization()
                    end
                )

        if core_refresh_err ~= nil then
            local rollback_ok,
                rollback_err =
                    restore_core_slot_asset(
                        core_instance,
                        slot_tag_struct,
                        original_asset
                    )

            if prior_unequip_invalid ~= nil then
                ctx.common.try_call(
                    function()
                        core_instance:SetUnequipInvalidPartsAfterRefresh(
                            prior_unequip_invalid
                        )
                    end
                )
            end

            return false,
                "Core RefreshCustomization failed: "
                    .. tostring(
                        core_refresh_err
                    )
                    .. " | rollback="
                    .. tostring(
                        rollback_ok
                    )
                    .. " "
                    .. tostring(
                        rollback_err
                    )
        end

        -- Refresh may rebuild the public ViewModels. Never verify through a stale
        -- slot reference.
        local refreshed,
            refreshed_err =
                current_slot_map(
                    character_vm
                )

        local verified_asset =
            nil

        if refreshed_err == nil then
            local refreshed_slot =
                refreshed[
                    tag
                ]

            if refreshed_slot ~= nil then
                verified_asset =
                    equipped_asset_for_slot(
                        refreshed_slot
                    )
            end
        end

        if verified_asset == asset then
            -- Do NOT restore bUnequipInvalidPartsAfterRefresh here.
            --
            -- The first live test proved the Core write was accepted and the
            -- public slot ViewModel immediately reported the desired unlocker-only
            -- asset, but a later creator/UI refresh could still remove it once the
            -- vanilla invalid-part policy was restored.  This CustomizationInstance
            -- belongs to the transient Create New editor, so keep the guard disabled
            -- for the rest of this editor session.  Closing/saving the creator
            -- destroys that transient instance; vanilla imports never touch this
            -- path at all.
            ctx.logging.log(
                string.format(
                    "MOD-COMPAT CORE SUCCEEDED: %s -> %s",
                    tag,
                    asset
                )
            )

            ctx.logging.log(
                string.format(
                    "MOD-COMPAT CORE GUARD HELD: invalid-part auto-unequip remains disabled for this transient Create New session (previous=%s).",
                    tostring(
                        prior_unequip_invalid
                    )
                )
            )

            return true,
                "applied via verified Core fragment fallback"
        end

        local core_after,
            core_after_err =
                ctx.common.try_call(
                    function()
                        return core_instance:GetSlotInstance(
                            slot_tag_struct
                        )
                    end
                )

        core_after =
            ctx.common.unwrap_remote_value(
                core_after
            )

        local core_asset_after =
            nil

        if core_after_err == nil
            and core_after ~= nil then
            core_asset_after =
                select(
                    1,
                    core_slot_asset(
                        core_after
                    )
                )
        end

        ctx.logging.log(
            string.format(
                "MOD-COMPAT CORE VERIFY FAILED: %s public=%s core=%s; rolling back.",
                tag,
                tostring(
                    verified_asset
                ),
                tostring(
                    core_asset_after
                )
            )
        )

        local rollback_ok,
            rollback_err =
                restore_core_slot_asset(
                    core_instance,
                    slot_tag_struct,
                    original_asset
                )

        if prior_unequip_invalid ~= nil then
            ctx.common.try_call(
                function()
                    core_instance:SetUnequipInvalidPartsAfterRefresh(
                        prior_unequip_invalid
                    )
                end
            )
        end

        if not rollback_ok then
            ctx.logging.log(
                string.format(
                    "MOD-COMPAT CORE ROLLBACK FAILED: %s :: %s",
                    tag,
                    tostring(
                        rollback_err
                    )
                )
            )
        else
            ctx.logging.log(
                string.format(
                    "MOD-COMPAT CORE ROLLBACK COMPLETE: %s -> %s",
                    tag,
                    tostring(
                        original_asset
                    )
                )
            )
        end

        return false,
            string.format(
                "Core fallback verification mismatch (wanted=%s public=%s core=%s rollback=%s)",
                tostring(
                    asset
                ),
                tostring(
                    verified_asset
                ),
                tostring(
                    core_asset_after
                ),
                tostring(
                    rollback_ok
                )
            )
    end

    local function apply_slot(character_vm, tag, asset)
        local slots, slots_err = current_slot_map(character_vm)
        if slots_err ~= nil then
            return false, slots_err
        end

        local slot_vm = slots[tag]
        if slot_vm == nil then
            if asset == nil then
                return true, "absent; desired None"
            end

            return false, "target character has no slot " .. tag
        end

        local current_asset = equipped_asset_for_slot(slot_vm)
        if current_asset == asset then
            return true, "already set"
        end

        local part_vm, part_err = get_part_vm_for_asset(character_vm, asset)
        if part_err ~= nil then
            return false, part_err
        end

        local _, equip_err = ctx.common.try_call(function()
            slot_vm:EquipCustomizationPart(part_vm)
        end)

        if equip_err ~= nil then
            return false, "EquipCustomizationPart failed: " .. equip_err
        end

        -- Re-read through a fresh slot map because equipping a high-level part can
        -- rebuild descendant slots and invalidate old ViewModel references.
        local refreshed, refresh_err = current_slot_map(character_vm)
        if refresh_err ~= nil then
            return false, refresh_err
        end

        local refreshed_slot = refreshed[tag]
        if refreshed_slot == nil then
            return false, "slot disappeared after equip: " .. tag
        end

        local verified_asset = equipped_asset_for_slot(refreshed_slot)
        if verified_asset ~= asset then
            -- Some customization-unlocker mods expose cross-archetype/species
            -- options through the game's preview/selection path even though a
            -- direct EquipCustomizationPart() call is rejected by the vanilla
            -- slot logic.  Do not whitelist or reinterpret the asset here:
            -- attempt the game's own preview path once, verify that the exact
            -- desired asset was accepted as the slot preview, then retry the
            -- normal equip call.
            --
            -- This keeps Character Share's wire format and dictionary global:
            -- modded combinations remain transportable without hard-coding which
            -- talents/colors/parts are "allowed" in which slot.
            if asset ~= nil then
                local _, preview_err =
                    ctx.common.try_call(
                        function()
                            refreshed_slot:PreviewCustomizationPart(
                                part_vm
                            )
                        end
                    )

                if preview_err == nil then
                    local preview_asset,
                        preview_read_err =
                            previewed_asset_for_slot(
                                refreshed_slot
                            )

                    if preview_read_err == nil
                        and preview_asset == asset then
                        ctx.logging.log(
                            string.format(
                                "MOD-COMPAT PREVIEW ACCEPTED: %s -> %s; retrying normal equip.",
                                tag,
                                asset
                            )
                        )

                        -- Previewing can also rebuild slot ViewModels, so reacquire
                        -- the slot before touching it again.
                        local preview_refreshed,
                            preview_refresh_err =
                                current_slot_map(
                                    character_vm
                                )

                        if preview_refresh_err == nil then
                            local preview_slot =
                                preview_refreshed[
                                    tag
                                ]

                            if preview_slot ~= nil then
                                local _,
                                    retry_equip_err =
                                        ctx.common.try_call(
                                            function()
                                                preview_slot:EquipCustomizationPart(
                                                    part_vm
                                                )
                                            end
                                        )

                                if retry_equip_err == nil then
                                    local final_map,
                                        final_map_err =
                                            current_slot_map(
                                                character_vm
                                            )

                                    if final_map_err == nil then
                                        local final_slot =
                                            final_map[
                                                tag
                                            ]

                                        if final_slot ~= nil then
                                            local final_asset =
                                                equipped_asset_for_slot(
                                                    final_slot
                                                )

                                            if final_asset == asset then
                                                ctx.logging.log(
                                                    string.format(
                                                        "MOD-COMPAT EQUIP SUCCEEDED: %s -> %s",
                                                        tag,
                                                        asset
                                                    )
                                                )

                                                return true,
                                                    "applied via mod-compat preview fallback"
                                            end
                                        end
                                    end
                                end
                            end
                        end

                        ctx.logging.log(
                            string.format(
                                "MOD-COMPAT PREVIEW DID NOT COMMIT: %s -> %s",
                                tag,
                                asset
                            )
                        )
                    elseif preview_read_err ~= nil then
                        ctx.logging.log(
                            string.format(
                                "MOD-COMPAT PREVIEW READ FAILED: %s :: %s",
                                tag,
                                tostring(
                                    preview_read_err
                                )
                            )
                        )
                    else
                        ctx.logging.log(
                            string.format(
                                "MOD-COMPAT PREVIEW REJECTED: %s wanted=%s preview=%s",
                                tag,
                                tostring(
                                    asset
                                ),
                                tostring(
                                    preview_asset
                                )
                            )
                        )
                    end
                else
                    ctx.logging.log(
                        string.format(
                            "MOD-COMPAT PREVIEW CALL FAILED: %s :: %s",
                            tag,
                            tostring(
                                preview_err
                            )
                        )
                    )
                end
            end

            if asset ~= nil then
                local core_ok,
                    core_result =
                        try_core_mod_compat_fallback(
                            character_vm,
                            tag,
                            asset
                        )

                if core_ok then
                    return true,
                        core_result
                end

                ctx.logging.log(
                    string.format(
                        "MOD-COMPAT CORE FAILED: %s :: %s",
                        tag,
                        tostring(
                            core_result
                        )
                    )
                )
            end

            return false, string.format(
                "verification mismatch for %s (wanted=%s got=%s)",
                tag,
                tostring(asset),
                tostring(verified_asset)
            )
        end

        return true, "applied"
    end

    function ctx.character_staging.detect_live_creator_type(character_vm)
        local slots, slots_err = current_slot_map(character_vm)
        if slots_err ~= nil then
            return nil, 0, slots_err
        end

        local humanoid = false
        local astromech = false
        local count = 0

        for tag, _ in pairs(slots) do
            count = count + 1

            if string.find(
                tag,
                "br.Customization.Slot.Character.Appearance.Humanoid.",
                1,
                true
            ) then
                humanoid = true
            elseif string.find(
                tag,
                "br.Customization.Slot.Character.Appearance.Astromech.",
                1,
                true
            ) then
                astromech = true
            end
        end

        if humanoid and not astromech then
            return "humanoid", count, nil
        elseif astromech and not humanoid then
            return "astromech", count, nil
        elseif humanoid and astromech then
            return nil, count, "live editor contains both Humanoid and Astromech slot trees"
        end

        return nil, count, "could not identify an active Humanoid/Astromech creator slot tree"
    end

    function ctx.character_staging.creator_name(character_type)
        if character_type == "astromech" then
            return "Astromech"
        elseif character_type == "humanoid" then
            return "Custom Character"
        end

        return tostring(character_type)
    end

    local function trimmed_text(value)
        local text =
            tostring(value or "")

        return text
            :gsub("^%s+", "")
            :gsub("%s+$", "")
    end

    local function live_creator_name(
        character_vm,
        character_type
    )
        if character_vm == nil then
            return nil, nil
        end

        local first =
            trimmed_text(
                ctx.common.text_value(
                    select(
                        1,
                        ctx.common.read_property(
                            character_vm,
                            "FirstName"
                        )
                    )
                )
            )

        local last =
            trimmed_text(
                ctx.common.text_value(
                    select(
                        1,
                        ctx.common.read_property(
                            character_vm,
                            "LastName"
                        )
                    )
                )
            )

        local full =
            trimmed_text(
                ctx.common.text_value(
                    select(
                        1,
                        ctx.common.read_property(
                            character_vm,
                            "FullName"
                        )
                    )
                )
            )

        if character_type == "astromech" then
            local name =
                first ~= ""
                    and first
                    or full

            if name == "" then
                return nil, nil
            end

            return name, ""
        end

        if first == "" and last == "" then
            return nil, nil
        end

        return first, last
    end

    function ctx.character_staging.matching_active_new_character_vm(
        databank_vm,
        character_type
    )
        if databank_vm == nil then
            return nil, "Character Databank ViewModel unavailable"
        end

        local new_vm, new_vm_err =
            ctx.common.read_property(
                databank_vm,
                "DatabankNewCharacterVM"
            )

        if new_vm_err ~= nil or new_vm == nil then
            return nil, "no native new-character ViewModel"
        end

        local character_vm, character_vm_err =
            ctx.common.read_property(
                new_vm,
                "CharacterVM"
            )

        if character_vm_err ~= nil
            or character_vm == nil then
            return nil, "no active new-character CharacterVM"
        end

        local live_type, _, live_type_err =
            ctx.character_staging.detect_live_creator_type(
                character_vm
            )

        if live_type_err ~= nil
            or live_type == nil then
            return nil,
                "could not verify active creator type: "
                .. tostring(live_type_err)
        end

        if live_type ~= character_type then
            return nil,
                "active creator is "
                .. ctx.character_staging.creator_name(live_type)
                .. ", not "
                .. ctx.character_staging.creator_name(character_type)
        end

        return character_vm, nil
    end

    function ctx.character_staging.adopt_manual_creator_name(
        payload,
        character_vm,
        source_label
    )
        -- Only a Character Share Rename decision opts this import session into
        -- "local/manual name wins" behavior. Otherwise the share payload remains
        -- authoritative, preserving the normal import semantics.
        if payload == nil
            or character_vm == nil
            or ctx.state.pending_name_override == nil then
            return false
        end

        local live_first, live_last =
            live_creator_name(
                character_vm,
                payload.characterType
            )

        if live_first == nil then
            return false
        end

        live_last =
            live_last or ""

        local payload_first =
            trimmed_text(
                payload.first
            )

        local payload_last =
            trimmed_text(
                payload.last
            )

        if live_first == payload_first
            and live_last == payload_last then
            return false
        end

        local old_name =
            ctx.import_validation.payload_full_name(payload)

        payload.first =
            live_first

        payload.last =
            payload.characterType == "astromech"
                and ""
                or live_last

        ctx.state.pending_name_override = {
            first = payload.first,
            last = payload.last,
        }

        ctx.state.pending_name_override_code =
            ctx.state.pending_import_code

        ctx.state.pending_import_payload =
            payload

        ctx.logging.log(
            string.format(
                "%s: adopted manual creator name '%s' -> '%s'.",
                source_label or "IMPORT",
                tostring(old_name),
                tostring(
                    ctx.import_validation.payload_full_name(payload)
                )
            )
        )

        return true
    end

    local function verify_staged_slots(
        character_vm,
        ordered_slots
    )
        local slots,
            slots_err =
                current_slot_map(
                    character_vm
                )

        if slots_err ~= nil then
            return nil,
                "could not reacquire final slot map: "
                    .. tostring(
                        slots_err
                    )
        end

        local failures = {}

        for _,
            item in ipairs(
                ordered_slots
            ) do
            local slot_vm =
                slots[
                    item.tag
                ]

            if slot_vm == nil then
                if item.asset ~= nil then
                    table.insert(
                        failures,
                        {
                            item = item,
                            actual = nil,
                            detail = "slot missing during final verification",
                        }
                    )
                end
            else
                local actual =
                    equipped_asset_for_slot(
                        slot_vm
                    )

                if actual ~= item.asset then
                    table.insert(
                        failures,
                        {
                            item = item,
                            actual = actual,
                            detail = "final verification mismatch",
                        }
                    )
                end
            end
        end

        return failures,
            nil
    end

    function ctx.character_staging.stage_payload_to_character_vm(
        payload,
        character_vm,
        session_label
    )
        local live_type, live_slot_count, live_type_err =
            ctx.character_staging.detect_live_creator_type(character_vm)

        if live_type_err ~= nil or live_type == nil then
            return false,
                "could not verify editor type: " .. tostring(live_type_err)
        end

        ctx.logging.log(
            string.format(
                "%s editor verified: %s (%d live slots).",
                session_label or "Import",
                ctx.character_staging.creator_name(live_type),
                live_slot_count
            )
        )

        if live_type ~= payload.characterType then
            return false,
                "payload type is "
                .. ctx.character_staging.creator_name(payload.characterType)
                .. " but editor is "
                .. ctx.character_staging.creator_name(live_type)
        end

        local ordered_slots = ctx.dependencies.Character.sorted_slots(payload)
        local applied = 0
        local already_set = 0
        local satisfied_absent_none = 0
        local remaining = ordered_slots
        local final_failures = {}

        -- Equipping high-level customization parts can rebuild descendant slot
        -- ViewModels. Humanoid usually settles fast enough for one pass, but the
        -- Astromech tree can expose a conditional descendant only after another
        -- parent part is equipped. Retry only the failures after the rest of the
        -- pass has had a chance to rebuild the tree.
        for pass = 1, 3 do
            local failures = {}

            for _, item in ipairs(remaining) do
                local ok, detail =
                    apply_slot(
                        character_vm,
                        item.tag,
                        item.asset
                    )

                if ok then
                    applied = applied + 1

                    if detail == "already set" then
                        already_set = already_set + 1
                    elseif detail == "absent; desired None" then
                        satisfied_absent_none =
                            satisfied_absent_none + 1
                    end
                else
                    table.insert(
                        failures,
                        {
                            item = item,
                            detail = detail,
                        }
                    )

                    ctx.logging.log(
                        string.format(
                            "%s SLOT RETRY[%d]: %s -> %s :: %s",
                            session_label or "IMPORT",
                            pass,
                            item.tag,
                            tostring(item.asset),
                            tostring(detail)
                        )
                    )
                end
            end

            if #failures == 0 then
                final_failures = {}
                break
            end

            final_failures = failures

            if pass < 3 then
                remaining = {}

                for _, failure in ipairs(failures) do
                    table.insert(
                        remaining,
                        failure.item
                    )
                end
            end
        end

        if #final_failures > 0 then
            local first =
                final_failures[1]

            return false,
                string.format(
                    "%d/%d slots failed; first: %s :: %s",
                    #final_failures,
                    #ordered_slots,
                    tostring(first.item.tag),
                    tostring(first.detail)
                )
        end

        -- Earlier versions verified each slot only at the moment it was applied.
        -- A later parent/weapon/UI refresh could invalidate an earlier slot without
        -- being noticed.  Verify the *entire final tree* after all mutations.
        local final_verify,
            final_verify_err =
                verify_staged_slots(
                    character_vm,
                    ordered_slots
                )

        if final_verify_err ~= nil then
            return false,
                final_verify_err
        end

        if #final_verify > 0 then
            ctx.logging.log(
                string.format(
                    "%s FINAL VERIFY: %d slot(s) drifted after later customization updates; running one bounded stabilization pass.",
                    session_label or "IMPORT",
                    #final_verify
                )
            )

            for _,
                failure in ipairs(
                    final_verify
                ) do
                local stabilize_ok,
                    stabilize_detail =
                        apply_slot(
                            character_vm,
                            failure.item.tag,
                            failure.item.asset
                        )

                if not stabilize_ok then
                    ctx.logging.log(
                        string.format(
                            "%s FINAL STABILIZE FAILED: %s wanted=%s actual=%s :: %s",
                            session_label or "IMPORT",
                            failure.item.tag,
                            tostring(
                                failure.item.asset
                            ),
                            tostring(
                                failure.actual
                            ),
                            tostring(
                                stabilize_detail
                            )
                        )
                    )
                else
                    ctx.logging.log(
                        string.format(
                            "%s FINAL STABILIZE APPLIED: %s -> %s",
                            session_label or "IMPORT",
                            failure.item.tag,
                            tostring(
                                failure.item.asset
                            )
                        )
                    )
                end
            end

            final_verify,
                final_verify_err =
                    verify_staged_slots(
                        character_vm,
                        ordered_slots
                    )

            if final_verify_err ~= nil then
                return false,
                    final_verify_err
            end
        end

        if #final_verify > 0 then
            local first =
                final_verify[1]

            return false,
                string.format(
                    "%d/%d slots failed final whole-character verification; first: %s wanted=%s got=%s",
                    #final_verify,
                    #ordered_slots,
                    tostring(
                        first.item.tag
                    ),
                    tostring(
                        first.item.asset
                    ),
                    tostring(
                        first.actual
                    )
                )
        end

        ctx.logging.log(
            string.format(
                "%s FINAL VERIFY COMPLETE: all %d final live slots match the payload.",
                session_label or "IMPORT",
                #ordered_slots
            )
        )

        local _, name_err = ctx.common.try_call(function()
            character_vm:SetFullName(FText(payload.first), FText(payload.last))
        end)

        if name_err ~= nil then
            return false, "setting name failed: " .. name_err
        end

        local _, background_err = ctx.common.try_call(function()
            character_vm:SetBackgroundDescription(FText(payload.background))
        end)

        if background_err ~= nil then
            return false, "setting background failed: " .. background_err
        end

        ctx.logging.log(
            string.format(
                "%s STAGE COMPLETE: %d/%d slots satisfied; %d already correct; %d absent conditional None slot(s).",
                session_label or "IMPORT",
                applied,
                #ordered_slots,
                already_set,
                satisfied_absent_none
            )
        )

        return true, nil
    end
end
