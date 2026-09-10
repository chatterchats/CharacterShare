-- Character Share canonical character payload helpers.

local M = {}

M.TAG_ARCHETYPE =
    "br.Customization.Slot.Character.Class"

M.TAG_RIG =
    "br.Customization.Slot.Character.Rig"

M.TAG_SPECIES =
    "br.Customization.Slot.Character.Species"

M.TAG_CLASS =
    "br.Customization.Slot.Character.Specializations.Tactical.Primary"

M.TAG_SECONDARY_CLASS =
    "br.Customization.Slot.Character.Specializations.Tactical.Secondary"

M.TAG_TALENT =
    "br.Customization.Slot.Character.Specializations.Talent"

M.TAG_WEAPON_CLASS =
    "br.Customization.Slot.Character.Specializations.Weapon"

M.TAG_WEAPON_MODEL =
    "br.Customization.Slot.Character.Specializations.Weapon.GearKit"

local function payload_slot_map(payload)
    local map = {}

    for _, pair in ipairs(payload.slots or {}) do
        if type(pair) == "table" then
            map[pair[1]] =
                pair[2]
        end
    end

    return map
end

local function derive_type(slot_map)
    local archetype =
        slot_map[M.TAG_ARCHETYPE]

    if archetype ~= nil then
        if string.find(
            archetype,
            "Hero_Astromech",
            1,
            true
        ) then
            return "astromech"
        elseif string.find(
            archetype,
            "Hero_Humanoid",
            1,
            true
        ) then
            return "humanoid"
        end
    end

    local species =
        slot_map[M.TAG_SPECIES]

    if species ~= nil
        and string.find(
            species,
            "Astromech",
            1,
            true
        ) then
        return "astromech"
    end

    local rig =
        slot_map[M.TAG_RIG]

    if rig ~= nil then
        if string.find(
            rig,
            "Rig_Astromech",
            1,
            true
        ) then
            return "astromech"
        elseif string.find(
            rig,
            "Rig_Humanoid",
            1,
            true
        ) then
            return "humanoid"
        end
    end

    return nil
end

function M.derive_metadata(payload)
    local slot_map =
        payload_slot_map(payload)

    return {
        characterType =
            derive_type(slot_map),

        archetype =
            slot_map[M.TAG_ARCHETYPE],

        class =
            slot_map[M.TAG_CLASS],

        secondaryClass =
            slot_map[M.TAG_SECONDARY_CLASS],

        talent =
            slot_map[M.TAG_TALENT],

        weaponClass =
            slot_map[M.TAG_WEAPON_CLASS],

        weaponModel =
            slot_map[M.TAG_WEAPON_MODEL],

        rig =
            slot_map[M.TAG_RIG],
    }
end

local function validate_asset_id(asset)
    if asset == nil then
        return true
    end

    if type(asset) ~= "string" then
        return false
    end

    local asset_type,
        asset_name =
            asset:match(
                "^([^:]+):(.+)$"
            )

    if asset_type
        ~= "CustomizationPartDefinition"
        or asset_name == nil then
        return false
    end

    return #asset_name >= 1
        and #asset_name <= 256
end

function M.validate_payload(payload)
    if type(payload) ~= "table" then
        return nil,
            "payload root is not an object"
    end

    if payload.v ~= 1 then
        return nil,
            "unsupported payload version"
    end

    if type(payload.first) ~= "string"
        or type(payload.last) ~= "string"
        or type(payload.background) ~= "string" then
        return nil,
            "name/background fields are invalid"
    end

    if #payload.first > 128
        or #payload.last > 128
        or #payload.background > 4096 then
        return nil,
            "name/background field is unreasonably long"
    end

    if type(payload.slots) ~= "table"
        or #payload.slots < 1
        or #payload.slots > 256 then
        return nil,
            "slot count is invalid"
    end

    local seen_tags = {}

    for index, pair in ipairs(payload.slots) do
        if type(pair) ~= "table"
            or #pair < 1
            or #pair > 2 then
            return nil,
                string.format(
                    "slot %d has invalid shape",
                    index
                )
        end

        local tag =
            pair[1]

        local asset =
            pair[2]

        if type(tag) ~= "string"
            or not tag:match(
                "^br%.Customization%.Slot%.Character%."
            ) then
            return nil,
                string.format(
                    "slot %d has invalid tag",
                    index
                )
        end

        if seen_tags[tag] then
            return nil,
                "duplicate slot tag: "
                .. tag
        end

        seen_tags[tag] = true

        if not validate_asset_id(asset) then
            return nil,
                "invalid asset id for slot: "
                .. tag
        end
    end

    local derived =
        M.derive_metadata(payload)

    if derived.characterType ~= "humanoid"
        and derived.characterType ~= "astromech" then
        return nil,
            "could not derive Humanoid/Astromech character type"
    end

    if derived.class == nil then
        return nil,
            "payload has no Tactical.Primary class"
    end

    -- Derived fields are reconstructed locally from canonical slots. They are
    -- deliberately not transmitted in ZC1.
    payload.characterType =
        derived.characterType

    -- Astromechs have one native name field. Ignore any second-name data from
    -- older, synthetic, modded, or hand-authored share codes.
    if derived.characterType == "astromech" then
        payload.last = ""
    end

    payload.archetype =
        derived.archetype

    payload.class =
        derived.class

    payload.secondaryClass =
        derived.secondaryClass

    payload.talent =
        derived.talent

    payload.weaponClass =
        derived.weaponClass

    payload.weaponModel =
        derived.weaponModel

    payload.rig =
        derived.rig

    return payload, nil
