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

# Where the credentials come from.
#
# On a maintainer's Mac both live in the keychain: the Developer ID identity,
# and a notarytool profile stored once by `xcrun notarytool store-credentials`.
# A CI runner has neither, and cannot have the second — so an App Store Connect
# API key stands in for both when ASC_KEY_PATH is set. The same key also
# authenticates xcodebuild, which otherwise has no account to fetch the
# Developer ID provisioning profiles with, and fails at the archive.
#
# Empty arrays are expanded through the `${a[@]+...}` guard because /bin/bash on
# macOS is 3.2, where an unguarded empty expansion under `set -u` is an error.
NOTARY_AUTH=(--keychain-profile "$KEYCHAIN_PROFILE")
XCODE_AUTH=()
if [ -n "${ASC_KEY_PATH:-}" ]; then
    [ -f "$ASC_KEY_PATH" ] || die "ASC_KEY_PATH is set but there is no file at $ASC_KEY_PATH"
    : "${ASC_KEY_ID:?ASC_KEY_PATH is set, so ASC_KEY_ID must be too}"
    : "${ASC_ISSUER_ID:?ASC_KEY_PATH is set, so ASC_ISSUER_ID must be too}"
    NOTARY_AUTH=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
    XCODE_AUTH=(-authenticationKeyPath "$ASC_KEY_PATH"
                -authenticationKeyID "$ASC_KEY_ID"
                -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

security find-identity -v -p codesigning 2>/dev/null \
    | grep -q "Developer ID Application.*$TEAM" \
    || die "no Developer ID Application certificate for $TEAM — run scripts/preflight-release.sh"

step "Clean"
rm -rf "$BUILD"
mkdir -p "$BUILD"

step "Regenerate project"
(cd "$ROOT" && xcodegen generate >/dev/null)

step "Test before shipping"
# The whole run goes to a log and only the summary is printed, because a passing
# suite has nothing to say. A failing one does, and a three-line tail is the one
# thing you cannot debug from — on CI it left nothing behind but the doc comment
# above the test that broke. So a failure prints the failures.
if (cd "$ROOT" && swift test >"$BUILD/test.log" 2>&1); then
    tail -3 "$BUILD/test.log" | sed 's/^/  /'
else
    grep -E '✘|error:|warning: .*test' "$BUILD/test.log" | head -40 | sed 's/^/  /'
    die "tests failed — full output in $BUILD/test.log"
fi

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
    ${XCODE_AUTH[@]+"${XCODE_AUTH[@]}"} \
    archive | tail -5

step "Export with Developer ID"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT" \
    -exportOptionsPlist "$ROOT/scripts/release/ExportOptions.plist" \
    -allowProvisioningUpdates \
    ${XCODE_AUTH[@]+"${XCODE_AUTH[@]}"} | tail -5
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
# Styling and layout live in scripts/make-dmg.sh, which needs Finder — the only
# thing that can write an icon view's .DS_Store. It warns and ships an unstyled
# image rather than failing if Finder cannot be driven.
"$ROOT/scripts/make-dmg.sh" "$APP" "$DMG" "Sideport"
codesign --sign "Developer ID Application" --timestamp "$DMG"

step "Notarize"
xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait 2>&1 | tee "$BUILD/notary.log"
grep -q "status: Accepted" "$BUILD/notary.log" || {
    ID=$(grep -m1 "id:" "$BUILD/notary.log" | awk '{print $2}')
    echo
    echo "Notarization did not succeed. The reason is in the log:"
    xcrun notarytool log "$ID" "${NOTARY_AUTH[@]}" 2>&1 | head -40
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
