#!/bin/bash
#
# uninstall-clamshell-daemon.sh — removes the com.djs.kvm-clamshell
# LaunchDaemon, restoring normal lid-close sleep first.
#
# Run with sudo:
#   sudo scripts/uninstall-clamshell-daemon.sh

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must be run with sudo." >&2
    exit 1
fi

LABEL="com.djs.kvm-clamshell"
PLIST_PATH="/Library/LaunchDaemons/com.djs.kvm-clamshell.plist"
INSTALLED_BINARY="/usr/local/libexec/kvm-clamshelld"
CONTROL_FILE="/Library/Application Support/CometKit/clamshell-enabled"

echo "Restoring normal lid-close sleep..."
pmset -a disablesleep 0 || true

if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
    echo "Unloading daemon..."
    launchctl bootout system "${PLIST_PATH}" 2>/dev/null || true
fi

rm -f "$PLIST_PATH" "$INSTALLED_BINARY" "$CONTROL_FILE"

echo "Uninstalled. (Left /Library/Application Support/CometKit in place if other files are there.)"