end

local function tag_depth(tag)
    local _, count =
        tag:gsub(
            "%.",
            ""
        )

    return count
end

local function import_priority(tag)
    if tag == M.TAG_ARCHETYPE then
        return 1
    elseif tag == M.TAG_RIG then
        return 2
    elseif tag == M.TAG_SPECIES then
        return 3
    elseif tag
        == "br.Customization.Slot.Character.Appearance" then
        return 4
    elseif tag
        == "br.Customization.Slot.Character.Specializations" then
        return 5
    elseif tag == M.TAG_CLASS then
        return 6
    elseif tag == M.TAG_SECONDARY_CLASS then
        return 7
    elseif tag == M.TAG_TALENT then
        return 8
    elseif tag == M.TAG_WEAPON_CLASS then
        return 9
    elseif tag == M.TAG_WEAPON_MODEL then
        return 10
    end

    return 100
        + tag_depth(tag)
end

function M.sorted_slots(payload)
    local items = {}

    for _, pair in ipairs(payload.slots) do
        table.insert(
            items,
            {
                tag = pair[1],
                asset = pair[2],
            }
        )
    end

    table.sort(
        items,
        function(a, b)
            local ap =
                import_priority(a.tag)

            local bp =
                import_priority(b.tag)

            if ap == bp then
                return a.tag < b.tag
            end

            return ap < bp
        end
    )

    return items
end


local function json_escape(value)
    value =
        tostring(
            value or ""
        )

    return value:gsub(
        '[%z\1-\31\\"]',
        function(char)
            if char == '"' then
                return '\\"'
            elseif char == '\\' then
                return '\\\\'
            elseif char == '\b' then
                return '\\b'
            elseif char == '\f' then
                return '\\f'
            elseif char == '\n' then
                return '\\n'
            elseif char == '\r' then
                return '\\r'
            elseif char == '\t' then
                return '\\t'
            end

            return string.format(
                "\\u%04x",
                string.byte(char)
            )
        end
    )
end

local function json_string_or_null(value)
    if value == nil then
        return "null"
    end

    return '"'
        .. json_escape(value)
        .. '"'
end

function M.to_json(payload)
    local validated,
        validation_err =
            M.validate_payload(payload)

    if validated == nil then
        return nil,
            validation_err
    end

    local slot_json = {}

    for _, pair in ipairs(validated.slots) do
        table.insert(
            slot_json,
            "["
                .. json_string_or_null(pair[1])
                .. ","
                .. json_string_or_null(pair[2])
                .. "]"
        )
    end

    local fields = {
        '"v":1',
        '"characterType":'
            .. json_string_or_null(
                validated.characterType
            ),
        '"archetype":'
            .. json_string_or_null(
                validated.archetype
            ),
        '"class":'
            .. json_string_or_null(
                validated.class
            ),
        '"secondaryClass":'
            .. json_string_or_null(
                validated.secondaryClass
            ),
        '"talent":'
            .. json_string_or_null(
                validated.talent
            ),
        '"weaponClass":'
            .. json_string_or_null(
                validated.weaponClass
            ),
        '"weaponModel":'
            .. json_string_or_null(
                validated.weaponModel
            ),
        '"rig":'
            .. json_string_or_null(
                validated.rig
            ),
        '"first":'
            .. json_string_or_null(
                validated.first
            ),
        '"last":'
            .. json_string_or_null(
                validated.last
            ),
        '"background":'
            .. json_string_or_null(
                validated.background
            ),
        '"slots":['
            .. table.concat(
                slot_json,
                ","
            )
            .. "]",
    }

    return "{"
        .. table.concat(
            fields,
            ","
        )
        .. "}",
        nil
end

return M
