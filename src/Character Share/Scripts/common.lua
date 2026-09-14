-- Character Share: common.
-- Initialized once per mod instance; shared references use explicit ctx fields.
-- Context: common.
return function(ctx)
    function ctx.common.try_call(fn)
        local ok, result = pcall(fn)
        if ok then
            return result, nil
        end
        return nil, tostring(result)
    end

    function ctx.common.read_property(object, property_name)
        if object == nil then
            return nil, "owner nil"
        end

        return ctx.common.try_call(function()
            return object[property_name]
        end)
    end

    function ctx.common.find_first(class_name)
        local object, err = ctx.common.try_call(function()
            return FindFirstOf(class_name)
        end)

        if err ~= nil or object == nil then
            return nil
        end

        return object
    end

    function ctx.common.text_value(value)
        if value == nil then
            return ""
        end

        local value_type = type(value)
        if value_type == "string" then
            return value
        elseif value_type == "number" or value_type == "boolean" then
            return tostring(value)
        end

        local text, err = ctx.common.try_call(function()
            return value:ToString()
        end)

        if err == nil and text ~= nil then
            return tostring(text)
        end

        return tostring(value)
    end

    function ctx.common.gameplay_tag_value(tag)
        if tag == nil then
            return nil
        end

        local tag_name, err = ctx.common.read_property(tag, "TagName")
        if err == nil and tag_name ~= nil then
            return ctx.common.text_value(tag_name)
        end

        return nil
    end

    function ctx.common.is_color_slot_tag(tag)
        if type(tag) ~= "string" then
            return false
        end

        return string.find(
                tag,
                ".Color",
                1,
                true
            ) ~= nil
            or string.find(
                tag,
                "SkinTone",
                1,
                true
            ) ~= nil
    end

    function ctx.common.count_color_slots(payload)
        local count = 0

        for _, pair in ipairs(
            payload.slots or {}
        ) do
            if type(pair) == "table"
                and ctx.common.is_color_slot_tag(
                    pair[1]
                ) then
                count =
                    count + 1
            end
        end

        return count
    end

    function ctx.common.primary_asset_id_value(asset_id)
        if asset_id == nil then
            return nil
        end

        local asset_type, type_err = ctx.common.read_property(asset_id, "PrimaryAssetType")
        local asset_name, name_err = ctx.common.read_property(asset_id, "PrimaryAssetName")

        if type_err ~= nil or name_err ~= nil or asset_name == nil then
            return nil
        end

        local type_name = nil
        if asset_type ~= nil then
            local nested_name, nested_err = ctx.common.read_property(asset_type, "Name")
            if nested_err == nil and nested_name ~= nil then
                type_name = ctx.common.text_value(nested_name)
            else
                type_name = ctx.common.text_value(asset_type)
            end
        end

        local name_text = ctx.common.text_value(asset_name)

        if name_text == "" or name_text == "None" then
            return nil
        end

        if type_name == nil or type_name == "" or type_name == "None" then
            return name_text
        end

        return type_name .. ":" .. name_text
    end

    function ctx.common.array_count(array)
        if array == nil then
            return 0
        end

        local count, err = ctx.common.try_call(function()
            return array:GetArrayNum()
        end)

        if err == nil and count ~= nil then
            return tonumber(count) or 0
        end

        count, err = ctx.common.try_call(function()
            return #array
        end)

        if err == nil and count ~= nil then
            return tonumber(count) or 0
        end

        return 0
    end

    function ctx.common.for_each_array(array, callback)
        if array == nil then
            return
        end

        local count = ctx.common.array_count(array)
        local emitted = 0

        local ok = pcall(function()
            for index, value in ipairs(array) do
                emitted = emitted + 1
                callback(index, value)
                if emitted >= count then
                    break
                end
            end
        end)

        if ok and (emitted > 0 or count == 0) then
            return
        end

        for index = 0, count - 1 do
            local value, err = ctx.common.try_call(function()
                return array[index]
            end)

            if err == nil then
                callback(index, value)
            end
        end
    end

    function ctx.common.popup_widget_identity(object)
        if object == nil then
            return "<nil>"
        end

        local full_name, full_name_err = ctx.common.try_call(function()
            return object:GetFullName()
        end)

        if full_name_err == nil and full_name ~= nil then
            return tostring(full_name)
        end

        return tostring(object)
    end

    function ctx.common.same_remote_object(a, b)
        if a == nil or b == nil then
            return false
        end

        if a == b then
            return true
        end

        return ctx.common.popup_widget_identity(a) == ctx.common.popup_widget_identity(b)
    end

    function ctx.common.unwrap_remote_value(value)
        if value == nil then
            return nil
        end

        -- UE4SS can surface UObject-valued UFunction returns / TArray elements as
        -- RemoteUnrealParam wrappers. Calling UObject methods on the wrapper
        -- itself fails even though the wrapped UObject is valid.
        local unwrapped, unwrap_err =
            ctx.common.try_call(
                function()
                    return value:get()
                end
            )

        if unwrap_err == nil
            and unwrapped ~= nil then
            return unwrapped
        end

        return value
    end

    function ctx.common.unwrap_hook_value(value)
        return ctx.common.unwrap_remote_value(
            value
        )
    end
end
