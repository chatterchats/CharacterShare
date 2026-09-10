-- Character Share v0.7.51
--
-- Pre-release native Databank import architecture.
--
-- Public-facing share format:
--   ZC1-<Base62>
--
-- ZC1 contains canonical name/background/slot data. Derived metadata is
-- reconstructed locally instead of being transmitted.
--
-- Native import flow:
--   New / Rename:
--     CreateNewDatabankCharacter()
--     -> SetDatabankCharacterType()
--     -> stage DatabankNewCharacterVM.CharacterVM
--     -> ConfirmNewDatabankCharacter()
--
--   Overwrite:
--     select existing BrunoCharacterPoolCharacterViewModel
--     -> stage CharacterBankAuxVM.CharacterVM
--     -> SavePoolCharacter()
--
-- The Character Creator / Edit screen is not required for normal imports.
-- Debug-only keyboard shortcuts are disabled by default and can be toggled
-- from the UE4SS console with `zcs_debug_hotkeys`.

local MOD_TAG = "[CharacterShare]"
local VERSION = "0.7.51"
-- UE4SS supports normal Lua modules. Add this mod's Scripts directory to
-- package.path using main.lua's own source path so the loader works whether the
-- mod manager installs the folder as "Character Share" or "Character_Share".
do
    local source_path =
        debug.getinfo(
            1,
            "S"
        ).source

    if source_path:sub(1, 1) == "@" then
        source_path =
            source_path:sub(2)
    end

    local script_directory =
        source_path:match(
            "^(.*[\\\\/])"
        )

    if script_directory ~= nil then
        package.path =
            script_directory
            .. "?.lua;"
            .. package.path
    end
end

local Codec =
    require("codec")

local Character =
    require("character")

local UI =
    require("ui")

local function log(message)
    print(string.format("%s %s\n", MOD_TAG, tostring(message)))
end

local function try_call(fn)
    local ok, result = pcall(fn)
    if ok then
        return result, nil
    end
    return nil, tostring(result)
end

local function read_property(object, property_name)
    if object == nil then
        return nil, "owner nil"
    end

    return try_call(function()
        return object[property_name]
    end)
end

local function find_first(class_name)
    local object, err = try_call(function()
        return FindFirstOf(class_name)
    end)

    if err ~= nil or object == nil then
        return nil
    end

    return object
end

local function text_value(value)
    if value == nil then
        return ""
    end

    local value_type = type(value)
    if value_type == "string" then
        return value
    elseif value_type == "number" or value_type == "boolean" then
        return tostring(value)
    end

    local text, err = try_call(function()
        return value:ToString()
    end)

    if err == nil and text ~= nil then
        return tostring(text)
    end

    return tostring(value)
end

local function gameplay_tag_value(tag)
    if tag == nil then
        return nil
    end

    local tag_name, err = read_property(tag, "TagName")
    if err == nil and tag_name ~= nil then
        return text_value(tag_name)
    end

    return nil
end

local function is_color_slot_tag(tag)
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

local function count_color_slots(payload)
    local count = 0

    for _, pair in ipairs(
        payload.slots or {}
    ) do
        if type(pair) == "table"
            and is_color_slot_tag(
                pair[1]
            ) then
            count =
                count + 1
        end
    end

    return count
end

local function primary_asset_id_value(asset_id)
    if asset_id == nil then
        return nil
    end

    local asset_type, type_err = read_property(asset_id, "PrimaryAssetType")
    local asset_name, name_err = read_property(asset_id, "PrimaryAssetName")

    if type_err ~= nil or name_err ~= nil or asset_name == nil then
        return nil
    end

    local type_name = nil
    if asset_type ~= nil then
        local nested_name, nested_err = read_property(asset_type, "Name")
        if nested_err == nil and nested_name ~= nil then
            type_name = text_value(nested_name)
        else
            type_name = text_value(asset_type)
        end
    end

    local name_text = text_value(asset_name)

    if name_text == "" or name_text == "None" then
        return nil
    end

    if type_name == nil or type_name == "" or type_name == "None" then
        return name_text
    end

    return type_name .. ":" .. name_text
end

local function array_count(array)
    if array == nil then
        return 0
    end

    local count, err = try_call(function()
        return array:GetArrayNum()
    end)

    if err == nil and count ~= nil then
        return tonumber(count) or 0
    end

    count, err = try_call(function()
        return #array
    end)

    if err == nil and count ~= nil then
        return tonumber(count) or 0
    end

    return 0
end

local function for_each_array(array, callback)
    if array == nil then
        return
    end

    local count = array_count(array)
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
        local value, err = try_call(function()
            return array[index]
        end)

        if err == nil then
            callback(index, value)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Native Character Share dialogs
--
-- v0.5.13 removes the hand-built WBP_ModalBase composition entirely.
--
-- Zero Company already has a complete message-box stack:
--
--   UBitReactorMessagingSubsystem
--       -> UBitReactorGameDialogDescriptor
--       -> WBP_GenericPopupMessage
--
-- We now let that system own:
--   * the modal frame
--   * spacing / layout
--   * button creation
--   * hover / click behavior
--   * button labels
--   * activation / deactivation
--
-- Character Share only injects its text-entry widgets into GenericPopupMessage's
-- existing AboveText / BelowText named slots.
-- ---------------------------------------------------------------------------

local popup_state =
    UI.new_popup_state()

local pending_import_code = nil
local pending_import_payload = nil
local pending_name_override = nil
local pending_name_override_code = nil
local pending_import_navigation_generation = 0
local last_export_code = nil

local databank_ui_state =
    UI.new_databank_state()

local databank_button_click_hook_registered = false
local databank_entry_probe_generation = 0
local databank_entry_probe_candidate_identity = nil
local databank_session_active = false

local native_dialog_result_hook_registered = false
local ensure_native_dialog_result_hook = nil
local handle_native_dialog_result = nil

local function popup_widget_identity(object)
    if object == nil then
        return "<nil>"
    end

    local full_name, full_name_err = try_call(function()
        return object:GetFullName()
    end)

    if full_name_err == nil and full_name ~= nil then
        return tostring(full_name)
    end

    return tostring(object)
end

local function same_remote_object(a, b)
    if a == nil or b == nil then
        return false
    end

    if a == b then
        return true
    end

    return popup_widget_identity(a) == popup_widget_identity(b)
end

