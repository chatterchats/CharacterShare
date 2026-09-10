-- Character Share codec
-- Pre-release external format: ZC1
-- Frozen ZC1 wire revision: 1
--
-- Hybrid layout:
--   * positional name fields (no JSON keys)
--   * known-slot presence bitset
--   * slot-implied exact customization-asset tables with raw fallback
--   * one shared palette table across every color-like slot
--   * DEFLATE only for the background, and only when it wins
--   * unknown/future slot extension records
--   * unknown assets/unknown slots remain representable through raw asset ids
--   * full CRC-32 integrity check
--   * letters/digits-only Base62 text representation
--
-- ZC1 is intentionally still allowed to change before public release.

local Codebook =
    require("codebook")

local LibDeflate =
    require("libdeflate")

local M = {}

M.PREFIX = "ZC1-"

local WIRE_REVISION = 1

if Codebook.FROZEN ~= true or Codebook.REVISION ~= 1 then
    error("ZC1 codec requires frozen codebook revision 1")
end

local TAG_PREFIX =
    "br.Customization.Slot.Character."

local ASSET_PREFIX =
    "CustomizationPartDefinition:"

local BASE62_ALPHABET =
    "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

local BASE62_INDEX = {}

for index = 1, #BASE62_ALPHABET do
    BASE62_INDEX[
        BASE62_ALPHABET:sub(
            index,
            index
        )
    ] =
        index - 1
end

local TAG_TO_INDEX = {}

for index, suffix in ipairs(
    Codebook.TAGS
) do
    TAG_TO_INDEX[suffix] =
        index
end

local TAG_TABLE = {}
local ASSET_TO_ID_BY_TABLE = {}
local ASSET_DICTIONARY_SIZE = 0

for _, table_name in ipairs(
    Codebook.TABLE_ORDER
) do
    local assets =
        Codebook.TABLES[
            table_name
        ]

    if type(assets) ~= "table" then
        error(
            "Character Share codebook is missing asset table: "
            .. tostring(table_name)
        )
    end

    local reverse = {}

    for index, asset in ipairs(
        assets
    ) do
        reverse[asset] =
            index
    end

    ASSET_TO_ID_BY_TABLE[
        table_name
    ] =
        reverse

    ASSET_DICTIONARY_SIZE =
        ASSET_DICTIONARY_SIZE
        + #assets
end

for index, suffix in ipairs(
    Codebook.TAGS
) do
    local table_name =
        Codebook.SLOT_TABLE[
            suffix
        ]

    if table_name == nil
        or Codebook.TABLES[
            table_name
        ] == nil then
        error(
            "Character Share codebook has no asset table for slot: "
            .. tostring(suffix)
        )
    end

    TAG_TABLE[index] =
        table_name
end

-- ---------------------------------------------------------------------------
-- CRC-32 (IEEE / zlib polynomial)
-- ---------------------------------------------------------------------------

local CRC32_TABLE = {}

for index = 0, 255 do
    local value =
        index

    for _ = 1, 8 do
        if (value & 1) ~= 0 then
            value =
                (value >> 1)
                ~ 0xEDB88320
        else
            value =
                value >> 1
        end
    end

    CRC32_TABLE[index] =
        value & 0xFFFFFFFF
end

local function crc32_string(value)
    local crc =
        0xFFFFFFFF

    for index = 1, #value do
        local byte =
            value:byte(index)

        crc =
            CRC32_TABLE[
                (crc ~ byte) & 0xFF
            ]
            ~ (crc >> 8)
    end

    return (crc ~ 0xFFFFFFFF)
        & 0xFFFFFFFF
end

local function append_u32_be(output, value)
    table.insert(
        output,
        string.char(
            (value >> 24) & 0xFF,
            (value >> 16) & 0xFF,
            (value >> 8) & 0xFF,
            value & 0xFF
        )
    )
end

local function read_u32_be(input, position)
    if position + 3 > #input then
        return nil,
            position,
            "truncated CRC-32"
    end

    local b1, b2, b3, b4 =
        input:byte(
            position,
            position + 3
        )

    local value =
        (b1 << 24)
        | (b2 << 16)
        | (b3 << 8)
        | b4

    return value & 0xFFFFFFFF,
        position + 4,
        nil
