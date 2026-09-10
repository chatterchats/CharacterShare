#!/usr/bin/env python3
"""Bump the mod version and promote the Unreleased changelog notes."""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import tempfile
from pathlib import Path
from re import Match, Pattern

ROOT = Path(__file__).resolve().parent.parent
CHANGELOG = ROOT / "CHANGELOG.md"
MODINFO = ROOT / "src/Character Share/modinfo.json"
ZCOM_MOD = ROOT / "src/Character Share/zcom-mod.json"
MAIN = ROOT / "src/Character Share/Scripts/main.lua"

SEMVER_PATTERN = re.compile(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)")
JSON_VERSION_PATTERN = re.compile(
    r'^(?P<prefix>\s*"version"\s*:\s*")(?P<version>[^"]+)(?P<suffix>".*)$',
    re.MULTILINE,
)
MAIN_VERSION_PATTERN = re.compile(
    r'^(?P<prefix>\s*local\s+VERSION\s*=\s*")(?P<version>[^"]+)(?P<suffix>".*)$',
    re.MULTILINE,
)
READY_LOG_VERSION_PATTERN = re.compile(
    r'^(?P<prefix>\s*log\("Character Share ready\. v)(?P<version>[^"]+)(?P<suffix>"\)\s*)$',
    re.MULTILINE,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Bump the mod version and promote CHANGELOG.md's Unreleased notes."
    )
    parser.add_argument(
        "part",
        type=str.lower,
        choices=("major", "minor", "patch"),
        help="semantic version component to bump (case-insensitive)",
    )
    return parser.parse_args()


def read_text(path: Path) -> str:
    try:
        return path.read_bytes().decode("utf-8")
    except FileNotFoundError as error:
        raise SystemExit(f"Required file does not exist: {path.relative_to(ROOT)}") from error
    except UnicodeDecodeError as error:
        raise SystemExit(f"Required file is not UTF-8: {path.relative_to(ROOT)}") from error


def extract_version(path: Path, text: str, pattern: Pattern[str]) -> str:
    matches = list(pattern.finditer(text))
    relative_path = path.relative_to(ROOT)
    if len(matches) != 1:
        raise SystemExit(
            f"Expected exactly one version declaration in {relative_path}, found {len(matches)}"
        )
    return matches[0].group("version")


def replace_version(
    path: Path,
    text: str,
    pattern: Pattern[str],
    current_version: str,
    next_version: str,
) -> str:
    def replacement(match: Match[str]) -> str:
        if match.group("version") != current_version:
            raise SystemExit(
                f"Version changed unexpectedly in {path.relative_to(ROOT)}: "
                f"{match.group('version')} != {current_version}"
            )
        return f"{match.group('prefix')}{next_version}{match.group('suffix')}"

    updated, count = pattern.subn(replacement, text)
    if count != 1:
        raise SystemExit(
            f"Expected exactly one version declaration in {path.relative_to(ROOT)}, found {count}"
        )
    return updated


def bump_version(current_version: str, part: str) -> str:
    match = SEMVER_PATTERN.fullmatch(current_version)
    if match is None:
        raise SystemExit(
            f"Version must use semantic X.Y.Z format without leading zeroes, got {current_version!r}"
        )

    major, minor, patch = (int(component) for component in match.groups())
    if part == "major":
        return f"{major + 1}.0.0"
    if part == "minor":
        return f"{major}.{minor + 1}.0"
    return f"{major}.{minor}.{patch + 1}"


def promote_unreleased(changelog: str, next_version: str) -> str:
    newline = "\r\n" if "\r\n" in changelog else "\n"
    unreleased_pattern = re.compile(r"^## \[Unreleased\][^\r\n]*(?:\r?\n|$)", re.MULTILINE)
    unreleased_matches = list(unreleased_pattern.finditer(changelog))
    if len(unreleased_matches) != 1:
        raise SystemExit(
            "Expected exactly one '## [Unreleased]' section in CHANGELOG.md, "
            f"found {len(unreleased_matches)}"
        )

    if re.search(rf"^## \[{re.escape(next_version)}\](?:[^\r\n]*)$", changelog, re.MULTILINE):
        raise SystemExit(f"CHANGELOG.md already contains a [{next_version}] section")

    unreleased = unreleased_matches[0]
    next_heading = re.search(r"^## ", changelog[unreleased.end() :], re.MULTILINE)
    section_end = (
        unreleased.end() + next_heading.start() if next_heading is not None else len(changelog)
    )
    release_notes = changelog[unreleased.end() : section_end].strip()
    if not release_notes:
        raise SystemExit("CHANGELOG.md's [Unreleased] section is empty")

    replacement = (
        f"## [Unreleased]{newline}{newline}"
        f"## [{next_version}]{newline}{newline}"
        f"{release_notes}{newline}{newline}"
    )
    return changelog[: unreleased.start()] + replacement + changelog[section_end:]


