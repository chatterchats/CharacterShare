# Character Share

[![Nexus Mods](https://img.shields.io/badge/Nexus%20Mods-Character%20Share-d98f40)](https://www.nexusmods.com/starwarszerocompany/mods/176)
[![UE4SS](https://img.shields.io/badge/framework-UE4SS-6f42c1)](https://github.com/UE4SS-RE/RE-UE4SS)
[![License: MIT](https://img.shields.io/badge/license-MIT-2f7d4f)](LICENSE)

A UE4SS Lua mod for **Star Wars: Zero Company** that adds **Share** and **Import** to the
Character Databank, so players exchange custom characters and astromechs as compact `ZC1-...`
codes. Imports go through the game's own Databank create and overwrite flow, and a code is fully
validated before anything changes. Players should download the release ZIP from
[Nexus Mods](https://www.nexusmods.com/starwarszerocompany/mods/176) or the
[GitHub releases](https://github.com/chatterchats/CharacterShare/releases); the mod page text,
with install steps, is in [`docs/nexus/`](docs/nexus/).

## Commands

`make help` lists everything. The usual loop: edit, `make test`, `make install`, restart the game.

| Target | Does |
| --- | --- |
| `make test` | the LuaJIT tests (mocked UE4SS and UMG), no game needed; `T=widget_reload_test` for one |
| `make install` / `make uninstall` | link `src/Character Share` into the main install, or remove the link |
| `make package` | `dist/CharacterShare-X.Y.Z.zip`, with `Character Share/` at its root |
| `make bump V=X.Y.Z` | set the version everywhere, date the changelog |
| `make release` | check, test, tag, push; CI publishes to GitHub and Nexus (mod 176) |
| `make check` / `make sync` | drift from the standard / fetch the latest shared files |

## Layout

The standard layout (see `../ModTemplate/STANDARD.md`). Specific to this repo:

- `src/Character Share/Scripts/`: `main.lua` boots the modules; `codec.lua` and `codebook.lua`
  are the ZC1 format, the `*_workflow.lua` files the import and overwrite flows, `databank_ui.lua`,
  `ui.lua` and `widget_helpers.lua` the injected buttons. [docs/architecture.md](docs/architecture.md)
  has the module map and shared state.
- `tests/`: LuaJIT tests with the engine faked; `ZC1-*.txt` are sample codes and error cases.
- `docs/todo.txt`: feature ideas (bulk export, export from Personalization).

## The ZC1 format is frozen

| Item | Value |
| --- | ---: |
| Wire revision | 1 |
| Codebook revision | 1 |
| Known slot tags | 121 |
| Palette / outfit / appearance / meta tables | 700 / 745 / 503 / 64 assets |

Never reorder, remove, repurpose or append to the tag order, slot-to-table mapping, table order
or table-local asset IDs. Assets outside the tables (later patches, other mods) travel as their
raw `PrimaryAssetId`; an incompatible change needs a new code generation (`ZC2`).

## How it works

Buttons are cloned from the Databank's own widgets and adopted again when the page is re-entered
(CommonUI stops exposing inserted children after reactivation, so the mod keeps its own
references). Import decodes and validates the code (revisions, CRC-32, every asset resolvable),
stages the character on a fresh Databank entry and saves through the native flow; a duplicate
name offers Overwrite, Rename or Cancel when a compatible target exists. It works alongside
[Enhanced Databank](https://www.nexusmods.com/starwarszerocompany/mods/209): Import shares
the Create New row with its Create Folder button.

**Hot reload.** The mod keeps its hook IDs and cancels its own delayed actions on teardown;
`ClearAllDelayedActions()` clears leftovers at startup unless
`CharacterShareClearDelayedActionsOnReload = false`. A same-state reload resumes an open
Databank; after a full Lua restart, reopen the Databank. Needs UE4SS with the delayed-action API
(`ExecuteInGameThreadWithDelay`, `MakeActionHandle`, `CancelDelayedAction`, `UnregisterHook`, …).

## Testing in game

Restart the game after `make install`. The mod logs to `UE4SS.log` and to
`src/Character Share/character_share.log` (UTC timestamps, session generations, workflow steps).
Check entering and leaving the Databank, share, a new import, rename, overwrite, cancel and
repeated imports, plus the button row with Enhanced Databank enabled.

Debug hotkeys are off by default; `zcs_debug_hotkeys on` in the UE4SS console turns them on:
`Ctrl+Shift+F7` exports the selected character as raw JSON, `Ctrl+Shift+F8` as a ZC1 code,
`Ctrl+Shift+F9` opens the Import dialog.

## License

[MIT](LICENSE), copyright 2026 Chatter Chats.
