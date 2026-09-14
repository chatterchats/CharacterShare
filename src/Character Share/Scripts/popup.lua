-- Character Share: popup.
-- Initialized once per mod instance; shared references use explicit ctx fields.
-- Context: common, dependencies, layout, logging, popup, runtime, state.
return function(ctx)
    function ctx.popup.load_class(class_path)
        local class_object, class_err = ctx.common.try_call(function()
            return StaticFindObject(class_path)
        end)

        if class_err == nil and class_object ~= nil then
            return class_object, nil
        end

        local package_path = class_path:match("^([^%.]+)")
        if package_path ~= nil then
            pcall(function()
                LoadAsset(package_path)
            end)

            class_object, class_err = ctx.common.try_call(function()
                return StaticFindObject(class_path)
            end)
        end

        if class_err ~= nil or class_object == nil then
            return nil, "class unavailable: " .. class_path
        end

        return class_object, nil
    end

    function ctx.popup.current_databank_host()
        return ctx.common.find_first("WBP_CharacterBank_Master_C")
    end

    function ctx.popup.create_user_widget(world_context, class_path)
        if world_context == nil then
            return nil, "world context unavailable"
        end

        local widget_class, class_err = ctx.popup.load_class(class_path)
        if class_err ~= nil or widget_class == nil then
            return nil, class_err
        end

        local library_class, library_class_err =
            ctx.popup.load_class("/Script/UMG.WidgetBlueprintLibrary")

        if library_class_err ~= nil or library_class == nil then
            return nil, "WidgetBlueprintLibrary unavailable"
        end

        local library, library_err = ctx.common.try_call(function()
            return library_class:GetCDO()
        end)

        if library_err ~= nil or library == nil then
            return nil, "WidgetBlueprintLibrary CDO unavailable"
        end

        local owning_player = nil
        pcall(function()
            owning_player = world_context:GetOwningPlayer()
        end)

        local widget, create_err = ctx.common.try_call(function()
            return library:Create(world_context, widget_class, owning_player)
        end)

        if create_err ~= nil or widget == nil then
            return nil, "could not create " .. class_path .. ": " .. tostring(create_err)
        end

        return widget, nil
    end

    function ctx.popup.construct_native_widget(owner_widget, class_path, object_name)
        if owner_widget == nil then
            return nil, "owner widget unavailable"
        end

        local widget_tree, tree_err = ctx.common.read_property(owner_widget, "WidgetTree")
        if tree_err ~= nil or widget_tree == nil then
            return nil, "WidgetTree unavailable: " .. tostring(tree_err)
        end

        local widget_class, class_err = ctx.popup.load_class(class_path)
        if class_err ~= nil or widget_class == nil then
            return nil, class_err
        end

        local widget, construct_err = ctx.common.try_call(function()
            return StaticConstructObject(
                widget_class,
                widget_tree,
                FName(object_name),
                0,
                0,
                false,
                false,
                nil
            )
        end)

        if construct_err ~= nil or widget == nil then
            return nil,
                "StaticConstructObject failed for "
                .. class_path
                .. ": "
                .. tostring(construct_err)
        end

        return widget, nil
    end

    function ctx.popup.add_vertical_child(parent, child, padding)
        if parent == nil or child == nil then
            return nil
        end

        local slot, slot_err = ctx.common.try_call(function()
            return parent:AddChildToVerticalBox(child)
        end)

        if slot_err ~= nil or slot == nil then
            return nil
        end

        if padding ~= nil then
            pcall(function()
                slot:SetPadding(padding)
            end)
        end

        return slot
    end

    local function add_horizontal_child(parent, child, padding)
        if parent == nil or child == nil then
            return nil
        end

        local slot, slot_err = ctx.common.try_call(function()
            return parent:AddChildToHorizontalBox(child)
        end)

        if slot_err ~= nil or slot == nil then
            return nil
        end

        if padding ~= nil then
            pcall(function()
                slot:SetPadding(padding)
            end)
        end

        return slot
    end

    function ctx.popup.create_game_entry(
        popup_widget,
        object_prefix,
        initial_text,
        hint_text,
        read_only
    )
        local entry, entry_err =
            ctx.popup.create_user_widget(popup_widget, ctx.dependencies.UI.ENTRY_TEXT_CLASS_PATH)

        if entry_err ~= nil or entry == nil then
            return nil, nil, entry_err
        end

        local initial_value = tostring(initial_text or "")

        pcall(function()
            entry:Rename(FName(object_prefix), popup_widget)
            entry.MaxCharacterCountSingleLine = 65536
            entry.MaxCharacterCountMultiline = 65536
            entry:SetIsMultiline(false)
            entry:SetTextboxHeight(42.0)
            entry:UpdateCharacterLimitsSingleLine()

            -- Keep Share editable in the visual copy so the game's EntryText widget
            -- permits normal focus/selection. Edits are never written back.
            entry:SetText(FText(initial_value), not read_only)
        end)

        local editable_text, editable_err =
            ctx.common.read_property(entry, "EditableText")

        if editable_err ~= nil or editable_text == nil then
            return nil, nil, "EntryText.EditableText unavailable"
        end

        local function apply_entry_value()
            pcall(function()
                -- The EntryText Blueprint resets its normal character limit during
                -- Construct/PreConstruct. That default is 10 characters, which is
                -- why the import box stopped exactly after "ZC1".
                --
                -- Reapply the large Character Share limit *after* construction and
                -- force the Blueprint to rebuild its single-line limit/counter.
                entry.MaxCharacterCountSingleLine = 65536
                entry.MaxCharacterCountMultiline = 65536
                entry:SetIsMultiline(false)
                entry:UpdateCharacterLimitsSingleLine()

                -- Set both the wrapper state and the actual Slate-backed text.
                -- The latter is what prevents the Blueprint's "%editable"
                -- design-time placeholder from surviving Construct/PreConstruct.
                entry:SetText(FText(initial_value), not read_only)
                editable_text:SetText(FText(initial_value))
                editable_text:SetHintText(FText(hint_text or ""))
                editable_text:SetMinimumDesiredWidth(540.0)
                editable_text:SetIsReadOnly(read_only)
                editable_text.SelectAllTextWhenFocused = true
                editable_text.SelectAllTextOnCommit = false
                editable_text.ClearKeyboardFocusOnCommit = false
                editable_text.AllowContextMenu = true
            end)
        end

        apply_entry_value()

        -- create_game_entry() runs before the widget is inserted into the dialog's
        -- NamedSlot. Reapply after that insertion has caused BP Construct to run.
        ctx.layout.run_group_after("popup_retirement", 1, function()
            apply_entry_value()
        end, entry, editable_text)

        return entry, editable_text, nil
    end

    function ctx.popup.make_rich_label(popup_widget, text, object_name)
        local label, label_err = ctx.popup.construct_native_widget(
            popup_widget,
            "/Script/BitReactorGame.BitReactorRichTextBlock",
            object_name
        )

        if label_err ~= nil or label == nil then
            return nil, label_err
        end

        pcall(function()
            label:SetTextEx(FText(text))
        end)

        return label, nil
    end

    local function get_messaging_subsystem(world_context)
        local subsystem_library_class, library_err =
            ctx.popup.load_class("/Script/Engine.SubsystemBlueprintLibrary")

        if library_err ~= nil or subsystem_library_class == nil then
            return nil, library_err
        end

        local subsystem_library, cdo_err = ctx.common.try_call(function()
            return subsystem_library_class:GetCDO()
        end)

        if cdo_err ~= nil or subsystem_library == nil then
            return nil, "SubsystemBlueprintLibrary CDO unavailable"
        end

        local messaging_class, messaging_class_err =
            ctx.popup.load_class("/Script/BitReactorGame.BitReactorMessagingSubsystem")

        if messaging_class_err ~= nil or messaging_class == nil then
            return nil, messaging_class_err
        end

        local subsystem, subsystem_err = ctx.common.try_call(function()
            return subsystem_library:GetLocalPlayerSubsystem(
                world_context,
                messaging_class
            )
        end)

        if subsystem_err ~= nil or subsystem == nil then
            return nil, "BitReactorMessagingSubsystem unavailable"
        end

        return subsystem, nil
    end

    local function make_dialog_action(result_tag, label)
        return {
            Result = {
                TagName = FName(result_tag),
            },
            OptionalDisplayText = FText(label),
            OptionalInputAction = nil,
        }
    end

    local function clear_named_slot_content(widget, property_name)
        if widget == nil then
            return
        end

        local named_slot, slot_err = ctx.common.read_property(widget, property_name)
        if slot_err ~= nil or named_slot == nil then
            return
        end

        pcall(function()
            named_slot:ClearChildren()
        end)

        pcall(function()
            named_slot:SetContent(nil)
        end)
    end

    function ctx.popup.detach_character_share_content(widget)
        if widget == nil then
            return
        end

        -- WBP_GenericPopupMessage_Small is reused by Zero Company. Any child we
        -- leave in AboveText/Belowtext will appear in the next unrelated game
        -- prompt. Always return those slots to an empty state.
        clear_named_slot_content(widget, "AboveText")
        clear_named_slot_content(widget, "Belowtext")

        -- Character Share 0.6.9 hides the descriptor-generated action row and puts
        -- its own Character Databank TopNav buttons in Belowtext instead. Restore
        -- the native row before the pooled popup is returned to the game.
        local entry_box =
            ctx.state.popup_state.nativeActionEntryBox

        if entry_box == nil then
            entry_box =
                ctx.common.unwrap_hook_value(
                    select(
                        1,
                        ctx.common.read_property(
                            widget,
                            "EntryBox_Buttons"
                        )
                    )
                )
        end

        if entry_box ~= nil then
            pcall(function()
                entry_box:SetVisibility(0)
            end)
        end
    end

    function ctx.popup.reset_popup_state()
        ctx.state.popup_state.widget = nil
        ctx.state.popup_state.mode = nil
        ctx.state.popup_state.textBox = nil
        ctx.state.popup_state.renameFirstBox = nil
        ctx.state.popup_state.renameLastBox = nil
        ctx.state.popup_state.context = nil
        ctx.state.popup_state.resultActions = {}
        ctx.state.popup_state.customActions = {}
        ctx.state.popup_state.nativeActionEntryBox = nil
        ctx.state.popup_state.suppressResult = false
        ctx.state.popup_state.capturedImportCode = nil
        ctx.state.popup_state.capturedRenameFirst = nil
        ctx.state.popup_state.capturedRenameLast = nil
        ctx.state.popup_state.injectedAbove = nil
        ctx.state.popup_state.injectedBelow = nil
    end

    local function close_native_popup()
        ctx.layout.cancel_action_group(
            "popup_retirement",
            "popup closed or replaced"
        )

        if ctx.state.popup_state.widget == nil then
            return
        end

        local widget = ctx.state.popup_state.widget
        ctx.state.popup_state.suppressResult = true

        ctx.popup.detach_character_share_content(widget)

        local _, close_err = ctx.common.try_call(function()
            widget:OnCloseWindow()
        end)

        if close_err ~= nil then
            pcall(function()
                widget:RemoveFromParent()
            end)
        end

        ctx.popup.reset_popup_state()
    end

    ctx.runtime.ui_cleanup = function()
        local popup = ctx.state.popup_state.widget
        ctx.state.popup_state.suppressResult = true
        if ctx.layout.uobject_is_valid(popup) then
            ctx.popup.detach_character_share_content(popup)
            pcall(function() popup:OnCloseWindow() end)
        end
        ctx.popup.reset_popup_state()
    end

    function ctx.popup.finish_native_popup_hide(widget)
        -- BP_OnHideDialog gives us the result, but does not prove the activatable
        -- widget has actually left CommonUI's stack yet.
        --
        -- Older builds forced Visibility=Collapsed here. That hid the popup while
        -- leaving a possible live stack entry behind. When the native Edit screen
        -- later closed, CommonUI could walk back through those hidden Character
        -- Share dialogs, producing the Import/Duplicate screen flashes.
        ctx.popup.detach_character_share_content(widget)
        ctx.popup.reset_popup_state()

        ctx.logging.log(
            "Native dialog result captured; awaiting native stack retirement: "
                .. ctx.common.popup_widget_identity(widget)
        )
    end

    local function native_popup_activation_state(widget)
        if widget == nil then
            return nil
        end

        local active, active_err = ctx.common.try_call(function()
            return widget:IsActivated()
        end)

        if active_err ~= nil then
            return nil
        end

        return active == true
    end

    function ctx.popup.retire_native_popup(widget, on_retired)
        if widget == nil then
            if on_retired ~= nil then
                on_retired()
            end
            return
        end

        ctx.layout.cancel_action_group(
            "popup_retirement",
            "new popup retirement started"
        )

        -- OnCloseWindow is the popup's own close path and is already the normal
        -- programmatic-close method used by Character Share. Run it after the
        -- BP_OnHideDialog callback returns so we do not re-enter the result handler.
        ctx.layout.run_group_after("popup_retirement", 1, function()
                local _, close_err = ctx.common.try_call(function()
                    widget:OnCloseWindow()
                end)

                if close_err ~= nil then
                    ctx.logging.log(
                        "Native dialog OnCloseWindow retirement warning: "
                            .. tostring(close_err)
                    )
                end

                local attempts = 0

                local function wait_for_retirement()
                    attempts = attempts + 1

                        local active =
                            native_popup_activation_state(widget)

                        if active == false then
                            ctx.logging.log(
                                "Native dialog retired from CommonUI: "
                                    .. ctx.common.popup_widget_identity(widget)
                            )

                            if on_retired ~= nil then
                                on_retired()
                            end
                            return
                        end

                        -- Some cooked popup variants may not expose IsActivated().
                        -- In that case, allow enough time for the native close/outro
                        -- to complete before chaining another dialog.
                        if active == nil and attempts >= 7 then
                            ctx.logging.log(
                                "Native dialog retirement state unavailable; continuing after native close window."
                            )

                            if on_retired ~= nil then
                                on_retired()
                            end
                            return
                        end

                        if attempts < 10 then
                            ctx.layout.run_group_after(
                                "popup_retirement",
                                50,
                                wait_for_retirement,
                                widget
                            )
                            return
                        end

                        -- Last-resort native deactivation. Do not RemoveFromParent:
                        -- that previously desynchronized the CommonUI stack.
                        pcall(function()
                            widget:DeactivateWidget()
                        end)

                        ctx.layout.run_group_after("popup_retirement", 100, function()
                                ctx.logging.log(
                                    "Native dialog retirement forced through DeactivateWidget: "
                                        .. ctx.common.popup_widget_identity(widget)
                                )

                                if on_retired ~= nil then
                                    on_retired()
                                end
                        end, widget)
                end

                ctx.layout.run_group_after(
                    "popup_retirement",
                    50,
                    wait_for_retirement,
                    widget
                )
        end, widget)
    end

    function ctx.popup.safe_remove_popup()
        close_native_popup()
    end

    function ctx.popup.popup_is_open(mode)
        return ctx.state.popup_state.widget ~= nil
            and (mode == nil or ctx.state.popup_state.mode == mode)
    end

    function ctx.popup.read_text_box_value(box)
        if box == nil then
            return ""
        end

        local value, value_err = ctx.common.try_call(function()
            return box:GetText()
        end)

        if value_err ~= nil or value == nil then
            return ""
        end

        return ctx.common.text_value(value)
    end

    function ctx.popup.dialog_widget_class_name(widget)
        if widget == nil then
            return ""
        end

        local class_object, class_err = ctx.common.try_call(function()
            return widget:GetClass()
        end)

        if class_err ~= nil or class_object == nil then
            return ""
        end

        local full_name, full_name_err = ctx.common.try_call(function()
            return class_object:GetFullName()
        end)

        if full_name_err ~= nil or full_name == nil then
            return ""
        end

        return tostring(full_name)
    end

    local function set_popup_topnav_button_text(
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

        pcall(function()
            button:SetText(FText(label))
        end)

        pcall(function()
            button:UpdateButtonText(FText(label))
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

    local function install_popup_topnav_actions(
        popup,
        actions
    )
        if popup == nil then
            return false, "popup unavailable"
        end

        local below_value, below_err =
            ctx.common.read_property(
                popup,
                "Belowtext"
            )

        local below =
            ctx.common.unwrap_hook_value(below_value)

        if below_err ~= nil or below == nil then
            return false, "GenericPopupMessage.Belowtext unavailable"
        end

        local existing_content = nil

        pcall(function()
            existing_content =
                ctx.common.unwrap_hook_value(
                    below:GetContent()
                )
        end)

        local body_panel, body_err =
            ctx.popup.construct_native_widget(
                popup,
                "/Script/UMG.VerticalBox",
                "CharacterShare_PopupBodyPanel"
            )

        if body_err ~= nil or body_panel == nil then
            return false, body_err
        end

        local action_row, row_err =
            ctx.popup.construct_native_widget(
                popup,
                "/Script/UMG.HorizontalBox",
                "CharacterShare_PopupActionRow"
            )

        if row_err ~= nil or action_row == nil then
            return false, row_err
        end

        -- Detach the content builder's text-entry/rename panel from the NamedSlot
        -- and place it above our action row.
        pcall(function()
            below:SetContent(nil)
        end)

        if existing_content ~= nil then
            local content_slot =
                ctx.popup.add_vertical_child(
                    body_panel,
                    existing_content,
                    {
                        Left = 0.0,
                        Top = 0.0,
                        Right = 0.0,
                        Bottom = 12.0,
                    }
                )

            if content_slot == nil then
                return false, "could not move popup content into body panel"
            end
        end

        local action_slot =
            ctx.popup.add_vertical_child(
                body_panel,
                action_row,
                {
                    Left = 0.0,
                    Top = 4.0,
                    Right = 0.0,
                    Bottom = 0.0,
                }
            )

        if action_slot == nil then
            return false, "could not add popup action row"
        end

        local _, body_set_err = ctx.common.try_call(function()
            below:SetContent(body_panel)
        end)

        if body_set_err ~= nil then
            return false, body_set_err
        end

        ctx.state.popup_state.injectedBelow =
            body_panel

        ctx.state.popup_state.customActions = {}

        local count =
            #(actions or {})

        for index, action in ipairs(actions or {}) do
            local button, button_err =
                ctx.popup.create_user_widget(
                    popup,
                    ctx.dependencies.UI.DATABANK_TOPNAV_BUTTON_CLASS_PATH
                )

            if button_err ~= nil or button == nil then
                return false,
                    "could not create popup TopNav action button: "
                    .. tostring(button_err)
            end

            pcall(function()
                button:SetButtonInteractionEnabled(true)
                button:SetIsInteractionEnabled(true)
                button:SetIsFocusable(true)
                button:SetIsSelectable(false)
            end)

            set_popup_topnav_button_text(
                button,
                action.label
            )

            local button_identity =
                ctx.common.popup_widget_identity(button)

            ctx.state.popup_state.customActions[button_identity] =
                action.id

            local padding = {
                Left = index == 1 and 0.0 or 4.0,
                Top = 0.0,
                Right = index == count and 0.0 or 4.0,
                Bottom = 0.0,
            }

            local slot =
                add_horizontal_child(
                    action_row,
                    button,
                    padding
                )

            if slot == nil then
                return false,
                    "could not add popup TopNav action button to row"
            end

            pcall(function()
                slot:SetSize({
                    Value = 1.0,
                    SizeRule = 1,
                })
            end)

            ctx.logging.log(
                string.format(
                    "Popup TopNav action[%d/%d]: %s -> %s",
                    index,
                    count,
                    tostring(action.label),
                    tostring(action.id)
                )
            )
        end

        local entry_box =
            ctx.common.unwrap_hook_value(
                select(
                    1,
                    ctx.common.read_property(
                        popup,
                        "EntryBox_Buttons"
                    )
                )
            )

        if entry_box ~= nil then
            ctx.state.popup_state.nativeActionEntryBox =
                entry_box

            pcall(function()
                entry_box:SetVisibility(2)
            end)
        end

        -- Blueprint Construct can restore its design-time text. Re-apply labels on
        -- the next tick by walking only our newly-created action row children.
        ctx.layout.run_group_after("popup_retirement", 1, function()
            if ctx.state.popup_state.widget ~= popup then
                return
            end

                local child_count = 0

                pcall(function()
                    child_count =
                        action_row:GetChildrenCount()
                end)

                for child_index = 0, child_count - 1 do
                    local child = nil

                    pcall(function()
                        child =
                            ctx.common.unwrap_hook_value(
                                action_row:GetChildAt(
                                    child_index
                                )
                            )
                    end)

                    if child ~= nil then
                        local action =
                            actions[child_index + 1]

                        if action ~= nil then
                            set_popup_topnav_button_text(
                                child,
                                action.label
                            )
                        end
                    end
                end
        end, popup, action_row)

        return true, nil
    end

    local function collect_native_dialog_action_buttons(popup)
        local buttons = {}

        if popup == nil then
            return buttons, nil
        end

        local entry_box, entry_box_err =
            ctx.common.read_property(popup, "EntryBox_Buttons")

        if entry_box_err ~= nil or entry_box == nil then
            return buttons,
                "BitReactorMessageBox.EntryBox_Buttons unavailable"
        end

        -- Tighten the spacing at the actual native action container rather than
        -- trying to alter unrelated UMG slots around the popup.
        pcall(function()
            entry_box:SetEntrySpacing({
                X = 8.0,
                Y = 0.0,
            })

            -- FSlateChildSize / ESlateSizeRule:
            --   0 = Automatic
            --   1 = Fill
            --
            -- GenericPopupMessage's action container normally fills the available
            -- width. Character Share wants compact buttons using their real desired
            -- widths instead.
            entry_box.EntrySizeRule = {
                Value = 1.0,
                SizeRule = 0,
            }
        end)

        local entries, entries_err = ctx.common.try_call(function()
            return entry_box:GetAllEntries()
        end)

        if entries_err ~= nil or entries == nil then
            return buttons,
                "EntryBox_Buttons:GetAllEntries failed: "
                .. tostring(entries_err)
        end

        ctx.common.for_each_array(entries, function(_, widget_value)
            local widget = ctx.common.unwrap_hook_value(widget_value)

            if widget ~= nil then
                table.insert(buttons, widget)

                ctx.logging.log(
                    "Native dialog action entry: "
                        .. ctx.common.popup_widget_identity(widget)
                        .. " / class="
                        .. ctx.popup.dialog_widget_class_name(widget)
                )
            end
        end)

        return buttons, nil
    end

    local function native_button_orientation(index, count)
        -- E_UI_ButtonOrientation:
        --   0 = Left
        --   1 = Center
        --   2 = Right
        if count <= 1 then
            return 1
        elseif count == 2 then
            return index == 1 and 0 or 2
        end

        if index == 1 then
            return 0
        elseif index == count then
            return 2
        end

        return 1
    end

    local function active_bound_button_visual_name(button)
        if button == nil then
            return ""
        end

        local switcher_value, switcher_err =
            ctx.common.read_property(button, "ButtonSwitcher")

        local switcher =
            ctx.common.unwrap_hook_value(switcher_value)

        if switcher_err ~= nil or switcher == nil then
            return ""
        end

        local active, active_err = ctx.common.try_call(function()
            return ctx.common.unwrap_hook_value(
                switcher:GetActiveWidget()
            )
        end)

        if active_err ~= nil or active == nil then
            return ""
        end

        return ctx.common.popup_widget_identity(active)
    end

    local function desired_button_visual_property(index, count)
        -- Use Zero Company's native grey Long family. We resize its real
        -- WidgetTree.SizeBox_0 instead of recoloring Small buttons.
        if count <= 1 then
            return "WBP_Bruno_Button_Long_Center", "Long_Center"
        elseif count == 2 then
            if index == 1 then
                return "WBP_Bruno_Button_Long_Left", "Long_Left"
            end

            return "WBP_Bruno_Button_Long_Right", "Long_Right"
        end

        if index == 1 then
            return "WBP_Bruno_Button_Long_Left", "Long_Left"
        elseif index == count then
            return "WBP_Bruno_Button_Long_Right", "Long_Right"
        end

        return "WBP_Bruno_Button_Long_Center", "Long_Center"
    end

    local function compact_native_action_width(count)
        if count <= 1 then
            return 128.0
        elseif count == 2 then
            return 138.0
        end

        -- OVERWRITE needs a little more room.
        return 150.0
    end

    local function set_button_entry_slot_auto(button)
        if button == nil then
            return false
        end

        local slot_value, slot_err =
            ctx.common.read_property(button, "Slot")

        local slot =
            ctx.common.unwrap_hook_value(slot_value)

        if slot_err ~= nil or slot == nil then
            return false
        end

        local _, size_err = ctx.common.try_call(function()
            slot:SetSize({
                Value = 1.0,
                SizeRule = 0,
            })
        end)

        pcall(function()
            slot:SetPadding({
                Left = 4.0,
                Top = 0.0,
                Right = 4.0,
                Bottom = 0.0,
            })
        end)

        return size_err == nil
    end

    local function find_named_widget_in_tree(user_widget, widget_name)
        if user_widget == nil then
            return nil
        end

        local widget_tree_value, tree_err =
            ctx.common.read_property(user_widget, "WidgetTree")

        local widget_tree =
            ctx.common.unwrap_hook_value(widget_tree_value)

        if tree_err ~= nil or widget_tree == nil then
            return nil
        end

        local widget, find_err = ctx.common.try_call(function()
            return ctx.common.unwrap_hook_value(
                widget_tree:FindWidget(FName(widget_name))
            )
        end)

        if find_err ~= nil then
            return nil
        end

        return widget
    end

    local function resize_long_button_layout(button, target, count)
        local width =
            compact_native_action_width(count)

        -- The object dump confirms every Long visual owns WidgetTree.SizeBox_0.
        -- FindWidget is reliable here even though GetAllWidgets() did not expose it
        -- through the cooked Blueprint wrapper.
        local size_box =
            find_named_widget_in_tree(
                target,
                "SizeBox_0"
            )

        if size_box == nil then
            ctx.logging.log(
                "Native dialog Long button resize: SizeBox_0 not found."
            )
            return false
        end

        local _, size_err = ctx.common.try_call(function()
            size_box:SetWidthOverride(width)
            size_box:SetMinDesiredWidth(width)
            size_box:SetMaxDesiredWidth(width)
        end)

        if size_err ~= nil then
            ctx.logging.log(
                "Native dialog Long button resize failed: "
                    .. tostring(size_err)
            )
            return false
        end

        pcall(function()
            button:SetMinDimensions(width, 38)
            button:SetMaxDimensions(width, 38)
        end)

        local slot_auto =
            set_button_entry_slot_auto(button)

        -- Remove any render transforms left from prior prototypes.
        pcall(function()
            target:SetRenderScale({
                X = 1.0,
                Y = 1.0,
            })
            target:SetRenderTranslation({
                X = 0.0,
                Y = 0.0,
            })
        end)

        ctx.logging.log(
            string.format(
                "Native dialog grey Long button resized: width=%.0f size_box=%s slot_auto=%s",
                width,
                ctx.common.popup_widget_identity(size_box),
                tostring(slot_auto)
            )
        )

        return true
    end

    local function configure_bound_action_button_visual(
        button,
        index,
        count
    )
        if button == nil then
            return false
        end

        local property_name, visual_name =
            desired_button_visual_property(index, count)

        local target =
            ctx.common.unwrap_hook_value(
                select(
                    1,
                    ctx.common.read_property(
                        button,
                        property_name
                    )
                )
            )

        if target == nil then
            ctx.logging.log(
                "Native dialog button visual unavailable: "
                    .. tostring(property_name)
            )
            return false
        end

        local switcher_value, switcher_err =
            ctx.common.read_property(button, "ButtonSwitcher")

        local switcher =
            ctx.common.unwrap_hook_value(switcher_value)

        if switcher_err ~= nil or switcher == nil then
            return false
        end

        local label =
            select(1, ctx.common.read_property(button, "LastUpdatedText"))

        local _, switch_err = ctx.common.try_call(function()
            -- Do not call UpdateButtonStyle/SelectButtonType here.
            -- Those Blueprint paths can select InvalidType when reflected enum
            -- values are marshalled through UE4SS.
            button.SelectedButton = target
            switcher:SetActiveWidget(target)
        end)

        if switch_err ~= nil then
            ctx.logging.log(
                "Native dialog button visual switch failed: "
                    .. tostring(switch_err)
            )
            return false
        end

        -- Configure only the concrete visual child with known-valid values.
        pcall(function()
            target.ShowAction = false
            target:UpdateType(0)
            target:UpdatePromptHidden(true, false)
            target:SetIsButtonHold(false)

            if label ~= nil then
                target:UpdateText(label)
            end

            target:NormalState()
        end)

        -- Keep the native Long visual's own grey material/state. Do not call
        -- UpdateColors or touch WBP_9Slice.TextureTint: those material paths can be
        -- shared with unrelated Zero Company dialogs.
        local resized =
            resize_long_button_layout(
                button,
                target,
                count
            )

        pcall(function()
            target:UpdateType(0)
            target:UpdatePromptHidden(true, false)
            target:SetIsButtonHold(false)
            if label ~= nil then
                target:UpdateText(label)
            end
            target:NormalState()
            button:SetIsSelected(false, false)
            button:SetIsSelectable(false)
            button:SetShouldSelectUponReceivingFocus(false)
            button:UpdateAnimState()
        end)

        ctx.logging.log(
            string.format(
                "Native dialog button[%d/%d] forced to native %s grey; resized=%s active=%s",
                index,
                count,
                visual_name,
                tostring(resized),
                active_bound_button_visual_name(button)
            )
        )

        return true
    end

    local function polish_native_dialog_buttons(popup, action_count)
        if popup == nil then
            return false
        end

        pcall(function()
            if (action_count or 0) >= 3 then
                popup:SetWidth(530.0)
            elseif (action_count or 0) == 2 then
                popup:SetWidth(500.0)
            else
                popup:SetWidth(480.0)
            end

            popup:UpdateSize()
        end)

        local buttons, buttons_err =
            collect_native_dialog_action_buttons(popup)

        if #buttons == 0 then
            ctx.logging.log(
                "Native dialog button polish: "
                    .. tostring(buttons_err or "no action entries yet")
            )
            return false
        end

        local count = math.min(#buttons, action_count or #buttons)

        if action_count ~= nil and count < action_count then
            ctx.logging.log(
                string.format(
                    "Native dialog button polish: only %d/%d native action entries exist yet.",
                    count,
                    action_count
                )
            )
            return false
        end

        ctx.logging.log(
            string.format(
                "Native dialog button polish: configuring %d action button(s) with concrete Small visuals.",
                count
            )
        )

        local all_ok = true

        for index = 1, count do
            local ok =
                configure_bound_action_button_visual(
                    buttons[index],
                    index,
                    count
                )

            if not ok then
                all_ok = false
            end
        end

        return all_ok
    end

    local function schedule_native_dialog_button_polish(
        popup,
        action_count,
        attempt
    )
        attempt = attempt or 1

        ctx.layout.run_group_after(
            "popup_retirement",
            attempt == 1 and 1 or 35,
            function()
                    if ctx.state.popup_state.widget ~= popup then
                        return
                    end

                    local done =
                        polish_native_dialog_buttons(
                            popup,
                            action_count
                        )

                    if not done and attempt < 8 then
                        schedule_native_dialog_button_polish(
                            popup,
                            action_count,
                            attempt + 1
                        )
                    end
            end,
            popup
        )
    end

    function ctx.popup.show_native_dialog(
        mode,
        title,
        body,
        actions,
        content_builder,
        context
    )
        close_native_popup()

        local host = ctx.popup.current_databank_host()
        if host == nil then
            ctx.logging.log("DIALOG FAILED: Character Databank is not open.")
            return nil
        end

        local descriptor_class, descriptor_class_err =
            ctx.popup.load_class("/Script/BitReactorGame.BitReactorGameDialogDescriptor")

        if descriptor_class_err ~= nil or descriptor_class == nil then
            ctx.logging.log("DIALOG FAILED: " .. tostring(descriptor_class_err))
            return nil
        end

        local descriptor_cdo, descriptor_cdo_err = ctx.common.try_call(function()
            return descriptor_class:GetCDO()
        end)

        if descriptor_cdo_err ~= nil or descriptor_cdo == nil then
            ctx.logging.log("DIALOG FAILED: descriptor CDO unavailable.")
            return nil
        end

        local message_class, message_class_err =
            ctx.popup.load_class(ctx.dependencies.UI.GENERIC_POPUP_CLASS_PATH)

        if message_class_err ~= nil or message_class == nil then
            ctx.logging.log(
                "Compact GenericPopupMessage unavailable; using normal dialog: "
                .. tostring(message_class_err)
            )

            message_class, message_class_err =
                ctx.popup.load_class(ctx.dependencies.UI.GENERIC_POPUP_FALLBACK_CLASS_PATH)
        end

        if message_class_err ~= nil or message_class == nil then
            ctx.logging.log("DIALOG FAILED: " .. tostring(message_class_err))
            return nil
        end

        -- Cold-start note:
        -- BP_OnHideDialog may not be registered with UE4SS until a real
        -- GenericPopupMessage instance has been constructed. Try opportunistically
        -- here, but do not fail the dialog yet; we retry immediately after
        -- BP_ShowMessageBox creates the popup.
        if ctx.state.ensure_native_dialog_result_hook ~= nil then
            ctx.state.ensure_native_dialog_result_hook(
                true
            )
        end

        local action_structs = {}
        local result_actions = {}

        local result_tags = {
            ctx.dependencies.UI.DIALOG_RESULT_PRIMARY,
            ctx.dependencies.UI.DIALOG_RESULT_SECONDARY,
            ctx.dependencies.UI.DIALOG_RESULT_TERTIARY,
        }

        for index, action in ipairs(actions or {}) do
            local result_tag = result_tags[index]

            table.insert(
                action_structs,
                make_dialog_action(result_tag, action.label)
            )

            result_actions[result_tag] = action.id
        end

        local descriptor, descriptor_err = ctx.common.try_call(function()
            return descriptor_cdo:MakeGameDialogDescriptor(
                descriptor_class,
                FText(title),
                FText(body),
                action_structs,
                message_class
            )
        end)

        if descriptor_err ~= nil or descriptor == nil then
            ctx.logging.log("DIALOG FAILED: descriptor creation failed: " .. tostring(descriptor_err))
            return nil
        end

        local subsystem, subsystem_err =
            get_messaging_subsystem(host)

        if subsystem_err ~= nil or subsystem == nil then
            ctx.logging.log("DIALOG FAILED: " .. tostring(subsystem_err))
            return nil
        end

        ctx.logging.log(
            string.format(
                "Native dialog show request after click unwind: mode=%s actions=%d",
                tostring(mode),
                #(actions or {})
            )
        )

        local popup, popup_err = ctx.common.try_call(function()
            -- An unbound dynamic delegate is valid here; the result is handled by
            -- our narrowly filtered BP_OnHideDialog hook instead.
            return subsystem:BP_ShowMessageBox(descriptor, nil)
        end)

        if popup_err ~= nil or popup == nil then
            ctx.logging.log("DIALOG FAILED: BP_ShowMessageBox failed: " .. tostring(popup_err))
            return nil
        end

        ctx.logging.log(
            "Native dialog BP_ShowMessageBox returned: mode="
                .. tostring(mode)
                .. " / "
                .. ctx.common.popup_widget_identity(popup)
        )

        -- A real popup now exists. Retry the result-hook registration after
        -- construction, which fixes the cold-launch timing case where UE4SS knew
        -- the Blueprint class but not BP_OnHideDialog yet.
        if ctx.state.ensure_native_dialog_result_hook ~= nil
            and not ctx.state.ensure_native_dialog_result_hook(
                false
            ) then
            ctx.logging.log(
                "DIALOG FAILED: GenericPopupMessage was created, but its result hook still could not be registered."
            )
            return nil
        end

        -- GenericPopupMessage_Small is pooled and may be the exact same UObject
        -- used for the previous Character Share or built-in game dialog.
        ctx.popup.detach_character_share_content(popup)

        ctx.state.popup_state.widget = popup
        ctx.state.popup_state.mode = mode
        ctx.state.popup_state.context = context

        -- GenericPopupMessage_Small instances are pooled. If this UObject was just
        -- used by the previous dialog, explicitly restore normal visibility.
        pcall(function()
            popup:SetVisibility(0)
        end)
        ctx.state.popup_state.resultActions = result_actions
        ctx.state.popup_state.suppressResult = false
        ctx.state.popup_state.capturedImportCode = nil
        ctx.state.popup_state.capturedRenameFirst = nil
        ctx.state.popup_state.capturedRenameLast = nil

        -- Let the game's GenericPopupMessage own its own dimensions and spacing.
        -- We only keep the dialog on the compact/short presentation.
        pcall(function()
            popup["Modal Short"] = true
            popup.HideBackground = false
        end)

        if content_builder ~= nil then
            local content_ok, content_err =
                content_builder(popup)

            if not content_ok then
                ctx.logging.log("DIALOG CONTENT FAILED: " .. tostring(content_err))
                close_native_popup()
                return nil
            end
        end

        local action_count = #(actions or {})

        local custom_actions_ok, custom_actions_err =
            install_popup_topnav_actions(
                popup,
                actions or {}
            )

        if custom_actions_ok then
            ctx.logging.log(
                "Native dialog actions replaced with Character Databank TopNav buttons."
            )
        else
            ctx.logging.log(
                "WARNING: popup TopNav action conversion failed; falling back to native descriptor buttons: "
                    .. tostring(custom_actions_err)
            )
        end

        -- Let the pooled CommonActivatableWidget finish reconstructing, then make
        -- sure the newly configured dialog is the visible/active one.
        ctx.layout.run_group_after("popup_retirement", 1, function()
                if ctx.state.popup_state.widget == popup then
                    pcall(function()
                        popup:SetVisibility(0)
                    end)

                    pcall(function()
                        popup:ActivateWidget()
                    end)
                end
        end, popup)

        if not custom_actions_ok then
            schedule_native_dialog_button_polish(
                popup,
                action_count,
                1
            )
        end

        ctx.logging.log(
            string.format(
                "Native dialog opened: %s / %s",
                mode,
                ctx.common.popup_widget_identity(popup)
            )
        )
        ctx.logging.log("Native dialog lifecycle: injected slots cleared before setup.")

        return popup
    end

    function ctx.popup.set_popup_status(message)
        -- Native dialogs intentionally avoid a persistent status row.
        -- Validation errors are shown as proper message dialogs instead.
        if message ~= nil and message ~= "" then
            ctx.logging.log("UI status: " .. tostring(message))
        end
    end

    function ctx.popup.show_notice_popup(title, body, _duration_ms)
        -- Native notices are intentionally persistent until the player chooses OK.
        return ctx.popup.show_native_dialog(
            "notice",
            title,
            body,
            {
                { id = "close_popup", label = "OK" },
            },
            nil,
            nil
        ) ~= nil
    end

    function ctx.popup.show_import_popup()
        local initial = ctx.state.pending_import_code or ""

        local popup = ctx.popup.show_native_dialog(
            "import",
            "IMPORT CHARACTER",
            "Paste a ZC1 Character Share code below.",
            {
                { id = "validate_import", label = "IMPORT" },
                { id = "cancel_import", label = "CANCEL" },
            },
            function(dialog)
                local entry, editable, entry_err = ctx.popup.create_game_entry(
                    dialog,
                    "CharacterShare_ImportEntry",
                    initial,
                    "ZC1-...",
                    false
                )

                if entry_err ~= nil or entry == nil or editable == nil then
                    return false, entry_err
                end

                local below, below_err = ctx.common.read_property(dialog, "Belowtext")
                if below_err ~= nil or below == nil then
                    return false, "GenericPopupMessage.Belowtext unavailable"
                end

                local _, set_err = ctx.common.try_call(function()
                    below:SetContent(entry)
                end)

                if set_err ~= nil then
                    return false, set_err
                end

                ctx.state.popup_state.textBox = editable
                ctx.state.popup_state.injectedBelow = entry

                pcall(function()
                    editable:SetKeyboardFocus()
                end)

                return true, nil
            end,
            nil
        )

        if popup == nil then
            return false
        end

        ctx.logging.log("Import dialog ready.")
        return true
    end

    local function show_text_export_popup(
        title,
        body,
        value,
        placeholder
    )
        local popup = ctx.popup.show_native_dialog(
            "share",
            title,
            body,
            {
                { id = "close_popup", label = "CLOSE" },
            },
            function(dialog)
                local entry, editable, entry_err = ctx.popup.create_game_entry(
                    dialog,
                    "CharacterShare_ShareEntry",
                    value,
                    placeholder or "",
                    false
                )

                if entry_err ~= nil or entry == nil or editable == nil then
                    return false, entry_err
                end

                local below, below_err = ctx.common.read_property(dialog, "Belowtext")
                if below_err ~= nil or below == nil then
                    return false, "GenericPopupMessage.Belowtext unavailable"
                end

                local _, set_err = ctx.common.try_call(function()
                    below:SetContent(entry)
                end)

                if set_err ~= nil then
                    return false, set_err
                end

                ctx.state.popup_state.textBox = editable
                ctx.state.popup_state.injectedBelow = entry

                pcall(function()
                    editable:SetKeyboardFocus()
                end)

                return true, nil
            end,
            nil
        )

        if popup == nil then
            return false
        end

        ctx.logging.log("Text export dialog ready: " .. tostring(title))
        return true
    end

    function ctx.popup.show_share_popup(code)
        ctx.state.last_export_code = code

        return show_text_export_popup(
            "SHARE CHARACTER",
            "Copy this code to share the selected character.",
            code,
            "ZC1-..."
        )
    end

    function ctx.popup.show_json_popup(json_payload)
        return show_text_export_popup(
            "EXPORT CHARACTER JSON",
            "Copy the plain JSON below. This is debug/inspection output, not a Character Share import code.",
            json_payload,
            '{"v":1,...}'
        )
    end

    function ctx.popup.code_from_import_popup()
        local contents = nil

        if ctx.state.popup_state.capturedImportCode ~= nil then
            contents =
                ctx.state.popup_state.capturedImportCode
        elseif ctx.state.popup_state.mode == "import"
            and ctx.state.popup_state.textBox ~= nil then
            contents =
                ctx.popup.read_text_box_value(
                    ctx.state.popup_state.textBox
                )
        end

        return ctx.dependencies.UI.extract_share_code(
            contents
        )
    end

    function ctx.popup.read_import_code()
        local popup_code = ctx.popup.code_from_import_popup()
        if popup_code ~= nil then
            return popup_code, nil
        end

        if ctx.state.pending_import_code ~= nil then
            return ctx.state.pending_import_code, nil
        end

        return nil,
            "no ZC1 import code is loaded; press Ctrl+Shift+F9 to open Import"
    end

    ctx.state.ensure_native_dialog_result_hook = function(quiet_if_unavailable)
        if ctx.state.native_dialog_result_hook_registered then
            return true
        end

        -- The base Blueprint owns BP_OnHideDialog. It is not necessarily loaded
        -- yet when Lua mods start on a fresh game launch.
        local _, class_err =
            ctx.popup.load_class(ctx.dependencies.UI.GENERIC_POPUP_FALLBACK_CLASS_PATH)

        if class_err ~= nil then
            if not quiet_if_unavailable then
                ctx.logging.log(
                    "Native dialog result hook unavailable after popup construction: "
                        .. tostring(class_err)
                )
            end

            return false
        end

        local hook_ok, hook_err = pcall(function()
            ctx.runtime:register_hook(
                "/Game/Game/UI/Common/WBP_GenericPopupMessage."
                    .. "WBP_GenericPopupMessage_C:BP_OnHideDialog",
                function(self, result)
                    if ctx.state.handle_native_dialog_result ~= nil then
                        ctx.state.handle_native_dialog_result(
                            self,
                            result
                        )
                    end
                end
            )
        end)

        if not hook_ok then
            if not quiet_if_unavailable then
                ctx.logging.log(
                    "Native GenericPopupMessage result hook registration failed after popup construction: "
                        .. tostring(hook_err)
                )
            end

            return false
        end

        ctx.state.native_dialog_result_hook_registered = true
        ctx.logging.log(
            "Native GenericPopupMessage result hook registered."
        )
        return true
    end
end
