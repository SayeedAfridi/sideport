#!/bin/bash
# Package an app into a styled disk image: volume icon, background, and the
# window laid out the way it will open on someone else's Mac.
#
#   scripts/make-dmg.sh <app> <output.dmg> [volume name]
#
# The layout lives in the volume's own .DS_Store, which is why this has to
# mount a read/write image, let Finder arrange it, and only then compress. The
# window is not decoration: this image has no installer, so the drag *is* the
# install, and it has to be obvious without instructions.
set -euo pipefail

APP="${1:?usage: make-dmg.sh <app> <output.dmg> [volume name]}"
DMG="${2:?usage: make-dmg.sh <app> <output.dmg> [volume name]}"
VOLUME="${3:-Sideport}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Must match the size the background is drawn at, in scripts/make-dmg-background.swift.
WINDOW_WIDTH=640
WINDOW_HEIGHT=400
ICON_SIZE=128

die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

[ -d "$APP" ] || die "no app at $APP"
NAME="$(basename "$APP")"

WORK="$(mktemp -d)"
STAGE="$WORK/stage"
MOUNT=""
cleanup() {
    [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
swift "$ROOT/scripts/make-dmg-background.swift" "$STAGE/.background/background.tiff" >/dev/null

# Sized from the payload with room for the filesystem's own overhead; UDZO
# compression at the end reclaims whatever is left unused.
MEGABYTES=$(( $(du -sm "$STAGE" | cut -f1) + 40 ))
hdiutil create -volname "$VOLUME" -srcfolder "$STAGE" -fs HFS+ \
    -format UDRW -size "${MEGABYTES}m" "$WORK/rw.dmg" >/dev/null

# Captured first, parsed second, and parsed with `tail` rather than `head`:
# under `set -o pipefail` a `head` that exits at its first match kills the
# still-writing command with SIGPIPE and takes the whole script with it.
ATTACHED=$(hdiutil attach "$WORK/rw.dmg" -nobrowse -noautoopen)
MOUNT=$(printf '%s\n' "$ATTACHED" | grep -o '/Volumes/.*' | tail -1)
[ -n "$MOUNT" ] || die "could not mount the working image"

# Ask Finder about the volume by the name it actually mounted under, not the
# name we asked for. If a volume called $VOLUME is already mounted — an earlier
# build of this very image, still sitting in someone's sidebar — macOS mounts
# ours as "$VOLUME 1", and every instruction below would then be aimed at the
# other one, which reports nothing worse than a puzzling -10006. The image
# still *carries* $VOLUME as its volume name, so what ships is unaffected.
MOUNTED_NAME="$(basename "$MOUNT")"

# Finder is the only thing that can write an icon view's .DS_Store, so it has to
# be asked. That needs permission to control Finder, which a machine that has
# never been asked will prompt for — and a machine running this unattended will
# simply refuse. An unstyled image is still a correct image, so this warns
# rather than fails.
if ! LAYOUT=$(osascript 2>&1 <<APPLESCRIPT
tell application "Finder"
    tell disk "$MOUNTED_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 140, $((200 + WINDOW_WIDTH)), $((140 + WINDOW_HEIGHT))}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to $ICON_SIZE
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "$NAME" of container window to {161, 180}
        set position of item "Applications" of container window to {479, 180}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
APPLESCRIPT
)
then
    printf '\033[33mwarning:\033[0m Finder would not arrange the window, so the image is unstyled:\n' >&2
    printf '         %s\n' "$LAYOUT" >&2
    printf '         If it was refused outright, grant this terminal control of Finder in\n' >&2
    printf '         System Settings > Privacy & Security > Automation.\n' >&2
fi

# The volume icon goes on last, and only now.
#
# It is the app's own compiled icns, so the two can never drift. Staging it
# before Finder ran would have thrown it away: a volume already flagged as
# having a custom icon has its .VolumeIcon.icns absorbed the moment Finder
# opens it, and the file is then deleted — leaving the flag set over nothing.
#
# Only the icon *inside* the image is worth setting. A custom icon on the .dmg
# file itself lives in an extended attribute, which does not survive being
# downloaded, while this one is part of the filesystem being shipped.
SETFILE=$(xcrun --find SetFile 2>/dev/null || true)
if [ -f "$APP/Contents/Resources/AppIcon.icns" ] && [ -n "$SETFILE" ]; then
    cp "$APP/Contents/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
    "$SETFILE" -a C "$MOUNT"
else
    printf '\033[33mwarning:\033[0m no volume icon: the app has no AppIcon.icns, or SetFile is missing.\n' >&2
fi

sync
hdiutil detach "$MOUNT" >/dev/null || hdiutil detach "$MOUNT" -force >/dev/null
MOUNT=""

rm -f "$DMG"
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
