-- Character Share: import validation.
-- Initialized once per mod instance; shared references use explicit ctx fields.
-- Context: common, import_validation, layout, logging, pool_identity, popup, sharing, state.
return function(ctx)
    local function clear_pending_name_override(reason)
        if ctx.state.pending_name_override ~= nil then
            ctx.logging.log(
                "IMPORT SESSION: cleared pending rename override"
                    .. (
                        reason ~= nil
                        and (" (" .. tostring(reason) .. ")")
                        or ""
                    )
                    .. "."
            )
        end

        ctx.state.pending_name_override = nil
        ctx.state.pending_name_override_code = nil
    end

    function ctx.import_validation.apply_pending_name_override(payload, code)
        if payload == nil
            or ctx.state.pending_name_override == nil then
            return payload
        end

        -- Rename state belongs to exactly one immutable ZComChar code. Never let a
        -- rename chosen for one character bleed into a later Humanoid/Astromech
        -- payload.
        if code == nil
            or ctx.state.pending_name_override_code == nil
            or ctx.state.pending_name_override_code ~= code then
            ctx.logging.log(
                "IMPORT SESSION: ignored rename override because it belongs to a different share code."
            )
            return payload
        end

        payload.first =
            ctx.state.pending_name_override.first
                or payload.first

        payload.last =
            ctx.state.pending_name_override.last
                or ""

        return payload
    end

    local function adopt_valid_import_code(code)
        if code == nil then
            return
        end

        if ctx.state.pending_import_code ~= nil
            and ctx.state.pending_import_code ~= code then
            ctx.layout.cancel_action_group(
                "import_create",
                "share code replaced"
            )
            ctx.layout.cancel_action_group(
                "overwrite_verification",
                "share code replaced"
            )

            ctx.state.pending_import_navigation_generation =
                ctx.state.pending_import_navigation_generation + 1

            ctx.state.pending_import_payload = nil

            clear_pending_name_override(
                "new share code"
            )

            ctx.logging.log(
                "IMPORT SESSION: new share code detected; previous import state was isolated."
            )
        elseif ctx.state.pending_name_override_code ~= nil
            and ctx.state.pending_name_override_code ~= code then
            clear_pending_name_override(
                "rename/code mismatch"
            )
        end

        ctx.state.pending_import_code = code
    end

    function ctx.import_validation.clear_pending_import()
        ctx.layout.cancel_action_group(
            "import_create",
            "import session ended"
        )
        ctx.layout.cancel_action_group(
            "overwrite_verification",
            "import session ended"
        )

        ctx.state.pending_import_navigation_generation =
            ctx.state.pending_import_navigation_generation + 1

        ctx.state.pending_import_code = nil
        ctx.state.pending_import_payload = nil

        clear_pending_name_override(
            "import session ended"
        )
    end

    function ctx.import_validation.normalize_character_name(name)
        name = tostring(name or "")
        name = name:gsub("^%s+", ""):gsub("%s+$", "")
        return string.lower(name)
    end

    function ctx.import_validation.payload_full_name(payload)
        if payload.last ~= nil and payload.last ~= "" then
            return payload.first .. " " .. payload.last
        end

        return payload.first
    end

    local function object_identity(object)
        if object == nil then
            return "<nil>"
        end

        local full_name, err = ctx.common.try_call(function()
            return object:GetFullName()
        end)

        if err == nil and full_name ~= nil then
            return tostring(full_name)
        end

        return tostring(object)
    end

    -- IMPORTANT:
    -- UBrunoCharacterPoolCharacterViewModel also has a reflected UFunction named
    -- GetFullName(), but UE4SS's UObject wrapper itself owns a native GetFullName()
    -- method. Calling `character_vm:GetFullName()` therefore resolves to the UE4SS
    -- UObject path/name helper, not the game's FText-returning UFunction.
    --
    -- Resolve the game's UFunction explicitly and call it with the pool-character
    -- ViewModel as context. Names still avoid CustomizationSlots; identity reads
    -- only the scalar PoolCharacterData.PoolCharacterID through pool_identity.
    local pool_character_get_full_name_function = nil

    local pool_character_get_full_name_lookup_attempted = false

    function ctx.import_validation.get_pool_character_display_name(character_vm)
        if character_vm == nil then
            return nil, "character vm is nil"
        end

        if not pool_character_get_full_name_lookup_attempted then
            pool_character_get_full_name_lookup_attempted = true

            local function_object, function_err = ctx.common.try_call(function()
                return StaticFindObject(
                    "/Script/Bruno.BrunoCharacterPoolCharacterViewModel:GetFullName"
                )
            end)

            if function_err == nil and function_object ~= nil then
                pool_character_get_full_name_function = function_object
                ctx.logging.log("Duplicate check: resolved native pool-character GetFullName UFunction.")
            else
                ctx.logging.log(
                    "Duplicate check: could not resolve pool-character GetFullName UFunction: "
                    .. tostring(function_err)
                )
            end
        end

        if pool_character_get_full_name_function == nil then
            return nil, "pool-character GetFullName UFunction unavailable"
        end

        local value, call_err = ctx.common.try_call(function()
            -- A UFunction obtained from StaticFindObject has no object context,
            -- therefore the context object is the first argument.
            return pool_character_get_full_name_function(character_vm)
        end)

        if call_err ~= nil or value == nil then
            return nil, "GetFullName UFunction failed: " .. tostring(call_err)
        end

        return ctx.common.text_value(value), nil
    end

    function ctx.import_validation.array_object_identity(value)
        if value == nil then
            return "<nil>"
        end

        local full_name, full_name_err = ctx.common.try_call(function()
            return value:GetFullName()
        end)

        if full_name_err == nil and full_name ~= nil then
            return tostring(full_name)
        end

        return tostring(value)
    end

    function ctx.import_validation.for_each_counted_array(array, callback)
        if array == nil then
            return 0, 0
        end

        local count = ctx.common.array_count(array)
        if count <= 0 then
            return 0, 0
        end

        local collected = {}
        local seen = {}

        local function add(value)
            if value == nil or #collected >= count then
                return
            end

            local identity = ctx.import_validation.array_object_identity(value)
            if seen[identity] then
                return
            end

            seen[identity] = true
            table.insert(collected, value)
        end

        -- Prefer Lua's iterator when the wrapper exposes one. This is the path that
        -- has consistently produced correct non-empty TArray ordering in UE4SS.
        pcall(function()
            for _, value in ipairs(array) do
                add(value)
                if #collected >= count then
                    break
                end
            end
        end)

        -- Some wrappers expose numeric indexing differently. If ipairs did not
        -- produce the reflected GetArrayNum() count, probe both index conventions
        -- and de-duplicate by UObject identity.
        if #collected < count then
            for index = 0, count - 1 do
                local value, value_err = ctx.common.try_call(function()
                    return array[index]
                end)

                if value_err == nil then
                    add(value)
                end
            end
        end

        if #collected < count then
            for index = 1, count do
                local value, value_err = ctx.common.try_call(function()
                    return array[index]
                end)

                if value_err == nil then
                    add(value)
                end
            end
        end

        for index, value in ipairs(collected) do
            callback(index, value)
        end

        return count, #collected
    end

    function ctx.import_validation.collect_character_pools(databank_vm)
        local pools = {}
        local seen = {}

        local function add_pool(pool_vm, character_type, source)
            if pool_vm == nil then
                return
            end

            local identity = object_identity(pool_vm)
            if seen[identity] then
                return
            end

            seen[identity] = true
            table.insert(pools, {
                vm = pool_vm,
                characterType = character_type,
                source = source,
            })
        end

        local default_custom, default_custom_err = ctx.common.read_property(
            databank_vm,
            "DefaultCustomCharacterPoolViewModel"
        )
        if default_custom_err == nil then
            add_pool(default_custom, "humanoid", "Default Custom Characters")
        end

        local custom_pools, custom_pools_err = ctx.common.read_property(
            databank_vm,
            "CustomCharacterPoolViewModels"
        )
        if custom_pools_err == nil and custom_pools ~= nil then
            ctx.import_validation.for_each_counted_array(custom_pools, function(_, pool_vm)
                add_pool(pool_vm, "humanoid", "Custom Character Pool")
            end)
        end

        local default_astromech, default_astromech_err = ctx.common.read_property(
            databank_vm,
            "DefaultAstromechCharacterPoolViewModel"
        )
        if default_astromech_err == nil then
            add_pool(default_astromech, "astromech", "Default Astromechs")
        end

        local astromech_pools, astromech_pools_err = ctx.common.read_property(
            databank_vm,
            "AstromechCharacterPoolViewModel"
        )
        if astromech_pools_err == nil and astromech_pools ~= nil then
            ctx.import_validation.for_each_counted_array(astromech_pools, function(_, pool_vm)
                add_pool(pool_vm, "astromech", "Astromech Pool")
            end)
        end

        return pools
    end

    function ctx.import_validation.find_duplicate_characters(databank_vm, payload)
        local target = ctx.import_validation.normalize_character_name(
            ctx.import_validation.payload_full_name(payload))
        local matches, seen_characters, unresolved_owners = {}, {}, {}
        local unreadable, total_seen = 0, 0
        local owners, owner_err = ctx.pool_identity.owner_snapshot()
        if owners == nil then
            -- Keep useful GUID-deduplicated name matches, but don't permit a
            -- destructive overwrite or claim a new name is safe from partial data.
            unreadable = unreadable + 1
            ctx.logging.log("Duplicate check: native ownership unavailable: " .. tostring(owner_err))
        end

        local pools = ctx.import_validation.collect_character_pools(databank_vm)
        ctx.logging.log(string.format("Duplicate check: scanning %d character pool(s).", #pools))
        for _, pool in ipairs(pools) do
            local character_vms, characters_err =
                ctx.common.read_property(pool.vm, "PoolCharacterViewModels")
            if characters_err ~= nil or character_vms == nil then
                unreadable = unreadable + 1
            else
                local reflected_count, enumerated_count =
                    ctx.import_validation.for_each_counted_array(character_vms, function(index, value)
                        local vm = ctx.common.unwrap_remote_value(value)
                        if not ctx.layout.uobject_is_valid(vm) then
                            unreadable = unreadable + 1
                            return
                        end
                        local vm_identity = ctx.import_validation.array_object_identity(vm)
                        local guid = ctx.pool_identity.character_guid(vm)
                        local owner = owners and guid and owners[guid] or nil
                        if owners ~= nil and guid ~= nil and owner == nil then
                            ctx.logging.log("Duplicate check: skipped deleted/non-authoritative GUID " .. guid)
                            return
                        end
                        local name, name_err = ctx.import_validation.get_pool_character_display_name(vm)
                        if name_err ~= nil or name == nil then
                            unreadable = unreadable + 1
                            return
                        end
                        local name_matches = ctx.import_validation.normalize_character_name(name) == target
                        local pool_name_value = select(1, ctx.common.read_property(pool.vm, "PoolName"))
                        local pool_name = pool_name_value and ctx.common.text_value(pool_name_value) or nil
                        local identity = guid and (pool.characterType .. ":" .. guid) or ("vm:" .. vm_identity)
                        local candidate = {
                            name = name, characterType = pool.characterType,
                            pool = pool_name or pool.source, vm = vm, guid = guid,
                        }

                        if owner ~= nil and pool_name ~= owner then
                            ctx.logging.log("Duplicate check: skipped stale pool copy of " .. guid
                                .. " in '" .. tostring(pool_name) .. "'; owner='" .. owner .. "'.")
                            -- If the owning pool's VM hasn't appeared yet, do not
                            -- mistake this for an available name. Keep the conflict,
                            -- but disable overwrite until the owning VM is readable.
                            if name_matches then unresolved_owners[identity] = candidate end
                            return
                        end
                        if seen_characters[identity] then
                            ctx.logging.log("Duplicate check: skipped repeated character GUID " .. tostring(guid))
                            return
                        end
                        seen_characters[identity] = true
                        total_seen = total_seen + 1
                        if guid == nil then
                            -- Unknown/zero IDs must not merge distinct characters.
                            unreadable = unreadable + 1
                            ctx.logging.log("Duplicate check: GUID unavailable for " .. vm_identity)
                        end
                        ctx.logging.log(string.format("Duplicate candidate[%d]: %s / %s / %s / guid=%s",
                            index, pool.characterType, candidate.pool, name, tostring(guid)))
                        if name_matches then table.insert(matches, candidate) end
                    end)
                if enumerated_count < reflected_count then
                    unreadable = unreadable + reflected_count - enumerated_count
                    ctx.logging.log("Duplicate check: incomplete VM enumeration in " .. pool.source)
                end
            end
        end
        for identity, candidate in pairs(unresolved_owners) do
            if not seen_characters[identity] then
                table.insert(matches, candidate)
                total_seen = total_seen + 1
                unreadable = unreadable + 1
                ctx.logging.log("Duplicate check: owning-pool VM not ready for GUID " .. candidate.guid
                    .. "; overwrite disabled.")
            end
        end
        ctx.logging.log(string.format(
            "Duplicate check complete: %d unique character(s) inspected, %d match(es), %d unreadable.",
            total_seen, #matches, unreadable))
        return matches, unreadable
    end

    function ctx.import_validation.duplicate_type_label(character_type)
        if character_type == "astromech" then
            return "Astromech"
        elseif character_type == "humanoid" then
            return "Custom Character"
        end

        return tostring(character_type)
    end

    function ctx.import_validation.log_duplicate_summary(matches, unreadable, payload)
        if #matches == 0 then
            if unreadable > 0 then
                ctx.logging.log(
                    string.format(
                        "Duplicate check: no matching name found; %d existing character(s) could not be read.",
                        unreadable
                    )
                )
            else
                ctx.logging.log("Duplicate check: name is available.")
            end
            return
        end

        local same_type = 0
        local other_type = 0

        for _, match in ipairs(matches) do
            if match.characterType == payload.characterType then
                same_type = same_type + 1
            else
                other_type = other_type + 1
            end
        end

        ctx.logging.log(
            string.format(
                "DUPLICATE NAME DETECTED: %d existing character(s) named '%s' (%d same type, %d other type).",
                #matches,
                ctx.import_validation.payload_full_name(payload),
                same_type,
                other_type
            )
        )

        for index, match in ipairs(matches) do
            ctx.logging.log(
                string.format(
                    "  DUPLICATE[%d]: %s / %s / %s",
                    index,
                    ctx.import_validation.duplicate_type_label(match.characterType),
                    match.pool,
                    match.name
                )
            )
        end

        if unreadable > 0 then
            ctx.logging.log(
                string.format(
                    "  WARNING: %d additional existing character(s) could not be read during duplicate detection.",
                    unreadable
                )
            )
        end
    end

    local pool_character_is_active_function = nil

    local pool_character_is_active_lookup_attempted = false

    local function get_pool_character_active_state(character_vm)
        if character_vm == nil then
            return nil
        end

        if not pool_character_is_active_lookup_attempted then
            pool_character_is_active_lookup_attempted = true

            local function_object, function_err = ctx.common.try_call(function()
                return StaticFindObject(
                    "/Script/Bruno.BrunoCharacterPoolCharacterViewModel:GetIsActiveInPool"
                )
            end)

            if function_err == nil and function_object ~= nil then
                pool_character_is_active_function = function_object
            end
        end

        if pool_character_is_active_function == nil then
            return nil
        end

        local value, value_err = ctx.common.try_call(function()
            return pool_character_is_active_function(character_vm)
        end)

        if value_err ~= nil or value == nil then
            return nil
        end

        return value == true
    end

    function ctx.import_validation.overwrite_match_description(match, index)
        local active = get_pool_character_active_state(match.vm)
        local suffix = ""

        if active == true then
            suffix = " — ACTIVE"
        elseif active == false then
            suffix = " — INACTIVE"
        end

        return string.format(
            "%d. %s%s",
            index,
            match.name or "Matching character",
            suffix
        )
    end

    local function same_type_matches(payload, matches)
        local result = {}

        for _, match in ipairs(matches or {}) do
            if match.characterType == payload.characterType then
                table.insert(result, match)
            end
        end

        return result
    end

    function ctx.import_validation.same_type_matches(payload, matches)
        local result = {}

        for _, match in ipairs(matches or {}) do
            if match.characterType == payload.characterType then
                table.insert(result, match)
            end
        end

        return result
    end

    local function friendly_asset_label(asset_id)
        if asset_id == nil or asset_id == "" then
            return nil
        end

        local token =
            tostring(asset_id):match("^[^:]+:(.+)$")
                or tostring(asset_id)

        token = token
            :gsub("^CPD_", "")
            :gsub("^TacticalSpec_", "")
            :gsub("^TalentSpec_", "")
            :gsub("^WeaponSpec_", "")
            :gsub("^Character_Rig_", "")
            :gsub("^Char_Class_Hero_", "")
            :gsub("_", " ")
            :gsub("(%l)(%u)", "%1 %2")
            :gsub("(%a)(%d)", "%1 %2")
            :gsub("(%d)(%a)", "%1 %2")

        token =
            token:gsub("^%s+", "")
                :gsub("%s+$", "")
                :gsub("%s+", " ")

        return token ~= "" and token or tostring(asset_id)
    end

    function ctx.import_validation.import_summary(payload)
        local lines = {
            ctx.import_validation.payload_full_name(payload),
            ctx.import_validation.duplicate_type_label(payload.characterType),
        }

        local class_label =
            friendly_asset_label(
                payload.class
            )

        local talent_label =
            friendly_asset_label(
                payload.talent
            )

        if class_label ~= nil then
            table.insert(
                lines,
                "Class: " .. class_label
            )
        end

        if talent_label ~= nil then
            table.insert(
                lines,
                "Talent: " .. talent_label
            )
        end

        if payload.slots ~= nil then
            table.insert(
                lines,
                string.format(
                    "%d customization slots",
                    #payload.slots
                )
            )
        end

        return table.concat(
            lines,
            "\n"
        )
    end

    function ctx.import_validation.friendly_import_failure(message)
        local detail =
            tostring(
                message
                    or "The character could not be imported."
            )

        if detail:find(
            "target character has no slot",
            1,
            true
        ) ~= nil then
            return "This character uses a customization slot that is not available in your game. It may require a mod or a different game version. No character was saved."
        end

        if detail:find(
            "verification mismatch",
            1,
            true
        ) ~= nil
            or detail:find(
                "MOD%-COMPAT",
                1
            ) ~= nil then
            return "One of this character's customization options is not available in your game. It may require a mod that is not installed. No character was saved."
        end

        if detail:find(
            "duplicate%-name verification",
            1
        ) ~= nil then
            return "Character Share could not safely verify duplicate names. No character was changed."
        end

        if detail:find(
            "Character Databank",
            1,
            true
        ) ~= nil
            and detail:find(
                "not",
                1,
                true
            ) ~= nil then
            return "Character Databank is not ready. Return to the Databank and try again."
        end

        return "The character could not be imported. No character was saved."
    end

    local function import_error_body(detail)
        detail = tostring(detail or "unknown import error")

        if detail:find(
            "checksum mismatch",
            1,
            true
        ) ~= nil then
            return "This Character Share code is corrupt or incomplete. Copy the complete ZC1 code and try again."
        end

        if detail:find(
            "unsupported ZC1 wire revision",
            1,
            true
        ) ~= nil then
            return "This ZC1 code uses an unsupported ZC1 wire revision."
        end

        if detail:find(
            "codebook revision",
            1,
            true
        ) ~= nil then
            return "This ZC1 code uses a different Character Share codebook revision and cannot be imported by this build."
        end

        if detail:find(
            "prefix",
            1,
            true
        ) ~= nil
            or detail:find(
                "no ZC1",
                1,
                true
            ) ~= nil then
            return "Paste a valid ZC1 Character Share code and try again."
        end

        return "Character Share could not validate this code:\n\n"
            .. detail
    end

    local function show_import_error(detail)
        ctx.popup.set_popup_status(
            "Invalid import code: "
                .. tostring(detail)
        )

        return ctx.popup.show_notice_popup(
            "INVALID SHARE CODE",
            import_error_body(detail),
            0
        )
    end

    function ctx.import_validation.import_preflight()
        ctx.logging.log("============================================================")
        ctx.logging.log("IMPORT PREFLIGHT START")

        local code, read_err = ctx.popup.read_import_code()
        if read_err ~= nil then
            ctx.logging.log("IMPORT PREFLIGHT FAILED: " .. read_err)
            show_import_error(read_err)
            ctx.logging.log("============================================================")
            return nil
        end

        local decoded, decode_err = ctx.sharing.decode_share_code(code)
        if decode_err ~= nil then
            ctx.logging.log("IMPORT PREFLIGHT FAILED: " .. decode_err)
            show_import_error(decode_err)
            ctx.logging.log("============================================================")
            return nil
        end

        adopt_valid_import_code(code)

        ctx.import_validation.apply_pending_name_override(
            decoded.payload,
            code
        )

        ctx.state.pending_import_payload = decoded.payload

        ctx.sharing.log_payload_summary(decoded.payload, "VALID IMPORT PAYLOAD")

        local duplicate_matches = {}
        local duplicate_unreadable = 0
        local databank_vm = ctx.common.find_first("BrunoCharacterDatabankViewModel")
        if databank_vm ~= nil then
            duplicate_matches, duplicate_unreadable =
                ctx.import_validation.find_duplicate_characters(databank_vm, decoded.payload)
            ctx.import_validation.log_duplicate_summary(
                duplicate_matches,
                duplicate_unreadable,
                decoded.payload
            )
        else
            ctx.logging.log("Duplicate check skipped: Character Databank view model is not loaded.")
        end

        ctx.logging.log("IMPORT PREFLIGHT COMPLETE")
        ctx.logging.log("============================================================")
        return decoded.payload, duplicate_matches, duplicate_unreadable
    end
end
