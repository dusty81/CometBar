#!/bin/bash
#
# kvm-clamshell.sh — toggle macOS lid-close (clamshell) sleep
#
# Purpose: the GL.iNet Comet X drops HDMI hotplug detect on the port when you
# switch away from this Mac. With the lid closed, macOS ends clamshell mode and
# sleeps immediately. Setting disablesleep=1 decouples sleep from lid state so
# the Mac stays awake while the KVM is pointed at another port.
#
# WARNING: while disabled, this Mac will NOT sleep when you close the lid.
# Re-enable before putting it in a bag.
#
# Usage:
#   ./kvm-clamshell.sh off      # disable lid-close sleep (stay awake on KVM switch)
#   ./kvm-clamshell.sh on       # restore normal lid-close sleep
#   ./kvm-clamshell.sh status   # show current setting + dock presence
#   ./kvm-clamshell.sh auto     # set based on whether the OWC dock is attached
#
# Setting is NOT persistent across reboots. Install the LaunchDaemon
# (com.djs.kvm-clamshell.plist) to have "auto" run at boot and on dock changes.

set -euo pipefail

# OWC Thunderbolt 3 Dock USB vendor ID (0x1E91 = 7825 decimal)
DOCK_VENDOR_ID=7825
DOCK_NAME="OWC Thunderbolt 3 Dock"

usage() {
    echo "Usage: $(basename "$0") {off|on|status|auto}"
    echo "  off     - disable lid-close sleep (pmset disablesleep 1)"
    echo "  on      - re-enable lid-close sleep (pmset disablesleep 0)"
    echo "  status  - show the current setting and dock presence"
    echo "  auto    - dock attached => off, dock absent => on"
    exit 1
}

# Run pmset as root only if we aren't already root (LaunchDaemon runs as root).
as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# Returns the current SleepDisabled value: 1 (disabled) or 0 (normal).
# NOTE: `pmset -g` labels this "SleepDisabled" under "System-wide power
# settings:" — NOT "disablesleep" (that is only the name of the -a argument).
# The section is also omitted entirely on some macOS builds when the value is
# 0, so an empty result is treated as 0.
get_sleep_disabled() {
    local raw val
    raw=$(pmset -g 2>/dev/null || true)
    val=$(printf '%s\n' "$raw" | awk '/^[[:space:]]*SleepDisabled/ {print $2}' | head -1)
    case "${val:-0}" in
        1|true|yes) echo 1 ;;
        *)          echo 0 ;;
    esac
}

dock_present() {
    # NOTE: capture first. Piping ioreg straight into `grep -q` makes grep exit
    # early, ioreg dies on SIGPIPE, and `set -o pipefail` then reports failure
    # even when the dock IS attached.
    local out
    out=$(ioreg -p IOUSB -w0 -l 2>/dev/null || true)
    printf '%s\n' "$out" | grep -q "\"idVendor\" = ${DOCK_VENDOR_ID}\$"
}

show_status() {
    if [ "$(get_sleep_disabled)" = "1" ]; then
        echo "Lid-close sleep: DISABLED (Mac stays awake with lid closed)"
    else
        echo "Lid-close sleep: ENABLED (normal macOS behavior)"
    fi
    if dock_present; then
        echo "Dock:            PRESENT (${DOCK_NAME})"
    else
        echo "Dock:            not detected"
    fi
}

set_sleep_disabled() {
    local want="$1"
    if [ "$(get_sleep_disabled)" = "$want" ]; then
        echo "Already set — no change needed."
    else
        as_root pmset -a disablesleep "$want"
    fi
}

[ $# -eq 1 ] || usage

case "$1" in
    off)
        echo "Disabling lid-close sleep..."
        set_sleep_disabled 1
        show_status
        ;;
    on)
        echo "Re-enabling lid-close sleep..."
        set_sleep_disabled 0
        show_status
        ;;
    auto)
        if dock_present; then
            echo "${DOCK_NAME} detected — disabling lid-close sleep."
            set_sleep_disabled 1
        else
            echo "Dock not detected — restoring normal lid-close sleep."
            set_sleep_disabled 0
        fi
        show_status
        ;;
    status)
        show_status
        ;;
    *)
        usage
        ;;
esac
