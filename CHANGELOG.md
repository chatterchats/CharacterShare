# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Write Character Share diagnostics to a dedicated `character_share.log` beside
  the installed mod while continuing to mirror messages to the shared UE4SS log.
- Prefix dedicated-log entries with UTC time plus runtime, Databank, and import
  generations, and record explicit Databank, import, overwrite, export, and
  reload workflow transitions for crash correlation.

### Changed

- Keep Character Databank discovery activation-based; dedicated diagnostics do
  not add `NotifyOnNewObject` observers during Blueprint/widget construction.
- Split the entry script into focused modules for actions, hook registration,
  logging, popups, Databank controls, sharing, import validation and dialogs,
  character staging, import/create and overwrite workflows, and lifecycle hooks.
- Use a fresh explicit module context per startup to keep mutable workflow
  state shared correctly without approaching Lua's 200-local limit.
- Test the production module factories and full bootstrap/reload wiring
  directly, including surviving-widget adoption.
- Read the ready-log version from the bootstrap version constant and adapt the
  version-bump helper to the modular entry script.

### Fixed

- Deduplicate import conflicts by saved character GUID rather than ViewModel
  identity. A moved character's stale Default-pool copy is no longer counted
  as a second character; genuinely different GUIDs remain separate matches.
- Check current native pool ownership when selecting conflict/overwrite targets,
  ignore deleted GUIDs, and fail closed when identity, ownership, or the owning
  pool's ViewModel cannot be verified. Snapshot reads retain only scalar values.
- Add regression tests for moved/deleted characters, real same-name duplicates,
  unknown IDs, incomplete ownership snapshots, and stale overwrite candidates.

- Added reload teardown with a central hook registry retaining both UE4SS hook
  IDs, cancellation of grouped and ungrouped actions, and optional current-mod
  delayed-action clearing. Retired callbacks are disabled.
- Rebind existing debug-key and console dispatchers, reset registration flags,
  and retire old popup content on the game thread. Reinitialization adopts
  attached Import/Share controls instead of duplicating buttons and spacers.
- Resume a known open Databank after same-state reload and add mocked reload
  and scheduler regression tests.
- Added owned, cancellable delayed-action groups for Databank entry/install,
  popup setup and retirement, import/create, and overwrite verification.
  Leaving the Databank, replacing an import, closing a popup, or ending a
  workflow now cancels pending actions immediately while retaining generation
  and UObject-validity checks as secondary guards.
- Added fail-closed `IsValid()` checks at delayed-action execution boundaries
  for captured popup widgets, Databank widgets, character ViewModels, import
  controls, and overwrite context. Stale callbacks now stop before touching
  released Unreal objects.
- Migrated deferred UI, popup, import, overwrite, and debug-hotkey work from
  legacy `ExecuteWithDelay` / `ExecuteInGameThread` scheduling to UE4SS's owned
  delayed game-thread action system.
- Removed the continuously rescheduled 40 ms Import-button hover poll and routed
  its icon tint through native CommonUI hover and unhover events.

## [1.0.2] - 2026-09-13

### Changed

- Replaced the half-width text Import control with a compact native button and a Tabler-inspired file-import glyph drawn entirely from UMG primitives.
- Made the Databank top action installer cooperate with Enhanced Databank's Create Folder row instead of nesting or overlapping either mod's controls.

## [1.0.1]

### Fixed

- Prevented a native access violation when opening another Strategy submenu page before Character Databank on a fresh launch.

## [1.0.0] - 2026-09-10

### Added

- Initial release of Character Share.
