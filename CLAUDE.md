# kvm-utility — project context

macOS menu bar utility for controlling a **GL.iNet Comet X (GL-RM4PE)** quad-port
remote KVM, plus an optional workaround for macOS dropping clamshell mode when
the KVM switches away.

Everything in the "Device facts" section below was **empirically verified against
the live device** on 2026-09-08. It is not documented by GL.iNet. Trust it over
guesswork, but re-verify after any Comet X firmware update.

---

## Device facts (verified)

| Property | Value |
|---|---|
| Host | `glkvm.local` / `10.0.1.173` |
| Firmware | `kvmd 4.82` (PiKVM-derived), `ustreamer 6.13` |
| Hardware | Rockchip RV1126B, aarch64, Linux 6.1.141 |
| Reports itself as | `board: rpi4`, `model: v3` (it is masquerading as a PiKVM V3) |
| TLS | Self-signed cert on the LAN address |
| Open ports | 22 (SSH), 80 (redirects to 443), 443 |
| Extras enabled | `webterm` (ttyd), `janus`, `pion`, `webrtc`, `media` |
| Extras disabled | `ipmi`, `vnc` |

Because the firmware is kvmd-derived, **PiKVM's kvmd API docs are the best
reference available** — but GL.iNet has diverged, so verify each endpoint.

### Authentication

Per-request headers. No cookie or token dance needed:

```
X-KVMD-User: admin
X-KVMD-Passwd: <password>
```

`GET /api/auth/check` returns `{"ok": true}` when the headers are good.
`POST /api/auth/login` (form-encoded `user` + `passwd`) also exists and sets a
cookie, but the headers are simpler and stateless — prefer them.

**The password lives in the login Keychain**, service `glkvm`, account `admin`.
Never hardcode it, never log it. Read it with `SecItemCopyMatching`.

### Endpoints

| Endpoint | Method | Notes |
|---|---|---|
| `/api/switch` | GET | Full switch state — see shape below |
| `/api/switch/set_active?port=1.4` | POST | **Switch the active port. See the float trap.** |
| `/api/switch/set_port_params` | POST | Per-port config incl. EDID assignment. Params not yet mapped. |
| `/api/switch/edids/create` | POST | EDID management. Not yet mapped. |
| `/api/switch/set_colors` | POST | Port LED colors |
| `/api/switch/set_beacon` | POST | Port beacon blink |
| `/api/switch/reset` | POST | Not explored |
| `/api/switch/atx/click` | POST | ATX power/reset per port |
| `/api/info` | GET | Firmware, health, enabled extras |
| `/api/streamer` | GET | Video stream params |
| `/api/hid` | GET | Exists, not explored |

404 on `/api`, `/api/switch/state`, `/api/switch/set`, `/api/switch/ports`,
`/api/switch/edids`, `/rpc`. Don't go looking for those again.

### ⚠️ The float trap — read this before touching set_active

`set_active` takes a `port` parameter that is **the port ID string parsed as a
float**. Port `"1.4"` means unit 1, channel 4, and is passed as `1.4`.

```
POST /api/switch/set_active?port=1.4   → {"ok": true}      ✅
POST /api/switch/set_active?port=3     → 500 Internal Error ❌
POST /api/switch/set_active            → ValidatorError: "None argument is not a valid float"
```

A bare channel index passes float validation and *then* blows up server-side, so
a 500 here means a malformed port, not a broken device. Always map user-facing
ports 1–4 to `1.1`–`1.4`.

Note the two coexisting representations in `/api/switch`: `summary.active_id` is
`"1.4"` (1-based channel) while `summary.active_port` is `3` (0-based index).
`model.ports[].channel` is 0-based, `model.ports[].id` is the `"1.N"` string.
**Mixing these up is the most likely source of off-by-one bugs in this project.**

### `/api/switch` response shape (fields that matter)

