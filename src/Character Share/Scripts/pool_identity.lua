-- Character Share: scalar character identity and current native pool ownership.
-- Read only during duplicate checks; never retain iterator-backed structs.
return function(ctx)
    function ctx.pool_identity.guid_key(value)
        value = ctx.common.unwrap_remote_value(value)
        if value == nil then return nil end
        local ok, a, b, c, d = pcall(function()
            return value.A, value.B, value.C, value.D
        end)
        if not ok then return nil end
        local function component(n)
            if type(n) ~= "number" or n ~= n or n % 1 ~= 0
                or n < -2147483648 or n > 4294967295 then return nil end
            return n < 0 and n + 4294967296 or n
        end
        a, b, c, d = component(a), component(b), component(c), component(d)
        if a == nil or b == nil or c == nil or d == nil then return nil end
        if a == 0 and b == 0 and c == 0 and d == 0 then return nil end
        return string.format("%08X-%08X-%08X-%08X", a, b, c, d)
    end

    function ctx.pool_identity.character_guid(character_vm)
        if not ctx.layout.uobject_is_valid(character_vm) then return nil end
        local data = select(1, ctx.common.read_property(
            ctx.common.unwrap_remote_value(character_vm), "PoolCharacterData"))
        local guid = data and select(1, ctx.common.read_property(data, "PoolCharacterID"))
        return ctx.pool_identity.guid_key(guid)
    end

    function ctx.pool_identity.owner_snapshot()
        local manager = ctx.common.find_first("BitReactorCharacterPoolManager")
        if not ctx.layout.uobject_is_valid(manager) then
            return nil, "CharacterPoolManager unavailable"
        end
        -- A partial snapshot must never be mistaken for an empty authoritative
        -- pool. Fail the whole read if any enumeration/property is incomplete.
        local ok, owners = pcall(function()
            local pools = assert(manager.CharacterPools, "CharacterPools unavailable")
            local count = pools:GetArrayNum()
            assert(type(count) == "number" and count > 0, "CharacterPools not ready")
            local result, visited = {}, 0
            pools:ForEach(function(_, pool_value)
                visited = visited + 1
                local pool = ctx.common.unwrap_remote_value(pool_value)
                local pool_type = tonumber(pool.CharacterPoolType)
                assert(pool_type ~= nil, "pool type unavailable")
                if pool_type < 2 or pool_type > 5 then return end
                local name = ctx.common.text_value(assert(pool.CharacterPoolName))
                assert(name ~= "", "pool name unavailable")
                local chars = assert(pool.Characters, "pool membership unavailable")
                local expected, emitted = #chars, 0
                -- Empty reflected collections can hang in older UE4SS builds.
                if expected > 0 then
                    chars:ForEach(function(key, _)
                        emitted = emitted + 1
                        local guid = assert(ctx.pool_identity.guid_key(key), "invalid pool GUID")
                        assert(result[guid] == nil or result[guid] == name,
                            "conflicting native GUID ownership")
                        result[guid] = name
                    end)
                end
                assert(emitted == expected, "incomplete pool membership")
            end)
            assert(visited == count, "incomplete CharacterPools")
            return result
        end)
        if not ok then return nil, tostring(owners) end
        return owners, nil
    end
end
