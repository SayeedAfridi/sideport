#!/bin/bash
# Build a Release DMG signed with whatever identity this Mac has.
#
# This is NOT a distributable build. Without a Developer ID certificate it
# cannot be notarized, so Gatekeeper will refuse it on any Mac that did not
# build it. It is the real Release configuration though — optimised, and
# without the debug entitlement Xcode injects for development signing.
#
# When the Developer ID certificate exists, use scripts/release.sh instead.
set -euo pipefail

TEAM="NU2JM39S5P"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.release"
DERIVED="$BUILD/DerivedData"
APP="$DERIVED/Build/Products/Release/Sideport.app"
DMG="$BUILD/Sideport.dmg"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

DEBUG_ENTITLEMENT=no
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 "Developer ID Application.*$TEAM" | sed 's/.*"\(.*\)"/\1/' || true)
NOTARIZABLE=yes
if [ -z "$IDENTITY" ]; then
    DEBUG_ENTITLEMENT=no
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -m1 "Apple Development" | sed 's/.*"\(.*\)"/\1/' || true)
    NOTARIZABLE=no
fi
[ -n "$IDENTITY" ] || die "no code signing identity at all"

echo "signing identity: $IDENTITY"
[ "$NOTARIZABLE" = no ] && echo "  (development identity — this build will not run on other Macs)"

step "Clean"
rm -rf "$BUILD"
mkdir -p "$BUILD"

step "Regenerate project"
(cd "$ROOT" && xcodegen generate >/dev/null)

step "Test"
(cd "$ROOT" && swift test 2>&1 | tail -2)

step "Build Release"
# Xcode injects get-task-allow whenever it signs with a development identity,
# and it must be left alone. Stripping it looks like the tidy thing to do, but
# on a development certificate that entitlement is what marks the binary as a
# development build: without it macOS treats the bundle as a distribution one,
# which a development certificate cannot authorise, and *refuses to launch the
# extension at all*. The app still opens and the mount still browses from the
# replica, so the only symptom is that every write fails and change detection
# falls back to polling — which reads as a bug in the provider.
#
# With a Developer ID certificate the export drops it properly. Until then it
# stays, and that is one of the things this build cannot be clean about.
xcodebuild -project "$ROOT/Sideport.xcodeproj" \
    -scheme Sideport \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    -destination 'platform=macOS' \
    build | tail -3
[ -d "$APP" ] || die "no app at $APP"

step "Verify what we built"
APPEX="$APP/Contents/PlugIns/SideportFileProvider.appex"
[ -d "$APPEX" ] || die "the extension is missing — the mount would never appear"

# Each fact is captured into a variable before it is judged. Reading these
# through a pipeline under `set -o pipefail` made the checks depend on the exit
# status of `codesign` rather than on what it said, which produced a confident
# "not hardened" about a bundle that was hardened.
for target in "$APPEX" "$APP"; do
    name=$(basename "$target")

    codesign --verify --strict "$target" || die "$name fails signature verification"

    ENTS=$(codesign -d --entitlements - --xml "$target" 2>/dev/null \
        | plutil -convert xml1 -o - - 2>/dev/null || true)
    SIG=$(codesign -d --verbose=2 "$target" 2>&1 || true)

    case "$ENTS:$NOTARIZABLE" in
        *get-task-allow*:yes)
            die "$name still carries get-task-allow; notarization would reject it" ;;
        *get-task-allow*:no)
            DEBUG_ENTITLEMENT=yes ;;
        *:yes) : ;;
        *:no)
            die "$name has no get-task-allow, so a development certificate cannot authorise it and the extension will not launch" ;;
    esac
    case "$ENTS" in
        *"$TEAM.dev.afridi.sideport"*) : ;;
        *) die "$name lost its App Group — the extension and app could not share a store" ;;
    esac
    case "$SIG" in
        *runtime*) : ;;
        *) die "$name is not hardened: $(echo "$SIG" | grep -o 'flags=[^ ]*' || echo 'no flags reported')" ;;
    esac

    printf '  \033[32m✓\033[0m %s — hardened, App Group intact, signature verifies\n' "$name"
done

step "Package"
"$ROOT/scripts/make-dmg.sh" "$APP" "$DMG" "Sideport"
codesign --sign "$IDENTITY" --timestamp "$DMG" 2>/dev/null \
    || codesign --sign "$IDENTITY" "$DMG"

step "Check the image opens and holds a valid app"
MOUNT=$(hdiutil attach "$DMG" -nobrowse -readonly | grep -o '/Volumes/.*' | head -1)
codesign --verify --deep --strict "$MOUNT/Sideport.app" && echo "  app inside the image verifies"
hdiutil detach "$MOUNT" >/dev/null

echo
echo "Built: $DMG  ($(du -h "$DMG" | cut -f1))"
if [ "$NOTARIZABLE" = no ]; then
    echo
    echo "Signed for this Mac only — not notarized, so Gatekeeper will refuse it"
    echo "anywhere else. It also still carries get-task-allow, because a"
    echo "development certificate cannot authorise a build without it."
    echo
    echo "To install:  open $DMG   →  drag Sideport to Applications"
fi
