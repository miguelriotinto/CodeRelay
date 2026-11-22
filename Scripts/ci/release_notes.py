#!/usr/bin/env python3
"""Adds the notarized Mac app DMG to a release body written by release.yml.

The `release` job writes the body before the DMG exists; the `mac-dmg` job
calls this only AFTER its upload succeeded, so a failed DMG build never leaves
a link to a missing asset. Idempotent: re-running the job rewrites the same
rows instead of stacking copies.

    release_notes.py add-mac-dmg <body.md> <asset> <url> <version> <build> <sha256>
"""
import sys

TESTFLIGHT_ROW = "| iOS / macOS app | TestFlight | — |"
STORE_ROW = "| iOS / macOS app | TestFlight · App Store | — |"
MARK = "<!-- mac-dmg -->"


def add_mac_dmg(body: str, asset: str, url: str, version: str, build: str, sha: str) -> str:
    # Drop anything a previous run of this job added.
    lines = [l for l in body.splitlines() if MARK not in l]
    out = []
    for line in lines:
        # The anchor in either form: as `release` wrote it, or as a previous run
        # of this job left it.
        if line.strip() in (TESTFLIGHT_ROW, STORE_ROW):
            out.append(f"| macOS app (Apple silicon + Intel, macOS 14+) | [`{asset}`]({url}) {MARK} | {version} ({build}) |")
            out.append(STORE_ROW)
            continue
        out.append(line)
        if line.strip() == "### macOS":
            # Every inserted line carries MARK (the last is only MARK, an HTML
            # comment that renders as nothing and ends the paragraph), so a
            # re-run removes exactly what it added.
            out.append(f"**Code[Relay] for Mac** {version} ({build}): [`{asset}`]({url}) — signed with Developer ID and "
                       f"notarized by Apple, so it opens without a Gatekeeper warning. Open the DMG and drag the app "
                       f"to Applications. The same app is on TestFlight and the Mac App Store. {MARK}")
            out.append(f"SHA-256 `{sha}` {MARK}")
            out.append(MARK)
    return "\n".join(out) + ("\n" if body.endswith("\n") else "")


def main(argv):
    if len(argv) != 8 or argv[1] != "add-mac-dmg":
        print(__doc__)
        return 2
    path, asset, url, version, build, sha = argv[2:]
    with open(path) as f:
        body = f.read()
    with open(path, "w") as f:
        f.write(add_mac_dmg(body, asset, url, version, build, sha))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
