#!/bin/bash
#
# kvm-switch.sh — control the GL.iNet Comet X (GL-RM4PE) input port
#
# The Comet X firmware is kvmd-derived (same API surface as PiKVM):
#   /api/info  /api/hid  /api/switch  /api/streamer  /api/auth/login
# GL.iNet does not document this API — it may change across firmware updates.
#
# Auth: kvmd accepts per-request headers X-KVMD-User / X-KVMD-Passwd.
# The password is read from the login keychain, never stored in this file.
#
# One-time setup:
#   security add-generic-password -a admin -s glkvm -w
#     (add -w with no value and it prompts, so the password stays out of
#      your shell history)
#
# Usage:
#   ./kvm-switch.sh discover     # dump raw API responses (run this first)
#   ./kvm-switch.sh status       # show which port is active
#   ./kvm-switch.sh set 2        # switch to port 2
#
set -euo pipefail

KVM_HOST="${KVM_HOST:-glkvm.local}"
KVM_USER="${KVM_USER:-admin}"
KEYCHAIN_SERVICE="${KEYCHAIN_SERVICE:-glkvm}"

# The device uses a self-signed cert on its LAN address, hence -k. If you
# pin a cert later, replace -k with --cacert /path/to/comet.pem.
CURL_OPTS=(-sS -k -m 10)

usage() {
    echo "Usage: $(basename "$0") {discover|status|set <port>}"
    echo "  discover     - dump raw /api/info and /api/switch responses"
    echo "  status       - show the active port"
    echo "  set <port>   - switch the KVM to <port>"
    echo
    echo "Env overrides: KVM_HOST (${KVM_HOST}), KVM_USER (${KVM_USER})"
    exit 1
}

get_passwd() {
    security find-generic-password -a "$KVM_USER" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || {
        echo "ERROR: no keychain entry for service '${KEYCHAIN_SERVICE}', account '${KVM_USER}'." >&2
        echo "Add one with:  security add-generic-password -a ${KVM_USER} -s ${KEYCHAIN_SERVICE} -w" >&2
        return 1
    }
}

# api <method> <path> [curl args...]
api() {
    local method="$1" path="$2"; shift 2
    local pw
    pw=$(get_passwd)
    curl "${CURL_OPTS[@]}" -X "$method" \
        -H "X-KVMD-User: ${KVM_USER}" \
        -H "X-KVMD-Passwd: ${pw}" \
        "$@" \
        "https://${KVM_HOST}${path}"
}

pretty() {
    if command -v jq >/dev/null 2>&1; then jq . 2>/dev/null || cat; else cat; fi
}

do_discover() {
    echo "### Host: ${KVM_HOST}  User: ${KVM_USER}"
    echo
    echo "### GET /api/auth/check"
    api GET /api/auth/check -o - -w "\n[http %{http_code}]\n" || true
    echo
    for p in /api/info /api/switch /api/streamer; do
        echo "### GET ${p}"
        api GET "$p" | pretty || true
        echo
    done
    echo "### Endpoint shape probe (no state change — reports codes only)"
    for p in /api/switch/state /api/switch/set /api/switch/set_active /api/switch/ports; do
        printf "  GET  %-24s " "$p"
        api GET "$p" -o /dev/null -w "%{http_code}\n" || true
    done
    echo
    echo "Send me this output and I'll pin down the exact 'set' call."
}

do_status() {
    api GET /api/switch | python3 -c '
import sys, json
d = json.load(sys.stdin)["result"]
s, m = d["summary"], d["model"]
vid = d["video"]["links"]
otg = d["usb_otg"]["links"]
print("Active port : %s (channel %s)  synced=%s" % (
    s["active_id"], s["active_port"], s["synced"]))
print("EDID assigned to ports: %s" % (d["edids"]["used"] or "NONE"))
print()
print("  port  video  usb   name")
for p in m["ports"]:
    ch = p["channel"]
    mark = "*" if p["id"] == s["active_id"] else " "
    print("%s %-5s %-6s %-5s %s" % (
        mark, p["id"],
        "up" if vid[ch] else "--",
        "up" if otg[ch] else "--",
        p["name"] or "(unnamed)"))
'
}

# Confirmed API: POST /api/switch/set_active?port=<unit>.<channel>
#
# The 'port' argument is the port ID ("1.4") parsed as a FLOAT — unit 1,
# channel 4. Passing a bare channel index instead (port=3) passes float
# validation and then returns 500, which is why this maps 1-4 to 1.N.
do_set() {
    local port="$1"
    [[ "$port" =~ ^[1-4]$ ]] || { echo "ERROR: port must be 1-4." >&2; exit 1; }
    local resp
    resp=$(api POST "/api/switch/set_active?port=1.${port}")
    if printf '%s' "$resp" | grep -q '"ok": *true'; then
        echo "Switched to port ${port} (id 1.${port})"
    else
        echo "ERROR: switch failed:" >&2
        printf '%s\n' "$resp" >&2
        exit 1
    fi
}

[ $# -ge 1 ] || usage

case "$1" in
    discover) do_discover ;;
    status)   do_status ;;
    set)      [ $# -eq 2 ] || usage; do_set "$2" ;;
    *)        usage ;;
esac
