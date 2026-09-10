-- Character Share UI configuration/state helpers.

local Codec =
    require("codec")

local M = {}

M.GENERIC_POPUP_CLASS_PATH =
    "/Game/Game/UI/Common/WBP_GenericPopupMessage_Small."
    .. "WBP_GenericPopupMessage_Small_C"

M.GENERIC_POPUP_FALLBACK_CLASS_PATH =
    "/Game/Game/UI/Common/WBP_GenericPopupMessage."
    .. "WBP_GenericPopupMessage_C"

M.ENTRY_TEXT_CLASS_PATH =
    "/Game/Game/UI/Strategy/Customization/Widgets/CustomCharacter/"
    .. "WBP_CustomCharacter_EntryText.WBP_CustomCharacter_EntryText_C"

M.DATABANK_MASTER_CLASS_PATH =
    "/Game/Game/UI/Strategy/Customization/Widgets/CharacterDatabank/"
    .. "WBP_CharacterBank_Master.WBP_CharacterBank_Master_C"

M.DATABANK_TOPNAV_BUTTON_CLASS_PATH =
    "/Game/Game/UI/Strategy/Customization/Widgets/CharacterDatabank/"
    .. "WBP_CharacterDataBank_TopNavButton."
    .. "WBP_CharacterDataBank_TopNavButton_C"

-- Existing registered GameplayTags used only as opaque dialog result IDs.
M.DIALOG_RESULT_PRIMARY =
    "br.Customization.Slot.Character.Info"

M.DIALOG_RESULT_SECONDARY =
    "br.Customization.Slot.Character.Class"

M.DIALOG_RESULT_TERTIARY =
    "br.Customization.Slot.Character.Rig"

function M.new_popup_state()
    return {
        widget = nil,
        mode = nil,
        textBox = nil,
        renameFirstBox = nil,
        renameLastBox = nil,
        context = nil,
        resultActions = {},
        customActions = {},
        nativeActionEntryBox = nil,
        suppressResult = false,
        capturedImportCode = nil,
        capturedRenameFirst = nil,
        capturedRenameLast = nil,
        injectedAbove = nil,
        injectedBelow = nil,
    }
end

function M.new_databank_state()
    return {
        buttons = {},
        installedPages = {},
        installedMasterIdentity = nil,
        activeMaster = nil,
        activeMasterIdentity = nil,
        generation = 0,
        shareDispatchPending = false,
        importDispatchPending = false,
    }
end

function M.extract_share_code(contents)
    return Codec.extract(contents)
end

return M