end

-- ---------------------------------------------------------------------------
-- Unsigned LEB128 varuint
-- ---------------------------------------------------------------------------

local function varuint_encode(value)
    value =
        math.floor(
            tonumber(value) or 0
        )

    if value < 0 then
        error(
            "varuint cannot encode a negative value"
        )
    end

    local output = {}

    repeat
        local byte =
            value & 0x7F

        value =
            value >> 7

        if value ~= 0 then
            byte =
                byte | 0x80
        end

        table.insert(
            output,
            string.char(byte)
        )
    until value == 0

    return table.concat(output)
end

local function varuint_decode(input, position)
    local value = 0
    local shift = 0

    for _ = 1, 5 do
        local byte =
            input:byte(position)

        if byte == nil then
            return nil,
                position,
                "truncated varuint"
        end

        position =
            position + 1

        value =
            value
            | ((byte & 0x7F) << shift)

        if (byte & 0x80) == 0 then
            return value,
                position,
                nil
        end

        shift =
            shift + 7
    end

    return nil,
        position,
        "varuint is too large"
end

local function append_string(
    output,
    value
)
    value =
        tostring(
            value or ""
        )

    table.insert(
        output,
        varuint_encode(
            #value
        )
    )

    table.insert(
        output,
        value
    )
end

local function read_string(
    input,
    position,
    maximum_length
)
    local length,
        next_position,
        length_err =
            varuint_decode(
                input,
                position
            )

    if length_err ~= nil then
        return nil,
            position,
            length_err
    end

    if maximum_length ~= nil
        and length > maximum_length then
        return nil,
            position,
            "compact string is unreasonably long"
    end

    local finish =
        next_position
        + length
        - 1

    if finish > #input then
        return nil,
            position,
            "truncated compact string"
    end

    return input:sub(
            next_position,
            finish
        ),
        finish + 1,
        nil
end

-- ---------------------------------------------------------------------------
-- Background text: raw or raw-DEFLATE, whichever is smaller.
-- ---------------------------------------------------------------------------

local BACKGROUND_RAW = 0
local BACKGROUND_DEFLATE = 1

local function append_background(
    output,
    background
)
    background =
        tostring(
            background or ""
        )

    local compressed =
        LibDeflate:CompressDeflate(
            background
        )

    if compressed ~= nil
        and #compressed < #background then
        table.insert(
            output,
            string.char(
                BACKGROUND_DEFLATE
            )
        )

        append_string(
            output,
            compressed
        )

        return {
            encoding = "deflate",
            rawBytes = #background,
            storedBytes = #compressed,
        }
    end

    table.insert(
        output,
        string.char(
            BACKGROUND_RAW
        )
    )

    append_string(
        output,
        background
    )

    return {
        encoding = "raw",
        rawBytes = #background,
        storedBytes = #background,
    }
end

local function read_background(
    input,
    position
)
    local encoding =
        input:byte(position)

    if encoding == nil then
        return nil,
            position,
            "truncated background encoding"
    end

    position =
        position + 1

    local stored,
        next_position,
        stored_err =
            read_string(
                input,
                position,
                8192
            )

    if stored_err ~= nil then
        return nil,
            position,
            stored_err
    end

    if encoding == BACKGROUND_RAW then
        if #stored > 4096 then
            return nil,
                position,
                "background is unreasonably long"
        end

        return stored,
            next_position,
            nil
    elseif encoding
        == BACKGROUND_DEFLATE then
        local decompressed =
            LibDeflate:DecompressDeflate(
                stored
            )

        if decompressed == nil then
            return nil,
                position,
                "background DEFLATE decompression failed"
        end

        if #decompressed > 4096 then
            return nil,
                position,
                "decompressed background is unreasonably long"
        end

        return decompressed,
            next_position,
            nil
    end

    return nil,
        position,
        "unknown background encoding"
end

