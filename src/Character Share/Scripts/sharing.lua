-- Character Share: sharing.
-- Initialized once per mod instance; shared references use explicit ctx fields.
-- Context: common, dependencies, logging, popup, sharing.
return function(ctx)
    function ctx.sharing.decode_share_code(code)
        local payload,
            codec_meta_or_err =
                ctx.dependencies.Codec.decode(code)

        if payload == nil then
            return nil,
                codec_meta_or_err
        end

        local validated,
            validation_err =
                ctx.dependencies.Character.validate_payload(
                    payload
                )

        if validation_err ~= nil then
            return nil,
                validation_err
        end

        -- Astromechs have one native name field. Normalize here, before any
        -- import summary, duplicate detection, native-create staging, or
        -- post-create verification can observe a synthetic second name.
        if validated.characterType == "astromech" then
            validated.last = ""
        end

        return {
            payload = validated,
            format = 1,
            compactBytes =
                codec_meta_or_err.compactBytes,
            compressedBytes =
                codec_meta_or_err.compressedBytes,
        }, nil
    end

    function ctx.sharing.log_payload_summary(payload, heading)
        ctx.logging.log("------------------------------------------------------------")
        ctx.logging.log(heading or "CHARACTER SHARE PAYLOAD")
        ctx.logging.log("Name: " .. payload.first .. (payload.last ~= "" and (" " .. payload.last) or ""))
        ctx.logging.log("Type: " .. tostring(payload.characterType))
        ctx.logging.log("Archetype: " .. tostring(payload.archetype))
        ctx.logging.log("Class: " .. tostring(payload.class))
        ctx.logging.log("Secondary class: " .. tostring(payload.secondaryClass))
        ctx.logging.log("Talent: " .. tostring(payload.talent))
        ctx.logging.log("Weapon class: " .. tostring(payload.weaponClass))
        ctx.logging.log("Weapon model: " .. tostring(payload.weaponModel))
        ctx.logging.log("Rig: " .. tostring(payload.rig))
        ctx.logging.log("Slots: " .. tostring(#payload.slots))
        ctx.logging.log(
            "Color/palette slots: "
                .. tostring(
                    ctx.common.count_color_slots(
                        payload
                    )
                )
        )
    end

    local function same_uobject(a, b)
        if a == nil or b == nil then
            return false
        end

        if a == b then
            return true
        end

        return tostring(a) == tostring(b)
    end

    function ctx.sharing.is_in_progress_character_vm(databank_vm, character_vm)
        if databank_vm == nil or character_vm == nil then
            return false
        end

        local new_vm, new_vm_err =
            ctx.common.read_property(databank_vm, "DatabankNewCharacterVM")

        if new_vm_err ~= nil or new_vm == nil then
            return false
        end

        local in_progress_vm, in_progress_err =
            ctx.common.read_property(new_vm, "CharacterVM")

        if in_progress_err ~= nil or in_progress_vm == nil then
            return false
        end

        return same_uobject(in_progress_vm, character_vm)
    end

    function ctx.sharing.capture_selected_character_payload()

        local aux_vm = ctx.common.find_first("CharacterBankAuxVM_C")
        local databank_vm = ctx.common.find_first("BrunoCharacterDatabankViewModel")

        if aux_vm == nil or databank_vm == nil then
            ctx.logging.log("Character Databank view models are not loaded.")
            ctx.logging.log("Open Character Databank, select a player-created character, and retry.")
            return nil
        end

        local character_vm, character_err = ctx.common.read_property(aux_vm, "CharacterVM")

        if character_err ~= nil or character_vm == nil then
            ctx.logging.log("EXPORT BLOCKED: no selected saved character was found.")
            ctx.logging.log("Select a player-created character in Character Databank and retry.")
            ctx.popup.show_notice_popup(
                "NOTHING TO SHARE",
                "Select a saved Custom Character or Astromech in Character Databank, then press Ctrl+Shift+F8.",
                2400
            )
            return nil
        end

        if ctx.sharing.is_in_progress_character_vm(databank_vm, character_vm) then
            ctx.logging.log("EXPORT BLOCKED: the current CharacterVM belongs to the in-progress Create New editor.")
            ctx.logging.log("Character Share only exports saved Databank characters.")
            ctx.popup.show_notice_popup(
                "UNSAVED CHARACTER",
                "Character Share only exports saved Databank characters. Save or cancel the current Create New character first.",
                2800
            )
            return nil
        end

        local first_name = ctx.common.text_value(select(1, ctx.common.read_property(character_vm, "FirstName")))
        local last_name = ctx.common.text_value(select(1, ctx.common.read_property(character_vm, "LastName")))
        local full_name = ctx.common.text_value(select(1, ctx.common.read_property(character_vm, "FullName")))
        local background = ctx.common.text_value(select(1, ctx.common.read_property(character_vm, "BackgroundDescription")))

        if full_name == "" and first_name == "" and last_name == "" then
            ctx.logging.log("EXPORT BLOCKED: selected character has no saved display name.")
            ctx.popup.show_notice_popup(
                "NOTHING TO SHARE",
                "The current selection does not look like a saved Databank character.",
                2400
            )
            return nil
        end

        ctx.logging.log("Selected character: " .. full_name)

        local customization_vm, customization_err =
            ctx.common.read_property(character_vm, "CustomizationInstanceVM")

        if customization_err ~= nil or customization_vm == nil then
            ctx.logging.log("CustomizationInstanceVM unavailable.")
            return nil
        end

        local slot_vms, slots_err = ctx.common.read_property(customization_vm, "SlotViewModels")
        if slots_err ~= nil or slot_vms == nil then
            ctx.logging.log("SlotViewModels unavailable.")
            return nil
        end

        local expected_count = ctx.common.array_count(slot_vms)
        local slots = {}
        local invalid_slots = 0

        ctx.common.for_each_array(slot_vms, function(index, slot_vm)
            local slot_tag_struct, tag_err = ctx.common.read_property(slot_vm, "SlotTag")
            local tag = nil

            if tag_err == nil then
                tag = ctx.common.gameplay_tag_value(slot_tag_struct)
            end

            if tag == nil or tag == "" then
                invalid_slots = invalid_slots + 1
                ctx.logging.log(string.format("Skipping slot %s: could not read SlotTag.", tostring(index)))
                return nil
            end

            local equipped_vm, equipped_err =
                ctx.common.read_property(slot_vm, "EquippedCustomizationPartViewModel")

            local asset = nil
            if equipped_err == nil and equipped_vm ~= nil then
                local asset_id, asset_err = ctx.common.read_property(equipped_vm, "AssetId")
                if asset_err == nil and asset_id ~= nil then
                    asset = ctx.common.primary_asset_id_value(asset_id)
                end
            end

            table.insert(
                slots,
                {
                    tag,
                    asset,
                }
            )
        end)

        ctx.logging.log(string.format(
            "Captured %d/%d customization slots (%d invalid).",
            #slots,
            expected_count,
            invalid_slots
        ))

        local captured_color_slots = 0

        for _, pair in ipairs(slots) do
            if ctx.common.is_color_slot_tag(pair[1]) then
                captured_color_slots =
                    captured_color_slots + 1
            end
        end

        ctx.logging.log(
            string.format(
                "Captured %d color/palette slot(s); colors use the same canonical slot encoder as every other customization asset.",
                captured_color_slots
            )
        )

        if invalid_slots > 0 or #slots ~= expected_count then
            ctx.logging.log("Export aborted because the slot capture was incomplete.")
            return nil
        end

        local payload = {
            v = 1,
            first = first_name,
            last = last_name,
            background = background,
            slots = slots,
        }

        local validated,
            validation_err =
                ctx.dependencies.Character.validate_payload(
                    payload
                )

        if validation_err ~= nil
            or validated == nil then
            ctx.logging.log(
                "Export aborted: "
                    .. tostring(validation_err)
            )
            return nil
        end

        return validated
    end

    function ctx.sharing.export_selected_character()
        ctx.logging.transition("export", "capturing", "selected character")
        ctx.logging.log("============================================================")
        ctx.logging.log("EXPORT START")

        local validated =
            ctx.sharing.capture_selected_character_payload()

        if validated == nil then
            ctx.logging.transition("export", "failed", "selected character unavailable")
            ctx.logging.log("============================================================")
            return
        end

        local share_code,
            compact_stats =
                ctx.dependencies.Codec.encode(
                    validated
                )

        if share_code == nil then
            ctx.logging.transition("export", "failed", "ZC1 encoding failed")
            ctx.logging.log(
                "Export aborted: ZC1 encoding failed: "
                    .. tostring(compact_stats)
            )
            ctx.logging.log("============================================================")
            return
        end

        ctx.logging.log(
            "Derived type: "
                .. tostring(
                    validated.characterType
                )
        )

        ctx.logging.log(
            "Derived class: "
                .. tostring(
                    validated.class
                )
        )

        ctx.logging.log(
            "Derived secondary class: "
                .. tostring(
                    validated.secondaryClass
                )
        )

        ctx.logging.log(
            string.format(
                "ZC1 binary bytes: %d",
                compact_stats.binaryBytes
            )
        )

        if compact_stats.background ~= nil then
            ctx.logging.log(
                string.format(
                    "Background: %d raw bytes -> %d stored bytes (%s)",
                    compact_stats.background.rawBytes,
                    compact_stats.background.storedBytes,
                    compact_stats.background.encoding
                )
            )
        end

        ctx.logging.log(
            string.format(
                "Codebook revision: %d | tag entries: %d | asset entries: %d across %d tables",
                compact_stats.codebookRevision,
                ctx.dependencies.Codec.tag_dictionary_size(),
                ctx.dependencies.Codec.asset_dictionary_size(),
                ctx.dependencies.Codec.asset_table_count()
            )
        )

        do
            local table_sizes =
                ctx.dependencies.Codec.asset_table_sizes()

            ctx.logging.log(
                string.format(
                    "Asset tables: palette=%d outfit=%d appearance=%d meta=%d",
                    table_sizes.palette or 0,
                    table_sizes.outfit or 0,
                    table_sizes.appearance or 0,
                    table_sizes.meta or 0
                )
            )
        end

        ctx.logging.log(
            string.format(
                "Fallbacks: %d extension slot(s), %d raw asset(s)",
                compact_stats.extensionSlots or 0,
                compact_stats.rawAssetFallbacks or 0
            )
        )

        ctx.logging.log(
            string.format(
                "CRC32: %08X",
                compact_stats.crc32
            )
        )

        ctx.logging.log(
            string.format(
                "ZC1 characters: %d",
                #share_code
            )
        )

        ctx.logging.log("EXPORT_CODE_BEGIN")
        ctx.logging.log(share_code)
        ctx.logging.log("EXPORT_CODE_END")

        ctx.popup.show_share_popup(share_code)

        ctx.logging.transition("export", "complete", "share popup opened")
        ctx.logging.log("EXPORT COMPLETE")
        ctx.logging.log("============================================================")
    end

    function ctx.sharing.export_selected_character_json()
        ctx.logging.log("============================================================")
        ctx.logging.log("JSON EXPORT START")

        local validated =
            ctx.sharing.capture_selected_character_payload()

        if validated == nil then
            ctx.logging.log("============================================================")
            return
        end

        local json_payload,
            json_err =
                ctx.dependencies.Character.to_json(
                    validated
                )

        if json_payload == nil then
            ctx.logging.log(
                "JSON export aborted: "
                    .. tostring(json_err)
            )
            ctx.logging.log("============================================================")
            return
        end

        ctx.logging.log(
            string.format(
                "Plain JSON characters: %d",
                #json_payload
            )
        )

        ctx.logging.log("EXPORT_JSON_BEGIN")
        ctx.logging.log(json_payload)
        ctx.logging.log("EXPORT_JSON_END")

        ctx.popup.show_json_popup(
            json_payload
        )

        ctx.logging.log("JSON EXPORT COMPLETE")
        ctx.logging.log("============================================================")
    end
end
