import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from release_notes import MARK, add_mac_dmg  # noqa: E402

BODY = """## Downloads

| Platform | Asset | Version |
|---|---|---|
| Android client | [`coderelay-v0.3.51-android.apk`](u) | 0.3-m69 |
| iOS / macOS app | TestFlight | — |

### macOS

The server ships through Homebrew.

### Checksums (SHA-256)
"""

ARGS = ("coderelay-v0.3.51-macos.dmg", "https://x/coderelay-v0.3.51-macos.dmg", "1.3.0", "130", "ab" * 32)


class ReleaseNotesTests(unittest.TestCase):
    def test_adds_the_dmg_row_and_section(self):
        out = add_mac_dmg(BODY, *ARGS)
        self.assertIn("| macOS app (Apple silicon + Intel, macOS 14+) | [`coderelay-v0.3.51-macos.dmg`]", out)
        self.assertIn("| iOS / macOS app | TestFlight · App Store | — |", out)
        self.assertNotIn("| iOS / macOS app | TestFlight | — |", out)
        section = out.split("### macOS")[1].split("### Checksums")[0]
        self.assertIn("notarized by Apple", section)
        self.assertIn("ab" * 32, section)
        # The existing section text is kept.
        self.assertIn("The server ships through Homebrew.", section)

    def test_is_idempotent(self):
        once = add_mac_dmg(BODY, *ARGS)
        twice = add_mac_dmg(once, *ARGS)
        self.assertEqual(once, twice)
        self.assertEqual(twice.count("coderelay-v0.3.51-macos.dmg`]("), 2)  # table row + section

    def test_rerun_with_a_new_build_replaces_the_old_rows(self):
        first = add_mac_dmg(BODY, *ARGS)
        second = add_mac_dmg(first, ARGS[0], ARGS[1], "1.3.0", "131", "cd" * 32)
        self.assertNotIn("(130)", second)
        self.assertIn("(131)", second)
        self.assertNotIn("ab" * 32, second)
        self.assertEqual(second.count(MARK), 4)

    def test_body_without_the_testflight_row_still_gets_the_section(self):
        body = "### macOS\n\nServer text.\n"
        out = add_mac_dmg(body, *ARGS)
        self.assertIn("notarized by Apple", out)


if __name__ == "__main__":
    unittest.main()