```jsonc
{
  "ok": true,
  "result": {
    "summary": { "active_id": "1.4", "active_port": 3, "synced": true },
    "video":    { "links": [false, true, true, true] },   // by 0-based channel
    "usb_otg":  { "links": [true, true, true, true] },
    "model": {
      "ports": [
        { "id": "1.1", "channel": 0, "unit": 0, "name": "", "video": {"dummy": true},
          "atx": { "click_delays": { "power": 0.5, "power_long": 5.5, "reset": 0.5 } } }
        // ... 1.2, 1.3, 1.4
      ]
    },
    "edids": { "all": { "default": { /* PiKVM V3 EDID */ } }, "used": [] },
    "colors": { "active": {...}, "inactive": {...}, "beacon": {...} }
  }
}
```

Observed live state: port `1.1` has no video link; `1.2`–`1.4` do. Dusty's Mac is
on **`1.4`**. All port names are empty — naming them is a nice-to-have feature.

Error envelope on failure:

```json
{ "ok": false, "result": { "error": "UnauthorizedError", "error_msg": "Unauthorized" } }
```

Always check the `ok` field. A 200 with `ok: false` is possible.

---

## The clamshell problem (optional scope)

The Comet X de-asserts HDMI hotplug detect on inactive ports. With the lid
closed, macOS sees the display vanish, ends clamshell mode, and sleeps
immediately. The workaround is `sudo pmset -a disablesleep 1`, which decouples
sleep from lid state.

**Status: deliberately optional, behind a feature flag.** Dusty's EDID config
currently works well and he does not want to change it, but has not yet
confirmed whether clamshell survives several switch cycles. Build switching
first; keep this compiled but off by default.

### Two traps already hit in the shell version

1. **`pmset -g` labels the setting `SleepDisabled`, not `disablesleep`.**
   `disablesleep` is only the argument name for `pmset -a`. The original script
   grepped for the wrong string and so reported the status backwards, always.
2. **`set -o pipefail` + `grep -q` is a trap.** grep exits early, the upstream
   `ioreg`/`pmset` dies on SIGPIPE, and the pipeline reports failure even on a
   match. Capture output to a variable first. (Relevant if any shell survives.)

### The unresolved design question: root

`pmset` needs root; a GUI app doesn't have it. Options, in Dusty's stated order
of preference:

1. **Reuse the existing root LaunchDaemon** (`com.djs.kvm-clamshell`, installed
   at `/Library/LaunchDaemons/`) as the privileged worker; the app signals intent
   to it. No escalation code, no signing requirements. **Preferred.**
2. `SMAppService` privileged helper + XPC — correct for a single bundle, most
   work, needs a Developer ID cert.
3. Sudoers `NOPASSWD` for `/usr/sbin/pmset` — fastest, but any local process
   running as Dusty can then disable system sleep. He owns HITRUST/SOC 2
   compliance at work, so this is a deliberate decision, not a default.

Do not implement 2 or 3 without asking.

---

## The dock

Dusty's Mac docks through an **OWC Thunderbolt 3 Dock**, USB vendor ID
`0x1E91` (7825 decimal). It presents two reliably-enumerated devices:

- `OWC Thunderbolt 3 Dock SD Card Reader` — product `0x4002` (16386)
- `OWC Thunderbolt 3 Audio Device` — product `0x4001` (16385)

Match on **vendor ID only** — product IDs are less stable across dock firmware.

