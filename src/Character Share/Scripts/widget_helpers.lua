-- Character Share: widget helpers.
-- Initialized once per mod instance; shared references use explicit ctx fields.
-- Context: common, layout, logging, popup, widget_helpers.
return function(ctx)
    -- ---------------------------------------------------------------------------
    -- Character Databank buttons (0.6.x)
    --
    -- v0.6.3 makes this screen-scoped instead of construction-scoped.
    --
    -- We do NOT watch CharacterBank Page/Master object creation anymore. Exact
    -- NotifyOnNewObject callbacks can fire while Blueprint classes/CDOs/template
    -- WidgetTrees are being constructed, which is too early for live-panel work.
    --
    -- Instead we hook CommonActivatableWidget ActivateWidget / DeactivateWidget,
    -- filter to the runtime WBP_CharacterBank_Master_C instance, and make the
    -- Character Share widgets live only for that Databank activation.
    -- ---------------------------------------------------------------------------

    function ctx.widget_helpers.databank_widget_identity(widget)
        return ctx.common.popup_widget_identity(widget)
    end

    local function object_class_full_name(object)
        if object == nil then
            return nil
        end

        local class_object, class_err = ctx.common.try_call(function()
            return object:GetClass()
        end)

        if class_err ~= nil or class_object == nil then
            return nil
        end

        local class_name, name_err = ctx.common.try_call(function()
            return class_object:GetFullName()
        end)

        if name_err ~= nil then
            return nil
        end

        return tostring(class_name)
    end

    local function is_runtime_databank_master(widget)
        if widget == nil then
            return false
        end

        local class_name =
            object_class_full_name(widget)

        if class_name == nil
            or not string.find(
                class_name,
                "WBP_CharacterBank_Master_C",
                1,
                true
            ) then
            return false
        end

        local identity =
            ctx.widget_helpers.databank_widget_identity(widget)

        if identity == nil
            or identity == ""
            or string.find(
                identity,
                "Default__",
                1,
                true
            ) then
            return false
        end

        -- Runtime UMG instances live under /Engine/Transient. Blueprint assets and
        -- their template WidgetTrees do not.
        return string.find(
            identity,
            "/Engine/Transient",
            1,
            true
        ) ~= nil
    end

    local function databank_master_is_attached_and_visible(master)
        if not is_runtime_databank_master(master) then
            return false
        end

        local attached = false

        pcall(function()
            local parent =
                ctx.common.unwrap_hook_value(
                    master:GetParent()
                )

            if parent ~= nil then
                attached = true
            end
        end)

        if not attached then
            pcall(function()
                if master:IsInViewport() then
                    attached = true
                end
            end)
        end

        if not attached then
            return false
        end

        local visible = true

        pcall(function()
            visible = master:IsVisible()
        end)

        return visible
    end

    function ctx.widget_helpers.find_live_databank_master()
        local master =
            ctx.popup.current_databank_host()

        if databank_master_is_attached_and_visible(master) then
            return master
        end

        return nil
    end

    function ctx.widget_helpers.page_widget_property(page, property_name)
        local value, value_err =
            ctx.common.read_property(
                page,
                property_name
            )

        local widget =
            ctx.common.unwrap_hook_value(value)

        if value_err ~= nil then
            return nil, value_err
        end

        return widget, nil
    end

    local function widget_parent(widget)
        if widget == nil then
            return nil
        end

        local parent, parent_err = ctx.common.try_call(function()
            return ctx.common.unwrap_hook_value(
                widget:GetParent()
            )
        end)

        if parent_err ~= nil then
            return nil
        end

        return parent
    end

    function ctx.widget_helpers.panel_child_index(parent, child)
        if parent == nil or child == nil then
            return -1
        end

        local index, index_err = ctx.common.try_call(function()
            return parent:GetChildIndex(child)
        end)

        if index_err ~= nil or index == nil then
            return -1
        end

        return tonumber(index) or -1
    end

    function ctx.widget_helpers.verified_anchor_parent(anchor)
        if anchor == nil then
            return nil, -1
        end

        local parent =
            widget_parent(anchor)

        if parent == nil then
            return nil, -1
        end

        local index =
            ctx.widget_helpers.panel_child_index(
                parent,
                anchor
            )

        if index < 0 then
            return nil, -1
        end

        return parent, index
    end

    local function numeric_struct_field(value, field_name)
        if value == nil then
            return 0.0
        end

        local field, field_err =
            ctx.common.read_property(
                value,
                field_name
            )

        if field_err ~= nil
            or field == nil then
            return 0.0
        end

        return tonumber(field) or 0.0
    end

    local function widget_render_translation(widget)
        if widget == nil then
            return 0.0, 0.0
        end

        local transform =
            ctx.common.unwrap_hook_value(
                select(
                    1,
                    ctx.common.read_property(
                        widget,
                        "RenderTransform"
                    )
                )
            )

        if transform == nil then
            return 0.0, 0.0
        end

        local translation =
            ctx.common.unwrap_hook_value(
                select(
                    1,
                    ctx.common.read_property(
                        transform,
                        "Translation"
                    )
                )
            )

        if translation == nil then
            return 0.0, 0.0
        end

        return numeric_struct_field(
            translation,
            "X"
        ),
            numeric_struct_field(
                translation,
                "Y"
            )
    end

    local function set_widget_render_translation(
        widget,
        x,
        y
    )
        if widget == nil then
            return false
        end

        local _, set_err = ctx.common.try_call(function()
            widget:SetRenderTranslation({
                X = x or 0.0,
                Y = y or 0.0,
            })
        end)

        return set_err == nil
    end

    local function widget_axis_extent(
        widget,
        axis
    )
        if widget == nil then
            return 0.0
        end

        pcall(function()
            widget:ForceLayoutPrepass()
        end)

        local extent = nil

        pcall(function()
            local geometry =
                widget:GetCachedGeometry()

            if geometry ~= nil then
                local size =
                    geometry:GetLocalSize()

                if size ~= nil then
                    if axis == "vertical" then
                        extent = tonumber(size.Y)
                    else
                        extent = tonumber(size.X)
                    end
                end
            end
        end)

        if extent == nil
            or extent <= 0.5 then
            pcall(function()
                local desired =
                    widget:GetDesiredSize()

                if desired ~= nil then
                    if axis == "vertical" then
                        extent = tonumber(desired.Y)
                    else
                        extent = tonumber(desired.X)
                    end
                end
            end)
        end

        extent = extent or 0.0

        local slot =
            ctx.common.unwrap_hook_value(
                select(
                    1,
                    ctx.common.read_property(
                        widget,
                        "Slot"
                    )
                )
            )

        if slot ~= nil then
            local padding =
                ctx.common.unwrap_hook_value(
                    select(
                        1,
                        ctx.common.read_property(
                            slot,
                            "Padding"
                        )
                    )
                )

            if padding ~= nil then
                if axis == "vertical" then
                    extent = extent
                        + numeric_struct_field(
                            padding,
                            "Top"
                        )
                        + numeric_struct_field(
                            padding,
                            "Bottom"
                        )
                else
                    extent = extent
                        + numeric_struct_field(
                            padding,
                            "Left"
                        )
                        + numeric_struct_field(
                            padding,
                            "Right"
                        )
                end
            end
        end

        return math.max(
            0.0,
            extent
        )
    end

    function ctx.widget_helpers.visually_move_appended_child_to_index(
        parent,
        child,
        target_index,
        axis
    )
        if parent == nil
            or child == nil
            or target_index == nil
            or target_index < 0 then
            return false,
                "invalid visual-move arguments"
        end

        pcall(function()
            parent:ForceLayoutPrepass()
        end)

        local count = nil
        local count_err = nil

        count, count_err = ctx.common.try_call(function()
            return tonumber(
                parent:GetChildrenCount()
            )
        end)

        if count_err ~= nil
            or count == nil
            or count <= 0 then
            return false,
                "could not read parent child count"
        end

        local appended_index =
            ctx.widget_helpers.panel_child_index(
                parent,
                child
            )

        if appended_index ~= count - 1 then
            return false,
                "child is not the final appended panel child"
        end

        if target_index > appended_index then
            return false,
                "target index is beyond appended child"
        end

        if target_index == appended_index then
            return true, nil
        end

        local shifted = {}
        local shifted_extent = 0.0

        for index = target_index,
            appended_index - 1 do
            local sibling = nil
            local child_err = nil

            sibling, child_err = ctx.common.try_call(function()
                return ctx.common.unwrap_hook_value(
                    parent:GetChildAt(
                        index
                    )
                )
            end)

            if child_err ~= nil
                or sibling == nil then
                return false,
                    "could not read sibling at index "
                        .. tostring(index)
            end

            local extent =
                widget_axis_extent(
                    sibling,
                    axis
                )

            if extent <= 0.5 then
                return false,
                    "could not measure sibling at index "
                        .. tostring(index)
            end

            local base_x,
                base_y =
                    widget_render_translation(
                        sibling
                    )

            table.insert(
                shifted,
                {
                    widget = sibling,
                    extent = extent,
                    baseX = base_x,
                    baseY = base_y,
                }
            )

            shifted_extent =
                shifted_extent
                    + extent
        end

        local child_extent =
            widget_axis_extent(
                child,
                axis
            )

        if child_extent <= 0.5 then
            return false,
                "could not measure appended child"
        end

        local child_base_x,
            child_base_y =
                widget_render_translation(
                    child
                )

        local applied = {}

        for _, entry in ipairs(shifted) do
            local x = entry.baseX
            local y = entry.baseY

            if axis == "vertical" then
                y = y + child_extent
            else
                x = x + child_extent
            end

            if not set_widget_render_translation(
                entry.widget,
                x,
                y
            ) then
                for _, rollback in ipairs(applied) do
                    set_widget_render_translation(
                        rollback.widget,
                        rollback.baseX,
                        rollback.baseY
                    )
                end

                return false,
                    "could not translate native sibling"
            end

            table.insert(
                applied,
                entry
            )
        end

        local child_x = child_base_x
        local child_y = child_base_y

        if axis == "vertical" then
            child_y =
                child_y
                    - shifted_extent
        else
            child_x =
                child_x
                    - shifted_extent
        end

        if not set_widget_render_translation(
            child,
            child_x,
            child_y
        ) then
            for _, rollback in ipairs(applied) do
                set_widget_render_translation(
                    rollback.widget,
                    rollback.baseX,
                    rollback.baseY
                )
            end

            return false,
                "could not translate appended child"
        end

        ctx.logging.log(
            string.format(
                "Databank visual child rotation: axis=%s target=%d appended=%d childExtent=%.1f shiftedExtent=%.1f",
                tostring(axis),
                target_index,
                appended_index,
                child_extent,
                shifted_extent
            )
        )

        return true, nil
    end

    function ctx.widget_helpers.set_databank_button_text(
        button,
        label
    )
        if button == nil then
            return
        end

        pcall(function()
            button:UpdateText(FText(label))
        end)

        pcall(function()
            button:SetButtonText(FText(label))
        end)

        local rich_text =
            ctx.common.unwrap_hook_value(
                select(
                    1,
                    ctx.common.read_property(
                        button,
                        "BitReactorRichTextBlock_74"
                    )
                )
            )

        if rich_text ~= nil then
            pcall(function()
                rich_text:SetTextEx(FText(label))
            end)

            pcall(function()
                rich_text:SetText(FText(label))
            end)
        end
    end

    ctx.layout =
        ctx.layout or {}

    function ctx.layout.create_user_widget_like(
        world_context,
        template,
        object_name
    )
        if world_context == nil
            or template == nil then
            return nil,
                "template widget unavailable"
        end

        local widget_class,
            class_err =
                ctx.common.try_call(function()
                    return template:GetClass()
                end)

        if class_err ~= nil
            or widget_class == nil then
            return nil,
                "template class unavailable: "
                    .. tostring(class_err)
        end

        local library_class,
            library_class_err =
                ctx.popup.load_class(
                    "/Script/UMG.WidgetBlueprintLibrary"
                )

        if library_class_err ~= nil
            or library_class == nil then
            return nil,
                "WidgetBlueprintLibrary unavailable"
        end

        local library,
            library_err =
                ctx.common.try_call(function()
                    return library_class:GetCDO()
                end)

        if library_err ~= nil
            or library == nil then
            return nil,
                "WidgetBlueprintLibrary CDO unavailable"
        end

        local owning_player = nil

        pcall(function()
            owning_player =
                world_context:GetOwningPlayer()
        end)

        local widget,
            create_err =
                ctx.common.try_call(function()
                    return library:Create(
                        world_context,
                        widget_class,
                        owning_player
                    )
                end)

        if create_err ~= nil
            or widget == nil then
            return nil,
                "could not create native-style widget: "
                    .. tostring(create_err)
        end

        pcall(function()
            widget:Rename(
                FName(object_name),
                world_context
            )
        end)

        ctx.logging.log(
            "Databank native-style clone created: template="
                .. ctx.popup.dialog_widget_class_name(template)
                .. " clone="
                .. ctx.popup.dialog_widget_class_name(widget)
        )

        return widget, nil
    end

    function ctx.layout.capture_box_slot_layout(
        child
    )
        local layout = {}

        if child == nil then
            return layout
        end

        local slot =
            ctx.common.unwrap_hook_value(
                select(
                    1,
                    ctx.common.read_property(
                        child,
                        "Slot"
                    )
                )
            )

        if slot == nil then
            return layout
        end

        local getters = {
            { key = "Padding", method = "GetPadding" },
            { key = "Size", method = "GetSize" },
            { key = "HorizontalAlignment", method = "GetHorizontalAlignment" },
            { key = "VerticalAlignment", method = "GetVerticalAlignment" },
        }

        for _,
            spec in ipairs(getters) do
            local value = nil

            pcall(function()
                value =
                    slot[spec.method](
                        slot
                    )
            end)

            if value == nil then
                local property_value,
                    property_err =
                        ctx.common.read_property(
                            slot,
                            spec.key
                        )

                if property_err == nil then
                    value =
                        property_value
                end
            end

            if value ~= nil then
                layout[spec.key] =
                    value
            end
        end

        return layout
    end

    function ctx.layout.apply_box_slot_layout(
        slot,
        layout
    )
        if slot == nil
            or layout == nil then
            return
        end

        if layout.Padding ~= nil then
            pcall(function()
                slot:SetPadding(
                    layout.Padding
                )
            end)
        end

        if layout.Size ~= nil then
            pcall(function()
                slot:SetSize(
                    layout.Size
                )
            end)
        end

        if layout.HorizontalAlignment ~= nil then
            pcall(function()
                slot:SetHorizontalAlignment(
                    layout.HorizontalAlignment
                )
            end)
        end

        if layout.VerticalAlignment ~= nil then
            pcall(function()
                slot:SetVerticalAlignment(
                    layout.VerticalAlignment
                )
            end)
        end
    end

    function ctx.layout.horizontal_fill(
        slot,
        left_padding
    )
        if slot == nil then
            return
        end

        pcall(function()
            slot:SetSize({
                Value = 1.0,
                SizeRule = 1,
            })
        end)

        pcall(function()
            slot:SetPadding({
                Left = left_padding or 0.0,
                Top = 0.0,
                Right = 0.0,
                Bottom = 0.0,
            })
        end)

        pcall(function()
            slot:SetHorizontalAlignment(3)
            slot:SetVerticalAlignment(2)
        end)
    end

    function ctx.layout.collect_widget_tree(
        user_widget
    )
        local widgets = {}

        if user_widget == nil then
            return widgets
        end

        local tree =
            ctx.common.unwrap_hook_value(
                select(
                    1,
                    ctx.common.read_property(
                        user_widget,
                        "WidgetTree"
                    )
                )
            )

        if tree == nil then
            return widgets
        end

        local root =
            ctx.common.unwrap_hook_value(
                select(
                    1,
                    ctx.common.read_property(
                        tree,
                        "RootWidget"
                    )
                )
            )

        if root == nil then
            return widgets
        end

        local function visit(widget)
            if widget == nil then
                return
            end

            table.insert(
                widgets,
                widget
            )

            local count = nil

            pcall(function()
                count =
                    tonumber(
                        widget:GetChildrenCount()
                    )
            end)

            if count == nil
                or count <= 0 then
                return
            end

            for index = 0, count - 1 do
                local child = nil

                pcall(function()
                    child =
                        ctx.common.unwrap_hook_value(
                            widget:GetChildAt(
                                index
                            )
                        )
                end)

                if child ~= nil then
                    visit(child)
                end
            end
        end

        visit(root)

        return widgets
    end

    function ctx.layout.find_widget(
        user_widget,
        needle
    )
        needle = tostring(needle or "")

        if needle == "" then
            return nil
        end

        for _, widget in ipairs(
            ctx.layout
                .collect_widget_tree(
                    user_widget
                )
        ) do
            local identity =
                ctx.widget_helpers.databank_widget_identity(
                    widget
                )

            local class_name =
                ctx.popup.dialog_widget_class_name(
                    widget
                )

            if string.find(
                tostring(identity or ""),
                needle,
                1,
                true
            ) ~= nil
                or string.find(
                    tostring(class_name or ""),
                    needle,
                    1,
                    true
                ) ~= nil then
                return widget
            end
        end

        return nil
    end

    function ctx.layout.set_clone_label(
        button,
        label
    )
        local changed = 0

        for _,
            widget in ipairs(
                ctx.layout
                    .collect_widget_tree(
                        button
                    )
            ) do
            local class_name =
                ctx.popup.dialog_widget_class_name(
                    widget
                )

            if class_name:find(
                "RichTextBlock",
                1,
                true
            ) ~= nil
                or class_name:find(
                    "TextBlock",
                    1,
                    true
                ) ~= nil then
                local ok = false

                pcall(function()
                    widget:SetTextEx(
                        FText(label)
                    )
                    ok = true
                end)

                pcall(function()
                    widget:SetText(
                        FText(label)
                    )
                    ok = true
                end)

                if ok then
                    changed =
                        changed + 1
                end
            end
        end

        pcall(function()
            button:UpdateText(
                FText(label)
            )
            button:SetButtonText(
                FText(label)
            )
            button:SetText(
                FText(label)
            )
        end)

        ctx.logging.log(
            string.format(
                "Databank clone label update: label=%s descendantsChanged=%d",
                tostring(label),
                changed
            )
        )

        return changed > 0
    end

    function ctx.layout.image_dimensions(
        widget
    )
        if widget == nil then
            return 0.0,
                0.0
        end

        pcall(function()
            widget:ForceLayoutPrepass()
        end)

        local width = nil
        local height = nil

        pcall(function()
            local geometry =
                widget:GetCachedGeometry()

            local size =
                geometry ~= nil
                    and geometry:GetLocalSize()
                    or nil

            if size ~= nil then
                width = tonumber(size.X)
                height = tonumber(size.Y)
            end
        end)

        if width == nil
            or height == nil
            or width <= 0.5
            or height <= 0.5 then
            pcall(function()
                local size =
                    widget:GetDesiredSize()

                if size ~= nil then
                    width = tonumber(size.X)
                    height = tonumber(size.Y)
                end
            end)
        end

        return width or 0.0,
            height or 0.0
    end

    function ctx.layout.hide_single_clone_image(
        button
    )
        local images = {}

        for _,
            widget in ipairs(
                ctx.layout
                    .collect_widget_tree(
                        button
                    )
            ) do
            if ctx.popup.dialog_widget_class_name(
                widget
            ):find(
                "Image",
                1,
                true
            ) ~= nil then
                local width,
                    height =
                        ctx.layout
                            .image_dimensions(
                                widget
                            )

                table.insert(
                    images,
                    {
                        widget = widget,
                        width = width,
                        height = height,
                    }
                )
            end
        end

        local hidden = 0

        for _, image in ipairs(images) do
            if image.width >= 4.0
                and image.height >= 4.0
                and image.width <= 56.0
                and image.height <= 56.0 then
                local ok = pcall(function()
                    image.widget:SetRenderOpacity(0.0)
                    image.widget:SetVisibility(3)
                end)

                if ok then
                    hidden = hidden + 1
                end
            end
        end

        ctx.logging.log(
            "Databank compact IMPORT inherited images cleaned: imageCount="
                .. tostring(#images)
                .. " hiddenCompactImages="
                .. tostring(hidden)
        )

        return hidden > 0
    end

    function ctx.layout.initialize_share_visual(
        button
    )
        if button == nil then
            return false
        end

        -- Set only the clone's scalar style properties,
        -- then ask the widget's own parameterless Blueprint ApplyStyle() routine to
        -- resolve its internal visual exactly as the game does.
        local _, apply_err = ctx.common.try_call(function()
            button.ButtonOrientation = 1
            button.ButtonSize = 0
            button.ButtonType = 0
            button:ApplyStyle()
        end)

        if apply_err ~= nil then
            ctx.logging.log(
                "Databank SHARE native ApplyStyle orientation failed; leaving current visual: "
                    .. tostring(apply_err)
            )
        else
            ctx.logging.log(
                "Databank SHARE native ApplyStyle completed for orientation=1 size=0 type=0."
            )
        end

        -- Apply the label after style resolution because ApplyStyle may switch the
        -- concrete child that owns the visible text.
        ctx.layout.set_clone_label(
            button,
            "SHARE"
        )

        return apply_err == nil
    end

    function ctx.layout.polish_action_row(
        page,
        share_button
    )
        -- Intentionally a no-op for native controls. Their cooked Databank style
        -- is already correct; Character Share must not switch their ButtonSwitcher
        -- to the dialog-only Long family.
        if page ~= nil
            and share_button ~= nil then
            ctx.logging.log(
                "Databank native action buttons preserved unchanged; SHARE remains on its cloned class-default visual."
            )
        end
    end

    function ctx.layout.widget_local_width(
        widget
    )
        if widget == nil then
            return nil
        end

        pcall(function()
            widget:ForceLayoutPrepass()
        end)

        local width = nil

        pcall(function()
            local geometry =
                widget:GetCachedGeometry()

            if geometry ~= nil then
                local size =
                    geometry:GetLocalSize()

                if size ~= nil then
                    width =
                        tonumber(size.X)
                end
            end
        end)

        if width ~= nil
            and width > 1.0 then
            return width
        end

        pcall(function()
            local size =
                widget:GetDesiredSize()

            if size ~= nil then
                width =
                    tonumber(size.X)
            end
        end)

        if width ~= nil
            and width > 1.0 then
            return width
        end

        return nil
    end

    function ctx.layout.make_width_wrapper(
        owner,
        child,
        object_name,
        width
    )
        local wrapper,
            wrapper_err =
                ctx.popup.construct_native_widget(
                    owner,
                    "/Script/UMG.SizeBox",
                    object_name
                )

        if wrapper == nil then
            return nil,
                nil,
                "SizeBox unavailable: "
                    .. tostring(wrapper_err)
        end

        if width ~= nil
            and width > 1.0 then
            pcall(function()
                wrapper:SetWidthOverride(
                    width
                )
            end)
        end

        local child_slot = nil

        pcall(function()
            child_slot =
                wrapper:AddChild(
                    child
                )
        end)

        child_slot =
            ctx.common.unwrap_hook_value(
                child_slot
            )

        if child_slot == nil then
            return nil,
                nil,
                "could not add child to SizeBox"
        end

        pcall(function()
            child_slot:SetHorizontalAlignment(3)
            child_slot:SetVerticalAlignment(3)
        end)

        return wrapper,
            child_slot,
            nil
    end

    function ctx.layout.configure_row_slot(
        slot,
        left_padding
    )
        if slot == nil then
            return
        end

        -- Keep each fixed-width wrapper in Auto mode. Using Fill here lets the
        -- cloned Create New widgets advertise their original full width again.
        pcall(function()
            slot:SetSize({
                Value = 1.0,
                SizeRule = 0,
            })
        end)

        pcall(function()
            slot:SetPadding({
                Left = left_padding or 0.0,
                Top = 0.0,
                Right = 0.0,
                Bottom = 0.0,
            })
        end)

        pcall(function()
            slot:SetHorizontalAlignment(3)
            slot:SetVerticalAlignment(2)
        end)
    end
end
