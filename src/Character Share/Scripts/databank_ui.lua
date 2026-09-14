-- Character Share: databank ui.
-- Initialized once per mod instance; shared references use explicit ctx fields.
-- Context: common, databank_ui, dependencies, layout, logging, popup, runtime, state, widget_helpers.
return function(ctx)
    local function create_unregistered_databank_button(
        page,
        object_name
    )
        local button, button_err =
            ctx.popup.create_user_widget(
                page,
                ctx.dependencies.UI.DATABANK_TOPNAV_BUTTON_CLASS_PATH
            )

        if button_err ~= nil or button == nil then
            ctx.logging.log(
                "Databank button creation failed: "
                    .. tostring(button_err)
            )
            return nil
        end

        pcall(function()
            button:Rename(
                FName(object_name),
                page
            )

            button:SetButtonInteractionEnabled(true)
            button:SetIsInteractionEnabled(true)
            button:SetIsFocusable(true)
            button:SetIsSelectable(false)
        end)

        return button
    end

    local function register_attached_databank_button(
        button,
        action,
        label,
        icon_canvas
    )
        local identity =
            ctx.widget_helpers.databank_widget_identity(button)

        ctx.state.databank_ui_state.buttons[identity] = {
            action = action,
            label = label,
            button = button,
            iconCanvas = icon_canvas,
        }

        -- No delayed label callback: this UI is deliberately screen-scoped.
        ctx.widget_helpers.set_databank_button_text(
            button,
            label
        )

        ctx.logging.log(
            string.format(
                "Databank button attached+registered: %s -> %s",
                identity,
                action
            )
        )
    end

    function ctx.layout.set_databank_button_hover_state(
        button_value,
        hovered
    )
        local button =
            ctx.common.unwrap_hook_value(button_value)

        if button == nil then
            return
        end

        local identity =
            ctx.widget_helpers.databank_widget_identity(button)

        local entry =
            ctx.state.databank_ui_state.buttons[identity]

        if entry == nil
            or entry.action ~= "databank_import"
            or entry.iconCanvas == nil then
            return
        end

        ctx.layout
            .set_import_icon_color(
                entry.iconCanvas,
                hovered
                    and {
                        R = 0.05,
                        G = 0.06,
                        B = 0.07,
                        A = 1.0,
                    }
                    or {
                        R = 0.82,
                        G = 0.85,
                        B = 0.86,
                        A = 1.0,
                    }
            )
    end

    function ctx.layout.register_databank_hover_hooks()
        if ctx.state.databank_ui_state.hoverHooksRegistered then
            return true
        end

        local hover_ok, hover_id = pcall(function()
            return ctx.runtime:register_hook(
                "/Script/CommonUI.CommonButtonBase:BP_OnHovered",
                function(self)
                    ctx.layout
                        .set_databank_button_hover_state(
                        self,
                        true
                    )
                end
            )
        end)

        local unhover_ok, unhover_id = pcall(function()
            return ctx.runtime:register_hook(
                "/Script/CommonUI.CommonButtonBase:BP_OnUnhovered",
                function(self)
                    ctx.layout
                        .set_databank_button_hover_state(
                        self,
                        false
                    )
                end
            )
        end)

        if hover_ok and hover_id ~= nil
            and unhover_ok and unhover_id ~= nil then
            ctx.state.databank_ui_state.hoverHooksRegistered = true
            ctx.logging.log(
                "Databank IMPORT icon uses event-driven hover tint hooks."
            )
            return true
        end

        ctx.logging.log(
            "WARNING: Databank IMPORT hover hooks unavailable: hover="
                .. tostring(hover_id)
                .. " unhover="
                .. tostring(unhover_id)
        )
        return false
    end

    function ctx.databank_ui.install_import_button(
        page,
        page_state
    )
        -- Lua state is recreated by reloads while the page WidgetTree can survive.
        -- Rebind the attached control and its glyph before considering a new clone.
        local attached = ctx.layout.find_widget(page, "CharacterShare_ImportButton")
        if ctx.layout.uobject_is_valid(attached)
            and select(1, ctx.common.try_call(function() return attached:GetParent() end)) ~= nil then
            local canvas = ctx.layout.find_widget(page, "CharacterShare_ImportGlyphCanvas")
            if not ctx.layout.uobject_is_valid(canvas) then canvas = nil end
            register_attached_databank_button(attached, "databank_import", "IMPORT", canvas)
            ctx.layout.set_clone_label(attached, "")
            ctx.layout.hide_single_clone_image(attached)
            page_state.importInstalled = true
            page_state.importRow = ctx.layout.find_widget(page, "CharacterShare_CreateImportRow")
            ctx.logging.log("Databank IMPORT adopted from existing WidgetTree.")
            return true
        end
        page_state.importInstalled = false

        local create_new =
            select(
                1,
                ctx.widget_helpers.page_widget_property(
                    page,
                    "WBP_CharacterBankCreateNewBtn"
                )
            )

        if create_new == nil then
            ctx.logging.log(
                "Databank IMPORT not ready: WBP_CharacterBankCreateNewBtn unavailable."
            )
            return false
        end

        local import_button,
            import_err =
                ctx.layout
                    .create_user_widget_like(
                        page,
                        create_new,
                        "CharacterShare_ImportButton"
                    )

        if import_button == nil then
            ctx.logging.log(
                "Databank IMPORT native-template creation failed: "
                    .. tostring(import_err)
            )
            return false
        end

        pcall(function()
            import_button:SetButtonInteractionEnabled(true)
            import_button:SetIsInteractionEnabled(true)
            import_button:SetIsFocusable(true)
            import_button:SetIsSelectable(false)
        end)

        local import_overlay,
            import_canvas,
            glyph_err =
                ctx.layout
                    .install_import_glyph(
                        page,
                        import_button
                    )

        if import_overlay == nil then
            ctx.logging.log(
                "Databank IMPORT compact glyph creation failed: "
                    .. tostring(glyph_err)
            )
            return false
        end

        local function finish_install(
            row,
            layout_mode
        )
            register_attached_databank_button(
                import_button,
                "databank_import",
                "IMPORT",
                import_canvas
            )

            -- Registration updates native button text for ordinary action buttons.
            -- This compact action is icon-only, so clear it once more afterwards.
            ctx.layout
                .set_clone_label(
                    import_button,
                    ""
                )

            ctx.layout
                .hide_single_clone_image(
                    import_button
                )

            local expected_identity =
                ctx.widget_helpers.databank_widget_identity(
                    import_button
                )

            -- The native Create New clone can rebuild its + image and text branch
            -- during its delayed Construct/style pass. Enhanced Databank performs
            -- the same second cleanup for Create Folder; mirror it here so only the
            -- UMG file-import glyph remains visible.
            ctx.layout.run_after(80, function()
                    local entry =
                        ctx.state.databank_ui_state.buttons[
                            expected_identity
                        ]

                    if entry ~= nil
                        and entry.action
                            == "databank_import" then
                        ctx.layout
                            .set_clone_label(
                                import_button,
                                ""
                            )

                        ctx.layout
                            .hide_single_clone_image(
                                import_button
                            )
                    end
            end, import_button)

            ctx.layout
                .set_import_icon_color(
                    import_canvas,
                    {
                        R = 0.82,
                        G = 0.85,
                        B = 0.86,
                        A = 1.0,
                    }
                )

            ctx.layout
                .register_databank_hover_hooks()

            page_state.importInstalled = true
            page_state.importRow = row

            ctx.logging.log(
                "Databank compact IMPORT installed: layout="
                    .. tostring(layout_mode)
                    .. " iconWidth=64.0 gap=8.0"
            )

            return true
        end

        -- Enhanced Databank may already own the Create New action row. Adopt that
        -- row and append our compact action instead of wrapping Create New again.
        -- The two mods therefore produce the same flat layout regardless of load
        -- order: Create New | Import | Create Folder.
        local enhanced_row =
            ctx.layout
                .find_widget(
                    page,
                    "EnhancedDatabank_CreateFolderRow"
                )

        if enhanced_row == nil then
            enhanced_row =
                ctx.layout
                    .find_widget(
                        page,
                        "DatabankDiscoveryProbe_CreateFolderRow"
                    )
        end

        local enhanced_create_wrapper =
            ctx.layout
                .find_widget(
                    page,
                    "EnhancedDatabank_CreateNewWidth"
                )

        if enhanced_create_wrapper == nil then
            enhanced_create_wrapper =
                ctx.layout
                    .find_widget(
                        page,
                        "DatabankDiscoveryProbe_CreateNewWidth"
                    )
        end

        if enhanced_row ~= nil
            and enhanced_create_wrapper ~= nil
            and ctx.widget_helpers.panel_child_index(
                enhanced_row,
                enhanced_create_wrapper
            ) >= 0 then
            local create_width =
                ctx.layout
                    .widget_local_width(
                        enhanced_create_wrapper
                    )

            if create_width == nil
                or create_width < 120.0 then
                create_width = 628.0
            end

            local resized_width =
                math.max(
                    120.0,
                    create_width - 72.0
                )

            pcall(function()
                enhanced_create_wrapper:SetWidthOverride(
                    resized_width
                )
            end)

            local import_wrapper,
                _,
                wrapper_err =
                    ctx.layout
                        .make_width_wrapper(
                            page,
                            import_overlay,
                            "CharacterShare_ImportWidth",
                            64.0
                        )

            if import_wrapper == nil then
                ctx.logging.log(
                    "Databank IMPORT could not join Enhanced Databank row: "
                        .. tostring(wrapper_err)
                )
                return false
            end

            local import_slot = nil

            pcall(function()
                import_slot =
                    ctx.common.unwrap_hook_value(
                        enhanced_row:AddChild(
                            import_wrapper
                        )
                    )
            end)

            if import_slot == nil then
                ctx.logging.log(
                    "Databank IMPORT could not append to Enhanced Databank row."
                )
                return false
            end

            ctx.layout
                .configure_row_slot(
                    import_slot,
                    8.0
                )

            local moved,
                move_err =
                    ctx.widget_helpers.visually_move_appended_child_to_index(
                        enhanced_row,
                        import_wrapper,
                        1,
                        "horizontal"
                    )

            if not moved then
                ctx.logging.log(
                    "Databank IMPORT could not move ahead of Create Folder; keeping appended order: "
                        .. tostring(move_err)
                )
            end

            return finish_install(
                enhanced_row,
                "adopted-enhanced-row"
            )
        end

        local parent,
            create_index =
                ctx.widget_helpers.verified_anchor_parent(
                    create_new
                )

        if parent == nil then
            ctx.logging.log(
                "Databank IMPORT not ready: live Create New parent unavailable."
            )
            return false
        end

        -- Capture only Create New's own native slot. Keep every unrelated native
        -- sibling permanently attached while replacing this single slot.
        local create_layout =
            ctx.layout
                .capture_box_slot_layout(
                    create_new
                )

        local row,
            row_err =
                ctx.popup.construct_native_widget(
                    page,
                    "/Script/UMG.HorizontalBox",
                    "CharacterShare_CreateImportRow"
                )

        if row == nil then
            ctx.logging.log(
                "Databank IMPORT row creation failed: "
                    .. tostring(row_err)
            )
            return false
        end

        local original_width =
            ctx.layout
                .widget_local_width(
                    create_new
                )

        -- 700 is only a last-resort design-unit fallback. On the normal game UI,
        -- CachedGeometry should give us the actual allocated Create New width.
        if original_width == nil
            or original_width < 200.0 then
            original_width = 700.0
            ctx.logging.log(
                "Databank IMPORT width measurement unavailable; using 700 design-unit fallback."
            )
        end

        local gap = 8.0
        local import_width = 64.0
        local create_width =
            math.max(
                120.0,
                original_width
                    - gap
                    - import_width
            )

        ctx.logging.log(
            string.format(
                "Databank compact IMPORT row width: original=%.1f gap=%.1f create=%.1f import=%.1f",
                original_width,
                gap,
                create_width,
                import_width
            )
        )

        local create_wrapper = nil
        local import_wrapper = nil

        local function restore_create_new(reason)
            -- Roll back only the one native child we intentionally moved. Never
            -- clear/rebuild the containing panel: that is the first-entry bug this
            -- revision is removing.
            pcall(function()
                row:RemoveFromParent()
            end)

            pcall(function()
                row:ClearChildren()
            end)

            pcall(function()
                if create_wrapper ~= nil then
                    create_wrapper:ClearChildren()
                end
            end)

            pcall(function()
                if import_wrapper ~= nil then
                    import_wrapper:ClearChildren()
                end
            end)

            pcall(function()
                create_new:RemoveFromParent()
            end)

            local restored_slot,
                restore_err =
                    ctx.common.try_call(function()
                        return parent:AddChild(
                            create_new
                        )
                    end)

            restored_slot =
                ctx.common.unwrap_hook_value(
                    restored_slot
                )

            if restore_err == nil
                and restored_slot ~= nil then
                ctx.layout
                    .apply_box_slot_layout(
                        restored_slot,
                        create_layout
                    )

                local restored_visual,
                    visual_err =
                        ctx.widget_helpers.visually_move_appended_child_to_index(
                            parent,
                            create_new,
                            create_index,
                            "vertical"
                        )

                if not restored_visual then
                    ctx.logging.log(
                        "Databank IMPORT rollback could not visually restore Create New order: "
                            .. tostring(visual_err)
                    )
                end
            end

            ctx.logging.log(
                string.format(
                    "Databank IMPORT localized rollback after %s: createIndex=%d physicalIndex=%d",
                    tostring(reason),
                    create_index,
                    ctx.widget_helpers.panel_child_index(
                        parent,
                        create_new
                    )
                )
            )
        end

        local removed,
            remove_err =
                ctx.common.try_call(function()
                    return parent:RemoveChild(
                        create_new
                    )
                end)

        if remove_err ~= nil
            or not removed then
            ctx.logging.log(
                "Databank IMPORT could not safely detach Create New."
            )
            return false
        end

        local create_wrap_err = nil
        local import_wrap_err = nil
        local create_wrapper_slot = nil
        local import_wrapper_slot = nil

        create_wrapper,
            create_wrapper_slot,
            create_wrap_err =
                ctx.layout
                    .make_width_wrapper(
                        page,
                        create_new,
                        "CharacterShare_CreateNewWidth",
                        create_width
                    )

        import_wrapper,
            import_wrapper_slot,
            import_wrap_err =
                ctx.layout
                    .make_width_wrapper(
                        page,
                        import_overlay,
                        "CharacterShare_ImportWidth",
                        import_width
                    )

        if create_wrapper == nil
            or import_wrapper == nil then
            restore_create_new(
                "failed Create New / Import width wrappers: "
                    .. tostring(
                        create_wrap_err
                            or import_wrap_err
                    )
            )
            return false
        end

        local create_slot,
            create_add_err =
                ctx.common.try_call(function()
                    return row:AddChild(
                        create_wrapper
                    )
                end)

        local import_slot,
            import_add_err =
                ctx.common.try_call(function()
                    return row:AddChild(
                        import_wrapper
                    )
                end)

        create_slot =
            ctx.common.unwrap_hook_value(
                create_slot
            )

        import_slot =
            ctx.common.unwrap_hook_value(
                import_slot
            )

        if create_add_err ~= nil
            or import_add_err ~= nil
            or create_slot == nil
            or import_slot == nil then
            restore_create_new(
                "failed Create New / Import row composition"
            )
            return false
        end

        ctx.layout
            .configure_row_slot(
                create_slot,
                0.0
            )

        ctx.layout
            .configure_row_slot(
                import_slot,
                gap
            )

        -- InsertChildAt is a native UPanelWidget method but is not a reflected
        -- BlueprintCallable UFunction in UE 5.6. UE4SS therefore exposes it as a
        -- non-callable TrivialObject. Append the replacement row using AddChild,
        -- then rotate only the *render positions* of the affected siblings. The
        -- character-list widget never leaves its native parent.
        local row_slot,
            add_err =
                ctx.common.try_call(function()
                    return parent:AddChild(
                        row
                    )
                end)

        row_slot =
            ctx.common.unwrap_hook_value(
                row_slot
            )

        if add_err ~= nil
            or row_slot == nil then
            restore_create_new(
                "failed localized Create New / Import append: "
                    .. tostring(add_err)
            )
            return false
        end

        ctx.layout
            .apply_box_slot_layout(
                row_slot,
                create_layout
            )

        local moved,
            move_err =
                ctx.widget_helpers.visually_move_appended_child_to_index(
                    parent,
                    row,
                    create_index,
                    "vertical"
                )

        if not moved then
            restore_create_new(
                "failed visual Create New / Import ordering: "
                    .. tostring(move_err)
            )
            return false
        end

        ctx.logging.log(
            string.format(
                "Databank compact IMPORT row attached using localized append+visual rotation (original index=%d).",
                create_index
            )
        )

        return finish_install(
            row,
            "character-share-row"
        )
    end

    function ctx.databank_ui.install_share_button(
        page,
        page_state
    )
        local attached = ctx.layout.find_widget(page, "CharacterShare_ShareButton")
        if ctx.layout.uobject_is_valid(attached)
            and select(1, ctx.common.try_call(function() return attached:GetParent() end)) ~= nil then
            register_attached_databank_button(attached, "databank_share", "SHARE")
            ctx.layout.initialize_share_visual(attached)
            page_state.shareInstalled = true
            page_state.shareButton = attached
            page_state.shareSpacer = ctx.layout.find_widget(page, "CharacterShare_ShareSpacer")
            ctx.logging.log("Databank SHARE adopted from existing WidgetTree.")
            return true
        end
        page_state.shareInstalled = false

        local edit =
            select(
                1,
                ctx.widget_helpers.page_widget_property(
                    page,
                    "Button_Edit"
                )
            )

        if edit == nil then
            ctx.logging.log(
                "Databank SHARE not ready: native Edit button unavailable."
            )
            return false
        end

        local parent,
            edit_index =
                ctx.widget_helpers.verified_anchor_parent(
                    edit
                )

        if parent == nil then
            ctx.logging.log(
                "Databank SHARE not ready: live native action-row parent unavailable."
            )
            return false
        end

        local edit_layout =
            ctx.layout
                .capture_box_slot_layout(
                    edit
                )

        -- The native action row is not padded through the button slots. The
        -- v0.7.40 probe showed its real structure is:
        --   EDIT -> Spacer -> DELETE -> Spacer -> ACTIVATE
        -- SHARE is appended after ACTIVATE, so copy one of those existing Spacer
        -- widgets before appending SHARE rather than inventing a pixel margin or
        -- modifying any native button/slot.
        local native_spacer = nil
        local native_spacer_layout = nil
        local native_spacer_size = nil

        local next_child,
            next_child_err =
                ctx.common.try_call(function()
                    return ctx.common.unwrap_hook_value(
                        parent:GetChildAt(
                            edit_index + 1
                        )
                    )
                end)

        if next_child_err == nil
            and next_child ~= nil
            and ctx.popup.dialog_widget_class_name(
                next_child
            ):find(
                "Spacer",
                1,
                true
            ) ~= nil then
            native_spacer = next_child
        end

        if native_spacer == nil then
            local child_count = nil
            pcall(function()
                child_count =
                    tonumber(
                        parent:GetChildrenCount()
                    )
            end)

            if child_count ~= nil then
                for index = 0, child_count - 1 do
                    local candidate = nil
                    pcall(function()
                        candidate =
                            ctx.common.unwrap_hook_value(
                                parent:GetChildAt(
                                    index
                                )
                            )
                    end)

                    if candidate ~= nil
                        and ctx.popup.dialog_widget_class_name(
                            candidate
                        ):find(
                            "Spacer",
                            1,
                            true
                        ) ~= nil then
                        native_spacer = candidate
                        break
                    end
                end
            end
        end

        if native_spacer ~= nil then
            native_spacer_layout =
                ctx.layout
                    .capture_box_slot_layout(
                        native_spacer
                    )

            local size_value,
                size_err =
                    ctx.common.read_property(
                        native_spacer,
                        "Size"
                    )

            if size_err == nil then
                native_spacer_size =
                    ctx.common.unwrap_hook_value(
                        size_value
                    )
            end
        end

        local share_button,
            share_err =
                ctx.layout
                    .create_user_widget_like(
                        page,
                        edit,
                        "CharacterShare_ShareButton"
                    )

        if share_button == nil then
            ctx.logging.log(
                "Databank SHARE native-template creation failed: "
                    .. tostring(share_err)
            )
            return false
        end

        pcall(function()
            share_button:SetButtonInteractionEnabled(true)
            share_button:SetIsInteractionEnabled(true)
            share_button:SetIsFocusable(true)
            share_button:SetIsSelectable(false)
        end)

        -- InsertChildAt is not callable through UE4SS on this UE 5.6 build.
        -- Append a cloned native Spacer first, then SHARE. This preserves the
        -- game's existing action-row rhythm while leaving every native child in
        -- place.
        local share_spacer = nil

        if native_spacer ~= nil then
            local spacer,
                spacer_err =
                    ctx.popup.construct_native_widget(
                        page,
                        "/Script/UMG.Spacer",
                        "CharacterShare_ShareSpacer"
                    )

            if spacer ~= nil then
                if native_spacer_size ~= nil then
                    pcall(function()
                        spacer:SetSize(
                            native_spacer_size
                        )
                    end)
                end

                local spacer_slot,
                    spacer_add_err =
                        ctx.common.try_call(function()
                            return parent:AddChild(
                                spacer
                            )
                        end)

                spacer_slot =
                    ctx.common.unwrap_hook_value(
                        spacer_slot
                    )

                if spacer_add_err == nil
                    and spacer_slot ~= nil then
                    ctx.layout
                        .apply_box_slot_layout(
                            spacer_slot,
                            native_spacer_layout
                        )

                    share_spacer = spacer

                    local spacer_x = nil
                    pcall(function()
                        spacer_x =
                            tonumber(
                                native_spacer_size.X
                            )
                    end)

                    ctx.logging.log(
                        "Databank SHARE spacing cloned from native action-row Spacer"
                            .. (
                                spacer_x ~= nil
                                    and (" width=" .. tostring(spacer_x))
                                    or ""
                            )
                            .. "."
                    )
                else
                    pcall(function()
                        spacer:RemoveFromParent()
                    end)

                    ctx.logging.log(
                        "Databank SHARE native spacer append failed; continuing without extra spacing: "
                            .. tostring(spacer_add_err)
                    )
                end
            else
                ctx.logging.log(
                    "Databank SHARE native spacer clone failed; continuing without extra spacing: "
                        .. tostring(spacer_err)
                )
            end
        else
            ctx.logging.log(
                "Databank SHARE native spacer unavailable; continuing without extra spacing."
            )
        end

        local share_slot,
            add_err =
                ctx.common.try_call(function()
                    return parent:AddChild(
                        share_button
                    )
                end)

        share_slot =
            ctx.common.unwrap_hook_value(
                share_slot
            )

        if add_err ~= nil
            or share_slot == nil then
            pcall(function()
                share_button:RemoveFromParent()
            end)

            if share_spacer ~= nil then
                pcall(function()
                    share_spacer:RemoveFromParent()
                end)
            end

            ctx.logging.log(
                "Databank SHARE append failed; native action row left untouched: "
                    .. tostring(add_err)
            )

            return false
        end

        ctx.layout
            .apply_box_slot_layout(
                share_slot,
                edit_layout
            )

        register_attached_databank_button(
            share_button,
            "databank_share",
            "SHARE"
        )

        ctx.layout
            .initialize_share_visual(
                share_button
            )

        ctx.layout
            .polish_action_row(
                page,
                share_button
            )

        -- Keep SHARE at the native AddChild append position on the far right.
        -- This avoids reordering or translating any native action-row children.
        page_state.shareInstalled = true
        page_state.shareButton = share_button
        page_state.shareSpacer = share_spacer

        ctx.logging.log(
            string.format(
                "Databank SHARE appended at far right with native Default_Right orientation and native spacer rhythm (native Edit index=%d).",
                edit_index
            )
        )

        return true
    end

    local function install_databank_page_ui(page)
        if page == nil then
            return false
        end

        local page_identity =
            ctx.widget_helpers.databank_widget_identity(page)

        local page_state =
            ctx.state.databank_ui_state.installedPages[page_identity]

        if page_state == nil then
            page_state = {
                importInstalled = false,
                shareInstalled = false,
                shareButton = nil,
                importRow = nil,
            }

            ctx.state.databank_ui_state.installedPages[page_identity] =
                page_state
        end

        local import_ok =
            ctx.databank_ui.install_import_button(
                page,
                page_state
            )

        local share_ok =
            ctx.databank_ui.install_share_button(
                page,
                page_state
            )

        ctx.logging.log(
            string.format(
                "Databank live page integration: IMPORT=%s SHARE=%s page=%s",
                tostring(import_ok),
                tostring(share_ok),
                page_identity
            )
        )

        return import_ok and share_ok
    end

    local function databank_pages(master)
        local pages = {}

        if master == nil then
            return pages
        end

        for _, property_name in ipairs({
            "OtherCharacterList",
            "AstromechCharacterList",
        }) do
            local page =
                select(
                    1,
                    ctx.widget_helpers.page_widget_property(
                        master,
                        property_name
                    )
                )

            if page ~= nil then
                table.insert(
                    pages,
                    page
                )
            end
        end

        return pages
    end

    function ctx.databank_ui.install_databank_ui_for_active_master(
        master,
        generation
    )
        if generation ~= ctx.state.databank_ui_state.generation then
            return
        end

        if ctx.state.databank_ui_state.activeMaster ~= master then
            return
        end

        local pages =
            databank_pages(master)

        ctx.logging.log(
            string.format(
                "Character Databank entered: %d live character-list page(s) exposed.",
                #pages
            )
        )

        local complete = true

        for _, page in ipairs(pages) do
            if not install_databank_page_ui(page) then
                complete = false
            end
        end

        if complete and #pages > 0 then
            ctx.state.databank_session_active = true

            ctx.logging.log(
                "Character Databank UI integration complete; controls are persistent for this runtime Databank master."
            )
            return
        end

        -- One guarded retry only, scoped to this exact activation generation.
        ctx.layout.run_group_after("databank_entry_install", 100, function()
            if generation ~= ctx.state.databank_ui_state.generation then
                return
            end

                if generation ~= ctx.state.databank_ui_state.generation
                    or ctx.state.databank_ui_state.activeMaster ~= master then
                    return
                end

                local retry_pages =
                    databank_pages(master)

                local retry_complete = true

                for _, page in ipairs(retry_pages) do
                    if not install_databank_page_ui(page) then
                        retry_complete = false
                    end
                end

                ctx.logging.log(
                    string.format(
                        "Character Databank guarded UI retry complete=%s.",
                        tostring(
                            retry_complete
                                and #retry_pages > 0
                        )
                    )
                )
        end, master)
    end
end
