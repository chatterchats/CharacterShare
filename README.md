# Character Share

[![Nexus Mods](https://img.shields.io/badge/Nexus%20Mods-Character%20Share-d98f40)](https://www.nexusmods.com/starwarszerocompany/mods/176)
[![UE4SS](https://img.shields.io/badge/framework-UE4SS-6f42c1)](https://github.com/UE4SS-RE/RE-UE4SS)

Character Share is a UE4SS Lua mod for **Star Wars: Zero Company** that adds
native-looking **Share** and **Import** actions to the Character Databank, so
players can exchange custom characters as compact `ZC1-...` codes without
opening the Character Creator.

Imports go through the game's native Databank create and overwrite flow. A
code is fully validated before anything is changed, and invalid codes are
rejected instead of being applied partially.

## Features

- **Share from the Databank:** select a saved character and use **Share** to
  get a copyable `ZC1-...` code.
- **Import from the Databank:** use **Import**, paste a code, and Character
  Share validates it and creates the character.
- **Duplicate handling:** same-name imports can be **Overwritten**,
  **Renamed** or **Cancelled** when safe. Overwrite is only offered when there
  is a compatible target of the same type.
- **Custom Characters and Astromechs**, end to end.
- **Mod-added assets:** known game assets use compact references; unknown or
  mod-added assets fall back to their raw `PrimaryAssetId`.
- **Corruption checks:** codes carry revision checks and a CRC-32 checksum,
  verified before any character is changed.
- A compact, native-styled **Import** icon button beside **Create New** that
  shares its row with Enhanced Databank's **Create Folder** button.

## Using Character Share

### Share a character

1. Open the **Character Databank**.
2. Select the Custom Character or Astromech you want to share.
3. Choose **Share**.
4. Copy the `ZC1-...` code and send it to the recipient.

### Import a character

1. Open the **Character Databank**.
2. Choose **Import**.
3. Paste the complete `ZC1-...` code and choose **Import**.
4. If the name is unique, the character is created. If it already exists,
   Character Share offers **Overwrite**, **Rename** or **Cancel**, depending on
   which targets are safe.

### Astromechs

Astromechs have a first name only. Any last name in a code is ignored when
importing an Astromech, including non-empty values from older or malformed
sources. Duplicate matching and renaming use the single displayed name.

### Modded assets

The frozen ZC1 codebook holds the customization options from the normal
creator and an unlock-all option sweep, stored as compact table-local
indexes. A `CustomizationPartDefinition` outside those tables is sent as its
raw `PrimaryAssetId` instead of being rejected.

**The recipient must have the mod that provides a raw asset installed.**
Character Share sends the asset's identifier, not another mod's files. If the
asset can't be resolved, the import fails safely before anything is created
or saved.

### ZC1 code format

`ZC1-...` is the frozen share-code format for the initial release.

| Item | Value |
| --- | ---: |
| Wire revision | 1 |
| Codebook revision | 1 |
| Known slot tags | 121 |
| Palette table | 700 assets |
| Outfit table | 745 assets |
| Appearance table | 503 assets |
| Meta table | 64 assets |

The tag order, slot-to-table mapping, table order and table-local asset IDs
are frozen: existing entries must never be reordered, removed, repurposed or
appended. Assets added later use the raw fallback; any incompatible change
needs a new code generation. Pre-release codes from before the freeze are not
covered by this guarantee.

## Requirements

- **Star Wars: Zero Company**
- **UE4SS** for Zero Company, with the delayed game-thread action API
  (`ExecuteInGameThreadWithDelay`, `MakeActionHandle`, `CancelDelayedAction`,
  `IsValidDelayedActionHandle`, `IsDelayedActionActive` and `UnregisterHook`)

| Steam build | Status |
| --- | --- |
| [25134257](https://steamdb.info/app/2075800/patchnotes/) | Tested |
| 24874058 | Tested |

Steam is the tested launcher; EA App compatibility has not been declared.
Later builds may work but are unverified until tested.

## Installation

Download the release ZIP from
[Nexus Mods](https://www.nexusmods.com/starwarszerocompany/mods/176), not
GitHub's source-code archive. The ZIP keeps `Character Share` as its
top-level folder and includes metadata for both mod managers below.

### With a mod manager

- **[Zero Mod Manager](https://github.com/stellamarislabs/zero-mod-manager)**
  (formerly ZCOM Mod Manager): open **Install**, drop in the ZIP, then
  confirm Character Share is enabled under **Mods**.
- **[Zero Company Mod Command](https://github.com/EnvianMods/ZeroCompanyModCommand)**:
  drag the ZIP into the **Hangar Bay** and check that it's enabled.

### By hand

1. Install UE4SS for Star Wars: Zero Company.
2. Extract the `Character Share` folder into
   `SWZeroCompany/Binaries/Win64/ue4ss/Mods/`.
3. Check that `ue4ss/Mods/Character Share/Scripts/main.lua` exists. Install
   the whole `Scripts` folder; `main.lua` alone is not enough.
4. If your UE4SS setup ignores the packaged `enabled.txt`, add
   `Character Share : 1` to `ue4ss/Mods/mods.txt`.
5. Start the game and open the Character Databank: **Import** and **Share**
   appear beside the native actions.

### Updating and uninstalling

Close the game, then install the new ZIP the same way (by hand, copy it over
the old folder). To uninstall, disable or remove it in your mod manager, or
delete the `Character Share` folder. Characters you imported stay in your
Databank.

## Compatibility

- **[Enhanced Databank](https://www.nexusmods.com/starwarszerocompany/mods/209):**
  designed to work together. **Create New**, compact **Import** and compact
  **Create Folder** share one action row, and **Move** and **Share** share the
  selected-character row.

## Troubleshooting

If an import fails, Character Share shows the reason in game and writes
details to `UE4SS.log` and to `character_share.log` beside the installed mod
(UTC timestamps, session generations and workflow steps).

| Message | Meaning |
| --- | --- |
| Checksum mismatch | The code was corrupted or cut off while copying. |
| Unsupported wire/codebook revision | The code is from an incompatible format revision. |
| Missing raw asset | The code uses a mod-added asset that isn't installed. |
| Unknown non-empty slot | The code has a future or modded slot this game can't safely stage. |

### Debug hotkeys

Disabled by default. Open the UE4SS console (`~` or `F10` by default) and run
`zcs_debug_hotkeys on` (`off`, `status`, or no argument to toggle).

| Shortcut | Action |
| --- | --- |
| `Ctrl+Shift+F7` | Export the selected character as one-line raw JSON (debugging only) |
| `Ctrl+Shift+F8` | Export the selected character as a ZC1 code |
| `Ctrl+Shift+F9` | Open the Import dialog |

### Reporting a bug

Open an [issue](https://github.com/chatterchats/CharacterShare/issues) with:

- the game build and UE4SS version;
- other Databank or customization mods installed;
- the steps to reproduce it;
- the share code, if it's safe to share; and
- `character_share.log` and `UE4SS.log`.

For codebook problems, include the slot tag and the exact
`CustomizationPartDefinition` asset ID when possible.

## Repository layout

```text
.
├── .github/workflows/release-nexus.yml   # manual Nexus release
├── CHANGELOG.md
├── README.md
├── docs/
│   ├── architecture.md                   # module map, reload rules, local checks
│   └── nexus/description.bbcode          # mod page description
├── scripts/
│   ├── bump_version.py                   # version bump + changelog promotion
│   └── nexus_changelog.py                # a release's notes as Nexus text
├── src/Character Share/                  # the distributable mod folder
│   ├── Scripts/                          # main.lua, codec, codebook, workflows, UI
│   ├── enabled.txt
│   ├── modinfo.json                      # Zero Company Mod Command
│   └── zcom-mod.json                     # Zero Mod Manager
└── tests/                                # LuaJIT and Python tests, ZC1 fixtures
```

`src/Character Share` is the distributable folder; there is no build or
bundle step. Documentation stays outside it so the release ZIP holds only
runtime files and manager metadata. See
[Script architecture](docs/architecture.md) for the module map and shared
state.

## Development

1. Clone the repository and copy or link `src/Character Share` into the
   game's `ue4ss/Mods` folder.
2. Run the tests from the repository root:

   ```bash
   for t in tests/*_test.lua; do luajit "$t" "src/Character Share/Scripts" || break; done
   for t in tests/*_test.py; do python3 "$t" || break; done
   ```

3. Test in game: the mod works on generated Blueprint classes and live UMG
   widget trees that the tests only fake.

**Hot reload.** The mod keeps its hook IDs and cancels its own delayed
actions on teardown. When available, `ClearAllDelayedActions()` also clears
leftovers at startup; set `CharacterShareClearDelayedActionsOnReload = false`
before reloading to skip that sweep. Existing Import/Share controls are
adopted again. A same-state reload resumes an open Databank; after a full Lua
restart, reopen the Databank to rebind the controls. Restart the game once
when upgrading from versions that didn't keep hook IDs.

## Releasing

The manually run **Release to Nexus Mods** workflow publishes a release; build
a local ZIP for package-only checks.

1. Add release notes under `## [Unreleased]` in [`CHANGELOG.md`](CHANGELOG.md).
2. Bump the version with `patch`, `minor` or `major`:

   ```bash
   ./scripts/bump_version.py patch
   ```

3. Run the tests, then check the package with a mod manager and a clean
   manual install.
4. Run **Release to Nexus Mods** from the **Actions** tab. It needs the
   `NEXUSMODS_API_KEY` repository secret.

The workflow:

- requires `modinfo.json` and `zcom-mod.json` to hold the same `#.#.#`
  version;
- reads that version's notes from `CHANGELOG.md`;
- packages `src/Character Share` as `Character Share V#.#.#.zip`; and
- uploads it to Nexus as `Character Share v#.#.#.zip`, finding the mod and its
  single active file through the API (exactly one active file is required).

## Contributing

Bug reports, compatibility findings and focused pull requests are welcome
through [Issues](https://github.com/chatterchats/CharacterShare/issues) and
[Pull Requests](https://github.com/chatterchats/CharacterShare/pulls).

ZC1 is intentionally frozen: never reorder or modify its existing
compatibility tables. New unsupported assets should keep using the raw
fallback unless a new share-code generation is introduced.

## Support

- Downloads: [Nexus Mods](https://www.nexusmods.com/starwarszerocompany/mods/176)
- Changes: [`CHANGELOG.md`](CHANGELOG.md)
- Bugs and requests: [GitHub Issues](https://github.com/chatterchats/CharacterShare/issues)

## License

This repository does not currently include a license. Unless one is added,
the source remains subject to applicable copyright law.
