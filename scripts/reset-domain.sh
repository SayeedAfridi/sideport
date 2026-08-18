#!/bin/bash
# Tear down every registered File Provider domain and restart the daemon.
#
# File Provider caches domains aggressively, and a stale one produces behaviour
# indistinguishable from a code bug. Reach for this before debugging anything
# that "should work".
set -euo pipefail

echo "==> registered domains before"
ls -1 ~/Library/Application\ Support/FileProvider/ 2>/dev/null || echo "  (none)"

echo "==> asking the app to remove its domains"
pkill -x FinderADB 2>/dev/null || true

echo "==> restarting the File Provider daemon"
pkill -f fileproviderd 2>/dev/null || true
pkill -f 'dev.afridi.finderadb.FileProvider' 2>/dev/null || true

sleep 1
echo "==> done. Relaunch FinderADB to re-register."
