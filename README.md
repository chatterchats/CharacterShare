# Character Share

Character Share is a UE4SS mod for **STAR WARS Zero Company** that adds native-looking **Share** and **Import** actions to the Character Databank.

It lets players exchange custom characters with compact `ZC1-...` share codes without opening the Character Creator to complete an import. Character Share supports both Custom Characters and Astromechs, duplicate-safe overwrite/rename flows, and raw fallbacks for mod-added customization assets.

## Features

- **Share directly from the Character Databank** — select a saved character and use **Share** to generate a copyable `ZC1-...` code.
- **Import directly from the Databank** — use **Import**, paste a share code, and let Character Share validate and create the character through the game's native Databank flow.
- **Duplicate handling** — same-name imports can be **Overwritten**, **Renamed**, or **Cancelled** when safe. Overwrite is only offered when there is a compatible same-type target.
- **Custom Character and Astromech support** — both Databank character types are supported end to end.
- **Astromech naming support** — Astromechs are first-name-only. Character Share ignores any encoded last-name value for Astromech imports.
- **Modded asset support** — known in-game assets use compact dictionary references; unknown/mod-added assets can fall back to their raw `PrimaryAssetId`.
- **Corruption and compatibility checks** — ZC1 codes include revision checks and CRC-32 validation before any character mutation occurs.

## Requirements

- **STAR WARS Zero Company**
- **UE4SS**

Character Share has been tested on the Steam release with these game builds:

| Steam build | Notes |
| --- | --- |
| [25134257](https://steamdb.info/app/2075800/patchnotes/) | Tested |
| 24874058 | Tested |

Steam is the currently tested launcher. EA App compatibility has not been declared.

## Installation

### Mod manager

The archive includes metadata for both **Zero Company Mod Manager** and **Zero Company Mod Command**. Install the archive normally through the manager you use.

### Manual installation

1. Install UE4SS for STAR WARS Zero Company.
2. Extract the `Character Share` folder into the game's UE4SS `Mods` directory.
3. Confirm the resulting layout includes:

   ```text
   ue4ss/
   └── Mods/
       └── Character Share/
           ├── Scripts/
           │   ├── main.lua
           │   ├── character.lua
           │   ├── codebook.lua
           │   ├── codec.lua
           │   ├── libdeflate.lua
           │   └── ui.lua
           ├── enabled.txt
           ├── modinfo.json
           └── zcom-mod.json
   ```

4. Start the game and open the Character Databank. **Import** and **Share** should appear alongside the native Databank actions.

## Using Character Share

### Export a character

1. Open the **Character Databank**.
2. Select the Custom Character or Astromech you want to share.
3. Choose **Share**.
4. Copy the generated `ZC1-...` code and send it to the recipient.

### Import a character

1. Open the **Character Databank**.
2. Choose **Import**.
3. Paste the complete `ZC1-...` code.
4. Choose **Import** to validate it.
5. If the name is unique, Character Share creates the character automatically. If the name already exists, Character Share may offer **Overwrite**, **Rename**, or **Cancel** depending on the available safe targets.

Character Share validates the code before entering the native create/overwrite stage. Invalid, truncated, incompatible, or unresolved payloads are rejected instead of being applied partially.

## Astromechs

Astromechs are treated as a first-name-only character type. Their `last` name field is always ignored during import, including when a code contains a non-empty value from an older or malformed source.

Duplicate matching and rename behavior use the Astromech's single displayed name.

## Modded assets

Character Share distinguishes between compact, known assets and raw fallback assets.

### Known in-game assets

The frozen ZC1 codebook contains the in-game customization options gathered from the normal creator and the unlock-all option sweep. These assets are represented by compact table-local indexes.

### Raw mod-added assets

If a character uses a `CustomizationPartDefinition` that is not part of the frozen ZC1 tables, Character Share can encode the raw `PrimaryAssetId` instead of rejecting the character.

**The recipient must also have the mod or asset that provides that raw customization asset installed.** Character Share transfers the asset identifier; it does not package or distribute another mod's files.

If the asset cannot be resolved on the recipient's installation, the import fails safely before native creation or save is confirmed.

## ZC1 compatibility

`ZC1-...` is the frozen share-code format for the initial release.

- Wire revision: **1**
- Codebook revision: **1**
- Known slot tags: **121**
- Palette table: **700** assets
- Outfit table: **745** assets
- Appearance table: **503** assets
- Meta table: **64** assets

The ZC1 tag order, slot-to-table mapping, table order, and table-local asset IDs are frozen. Existing entries must not be reordered, removed, repurposed, or appended after the public compatibility baseline is established.

Future assets that are not in ZC1 use the raw asset fallback. A future format generation is required for any incompatible wire/schema or compact-table redesign.

Pre-release codes created before the final ZC1 freeze are not part of the public compatibility guarantee.

## Debug hotkeys

Normal use does not require keyboard shortcuts. Three support/debug shortcuts remain available but are **disabled by default**.

Open the UE4SS console (Default: ~ or F10) and run:

```text
zcs_debug_hotkeys on
```

Available shortcuts while enabled:

| Shortcut | Action |
| --- | --- |
| `Ctrl+Shift+F7` | Export the selected character as one-line raw JSON for debugging/inspection |
| `Ctrl+Shift+F8` | Export the selected character as a ZC1 share code |
| `Ctrl+Shift+F9` | Open the Importdialog |

Use `zcs_debug_hotkeys off` to disable them again, or `zcs_debug_hotkeys status` to check the current state. Running `zcs_debug_hotkeys` with no argument toggles the setting.

The raw JSON export is a debugging aid only. Normal imports accept ZC1 share codes.

## Troubleshooting

If an import fails, Character Share reports the validation or staging reason in-game and writes additional detail to `UE4SS.log`.

Common cases include:

- **Checksum mismatch** — the share code was corrupted or truncated while copying.
- **Unsupported wire/codebook revision** — the code is from an incompatible format revision.
- **Missing raw asset** — the code references a mod-added asset that is not installed or available locally.
- **Unknown non-empty slot** — the code contains a future/modded slot the current game/editor cannot safely stage.

When reporting a crash or reproducible import problem, include the relevant `UE4SS.log`, the share code if it is safe to share, and the game build/mod setup needed to reproduce it.

## Repository layout

```text
README.md
CHANGELOG.md
Character Share/
├── Scripts/
│   ├── main.lua
│   ├── character.lua
│   ├── codebook.lua
│   ├── codec.lua
│   ├── libdeflate.lua
│   └── ui.lua
├── enabled.txt
├── modinfo.json
└── zcom-mod.json
```

The repository documentation stays outside the installable `Character Share/` directory so release archives contain only runtime files and manager metadata.

## Contributing

Bug reports and compatibility findings are welcome. For customization/codebook issues, include the affected slot tag and exact `CustomizationPartDefinition` asset ID when possible.

ZC1 is intentionally frozen. Contributions must not reorder or modify its existing compatibility tables. New unsupported assets should continue to use the raw fallback unless a future share-code generation is introduced.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for release history.
