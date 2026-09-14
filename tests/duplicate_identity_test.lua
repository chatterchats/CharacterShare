-- Run: luajit tests/duplicate_identity_test.lua "src/Character Share/Scripts"
local scripts = assert(arg[1])
local function wrap(value) return { get = function() return value end } end
local function object(path)
    return {
        IsValid = function(self) return self.valid ~= false end,
        GetFullName = function() return path end,
    }
end
local function array(values)
    values.GetArrayNum = function(self) return #self end
    values.ForEach = function(self, callback)
        assert(#self > 0, "empty native array iteration")
        for i, value in ipairs(self) do callback(i, wrap(value)) end
    end
    return values
end
local function map(keys)
    keys.ForEach = function(self, callback)
        assert(#self > 0, "empty native map iteration")
        for _, key in ipairs(self) do callback(wrap(key), {}) end
    end
    return keys
end
local function guid(id) return { A = id, B = 2, C = 3, D = 4 } end
local function character(path, id, name)
    local value = object(path)
    value.PoolCharacterData = { PoolCharacterID = id }
    value.display_name = name or "Rico"
    return value
end
local function pool(name, characters)
    local value = object(name)
    value.PoolName = name
    value.PoolCharacterViewModels = array(characters)
    return value
end
local function native_pool(name, keys, kind)
    return { CharacterPoolName = name, CharacterPoolType = kind or 5, Characters = map(keys) }
end
local manager = object("manager")
function FindFirstOf(name)
    assert(name == "BitReactorCharacterPoolManager")
    return manager
end
function StaticFindObject(path)
    assert(path == "/Script/Bruno.BrunoCharacterPoolCharacterViewModel:GetFullName")
    return function(value)
        assert(value:IsValid(), "invalid VM reached native name getter")
        return value.display_name
    end
end
local ctx = { common = {}, logging = { log = function() end },
    import_validation = {}, pool_identity = {}, layout = {} }
assert(loadfile(scripts .. "/common.lua"))()(ctx)
ctx.layout.uobject_is_valid = function(value)
    value = ctx.common.unwrap_remote_value(value)
    return value ~= nil and value:IsValid()
end
assert(loadfile(scripts .. "/pool_identity.lua"))()(ctx)
assert(loadfile(scripts .. "/import_validation.lua"))()(ctx)
local a, b, c = guid(1), guid(2), guid(3)
local old = character("Default.Rico", a)
local live = character("Folder.Rico", a)
local default = pool("Default Custom Characters", { old })
local custom = pool("Look at the folders!", { live })
local astromechs = pool("Default Astromechs", {})
local databank = {
    DefaultCustomCharacterPoolViewModel = default,
    CustomCharacterPoolViewModels = array({ custom }),
    DefaultAstromechCharacterPoolViewModel = astromechs,
    AstromechCharacterPoolViewModel = array({}),
}
local function ownership(default_ids, custom_ids, astro_ids)
    manager.CharacterPools = array({
        native_pool(default.PoolName, default_ids, 4),
        native_pool(custom.PoolName, custom_ids, 5),
        native_pool(astromechs.PoolName, astro_ids or {}, 2),
    })
end
local function check(count, unreadable, name)
    local matches, errors = ctx.import_validation.find_duplicate_characters(
        databank, { first = name or "Rico", last = "", characterType = "humanoid" })
    assert(#matches == count, "expected " .. count .. " matches, got " .. #matches)
    assert(errors == unreadable, "expected " .. unreadable .. " unreadable, got " .. errors)
    return matches
end
ownership({}, { a })
assert(check(1, 0)[1].vm == live, "overwrite must choose the owning pool's VM")
check(0, 0, "Rico 2")
-- The same UObject may also appear in both arrays; seeing it in the stale
-- source first must not hide its later authoritative-pool occurrence.
custom.PoolCharacterViewModels = array({ old })
assert(check(1, 0)[1].vm == old)
custom.PoolCharacterViewModels = array({ live })
ownership({ a }, {})
assert(check(1, 0)[1].vm == old, "moving back to Default must select Default's VM")
ownership({}, { a })
custom.PoolCharacterViewModels = array({ live, character("Folder.Rico.CopyVM", a) })
check(1, 0)
local other = character("Folder.OtherRico", b)
custom.PoolCharacterViewModels = array({ live, other })
ownership({}, { a, b })
check(2, 0) -- same name, genuinely different characters
astromechs.PoolCharacterViewModels = array({ character("Astromech.Rico", c) })
ownership({}, { a, b }, { c })
local mixed = check(3, 0)
assert(mixed[3].characterType == "astromech")
astromechs.PoolCharacterViewModels = array({})
custom.PoolCharacterViewModels = array({ live })
ownership({}, {})
check(0, 0) -- deleted GUID remains in both old VM arrays, but isn't a conflict
ownership({}, { a })
custom.PoolCharacterViewModels = array({})
check(1, 1) -- owner exists but its VM has not converged: don't offer unsafe overwrite
custom.PoolCharacterViewModels = array({ live })
local unavailable_manager = manager
manager = nil
check(1, 1) -- GUID-deduplicated fallback, with uncertainty blocking mutation
manager = unavailable_manager
ownership({}, { a })
manager.CharacterPools[2].Characters.ForEach = function() end
local snapshot, err = ctx.pool_identity.owner_snapshot()
assert(snapshot == nil and err:find("incomplete pool membership", 1, true))
check(1, 1) -- partial snapshot must not claim every stale entry is deleted
ownership({}, { a })
default.PoolCharacterViewModels = array({})
custom.PoolCharacterViewModels = array({
    character("Unknown1", nil), character("Unknown2", { A = 0, B = 0, C = 0, D = 0 }),
})
check(2, 2) -- unknown IDs never collapse unrelated characters into one
live.valid = false
custom.PoolCharacterViewModels = array({ live })
check(0, 1)
assert(ctx.pool_identity.guid_key(guid(-1)) == ctx.pool_identity.guid_key(guid(4294967295)))
assert(ctx.pool_identity.guid_key({ A = 1.5, B = 2, C = 3, D = 4 }) == nil)
assert(ctx.pool_identity.guid_key({ A = math.huge, B = 2, C = 3, D = 4 }) == nil)
ctx.import_dialogs = {}
local shown_body, shown_actions
ctx.popup = { show_native_dialog = function(_, _, body, actions)
    shown_body, shown_actions = body, actions
    return {}
end }
assert(loadfile(scripts .. "/import_dialogs.lua"))()(ctx)
ctx.import_dialogs.show_duplicate_resolution_popup(
    { first = "Rico", last = "", characterType = "humanoid" }, { mixed[1] }, 1)
assert(shown_body:find("could not be verified", 1, true))
for _, action in ipairs(shown_actions) do
    assert(action.id ~= "duplicate_overwrite", "uncertain ownership offered overwrite")
end
print("duplicate GUID identity, ownership, deletion, and fail-closed tests passed")
