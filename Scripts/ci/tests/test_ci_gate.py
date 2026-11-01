import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from ci_gate import find_green_ancestor, uncovered_path  # noqa: E402


class GateTests(unittest.TestCase):
    def test_exact_sha_green(self):
        self.assertEqual(find_green_ancestor(["a", "b"], {"a"}), "a")

    def test_nearest_ancestor(self):
        self.assertEqual(find_green_ancestor(["a", "b", "c"], {"c", "b"}), "b")

    def test_walk_limit(self):
        chain = [str(i) for i in range(60)]
        self.assertIsNone(find_green_ancestor(chain, {"55"}, limit=50))

    def test_android_and_formula_only_is_covered(self):
        self.assertIsNone(uncovered_path(["CodeRelayAndroid/app/x.kt", "Formula/clauderelay.rb"]))

    def test_app_path_breaks_coverage(self):
        self.assertEqual(uncovered_path(["Formula/clauderelay.rb", "CodeRelayApp/Views/A.swift"]),
                         "CodeRelayApp/Views/A.swift")

    def test_prefix_is_a_directory_not_a_string_prefix(self):
        self.assertEqual(uncovered_path(["FormulaNotes.md"]), "FormulaNotes.md")


if __name__ == "__main__":
    unittest.main()
