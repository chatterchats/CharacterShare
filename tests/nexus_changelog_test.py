"""Regression tests for Nexus-friendly changelog publishing."""

from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from scripts.nexus_changelog import format_for_nexus, nexus_changelog


class NexusChangelogTest(unittest.TestCase):
    def test_formats_current_release_as_plain_single_line_entries(self):
        changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")

        rendered = nexus_changelog(changelog, "1.0.4")

        self.assertEqual(
            rendered.splitlines(),
            [
                "Fixed: Validate the Databank master and its class before class inspection during entry discovery. A non-nil invalid UObject wrapper could previously reach GetClass and cause a native access violation while the screen was opening.",
                "Fixed: Reuse the retained, attached Share button when re-entering a persistent Databank page, even when a fresh WidgetTree traversal cannot rediscover the dynamically appended control. This prevents duplicate Share buttons.",
            ],
        )
        self.assertNotIn("###", rendered)
        self.assertNotIn("\n- ", rendered)
        self.assertNotIn("`", rendered)

    def test_preserves_categories_while_collapsing_wrapped_markdown(self):
        rendered = format_for_nexus(
            """### Added

- Added a `console` command with a
  wrapped description.

### Fixed

- Fixed the [button](https://example.com).
"""
        )

        self.assertEqual(
            rendered,
            "Added: Added a console command with a wrapped description.\n"
            "Fixed: Fixed the button.",
        )


if __name__ == "__main__":
    unittest.main()
