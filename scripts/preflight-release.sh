#!/bin/bash
# What still stands between here and a notarized build.
#
# Run it after each step of the release setup; it reports what is present,
# what is missing, and the exact next action. It changes nothing.

TEAM="NU2JM39S5P"
APP_ID="dev.afridi.sideport"
EXT_ID="dev.afridi.sideport.FileProvider"
GROUP="$TEAM.$APP_ID"
KEYCHAIN_PROFILE="sideport-notary"

ok=0
missing=0
say_ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; ok=$((ok+1)); }
say_miss() { printf '  \033[31m✗\033[0m %s\n'   "$1"; missing=$((missing+1)); }
say_note() { printf '      %s\n' "$1"; }

echo
echo "Sideport release preflight — team $TEAM"
echo

echo "1. Signing identity"
IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null)
if echo "$IDENTITIES" | grep -q "Developer ID Application.*$TEAM"; then
    say_ok "Developer ID Application certificate present"
    echo "$IDENTITIES" | grep "Developer ID Application" | sed 's/^/      /'
else
    say_miss "no Developer ID Application certificate for $TEAM"
    say_note "Xcode ▸ Settings ▸ Accounts ▸ $TEAM ▸ Manage Certificates ▸ + ▸"
    say_note "Developer ID Application.  Requires the Account Holder role."
fi

echo
echo "2. Notarization credentials"
if xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
    say_ok "notarytool profile '$KEYCHAIN_PROFILE' works"
else
    say_miss "no working notarytool profile named '$KEYCHAIN_PROFILE'"
    say_note "App Store Connect ▸ Users and Access ▸ Integrations ▸ App Store"
    say_note "Connect API ▸ generate a key with Developer access, then:"
    say_note "  xcrun notarytool store-credentials $KEYCHAIN_PROFILE \\"
    say_note "    --key ~/private_keys/AuthKey_<KEYID>.p8 \\"
    say_note "    --key-id <KEYID> --issuer <ISSUER-UUID>"
fi

echo
echo "3. Identifiers this build needs registered"
say_note "App ID          $APP_ID          (App Groups capability)"
say_note "App ID          $EXT_ID  (App Groups capability)"
say_note "App Group       $GROUP"
say_note "Xcode's automatic signing creates these on first Developer ID archive;"
say_note "this script cannot see the portal, so they are listed, not checked."

echo
echo "4. Local toolchain"
command -v xcodegen >/dev/null 2>&1 && say_ok "xcodegen" || say_miss "xcodegen (brew install xcodegen)"
command -v create-dmg >/dev/null 2>&1 \
    && say_ok "create-dmg" \
    || say_note "create-dmg absent — release.sh falls back to hdiutil, which is fine"
xcrun notarytool --version >/dev/null 2>&1 && say_ok "notarytool" || say_miss "notarytool (Xcode command line tools)"

echo
if [ "$missing" -eq 0 ]; then
    echo "Ready. Run: ./scripts/release.sh"
else
    echo "$missing thing(s) still needed; $ok already in place."
fi
echo
