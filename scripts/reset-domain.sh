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

# Ask xcodebuild where the product actually is. Searching DerivedData by hand
# is a trap: regenerating the project creates a second derived-data directory,
# and picking the wrong one silently launches a stale build — every subsequent
# symptom then looks like a code bug in the current source.
resolve_app() {
    if [ -n "${FINDERADB_APP:-}" ]; then echo "$FINDERADB_APP"; return; fi
    local dir
    dir=$(xcodebuild -project FinderADB.xcodeproj -scheme FinderADB -configuration Debug \
            -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
          | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')
    [ -n "$dir" ] && [ -d "$dir/FinderADB.app" ] && echo "$dir/FinderADB.app"
}
APP="$(resolve_app)"
if [ -z "$APP" ]; then
    echo "!! could not locate a built FinderADB.app — run 'make app' first"
    exit 1
fi
echo "==> using $APP"

echo "==> stopping the app"
pkill -x FinderADB 2>/dev/null || true
sleep 2

# Removing the domain through NSFileProviderManager is the only way to make the
# system discard its replica. Without this, cached item capabilities survive
# every other kind of reset — a folder that became writable still reads as
# read-only, because Finder never asks us again.
if [ -n "$APP" ]; then
    echo "==> purging domains through the API"
    "$APP/Contents/MacOS/FinderADB" --purge-domains >/dev/null 2>&1 &
    sleep 4
    pkill -x FinderADB 2>/dev/null || true
fi

echo "==> clearing our metadata store"
rm -rf "$HOME/Library/Group Containers/NU2JM39S5P.dev.afridi.finderadb/domains"

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
    if [ -n "$APP" ]; then
        echo "==> re-registering and launching"
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
        open "$APP"
    fi
fi

echo "==> done"
