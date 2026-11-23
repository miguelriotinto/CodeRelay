#!/bin/zsh
# Packs a signed .app into a compressed DMG whose Finder window is the
# designed installer: the app on the left, Applications on the right, a drawn
# drag arrow between them (Scripts/ci/dmg-background.swift). Called by
# mac-dmg.sh before the DMG is signed and notarized; runnable on its own to
# preview the window:
#
#   Scripts/ci/make-dmg.sh <app> <out.dmg> <volname>
#
# Finder has to see the volume to write the window layout into its .DS_Store,
# so the image is mounted browsable (never -nobrowse) while the layout is
# applied — this needs a logged-in GUI session with Finder automation allowed,
# which GitHub's macOS runners have.
set -euo pipefail; [[ -n "${DMG_TRACE:-}" ]] && set -x
[[ $# -eq 3 ]] || { echo "usage: make-dmg.sh <app> <out.dmg> <volname>" >&2; exit 1; }
app=${1:A} out=${2:A} vol=$3 here=${0:A:h}
[[ -d "$app" ]] || { echo "make-dmg: no app at $app" >&2; exit 2; }
[[ ! -e "/Volumes/$vol" ]] || { echo "make-dmg: /Volumes/$vol is already mounted; eject it first" >&2; exit 2; }
name=${app:t}
# The volume icon is the app's full-bleed .icns (CFBundleIconFile), not the
# Assets.car icon macOS 26 draws for the app itself.
icon=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$app/Contents/Info.plist" 2>/dev/null) || icon=""
icns="$app/Contents/Resources/${icon%.icns}.icns"
[[ -f "$icns" ]] || { echo "make-dmg: no icon at $icns" >&2; exit 2; }
stage=$(mktemp -d) rw="$(mktemp -u).dmg" dev=""
cleanup() { [[ -n "$dev" ]] && hdiutil detach "$dev" -force -quiet 2>/dev/null; rm -rf "$stage" "$rw"; }
trap cleanup EXIT

ditto "$app" "$stage/$name"     # ditto keeps the signature's xattrs and the stapled ticket
ln -s /Applications "$stage/Applications"
mkdir "$stage/.background"
swift "$here/dmg-background.swift" "$stage/.background" \
  || { echo "make-dmg: the background didn't render" >&2; exit 2; }

size_mb=$(( $(du -sm "$stage" | cut -f1) + 40 ))
hdiutil create -quiet -volname "$vol" -srcfolder "$stage" -fs HFS+ -format UDRW -size "${size_mb}m" "$rw"
dev=$(hdiutil attach "$rw" -readwrite -noverify -noautoopen | awk -F'\t' '/Apple_HFS/ {gsub(/ +$/,"",$1); print $1}')
mnt="/Volumes/$vol"
[[ -d "$mnt" ]] || { echo "make-dmg: the image didn't mount at $mnt" >&2; exit 3; }

# Finder registers a new disk a moment after the mount; wait for it before laying it out.
for _ in {1..40}; do osascript -e "tell application \"Finder\" to exists disk \"$vol\"" 2>/dev/null | grep -q true && break; sleep 0.25; done

# Window content is 660x400 points (the background's size); bounds add Finder's
# 28-point title bar. Icon positions are icon centres, matching appCenter /
# appsCenter in dmg-background.swift.
layout() {
  osascript - "$vol" "$name" <<'APPLESCRIPT'
on run {vol, appName}
  tell application "Finder"
    tell disk vol
      open
      set w to container window
      set current view of w to icon view
      set toolbar visible of w to false
      set statusbar visible of w to false
      set pathbar visible of w to false
      set sidebar width of w to 0
      set bounds of w to {200, 140, 860, 568}
      set o to icon view options of w
      set arrangement of o to not arranged
      set icon size of o to 128
      set text size of o to 12
      set shows item info of o to false
      set shows icon preview of o to false
      set background picture of o to file ".background:background.png"
      set position of item appName of w to {165, 215}
      set position of item "Applications" of w to {495, 215}
      update without registering applications
      delay 1
      close
      open
      delay 1
      close
    end tell
  end tell
end run
APPLESCRIPT
}
# Finder on a freshly booted runner can time out the first Apple Event.
for attempt in 1 2 3; do layout && break
  [[ $attempt -lt 3 ]] || { echo "make-dmg: Finder refused the window layout" >&2; exit 4; }
  sleep 3
done

# Wait for Finder to flush the layout. The volume icon goes in afterwards:
# Finder drops a .VolumeIcon.icns that was there while it laid the window out.
for _ in {1..20}; do [[ -f "$mnt/.DS_Store" ]] && break; sleep 0.5; done
[[ -f "$mnt/.DS_Store" ]] || { echo "make-dmg: Finder didn't write the window layout" >&2; exit 4; }
cp "$icns" "$mnt/.VolumeIcon.icns"
SetFile -a C "$mnt"
SetFile -a V "$mnt/.background" "$mnt/.VolumeIcon.icns" 2>/dev/null || true
rm -rf "$mnt/.fseventsd" "$mnt/.Trashes" 2>/dev/null || true
chmod -Rf go-w "$mnt" 2>/dev/null || true
sync
hdiutil detach "$dev" -quiet; dev=""
rm -f "$out"
hdiutil convert "$rw" -quiet -format UDZO -imagekey zlib-level=9 -o "$out"
echo "make-dmg: $out"
