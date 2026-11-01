#!/usr/bin/env python3
"""Refuse an Apple release unless the commit is on main and covered by green CI.

Covered means: the nearest first-parent ancestor with a successful ci.yml run,
and every change since it lies under a path ci.yml does not build. Exact-SHA
matching is not enough because ci.yml skips Android-only pushes, cancels
superseded runs on main, and the release job's Formula/ commit triggers no
workflow (spec 2026-11-01-remote-release-pipeline-design.md, Part A §2).
"""
from __future__ import annotations

import os
import subprocess
import sys
from typing import List, Optional, Set, Tuple

IGNORED_PREFIXES: Tuple[str, ...] = ("CodeRelayAndroid/", "Formula/")
WALK_LIMIT = 50


def find_green_ancestor(chain: List[str], green: Set[str], limit: int = WALK_LIMIT) -> Optional[str]:
    """First SHA of `chain` (newest first) within `limit` that had a green CI run."""
    for sha in chain[:limit]:
        if sha in green:
            return sha
    return None


def uncovered_path(changed: List[str], prefixes: Tuple[str, ...] = IGNORED_PREFIXES) -> Optional[str]:
    """First changed path CI would have built, i.e. not under any ignored directory."""
    for path in changed:
        if not path.startswith(prefixes):
            return path
    return None


def _run(*args: str) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()


class _GreenRuns:
    """Set-like view of "has a successful ci.yml run", asked of GitHub per SHA so
    the walk stops at the first hit instead of querying all 50 commits."""

    def __init__(self, repo: str) -> None:
        self.repo = repo

    def __contains__(self, sha: object) -> bool:
        count = _run("gh", "api",
                     f"repos/{self.repo}/actions/workflows/ci.yml/runs?head_sha={sha}&status=success",
                     "--jq", ".total_count")
        return int(count or "0") > 0


def main(argv: List[str]) -> int:
    if len(argv) != 1:
        print("usage: ci_gate.py <sha>", file=sys.stderr)
        return 2
    sha = argv[0]
    repo = os.environ["GITHUB_REPOSITORY"]
    if subprocess.run(["git", "merge-base", "--is-ancestor", sha, "origin/main"]).returncode != 0:
        print(f"{sha} is not on main")
        return 1
    chain = _run("git", "rev-list", "--first-parent", f"--max-count={WALK_LIMIT}", sha).split()
    ancestor = find_green_ancestor(chain, _GreenRuns(repo))  # type: ignore[arg-type]
    if ancestor is None:
        print(f"no green CI run within {WALK_LIMIT} commits of {sha}")
        return 1
    changed = _run("git", "diff", "--name-only", ancestor, sha).splitlines()
    path = uncovered_path(changed)
    if path is not None:
        print(f"{path} changed since green {ancestor}; wait for CI on {sha}")
        return 1
    print(f"covered by {ancestor}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
