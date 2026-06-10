#!/usr/bin/env bash
#
# Publish the Android release APK to a GitHub release with a TIMESTAMPED asset name.
#
# Naming convention (REQUIRED — do not deviate):
#
#     claude-relay-android-<versionName>-<YYYYMMDD-HHMM>-debug-signed.apk
#
#   e.g. claude-relay-android-0.3-m4-terminal-20260610-0654-debug-signed.apk
#
#   - <versionName> is read from app/build.gradle.kts (e.g. "0.3-m4"), with the
#     "-terminal" qualifier appended (the milestone these debug builds track).
#   - <YYYYMMDD-HHMM> is the local build/upload time, so every upload is uniquely
#     named and sorts chronologically.
#   - "debug-signed" because these sideload builds use the debug keystore (so they
#     install in-place over prior assets — same signer).
#
# It uploads the new stamped asset, then deletes ALL OTHER *.apk assets on the
# release so only the newest stamped build remains.
#
# Usage:
#   scripts/publish-release-apk.sh [--build] [--tag <release-tag>] [--qualifier <q>]
#     --build         run `assembleRelease` first (default: use the existing APK)
#     --tag           GitHub release tag (default: android-v0.3-m4)
#     --qualifier     name qualifier after versionName (default: terminal)
#
# Run from anywhere; paths are resolved relative to this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO="miguelriotinto/clauderelay"

TAG="android-v0.3-m4"
QUALIFIER="terminal"
DO_BUILD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) DO_BUILD=1; shift ;;
    --tag) TAG="$2"; shift 2 ;;
    --qualifier) QUALIFIER="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

APK="$ANDROID_DIR/app/build/outputs/apk/release/app-release.apk"

if [[ "$DO_BUILD" == "1" ]]; then
  echo "==> assembleRelease"
  ( cd "$ANDROID_DIR" && ./gradlew :app:assembleRelease )
fi

[[ -f "$APK" ]] || { echo "ERROR: $APK not found (run with --build, or build first)." >&2; exit 1; }

# Derive versionName from the app module (single source of truth).
VERSION_NAME="$(grep -E 'versionName' "$ANDROID_DIR/app/build.gradle.kts" \
  | head -1 | sed -E 's/.*versionName *= *"([^"]+)".*/\1/')"
[[ -n "$VERSION_NAME" ]] || { echo "ERROR: could not read versionName." >&2; exit 1; }

STAMP="$(date +%Y%m%d-%H%M)"
ASSET_NAME="claude-relay-android-${VERSION_NAME}-${QUALIFIER}-${STAMP}-debug-signed.apk"
STAGED="$(mktemp -d)/${ASSET_NAME}"
cp "$APK" "$STAGED"

echo "==> versionName : $VERSION_NAME"
echo "==> timestamp   : $STAMP"
echo "==> asset name  : $ASSET_NAME"
echo "==> sha-256     : $(shasum -a 256 "$STAGED" | awk '{print $1}')"

echo "==> uploading to release $TAG"
gh release upload "$TAG" "$STAGED" --repo "$REPO"

# Remove every OTHER .apk asset so only the newest stamped build remains.
echo "==> pruning older .apk assets"
gh release view "$TAG" --repo "$REPO" --json assets -q '.assets[].name' \
  | grep -E '\.apk$' \
  | grep -vF "$ASSET_NAME" \
  | while read -r old; do
      echo "    deleting $old"
      gh release delete-asset "$TAG" "$old" --repo "$REPO" --yes
    done

echo "==> done. Current assets:"
gh release view "$TAG" --repo "$REPO" --json assets -q '.assets[].name'