def write_updates(updates: dict[Path, str]) -> None:
    temporary_files: list[tuple[Path, Path]] = []
    try:
        for path, content in updates.items():
            file_descriptor, temporary_name = tempfile.mkstemp(
                dir=path.parent, prefix=f".{path.name}.", suffix=".tmp"
            )
            temporary_path = Path(temporary_name)
            temporary_files.append((temporary_path, path))
            os.chmod(temporary_path, stat.S_IMODE(path.stat().st_mode))
            with os.fdopen(file_descriptor, "wb") as stream:
                stream.write(content.encode("utf-8"))
                stream.flush()
                os.fsync(stream.fileno())

        for temporary_path, path in temporary_files:
            os.replace(temporary_path, path)
    finally:
        for temporary_path, _ in temporary_files:
            temporary_path.unlink(missing_ok=True)


def main() -> None:
    args = parse_args()
    texts = {
        MODINFO: read_text(MODINFO),
        ZCOM_MOD: read_text(ZCOM_MOD),
        MAIN: read_text(MAIN),
        CHANGELOG: read_text(CHANGELOG),
    }

    try:
        modinfo_json = json.loads(texts[MODINFO])
        zcom_mod_json = json.loads(texts[ZCOM_MOD])
    except json.JSONDecodeError as error:
        raise SystemExit(f"Invalid JSON: {error}") from error

    versions = {
        MODINFO: extract_version(MODINFO, texts[MODINFO], JSON_VERSION_PATTERN),
        ZCOM_MOD: extract_version(ZCOM_MOD, texts[ZCOM_MOD], JSON_VERSION_PATTERN),
        MAIN: extract_version(MAIN, texts[MAIN], MAIN_VERSION_PATTERN),
    }
    ready_log_version = extract_version(
        MAIN, texts[MAIN], READY_LOG_VERSION_PATTERN
    )
    if modinfo_json.get("version") != versions[MODINFO]:
        raise SystemExit("Parsed modinfo.json version does not match its version declaration")
    if zcom_mod_json.get("version") != versions[ZCOM_MOD]:
        raise SystemExit("Parsed zcom-mod.json version does not match its version declaration")

    unique_versions = set(versions.values()) | {ready_log_version}
    if len(unique_versions) != 1:
        details = ", ".join(
            f"{path.relative_to(ROOT)}: {version}" for path, version in versions.items()
        )
        details += f", {MAIN.relative_to(ROOT)} ready log: {ready_log_version}"
        raise SystemExit(f"Version declarations do not match: {details}")

    current_version = unique_versions.pop()
    next_version = bump_version(current_version, args.part)

    updates = {
        MODINFO: replace_version(
            MODINFO, texts[MODINFO], JSON_VERSION_PATTERN, current_version, next_version
        ),
        ZCOM_MOD: replace_version(
            ZCOM_MOD, texts[ZCOM_MOD], JSON_VERSION_PATTERN, current_version, next_version
        ),
        MAIN: replace_version(
            MAIN, texts[MAIN], MAIN_VERSION_PATTERN, current_version, next_version
        ),
        CHANGELOG: promote_unreleased(texts[CHANGELOG], next_version),
    }
    updates[MAIN] = replace_version(
        MAIN,
        updates[MAIN],
        READY_LOG_VERSION_PATTERN,
        current_version,
        next_version,
    )

    main_header = f"-- Character Share v{current_version}"
    if main_header in updates[MAIN]:
        updates[MAIN] = updates[MAIN].replace(
            main_header, f"-- Character Share v{next_version}", 1
        )

    write_updates(updates)
    print(f"Bumped version from {current_version} to {next_version}.")


if __name__ == "__main__":
    main()
