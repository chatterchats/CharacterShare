-- Character Share: import icon.
-- Initialized once per mod instance; shared references use explicit ctx fields.
-- Context: common, layout, logging, popup.
return function(ctx)
    function ctx.layout.install_import_glyph(
        page,
        button
    )
        if page == nil
            or button == nil then
            return nil,
                "page/button unavailable"
        end

        local image_hidden =
            ctx.layout
                .hide_single_clone_image(
                    button
                )

        local label_changed =
            ctx.layout
                .set_clone_label(
                    button,
                    ""
                )

        pcall(function()
            button:SetToolTipText(
                FText("IMPORT CHARACTER")
            )
        end)

        local overlay,
            overlay_err =
                ctx.popup.construct_native_widget(
                    page,
                    "/Script/UMG.Overlay",
                    "CharacterShare_ImportOverlay"
                )

        if overlay == nil then
            return nil,
                "import Overlay unavailable: "
                    .. tostring(overlay_err)
        end

        pcall(function()
            overlay:SetVisibility(4)
        end)

        local button_slot = nil

        pcall(function()
            button_slot =
                ctx.common.unwrap_hook_value(
                    overlay:AddChild(
                        button
                    )
                )
        end)

        if button_slot == nil then
            return nil,
                "could not add import button to Overlay"
        end

        pcall(function()
            button_slot:SetHorizontalAlignment(3)
            button_slot:SetVerticalAlignment(3)
        end)

        local icon_size,
            size_err =
                ctx.popup.construct_native_widget(
                    page,
                    "/Script/UMG.SizeBox",
                    "CharacterShare_ImportGlyphSize"
                )

        if icon_size == nil then
            return nil,
                "import glyph SizeBox unavailable: "
                    .. tostring(size_err)
        end

        pcall(function()
            icon_size:SetWidthOverride(28.0)
            icon_size:SetHeightOverride(28.0)
            icon_size:SetVisibility(4)
        end)

        local canvas,
            canvas_err =
                ctx.popup.construct_native_widget(
                    page,
                    "/Script/UMG.CanvasPanel",
                    "CharacterShare_ImportGlyphCanvas"
                )

        if canvas == nil then
            return nil,
                "import glyph CanvasPanel unavailable: "
                    .. tostring(canvas_err)
        end

        pcall(function()
            canvas:SetVisibility(4)
        end)

        local canvas_slot = nil

        pcall(function()
            canvas_slot =
                ctx.common.unwrap_hook_value(
                    icon_size:AddChild(
                        canvas
                    )
                )
        end)

        if canvas_slot == nil then
            return nil,
                "could not add import CanvasPanel to SizeBox"
        end

        pcall(function()
            canvas_slot:SetHorizontalAlignment(3)
            canvas_slot:SetVerticalAlignment(3)
        end)

        -- 28x28 Tabler file-import silhouette, drawn only with native UMG
        -- Borders. This avoids external textures and remains crisp at UI scale.
        local rects = {
            { "DocTop", 8.0, 3.0, 9.0, 2.2, 0.0 },
            { "DocLeftTop", 8.0, 3.0, 2.2, 8.0, 0.0 },
            { "DocLeftBottom", 8.0, 20.0, 2.2, 4.0, 0.0 },
            { "DocFoldRise", 16.0, 3.0, 2.2, 7.0, 0.0 },
            { "DocFoldTop", 16.0, 8.0, 6.0, 2.2, 0.0 },
            { "DocRight", 20.0, 8.0, 2.2, 16.0, 0.0 },
            { "DocBottom", 8.0, 22.0, 14.0, 2.2, 0.0 },
            { "ArrowShaft", 2.0, 15.0, 13.0, 2.4, 0.0 },
            { "ArrowUp", 10.3, 12.0, 6.0, 2.4, 45.0 },
            { "ArrowDown", 10.3, 18.0, 6.0, 2.4, -45.0 },
        }

        for _, spec in ipairs(rects) do
            local rect,
                rect_err =
                    ctx.popup.construct_native_widget(
                        page,
                        "/Script/UMG.Border",
                        "CharacterShare_ImportGlyph_"
                            .. spec[1]
                    )

            if rect == nil then
                return nil,
                    "import glyph Border unavailable: "
                        .. tostring(rect_err)
            end

            pcall(function()
                rect:SetBrushColor({
                    R = 0.82,
                    G = 0.85,
                    B = 0.86,
                    A = 1.0,
                })
                rect:SetVisibility(4)

                if spec[6] ~= 0.0 then
                    rect:SetRenderTransformAngle(
                        spec[6]
                    )
                end
            end)

            local rect_slot = nil

            pcall(function()
                rect_slot =
                    ctx.common.unwrap_hook_value(
                        canvas:AddChildToCanvas(
                            rect
                        )
                    )
            end)

            if rect_slot == nil then
                return nil,
                    "could not add import glyph Border to CanvasPanel"
            end

            pcall(function()
                rect_slot:SetPosition({
                    X = spec[2],
                    Y = spec[3],
                })
                rect_slot:SetSize({
                    X = spec[4],
                    Y = spec[5],
                })
                rect_slot:SetAutoSize(false)
            end)
        end

        local icon_slot = nil

        pcall(function()
            icon_slot =
                ctx.common.unwrap_hook_value(
                    overlay:AddChild(
                        icon_size
                    )
                )
        end)

        if icon_slot == nil then
            return nil,
                "could not add import glyph to Overlay"
        end

        pcall(function()
            icon_slot:SetHorizontalAlignment(2)
            icon_slot:SetVerticalAlignment(2)
            icon_size:SetRenderTranslation({
                X = -4.0,
                Y = -4.0,
            })
        end)

        ctx.logging.log(
            string.format(
                "Databank compact IMPORT visual initialized: labelBlanked=%s inheritedPlusHidden=%s nativeVectorIcon=true",
                tostring(label_changed),
                tostring(image_hidden)
            )
        )

        return overlay,
            canvas,
            nil
    end

    function ctx.layout.set_import_icon_color(
        canvas,
        color
    )
        if canvas == nil
            or color == nil then
            return false
        end

        local count = 0

        pcall(function()
            count =
                tonumber(
                    canvas:GetChildrenCount()
                ) or 0
        end)

        local changed = 0

        for index = 0, count - 1 do
            local child = nil

            pcall(function()
                child =
                    ctx.common.unwrap_hook_value(
                        canvas:GetChildAt(
                            index
                        )
                    )
            end)

            if child ~= nil then
                local ok = pcall(function()
                    child:SetBrushColor(
                        color
                    )
                end)

                if ok then
                    changed =
                        changed + 1
                end
            end
        end

        return changed > 0
    end
end