Dock presence is how the app decides whether it is at the desk. Use
`IOServiceAddMatchingNotification` with `kIOMatchedNotification` and
`kIOTerminatedNotification` on `IOUSBHostDevice`. **Do not poll.** The shell
version polled every 30s via launchd `StartInterval`, which both wasted cycles
and left a gap across sleep/wake (interval timers don't fire reliably on wake).
Event-driven IOKit notification plus `NSWorkspace.didWakeNotification` is the
whole point of moving to Swift.

---

## ⚠️ The switch-back constraint — this shapes the UX

**When the KVM switches away from the Mac, it takes the keyboard and mouse with
it.** A global hotkey registered in this app can therefore only ever switch
*away* from the Mac, never back. Any UI that assumes bidirectional control from
the Mac's own keyboard is broken by design.

Mitigation under investigation: Dusty has a **Flexbar** (USB vendor `12346`)
which appears in `ioreg` on `AppleUSBXHCIAR` — a *different* USB controller from
the OWC dock's devices on `AppleUSBXHCIFL1100`. That suggests it's wired
directly to the Mac rather than through the KVM'd path, so it would stay
attached when the KVM switches away and could serve as the switch-back control.

**This is unconfirmed.** The test: switch to port 2, then check whether the
Flexbar still drives the Mac. Confirm before building Flexbar integration.

---

## ⚠️ macOS API traps (all three cost real debugging time here)

Every one of these fails **silently and plausibly** — no crash, no error, just a
confidently wrong answer. They were caught only by running the Swift against the
live machine and comparing with the shell scripts in `legacy/`, which were
already correct. When a reader disagrees with `legacy/`, assume the Swift is
wrong.

1. **IOKit property matching needs a sub-dictionary.**
   `idVendor` must go inside `kIOPropertyMatchKey`, not at the top level of the
   matching dictionary. The top level accepts only IOKit's reserved keys
   (`IOProviderClass`, `IOClass`, `IONameMatch`, `IOPropertyMatch`, …) and an
   unrecognised key there does not get ignored — **it makes the match return
   zero results.** Dock detection reported "not detected" with the dock plainly
   attached.

   ```swift
   // WRONG — silently matches nothing
   (matching as NSMutableDictionary)[kUSBVendorID] = 0x1E91
   // RIGHT
   (matching as NSMutableDictionary)[kIOPropertyMatchKey] = [kUSBVendorID: 0x1E91]
   ```

2. **Use `IOUSBHostDevice`, not `kIOUSBDeviceClassName`.**
   The latter is `"IOUSBDevice"`, the legacy class, and matches nothing on this
   machine. Verified: `IOUSBHostDevice` returns 9 devices, of which the OWC SD
   Card Reader and Audio Device carry vendor `0x1E91`.

3. **`pmset -g` separates label from value with TABS.**
   `line.split(separator: " ")` returns the whole line as a single element, so
   the value comparison silently fails and the status reads backwards. Split on
   whitespace generally: `split(whereSeparator: \.isWhitespace)`.

Reference values confirmed live on this Mac: OWC dock `0x1E91` → SD Card Reader
+ Audio Device; Flexbar `12346` (`0x303A`) → one device.

`String(format: "%-5@", someNSString)` also does not pad. Pad manually.

## Project layout

```
Package.swift
Sources/
  CometKit/          Reusable core — API client, models, Keychain, watchers
  CometBar/          SwiftUI MenuBarExtra app (LSUIElement, no dock icon)
  comet-cli/         CLI front end; fastest way to test CometKit by hand
Tests/CometKitTests/
legacy/              The shell scripts this replaces, kept for reference
```

`CometKit` holds all logic and must not import SwiftUI. Keep the app layer thin
so the CLI and the menu bar app exercise identical code paths.

## Build

```sh
swift build                       # library + CLI
swift run comet-cli status        # smoke test against the live device
make app                          # assemble CometBar.app bundle
```

## Conventions

- Swift 6 strict concurrency. `CometClient` is an `actor`.
- No secrets in source, logs, or committed files. Keychain only.
- Every API call checks the `ok` field, not just the HTTP status.
- Self-signed cert handling is scoped to the KVM host and marked `TODO: pin`.
  Do not disable TLS validation globally.
- Port numbers are 1-based at every boundary the user touches; convert to
  channel indices only at the last moment.

## Open questions

- [ ] Does clamshell survive switch cycles with the current EDID? (decides whether pmset stays)
- [ ] Is the Flexbar off the KVM'd USB path? (decides switch-back design)
- [ ] `set_port_params` parameter names — needed for in-app EDID assignment
- [ ] Does `/api/hid` allow sending keystrokes to the *other* hosts? (would be a nice extra)
- [ ] Port naming: is `name` writable via `set_port_params`?

## Don't

- Don't call `set_port_params` or `edids/create` against the live device
  casually — Dusty's video path runs through it and a wrong parameter can drop
  his display mid-call. Read state freely; write config deliberately.
- Don't reintroduce polling for dock detection.
- Don't assume `port=3` works. See the float trap.
