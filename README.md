# CometBar

macOS menu bar utility for a **GL.iNet Comet X (GL-RM4PE)** quad-port KVM.

Switch the active input from the menu bar instead of the web console. Optional,
off by default: a `pmset` workaround, applied by a root LaunchDaemon, for
macOS dropping clamshell mode when the KVM switches away.

Replaces the shell scripts in `legacy/`.

## Setup

Host, username, and per-port friendly names (e.g. "Work MBP") are configured
in the menu bar app's Settings pane (`Settings…` in the menu, or ⌘,). The
password is entered there too, but is never displayed back — it's written
straight to the login Keychain and read from there on every request:

```sh
security add-generic-password -a admin -s glkvm -w
```

(`-w` with no value prompts, keeping the password out of shell history. Not
required if you set the password from the Settings pane instead.)

## Use

```sh
swift build
swift run comet-cli status     # active port, link state, port names
swift run comet-cli set 2      # switch to port 2
swift run comet-cli dock       # is the OWC dock attached?
swift test                     # unit tests

make app                       # assemble build/CometBar.app
make install                   # copy to /Applications
```

The CLI reads the same host/user/port-name settings as the menu bar app;
override the host or user for one invocation with `KVM_HOST` / `KVM_USER`.

The menu bar app polls `/api/switch` on a timer (default 45s, configurable in
Settings) since the device has no push mechanism — separate from the
event-driven IOKit dock watcher, which never polls.

## Keyboard shortcuts

`⌘⌥1` – `⌘⌥4` switch ports system-wide, whether or not CometBar's menu is
open or frontmost (a system-wide Carbon hotkey, not just a menu shortcut).

This can only ever switch **away** from the Mac it's pressed on: once the KVM
switches away, that Mac's keyboard physically goes with it, so the same
shortcut pressed there can't reach back. If you use CometBar on more than one
of the KVM's machines, install it on all of them and use whichever one's
keyboard is currently live to switch away from it.

## Clamshell workaround (optional)

The Comet X drops HDMI hotplug detect on inactive ports, which makes macOS
end clamshell mode and sleep immediately if the lid is closed. The fix is
`pmset -a disablesleep`, which needs root — a GUI app doesn't have that, so
this is a separate root LaunchDaemon (`com.djs.kvm-clamshell`, built from the
`kvm-clamshelld` target) that watches OWC dock presence itself and keeps sleep
disabled exactly while docked. It's off by default until installed.

**Install it from Settings**: the Clamshell section has an "Install
background helper…" button. Clicking it runs the bundled install script with
administrator privileges via the standard macOS admin-password prompt — no
Terminal needed. An "Uninstall background helper…" button appears once it's
installed.

`make app`/`make install` bundle the daemon binary and its install/uninstall
scripts into `CometBar.app/Contents/Resources` — copying the `.app` to
another Mac carries everything needed for that button to work there too, no
repo checkout required. The same scripts are also runnable directly if you'd
rather not use the button:

```sh
sudo /Applications/CometBar.app/Contents/Resources/install-clamshell-daemon.sh
sudo /Applications/CometBar.app/Contents/Resources/uninstall-clamshell-daemon.sh   # reverses it
```

From a repo checkout instead, `scripts/install-clamshell-daemon.sh` works the
same way (falls back to `.build/release/kvm-clamshelld` if there's nothing
bundled next to it — build that first with
`swift build -c release --product kvm-clamshelld`).

Once installed, turn it on/off from CometBar's Settings pane ("Keep this Mac
awake while docked") or `comet-cli clamshell on|off`. The app and daemon never
talk to each other directly — the app writes a plain "0"/"1" control file the
daemon polls, so no privilege-escalation code lives in the GUI app.

**Moving to another Mac**, note what does *not* come along automatically:
the Keychain password (`security add-generic-password -a admin -s glkvm -w`,
or set it from Settings there), and the host/user/refresh settings (local
`UserDefaults`, defaults to `glkvm.local`/`admin`/45s until configured). Port
names *do* carry over — they live on the KVM itself, not per-machine.

## Layout

| Path | Purpose |
|---|---|
| `Sources/CometKit` | API client, models, Keychain, IOKit dock watcher, clamshell logic. No SwiftUI. |
| `Sources/CometBar` | SwiftUI `MenuBarExtra` app |
| `Sources/comet-cli` | CLI front end — quickest way to test against the device |
| `Sources/kvm-clamshelld` | Root LaunchDaemon body — see "Clamshell workaround" above |
| `scripts/` | Install/uninstall for the clamshell LaunchDaemon |
| `legacy/` | The shell scripts this replaces |

## Read before changing anything

**[CLAUDE.md](CLAUDE.md)** holds the verified API reference and three things
that will otherwise cost you an afternoon:

- `set_active` takes the port ID as a **float** (`1.4`), not a channel index —
  a bare index returns HTTP 500 from the handler, not a validation error.
- The device exposes 1-based IDs *and* 0-based channels in the same response.
- Once the KVM switches away, this Mac loses its keyboard, so the app can only
  ever switch **away**, never back.

The API is undocumented and kvmd-derived. Re-verify after firmware updates.
