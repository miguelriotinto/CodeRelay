import os
import sys
import unittest

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, ".."))

from formula import Bottle, render  # noqa: E402

with open(os.path.join(HERE, "..", "..", "..", "Formula", "coderelay.rb")) as f:
    FIXTURE = f.read()

REPO = "miguelriotinto/CodeRelay"
B = Bottle("arm64_sequoia", ":any_skip_relocation", "a" * 64)


class FormulaTests(unittest.TestCase):
    def test_render_url_and_sha(self):
        out = render(FIXTURE, REPO, "v0.3.39", "b" * 64, None)
        self.assertIn('url "https://github.com/miguelriotinto/CodeRelay/archive/refs/tags/v0.3.39.tar.gz"', out)
        self.assertIn(f'sha256 "{"b" * 64}"', out)
        self.assertIn('head "https://github.com/miguelriotinto/CodeRelay.git", branch: "main"', out)

    def test_render_adds_bottle(self):
        out = render(FIXTURE, REPO, "v0.3.39", "b" * 64, B)
        self.assertIn('root_url "https://github.com/miguelriotinto/CodeRelay/releases/download/v0.3.39"', out)
        self.assertIn(f'sha256 cellar: :any_skip_relocation, arm64_sequoia: "{"a" * 64}"', out)

    def test_render_replaces_existing_bottle(self):
        once = render(FIXTURE, REPO, "v0.3.39", "b" * 64, B)
        twice = render(once, REPO, "v0.3.40", "c" * 64, B._replace(sha256="d" * 64))
        self.assertEqual(twice.count("bottle do"), 1)
        self.assertNotIn("a" * 64, twice)

    def test_render_idempotent(self):
        once = render(FIXTURE, REPO, "v0.3.39", "b" * 64, B)
        self.assertEqual(render(once, REPO, "v0.3.39", "b" * 64, B), once)

    def test_render_without_bottle_removes_it(self):
        once = render(FIXTURE, REPO, "v0.3.39", "b" * 64, B)
        self.assertEqual(render(once, REPO, "v0.3.39", "b" * 64, None),
                         render(FIXTURE, REPO, "v0.3.39", "b" * 64, None))

    def test_install_block_untouched(self):
        out = render(FIXTURE, REPO, "v0.3.39", "b" * 64, B)
        self.assertEqual(out.split("def install")[1], FIXTURE.split("def install")[1])


if __name__ == "__main__":
    unittest.main()
