#!/usr/bin/env python3
"""App Store Connect helper for apple-release.yml.

  asc.py next-build   --bundle-id ID --floor N
  asc.py what-to-test --bundle-id ID --build N --notes-file PATH

Auth comes from ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (the .p8). The key
is read from disk and never printed.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional

API = "https://api.appstoreconnect.apple.com"
WHAT_TO_TEST_LIMIT = 4000  # App Store Connect's whatsNew cap, in characters
LOCALE = "en-US"


def highest_build(versions: List[str]) -> Optional[int]:
    """Largest build number that is a plain integer; legacy dotted ones are ignored."""
    numbers = [int(v) for v in versions if v.isdigit()]
    return max(numbers) if numbers else None


def next_build_number(highest: Optional[int], floor: int) -> int:
    """project.yml's value is only a floor; App Store Connect's highest normally wins."""
    return max(highest or 0, floor) + 1


def what_to_test_text(subjects: List[str], limit: int = WHAT_TO_TEST_LIMIT) -> str:
    if not subjects:
        return "No changes since the previous build."
    lines = ["- " + s for s in subjects]
    text = "\n".join(lines)
    if len(text) <= limit:
        return text
    # Keep the newest whole lines that fit alongside the "and N more" marker.
    for keep in range(len(lines) - 1, -1, -1):
        text = "\n".join(lines[:keep] + [f"- … and {len(lines) - keep} more"])
        if len(text) <= limit:
            return text
    return text[:limit]


# --- network ----------------------------------------------------------------

def _token() -> str:
    import jwt  # PyJWT[crypto]; imported here so the unit tests need no third-party package

    with open(os.path.expanduser(os.environ["ASC_KEY_PATH"])) as f:
        key = f.read()
    now = int(time.time())
    payload = {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 15 * 60,
               "aud": "appstoreconnect-v1"}
    return jwt.encode(payload, key, algorithm="ES256",
                      headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


def _request(method: str, path: str, body: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    # A fresh token per call: the What-to-Test poll outlives one token's 15 minutes.
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method, headers={
        "Authorization": "Bearer " + _token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as e:
        raise SystemExit(f"{method} {path} → HTTP {e.code}: {e.read().decode(errors='replace')}")
    return json.loads(raw) if raw else {}


def app_id_for(apps: List[Dict[str, Any]], bundle_id: str) -> Optional[str]:
    """filter[bundleId] is not guaranteed exact: com.claude.relay can also list
    com.claude.relay.mac, so re-check before trusting the first entry."""
    for app in apps:
        if app["attributes"]["bundleId"] == bundle_id:
            return app["id"]
    return None


def _app_id(bundle_id: str) -> str:
    q = urllib.parse.urlencode({"filter[bundleId]": bundle_id})
    found = app_id_for(_request("GET", f"/v1/apps?{q}")["data"], bundle_id)
    if found is None:
        raise SystemExit(f"no App Store Connect app with bundle id {bundle_id}")
    return found


def _builds(app_id: str, **filters: str) -> List[Dict[str, Any]]:
    params = {"filter[app]": app_id, "limit": "200", "sort": "-uploadedDate"}
    params.update({f"filter[{k}]": v for k, v in filters.items()})
    return _request("GET", "/v1/builds?" + urllib.parse.urlencode(params))["data"]


def cmd_next_build(args: argparse.Namespace) -> int:
    versions = [b["attributes"]["version"] for b in _builds(_app_id(args.bundle_id))]
    print(next_build_number(highest_build(versions), args.floor))
    return 0


def _wait_until_valid(app_id: str, build: int, poll: int, timeout: int) -> str:
    deadline = time.monotonic() + timeout
    while True:
        found = _builds(app_id, version=str(build))
        state = found[0]["attributes"]["processingState"] if found else "NOT_YET_LISTED"
        print(f"build {build}: {state}", flush=True)
        if state == "VALID":
            return found[0]["id"]
        if state in ("FAILED", "INVALID"):
            raise SystemExit(f"build {build} processing ended {state}")
        if time.monotonic() > deadline:
            raise SystemExit(f"build {build} still {state} after {timeout}s")
        time.sleep(poll)


def cmd_what_to_test(args: argparse.Namespace) -> int:
    with open(args.notes_file) as f:
        subjects = [line.strip() for line in f if line.strip()]
    text = what_to_test_text(subjects)
    build_id = _wait_until_valid(_app_id(args.bundle_id), args.build,
                                 args.poll_seconds, args.timeout_seconds)
    existing = [loc for loc in _request("GET", f"/v1/builds/{build_id}/betaBuildLocalizations")["data"]
                if loc["attributes"]["locale"] == LOCALE]
    if existing:
        _request("PATCH", f"/v1/betaBuildLocalizations/{existing[0]['id']}", {"data": {
            "type": "betaBuildLocalizations", "id": existing[0]["id"],
            "attributes": {"whatsNew": text}}})
    else:
        _request("POST", "/v1/betaBuildLocalizations", {"data": {
            "type": "betaBuildLocalizations",
            "attributes": {"locale": LOCALE, "whatsNew": text},
            "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
    print(f"What to Test set on build {args.build} ({len(subjects)} commits)")
    return 0


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(prog="asc.py")
    sub = parser.add_subparsers(dest="command", required=True)
    nb = sub.add_parser("next-build")
    nb.add_argument("--bundle-id", required=True)
    nb.add_argument("--floor", type=int, required=True)
    nb.set_defaults(func=cmd_next_build)
    wt = sub.add_parser("what-to-test")
    wt.add_argument("--bundle-id", required=True)
    wt.add_argument("--build", type=int, required=True)
    wt.add_argument("--notes-file", required=True)
    wt.add_argument("--poll-seconds", type=int, default=60)
    wt.add_argument("--timeout-seconds", type=int, default=5100)
    wt.set_defaults(func=cmd_what_to_test)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
