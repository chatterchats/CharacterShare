# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

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
