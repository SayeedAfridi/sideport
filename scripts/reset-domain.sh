#!/bin/bash
# Full teardown of this provider's File Provider state.
#
# File Provider caches domain configuration aggressively: changes to the
# extension's Info.plist (NSFileProviderDefaultDomainEnabled and friends) are
# read once and then persisted in the provider's state directory, so editing
# the plist alone changes nothing. A stale cache produces behaviour
# indistinguishable from a code bug — reach for this before debugging anything
# that "should already work".
#
# Only this provider's own state is touched; other providers are left alone.
set -euo pipefail

PROVIDER="dev.afridi.finderadb.FileProvider"
STATE="$HOME/Library/Application Support/FileProvider/$PROVIDER"

echo "==> stopping the app (it removes its domains on quit)"
pkill -x FinderADB 2>/dev/null || true
sleep 2

if [ -d "$STATE" ]; then
    echo "==> clearing cached domain state"
    rm -rf "$STATE"
else
    echo "==> no cached state to clear"
fi

echo "==> restarting the File Provider daemon"
killall fileproviderd 2>/dev/null || true
sleep 2

if [ "${1:-}" = "--relaunch" ]; then
    APP="${FINDERADB_APP:-$(find "$HOME/Library/Developer/Xcode/DerivedData" \
        -maxdepth 5 -name FinderADB.app -path "*/Debug/*" 2>/dev/null | head -1)}"
    if [ -n "$APP" ]; then
        echo "==> re-registering and launching $APP"
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
        open "$APP"
    else
        echo "!! could not find a built FinderADB.app; set FINDERADB_APP"
    fi
fi

echo "==> done"
