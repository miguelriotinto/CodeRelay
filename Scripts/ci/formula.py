#!/usr/bin/env python3
"""Point Formula/coderelay.rb (or the tap's copy) at a release tag.

  formula.py <formula.rb> --repo R --tag T --source-sha S [--bottle-json F]

Rewrites `url`, the source `sha256` directly after it and the `bottle do`
block in place; everything else in the formula is left byte-for-byte alone.
Re-rendering for the same inputs is a no-op, so a re-run tap job is harmless.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from typing import List, NamedTuple, Optional


class Bottle(NamedTuple):
    tag: str      # e.g. arm64_sequoia
    cellar: str   # Ruby literal: :any_skip_relocation, :any or "/opt/homebrew/Cellar"
    sha256: str


_URL = re.compile(r'^(  url ")[^"]*(")$\n(  sha256 ")[0-9a-f]*(")$', re.M)
_BOTTLE = re.compile(r'\n  bottle do\n.*?\n  end\n', re.S)
_HEAD = re.compile(r'^  head .*$\n', re.M)


def render(text: str, repo: str, tag: str, source_sha: str, bottle: Optional[Bottle]) -> str:
    url = f"https://github.com/{repo}/archive/refs/tags/{tag}.tar.gz"
    text, n = _URL.subn(lambda m: f"{m[1]}{url}{m[2]}\n{m[3]}{source_sha}{m[4]}", text, count=1)
    if n != 1:
        raise ValueError("formula has no `url` line followed by its `sha256`")
    text = _BOTTLE.sub("", text, count=1)
    if bottle is not None:
        block = (f'\n  bottle do\n'
                 f'    root_url "https://github.com/{repo}/releases/download/{tag}"\n'
                 f'    sha256 cellar: {bottle.cellar}, {bottle.tag}: "{bottle.sha256}"\n'
                 f'  end\n')
        text, n = _HEAD.subn(lambda m: m[0] + block, text, count=1)
        if n != 1:
            raise ValueError("formula has no `head` line to place the bottle block after")
    return text


def _cellar_literal(value: str) -> str:
    if value.startswith("/"):
        return f'"{value}"'
    return value if value.startswith(":") else ":" + value


def bottle_from_json(path: str) -> Bottle:
    """The single formula/tag entry of `brew bottle --json` output."""
    with open(path) as f:
        (entry,) = json.load(f).values()
    (tag, info), = entry["bottle"]["tags"].items()
    cellar = info.get("cellar") or entry["bottle"]["cellar"]
    return Bottle(tag, _cellar_literal(cellar), info["sha256"])


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(prog="formula.py")
    parser.add_argument("formula")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--bottle-json")
    args = parser.parse_args(argv)
    bottle = bottle_from_json(args.bottle_json) if args.bottle_json else None
    with open(args.formula) as f:
        text = f.read()
    with open(args.formula, "w") as f:
        f.write(render(text, args.repo, args.tag, args.source_sha, bottle))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
