"""Run the release version helper against an isolated copy, never the real tree."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
MOD = next(path for path in (ROOT / "src").iterdir() if (path / "modinfo.json").is_file())


class VersionBumpTest(unittest.TestCase):
    def test_patch_updates_bootstrap_and_metadata(self):
        with tempfile.TemporaryDirectory(prefix="zcom-version-test-") as directory:
            scratch = Path(directory)
            relative = MOD.relative_to(ROOT)
            for source in (ROOT / "scripts/bump_version.py", ROOT / "CHANGELOG.md",
                           MOD / "modinfo.json", MOD / "zcom-mod.json", MOD / "Scripts/main.lua"):
                target = scratch / source.relative_to(ROOT)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
            before = json.loads((scratch / relative / "modinfo.json").read_text())["version"]
            major, minor, patch = map(int, before.split("."))
            expected = f"{major}.{minor}.{patch + 1}"
            subprocess.run([sys.executable, str(scratch / "scripts/bump_version.py"), "patch"],
                           cwd=scratch, check=True, capture_output=True, text=True)
            for name in ("modinfo.json", "zcom-mod.json"):
                self.assertEqual(json.loads((scratch / relative / name).read_text())["version"], expected)
            main = (scratch / relative / "Scripts/main.lua").read_text()
            self.assertEqual(re.search(r'^local VERSION = "([^"]+)"$', main, re.M).group(1), expected)
            self.assertIn(f"v{expected}", main.splitlines()[0])
            changelog = (scratch / "CHANGELOG.md").read_text()
            self.assertIn(f"## [{expected}]", changelog)
            self.assertIn("## [Unreleased]", changelog)


if __name__ == "__main__":
    unittest.main()
