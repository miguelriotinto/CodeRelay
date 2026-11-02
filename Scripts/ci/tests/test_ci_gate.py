import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from ci_gate import changed_paths, find_green_ancestor, uncovered_path  # noqa: E402


class GateTests(unittest.TestCase):
    def test_exact_sha_green(self):
        self.assertEqual(find_green_ancestor(["a", "b"], {"a"}), "a")

    def test_nearest_ancestor(self):
        self.assertEqual(find_green_ancestor(["a", "b", "c"], {"c", "b"}), "b")

    def test_walk_limit(self):
        chain = [str(i) for i in range(60)]
        self.assertIsNone(find_green_ancestor(chain, {"55"}, limit=50))

    def test_android_and_formula_only_is_covered(self):
        self.assertIsNone(uncovered_path(["CodeRelayAndroid/app/x.kt", "Formula/coderelay.rb"]))

    def test_app_path_breaks_coverage(self):
        self.assertEqual(uncovered_path(["Formula/coderelay.rb", "CodeRelayApp/Views/A.swift"]),
                         "CodeRelayApp/Views/A.swift")

    def test_prefix_is_a_directory_not_a_string_prefix(self):
        self.assertEqual(uncovered_path(["FormulaNotes.md"]), "FormulaNotes.md")

    def test_move_out_of_an_app_dir_is_not_covered(self):
        # Rename detection would report only the new CodeRelayAndroid/ path.
        with tempfile.TemporaryDirectory() as repo:
            def git(*args):
                return subprocess.run(["git", "-C", repo, *args], check=True,
                                      capture_output=True, text=True).stdout.strip()
            git("init", "-q")
            git("config", "user.email", "t@example.com")
            git("config", "user.name", "t")
            os.makedirs(os.path.join(repo, "CodeRelayApp"))
            os.makedirs(os.path.join(repo, "CodeRelayAndroid"))
            with open(os.path.join(repo, "CodeRelayApp", "A.swift"), "w") as f:
                f.write("let a = 1\n" * 20)
            git("add", "-A")
            git("commit", "-qm", "one")
            base = git("rev-parse", "HEAD")
            git("mv", "CodeRelayApp/A.swift", "CodeRelayAndroid/A.swift")
            git("commit", "-qm", "two")
            changed = changed_paths(base, git("rev-parse", "HEAD"), cwd=repo)
            self.assertEqual(uncovered_path(changed), "CodeRelayApp/A.swift")


if __name__ == "__main__":
    unittest.main()
