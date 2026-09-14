# Script architecture

`main.lua` is the version declaration and composition root. It starts the reload
registry, loads the existing codec/character/UI helpers, allocates one context,
and initializes the factories. Every module is shipped inside the existing
`Scripts` directory, which the release workflow packages recursively.

| Modules | Responsibility |
| --- | --- |
| `hook_registry.lua`, `actions.lua` | Own hook IDs, guarded callbacks, delayed handles, cancellation, and reload teardown. |
| `common.lua`, `logging.lua`, `state.lua` | UObject helpers, dedicated session/workflow logging, mutable session state, and callback slots. |
| `popup.lua`, `popup_dispatch.lua` | Native dialog construction, text capture, retirement, result/action routing. |
| `sharing.lua` | Export the selected character and show its share code. |
| `import_validation.lua`, `import_dialogs.lua` | Resolve import data, detect conflicts, and present import choices. |
| `pool_identity.lua` | Read GUIDs and a complete scalar native ownership snapshot for conflict/overwrite selection. |
| `character_staging.lua` | Apply names, slots, and character data to native ViewModels. |
| `import_workflow.lua` | Native new-character creation, staging, confirmation, verification, and cancellation. |
| `overwrite_workflow.lua` | Stage and save an existing character, then verify the overwrite. |
| `widget_helpers.lua`, `import_icon.lua`, `databank_ui.lua` | Native widget layout, import glyphs, cooperative action rows, Import/Share controls, and adoption. |
| `lifecycle.lua`, `button_hooks.lua` | Screen sessions, entry/install/deactivation, and native button dispatch. |
| `debug_hotkeys.lua`, `startup.lua` | Opt-in debug controls and final startup wiring. |
| `codec.lua`, `codebook.lua`, `libdeflate.lua`, `character.lua`, `ui.lua` | Existing format, compression, character-data, and UI configuration helpers (unchanged). |

## Context and initialization

Factories have the signature `return function(ctx) ... end`. Private helpers stay
local; shared functions and mutable values use explicit
`ctx.<namespace>.<name>` references. `ctx.layout` retains the existing layout/action
API, while `ctx.dependencies` holds the codec, character, and UI helper modules.
There is no shared Lua environment, and no copying of mutable workflow state
between modules. Do not cache a state field in a local if another module replaces
it.

The bootstrap allocates namespaces first. Each factory defines its functions,
including the late-bound native-dialog callback slots in `ctx.state`. Only
`startup.lua` installs initial hooks/actions, after all the factories are ready.
Cross-module workflow callbacks resolve through their context when invoked.

Reloading invalidates the factory cache and constructs a fresh context. The
registry retires the previous runtime first; pending callbacks retain their
retired context, not the new instance. `CharacterShareLayout` remains a compatibility
alias to the current layout/action API, and the old `reload_runtime.lua` import
forwards to the registry. The native import/save operations, ZC1 format,
cancellation groups, validity checks, and widget identifiers are unchanged.
The dedicated log is observational only: Databank discovery remains driven by
the bounded activation/navigation probe, never `NotifyOnNewObject` during
Blueprint or WidgetTree construction.

## Local checks

Run from the repository root:

```sh
luajit tests/reload_runtime_test.lua "src/Character Share/Scripts"
luajit tests/widget_reload_test.lua "src/Character Share/Scripts"
luajit tests/module_bootstrap_test.lua "src/Character Share/Scripts"
luajit tests/duplicate_identity_test.lua "src/Character Share/Scripts"
python3 tests/version_bump_test.py
```

The bootstrap test runs the production modules with mocked engine boundaries.
Under LuaJIT it stubs only the codec among the existing helper modules because
LuaJIT cannot parse the codec's Lua 5.3 bit operators. With `lua5.4` in place of
`luajit`, it loads all real helper modules. This is not an import round-trip test.
In game, check entry/exit, share, new import, rename/conflict/overwrite, cancellation,
and repeated imports. Also check Import/Create Folder layout with Enhanced
Databank enabled.