local function unwrap_remote_value(value)
    if value == nil then
        return nil
    end

    -- UE4SS can surface UObject-valued UFunction returns / TArray elements as
    -- RemoteUnrealParam wrappers. Calling UObject methods on the wrapper
    -- itself fails even though the wrapped UObject is valid.
    local unwrapped, unwrap_err =
        try_call(
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

local function unwrap_hook_value(value)
    return unwrap_remote_value(
        value
    )
end

local function load_class(class_path)
    local class_object, class_err = try_call(function()
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

        class_object, class_err = try_call(function()
            return StaticFindObject(class_path)
        end)
    end

    if class_err ~= nil or class_object == nil then
        return nil, "class unavailable: " .. class_path
    end

    return class_object, nil
end

local function current_databank_host()
    return find_first("WBP_CharacterBank_Master_C")
end

local function create_user_widget(world_context, class_path)
    if world_context == nil then
        return nil, "world context unavailable"
    end

    local widget_class, class_err = load_class(class_path)
    if class_err ~= nil or widget_class == nil then
        return nil, class_err
    end

    local library_class, library_class_err =
        load_class("/Script/UMG.WidgetBlueprintLibrary")

    if library_class_err ~= nil or library_class == nil then
        return nil, "WidgetBlueprintLibrary unavailable"
    end

    local library, library_err = try_call(function()
        return library_class:GetCDO()
    end)

    if library_err ~= nil or library == nil then
        return nil, "WidgetBlueprintLibrary CDO unavailable"
    end

    local owning_player = nil
    pcall(function()
        owning_player = world_context:GetOwningPlayer()
    end)

    local widget, create_err = try_call(function()
        return library:Create(world_context, widget_class, owning_player)
    end)

    if create_err ~= nil or widget == nil then
        return nil, "could not create " .. class_path .. ": " .. tostring(create_err)
    end

    return widget, nil
end

local function construct_native_widget(owner_widget, class_path, object_name)
    if owner_widget == nil then
        return nil, "owner widget unavailable"
    end

    local widget_tree, tree_err = read_property(owner_widget, "WidgetTree")
    if tree_err ~= nil or widget_tree == nil then
        return nil, "WidgetTree unavailable: " .. tostring(tree_err)
    end

    local widget_class, class_err = load_class(class_path)
    if class_err ~= nil or widget_class == nil then
        return nil, class_err
    end

    local widget, construct_err = try_call(function()
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

local function add_vertical_child(parent, child, padding)
    if parent == nil or child == nil then
        return nil
    end

    local slot, slot_err = try_call(function()
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

    local slot, slot_err = try_call(function()
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

local function create_game_entry(
    popup_widget,
    object_prefix,
    initial_text,
    hint_text,
    read_only
)
    local entry, entry_err =
        create_user_widget(popup_widget, UI.ENTRY_TEXT_CLASS_PATH)

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
        read_property(entry, "EditableText")

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
    ExecuteWithDelay(1, function()
        ExecuteInGameThread(function()
            apply_entry_value()
        end)
    end)

    return entry, editable_text, nil
end

local function make_rich_label(popup_widget, text, object_name)
    local label, label_err = construct_native_widget(
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
        load_class("/Script/Engine.SubsystemBlueprintLibrary")

    if library_err ~= nil or subsystem_library_class == nil then
        return nil, library_err
    end

    local subsystem_library, cdo_err = try_call(function()
        return subsystem_library_class:GetCDO()
    end)

    if cdo_err ~= nil or subsystem_library == nil then
        return nil, "SubsystemBlueprintLibrary CDO unavailable"
    end

    local messaging_class, messaging_class_err =
        load_class("/Script/BitReactorGame.BitReactorMessagingSubsystem")

    if messaging_class_err ~= nil or messaging_class == nil then
        return nil, messaging_class_err
    end

    local subsystem, subsystem_err = try_call(function()
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

    local named_slot, slot_err = read_property(widget, property_name)
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

local function detach_character_share_content(widget)
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
        popup_state.nativeActionEntryBox

    if entry_box == nil then
        entry_box =
            unwrap_hook_value(
                select(
                    1,
                    read_property(
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

local function reset_popup_state()
    popup_state.widget = nil
    popup_state.mode = nil
    popup_state.textBox = nil
    popup_state.renameFirstBox = nil
    popup_state.renameLastBox = nil
    popup_state.context = nil
    popup_state.resultActions = {}
    popup_state.customActions = {}
    popup_state.nativeActionEntryBox = nil
    popup_state.suppressResult = false
    popup_state.capturedImportCode = nil
    popup_state.capturedRenameFirst = nil
    popup_state.capturedRenameLast = nil
    popup_state.injectedAbove = nil
    popup_state.injectedBelow = nil
end

local function close_native_popup()
    if popup_state.widget == nil then
        return
    end

    local widget = popup_state.widget
    popup_state.suppressResult = true

    detach_character_share_content(widget)

    local _, close_err = try_call(function()
        widget:OnCloseWindow()
    end)

    if close_err ~= nil then
        pcall(function()
            widget:RemoveFromParent()
        end)
    end

    reset_popup_state()
end

local function finish_native_popup_hide(widget)
    -- BP_OnHideDialog gives us the result, but does not prove the activatable
    -- widget has actually left CommonUI's stack yet.
    --
    -- Older builds forced Visibility=Collapsed here. That hid the popup while
    -- leaving a possible live stack entry behind. When the native Edit screen
    -- later closed, CommonUI could walk back through those hidden Character
    -- Share dialogs, producing the Import/Duplicate screen flashes.
    detach_character_share_content(widget)
    reset_popup_state()

    log(
        "Native dialog result captured; awaiting native stack retirement: "
            .. popup_widget_identity(widget)
    )
end

local function native_popup_activation_state(widget)
    if widget == nil then
        return nil
    end

    local active, active_err = try_call(function()
        return widget:IsActivated()
    end)

    if active_err ~= nil then
        return nil
    end

    return active == true
end

local function retire_native_popup(widget, on_retired)
    if widget == nil then
        if on_retired ~= nil then
            on_retired()
        end
        return
    end

    -- OnCloseWindow is the popup's own close path and is already the normal
    -- programmatic-close method used by Character Share. Run it after the
    -- BP_OnHideDialog callback returns so we do not re-enter the result handler.
    ExecuteWithDelay(1, function()
        ExecuteInGameThread(function()
            local _, close_err = try_call(function()
                widget:OnCloseWindow()
            end)

            if close_err ~= nil then
                log(
                    "Native dialog OnCloseWindow retirement warning: "
                        .. tostring(close_err)
                )
            end

            local attempts = 0

            local function wait_for_retirement()
                attempts = attempts + 1

                ExecuteInGameThread(function()
                    local active =
                        native_popup_activation_state(widget)

                    if active == false then
                        log(
                            "Native dialog retired from CommonUI: "
                                .. popup_widget_identity(widget)
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
                        log(
                            "Native dialog retirement state unavailable; continuing after native close window."
                        )

                        if on_retired ~= nil then
                            on_retired()
                        end
                        return
                    end

                    if attempts < 10 then
                        ExecuteWithDelay(
                            50,
                            wait_for_retirement
                        )
                        return
                    end

                    -- Last-resort native deactivation. Do not RemoveFromParent:
                    -- that previously desynchronized the CommonUI stack.
                    pcall(function()
                        widget:DeactivateWidget()
                    end)

                    ExecuteWithDelay(100, function()
                        ExecuteInGameThread(function()
                            log(
                                "Native dialog retirement forced through DeactivateWidget: "
                                    .. popup_widget_identity(widget)
                            )

                            if on_retired ~= nil then
                                on_retired()
                            end
                        end)
                    end)
                end)
            end

            ExecuteWithDelay(
                50,
                wait_for_retirement
            )
        end)
    end)
end

local function safe_remove_popup()
    close_native_popup()
end

local function popup_is_open(mode)
    return popup_state.widget ~= nil
        and (mode == nil or popup_state.mode == mode)
end

local function read_text_box_value(box)
    if box == nil then
        return ""
    end

    local value, value_err = try_call(function()
        return box:GetText()
    end)

    if value_err ~= nil or value == nil then
        return ""
    end

    return text_value(value)
end

local function dialog_widget_class_name(widget)
    if widget == nil then
        return ""
    end

    local class_object, class_err = try_call(function()
        return widget:GetClass()
    end)

    if class_err ~= nil or class_object == nil then
        return ""
    end

    local full_name, full_name_err = try_call(function()
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
        unwrap_hook_value(
            select(
                1,
                read_property(
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
        read_property(
            popup,
            "Belowtext"
        )

    local below =
        unwrap_hook_value(below_value)

    if below_err ~= nil or below == nil then
        return false, "GenericPopupMessage.Belowtext unavailable"
    end

    local existing_content = nil

    pcall(function()
        existing_content =
            unwrap_hook_value(
                below:GetContent()
            )
    end)

    local body_panel, body_err =
        construct_native_widget(
            popup,
            "/Script/UMG.VerticalBox",
            "CharacterShare_PopupBodyPanel"
        )

    if body_err ~= nil or body_panel == nil then
        return false, body_err
    end

    local action_row, row_err =
        construct_native_widget(
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
            add_vertical_child(
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
        add_vertical_child(
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

    local _, body_set_err = try_call(function()
        below:SetContent(body_panel)
    end)

    if body_set_err ~= nil then
        return false, body_set_err
    end

    popup_state.injectedBelow =
        body_panel

    popup_state.customActions = {}

    local count =
        #(actions or {})

    for index, action in ipairs(actions or {}) do
        local button, button_err =
            create_user_widget(
                popup,
                UI.DATABANK_TOPNAV_BUTTON_CLASS_PATH
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
            popup_widget_identity(button)

        popup_state.customActions[button_identity] =
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

        log(
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
        unwrap_hook_value(
            select(
                1,
                read_property(
                    popup,
                    "EntryBox_Buttons"
                )
            )
        )

    if entry_box ~= nil then
        popup_state.nativeActionEntryBox =
            entry_box

        pcall(function()
            entry_box:SetVisibility(2)
        end)
    end

    -- Blueprint Construct can restore its design-time text. Re-apply labels on
    -- the next tick by walking only our newly-created action row children.
    ExecuteWithDelay(1, function()
        ExecuteInGameThread(function()
            if popup_state.widget ~= popup then
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
                        unwrap_hook_value(
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
        end)
    end)

    return true, nil
end

local function collect_native_dialog_action_buttons(popup)
    local buttons = {}

    if popup == nil then
        return buttons, nil
    end

    local entry_box, entry_box_err =
        read_property(popup, "EntryBox_Buttons")

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

    local entries, entries_err = try_call(function()
        return entry_box:GetAllEntries()
    end)

    if entries_err ~= nil or entries == nil then
        return buttons,
            "EntryBox_Buttons:GetAllEntries failed: "
            .. tostring(entries_err)
    end

    for_each_array(entries, function(_, widget_value)
        local widget = unwrap_hook_value(widget_value)

        if widget ~= nil then
            table.insert(buttons, widget)

            log(
                "Native dialog action entry: "
                    .. popup_widget_identity(widget)
                    .. " / class="
                    .. dialog_widget_class_name(widget)
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
        read_property(button, "ButtonSwitcher")

    local switcher =
        unwrap_hook_value(switcher_value)

    if switcher_err ~= nil or switcher == nil then
        return ""
    end

    local active, active_err = try_call(function()
        return unwrap_hook_value(
            switcher:GetActiveWidget()
        )
    end)

    if active_err ~= nil or active == nil then
        return ""
    end

    return popup_widget_identity(active)
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
        read_property(button, "Slot")

    local slot =
        unwrap_hook_value(slot_value)

    if slot_err ~= nil or slot == nil then
        return false
    end

    local _, size_err = try_call(function()
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
        read_property(user_widget, "WidgetTree")

    local widget_tree =
        unwrap_hook_value(widget_tree_value)

    if tree_err ~= nil or widget_tree == nil then
        return nil
    end

    local widget, find_err = try_call(function()
        return unwrap_hook_value(
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
        log(
            "Native dialog Long button resize: SizeBox_0 not found."
        )
        return false
    end

    local _, size_err = try_call(function()
        size_box:SetWidthOverride(width)
        size_box:SetMinDesiredWidth(width)
        size_box:SetMaxDesiredWidth(width)
    end)

    if size_err ~= nil then
        log(
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

    log(
        string.format(
            "Native dialog grey Long button resized: width=%.0f size_box=%s slot_auto=%s",
            width,
            popup_widget_identity(size_box),
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
        unwrap_hook_value(
            select(
                1,
                read_property(
                    button,
                    property_name
                )
            )
        )

    if target == nil then
        log(
            "Native dialog button visual unavailable: "
                .. tostring(property_name)
        )
        return false
    end

    local switcher_value, switcher_err =
        read_property(button, "ButtonSwitcher")

    local switcher =
        unwrap_hook_value(switcher_value)

    if switcher_err ~= nil or switcher == nil then
        return false
    end

    local label =
        select(1, read_property(button, "LastUpdatedText"))

    local _, switch_err = try_call(function()
        -- Do not call UpdateButtonStyle/SelectButtonType here.
        -- Those Blueprint paths can select InvalidType when reflected enum
        -- values are marshalled through UE4SS.
        button.SelectedButton = target
        switcher:SetActiveWidget(target)
    end)

    if switch_err ~= nil then
        log(
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

    log(
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
        log(
            "Native dialog button polish: "
                .. tostring(buttons_err or "no action entries yet")
        )
        return false
    end

    local count = math.min(#buttons, action_count or #buttons)

    if action_count ~= nil and count < action_count then
        log(
            string.format(
                "Native dialog button polish: only %d/%d native action entries exist yet.",
                count,
                action_count
            )
        )
        return false
    end

    log(
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

    ExecuteWithDelay(
        attempt == 1 and 1 or 35,
        function()
            ExecuteInGameThread(function()
                if popup_state.widget ~= popup then
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
            end)
        end
    )
end

local function show_native_dialog(
    mode,
    title,
    body,
    actions,
    content_builder,
    context
)
    close_native_popup()

    local host = current_databank_host()
    if host == nil then
        log("DIALOG FAILED: Character Databank is not open.")
        return nil
    end

    local descriptor_class, descriptor_class_err =
        load_class("/Script/BitReactorGame.BitReactorGameDialogDescriptor")

    if descriptor_class_err ~= nil or descriptor_class == nil then
        log("DIALOG FAILED: " .. tostring(descriptor_class_err))
        return nil
    end

    local descriptor_cdo, descriptor_cdo_err = try_call(function()
        return descriptor_class:GetCDO()
    end)

    if descriptor_cdo_err ~= nil or descriptor_cdo == nil then
        log("DIALOG FAILED: descriptor CDO unavailable.")
        return nil
    end

    local message_class, message_class_err =
        load_class(UI.GENERIC_POPUP_CLASS_PATH)

    if message_class_err ~= nil or message_class == nil then
        log(
            "Compact GenericPopupMessage unavailable; using normal dialog: "
            .. tostring(message_class_err)
        )

        message_class, message_class_err =
            load_class(UI.GENERIC_POPUP_FALLBACK_CLASS_PATH)
    end

    if message_class_err ~= nil or message_class == nil then
        log("DIALOG FAILED: " .. tostring(message_class_err))
        return nil
    end

    -- Cold-start note:
    -- BP_OnHideDialog may not be registered with UE4SS until a real
    -- GenericPopupMessage instance has been constructed. Try opportunistically
    -- here, but do not fail the dialog yet; we retry immediately after
    -- BP_ShowMessageBox creates the popup.
    if ensure_native_dialog_result_hook ~= nil then
        ensure_native_dialog_result_hook(
            true
        )
    end

    local action_structs = {}
    local result_actions = {}

    local result_tags = {
        UI.DIALOG_RESULT_PRIMARY,
        UI.DIALOG_RESULT_SECONDARY,
        UI.DIALOG_RESULT_TERTIARY,
    }

    for index, action in ipairs(actions or {}) do
        local result_tag = result_tags[index]

        table.insert(
            action_structs,
            make_dialog_action(result_tag, action.label)
        )

        result_actions[result_tag] = action.id
    end

    local descriptor, descriptor_err = try_call(function()
        return descriptor_cdo:MakeGameDialogDescriptor(
            descriptor_class,
            FText(title),
            FText(body),
            action_structs,
            message_class
        )
    end)

    if descriptor_err ~= nil or descriptor == nil then
        log("DIALOG FAILED: descriptor creation failed: " .. tostring(descriptor_err))
        return nil
    end

    local subsystem, subsystem_err =
        get_messaging_subsystem(host)

    if subsystem_err ~= nil or subsystem == nil then
        log("DIALOG FAILED: " .. tostring(subsystem_err))
        return nil
    end

    log(
        string.format(
            "Native dialog show request after click unwind: mode=%s actions=%d",
            tostring(mode),
            #(actions or {})
        )
    )

    local popup, popup_err = try_call(function()
        -- An unbound dynamic delegate is valid here; the result is handled by
        -- our narrowly filtered BP_OnHideDialog hook instead.
        return subsystem:BP_ShowMessageBox(descriptor, nil)
    end)

    if popup_err ~= nil or popup == nil then
        log("DIALOG FAILED: BP_ShowMessageBox failed: " .. tostring(popup_err))
        return nil
    end

    log(
        "Native dialog BP_ShowMessageBox returned: mode="
            .. tostring(mode)
            .. " / "
            .. popup_widget_identity(popup)
    )

    -- A real popup now exists. Retry the result-hook registration after
    -- construction, which fixes the cold-launch timing case where UE4SS knew
    -- the Blueprint class but not BP_OnHideDialog yet.
    if ensure_native_dialog_result_hook ~= nil
        and not ensure_native_dialog_result_hook(
            false
        ) then
        log(
            "DIALOG FAILED: GenericPopupMessage was created, but its result hook still could not be registered."
        )
        return nil
    end

    -- GenericPopupMessage_Small is pooled and may be the exact same UObject
    -- used for the previous Character Share or built-in game dialog.
    detach_character_share_content(popup)

    popup_state.widget = popup
    popup_state.mode = mode
    popup_state.context = context

    -- GenericPopupMessage_Small instances are pooled. If this UObject was just
    -- used by the previous dialog, explicitly restore normal visibility.
    pcall(function()
        popup:SetVisibility(0)
    end)
    popup_state.resultActions = result_actions
    popup_state.suppressResult = false
    popup_state.capturedImportCode = nil
    popup_state.capturedRenameFirst = nil
    popup_state.capturedRenameLast = nil

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
            log("DIALOG CONTENT FAILED: " .. tostring(content_err))
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
        log(
            "Native dialog actions replaced with Character Databank TopNav buttons."
        )
    else
        log(
            "WARNING: popup TopNav action conversion failed; falling back to native descriptor buttons: "
                .. tostring(custom_actions_err)
        )
    end

    -- Let the pooled CommonActivatableWidget finish reconstructing, then make
    -- sure the newly configured dialog is the visible/active one.
    ExecuteWithDelay(1, function()
        ExecuteInGameThread(function()
            if popup_state.widget == popup then
                pcall(function()
                    popup:SetVisibility(0)
                end)

                pcall(function()
                    popup:ActivateWidget()
                end)
            end
        end)
    end)

    if not custom_actions_ok then
        schedule_native_dialog_button_polish(
            popup,
            action_count,
            1
        )
    end

    log(
        string.format(
            "Native dialog opened: %s / %s",
            mode,
            popup_widget_identity(popup)
        )
    )
    log("Native dialog lifecycle: injected slots cleared before setup.")

    return popup
end

local function set_popup_status(message)
    -- Native dialogs intentionally avoid a persistent status row.
    -- Validation errors are shown as proper message dialogs instead.
    if message ~= nil and message ~= "" then
        log("UI status: " .. tostring(message))
    end
end

local function show_notice_popup(title, body, _duration_ms)
    -- Native notices are intentionally persistent until the player chooses OK.
    return show_native_dialog(
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

local function show_import_popup()
    local initial = pending_import_code or ""

    local popup = show_native_dialog(
        "import",
        "IMPORT CHARACTER",
        "Paste a ZC1 Character Share code below.",
        {
            { id = "validate_import", label = "IMPORT" },
            { id = "cancel_import", label = "CANCEL" },
        },
        function(dialog)
            local entry, editable, entry_err = create_game_entry(
                dialog,
                "CharacterShare_ImportEntry",
                initial,
                "ZC1-...",
                false
            )

            if entry_err ~= nil or entry == nil or editable == nil then
                return false, entry_err
            end

            local below, below_err = read_property(dialog, "Belowtext")
            if below_err ~= nil or below == nil then
                return false, "GenericPopupMessage.Belowtext unavailable"
            end

            local _, set_err = try_call(function()
                below:SetContent(entry)
            end)

            if set_err ~= nil then
                return false, set_err
            end

            popup_state.textBox = editable
            popup_state.injectedBelow = entry

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

    log("Import dialog ready.")
    return true
end

local function show_text_export_popup(
    title,
    body,
    value,
    placeholder
)
    local popup = show_native_dialog(
        "share",
        title,
        body,
        {
            { id = "close_popup", label = "CLOSE" },
        },
        function(dialog)
            local entry, editable, entry_err = create_game_entry(
                dialog,
                "CharacterShare_ShareEntry",
                value,
                placeholder or "",
                false
            )

            if entry_err ~= nil or entry == nil or editable == nil then
                return false, entry_err
            end

            local below, below_err = read_property(dialog, "Belowtext")
            if below_err ~= nil or below == nil then
                return false, "GenericPopupMessage.Belowtext unavailable"
            end

            local _, set_err = try_call(function()
                below:SetContent(entry)
            end)

            if set_err ~= nil then
                return false, set_err
            end

            popup_state.textBox = editable
            popup_state.injectedBelow = entry

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

    log("Text export dialog ready: " .. tostring(title))
    return true
end

local function show_share_popup(code)
    last_export_code = code

    return show_text_export_popup(
        "SHARE CHARACTER",
        "Copy this code to share the selected character.",
        code,
        "ZC1-..."
    )
end

local function show_json_popup(json_payload)
    return show_text_export_popup(
        "EXPORT CHARACTER JSON",
        "Copy the plain JSON below. This is debug/inspection output, not a Character Share import code.",
        json_payload,
        '{"v":1,...}'
    )
end

local function code_from_import_popup()
    local contents = nil

    if popup_state.capturedImportCode ~= nil then
        contents =
            popup_state.capturedImportCode
    elseif popup_state.mode == "import"
        and popup_state.textBox ~= nil then
        contents =
            read_text_box_value(
                popup_state.textBox
            )
    end

    return UI.extract_share_code(
        contents
    )
end

local function read_import_code()
    local popup_code = code_from_import_popup()
    if popup_code ~= nil then
        return popup_code, nil
    end

    if pending_import_code ~= nil then
        return pending_import_code, nil
    end

    return nil,
        "no ZC1 import code is loaded; press Ctrl+Shift+F9 to open Import"
end

local function clear_pending_name_override(reason)
    if pending_name_override ~= nil then
        log(
            "IMPORT SESSION: cleared pending rename override"
                .. (
                    reason ~= nil
                    and (" (" .. tostring(reason) .. ")")
                    or ""
                )
                .. "."
        )
    end

    pending_name_override = nil
    pending_name_override_code = nil
end

local function apply_pending_name_override(payload, code)
    if payload == nil
        or pending_name_override == nil then
        return payload
    end

    -- Rename state belongs to exactly one immutable ZComChar code. Never let a
    -- rename chosen for one character bleed into a later Humanoid/Astromech
    -- payload.
    if code == nil
        or pending_name_override_code == nil
        or pending_name_override_code ~= code then
        log(
            "IMPORT SESSION: ignored rename override because it belongs to a different share code."
        )
        return payload
    end

    payload.first =
        pending_name_override.first
            or payload.first

    payload.last =
        pending_name_override.last
            or ""

    return payload
end

local function adopt_valid_import_code(code)
    if code == nil then
        return
    end

    if pending_import_code ~= nil
        and pending_import_code ~= code then
        pending_import_navigation_generation =
            pending_import_navigation_generation + 1

        pending_import_payload = nil

        clear_pending_name_override(
            "new share code"
        )

        log(
            "IMPORT SESSION: new share code detected; previous import state was isolated."
        )
    elseif pending_name_override_code ~= nil
        and pending_name_override_code ~= code then
        clear_pending_name_override(
            "rename/code mismatch"
        )
    end

    pending_import_code = code
end

local function clear_pending_import()
    pending_import_navigation_generation =
        pending_import_navigation_generation + 1

    pending_import_code = nil
    pending_import_payload = nil

    clear_pending_name_override(
        "import session ended"
    )
end

local function decode_share_code(code)
    local payload,
        codec_meta_or_err =
            Codec.decode(code)

    if payload == nil then
        return nil,
            codec_meta_or_err
    end

    local validated,
        validation_err =
            Character.validate_payload(
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

local function log_payload_summary(payload, heading)
    log("------------------------------------------------------------")
    log(heading or "CHARACTER SHARE PAYLOAD")
    log("Name: " .. payload.first .. (payload.last ~= "" and (" " .. payload.last) or ""))
    log("Type: " .. tostring(payload.characterType))
    log("Archetype: " .. tostring(payload.archetype))
    log("Class: " .. tostring(payload.class))
    log("Secondary class: " .. tostring(payload.secondaryClass))
    log("Talent: " .. tostring(payload.talent))
    log("Weapon class: " .. tostring(payload.weaponClass))
    log("Weapon model: " .. tostring(payload.weaponModel))
    log("Rig: " .. tostring(payload.rig))
    log("Slots: " .. tostring(#payload.slots))
    log(
        "Color/palette slots: "
            .. tostring(
                count_color_slots(
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

local function is_in_progress_character_vm(databank_vm, character_vm)
    if databank_vm == nil or character_vm == nil then
        return false
    end

    local new_vm, new_vm_err =
        read_property(databank_vm, "DatabankNewCharacterVM")

    if new_vm_err ~= nil or new_vm == nil then
        return false
    end

    local in_progress_vm, in_progress_err =
        read_property(new_vm, "CharacterVM")

    if in_progress_err ~= nil or in_progress_vm == nil then
        return false
    end

    return same_uobject(in_progress_vm, character_vm)
end

local function capture_selected_character_payload()

    local aux_vm = find_first("CharacterBankAuxVM_C")
    local databank_vm = find_first("BrunoCharacterDatabankViewModel")

    if aux_vm == nil or databank_vm == nil then
        log("Character Databank view models are not loaded.")
        log("Open Character Databank, select a player-created character, and retry.")
        return nil
    end

    local character_vm, character_err = read_property(aux_vm, "CharacterVM")

    if character_err ~= nil or character_vm == nil then
        log("EXPORT BLOCKED: no selected saved character was found.")
        log("Select a player-created character in Character Databank and retry.")
        show_notice_popup(
            "NOTHING TO SHARE",
            "Select a saved Custom Character or Astromech in Character Databank, then press Ctrl+Shift+F8.",
            2400
        )
        return nil
    end

    if is_in_progress_character_vm(databank_vm, character_vm) then
        log("EXPORT BLOCKED: the current CharacterVM belongs to the in-progress Create New editor.")
        log("Character Share only exports saved Databank characters.")
        show_notice_popup(
            "UNSAVED CHARACTER",
            "Character Share only exports saved Databank characters. Save or cancel the current Create New character first.",
            2800
        )
        return nil
    end

    local first_name = text_value(select(1, read_property(character_vm, "FirstName")))
    local last_name = text_value(select(1, read_property(character_vm, "LastName")))
    local full_name = text_value(select(1, read_property(character_vm, "FullName")))
    local background = text_value(select(1, read_property(character_vm, "BackgroundDescription")))

    if full_name == "" and first_name == "" and last_name == "" then
        log("EXPORT BLOCKED: selected character has no saved display name.")
        show_notice_popup(
            "NOTHING TO SHARE",
            "The current selection does not look like a saved Databank character.",
            2400
        )
        return nil
    end

    log("Selected character: " .. full_name)

    local customization_vm, customization_err =
        read_property(character_vm, "CustomizationInstanceVM")

    if customization_err ~= nil or customization_vm == nil then
        log("CustomizationInstanceVM unavailable.")
        return nil
    end

    local slot_vms, slots_err = read_property(customization_vm, "SlotViewModels")
    if slots_err ~= nil or slot_vms == nil then
        log("SlotViewModels unavailable.")
        return nil
    end

    local expected_count = array_count(slot_vms)
    local slots = {}
    local invalid_slots = 0

    for_each_array(slot_vms, function(index, slot_vm)
        local slot_tag_struct, tag_err = read_property(slot_vm, "SlotTag")
        local tag = nil

        if tag_err == nil then
            tag = gameplay_tag_value(slot_tag_struct)
        end

        if tag == nil or tag == "" then
            invalid_slots = invalid_slots + 1
            log(string.format("Skipping slot %s: could not read SlotTag.", tostring(index)))
            return nil
        end

        local equipped_vm, equipped_err =
            read_property(slot_vm, "EquippedCustomizationPartViewModel")

        local asset = nil
        if equipped_err == nil and equipped_vm ~= nil then
            local asset_id, asset_err = read_property(equipped_vm, "AssetId")
            if asset_err == nil and asset_id ~= nil then
                asset = primary_asset_id_value(asset_id)
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

    log(string.format(
        "Captured %d/%d customization slots (%d invalid).",
        #slots,
        expected_count,
        invalid_slots
    ))

    local captured_color_slots = 0

    for _, pair in ipairs(slots) do
        if is_color_slot_tag(pair[1]) then
            captured_color_slots =
                captured_color_slots + 1
        end
    end

    log(
        string.format(
            "Captured %d color/palette slot(s); colors use the same canonical slot encoder as every other customization asset.",
            captured_color_slots
        )
    )

    if invalid_slots > 0 or #slots ~= expected_count then
        log("Export aborted because the slot capture was incomplete.")
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
            Character.validate_payload(
                payload
            )

    if validation_err ~= nil
        or validated == nil then
        log(
            "Export aborted: "
                .. tostring(validation_err)
        )
        return nil
    end

    return validated
end

local function export_selected_character()
    log("============================================================")
    log("EXPORT START")

    local validated =
        capture_selected_character_payload()

    if validated == nil then
        log("============================================================")
        return
    end

    local share_code,
        compact_stats =
            Codec.encode(
                validated
            )

    if share_code == nil then
        log(
            "Export aborted: ZC1 encoding failed: "
                .. tostring(compact_stats)
        )
        log("============================================================")
        return
    end

    log(
        "Derived type: "
            .. tostring(
                validated.characterType
            )
    )

    log(
        "Derived class: "
            .. tostring(
                validated.class
            )
    )

    log(
        "Derived secondary class: "
            .. tostring(
                validated.secondaryClass
            )
    )

    log(
        string.format(
            "ZC1 binary bytes: %d",
            compact_stats.binaryBytes
        )
    )

    if compact_stats.background ~= nil then
        log(
            string.format(
                "Background: %d raw bytes -> %d stored bytes (%s)",
                compact_stats.background.rawBytes,
                compact_stats.background.storedBytes,
                compact_stats.background.encoding
            )
        )
    end

    log(
        string.format(
            "Codebook revision: %d | tag entries: %d | asset entries: %d across %d tables",
            compact_stats.codebookRevision,
            Codec.tag_dictionary_size(),
            Codec.asset_dictionary_size(),
            Codec.asset_table_count()
        )
    )

    do
        local table_sizes =
            Codec.asset_table_sizes()

        log(
            string.format(
                "Asset tables: palette=%d outfit=%d appearance=%d meta=%d",
                table_sizes.palette or 0,
                table_sizes.outfit or 0,
                table_sizes.appearance or 0,
                table_sizes.meta or 0
            )
        )
    end

    log(
        string.format(
            "Fallbacks: %d extension slot(s), %d raw asset(s)",
            compact_stats.extensionSlots or 0,
            compact_stats.rawAssetFallbacks or 0
        )
    )

    log(
        string.format(
            "CRC32: %08X",
            compact_stats.crc32
        )
    )

    log(
        string.format(
            "ZC1 characters: %d",
            #share_code
        )
    )

    log("EXPORT_CODE_BEGIN")
    log(share_code)
    log("EXPORT_CODE_END")

    show_share_popup(share_code)

    log("EXPORT COMPLETE")
    log("============================================================")
end

local function export_selected_character_json()
    log("============================================================")
    log("JSON EXPORT START")

    local validated =
        capture_selected_character_payload()

    if validated == nil then
        log("============================================================")
        return
    end

    local json_payload,
        json_err =
            Character.to_json(
                validated
            )

    if json_payload == nil then
        log(
            "JSON export aborted: "
                .. tostring(json_err)
        )
        log("============================================================")
        return
    end

    log(
        string.format(
            "Plain JSON characters: %d",
            #json_payload
        )
    )

    log("EXPORT_JSON_BEGIN")
    log(json_payload)
    log("EXPORT_JSON_END")

    show_json_popup(
        json_payload
    )

    log("JSON EXPORT COMPLETE")
    log("============================================================")
end

local function normalize_character_name(name)
    name = tostring(name or "")
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    return string.lower(name)
end

local function payload_full_name(payload)
    if payload.last ~= nil and payload.last ~= "" then
        return payload.first .. " " .. payload.last
    end

    return payload.first
end

local function object_identity(object)
    if object == nil then
        return "<nil>"
    end

    local full_name, err = try_call(function()
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
-- ViewModel as context. This lets duplicate detection stay completely out of
-- FPoolCharacterData/CustomizationSlots.
local pool_character_get_full_name_function = nil
local pool_character_get_full_name_lookup_attempted = false

local function get_pool_character_display_name(character_vm)
    if character_vm == nil then
        return nil, "character vm is nil"
    end

    if not pool_character_get_full_name_lookup_attempted then
        pool_character_get_full_name_lookup_attempted = true

        local function_object, function_err = try_call(function()
            return StaticFindObject(
                "/Script/Bruno.BrunoCharacterPoolCharacterViewModel:GetFullName"
            )
        end)

        if function_err == nil and function_object ~= nil then
            pool_character_get_full_name_function = function_object
            log("Duplicate check: resolved native pool-character GetFullName UFunction.")
        else
            log(
                "Duplicate check: could not resolve pool-character GetFullName UFunction: "
                .. tostring(function_err)
            )
        end
    end

    if pool_character_get_full_name_function == nil then
        return nil, "pool-character GetFullName UFunction unavailable"
    end

    local value, call_err = try_call(function()
        -- A UFunction obtained from StaticFindObject has no object context,
        -- therefore the context object is the first argument.
        return pool_character_get_full_name_function(character_vm)
    end)

    if call_err ~= nil or value == nil then
        return nil, "GetFullName UFunction failed: " .. tostring(call_err)
    end

    return text_value(value), nil
end

local function array_object_identity(value)
    if value == nil then
        return "<nil>"
    end

    local full_name, full_name_err = try_call(function()
        return value:GetFullName()
    end)

    if full_name_err == nil and full_name ~= nil then
        return tostring(full_name)
    end

    return tostring(value)
end

local function for_each_counted_array(array, callback)
    if array == nil then
        return 0, 0
    end

    local count = array_count(array)
    if count <= 0 then
        return 0, 0
    end

    local collected = {}
    local seen = {}

    local function add(value)
        if value == nil or #collected >= count then
            return
        end

        local identity = array_object_identity(value)
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
            local value, value_err = try_call(function()
                return array[index]
            end)

            if value_err == nil then
                add(value)
            end
        end
    end

    if #collected < count then
        for index = 1, count do
            local value, value_err = try_call(function()
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

local function collect_character_pools(databank_vm)
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

    local default_custom, default_custom_err = read_property(
        databank_vm,
        "DefaultCustomCharacterPoolViewModel"
    )
    if default_custom_err == nil then
        add_pool(default_custom, "humanoid", "Default Custom Characters")
    end

    local custom_pools, custom_pools_err = read_property(
        databank_vm,
        "CustomCharacterPoolViewModels"
    )
    if custom_pools_err == nil and custom_pools ~= nil then
        for_each_counted_array(custom_pools, function(_, pool_vm)
            add_pool(pool_vm, "humanoid", "Custom Character Pool")
        end)
    end

    local default_astromech, default_astromech_err = read_property(
        databank_vm,
        "DefaultAstromechCharacterPoolViewModel"
    )
    if default_astromech_err == nil then
        add_pool(default_astromech, "astromech", "Default Astromechs")
    end

    local astromech_pools, astromech_pools_err = read_property(
        databank_vm,
        "AstromechCharacterPoolViewModel"
    )
    if astromech_pools_err == nil and astromech_pools ~= nil then
        for_each_counted_array(astromech_pools, function(_, pool_vm)
            add_pool(pool_vm, "astromech", "Astromech Pool")
        end)
    end

    return pools
end

local function find_duplicate_characters(databank_vm, payload)
    local target_name = payload_full_name(payload)
    local normalized_target = normalize_character_name(target_name)
    local matches = {}
    local unreadable = 0
    local total_seen = 0
    local seen_character_vms = {}

    local pools = collect_character_pools(databank_vm)
    log(string.format("Duplicate check: scanning %d character pool(s).", #pools))

    for _, pool in ipairs(pools) do
        local character_vms, characters_err =
            read_property(pool.vm, "PoolCharacterViewModels")

        if characters_err == nil and character_vms ~= nil then
            local pool_count = array_count(character_vms)

            log(
                string.format(
                    "Duplicate check: %s has %d character(s).",
                    pool.source,
                    pool_count
                )
            )

            local reflected_count, enumerated_count =
                for_each_counted_array(
                    character_vms,
                    function(index, character_vm)
                        local vm_identity =
                            array_object_identity(character_vm)

                        if seen_character_vms[vm_identity] then
                            log(
                                string.format(
                                    "Duplicate check: skipped repeated VM %s from %s.",
                                    vm_identity,
                                    pool.source
                                )
                            )
                            return
                        end

                        seen_character_vms[vm_identity] = true
                        total_seen = total_seen + 1

                        local candidate_name, candidate_err =
                            get_pool_character_display_name(character_vm)

                        if candidate_err ~= nil or candidate_name == nil then
                            unreadable = unreadable + 1
                            log(
                                string.format(
                                    "Duplicate candidate[%d]: %s / %s / <unreadable>",
                                    index,
                                    pool.characterType,
                                    pool.source
                                )
                            )
                            return
                        end

                        log(
                            string.format(
                                "Duplicate candidate[%d]: %s / %s / %s",
                                index,
                                pool.characterType,
                                pool.source,
                                candidate_name
                            )
                        )

                        if normalize_character_name(candidate_name)
                            == normalized_target then
                            table.insert(matches, {
                                name = candidate_name,
                                characterType = pool.characterType,
                                pool = pool.source,
                                vm = character_vm,
                            })
                        end
                    end
                )

            if enumerated_count < reflected_count then
                local missing = reflected_count - enumerated_count
                unreadable = unreadable + missing

                log(
                    string.format(
                        "Duplicate check warning: %s reflected %d character(s) but only %d unique VM(s) were enumerable.",
                        pool.source,
                        reflected_count,
                        enumerated_count
                    )
                )
            end
        end
    end

    log(
        string.format(
            "Duplicate check complete: %d unique character(s) inspected, %d match(es), %d unreadable.",
            total_seen,
            #matches,
            unreadable
        )
    )

    return matches, unreadable
end

local function duplicate_type_label(character_type)
    if character_type == "astromech" then
        return "Astromech"
    elseif character_type == "humanoid" then
        return "Custom Character"
    end

    return tostring(character_type)
end

local function log_duplicate_summary(matches, unreadable, payload)
    if #matches == 0 then
        if unreadable > 0 then
            log(
                string.format(
                    "Duplicate check: no matching name found; %d existing character(s) could not be read.",
                    unreadable
                )
            )
        else
            log("Duplicate check: name is available.")
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

    log(
        string.format(
            "DUPLICATE NAME DETECTED: %d existing character(s) named '%s' (%d same type, %d other type).",
            #matches,
            payload_full_name(payload),
            same_type,
            other_type
        )
    )

    for index, match in ipairs(matches) do
        log(
            string.format(
                "  DUPLICATE[%d]: %s / %s / %s",
                index,
                duplicate_type_label(match.characterType),
                match.pool,
                match.name
            )
        )
    end

    if unreadable > 0 then
        log(
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

        local function_object, function_err = try_call(function()
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

    local value, value_err = try_call(function()
        return pool_character_is_active_function(character_vm)
    end)

    if value_err ~= nil or value == nil then
        return nil
    end

    return value == true
end

local function overwrite_match_description(match, index)
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

local function same_type_matches(payload, matches)
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

local function import_summary(payload)
    local lines = {
        payload_full_name(payload),
        duplicate_type_label(payload.characterType),
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

local function friendly_import_failure(message)
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

local function show_overwrite_target_popup(payload, matches)
    if matches == nil or #matches < 2 then
        return false
    end

    local lines = {
        string.format(
            "%d matching %s characters use the name %s.",
            #matches,
            duplicate_type_label(payload.characterType),
            payload_full_name(payload)
        ),
        "",
        "Choose the existing character that should be replaced:",
    }

    for index, match in ipairs(matches) do
        table.insert(
            lines,
            overwrite_match_description(match, index)
        )
    end

    local actions = {
        { id = "overwrite_target_1", label = "MATCH 1" },
        { id = "overwrite_target_2", label = "MATCH 2" },
        { id = "cancel_import", label = "CANCEL" },
    }

    local popup = show_native_dialog(
        "overwrite_target",
        "CHOOSE OVERWRITE TARGET",
        table.concat(lines, "\n"),
        actions,
        nil,
        {
            payload = payload,
            matches = matches,
        }
    )

    return popup ~= nil
end

local function show_duplicate_resolution_popup(payload, matches, unreadable)
    local display_name = payload_full_name(payload)
    local same_type = same_type_matches(payload, matches)
    local actions = {}
    local body = nil

    if #same_type == 1 and unreadable == 0 then
        body = string.format(
            "%s\n\nA character named %s already exists.\n\nOVERWRITE replaces that character with this import.\nRENAME imports this character as a new copy.",
            import_summary(payload),
            display_name
        )

        actions = {
            { id = "duplicate_overwrite", label = "OVERWRITE" },
            { id = "duplicate_rename", label = "RENAME" },
            { id = "cancel_import", label = "CANCEL" },
        }
    elseif #same_type == 2 and unreadable == 0 then
        body = string.format(
            "%s\n\nTwo existing %s characters use this name. Choose which one to overwrite, import under a new name, or cancel.",
            import_summary(payload),
            duplicate_type_label(payload.characterType)
        )

        actions = {
            { id = "duplicate_overwrite", label = "OVERWRITE" },
            { id = "duplicate_rename", label = "RENAME" },
            { id = "cancel_import", label = "CANCEL" },
        }
    elseif #same_type > 2 then
        body = string.format(
            "%d %s characters already use the name %s. There are too many matches for the compact overwrite picker; rename the import or cancel.",
            #same_type,
            duplicate_type_label(payload.characterType),
            display_name
        )

        actions = {
            { id = "duplicate_rename", label = "RENAME" },
            { id = "cancel_import", label = "CANCEL" },
        }
    else
        local existing_type =
            #matches == 1
                and duplicate_type_label(matches[1].characterType)
                or "another character type"

        body = string.format(
            "%s is already used by %s. There is no same-type character to overwrite, so rename the import or cancel.",
            display_name,
            existing_type
        )

        actions = {
            { id = "duplicate_rename", label = "RENAME" },
            { id = "cancel_import", label = "CANCEL" },
        }
    end

    local popup = show_native_dialog(
        "duplicate",
        "DUPLICATE CHARACTER",
        body,
        actions,
        nil,
        {
            payload = payload,
            matches = matches,
            unreadable = unreadable,
        }
    )

    return popup ~= nil
end

local function read_popup_text(box)
    return read_text_box_value(box)
end

local function show_rename_popup(payload)
    local popup = show_native_dialog(
        "rename",
        "IMPORT AS NEW CHARACTER",
        payload.characterType == "astromech"
            and "Choose the name for the new Astromech."
            or "Choose the first and last name for the new character.",
        {
            { id = "rename_confirm", label = "IMPORT" },
            { id = "cancel_import", label = "CANCEL" },
        },
        function(dialog)
            local below, below_err = read_property(dialog, "Belowtext")
            if below_err ~= nil or below == nil then
                return false, "GenericPopupMessage.Belowtext unavailable"
            end

            local panel, panel_err = construct_native_widget(
                dialog,
                "/Script/UMG.VerticalBox",
                "CharacterShare_RenamePanel"
            )

            if panel_err ~= nil or panel == nil then
                return false, panel_err
            end

            local first_label =
                payload.characterType == "astromech"
                    and "NAME"
                    or "FIRST NAME"

            local first_text, first_text_err = make_rich_label(
                dialog,
                first_label,
                "CharacterShare_RenameFirstLabel"
            )

            if first_text_err == nil and first_text ~= nil then
                add_vertical_child(
                    panel,
                    first_text,
                    {
                        Left = 0.0,
                        Top = 2.0,
                        Right = 0.0,
                        Bottom = 2.0,
                    }
                )
            end

            local first_entry, first_editable, first_err =
                create_game_entry(
                    dialog,
                    "CharacterShare_RenameFirst",
                    payload.first or "",
                    first_label,
                    false
                )

            if first_err ~= nil
                or first_entry == nil
                or first_editable == nil then
                return false, first_err
            end

            add_vertical_child(
                panel,
                first_entry,
                {
                    Left = 0.0,
                    Top = 1.0,
                    Right = 0.0,
                    Bottom = 8.0,
                }
            )

            popup_state.renameFirstBox = first_editable
            popup_state.injectedBelow = panel

            if payload.characterType ~= "astromech" then
                local last_text, last_text_err = make_rich_label(
                    dialog,
                    "LAST NAME",
                    "CharacterShare_RenameLastLabel"
                )

                if last_text_err == nil and last_text ~= nil then
                    add_vertical_child(
                        panel,
                        last_text,
                        {
                            Left = 0.0,
                            Top = 2.0,
                            Right = 0.0,
                            Bottom = 2.0,
                        }
                    )
                end

                local last_entry, last_editable, last_err =
                    create_game_entry(
                        dialog,
                        "CharacterShare_RenameLast",
                        payload.last or "",
                        "LAST NAME",
                        false
                    )

                if last_err ~= nil
                    or last_entry == nil
                    or last_editable == nil then
                    return false, last_err
                end

                add_vertical_child(
                    panel,
                    last_entry,
                    {
                        Left = 0.0,
                        Top = 1.0,
                        Right = 0.0,
                        Bottom = 2.0,
                    }
                )

                popup_state.renameLastBox = last_editable
            end

            local _, set_err = try_call(function()
                below:SetContent(panel)
            end)

            if set_err ~= nil then
                return false, set_err
            end

            pcall(function()
                first_editable:SetKeyboardFocus()
            end)

            return true, nil
        end,
        {
            payload = payload,
        }
    )

    return popup ~= nil
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
    set_popup_status(
        "Invalid import code: "
            .. tostring(detail)
    )

    return show_notice_popup(
        "INVALID SHARE CODE",
        import_error_body(detail),
        0
    )
end

local function import_preflight()
    log("============================================================")
    log("IMPORT PREFLIGHT START")

    local code, read_err = read_import_code()
    if read_err ~= nil then
        log("IMPORT PREFLIGHT FAILED: " .. read_err)
        show_import_error(read_err)
        log("============================================================")
        return nil
    end

    local decoded, decode_err = decode_share_code(code)
    if decode_err ~= nil then
        log("IMPORT PREFLIGHT FAILED: " .. decode_err)
        show_import_error(decode_err)
        log("============================================================")
        return nil
    end

    adopt_valid_import_code(code)

    apply_pending_name_override(
        decoded.payload,
        code
    )

    pending_import_payload = decoded.payload

    log_payload_summary(decoded.payload, "VALID IMPORT PAYLOAD")

    local duplicate_matches = {}
    local duplicate_unreadable = 0
    local databank_vm = find_first("BrunoCharacterDatabankViewModel")
    if databank_vm ~= nil then
        duplicate_matches, duplicate_unreadable =
            find_duplicate_characters(databank_vm, decoded.payload)
        log_duplicate_summary(
            duplicate_matches,
            duplicate_unreadable,
            decoded.payload
        )
    else
        log("Duplicate check skipped: Character Databank view model is not loaded.")
    end

    log("IMPORT PREFLIGHT COMPLETE")
    log("============================================================")
    return decoded.payload, duplicate_matches, duplicate_unreadable
end

local function current_slot_map(character_vm)
    local map = {}

    local customization_vm, customization_err =
        read_property(character_vm, "CustomizationInstanceVM")
    if customization_err ~= nil or customization_vm == nil then
        return nil, "CustomizationInstanceVM unavailable"
    end

    local slot_vms, slots_err = read_property(customization_vm, "SlotViewModels")
    if slots_err ~= nil or slot_vms == nil then
        return nil, "SlotViewModels unavailable"
    end

    for_each_array(slot_vms, function(_, slot_vm)
        local slot_tag_struct, tag_err = read_property(slot_vm, "SlotTag")
        if tag_err == nil and slot_tag_struct ~= nil then
            local tag = gameplay_tag_value(slot_tag_struct)
            if tag ~= nil and tag ~= "" then
                map[tag] = slot_vm
            end
        end
    end)

    return map, nil
end

local function equipped_asset_for_slot(slot_vm)
    local equipped_vm, equipped_err =
        read_property(slot_vm, "EquippedCustomizationPartViewModel")

    if equipped_err ~= nil or equipped_vm == nil then
        return nil
    end

    local asset_id, asset_err = read_property(equipped_vm, "AssetId")
    if asset_err ~= nil or asset_id == nil then
        return nil
    end

    return primary_asset_id_value(asset_id)
end

local function previewed_asset_for_slot(slot_vm)
    local preview_vm, preview_err =
        try_call(
            function()
                return slot_vm:PreviewedCustomizationPartViewModel()
            end
        )

    if preview_err ~= nil
        or preview_vm == nil then
        return nil,
            preview_err
    end

    local asset_id, asset_err =
        read_property(
            preview_vm,
            "AssetId"
        )

    if asset_err ~= nil
        or asset_id == nil then
        return nil,
            asset_err
    end

    return primary_asset_id_value(asset_id),
        nil
end

local function parse_asset_id(asset)
    if asset == nil then
        return nil, nil
    end

    return asset:match("^([^:]+):(.+)$")
end

local function get_part_vm_cdo()
    local class_object, class_err = try_call(function()
        return StaticFindObject("/Script/BitReactorGame.BitReactorCustomizationPartViewModel")
    end)

    if class_err ~= nil or class_object == nil then
        return nil, "could not find BitReactorCustomizationPartViewModel class"
    end

    local cdo, cdo_err = try_call(function()
        return class_object:GetCDO()
    end)

    if cdo_err ~= nil or cdo == nil then
        return nil, "could not get BitReactorCustomizationPartViewModel CDO"
    end

    return cdo, nil
end

local function get_part_vm_for_asset(world_context, asset)
    if asset == nil then
        local none_vm = find_first("BitReactorNoneCustomizationPartViewModel")
        if none_vm == nil then
            return nil, "could not find game's None customization part ViewModel"
        end
        return none_vm, nil
    end

    local asset_type, asset_name = parse_asset_id(asset)
    if asset_type == nil or asset_name == nil then
        return nil, "invalid asset id: " .. tostring(asset)
    end

    local cdo, cdo_err = get_part_vm_cdo()
    if cdo_err ~= nil then
        return nil, cdo_err
    end

    -- UE4SS supports passing Lua tables for reflected struct parameters.
    local part_id = {
        PrimaryAssetType = {
            Name = FName(asset_type),
        },
        PrimaryAssetName = FName(asset_name),
    }

    local part_vm, part_err = try_call(function()
        return cdo:GetOrCreateCachedCustomizationPartViewModelFromPartId(
            world_context,
            part_id
        )
    end)

    if part_err ~= nil or part_vm == nil then
        return nil, "could not create part ViewModel for " .. asset .. ": " .. tostring(part_err)
    end

    return part_vm, nil
end

local function make_primary_asset_id(asset)
    local asset_type,
        asset_name =
            parse_asset_id(
                asset
            )

    if asset_type == nil
        or asset_name == nil then
        return nil,
            "invalid asset id: "
                .. tostring(
                    asset
                )
    end

    return {
        PrimaryAssetType = {
            Name = FName(
                asset_type
            ),
        },
        PrimaryAssetName = FName(
            asset_name
        ),
    },
        nil
end

local function find_core_customization_instance(
    slots
)
    local slots_examined =
        0

    local fragments_examined =
        0

    local direct_owner_errors =
        0

    local slot_owner_errors =
        0

    local first_direct_error =
        nil

    local first_slot_error =
        nil

    for _,
        candidate_slot in pairs(
            slots
        ) do
        slots_examined =
            slots_examined + 1

        local fragments,
            fragments_err =
                try_call(
                    function()
                        return candidate_slot:GetFragments()
                    end
                )

        if fragments_err == nil
            and fragments ~= nil then
            local found_instance =
                nil

            for_each_array(
                fragments,
                function(
                    _,
                    fragment_value
                )
                    if found_instance ~= nil
                        or fragment_value == nil then
                        return
                    end

                    fragments_examined =
                        fragments_examined + 1

                    local fragment =
                        unwrap_remote_value(
                            fragment_value
                        )

                    -- Some fragment types carry a direct owning-instance link.
                    local instance_value,
                        instance_err =
                            try_call(
                                function()
                                    return fragment:GetOwningCustomizationInstance()
                                end
                            )

                    if instance_err == nil
                        and instance_value ~= nil then
                        local instance =
                            unwrap_remote_value(
                                instance_value
                            )

                        if instance ~= nil then
                            found_instance =
                                instance

                            return
                        end
                    end

                    if instance_err ~= nil then
                        direct_owner_errors =
                            direct_owner_errors + 1

                        if first_direct_error == nil then
                            first_direct_error =
                                instance_err
                        end
                    end

                    -- Child fragments may belong to a Core slot rather than
                    -- carrying the CustomizationInstance directly.
                    local owning_slot_value,
                        owning_slot_err =
                            try_call(
                                function()
                                    return fragment:GetOwningCustomizationSlot()
                                end
                            )

                    if owning_slot_err ~= nil
                        or owning_slot_value == nil then
                        if owning_slot_err ~= nil then
                            slot_owner_errors =
                                slot_owner_errors + 1

                            if first_slot_error == nil then
                                first_slot_error =
                                    owning_slot_err
                            end
                        end

                        return
                    end

                    local owning_slot =
                        unwrap_remote_value(
                            owning_slot_value
                        )

                    local slot_instance_value,
                        slot_instance_err =
                            try_call(
                                function()
                                    return owning_slot:GetOwningCustomizationInstance()
                                end
                            )

                    if slot_instance_err == nil
                        and slot_instance_value ~= nil then
                        local slot_instance =
                            unwrap_remote_value(
                                slot_instance_value
                            )

                        if slot_instance ~= nil then
                            found_instance =
                                slot_instance

                            return
                        end
                    end

                    if slot_instance_err ~= nil then
                        slot_owner_errors =
                            slot_owner_errors + 1

                        if first_slot_error == nil then
                            first_slot_error =
                                slot_instance_err
                        end
                    end
                end
            )

            if found_instance ~= nil then
                log(
                    string.format(
                        "MOD-COMPAT CORE OWNER RESOLVED: slots=%d fragments=%d directErrors=%d slotErrors=%d",
                        slots_examined,
                        fragments_examined,
                        direct_owner_errors,
                        slot_owner_errors
                    )
                )

                return found_instance,
                    nil
            end
        end
    end

    return nil,
        string.format(
            "could not resolve the Core CustomizationInstance from live slot fragments (slots=%d fragments=%d directErrors=%d slotErrors=%d firstDirect=%s firstSlot=%s)",
            slots_examined,
            fragments_examined,
            direct_owner_errors,
            slot_owner_errors,
            tostring(
                first_direct_error
            ),
            tostring(
                first_slot_error
            )
        )
end

local function core_slot_asset(
    core_slot
)
    local asset_id,
        asset_err =
            try_call(
                function()
                    return core_slot:GetCustomizationPartPrimaryAssetId()
                end
            )

    if asset_err ~= nil then
        return nil,
            asset_err
    end

    return primary_asset_id_value(
        asset_id
    ),
        nil
end

local function restore_core_slot_asset(
    core_instance,
    slot_tag_struct,
    original_asset
)
    local restore_slot,
        restore_slot_err =
            try_call(
                function()
                    return core_instance:GetSlotInstance(
                        slot_tag_struct
                    )
                end
            )

    restore_slot =
        unwrap_remote_value(
            restore_slot
        )

    if restore_slot_err ~= nil
        or restore_slot == nil then
        return false,
            "could not reacquire Core slot for rollback: "
                .. tostring(
                    restore_slot_err
                )
    end

    if original_asset == nil then
        local _,
            unequip_err =
                try_call(
                    function()
                        restore_slot:UnEquip()
                    end
                )

        if unequip_err ~= nil then
            return false,
                "rollback UnEquip failed: "
                    .. tostring(
                        unequip_err
                    )
        end
    else
        local original_id,
            original_id_err =
                make_primary_asset_id(
                    original_asset
                )

        if original_id_err ~= nil then
            return false,
                original_id_err
        end

        local _,
            restore_err =
                try_call(
                    function()
                        restore_slot:SetCustomizationPartPrimaryAssetId(
                            original_id
                        )
                    end
                )

        if restore_err ~= nil then
            return false,
                "rollback SetCustomizationPartPrimaryAssetId failed: "
                    .. tostring(
                        restore_err
                    )
        end
    end

    local _,
        refresh_err =
            try_call(
                function()
                    core_instance:RefreshCustomization()
                end
            )

    if refresh_err ~= nil then
        return false,
            "rollback RefreshCustomization failed: "
                .. tostring(
                    refresh_err
                )
    end

    return true,
        nil
end

local function try_core_mod_compat_fallback(
    character_vm,
    tag,
    asset
)
    if asset == nil then
        return false,
            "Core fallback is only used for non-empty assets"
    end

    local slots,
        slots_err =
            current_slot_map(
                character_vm
            )

    if slots_err ~= nil then
        return false,
            slots_err
    end

    local target_slot =
        slots[
            tag
        ]

    if target_slot == nil then
        return false,
            "target slot disappeared before Core fallback"
    end

    local slot_tag_struct,
        slot_tag_err =
            read_property(
                target_slot,
                "SlotTag"
            )

    if slot_tag_err ~= nil
        or slot_tag_struct == nil then
        return false,
            "could not read target slot GameplayTag for Core fallback"
    end

    local core_instance,
        core_instance_err =
            find_core_customization_instance(
                slots
            )

    if core_instance_err ~= nil then
        return false,
            core_instance_err
    end

    local core_slot,
        core_slot_err =
            try_call(
                function()
                    return core_instance:GetSlotInstance(
                        slot_tag_struct
                    )
                end
            )

    core_slot =
        unwrap_remote_value(
            core_slot
        )

    if core_slot_err ~= nil
        or core_slot == nil then
        return false,
            "Core GetSlotInstance failed: "
                .. tostring(
                    core_slot_err
                )
    end

    local original_asset,
        original_asset_err =
            core_slot_asset(
                core_slot
            )

    if original_asset_err ~= nil then
        return false,
            "could not read original Core slot asset: "
                .. tostring(
                    original_asset_err
                )
    end

    local desired_id,
        desired_id_err =
            make_primary_asset_id(
                asset
            )

    if desired_id_err ~= nil then
        return false,
            desired_id_err
    end

    local prior_unequip_invalid =
        nil

    local prior_value,
        prior_value_err =
            try_call(
                function()
                    return core_instance:ShouldUnequipInvalidPartsAfterRefresh()
                end
            )

    if prior_value_err == nil then
        prior_unequip_invalid =
            prior_value
    end

    -- The importer is deliberately setting an option that a compatibility mod
    -- already permits but the vanilla ViewModel rejected. Prevent the Core
    -- refresh from immediately deleting it while this one verified mutation is
    -- in progress. Restore the instance policy immediately afterward.
    local _,
        policy_err =
            try_call(
                function()
                    core_instance:SetUnequipInvalidPartsAfterRefresh(
                        false
                    )
                end
            )

    if policy_err ~= nil then
        log(
            string.format(
                "MOD-COMPAT CORE POLICY WARNING: %s :: %s",
                tag,
                tostring(
                    policy_err
                )
            )
        )
    end

    log(
        string.format(
            "MOD-COMPAT CORE ATTEMPT: %s original=%s desired=%s",
            tag,
            tostring(
                original_asset
            ),
            asset
        )
    )

    local _,
        set_err =
            try_call(
                function()
                    core_slot:SetCustomizationPartPrimaryAssetId(
                        desired_id
                    )
                end
            )

    if set_err ~= nil then
        if prior_unequip_invalid ~= nil then
            try_call(
                function()
                    core_instance:SetUnequipInvalidPartsAfterRefresh(
                        prior_unequip_invalid
                    )
                end
            )
        end

        return false,
            "Core SetCustomizationPartPrimaryAssetId failed: "
                .. tostring(
                    set_err
                )
    end

    local _,
        core_refresh_err =
            try_call(
                function()
                    core_instance:RefreshCustomization()
                end
            )

    if core_refresh_err ~= nil then
        local rollback_ok,
            rollback_err =
                restore_core_slot_asset(
                    core_instance,
                    slot_tag_struct,
                    original_asset
                )

        if prior_unequip_invalid ~= nil then
            try_call(
                function()
                    core_instance:SetUnequipInvalidPartsAfterRefresh(
                        prior_unequip_invalid
                    )
                end
            )
        end

        return false,
            "Core RefreshCustomization failed: "
                .. tostring(
                    core_refresh_err
                )
                .. " | rollback="
                .. tostring(
                    rollback_ok
                )
                .. " "
                .. tostring(
                    rollback_err
                )
    end

    -- Refresh may rebuild the public ViewModels. Never verify through a stale
    -- slot reference.
    local refreshed,
        refreshed_err =
            current_slot_map(
                character_vm
            )

    local verified_asset =
        nil

    if refreshed_err == nil then
        local refreshed_slot =
            refreshed[
                tag
            ]

        if refreshed_slot ~= nil then
            verified_asset =
                equipped_asset_for_slot(
                    refreshed_slot
                )
        end
    end

    if verified_asset == asset then
        -- Do NOT restore bUnequipInvalidPartsAfterRefresh here.
        --
        -- The first live test proved the Core write was accepted and the
        -- public slot ViewModel immediately reported the desired unlocker-only
        -- asset, but a later creator/UI refresh could still remove it once the
        -- vanilla invalid-part policy was restored.  This CustomizationInstance
        -- belongs to the transient Create New editor, so keep the guard disabled
        -- for the rest of this editor session.  Closing/saving the creator
        -- destroys that transient instance; vanilla imports never touch this
        -- path at all.
        log(
            string.format(
                "MOD-COMPAT CORE SUCCEEDED: %s -> %s",
                tag,
                asset
            )
        )

        log(
            string.format(
                "MOD-COMPAT CORE GUARD HELD: invalid-part auto-unequip remains disabled for this transient Create New session (previous=%s).",
                tostring(
                    prior_unequip_invalid
                )
            )
        )

        return true,
            "applied via verified Core fragment fallback"
    end

    local core_after,
        core_after_err =
            try_call(
                function()
                    return core_instance:GetSlotInstance(
                        slot_tag_struct
                    )
                end
            )

    core_after =
        unwrap_remote_value(
            core_after
        )

    local core_asset_after =
        nil

    if core_after_err == nil
        and core_after ~= nil then
        core_asset_after =
            select(
                1,
                core_slot_asset(
                    core_after
                )
            )
    end

    log(
        string.format(
            "MOD-COMPAT CORE VERIFY FAILED: %s public=%s core=%s; rolling back.",
            tag,
            tostring(
                verified_asset
            ),
            tostring(
                core_asset_after
            )
        )
    )

    local rollback_ok,
        rollback_err =
            restore_core_slot_asset(
                core_instance,
                slot_tag_struct,
                original_asset
            )

    if prior_unequip_invalid ~= nil then
        try_call(
            function()
                core_instance:SetUnequipInvalidPartsAfterRefresh(
                    prior_unequip_invalid
                )
            end
        )
    end

    if not rollback_ok then
        log(
            string.format(
                "MOD-COMPAT CORE ROLLBACK FAILED: %s :: %s",
                tag,
                tostring(
                    rollback_err
                )
            )
        )
    else
        log(
            string.format(
                "MOD-COMPAT CORE ROLLBACK COMPLETE: %s -> %s",
                tag,
                tostring(
                    original_asset
                )
            )
        )
    end

    return false,
        string.format(
            "Core fallback verification mismatch (wanted=%s public=%s core=%s rollback=%s)",
            tostring(
                asset
            ),
            tostring(
                verified_asset
            ),
            tostring(
                core_asset_after
            ),
            tostring(
                rollback_ok
            )
        )
end

local function apply_slot(character_vm, tag, asset)
    local slots, slots_err = current_slot_map(character_vm)
    if slots_err ~= nil then
        return false, slots_err
    end

    local slot_vm = slots[tag]
    if slot_vm == nil then
        if asset == nil then
            return true, "absent; desired None"
        end

        return false, "target character has no slot " .. tag
    end

    local current_asset = equipped_asset_for_slot(slot_vm)
    if current_asset == asset then
        return true, "already set"
    end

    local part_vm, part_err = get_part_vm_for_asset(character_vm, asset)
    if part_err ~= nil then
        return false, part_err
    end

    local _, equip_err = try_call(function()
        slot_vm:EquipCustomizationPart(part_vm)
    end)

    if equip_err ~= nil then
        return false, "EquipCustomizationPart failed: " .. equip_err
    end

    -- Re-read through a fresh slot map because equipping a high-level part can
    -- rebuild descendant slots and invalidate old ViewModel references.
    local refreshed, refresh_err = current_slot_map(character_vm)
    if refresh_err ~= nil then
        return false, refresh_err
    end

    local refreshed_slot = refreshed[tag]
    if refreshed_slot == nil then
        return false, "slot disappeared after equip: " .. tag
    end

    local verified_asset = equipped_asset_for_slot(refreshed_slot)
    if verified_asset ~= asset then
        -- Some customization-unlocker mods expose cross-archetype/species
        -- options through the game's preview/selection path even though a
        -- direct EquipCustomizationPart() call is rejected by the vanilla
        -- slot logic.  Do not whitelist or reinterpret the asset here:
        -- attempt the game's own preview path once, verify that the exact
        -- desired asset was accepted as the slot preview, then retry the
        -- normal equip call.
        --
        -- This keeps Character Share's wire format and dictionary global:
        -- modded combinations remain transportable without hard-coding which
        -- talents/colors/parts are "allowed" in which slot.
        if asset ~= nil then
            local _, preview_err =
                try_call(
                    function()
                        refreshed_slot:PreviewCustomizationPart(
                            part_vm
                        )
                    end
                )

            if preview_err == nil then
                local preview_asset,
                    preview_read_err =
                        previewed_asset_for_slot(
                            refreshed_slot
                        )

                if preview_read_err == nil
                    and preview_asset == asset then
                    log(
                        string.format(
                            "MOD-COMPAT PREVIEW ACCEPTED: %s -> %s; retrying normal equip.",
                            tag,
                            asset
                        )
                    )

                    -- Previewing can also rebuild slot ViewModels, so reacquire
                    -- the slot before touching it again.
                    local preview_refreshed,
                        preview_refresh_err =
                            current_slot_map(
                                character_vm
                            )

                    if preview_refresh_err == nil then
                        local preview_slot =
                            preview_refreshed[
                                tag
                            ]

                        if preview_slot ~= nil then
                            local _,
                                retry_equip_err =
                                    try_call(
                                        function()
                                            preview_slot:EquipCustomizationPart(
                                                part_vm
                                            )
                                        end
                                    )

                            if retry_equip_err == nil then
                                local final_map,
                                    final_map_err =
                                        current_slot_map(
                                            character_vm
                                        )

                                if final_map_err == nil then
                                    local final_slot =
                                        final_map[
                                            tag
                                        ]

                                    if final_slot ~= nil then
                                        local final_asset =
                                            equipped_asset_for_slot(
                                                final_slot
                                            )

                                        if final_asset == asset then
                                            log(
                                                string.format(
                                                    "MOD-COMPAT EQUIP SUCCEEDED: %s -> %s",
                                                    tag,
                                                    asset
                                                )
                                            )

                                            return true,
                                                "applied via mod-compat preview fallback"
                                        end
                                    end
                                end
                            end
                        end
                    end

                    log(
                        string.format(
                            "MOD-COMPAT PREVIEW DID NOT COMMIT: %s -> %s",
                            tag,
                            asset
                        )
                    )
                elseif preview_read_err ~= nil then
                    log(
                        string.format(
                            "MOD-COMPAT PREVIEW READ FAILED: %s :: %s",
                            tag,
                            tostring(
                                preview_read_err
                            )
                        )
                    )
                else
                    log(
                        string.format(
                            "MOD-COMPAT PREVIEW REJECTED: %s wanted=%s preview=%s",
                            tag,
                            tostring(
                                asset
                            ),
                            tostring(
                                preview_asset
                            )
                        )
                    )
                end
            else
                log(
                    string.format(
                        "MOD-COMPAT PREVIEW CALL FAILED: %s :: %s",
                        tag,
                        tostring(
                            preview_err
                        )
                    )
                )
            end
        end

        if asset ~= nil then
            local core_ok,
                core_result =
                    try_core_mod_compat_fallback(
                        character_vm,
                        tag,
                        asset
                    )

            if core_ok then
                return true,
                    core_result
            end

            log(
                string.format(
                    "MOD-COMPAT CORE FAILED: %s :: %s",
                    tag,
                    tostring(
                        core_result
                    )
                )
            )
        end

        return false, string.format(
            "verification mismatch for %s (wanted=%s got=%s)",
            tag,
            tostring(asset),
            tostring(verified_asset)
        )
    end

    return true, "applied"
end

local function detect_live_creator_type(character_vm)
    local slots, slots_err = current_slot_map(character_vm)
    if slots_err ~= nil then
        return nil, 0, slots_err
    end

    local humanoid = false
    local astromech = false
    local count = 0

    for tag, _ in pairs(slots) do
        count = count + 1

        if string.find(
            tag,
            "br.Customization.Slot.Character.Appearance.Humanoid.",
            1,
            true
        ) then
            humanoid = true
        elseif string.find(
            tag,
            "br.Customization.Slot.Character.Appearance.Astromech.",
            1,
            true
        ) then
            astromech = true
        end
    end

    if humanoid and not astromech then
        return "humanoid", count, nil
    elseif astromech and not humanoid then
        return "astromech", count, nil
    elseif humanoid and astromech then
        return nil, count, "live editor contains both Humanoid and Astromech slot trees"
    end

    return nil, count, "could not identify an active Humanoid/Astromech creator slot tree"
end

local function creator_name(character_type)
    if character_type == "astromech" then
        return "Astromech"
    elseif character_type == "humanoid" then
        return "Custom Character"
    end

    return tostring(character_type)
end


local function trimmed_text(value)
    local text =
        tostring(value or "")

    return text
        :gsub("^%s+", "")
        :gsub("%s+$", "")
end

local function live_creator_name(
    character_vm,
    character_type
)
    if character_vm == nil then
        return nil, nil
    end

    local first =
        trimmed_text(
            text_value(
                select(
                    1,
                    read_property(
                        character_vm,
                        "FirstName"
                    )
                )
            )
        )

    local last =
        trimmed_text(
            text_value(
                select(
                    1,
                    read_property(
                        character_vm,
                        "LastName"
                    )
                )
            )
        )

    local full =
        trimmed_text(
            text_value(
                select(
                    1,
                    read_property(
                        character_vm,
                        "FullName"
                    )
                )
            )
        )

    if character_type == "astromech" then
        local name =
            first ~= ""
                and first
                or full

        if name == "" then
            return nil, nil
        end

        return name, ""
    end

    if first == "" and last == "" then
        return nil, nil
    end

    return first, last
end

local function matching_active_new_character_vm(
    databank_vm,
    character_type
)
    if databank_vm == nil then
        return nil, "Character Databank ViewModel unavailable"
    end

    local new_vm, new_vm_err =
        read_property(
            databank_vm,
            "DatabankNewCharacterVM"
        )

    if new_vm_err ~= nil or new_vm == nil then
        return nil, "no native new-character ViewModel"
    end

    local character_vm, character_vm_err =
        read_property(
            new_vm,
            "CharacterVM"
        )

    if character_vm_err ~= nil
        or character_vm == nil then
        return nil, "no active new-character CharacterVM"
    end

    local live_type, _, live_type_err =
        detect_live_creator_type(
            character_vm
        )

    if live_type_err ~= nil
        or live_type == nil then
        return nil,
            "could not verify active creator type: "
            .. tostring(live_type_err)
    end

    if live_type ~= character_type then
        return nil,
            "active creator is "
            .. creator_name(live_type)
            .. ", not "
            .. creator_name(character_type)
    end

    return character_vm, nil
end

local function adopt_manual_creator_name(
    payload,
    character_vm,
    source_label
)
    -- Only a Character Share Rename decision opts this import session into
    -- "local/manual name wins" behavior. Otherwise the share payload remains
    -- authoritative, preserving the normal import semantics.
    if payload == nil
        or character_vm == nil
        or pending_name_override == nil then
        return false
    end

    local live_first, live_last =
        live_creator_name(
            character_vm,
            payload.characterType
        )

    if live_first == nil then
        return false
    end

    live_last =
        live_last or ""

    local payload_first =
        trimmed_text(
            payload.first
        )

    local payload_last =
        trimmed_text(
            payload.last
        )

    if live_first == payload_first
        and live_last == payload_last then
        return false
    end

    local old_name =
        payload_full_name(payload)

    payload.first =
        live_first

    payload.last =
        payload.characterType == "astromech"
            and ""
            or live_last

    pending_name_override = {
        first = payload.first,
        last = payload.last,
    }

    pending_name_override_code =
        pending_import_code

    pending_import_payload =
        payload

    log(
        string.format(
            "%s: adopted manual creator name '%s' -> '%s'.",
            source_label or "IMPORT",
            tostring(old_name),
            tostring(
                payload_full_name(payload)
            )
        )
    )

    return true
end

local function verify_staged_slots(
    character_vm,
    ordered_slots
)
    local slots,
        slots_err =
            current_slot_map(
                character_vm
            )

    if slots_err ~= nil then
        return nil,
            "could not reacquire final slot map: "
                .. tostring(
                    slots_err
                )
    end

    local failures = {}

    for _,
        item in ipairs(
            ordered_slots
        ) do
        local slot_vm =
            slots[
                item.tag
            ]

        if slot_vm == nil then
            if item.asset ~= nil then
                table.insert(
                    failures,
                    {
                        item = item,
                        actual = nil,
                        detail = "slot missing during final verification",
                    }
                )
            end
        else
            local actual =
                equipped_asset_for_slot(
                    slot_vm
                )

            if actual ~= item.asset then
                table.insert(
                    failures,
                    {
                        item = item,
                        actual = actual,
                        detail = "final verification mismatch",
                    }
                )
            end
        end
    end

    return failures,
        nil
end

local function stage_payload_to_character_vm(
    payload,
    character_vm,
    session_label
)
    local live_type, live_slot_count, live_type_err =
        detect_live_creator_type(character_vm)

    if live_type_err ~= nil or live_type == nil then
        return false,
            "could not verify editor type: " .. tostring(live_type_err)
    end

    log(
        string.format(
            "%s editor verified: %s (%d live slots).",
            session_label or "Import",
            creator_name(live_type),
            live_slot_count
        )
    )

    if live_type ~= payload.characterType then
        return false,
            "payload type is "
            .. creator_name(payload.characterType)
            .. " but editor is "
            .. creator_name(live_type)
    end

    local ordered_slots = Character.sorted_slots(payload)
    local applied = 0
    local already_set = 0
    local satisfied_absent_none = 0
    local remaining = ordered_slots
    local final_failures = {}

    -- Equipping high-level customization parts can rebuild descendant slot
    -- ViewModels. Humanoid usually settles fast enough for one pass, but the
    -- Astromech tree can expose a conditional descendant only after another
    -- parent part is equipped. Retry only the failures after the rest of the
    -- pass has had a chance to rebuild the tree.
    for pass = 1, 3 do
        local failures = {}

        for _, item in ipairs(remaining) do
            local ok, detail =
                apply_slot(
                    character_vm,
                    item.tag,
                    item.asset
                )

            if ok then
                applied = applied + 1

                if detail == "already set" then
                    already_set = already_set + 1
                elseif detail == "absent; desired None" then
                    satisfied_absent_none =
                        satisfied_absent_none + 1
                end
            else
                table.insert(
                    failures,
                    {
                        item = item,
                        detail = detail,
                    }
                )

                log(
                    string.format(
                        "%s SLOT RETRY[%d]: %s -> %s :: %s",
                        session_label or "IMPORT",
                        pass,
                        item.tag,
                        tostring(item.asset),
                        tostring(detail)
                    )
                )
            end
        end

        if #failures == 0 then
            final_failures = {}
            break
        end

        final_failures = failures

        if pass < 3 then
            remaining = {}

            for _, failure in ipairs(failures) do
                table.insert(
                    remaining,
                    failure.item
                )
            end
        end
    end

    if #final_failures > 0 then
        local first =
            final_failures[1]

        return false,
            string.format(
                "%d/%d slots failed; first: %s :: %s",
                #final_failures,
                #ordered_slots,
                tostring(first.item.tag),
                tostring(first.detail)
            )
    end

    -- Earlier versions verified each slot only at the moment it was applied.
    -- A later parent/weapon/UI refresh could invalidate an earlier slot without
    -- being noticed.  Verify the *entire final tree* after all mutations.
    local final_verify,
        final_verify_err =
            verify_staged_slots(
                character_vm,
                ordered_slots
            )

    if final_verify_err ~= nil then
        return false,
            final_verify_err
    end

    if #final_verify > 0 then
        log(
            string.format(
                "%s FINAL VERIFY: %d slot(s) drifted after later customization updates; running one bounded stabilization pass.",
                session_label or "IMPORT",
                #final_verify
            )
        )

        for _,
            failure in ipairs(
                final_verify
            ) do
            local stabilize_ok,
                stabilize_detail =
                    apply_slot(
                        character_vm,
                        failure.item.tag,
                        failure.item.asset
                    )

            if not stabilize_ok then
                log(
                    string.format(
                        "%s FINAL STABILIZE FAILED: %s wanted=%s actual=%s :: %s",
                        session_label or "IMPORT",
                        failure.item.tag,
                        tostring(
                            failure.item.asset
                        ),
                        tostring(
                            failure.actual
                        ),
                        tostring(
                            stabilize_detail
                        )
                    )
                )
            else
                log(
                    string.format(
                        "%s FINAL STABILIZE APPLIED: %s -> %s",
                        session_label or "IMPORT",
                        failure.item.tag,
                        tostring(
                            failure.item.asset
                        )
                    )
                )
            end
        end

        final_verify,
            final_verify_err =
                verify_staged_slots(
                    character_vm,
                    ordered_slots
                )

        if final_verify_err ~= nil then
            return false,
                final_verify_err
        end
    end

    if #final_verify > 0 then
        local first =
            final_verify[1]

        return false,
            string.format(
                "%d/%d slots failed final whole-character verification; first: %s wanted=%s got=%s",
                #final_verify,
                #ordered_slots,
                tostring(
                    first.item.tag
                ),
                tostring(
                    first.item.asset
                ),
                tostring(
                    first.actual
                )
            )
    end

    log(
        string.format(
            "%s FINAL VERIFY COMPLETE: all %d final live slots match the payload.",
            session_label or "IMPORT",
            #ordered_slots
        )
    )

    local _, name_err = try_call(function()
        character_vm:SetFullName(FText(payload.first), FText(payload.last))
    end)

    if name_err ~= nil then
        return false, "setting name failed: " .. name_err
    end

    local _, background_err = try_call(function()
        character_vm:SetBackgroundDescription(FText(payload.background))
    end)

    if background_err ~= nil then
        return false, "setting background failed: " .. background_err
    end

    log(
        string.format(
            "%s STAGE COMPLETE: %d/%d slots satisfied; %d already correct; %d absent conditional None slot(s).",
            session_label or "IMPORT",
            applied,
            #ordered_slots,
            already_set,
            satisfied_absent_none
        )
    )

    return true, nil
end

local function character_list_page_for_type(master, character_type)
    if master == nil then
        return nil
    end

    if character_type == "astromech" then
        return select(1, read_property(master, "AstromechCharacterList"))
    end

    return select(1, read_property(master, "OtherCharacterList"))
end

local function active_new_character_session(databank_vm)
    if databank_vm == nil then
        return nil, nil
    end

    local new_vm, new_vm_err =
        read_property(databank_vm, "DatabankNewCharacterVM")

    if new_vm_err ~= nil or new_vm == nil then
        return nil, nil
    end

    local character_vm, character_vm_err =
        read_property(new_vm, "CharacterVM")

    if character_vm_err ~= nil or character_vm == nil then
        return new_vm, nil
    end

    local live_type, live_slot_count, _ =
        detect_live_creator_type(character_vm)

    if live_type ~= nil then
        return new_vm, {
            vm = character_vm,
            characterType = live_type,
            slotCount = live_slot_count,
        }
    end

    return new_vm, nil
end

local function wait_for_new_character_to_close(
    databank_vm,
    on_closed,
    on_failed
)
    local attempts = 0

    local function poll()
        attempts = attempts + 1

        ExecuteInGameThread(function()
            local _, active = active_new_character_session(databank_vm)

            if active == nil then
                log(
                    string.format(
                        "OVERWRITE: Create New session closed after %d check(s).",
                        attempts
                    )
                )
                on_closed()
                return
            end

            if attempts >= 20 then
                on_failed(
                    "Create New remained active after cancellation."
                )
                return
            end

            ExecuteWithDelay(100, poll)
        end)
    end

    ExecuteWithDelay(100, poll)
end

local function close_active_new_character_before_overwrite(
    databank_vm,
    on_closed,
    on_failed
)
    local new_vm, active =
        active_new_character_session(databank_vm)

    if active == nil then
        on_closed()
        return
    end

    log(
        string.format(
            "OVERWRITE: active Create New editor detected (%s, %d live slots); cancelling it before opening Edit.",
            creator_name(active.characterType),
            active.slotCount or 0
        )
    )

    local _, cancel_err = try_call(function()
        new_vm:CancelNewCharacter()
    end)

    if cancel_err ~= nil then
        on_failed(
            "CancelNewCharacter failed: " .. tostring(cancel_err)
        )
        return
    end

    wait_for_new_character_to_close(
        databank_vm,
        on_closed,
        on_failed
    )
end

local function cancel_auto_created_new_character(
    new_vm,
    reason
)
    if new_vm == nil then
        return
    end

    local _, cancel_err = try_call(function()
        new_vm:CancelNewCharacter()
    end)

    if cancel_err ~= nil then
        log(
            "AUTO IMPORT cleanup warning: CancelNewCharacter failed after "
                .. tostring(reason)
                .. ": "
                .. tostring(cancel_err)
        )
    else
        log(
            "AUTO IMPORT cleanup: cancelled temporary Create New session after "
                .. tostring(reason)
                .. "."
        )
    end
end

local function auto_import_fail(
    title,
    message,
    new_vm
)
    log(
        "AUTO IMPORT FAILED: "
            .. tostring(message)
    )

    if new_vm ~= nil then
        cancel_auto_created_new_character(
            new_vm,
            message
        )
    end

    show_notice_popup(
        title or "IMPORT FAILED",
        friendly_import_failure(
            message
        ),
        5200
    )
end

local function stage_auto_import_into_character_vm(
    payload,
    character_vm,
    source_label,
    allow_live_name_override
)
    if payload == nil
        or character_vm == nil then
        return false, "payload/editor unavailable"
    end

    -- IMPORTANT:
    -- A creator that Character Share just opened automatically still contains
    -- the game's own generated/default name (for example P1-O5 on Astromech).
    -- That is not a player edit and must not supersede the validated payload
    -- name.
    --
    -- Live-name adoption is therefore allowed only when the creator was
    -- already open before this automatic import began. The legacy manual
    -- Validate/Stage paths keep their existing v0.6.10 behavior.
    if allow_live_name_override then
        adopt_manual_creator_name(
            payload,
            character_vm,
            source_label or "AUTO IMPORT"
        )
    else
        log(
            string.format(
                "%s: preserving validated payload name '%s' over automatic creator default.",
                source_label or "AUTO IMPORT",
                payload_full_name(payload)
            )
        )
    end

    local databank_vm =
        find_first(
            "BrunoCharacterDatabankViewModel"
        )

    if databank_vm == nil then
        return false,
            "Character Databank ViewModel disappeared before staging"
    end

    local matches, unreadable =
        find_duplicate_characters(
            databank_vm,
            payload
        )

    if #matches > 0 then
        log_duplicate_summary(
            matches,
            unreadable,
            payload
        )

        show_duplicate_resolution_popup(
            payload,
            matches,
            unreadable
        )

        return false,
            "duplicate name appeared before staging"
    end

    if unreadable > 0 then
        return false,
            "duplicate-name verification became incomplete before staging"
    end

    return stage_payload_to_character_vm(
        payload,
        character_vm,
        source_label or "AUTO IMPORT"
    )
end

local function wait_for_native_create_new_then_stage(
    payload,
    navigation_generation,
    attempt,
    previous_slot_count,
    stable_checks
)
    if navigation_generation
        ~= pending_import_navigation_generation then
        log(
            "SAFE IMPORT wait cancelled because the pending import changed."
        )
        return
    end

    attempt =
        attempt or 1

    ExecuteInGameThread(function()
        if navigation_generation
            ~= pending_import_navigation_generation then
            return
        end

        local databank_vm =
            find_first(
                "BrunoCharacterDatabankViewModel"
            )

        if databank_vm ~= nil then
            local _, active =
                active_new_character_session(
                    databank_vm
                )

            if active ~= nil then
                if active.characterType
                    ~= payload.characterType then
                    show_notice_popup(
                        "WRONG CREATOR OPEN",
                        "Character Share is waiting for "
                            .. creator_name(payload.characterType)
                            .. ", but the game currently has "
                            .. creator_name(active.characterType)
                            .. " Create New open. Cancel/back out of that creator and open the matching one.",
                        5200
                    )

                    log(
                        "SAFE IMPORT stopped because the wrong native Create New editor was opened."
                    )
                    return
                end

                local live_type,
                    live_slot_count,
                    live_type_err =
                        detect_live_creator_type(
                            active.vm
                        )

                if live_type
                    == payload.characterType then
                    local current_count =
                        live_slot_count or 0

                    if previous_slot_count
                        == current_count then
                        stable_checks =
                            (stable_checks or 0) + 1
                    else
                        stable_checks = 0
                    end

                    if stable_checks < 1 then
                        log(
                            string.format(
                                "SAFE IMPORT creator detected but still settling: %s (%d live slots).",
                                creator_name(live_type),
                                current_count
                            )
                        )

                        ExecuteWithDelay(
                            100,
                            function()
                                wait_for_native_create_new_then_stage(
                                    payload,
                                    navigation_generation,
                                    attempt + 1,
                                    current_count,
                                    stable_checks
                                )
                            end
                        )
                        return
                    end

                    log(
                        string.format(
                            "SAFE IMPORT native creator verified stable after %d check(s): %s (%d live slots).",
                            attempt,
                            creator_name(live_type),
                            current_count
                        )
                    )

                    local staged, stage_err =
                        stage_auto_import_into_character_vm(
                            payload,
                            active.vm,
                            "SAFE IMPORT",
                            false
                        )

                    if staged then
                        show_notice_popup(
                            "IMPORT STAGED",
                            string.format(
                                "%s has been loaded into the game's native %s creator. Review it, then use the game's Save button.",
                                payload_full_name(payload),
                                creator_name(payload.characterType)
                            ),
                            4600
                        )

                        log(
                            "SAFE IMPORT COMPLETE: native Create New was user/game-owned; payload staged; final Save remains manual."
                        )
                    elseif stage_err
                        ~= "duplicate name appeared before staging" then
                        auto_import_fail(
                            "IMPORT STAGING FAILED",
                            tostring(stage_err),
                            nil
                        )
                    end

                    return
                elseif live_type_err ~= nil then
                    log(
                        "SAFE IMPORT waiting for native creator slot tree: "
                            .. tostring(live_type_err)
                    )
                end
            end
        end

        if attempt >= 300 then
            show_notice_popup(
                "IMPORT READY",
                string.format(
                    "%s is still pending. Open Create New under %s, then retry Import if the automatic staging window expired.",
                    payload_full_name(payload),
                    creator_name(payload.characterType)
                ),
                5200
            )

            log(
                "SAFE IMPORT wait expired after 30 seconds without a matching native Create New editor."
            )
            return
        end

        ExecuteWithDelay(
            100,
            function()
                wait_for_native_create_new_then_stage(
                    payload,
                    navigation_generation,
                    attempt + 1,
                    previous_slot_count,
                    stable_checks
                )
            end
        )
    end)
end

local function make_empty_tag_requirements()
    -- FGameplayTagRequirements:
    --   RequireTags : FGameplayTagContainer
    --   IgnoreTags  : FGameplayTagContainer
    --   TagQuery    : FGameplayTagQuery
    --
    -- The native create flow uses this struct for ConfirmNewDatabankCharacter.
    -- A zero/empty requirement set is the least permissive *filter state* in
    -- the sense that it imposes no additional tag requirements.
    return {
        RequireTags = {
            GameplayTags = {},
            ParentTags = {},
        },
        IgnoreTags = {
            GameplayTags = {},
            ParentTags = {},
        },
        TagQuery = {},
    }
end

local function snapshot_type_pool_identities(
    databank_vm,
    character_type
)
    local identities = {}

    for _,
        pool in ipairs(
            collect_character_pools(
                databank_vm
            )
        ) do
        if pool.characterType
            == character_type then
            local character_vms,
                characters_err =
                    read_property(
                        pool.vm,
                        "PoolCharacterViewModels"
                    )

            if characters_err == nil
                and character_vms ~= nil then
                for_each_counted_array(
                    character_vms,
                    function(
                        _,
                        character_vm
                    )
                        identities[
                            array_object_identity(
                                character_vm
                            )
                        ] =
                            true
                    end
                )
            end
        end
    end

    return identities
end

local function scan_new_type_pool_entries(
    databank_vm,
    character_type,
    baseline_identities
)
    local entries = {}
    local unreadable = 0

    baseline_identities =
        baseline_identities or {}

    for _,
        pool in ipairs(
            collect_character_pools(
                databank_vm
            )
        ) do
        if pool.characterType
            == character_type then
            local character_vms,
                characters_err =
                    read_property(
                        pool.vm,
                        "PoolCharacterViewModels"
                    )

            if characters_err == nil
                and character_vms ~= nil then
                for_each_counted_array(
                    character_vms,
                    function(
                        _,
                        character_vm
                    )
                        local identity =
                            array_object_identity(
                                character_vm
                            )

                        if not baseline_identities[
                            identity
                        ] then
                            local candidate_name,
                                candidate_err =
                                    get_pool_character_display_name(
                                        character_vm
                                    )

                            if candidate_err ~= nil
                                or candidate_name == nil then
                                unreadable =
                                    unreadable + 1
                            else
                                table.insert(
                                    entries,
                                    {
                                        name = candidate_name,
                                        identity = identity,
                                        vm = character_vm,
                                        pool = pool.source,
                                    }
                                )
                            end
                        end
                    end
                )
            end
        end
    end

    return entries,
        unreadable
end

local function verify_headless_created_character(
    databank_vm,
    payload,
    baseline_identities,
    attempt
)
    attempt =
        attempt or 1

    ExecuteInGameThread(function()
        local expected_name =
            payload_full_name(
                payload
            )

        local normalized_expected =
            normalize_character_name(
                expected_name
            )

        local new_entries,
            unreadable =
                scan_new_type_pool_entries(
                    databank_vm,
                    payload.characterType,
                    baseline_identities
                )

        for _,
            entry in ipairs(
                new_entries
            ) do
            if normalize_character_name(
                entry.name
            ) ==
                normalized_expected then
                log(
                    string.format(
                        "NATIVE CREATE VERIFIED: '%s' appeared in the %s pool after %d check(s).",
                        expected_name,
                        creator_name(
                            payload.characterType
                        ),
                        attempt
                    )
                )

                clear_pending_import()

                show_notice_popup(
                    "IMPORT COMPLETE",
                    string.format(
                        "%s was added to Character Databank.",
                        expected_name
                    ),
                    4200
                )

                return
            end
        end

        if #new_entries > 0
            and (
                attempt == 1
                or attempt == 5
                or attempt == 10
            ) then
            local observed_names = {}

            for _,
                entry in ipairs(
                    new_entries
                ) do
                table.insert(
                    observed_names,
                    entry.name
                )
            end

            log(
                string.format(
                    "NATIVE CREATE VERIFY: new %s pool entry observed, but name does not yet match payload (expected='%s' observed='%s').",
                    creator_name(
                        payload.characterType
                    ),
                    expected_name,
                    table.concat(
                        observed_names,
                        "', '"
                    )
                )
            )
        end

        if unreadable > 0
            and (
                attempt == 1
                or attempt == 10
            ) then
            log(
                string.format(
                    "NATIVE CREATE VERIFY WARNING: %d newly-created candidate(s) were unreadable on check %d.",
                    unreadable,
                    attempt
                )
            )
        end

        if attempt < 20 then
            ExecuteWithDelay(
                100,
                function()
                    verify_headless_created_character(
                        databank_vm,
                        payload,
                        baseline_identities,
                        attempt + 1
                    )
                end
            )
            return
        end

        -- A native pool identity delta is stronger evidence of successful
        -- creation than an exact display-name match. In particular, Astromech
        -- characters only persist the game's single native name field; a
        -- synthetic/imported payload containing a separate LastName can be
        -- normalized by the native commit to the FirstName.
        if #new_entries > 0 then
            local observed_names = {}

            for _,
                entry in ipairs(
                    new_entries
                ) do
                table.insert(
                    observed_names,
                    entry.name
                )
            end

            local observed =
                table.concat(
                    observed_names,
                    "', '"
                )

            log(
                string.format(
                    "NATIVE CREATE VERIFIED WITH NAME CHANGE: native pool entry was created, but expected='%s' observed='%s'.",
                    expected_name,
                    observed
                )
            )

            clear_pending_import()

            show_notice_popup(
                "IMPORT COMPLETE - NAME ADJUSTED",
                string.format(
                    "The character was imported as '%s'. The game did not keep the requested name '%s'.",
                    observed,
                    expected_name
                ),
                6500
            )

            return
        end

        log(
            "NATIVE CREATE VERIFY UNCERTAIN: Confirm returned success, but no new character identity was observed in the target pool within 2 seconds."
        )

        show_notice_popup(
            "IMPORT STATUS UNCERTAIN",
            "The native create transaction returned success, but Character Share could not observe a new character entry in the target Databank pool. Check the list before retrying so you do not create a duplicate.",
            6000
        )
    end)
end

local function wait_for_headless_draft_then_stage(
    databank_vm,
    new_vm,
    payload,
    baseline_identities,
    attempt,
    previous_slot_count,
    stable_checks
)
    attempt =
        attempt or 1

    stable_checks =
        stable_checks or 0

    ExecuteInGameThread(function()
        local character_vm,
            character_vm_err =
                read_property(
                    new_vm,
                    "CharacterVM"
                )

        if character_vm_err == nil
            and character_vm ~= nil then
            local live_type,
                live_slot_count,
                live_type_err =
                    detect_live_creator_type(
                        character_vm
                    )

            if live_type == payload.characterType then
                local current_count =
                    live_slot_count or 0

                if previous_slot_count == current_count then
                    stable_checks =
                        stable_checks + 1
                else
                    stable_checks = 0
                end

                if stable_checks >= 1 then
                    log(
                        string.format(
                            "NATIVE CREATE DRAFT READY: %s (%d live slots) after %d check(s).",
                            creator_name(live_type),
                            current_count,
                            attempt
                        )
                    )

                    local staged,
                        stage_err =
                            stage_auto_import_into_character_vm(
                                payload,
                                character_vm,
                                "NATIVE CREATE",
                                false
                            )

                    if not staged then
                        auto_import_fail(
                            "NATIVE IMPORT FAILED",
                            "Native draft staging failed: "
                                .. tostring(
                                    stage_err
                                ),
                            new_vm
                        )
                        return
                    end

                    log(
                        "NATIVE CREATE STAGED: calling native ConfirmNewDatabankCharacter with empty GameplayTagRequirements."
                    )

                    local confirmed,
                        confirm_err =
                            try_call(
                                function()
                                    return new_vm:ConfirmNewDatabankCharacter(
                                        make_empty_tag_requirements()
                                    )
                                end
                            )

                    if confirm_err ~= nil then
                        auto_import_fail(
                            "NATIVE IMPORT FAILED",
                            "ConfirmNewDatabankCharacter call failed: "
                                .. tostring(
                                    confirm_err
                                ),
                            new_vm
                        )
                        return
                    end

                    if confirmed ~= true then
                        auto_import_fail(
                            "NATIVE IMPORT FAILED",
                            "ConfirmNewDatabankCharacter returned "
                                .. tostring(
                                    confirmed
                                )
                                .. ".",
                            new_vm
                        )
                        return
                    end

                    log(
                        "NATIVE CREATE CONFIRMED: native ConfirmNewDatabankCharacter returned true."
                    )

                    verify_headless_created_character(
                        databank_vm,
                        payload,
                        baseline_identities,
                        1
                    )

                    return
                end

                ExecuteWithDelay(
                    100,
                    function()
                        wait_for_headless_draft_then_stage(
                            databank_vm,
                            new_vm,
                            payload,
                            baseline_identities,
                            attempt + 1,
                            current_count,
                            stable_checks
                        )
                    end
                )

                return
            elseif live_type ~= nil then
                auto_import_fail(
                    "NATIVE IMPORT FAILED",
                    "Native draft initialized as "
                        .. creator_name(live_type)
                        .. " instead of "
                        .. creator_name(payload.characterType)
                        .. ".",
                    new_vm
                )
                return
            elseif live_type_err ~= nil then
                log(
                    "NATIVE CREATE waiting for draft type/slot initialization: "
                        .. tostring(
                            live_type_err
                        )
                )
            end
        end

        if attempt >= 30 then
            auto_import_fail(
                "NATIVE IMPORT FAILED",
                "The native draft CharacterVM did not become ready within 3 seconds.",
                new_vm
            )
            return
        end

        ExecuteWithDelay(
            100,
            function()
                wait_for_headless_draft_then_stage(
                    databank_vm,
                    new_vm,
                    payload,
                    baseline_identities,
                    attempt + 1,
                    previous_slot_count,
                    stable_checks
                )
            end
        )
    end)
end

local function begin_new_import_stage(payload)
    safe_remove_popup()

    if payload == nil then
        show_notice_popup(
            "IMPORT FAILED",
            "No validated Character Share payload is pending.",
            3200
        )
        return
    end

    pending_import_payload =
        payload

    local databank_vm =
        find_first(
            "BrunoCharacterDatabankViewModel"
        )

    if databank_vm == nil then
        auto_import_fail(
            "NATIVE IMPORT FAILED",
            "Character Databank is not ready.",
            nil
        )
        return
    end

    local existing_new_vm,
        existing_active =
            active_new_character_session(
                databank_vm
            )

    if existing_active ~= nil then
        show_notice_popup(
            "NATIVE IMPORT BLOCKED",
            "A native Create New session is already active. Save or cancel it before importing this character.",
            4600
        )
        return
    end

    local baseline_identities =
        snapshot_type_pool_identities(
            databank_vm,
            payload.characterType
        )

    local baseline_count = 0

    for _,
        _ in pairs(
            baseline_identities
        ) do
        baseline_count =
            baseline_count + 1
    end

    log(
        string.format(
            "NATIVE CREATE START: '%s' -> %s; editor UI will not be opened. Baseline pool identities=%d.",
            payload_full_name(payload),
            creator_name(payload.characterType),
            baseline_count
        )
    )

    local _,
        create_err =
            try_call(
                function()
                    databank_vm:CreateNewDatabankCharacter()
                end
            )

    if create_err ~= nil then
        auto_import_fail(
            "NATIVE IMPORT FAILED",
            "CreateNewDatabankCharacter failed: "
                .. tostring(
                    create_err
                ),
            nil
        )
        return
    end

    local new_vm,
        new_vm_err =
            read_property(
                databank_vm,
                "DatabankNewCharacterVM"
            )

    if new_vm_err ~= nil
        or new_vm == nil then
        auto_import_fail(
            "NATIVE IMPORT FAILED",
            "DatabankNewCharacterVM was unavailable after CreateNewDatabankCharacter.",
            nil
        )
        return
    end

    local type_value =
        payload.characterType == "astromech"
            and 2
            or 1

    log(
        string.format(
            "NATIVE CREATE TYPE: SetDatabankCharacterType(%d) for %s.",
            type_value,
            creator_name(payload.characterType)
        )
    )

    local _,
        type_err =
            try_call(
                function()
                    new_vm:SetDatabankCharacterType(
                        type_value
                    )
                end
            )

    if type_err ~= nil then
        auto_import_fail(
            "NATIVE IMPORT FAILED",
            "SetDatabankCharacterType failed: "
                .. tostring(
                    type_err
                ),
            new_vm
        )
        return
    end

    wait_for_headless_draft_then_stage(
        databank_vm,
        new_vm,
        payload,
        baseline_identities,
        1,
        nil,
        0
    )
end

local function begin_overwrite_stage(payload, match)
    safe_remove_popup()

    local aux_vm =
        find_first(
            "CharacterBankAuxVM_C"
        )

    local databank_vm =
        find_first(
            "BrunoCharacterDatabankViewModel"
        )

    if aux_vm == nil
        or databank_vm == nil
        or match == nil
        or match.vm == nil then
        show_notice_popup(
            "OVERWRITE FAILED",
            "Character Databank overwrite state is not ready. No SavePoolCharacter call was made.",
            3800
        )
        return
    end

    local function fail(message)
        log(
            "NATIVE OVERWRITE FAILED: "
                .. tostring(
                    message
                )
        )

        show_notice_popup(
            "OVERWRITE FAILED",
            tostring(
                message
            ),
            5200
        )
    end

    local function payload_code_for_compare(candidate)
        if candidate == nil then
            return nil,
                "candidate payload is nil"
        end

        -- Codec.encode() returns:
        --   success: code, stats_table
        --   failure: nil, error_string
        --
        -- v0.3.0 incorrectly treated the second success value (stats_table)
        -- as an error, causing every verification code to become nil and
        -- forcing an unnecessary rollback even after SavePoolCharacter
        -- completed successfully.
        local code,
            stats_or_err =
                Codec.encode(
                    candidate
                )

        if code == nil then
            return nil,
                tostring(
                    stats_or_err
                )
        end

        return code,
            nil
    end

    local function begin_direct_saved_vm_overwrite()
        log(
            string.format(
                "NATIVE OVERWRITE START: '%s' -> existing %s '%s'; using the selected saved CharacterVM directly.",
                payload_full_name(payload),
                creator_name(payload.characterType),
                match.name or "<unnamed>"
            )
        )

        local _,
            select_err =
                try_call(
                    function()
                        match.vm:OnSelected()
                    end
                )

        if select_err ~= nil then
            fail(
                "Could not select the existing character: "
                    .. tostring(
                        select_err
                    )
            )
            return
        end

        local attempt =
            0

        local previous_slot_count =
            nil

        local stable_checks =
            0

        local function wait_for_selected_vm()
            attempt =
                attempt + 1

            ExecuteInGameThread(
                function()
                    local character_vm,
                        character_vm_err =
                            read_property(
                                aux_vm,
                                "CharacterVM"
                            )

                    if character_vm_err == nil
                        and character_vm ~= nil
                        and not is_in_progress_character_vm(
                            databank_vm,
                            character_vm
                        ) then
                        local live_type,
                            slot_count,
                            live_type_err =
                                detect_live_creator_type(
                                    character_vm
                                )

                        if live_type ~= nil
                            and live_type
                                ~= payload.characterType then
                            fail(
                                "Selected saved CharacterVM is "
                                    .. creator_name(
                                        live_type
                                    )
                                    .. " instead of "
                                    .. creator_name(
                                        payload.characterType
                                    )
                                    .. "."
                            )
                            return
                        end

                        if live_type
                            == payload.characterType then
                            local current_count =
                                slot_count or 0

                            if previous_slot_count
                                == current_count then
                                stable_checks =
                                    stable_checks + 1
                            else
                                stable_checks = 0
                            end

                            previous_slot_count =
                                current_count

                            if stable_checks >= 1 then
                                local selected_name =
                                    text_value(
                                        select(
                                            1,
                                            read_property(
                                                character_vm,
                                                "FullName"
                                            )
                                        )
                                    )

                                if selected_name ~= ""
                                    and match.name ~= nil
                                    and selected_name
                                        ~= match.name then
                                    fail(
                                        "Selection changed while preparing overwrite (expected '"
                                            .. tostring(
                                                match.name
                                            )
                                            .. "', got '"
                                            .. tostring(
                                                selected_name
                                            )
                                            .. "')."
                                    )
                                    return
                                end

                                log(
                                    string.format(
                                        "NATIVE OVERWRITE SAVED VM READY: %s (%d live slots) after %d check(s).",
                                        creator_name(
                                            live_type
                                        ),
                                        current_count,
                                        attempt
                                    )
                                )

                                -- Capture a complete rollback image before the
                                -- first mutation. This uses the same proven
                                -- saved-character capture path as Share/F7.
                                local original_payload =
                                    capture_selected_character_payload()

                                if original_payload == nil then
                                    fail(
                                        "Could not capture the existing character for rollback; overwrite was not attempted."
                                    )
                                    return
                                end

                                local original_code,
                                    original_code_err =
                                        payload_code_for_compare(
                                            original_payload
                                        )

                                local desired_code,
                                    desired_code_err =
                                        payload_code_for_compare(
                                            payload
                                        )

                                if original_code == nil then
                                    fail(
                                        "Could not encode the rollback payload for verification: "
                                            .. tostring(
                                                original_code_err
                                            )
                                    )
                                    return
                                end

                                if desired_code == nil then
                                    fail(
                                        "Could not encode the imported payload for verification: "
                                            .. tostring(
                                                desired_code_err
                                            )
                                    )
                                    return
                                end

                                local function rollback_and_resave(
                                    reason
                                )
                                    log(
                                        "NATIVE OVERWRITE ROLLBACK START: "
                                            .. tostring(
                                                reason
                                            )
                                    )

                                    local rolled_back,
                                        rollback_err =
                                            stage_payload_to_character_vm(
                                                original_payload,
                                                character_vm,
                                                "NATIVE OVERWRITE ROLLBACK"
                                            )

                                    if not rolled_back then
                                        log(
                                            "NATIVE OVERWRITE ROLLBACK FAILED: "
                                                .. tostring(
                                                    rollback_err
                                                )
                                        )
                                        return false
                                    end

                                    local _,
                                        restore_save_err =
                                            try_call(
                                                function()
                                                    databank_vm:SavePoolCharacter(
                                                        match.vm,
                                                        make_empty_tag_requirements()
                                                    )
                                                end
                                            )

                                    if restore_save_err ~= nil then
                                        log(
                                            "NATIVE OVERWRITE ROLLBACK SAVE FAILED: "
                                                .. tostring(
                                                    restore_save_err
                                                )
                                        )
                                        return false
                                    end

                                    log(
                                        "NATIVE OVERWRITE ROLLBACK COMPLETE."
                                    )

                                    return true
                                end

                                local staged,
                                    stage_err =
                                        stage_payload_to_character_vm(
                                            payload,
                                            character_vm,
                                            "NATIVE OVERWRITE"
                                        )

                                if not staged then
                                    rollback_and_resave(
                                        "import staging failed"
                                    )

                                    fail(
                                        "Direct saved-character staging failed: "
                                            .. tostring(
                                                stage_err
                                            )
                                    )
                                    return
                                end

                                log(
                                    "NATIVE OVERWRITE STAGED: selected saved CharacterVM matches the imported payload; calling SavePoolCharacter(existingVM, empty GameplayTagRequirements)."
                                )

                                local _,
                                    save_err =
                                        try_call(
                                            function()
                                                databank_vm:SavePoolCharacter(
                                                    match.vm,
                                                    make_empty_tag_requirements()
                                                )
                                            end
                                        )

                                if save_err ~= nil then
                                    rollback_and_resave(
                                        "SavePoolCharacter call failed"
                                    )

                                    fail(
                                        "SavePoolCharacter failed: "
                                            .. tostring(
                                                save_err
                                            )
                                    )
                                    return
                                end

                                log(
                                    "NATIVE OVERWRITE SAVE CALL COMPLETE: native SavePoolCharacter returned without an exposed error."
                                )

                                -- Re-select through the PoolCharacterVM and
                                -- recapture through the normal Share path. This
                                -- is not a disk-reload proof, but it does verify
                                -- that the Databank's selected saved model still
                                -- resolves to the imported state after Save.
                                ExecuteWithDelay(
                                    150,
                                    function()
                                        ExecuteInGameThread(
                                            function()
                                                try_call(
                                                    function()
                                                        match.vm:OnSelected()
                                                    end
                                                )

                                                local saved_payload =
                                                    capture_selected_character_payload()

                                                local saved_code,
                                                    saved_code_err =
                                                        payload_code_for_compare(
                                                            saved_payload
                                                        )

                                                if saved_code == nil then
                                                    log(
                                                        "NATIVE OVERWRITE VERIFY ENCODE FAILED: "
                                                            .. tostring(
                                                                saved_code_err
                                                            )
                                                    )
                                                end

                                                if saved_code ~= nil
                                                    and saved_code
                                                        == desired_code then
                                                    log(
                                                        "NATIVE OVERWRITE VERIFIED: re-selected saved CharacterVM exactly matches the imported payload after SavePoolCharacter."
                                                    )

                                                    clear_pending_import()

                                                    show_notice_popup(
                                                        "OVERWRITE COMPLETE",
                                                        string.format(
                                                            "%s was overwritten successfully.",
                                                            payload_full_name(payload)
                                                        ),
                                                        6200
                                                    )

                                                    return
                                                end

                                                local restored =
                                                    rollback_and_resave(
                                                        "post-save verification mismatch"
                                                    )

                                                log(
                                                    string.format(
                                                        "NATIVE OVERWRITE VERIFY FAILED: desiredCode=%s savedCode=%s rollback=%s originalCode=%s",
                                                        tostring(
                                                            desired_code
                                                        ),
                                                        tostring(
                                                            saved_code
                                                        ),
                                                        tostring(
                                                            restored
                                                        ),
                                                        tostring(
                                                            original_code
                                                        )
                                                    )
                                                )

                                                fail(
                                                    "SavePoolCharacter returned, but the re-selected saved character did not match the imported payload. The branch attempted to restore the original character."
                                                )
                                            end
                                        )
                                    end
                                )

                                return
                            end
                        elseif live_type_err ~= nil then
                            log(
                                "NATIVE OVERWRITE waiting for selected saved VM type/slots: "
                                    .. tostring(
                                        live_type_err
                                    )
                            )
                        end
                    end

                    if attempt < 30 then
                        ExecuteWithDelay(
                            100,
                            wait_for_selected_vm
                        )
                    else
                        fail(
                            "The selected saved CharacterVM did not become ready."
                        )
                    end
                end
            )
        end

        ExecuteWithDelay(
            50,
            wait_for_selected_vm
        )
    end

    close_active_new_character_before_overwrite(
        databank_vm,
        begin_direct_saved_vm_overwrite,
        function(reason)
            fail(
                tostring(
                    reason
                )
            )
        end
    )
end

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

local function databank_widget_identity(widget)
    return popup_widget_identity(widget)
end

local function object_class_full_name(object)
    if object == nil then
        return nil
    end

    local class_object, class_err = try_call(function()
        return object:GetClass()
    end)

    if class_err ~= nil or class_object == nil then
        return nil
    end

    local class_name, name_err = try_call(function()
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
        databank_widget_identity(widget)

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
            unwrap_hook_value(
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

local function find_live_databank_master()
    local master =
        current_databank_host()

    if databank_master_is_attached_and_visible(master) then
        return master
    end

    return nil
end

local function page_widget_property(page, property_name)
    local value, value_err =
        read_property(
            page,
            property_name
        )

    local widget =
        unwrap_hook_value(value)

    if value_err ~= nil then
        return nil, value_err
    end

    return widget, nil
end

local function widget_parent(widget)
    if widget == nil then
        return nil
    end

    local parent, parent_err = try_call(function()
        return unwrap_hook_value(
            widget:GetParent()
        )
    end)

    if parent_err ~= nil then
        return nil
    end

    return parent
end

local function panel_child_index(parent, child)
    if parent == nil or child == nil then
        return -1
    end

    local index, index_err = try_call(function()
        return parent:GetChildIndex(child)
    end)

    if index_err ~= nil or index == nil then
        return -1
    end

    return tonumber(index) or -1
end

local function verified_anchor_parent(anchor)
    if anchor == nil then
        return nil, -1
    end

    local parent =
        widget_parent(anchor)

    if parent == nil then
        return nil, -1
    end

    local index =
        panel_child_index(
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
        read_property(
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
        unwrap_hook_value(
            select(
                1,
                read_property(
                    widget,
                    "RenderTransform"
                )
            )
        )

    if transform == nil then
        return 0.0, 0.0
    end

    local translation =
        unwrap_hook_value(
            select(
                1,
                read_property(
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

    local _, set_err = try_call(function()
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
        unwrap_hook_value(
            select(
                1,
                read_property(
                    widget,
                    "Slot"
                )
            )
        )

    if slot ~= nil then
        local padding =
            unwrap_hook_value(
                select(
                    1,
                    read_property(
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

local function visually_move_appended_child_to_index(
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

    count, count_err = try_call(function()
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
        panel_child_index(
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

        sibling, child_err = try_call(function()
            return unwrap_hook_value(
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

    log(
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

local function set_databank_button_text(
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
        unwrap_hook_value(
            select(
                1,
                read_property(
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


CharacterShareLayout =
    CharacterShareLayout or {}

function CharacterShareLayout.create_user_widget_like(
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
            try_call(function()
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
            load_class(
                "/Script/UMG.WidgetBlueprintLibrary"
            )

    if library_class_err ~= nil
        or library_class == nil then
        return nil,
            "WidgetBlueprintLibrary unavailable"
    end

    local library,
        library_err =
            try_call(function()
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
            try_call(function()
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

    log(
        "Databank native-style clone created: template="
            .. dialog_widget_class_name(template)
            .. " clone="
            .. dialog_widget_class_name(widget)
    )

    return widget, nil
end

function CharacterShareLayout.capture_box_slot_layout(
    child
)
    local layout = {}

    if child == nil then
        return layout
    end

    local slot =
        unwrap_hook_value(
            select(
                1,
                read_property(
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
                    read_property(
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

function CharacterShareLayout.apply_box_slot_layout(
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

function CharacterShareLayout.horizontal_fill(
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


function CharacterShareLayout.collect_widget_tree(
    user_widget
)
    local widgets = {}

    if user_widget == nil then
        return widgets
    end

    local tree =
        unwrap_hook_value(
            select(
                1,
                read_property(
                    user_widget,
                    "WidgetTree"
                )
            )
        )

    if tree == nil then
        return widgets
    end

    local root =
        unwrap_hook_value(
            select(
                1,
                read_property(
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
                    unwrap_hook_value(
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

function CharacterShareLayout.set_clone_label(
    button,
    label
)
    local changed = 0

    for _,
        widget in ipairs(
            CharacterShareLayout
                .collect_widget_tree(
                    button
                )
        ) do
        local class_name =
            dialog_widget_class_name(
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

    log(
        string.format(
            "Databank clone label update: label=%s descendantsChanged=%d",
            tostring(label),
            changed
        )
    )

    return changed > 0
end

function CharacterShareLayout.hide_single_clone_image(
    button
)
    local images = {}

    for _,
        widget in ipairs(
            CharacterShareLayout
                .collect_widget_tree(
                    button
                )
        ) do
        if dialog_widget_class_name(
            widget
        ):find(
            "Image",
            1,
            true
        ) ~= nil then
            table.insert(
                images,
                widget
            )
        end
    end

    if #images ~= 1 then
        log(
            "Databank clone image substitution skipped: imageCount="
                .. tostring(#images)
        )
        return false
    end

    pcall(function()
        images[1]:SetVisibility(1)
        images[1]:SetRenderOpacity(0.0)
    end)

    log(
        "Databank clone's single native image hidden for import-glyph label."
    )

    return true
end

function CharacterShareLayout.initialize_share_visual(
    button
)
    if button == nil then
        return false
    end

    -- v0.7.40-probe established the native Databank contract on both character
    -- pages: orientation=1, size=0, type=0. v0.7.41 directly manipulated the
    -- clone's ButtonSwitcher/SelectedButton. That path is unnecessary and is
    -- deliberately avoided here. Set only the clone's scalar style properties,
    -- then ask the widget's own parameterless Blueprint ApplyStyle() routine to
    -- resolve its internal visual exactly as the game does.
    local _, apply_err = try_call(function()
        button.ButtonOrientation = 1
        button.ButtonSize = 0
        button.ButtonType = 0
        button:ApplyStyle()
    end)

    if apply_err ~= nil then
        log(
            "Databank SHARE native ApplyStyle orientation failed; leaving current visual: "
                .. tostring(apply_err)
        )
    else
        log(
            "Databank SHARE native ApplyStyle completed for orientation=1 size=0 type=0."
        )
    end

    -- Apply the label after style resolution because ApplyStyle may switch the
    -- concrete child that owns the visible text.
    CharacterShareLayout.set_clone_label(
        button,
        "SHARE"
    )

    return apply_err == nil
end

function CharacterShareLayout.polish_action_row(
    page,
    share_button
)
    -- Intentionally a no-op for native controls. Their cooked Databank style
    -- is already correct; Character Share must not switch their ButtonSwitcher
    -- to the dialog-only Long family.
    if page ~= nil
        and share_button ~= nil then
        log(
            "Databank native action buttons preserved unchanged; SHARE remains on its cloned class-default visual."
        )
    end
end


function CharacterShareLayout.widget_local_width(
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

function CharacterShareLayout.make_width_wrapper(
    owner,
    child,
    object_name,
    width
)
    local wrapper,
        wrapper_err =
            construct_native_widget(
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
        unwrap_hook_value(
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

function CharacterShareLayout.configure_row_slot(
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

function CharacterShareLayout.install_import_glyph(
    button
)
    if button == nil then
        return false
    end

    local image_hidden =
        CharacterShareLayout
            .hide_single_clone_image(
                button
            )

    local label_changed =
        CharacterShareLayout
            .set_clone_label(
                button,
                "⇩  IMPORT"
            )

    log(
        string.format(
            "Databank IMPORT visual initialized: label=%s inheritedPlusHidden=%s",
            tostring(label_changed),
            tostring(image_hidden)
        )
    )

    return label_changed
end

local function create_unregistered_databank_button(
    page,
    object_name
)
    local button, button_err =
        create_user_widget(
            page,
            UI.DATABANK_TOPNAV_BUTTON_CLASS_PATH
        )

    if button_err ~= nil or button == nil then
        log(
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
    label
)
    local identity =
        databank_widget_identity(button)

    databank_ui_state.buttons[identity] = {
        action = action,
        label = label,
    }

    -- No delayed label callback: this UI is deliberately screen-scoped.
    set_databank_button_text(
        button,
        label
    )

    log(
        string.format(
            "Databank button attached+registered: %s -> %s",
            identity,
            action
        )
    )
end

local function install_import_button(
    page,
    page_state
)
    if page_state.importInstalled then
        return true
    end

    local create_new =
        select(
            1,
            page_widget_property(
                page,
                "WBP_CharacterBankCreateNewBtn"
            )
        )

    if create_new == nil then
        log(
            "Databank IMPORT not ready: WBP_CharacterBankCreateNewBtn unavailable."
        )
        return false
    end

    local parent,
        create_index =
            verified_anchor_parent(
                create_new
            )

    if parent == nil then
        log(
            "Databank IMPORT not ready: live Create New parent unavailable."
        )
        return false
    end

    -- Capture only Create New's own native slot. Older revisions snapshotted,
    -- cleared, and rebuilt this entire parent to replace one child. On first
    -- Databank entry that could detach/re-add the live character-list widget
    -- while CommonUI was still establishing its selection state. Keep every
    -- unrelated native sibling permanently attached instead.
    local create_layout =
        CharacterShareLayout
            .capture_box_slot_layout(
                create_new
            )

    local import_button,
        import_err =
            CharacterShareLayout
                .create_user_widget_like(
                    page,
                    create_new,
                    "CharacterShare_ImportButton"
                )

    if import_button == nil then
        log(
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

    local row,
        row_err =
            construct_native_widget(
                page,
                "/Script/UMG.HorizontalBox",
                "CharacterShare_CreateImportRow"
            )

    if row == nil then
        log(
            "Databank IMPORT row creation failed: "
                .. tostring(row_err)
        )
        return false
    end

    local original_width =
        CharacterShareLayout
            .widget_local_width(
                create_new
            )

    -- 700 is only a last-resort design-unit fallback. On the normal game UI,
    -- CachedGeometry should give us the actual allocated Create New width.
    if original_width == nil
        or original_width < 200.0 then
        original_width = 700.0
        log(
            "Databank IMPORT width measurement unavailable; using 700 design-unit fallback."
        )
    end

    local gap = 8.0
    local half_width =
        math.max(
            120.0,
            (
                original_width
                    - gap
            ) / 2.0
        )

    log(
        string.format(
            "Databank IMPORT row width: original=%.1f gap=%.1f half=%.1f",
            original_width,
            gap,
            half_width
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
                try_call(function()
                    return parent:AddChild(
                        create_new
                    )
                end)

        restored_slot =
            unwrap_hook_value(
                restored_slot
            )

        if restore_err == nil
            and restored_slot ~= nil then
            CharacterShareLayout
                .apply_box_slot_layout(
                    restored_slot,
                    create_layout
                )

            local restored_visual,
                visual_err =
                    visually_move_appended_child_to_index(
                        parent,
                        create_new,
                        create_index,
                        "vertical"
                    )

            if not restored_visual then
                log(
                    "Databank IMPORT rollback could not visually restore Create New order: "
                        .. tostring(visual_err)
                )
            end
        end

        log(
            string.format(
                "Databank IMPORT localized rollback after %s: createIndex=%d physicalIndex=%d",
                tostring(reason),
                create_index,
                panel_child_index(
                    parent,
                    create_new
                )
            )
        )
    end

    local removed,
        remove_err =
            try_call(function()
                return parent:RemoveChild(
                    create_new
                )
            end)

    if remove_err ~= nil
        or not removed then
        log(
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
            CharacterShareLayout
                .make_width_wrapper(
                    page,
                    create_new,
                    "CharacterShare_CreateNewHalf",
                    half_width
                )

    import_wrapper,
        import_wrapper_slot,
        import_wrap_err =
            CharacterShareLayout
                .make_width_wrapper(
                    page,
                    import_button,
                    "CharacterShare_ImportHalf",
                    half_width
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
            try_call(function()
                return row:AddChild(
                    create_wrapper
                )
            end)

    local import_slot,
        import_add_err =
            try_call(function()
                return row:AddChild(
                    import_wrapper
                )
            end)

    create_slot =
        unwrap_hook_value(
            create_slot
        )

    import_slot =
        unwrap_hook_value(
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

    CharacterShareLayout
        .configure_row_slot(
            create_slot,
            0.0
        )

    CharacterShareLayout
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
            try_call(function()
                return parent:AddChild(
                    row
                )
            end)

    row_slot =
        unwrap_hook_value(
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

    CharacterShareLayout
        .apply_box_slot_layout(
            row_slot,
            create_layout
        )

    local moved,
        move_err =
            visually_move_appended_child_to_index(
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

    register_attached_databank_button(
        import_button,
        "databank_import",
        "IMPORT"
    )

    CharacterShareLayout
        .install_import_glyph(
            import_button
        )

    page_state.importInstalled = true
    page_state.importRow = row

    log(
        string.format(
            "Databank IMPORT installed beside Create New using append+visual rotation only (character-list parent never rebuilt, original index=%d).",
            create_index
        )
    )

    return true
end

local function install_share_button(
    page,
    page_state
)
    if page_state.shareInstalled then
        return true
    end

    local edit =
        select(
            1,
            page_widget_property(
                page,
                "Button_Edit"
            )
        )

    if edit == nil then
        log(
            "Databank SHARE not ready: native Edit button unavailable."
        )
        return false
    end

    local parent,
        edit_index =
            verified_anchor_parent(
                edit
            )

    if parent == nil then
        log(
            "Databank SHARE not ready: live native action-row parent unavailable."
        )
        return false
    end

    local edit_layout =
        CharacterShareLayout
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
            try_call(function()
                return unwrap_hook_value(
                    parent:GetChildAt(
                        edit_index + 1
                    )
                )
            end)

    if next_child_err == nil
        and next_child ~= nil
        and dialog_widget_class_name(
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
                        unwrap_hook_value(
                            parent:GetChildAt(
                                index
                            )
                        )
                end)

                if candidate ~= nil
                    and dialog_widget_class_name(
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
            CharacterShareLayout
                .capture_box_slot_layout(
                    native_spacer
                )

        local size_value,
            size_err =
                read_property(
                    native_spacer,
                    "Size"
                )

        if size_err == nil then
            native_spacer_size =
                unwrap_hook_value(
                    size_value
                )
        end
    end

    local share_button,
        share_err =
            CharacterShareLayout
                .create_user_widget_like(
                    page,
                    edit,
                    "CharacterShare_ShareButton"
                )

    if share_button == nil then
        log(
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
                construct_native_widget(
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
                    try_call(function()
                        return parent:AddChild(
                            spacer
                        )
                    end)

            spacer_slot =
                unwrap_hook_value(
                    spacer_slot
                )

            if spacer_add_err == nil
                and spacer_slot ~= nil then
                CharacterShareLayout
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

                log(
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

                log(
                    "Databank SHARE native spacer append failed; continuing without extra spacing: "
                        .. tostring(spacer_add_err)
                )
            end
        else
            log(
                "Databank SHARE native spacer clone failed; continuing without extra spacing: "
                    .. tostring(spacer_err)
            )
        end
    else
        log(
            "Databank SHARE native spacer unavailable; continuing without extra spacing."
        )
    end

    local share_slot,
        add_err =
            try_call(function()
                return parent:AddChild(
                    share_button
                )
            end)

    share_slot =
        unwrap_hook_value(
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

        log(
            "Databank SHARE append failed; native action row left untouched: "
                .. tostring(add_err)
        )

        return false
    end

    CharacterShareLayout
        .apply_box_slot_layout(
            share_slot,
            edit_layout
        )

    register_attached_databank_button(
        share_button,
        "databank_share",
        "SHARE"
    )

    CharacterShareLayout
        .initialize_share_visual(
            share_button
        )

    CharacterShareLayout
        .polish_action_row(
            page,
            share_button
        )

    -- Keep SHARE at the native AddChild append position on the far right.
    -- This avoids reordering or translating any native action-row children.
    page_state.shareInstalled = true
    page_state.shareButton = share_button
    page_state.shareSpacer = share_spacer

    log(
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
        databank_widget_identity(page)

    local page_state =
        databank_ui_state.installedPages[page_identity]

    if page_state == nil then
        page_state = {
            importInstalled = false,
            shareInstalled = false,
            shareButton = nil,
            importRow = nil,
        }

        databank_ui_state.installedPages[page_identity] =
            page_state
    end

    local import_ok =
        install_import_button(
            page,
            page_state
        )

    local share_ok =
        install_share_button(
            page,
            page_state
        )

    log(
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
                page_widget_property(
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

local function install_databank_ui_for_active_master(
    master,
    generation
)
    if generation ~= databank_ui_state.generation then
        return
    end

    if databank_ui_state.activeMaster ~= master then
        return
    end

    local pages =
        databank_pages(master)

    log(
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
        databank_session_active = true

        log(
            "Character Databank UI integration complete; controls are persistent for this runtime Databank master."
        )
        return
    end

    -- One guarded retry only, scoped to this exact activation generation.
    ExecuteWithDelay(100, function()
        if generation ~= databank_ui_state.generation then
            return
        end

        ExecuteInGameThread(function()
            if generation ~= databank_ui_state.generation
                or databank_ui_state.activeMaster ~= master then
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

            log(
                string.format(
                    "Character Databank guarded UI retry complete=%s.",
                    tostring(
                        retry_complete
                            and #retry_pages > 0
                    )
                )
            )
        end)
    end)
end

local function leave_databank_session(reason)
    -- Zero Company reuses the same Character Databank widget instance when the
    -- player backs out and later re-enters it. Therefore the injected children
    -- remain in that WidgetTree too.
    --
    -- Preserve the string action mappings + per-page installed flags here.
    -- Clearing them would cause a second set of IMPORT/SHARE controls to be
    -- appended on the next entry.
    databank_ui_state.generation =
        databank_ui_state.generation + 1

    databank_ui_state.activeMaster = nil
    databank_ui_state.activeMasterIdentity = nil
    databank_ui_state.shareDispatchPending = false
    databank_ui_state.importDispatchPending = false
    databank_session_active = false

    log(
        "Character Databank session paused; preserving installed controls for reusable screen. reason="
            .. tostring(reason or "navigation")
    )
end

local function reset_databank_install_state_for_new_master(
    new_master_identity
)
    local mapped = 0

    for _ in pairs(
        databank_ui_state.buttons
    ) do
        mapped = mapped + 1
    end

    databank_ui_state.generation =
        databank_ui_state.generation + 1

    -- Only Lua-owned strings/booleans are discarded. Never touch widgets from
    -- the previous screen here; Unreal may already be tearing them down.
    databank_ui_state.buttons = {}
    databank_ui_state.installedPages = {}
    databank_ui_state.installedMasterIdentity =
        new_master_identity
    databank_ui_state.activeMaster = nil
    databank_ui_state.activeMasterIdentity = nil
    databank_ui_state.shareDispatchPending = false
    databank_ui_state.importDispatchPending = false
    databank_session_active = false

    log(
        string.format(
            "Character Databank install state reset for new runtime master; released %d stale mapping(s).",
            mapped
        )
    )
end

local function runtime_databank_master_candidate()
    -- FindFirstOf may observe the runtime master while CommonUI is still
    -- transitioning it into the hierarchy. Keep the attached/visible checks,
    -- but do NOT call CommonActivatableWidget:IsActivated() here. The native
    -- access violation seen in v0.7.38 and v0.7.41 happened before the success
    -- log, inside this bounded entry check; a native AV is not catchable by Lua
    -- pcall. Attached + visible, followed by a second stable observation below,
    -- is sufficient readiness for the non-destructive v0.7.36+ UI insertion.
    return find_live_databank_master()
end

local function begin_databank_session(master)
    if master == nil then
        return
    end

    local master_identity =
        databank_widget_identity(master)

    if master_identity == nil then
        return
    end

    local same_installed_master =
        databank_ui_state.installedMasterIdentity
            == master_identity

    if not same_installed_master then
        reset_databank_install_state_for_new_master(
            master_identity
        )
    else
        log(
            "Character Databank reusable runtime master detected; adopting existing Character Share controls."
        )
    end

    databank_ui_state.generation =
        databank_ui_state.generation + 1

    databank_ui_state.activeMaster = master
    databank_ui_state.activeMasterIdentity =
        master_identity
    databank_session_active = true

    local generation =
        databank_ui_state.generation

    log(
        "Character Databank ENTER confirmed after main-menu click: "
            .. tostring(master_identity)
    )

    -- Safe to run on both first entry and re-entry. install_databank_page_ui()
    -- is keyed by persistent page identity and returns true immediately when
    -- that page already received its controls.
    install_databank_ui_for_active_master(
        master,
        generation
    )
end

local function probe_for_databank_after_menu_click(
    probe_generation,
    attempt
)
    if probe_generation
        ~= databank_entry_probe_generation then
        return
    end

    local master =
        runtime_databank_master_candidate()

    if master ~= nil then
        local candidate_identity =
            databank_widget_identity(master)

        if candidate_identity ~= nil
            and candidate_identity == databank_entry_probe_candidate_identity then
            log(
                string.format(
                    "Databank entry probe stabilized on attempt %d; beginning UI integration.",
                    attempt
                )
            )

            databank_entry_probe_candidate_identity = nil

            begin_databank_session(
                master
            )

            return
        end

        databank_entry_probe_candidate_identity =
            candidate_identity

        log(
            string.format(
                "Databank entry probe observed live candidate on attempt %d; waiting for one stable re-observation.",
                attempt
            )
        )
    else
        databank_entry_probe_candidate_identity = nil
    end

    if attempt >= 6 then
        log(
            "Databank entry probe ended: clicked submenu did not open Character Databank."
        )
        return
    end

    local delays = {
        150,
        150,
        200,
        300,
        450,
        650,
    }

    local delay =
        delays[attempt + 1] or 250

    ExecuteWithDelay(delay, function()
        if probe_generation
            ~= databank_entry_probe_generation then
            return
        end

        ExecuteInGameThread(function()
            probe_for_databank_after_menu_click(
                probe_generation,
                attempt + 1
            )
        end)
    end)
end

local function handle_strategy_submenu_click(button)
    if button == nil then
        return
    end

    local identity =
        databank_widget_identity(button)

    if identity == nil
        or not string.find(
            identity,
            "WBP_AnimatedSubMenuListButton_C",
            1,
            true
        ) then
        return
    end

    -- The game reuses the Character Databank widget after backing out. Keep
    -- its action mappings/install flags across Strategy navigation so returning
    -- to the same runtime master adopts the existing controls instead of
    -- appending another set.
    if databank_session_active then
        leave_databank_session(
            "Strategy submenu navigation"
        )
    end

    -- Probe v0.2.0 proved that Character Databank is entered through this
    -- stable CommonUI button family. We do not need to know which dynamic-list
    -- instance number corresponds to Databank: every submenu click gets a tiny,
    -- bounded post-navigation check, and only the real Databank can satisfy it.
    databank_entry_probe_generation =
        databank_entry_probe_generation + 1

    local probe_generation =
        databank_entry_probe_generation

    databank_entry_probe_candidate_identity = nil

    log(
        "Strategy submenu click detected; starting bounded Character Databank entry check."
    )

    ExecuteWithDelay(150, function()
        if probe_generation
            ~= databank_entry_probe_generation then
            return
        end

        ExecuteInGameThread(function()
            probe_for_databank_after_menu_click(
                probe_generation,
                1
            )
        end)
    end)
end

local function handle_popup_topnav_action(
    button
)
    if button == nil
        or popup_state.widget == nil then
        return false
    end

    local identity =
        databank_widget_identity(button)

    local action =
        popup_state.customActions[identity]

    if action == nil then
        return false
    end

    local widget =
        popup_state.widget

    local captured_import =
        popup_state.capturedImportCode

    local captured_first =
        popup_state.capturedRenameFirst

    local captured_last =
        popup_state.capturedRenameLast

    if popup_state.mode == "import" then
        captured_import =
            read_text_box_value(
                popup_state.textBox
            )
    elseif popup_state.mode == "rename" then
        captured_first =
            read_text_box_value(
                popup_state.renameFirstBox
            )

        captured_last =
            read_text_box_value(
                popup_state.renameLastBox
            )
    end

    local captured_context =
        popup_state.context

    log(
        string.format(
            "Popup TopNav click: %s -> %s",
            identity,
            tostring(action)
        )
    )

    -- These are our buttons, not descriptor result buttons. Suppress the
    -- BP_OnHideDialog result path and close/deactivate the popup ourselves.
    popup_state.suppressResult = true

    detach_character_share_content(
        widget
    )

    local _, close_err = try_call(function()
        widget:OnCloseWindow()
    end)

    if close_err ~= nil then
        log(
            "Popup TopNav native close warning: "
                .. tostring(close_err)
        )
    end

    pcall(function()
        widget:DeactivateWidget()
    end)

    reset_popup_state()

    -- Give CommonUI one short native-outro window before opening the next
    -- Character Share dialog or entering the game's native Edit flow.
    ExecuteWithDelay(120, function()
        ExecuteInGameThread(function()
            popup_state.capturedImportCode =
                captured_import

            popup_state.capturedRenameFirst =
                captured_first

            popup_state.capturedRenameLast =
                captured_last

            popup_state.context =
                captured_context

            log(
                "Popup TopNav dispatch after native close: "
                    .. tostring(action)
            )

            if dispatch_popup_action ~= nil then
                dispatch_popup_action(
                    action
                )
            end
        end)
    end)

    return true
end

local function handle_databank_button_click(
    button_value
)
    local button =
        unwrap_hook_value(button_value)

    if button == nil then
        return
    end

    if handle_popup_topnav_action(
        button
    ) then
        return
    end

    -- The Character Databank entry point itself is a
    -- WBP_AnimatedSubMenuListButton_C. Probe that click first.
    handle_strategy_submenu_click(
        button
    )

    local identity =
        databank_widget_identity(button)

    local entry =
        databank_ui_state.buttons[identity]

    if identity ~= nil
        and string.find(
            identity,
            "WBP_CharacterDataBank_TopNavButton_C",
            1,
            true
        ) then
        log(
            string.format(
                "Databank TopNav click observed: mapped=%s identity=%s",
                tostring(entry ~= nil),
                tostring(identity)
            )
        )
    end

    if entry == nil then
        return
    end

    log(
        string.format(
            "Databank button clicked: %s -> %s",
            entry.label,
            entry.action
        )
    )

    if entry.action == "databank_import" then
        -- The injected IMPORT control is a cloned native Databank button and,
        -- like WBP_BoundActionButton, still has native click work to finish
        -- after CommonButtonBase:HandleButtonClicked enters this hook. Opening
        -- a pooled CommonUI modal synchronously from that hook was normally
        -- tolerated, but the error-code stress pass eventually crashed inside
        -- UE4SS immediately after IMPORT SESSION and before the popup could be
        -- constructed. Defer the entire modal/session transition one tick so
        -- the native click can unwind first.
        if databank_ui_state.importDispatchPending then
            log(
                "Databank IMPORT click ignored: deferred dispatch already pending."
            )
            return
        end

        databank_ui_state.importDispatchPending = true

        local expected_generation =
            databank_ui_state.generation
        local expected_identity = identity

        log(
            "Databank IMPORT queued until native button click unwinds."
        )

        ExecuteWithDelay(1, function()
            ExecuteInGameThread(function()
                databank_ui_state.importDispatchPending = false

                if expected_generation
                    ~= databank_ui_state.generation then
                    log(
                        "Databank IMPORT deferred dispatch cancelled: Databank generation changed."
                    )
                    return
                end

                local current_entry =
                    databank_ui_state.buttons[
                        expected_identity
                    ]

                if current_entry == nil
                    or current_entry.action
                        ~= "databank_import" then
                    log(
                        "Databank IMPORT deferred dispatch cancelled: button mapping is no longer live."
                    )
                    return
                end

                if popup_is_open() then
                    safe_remove_popup()
                end

                clear_pending_import()

                log(
                    "Databank IMPORT dispatch after native click unwind."
                )
                log(
                    "IMPORT SESSION: Databank Import button started a fresh session."
                )

                show_import_popup()
            end)
        end)
    elseif entry.action == "databank_share" then
        -- WBP_BoundActionButton runs additional native work after
        -- CommonButtonBase:HandleButtonClicked returns. Opening the Character
        -- Share modal from inside this hook changes CommonUI focus/layer state
        -- while that native click is still unwinding; v0.7.43's log reaches
        -- EXPORT COMPLETE and then the process dies before another Lua line.
        --
        -- Keep the now-correct native-looking SHARE button, but defer the
        -- export/modal work to the next tick so the BoundActionButton click can
        -- finish first. The pending flag prevents a double-click from queuing
        -- two share dialogs during that tiny window.
        if databank_ui_state.shareDispatchPending then
            log(
                "Databank SHARE click ignored: deferred dispatch already pending."
            )
            return
        end

        databank_ui_state.shareDispatchPending = true

        local expected_generation =
            databank_ui_state.generation
        local expected_identity = identity

        log(
            "Databank SHARE queued until native BoundActionButton click unwinds."
        )

        ExecuteWithDelay(1, function()
            ExecuteInGameThread(function()
                databank_ui_state.shareDispatchPending = false

                if expected_generation
                    ~= databank_ui_state.generation then
                    log(
                        "Databank SHARE deferred dispatch cancelled: Databank generation changed."
                    )
                    return
                end

                local current_entry =
                    databank_ui_state.buttons[
                        expected_identity
                    ]

                if current_entry == nil
                    or current_entry.action
                        ~= "databank_share" then
                    log(
                        "Databank SHARE deferred dispatch cancelled: button mapping is no longer live."
                    )
                    return
                end

                if popup_is_open() then
                    safe_remove_popup()
                end

                log(
                    "Databank SHARE dispatch after native click unwind."
                )

                export_selected_character()
            end)
        end)
    end
end

local function register_databank_click_hook()
    if databank_button_click_hook_registered then
        return true
    end

    local hook_ok, hook_err = pcall(function()
        RegisterHook(
            "/Script/CommonUI.CommonButtonBase:HandleButtonClicked",
            function(self)
                handle_databank_button_click(self)
            end
        )
    end)

    if not hook_ok then
        log(
            "WARNING: Character Databank button click hook failed: "
                .. tostring(hook_err)
        )
        return false
    end

    databank_button_click_hook_registered = true

    log(
        "Character Databank button click hook registered."
    )

    return true
end

local function handle_export_key()
    if popup_is_open("share") then
        safe_remove_popup()
        log("Share popup closed.")
        return
    end

    export_selected_character()
end

local function validate_import_popup()
    local code = code_from_import_popup()
    if code == nil then
        log("IMPORT PREFLIGHT FAILED: dialog contains no ZC1 character code")
        show_notice_popup(
            "INVALID SHARE CODE",
            "Paste a ZC1 character code, then choose Validate.",
            0
        )
        return
    end

    local payload, duplicate_matches, duplicate_unreadable =
        import_preflight()

    if payload == nil then
        return
    end

    pending_import_payload = payload

    -- If Rename was already chosen and a matching Create New editor is open,
    -- Validate should reflect the name the player is actually looking at in
    -- that creator. This prevents an earlier name such as "Tal Rea5" from
    -- becoming sticky after the player changes it again manually.
    local databank_vm =
        find_first(
            "BrunoCharacterDatabankViewModel"
        )

    local active_creator_vm = nil
    local active_creator_err = nil

    if pending_name_override ~= nil
        and databank_vm ~= nil then
        active_creator_vm, active_creator_err =
            matching_active_new_character_vm(
                databank_vm,
                payload.characterType
            )

        if active_creator_vm ~= nil
            and adopt_manual_creator_name(
                payload,
                active_creator_vm,
                "IMPORT VALIDATE"
            ) then
            duplicate_matches,
            duplicate_unreadable =
                find_duplicate_characters(
                    databank_vm,
                    payload
                )

            log_duplicate_summary(
                duplicate_matches,
                duplicate_unreadable,
                payload
            )
        elseif active_creator_vm == nil then
            log(
                "IMPORT VALIDATE name sync skipped: "
                    .. tostring(active_creator_err)
            )
        end
    end

    pending_import_payload = payload
    safe_remove_popup()

    if duplicate_matches ~= nil and #duplicate_matches > 0 then
        show_duplicate_resolution_popup(
            payload,
            duplicate_matches,
            duplicate_unreadable or 0
        )
        return
    end

    if duplicate_unreadable ~= nil and duplicate_unreadable > 0 then
        show_notice_popup(
            "IMPORT BLOCKED",
            string.format(
                "The code is valid, but %d existing character%s could not be checked for duplicates.",
                duplicate_unreadable,
                duplicate_unreadable == 1 and "" or "s"
            ),
            3600
        )
        return
    end

    log(
        "IMPORT PREFLIGHT: unique validated payload; starting native create."
    )

    begin_new_import_stage(
        payload
    )
end

local function handle_import_preflight_key()
    if popup_is_open("import") then
        validate_import_popup()
        return
    end

    show_import_popup()
end

dispatch_popup_action = function(action)
    if action == "close_popup" then
        reset_popup_state()
        return
    end

    if action == "cancel_import" then
        clear_pending_import()
        reset_popup_state()
        log("Import cancelled; dialog chain terminated.")
        return
    end

    if action == "validate_import" then
        -- BP_OnHideDialog fires as the native dialog closes. v0.5.16 correctly
        -- captured the text and released the pooled popup before dispatch, but
        -- then incorrectly required that same popup to still be open here.
        --
        -- validate_import_popup() can read popup_state.capturedImportCode, so
        -- validation must run after the native dialog has closed.
        if popup_state.capturedImportCode ~= nil
            or pending_import_code ~= nil then
            validate_import_popup()
        else
            log("IMPORT PREFLIGHT FAILED: Validate result had no captured code.")
            show_notice_popup(
                "INVALID SHARE CODE",
                "No Character Share code was captured from the Import dialog.",
                0
            )
        end
        return
    end

    if action == "duplicate_rename" then
        local context = popup_state.context
        if context ~= nil and context.payload ~= nil then
            show_rename_popup(context.payload)
        end
        return
    end

    if action == "duplicate_overwrite" then
        local context = popup_state.context
        if context == nil or context.payload == nil then
            return
        end

        local same_type =
            same_type_matches(context.payload, context.matches or {})

        if #same_type == 1 then
            begin_overwrite_stage(
                context.payload,
                same_type[1]
            )
        elseif #same_type == 2 then
            show_overwrite_target_popup(
                context.payload,
                same_type
            )
        else
            show_notice_popup(
                "OVERWRITE UNAVAILABLE",
                "Overwrite needs one or two matching characters of the same type.",
                0
            )
        end
        return
    end

    if action == "overwrite_target_1"
        or action == "overwrite_target_2" then
        local context = popup_state.context
        if context == nil
            or context.payload == nil
            or context.matches == nil then
            return
        end

        local index =
            action == "overwrite_target_1"
                and 1
                or 2

        local match = context.matches[index]
        if match == nil then
            show_notice_popup(
                "OVERWRITE FAILED",
                "The selected overwrite target is no longer available.",
                0
            )
            return
        end

        begin_overwrite_stage(
            context.payload,
            match
        )
        return
    end

    if action == "rename_confirm" then
        local context = popup_state.context
        if context == nil or context.payload == nil then
            return
        end

        local payload = context.payload
        local first =
            popup_state.capturedRenameFirst
                or read_popup_text(popup_state.renameFirstBox)

        local last =
            popup_state.capturedRenameLast
                or read_popup_text(popup_state.renameLastBox)

        first = first:gsub("^%s+", ""):gsub("%s+$", "")
        last = last:gsub("^%s+", ""):gsub("%s+$", "")

        if first == "" then
            show_notice_popup(
                "INVALID NAME",
                payload.characterType == "astromech"
                    and "Astromech name cannot be empty."
                    or "First name cannot be empty.",
                2600
            )
            return
        end

        if #first > 128 or #last > 128 then
            show_notice_popup(
                "INVALID NAME",
                "The new name is too long.",
                2600
            )
            return
        end

        local code = pending_import_code
        if code == nil then
            clear_pending_import()
            safe_remove_popup()
            return
        end

        pending_name_override = {
            first = first,
            last = payload.characterType == "astromech" and "" or last,
        }

        pending_name_override_code =
            code

        local decoded, decode_err = decode_share_code(code)
        if decode_err ~= nil or decoded == nil then
            show_notice_popup(
                "IMPORT ERROR",
                "The pending share code could not be decoded again.",
                3000
            )
            return
        end

        local renamed_payload = decoded.payload

        apply_pending_name_override(
            renamed_payload,
            code
        )

        pending_import_payload = renamed_payload

        local databank_vm = find_first("BrunoCharacterDatabankViewModel")
        local matches = {}
        local unreadable = 0

        if databank_vm ~= nil then
            matches, unreadable =
                find_duplicate_characters(databank_vm, renamed_payload)
        end

        safe_remove_popup()

        if #matches > 0 then
            show_duplicate_resolution_popup(
                renamed_payload,
                matches,
                unreadable
            )
        elseif unreadable > 0 then
            show_notice_popup(
                "IMPORT BLOCKED",
                "The new name is valid, but duplicate verification was incomplete.",
                3400
            )
        else
            log(
                string.format(
                    "IMPORT RENAMED: '%s' is unique; starting native create.",
                    payload_full_name(renamed_payload)
                )
            )

            begin_new_import_stage(
                renamed_payload
            )
        end

        return
    end
end

local function capture_native_dialog_inputs()
    if popup_state.mode == "import" then
        popup_state.capturedImportCode =
            read_text_box_value(popup_state.textBox)
    elseif popup_state.mode == "rename" then
        popup_state.capturedRenameFirst =
            read_text_box_value(popup_state.renameFirstBox)

        popup_state.capturedRenameLast =
            read_text_box_value(popup_state.renameLastBox)
    end
end

handle_native_dialog_result = function(widget_value, result_value)
    local widget = unwrap_hook_value(widget_value)
    local result = unwrap_hook_value(result_value)

    if widget == nil
        or popup_state.widget == nil
        or not same_remote_object(widget, popup_state.widget) then
        return
    end

    if popup_state.suppressResult then
        return
    end

    capture_native_dialog_inputs()

    local result_tag = gameplay_tag_value(result)
    local action =
        result_tag ~= nil
            and popup_state.resultActions[result_tag]
            or nil

    if action == nil then
        log(
            "Native dialog closed with unmapped result: "
            .. tostring(result_tag)
        )
        finish_native_popup_hide(widget)
        retire_native_popup(widget, nil)
        return
    end

    log(
        string.format(
            "Native dialog result: %s -> %s",
            tostring(result_tag),
            action
        )
    )

    -- Preserve values that dispatch_popup_action may need after state reset.
    local captured_import = popup_state.capturedImportCode
    local captured_first = popup_state.capturedRenameFirst
    local captured_last = popup_state.capturedRenameLast
    local captured_context = popup_state.context

    -- Clear Character Share content/state immediately, then explicitly retire
    -- the resolved popup from CommonUI before performing the next action. This
    -- prevents old Import/Duplicate/Notice dialogs from remaining underneath
    -- the native Edit screen and resurfacing when that screen closes.
    finish_native_popup_hide(widget)

    retire_native_popup(widget, function()
        ExecuteInGameThread(function()
            popup_state.capturedImportCode = captured_import
            popup_state.capturedRenameFirst = captured_first
            popup_state.capturedRenameLast = captured_last
            popup_state.context = captured_context

            log(
                string.format(
                    "Native dialog dispatch after retirement: %s",
                    tostring(action)
                )
            )

            if dispatch_popup_action ~= nil then
                dispatch_popup_action(action)
            end
        end)
    end)
end

log(string.format("Character Share v%s loading.", VERSION))

local debug_hotkeys_enabled = false

local function debug_hotkey_state_text()
    if debug_hotkeys_enabled then
        return "enabled"
    end

    return "disabled"
end

local function emit_console_status(output_device, message)
    log(message)

    if output_device ~= nil then
        pcall(function()
            output_device:Log(message)
        end)
    end
end

local function set_debug_hotkeys_enabled(enabled, output_device)
    debug_hotkeys_enabled = enabled == true

    emit_console_status(
        output_device,
        string.format(
            "Debug hotkeys %s: CTRL+SHIFT+F7 raw JSON, CTRL+SHIFT+F8 ZC1 export, CTRL+SHIFT+F9 Import.",
            debug_hotkey_state_text()
        )
    )
end

local function register_debug_hotkey_console_command()
    local ok, err = pcall(function()
        RegisterConsoleCommandHandler(
            "zcs_debug_hotkeys",
            function(full_command, _, output_device)
                local argument =
                    tostring(full_command or "")
                        :match("^%S+%s*(.-)%s*$")
                        :lower()

                if argument == "" or argument == "toggle" then
                    set_debug_hotkeys_enabled(
                        not debug_hotkeys_enabled,
                        output_device
                    )
                elseif argument == "on"
                    or argument == "1"
                    or argument == "true"
                    or argument == "enable"
                    or argument == "enabled" then
                    set_debug_hotkeys_enabled(true, output_device)
                elseif argument == "off"
                    or argument == "0"
                    or argument == "false"
                    or argument == "disable"
                    or argument == "disabled" then
                    set_debug_hotkeys_enabled(false, output_device)
                elseif argument == "status" then
                    emit_console_status(
                        output_device,
                        "Debug hotkeys are "
                            .. debug_hotkey_state_text()
                            .. "."
                    )
                else
                    emit_console_status(
                        output_device,
                        "Usage: zcs_debug_hotkeys [on|off|status|toggle]"
                    )
                end

                return true
            end
        )
    end)

    if not ok then
        log(
            "WARNING: zcs_debug_hotkeys console command registration failed: "
                .. tostring(err)
        )
        return false
    end

    log(
        "Debug hotkeys disabled by default. UE4SS console: zcs_debug_hotkeys [on|off|status|toggle]."
    )
    return true
end

register_debug_hotkey_console_command()
log("Import source: native GenericPopupMessage text-entry field (ZC1 only)")

ensure_native_dialog_result_hook = function(quiet_if_unavailable)
    if native_dialog_result_hook_registered then
        return true
    end

    -- The base Blueprint owns BP_OnHideDialog. It is not necessarily loaded
    -- yet when Lua mods start on a fresh game launch.
    local _, class_err =
        load_class(UI.GENERIC_POPUP_FALLBACK_CLASS_PATH)

    if class_err ~= nil then
        if not quiet_if_unavailable then
            log(
                "Native dialog result hook unavailable after popup construction: "
                    .. tostring(class_err)
            )
        end

        return false
    end

    local hook_ok, hook_err = pcall(function()
        RegisterHook(
            "/Game/Game/UI/Common/WBP_GenericPopupMessage."
                .. "WBP_GenericPopupMessage_C:BP_OnHideDialog",
            function(self, result)
                if handle_native_dialog_result ~= nil then
                    handle_native_dialog_result(
                        self,
                        result
                    )
                end
            end
        )
    end)

    if not hook_ok then
        if not quiet_if_unavailable then
            log(
                "Native GenericPopupMessage result hook registration failed after popup construction: "
                    .. tostring(hook_err)
            )
        end

        return false
    end

    native_dialog_result_hook_registered = true
    log(
        "Native GenericPopupMessage result hook registered."
    )
    return true
end

-- Do not register BP_OnHideDialog during Lua startup. On a fresh launch,
-- UE4SS may have the Blueprint class loaded before that Blueprint UFunction has
-- entered the runtime function map. show_native_dialog() handles registration
-- lazily and retries after the first popup instance is constructed.
log(
    "Native GenericPopupMessage result hook registration deferred until first Character Share dialog."
)

register_databank_click_hook()

local json_export_key_ok, json_export_key_err = pcall(function()
    RegisterKeyBind(Key.F7, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
        if not debug_hotkeys_enabled then
            return
        end

        ExecuteInGameThread(function()
            export_selected_character_json()
        end)
    end)
end)

if not json_export_key_ok then
    log(
        "WARNING: JSON export hotkey registration failed: "
            .. tostring(json_export_key_err)
    )
end

local export_key_ok, export_key_err = pcall(function()
    RegisterKeyBind(Key.F8, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
        if not debug_hotkeys_enabled then
            return
        end

        ExecuteInGameThread(function()
            handle_export_key()
        end)
    end)
end)

if not export_key_ok then
    log("WARNING: export hotkey registration failed: " .. tostring(export_key_err))
end

local preflight_key_ok, preflight_key_err = pcall(function()
    RegisterKeyBind(Key.F9, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
        if not debug_hotkeys_enabled then
            return
        end

        ExecuteInGameThread(function()
            handle_import_preflight_key()
        end)
    end)
end)

if not preflight_key_ok then
    log("WARNING: import preflight hotkey registration failed: " .. tostring(preflight_key_err))
end

log("Character Share ready. v0.7.51 keeps frozen ZC1 revision 1/1 and release-packages both zcom-mod.json and modinfo.json metadata while keeping development documentation outside the installed mod folder.")
