import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from asc import app_id_for, highest_build, next_build_number, what_to_test_text  # noqa: E402


class AscTests(unittest.TestCase):
    def test_highest_ignores_non_integer(self):
        self.assertEqual(highest_build(["198", "1.4.1", "abc", "200", "199"]), 200)

    def test_highest_empty(self):
        self.assertIsNone(highest_build([]))

    def test_next_build_from_asc(self):
        self.assertEqual(next_build_number(201, 197), 202)

    def test_next_build_floor_wins(self):
        self.assertEqual(next_build_number(150, 201), 202)

    def test_next_build_no_history(self):
        self.assertEqual(next_build_number(None, 201), 202)

    def test_what_to_test_empty(self):
        self.assertEqual(what_to_test_text([]), "No changes since the previous build.")

    def test_what_to_test_lines(self):
        self.assertEqual(what_to_test_text(["fix: b", "feat: a"]), "- fix: b\n- feat: a")

    def test_what_to_test_truncates(self):
        text = what_to_test_text([f"commit {i} " + "x" * 80 for i in range(200)], limit=1000)
        self.assertLessEqual(len(text), 1000)
        self.assertTrue(text.splitlines()[-1].startswith("- … and "))

    def test_app_lookup_requires_exact_bundle_id(self):
        apps = [{"id": "mac", "attributes": {"bundleId": "com.claude.relay.mac"}},
                {"id": "ios", "attributes": {"bundleId": "com.claude.relay"}}]
        self.assertEqual(app_id_for(apps, "com.claude.relay"), "ios")
        self.assertEqual(app_id_for(apps, "com.claude.relay.mac"), "mac")
        self.assertIsNone(app_id_for(apps[:1], "com.claude.relay"))


if __name__ == "__main__":
    unittest.main()