-- ---------------------------------------------------------------------------
-- Asset references
--
-- The known slot implies which codebook table owns the reference.
--
-- 0 = nil
-- 1 = raw/future asset suffix follows
-- 2+ = Codebook.TABLES[slot_table][index] where index = ref - 1
--
-- Extension/unknown slots have no safe table implication, so their assets are
-- encoded raw even when that asset happens to exist in a known table.
-- ---------------------------------------------------------------------------

local function append_asset_ref(
    output,
    asset,
    table_name
)
    if asset == nil then
        table.insert(
            output,
            varuint_encode(0)
        )

        return nil
    end

    asset =
        tostring(asset)

    local reverse =
        table_name ~= nil
        and ASSET_TO_ID_BY_TABLE[
            table_name
        ]
        or nil

    local asset_id =
        reverse ~= nil
        and reverse[asset]
        or nil

    if asset_id ~= nil then
        table.insert(
            output,
            varuint_encode(
                asset_id + 1
            )
        )

        return nil
    end

    if asset:sub(
        1,
        #ASSET_PREFIX
    ) ~= ASSET_PREFIX then
        return "unsupported asset id: "
            .. asset
    end

    table.insert(
        output,
        varuint_encode(1)
    )

    append_string(
        output,
        asset:sub(
            #ASSET_PREFIX + 1
        )
    )

    return nil
end

local function read_asset_ref(
    input,
    position,
    table_name
)
    local ref,
        next_position,
        ref_err =
            varuint_decode(
                input,
                position
            )

    if ref_err ~= nil then
        return nil,
            position,
            ref_err
    end

    if ref == 0 then
        return nil,
            next_position,
            nil
    end

    if ref == 1 then
        local suffix,
            after_suffix,
            suffix_err =
                read_string(
                    input,
                    next_position,
                    256
                )

        if suffix_err ~= nil then
            return nil,
                position,
                suffix_err
        end

        return ASSET_PREFIX
                .. suffix,
            after_suffix,
            nil
    end

    if table_name == nil then
        return nil,
            position,
            "dictionary reference is invalid for an extension slot"
    end

    local assets =
        Codebook.TABLES[
            table_name
        ]

    local asset =
        assets ~= nil
        and assets[
            ref - 1
        ]
        or nil

    if asset == nil then
        return nil,
            position,
            string.format(
                "unknown %s asset-table reference",
                tostring(table_name)
            )
    end

    return asset,
        next_position,
        nil
end

-- ---------------------------------------------------------------------------
-- Binary payload
-- ---------------------------------------------------------------------------

local function slot_fields(slot)
    if type(slot) ~= "table" then
        return nil, nil
    end

    local tag =
        slot.tag
        or slot[1]

    local asset =
        slot.asset

    if slot.tag == nil then
        asset =
            slot[2]
    end

    return tag, asset
end

