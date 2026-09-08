#!/bin/bash
#
# install-clamshell-daemon.sh — installs the com.djs.kvm-clamshell root
# LaunchDaemon that keeps this Mac awake with the lid closed while it's
# docked (see CLAUDE.md's "clamshell problem" section).
#
# Runs standalone from inside CometBar.app (no repo checkout needed) if the
# kvm-clamshelld binary sits next to this script — that's how `make app`
# bundles it, under Contents/Resources/. Falls back to
# <repo>/.build/release/kvm-clamshelld for a dev checkout.
#
# Run with sudo, either from the app bundle:
#   sudo /Applications/CometBar.app/Contents/Resources/install-clamshell-daemon.sh
# or from a repo checkout (after `swift build -c release --product kvm-clamshelld`):
#   sudo scripts/install-clamshell-daemon.sh
#
# The daemon is installed OFF by default — it does nothing until you flip
# "Keep this Mac awake while docked" on in CometBar's Settings pane (or run
# `comet-cli clamshell on`). This script is idempotent; re-run it after
# rebuilding to install an updated binary.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must be run with sudo." >&2
    exit 1
fi

# The user who invoked sudo — the control flag file is owned by them so the
# unprivileged app can flip it without any privilege-escalation code.
TARGET_USER="${SUDO_USER:-$(stat -f%Su /dev/console)}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    echo "ERROR: could not determine the non-root user to own the control file." >&2
    echo "Run this with 'sudo', not as root directly." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLED_BINARY="${SCRIPT_DIR}/kvm-clamshelld"
REPO_BUILT_BINARY="${SCRIPT_DIR}/../.build/release/kvm-clamshelld"
INSTALLED_BINARY="/usr/local/libexec/kvm-clamshelld"
PLIST_PATH="/Library/LaunchDaemons/com.djs.kvm-clamshell.plist"
CONTROL_DIR="/Library/Application Support/CometKit"
CONTROL_FILE="${CONTROL_DIR}/clamshell-enabled"
LOG_PATH="/var/log/kvm-clamshell.log"
LABEL="com.djs.kvm-clamshell"

if [ -x "$BUNDLED_BINARY" ]; then
    BUILT_BINARY="$BUNDLED_BINARY"
elif [ -x "$REPO_BUILT_BINARY" ]; then
    BUILT_BINARY="$REPO_BUILT_BINARY"
else
    echo "ERROR: no kvm-clamshelld binary found next to this script or at ${REPO_BUILT_BINARY}." >&2
    echo "From a repo checkout, build it first (as your normal user, not sudo):" >&2
    echo "  swift build -c release --product kvm-clamshelld" >&2
    exit 1
fi

echo "Installing kvm-clamshelld for user: ${TARGET_USER}"

# Stop any existing instance before overwriting the binary/plist.
if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
    echo "Unloading existing daemon..."
    launchctl bootout system "${PLIST_PATH}" 2>/dev/null || true
fi

echo "Installing binary to ${INSTALLED_BINARY}..."
mkdir -p "$(dirname "$INSTALLED_BINARY")"
cp -f "$BUILT_BINARY" "$INSTALLED_BINARY"
chown root:wheel "$INSTALLED_BINARY"
chmod 755 "$INSTALLED_BINARY"

echo "Setting up control flag file at ${CONTROL_FILE}..."
mkdir -p "$CONTROL_DIR"
chown "${TARGET_USER}:staff" "$CONTROL_DIR"
chmod 755 "$CONTROL_DIR"
if [ ! -f "$CONTROL_FILE" ]; then
    # Default OFF — matches the old FeatureFlags.clamshellControl default.
    printf '0' > "$CONTROL_FILE"
fi
chown "${TARGET_USER}:staff" "$CONTROL_FILE"
chmod 644 "$CONTROL_FILE"

echo "Writing LaunchDaemon plist to ${PLIST_PATH}..."
cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALLED_BINARY}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_PATH}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_PATH}</string>
</dict>
</plist>
PLIST
chown root:wheel "$PLIST_PATH"
chmod 644 "$PLIST_PATH"

echo "Loading daemon..."
launchctl bootstrap system "$PLIST_PATH"

sleep 1
if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
    echo "Installed and running. Off by default — enable it from CometBar's Settings"
    echo "pane, or: comet-cli clamshell on"
    echo "Log: ${LOG_PATH}"
else
    echo "WARNING: daemon did not start. Check ${LOG_PATH} for details." >&2
    exit 1
fi
