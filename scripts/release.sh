#!/bin/bash
# Build, sign, notarize and staple a distributable Sideport.dmg.
#
# Every step verifies rather than assumes: an unsigned nested appex, a stray
# get-task-allow, or a notarization that "succeeded" without stapling all look
# like success until a user on another Mac double-clicks the thing.
set -euo pipefail

TEAM="NU2JM39S5P"
KEYCHAIN_PROFILE="${NOTARY_PROFILE:-sideport-notary}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.release"
ARCHIVE="$BUILD/Sideport.xcarchive"
EXPORT="$BUILD/export"
APP="$EXPORT/Sideport.app"
DMG="$BUILD/Sideport.dmg"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

security find-identity -v -p codesigning 2>/dev/null \
    | grep -q "Developer ID Application.*$TEAM" \
    || die "no Developer ID Application certificate for $TEAM — run scripts/preflight-release.sh"

step "Clean"
rm -rf "$BUILD"
mkdir -p "$BUILD"

step "Regenerate project"
(cd "$ROOT" && xcodegen generate >/dev/null)

step "Test before shipping"
(cd "$ROOT" && swift test 2>&1 | tail -3)

# Automatic signing needs permission to fetch — and on a first run, create —
# the Developer ID profiles for the app, the extension and the App Group.
# Without -allowProvisioningUpdates xcodebuild refuses to touch them and fails
# on a machine that has not built this before.
step "Archive (Release)"
xcodebuild -project "$ROOT/Sideport.xcodeproj" \
    -scheme Sideport \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    -destination 'generic/platform=macOS' \
    -allowProvisioningUpdates \
    archive | tail -5

step "Export with Developer ID"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT" \
    -exportOptionsPlist "$ROOT/scripts/release/ExportOptions.plist" \
    -allowProvisioningUpdates | tail -5
[ -d "$APP" ] || die "export produced no app at $APP"

step "Verify what we are about to ship"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'

# The extension is the part that breaks quietly: it is signed separately and a
# failure here still leaves a launchable app whose device mount never appears.
APPEX="$APP/Contents/PlugIns/SideportFileProvider.appex"
[ -d "$APPEX" ] || die "the extension is missing from the exported app"
codesign --verify --strict --verbose=2 "$APPEX" 2>&1 | sed 's/^/  /'

# Each fact is captured into a variable before it is judged, the same way
# build-local-dmg.sh does, and for the same reason. Reading these through a
# pipeline under `set -o pipefail` makes the check depend on codesign's exit
# status rather than on what it said: `grep -q` exits at its first match, the
# still-writing codesign dies of SIGPIPE, and a properly hardened bundle is
# reported as unhardened. That failure is silent until the day the signing
# certificate finally exists and this step runs for real.
for target in "$APP" "$APPEX"; do
    name=$(basename "$target")

    ENTS=$(codesign -d --entitlements - --xml "$target" 2>/dev/null \
        | plutil -convert xml1 -o - - 2>/dev/null || true)
    SIG=$(codesign -d --verbose=2 "$target" 2>&1 || true)

    case "$ENTS" in
        *get-task-allow*)
            die "$name still carries get-task-allow — that is a debug entitlement" ;;
    esac
    case "$ENTS" in
        *"$TEAM.dev.afridi.sideport"*) : ;;
        *) die "$name lost its App Group — the extension and app could not share a store" ;;
    esac
    case "$SIG" in
        *runtime*) : ;;
        *) die "$name is not hardened; notarization will reject it" ;;
    esac

    printf '  %s: hardened, App Group intact, no debug entitlement\n' "$name"
done

step "Build the disk image"
STAGE="$BUILD/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Sideport" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --sign "Developer ID Application" --timestamp "$DMG"

step "Notarize"
xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait 2>&1 | tee "$BUILD/notary.log"
grep -q "status: Accepted" "$BUILD/notary.log" || {
    ID=$(grep -m1 "id:" "$BUILD/notary.log" | awk '{print $2}')
    echo
    echo "Notarization did not succeed. The reason is in the log:"
    xcrun notarytool log "$ID" --keychain-profile "$KEYCHAIN_PROFILE" 2>&1 | head -40
    die "notarization rejected"
}

step "Staple"
# Without this the DMG only passes on a machine that can reach Apple; stapling
# is what makes it work offline.
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

step "Final check, as a first-time user's Mac would see it"
# Only meaningful while Gatekeeper assessment is enabled. With it off, spctl
# accepts everything and reports "override=security disabled" — a pass that
# says nothing about the Mac we are actually shipping to, which is worse than
# no check at all.
if spctl --status 2>&1 | grep -q "assessments enabled"; then
    spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/  /'
else
    echo "  skipped: Gatekeeper assessment is disabled on this Mac, so spctl"
    echo "  would accept the image no matter how it was signed. Re-enable with"
    echo "  'sudo spctl --master-enable' to check this properly."
fi

echo
echo "Ready: $DMG"
echo "  $(du -h "$DMG" | cut -f1)"