local function serialize_body(payload)
    if type(payload) ~= "table" then
        return nil,
            "payload is not a table"
    end

    local known_assets = {}
    local present = {}
    local unknown = {}

    for _, slot in ipairs(
        payload.slots or {}
    ) do
        local tag, asset =
            slot_fields(slot)

        tag =
            tostring(
                tag or ""
            )

        if tag:sub(
            1,
            #TAG_PREFIX
        ) ~= TAG_PREFIX then
            return nil,
                "unsupported slot tag: "
                .. tag
        end

        local suffix =
            tag:sub(
                #TAG_PREFIX + 1
            )

        local index =
            TAG_TO_INDEX[suffix]

        if index ~= nil then
            present[index] = true
            known_assets[index] = asset
        else
            table.insert(
                unknown,
                {
                    suffix = suffix,
                    asset = asset,
                }
            )
        end
    end

    table.sort(
        unknown,
        function(a, b)
            return a.suffix
                < b.suffix
        end
    )

    local output = {
        string.char(
            WIRE_REVISION
        ),
    }

    table.insert(
        output,
        varuint_encode(
            Codebook.REVISION
        )
    )

    append_string(
        output,
        payload.first
    )

    append_string(
        output,
        payload.last
    )

    local background_stats =
        append_background(
            output,
            payload.background
        )

    local bitset_length =
        math.floor(
            (#Codebook.TAGS + 7)
            / 8
        )

    local bitset = {}

    for byte_index = 1, bitset_length do
        local value = 0
        local base_index =
            (byte_index - 1)
            * 8

        for bit = 0, 7 do
            local tag_index =
                base_index
                + bit
                + 1

            if tag_index <= #Codebook.TAGS
                and present[tag_index] then
                value =
                    value
                    | (1 << bit)
            end
        end

        table.insert(
            bitset,
            string.char(value)
        )
    end

    table.insert(
        output,
        table.concat(bitset)
    )

    table.insert(
        output,
        varuint_encode(
            #unknown
        )
    )

    local raw_asset_fallbacks = 0

    for index = 1, #Codebook.TAGS do
        if present[index] then
            local asset =
                known_assets[index]

            local table_name =
                TAG_TABLE[index]

            local reverse =
                ASSET_TO_ID_BY_TABLE[
                    table_name
                ]

            if asset ~= nil
                and (
                    reverse == nil
                    or reverse[asset] == nil
                ) then
                raw_asset_fallbacks =
                    raw_asset_fallbacks + 1
            end

            local asset_err =
                append_asset_ref(
                    output,
                    asset,
                    table_name
                )

            if asset_err ~= nil then
                return nil,
                    asset_err
            end
        end
    end

    for _, slot in ipairs(unknown) do
        append_string(
            output,
            slot.suffix
        )

        if slot.asset ~= nil then
            raw_asset_fallbacks =
                raw_asset_fallbacks + 1
        end

        local asset_err =
            append_asset_ref(
                output,
                slot.asset,
                nil
            )

        if asset_err ~= nil then
            return nil,
                asset_err
        end
    end

    return table.concat(output),
        {
            background = background_stats,
            extensionSlots = #unknown,
            rawAssetFallbacks = raw_asset_fallbacks,
        }
end

local function deserialize_body(body)
    local position = 1

    local revision =
        body:byte(position)

    if revision
        ~= WIRE_REVISION then
        return nil,
            "unsupported ZC1 wire revision"
    end

    position =
        position + 1

    local codebook_revision,
        after_codebook_revision,
        codebook_revision_err =
            varuint_decode(
                body,
                position
            )

    if codebook_revision_err ~= nil then
        return nil,
            codebook_revision_err
    end

    if codebook_revision
        ~= Codebook.REVISION then
        return nil,
            string.format(
                "ZC1 codebook revision %d does not match this build's revision %d",
                codebook_revision,
                Codebook.REVISION
            )
    end

    position =
        after_codebook_revision

    local first, first_err
    first, position, first_err =
        read_string(
            body,
            position,
            128
        )

    if first_err ~= nil then
        return nil,
            first_err
    end

    local last, last_err
    last, position, last_err =
        read_string(
            body,
            position,
            128
        )

    if last_err ~= nil then
        return nil,
            last_err
    end

    local background,
        background_next,
        background_err =
            read_background(
                body,
                position
            )

    if background_err ~= nil then
        return nil,
            background_err
    end

    position =
        background_next

    local bitset_length =
        math.floor(
            (#Codebook.TAGS + 7)
            / 8
        )

    if position
        + bitset_length
        - 1
        > #body then
        return nil,
            "truncated tag presence bitset"
    end

    local present = {}

    for byte_index = 1, bitset_length do
        local value =
            body:byte(
                position
                + byte_index
                - 1
            )

        local base_index =
            (byte_index - 1)
            * 8

        for bit = 0, 7 do
            local tag_index =
                base_index
                + bit
                + 1

            if tag_index <= #Codebook.TAGS
                and (value & (1 << bit))
                    ~= 0 then
                present[tag_index] = true
            end
        end
    end

    position =
        position
        + bitset_length

    local unknown_count,
        after_unknown_count,
        unknown_count_err =
            varuint_decode(
                body,
                position
            )

    if unknown_count_err ~= nil then
        return nil,
            unknown_count_err
    end

    if unknown_count > 256 then
        return nil,
            "unreasonable extension-slot count"
    end

    position =
        after_unknown_count

    local slots = {}

    for index = 1, #Codebook.TAGS do
        if present[index] then
            local asset,
                next_position,
                asset_err =
                    read_asset_ref(
                        body,
                        position,
                        TAG_TABLE[index]
                    )

            if asset_err ~= nil then
                return nil,
                    string.format(
                        "known slot %s: %s",
                        Codebook.TAGS[index],
                        asset_err
                    )
            end

            position =
                next_position

            table.insert(
                slots,
                {
                    TAG_PREFIX
                        .. Codebook.TAGS[index],
                    asset,
                }
            )
        end
    end

    for index = 1, unknown_count do
        local suffix,
            after_suffix,
            suffix_err =
                read_string(
                    body,
                    position,
                    256
                )

        if suffix_err ~= nil then
            return nil,
                string.format(
                    "extension slot %d tag: %s",
                    index,
                    suffix_err
                )
        end

        position =
            after_suffix

        local asset,
            after_asset,
            asset_err =
                read_asset_ref(
                    body,
                    position,
                    nil
                )

        if asset_err ~= nil then
            return nil,
                string.format(
                    "extension slot %d asset: %s",
                    index,
                    asset_err
                )
        end

        position =
            after_asset

        table.insert(
            slots,
            {
                TAG_PREFIX
                    .. suffix,
                asset,
            }
        )
    end

    if #slots < 1
        or #slots > 256 then
        return nil,
            "decoded slot count is invalid"
    end

    if position
        ~= #body + 1 then
        return nil,
            "binary payload has trailing data"
    end

    return {
        v = 1,
        first = first,
        last = last,
        background = background,
        slots = slots,
    }, nil
end

-- ---------------------------------------------------------------------------
-- Base62 using arbitrary-length manual long division/multiplication.
-- ---------------------------------------------------------------------------

local function base62_encode(input)
    local bytes = {}

    for index = 1, #input do
        bytes[index] =
            input:byte(index)
    end

    local leading_zeros = 0

    for index = 1, #bytes do
        if bytes[index] == 0 then
            leading_zeros =
                leading_zeros + 1
        else
            break
        end
    end

    local work = {}

    for index = 1, #bytes do
        work[index] =
            bytes[index]
    end

    local function is_zero(values)
        for index = 1, #values do
            if values[index] ~= 0 then
                return false
            end
        end

        return true
    end

    local digits = {}

    while not is_zero(work) do
        local remainder = 0

        for index = 1, #work do
            local current =
                remainder * 256
                + work[index]

            work[index] =
                math.floor(
                    current / 62
                )

            remainder =
                current % 62
        end

        table.insert(
            digits,
            1,
            BASE62_ALPHABET:sub(
                remainder + 1,
                remainder + 1
            )
        )
    end

    local zeros =
        BASE62_ALPHABET:sub(
            1,
            1
        ):rep(
            leading_zeros
        )

    if #digits == 0 then
        return zeros ~= ""
            and zeros
            or BASE62_ALPHABET:sub(
                1,
                1
            )
    end

    return zeros
        .. table.concat(digits)
end

local function base62_decode(input)
    local leading_zeros = 0

    for index = 1, #input do
        if input:sub(
            index,
            index
        ) == BASE62_ALPHABET:sub(
            1,
            1
        ) then
            leading_zeros =
                leading_zeros + 1
        else
            break
        end
    end

    local work = {}

    for index = 1, #input do
        local character =
            input:sub(
                index,
                index
            )

        local digit =
            BASE62_INDEX[
                character
            ]

        if digit == nil then
            return nil,
                "invalid Base62 character"
        end

        local carry =
            digit

        for work_index = #work, 1, -1 do
            local current =
                work[work_index]
                    * 62
                + carry

            work[work_index] =
                current % 256

            carry =
                math.floor(
                    current / 256
                )
        end

        while carry > 0 do
            table.insert(
                work,
                1,
                carry % 256
            )

            carry =
                math.floor(
                    carry / 256
                )
        end
    end

    local bytes = {}

    for index = 1, leading_zeros do
        bytes[index] = 0
    end

    for index = 1, #work do
        bytes[
            leading_zeros + index
        ] =
            work[index]
    end

    local chunks = {}

    for start_index = 1, #bytes, 1024 do
        local finish =
            math.min(
                #bytes,
                start_index + 1023
            )

        local values = {}

        for index = start_index, finish do
            table.insert(
                values,
                bytes[index]
            )
        end

        table.insert(
            chunks,
            string.char(
                table.unpack(values)
            )
        )
    end

    return table.concat(chunks), nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.encode(payload)
    local body,
        body_stats_or_err =
            serialize_body(
                payload
            )

    if body == nil then
        return nil,
            body_stats_or_err
    end

    local checksum =
        crc32_string(
            body
        )

    local binary_parts = {
        body,
    }

    append_u32_be(
        binary_parts,
        checksum
    )

    local binary =
        table.concat(
            binary_parts
        )

    local code =
        M.PREFIX
        .. base62_encode(
            binary
        )

    return code,
        {
            binaryBytes = #binary,
            bodyBytes = #body,
            codeCharacters = #code,
            crc32 = checksum,
            wireRevision = WIRE_REVISION,
            codebookRevision =
                Codebook.REVISION,
            background =
                body_stats_or_err.background,
            extensionSlots =
                body_stats_or_err.extensionSlots,
            rawAssetFallbacks =
                body_stats_or_err.rawAssetFallbacks,
        }
end

function M.decode(code)
    if type(code) ~= "string" then
        return nil,
            "import code is not a string"
    end

    if #code > 8192 then
        return nil,
            "share code is unreasonably large"
    end

    if code:sub(
        1,
        #M.PREFIX
    ) ~= M.PREFIX then
        return nil,
            "invalid Character Share prefix"
    end

    local encoded =
        code:sub(
            #M.PREFIX + 1
        )

    if encoded == "" then
        return nil,
            "share code has no payload"
    end

    local binary,
        base62_err =
            base62_decode(
                encoded
            )

    if binary == nil then
        return nil,
            base62_err
    end

    if #binary < 6 then
        return nil,
            "share code is too short"
    end

    local body =
        binary:sub(
            1,
            #binary - 4
        )

    local expected_crc,
        _,
        crc_err =
            read_u32_be(
                binary,
                #binary - 3
            )

    if crc_err ~= nil then
        return nil,
            crc_err
    end

    local actual_crc =
        crc32_string(
            body
        )

    if actual_crc
        ~= expected_crc then
        return nil,
            "checksum mismatch - code is corrupt or truncated"
    end

    local payload,
        payload_err =
            deserialize_body(
                body
            )

    if payload == nil then
        return nil,
            payload_err
    end

    return payload,
        {
            binaryBytes = #binary,
            bodyBytes = #body,
            codeCharacters = #code,
            crc32 = actual_crc,
            wireRevision = WIRE_REVISION,
            codebookRevision =
                Codebook.REVISION,
        }
end

function M.extract(contents)
    if type(contents) ~= "string" then
        return nil
    end

    local start_index =
        string.find(
            contents,
            M.PREFIX,
            1,
            true
        )

    if start_index == nil then
        return nil
    end

    local index =
        start_index
        + #M.PREFIX

    while index <= #contents do
        local character =
            contents:sub(
                index,
                index
            )

        if BASE62_INDEX[
            character
        ] == nil then
            break
        end

        index =
            index + 1
    end

    if index
        == start_index
            + #M.PREFIX then
        return nil
    end

    return contents:sub(
        start_index,
        index - 1
    )
end

function M.tag_dictionary_size()
    return #Codebook.TAGS
end

function M.asset_dictionary_size()
    return ASSET_DICTIONARY_SIZE
end

function M.asset_table_count()
    return #Codebook.TABLE_ORDER
end

function M.asset_table_sizes()
    local sizes = {}

    for _, table_name in ipairs(
        Codebook.TABLE_ORDER
    ) do
        sizes[table_name] =
            #Codebook.TABLES[
                table_name
            ]
    end

    return sizes
end

function M.codebook_revision()
    return Codebook.REVISION
end

function M.is_zc1_frozen()
    return Codebook.FROZEN == true
        and Codebook.REVISION == 1
        and WIRE_REVISION == 1
end

return M
