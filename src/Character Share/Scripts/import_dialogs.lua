-- Character Share: import dialogs.
-- Initialized once per mod instance; shared references use explicit ctx fields.
-- Context: common, import_dialogs, import_validation, popup, state.
return function(ctx)
    function ctx.import_dialogs.show_overwrite_target_popup(payload, matches)
        if matches == nil or #matches < 2 then
            return false
        end

        local lines = {
            string.format(
                "%d matching %s characters use the name %s.",
                #matches,
                ctx.import_validation.duplicate_type_label(payload.characterType),
                ctx.import_validation.payload_full_name(payload)
            ),
            "",
            "Choose the existing character that should be replaced:",
        }

        for index, match in ipairs(matches) do
            table.insert(
                lines,
                ctx.import_validation.overwrite_match_description(match, index)
            )
        end

        local actions = {
            { id = "overwrite_target_1", label = "MATCH 1" },
            { id = "overwrite_target_2", label = "MATCH 2" },
            { id = "cancel_import", label = "CANCEL" },
        }

        local popup = ctx.popup.show_native_dialog(
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

    function ctx.import_dialogs.show_duplicate_resolution_popup(payload, matches, unreadable)
        local display_name = ctx.import_validation.payload_full_name(payload)
        local same_type = ctx.import_validation.same_type_matches(payload, matches)
        local actions = {}
        local body = nil

        if unreadable > 0 then
            body = string.format(
                "Found %d existing character(s) named %s, but some character data or current pool ownership could not be verified. Overwrite is unavailable until the Databank is synchronized. Rename the import or cancel.",
                #matches, display_name
            )
            actions = {
                { id = "duplicate_rename", label = "RENAME" },
                { id = "cancel_import", label = "CANCEL" },
            }
        elseif #same_type == 1 then
            body = string.format(
                "%s\n\nA character named %s already exists.\n\nOVERWRITE replaces that character with this import.\nRENAME imports this character as a new copy.",
                ctx.import_validation.import_summary(payload),
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
                ctx.import_validation.import_summary(payload),
                ctx.import_validation.duplicate_type_label(payload.characterType)
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
                ctx.import_validation.duplicate_type_label(payload.characterType),
                display_name
            )

            actions = {
                { id = "duplicate_rename", label = "RENAME" },
                { id = "cancel_import", label = "CANCEL" },
            }
        else
            local existing_type =
                #matches == 1
                    and ctx.import_validation.duplicate_type_label(matches[1].characterType)
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

        local popup = ctx.popup.show_native_dialog(
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

    function ctx.import_dialogs.read_popup_text(box)
        return ctx.popup.read_text_box_value(box)
    end

    function ctx.import_dialogs.show_rename_popup(payload)
        local popup = ctx.popup.show_native_dialog(
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
                local below, below_err = ctx.common.read_property(dialog, "Belowtext")
                if below_err ~= nil or below == nil then
                    return false, "GenericPopupMessage.Belowtext unavailable"
                end

                local panel, panel_err = ctx.popup.construct_native_widget(
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

                local first_text, first_text_err = ctx.popup.make_rich_label(
                    dialog,
                    first_label,
                    "CharacterShare_RenameFirstLabel"
                )

                if first_text_err == nil and first_text ~= nil then
                    ctx.popup.add_vertical_child(
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
                    ctx.popup.create_game_entry(
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

                ctx.popup.add_vertical_child(
                    panel,
                    first_entry,
                    {
                        Left = 0.0,
                        Top = 1.0,
                        Right = 0.0,
                        Bottom = 8.0,
                    }
                )

                ctx.state.popup_state.renameFirstBox = first_editable
                ctx.state.popup_state.injectedBelow = panel

                if payload.characterType ~= "astromech" then
                    local last_text, last_text_err = ctx.popup.make_rich_label(
                        dialog,
                        "LAST NAME",
                        "CharacterShare_RenameLastLabel"
                    )

                    if last_text_err == nil and last_text ~= nil then
                        ctx.popup.add_vertical_child(
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
                        ctx.popup.create_game_entry(
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

                    ctx.popup.add_vertical_child(
                        panel,
                        last_entry,
                        {
                            Left = 0.0,
                            Top = 1.0,
                            Right = 0.0,
                            Bottom = 2.0,
                        }
                    )

                    ctx.state.popup_state.renameLastBox = last_editable
                end

                local _, set_err = ctx.common.try_call(function()
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
end
