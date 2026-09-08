# kvm-utility

macOS menu bar utility for a **GL.iNet Comet X (GL-RM4PE)** quad-port KVM.

Switch the active input from the menu bar instead of the web console. Optional,
currently disabled: the `pmset` workaround for macOS dropping clamshell mode
when the KVM switches away.

Replaces the shell scripts in `legacy/`.

## Setup

The Comet X password comes from the login Keychain — the same entry the shell
scripts use, so nothing is duplicated:

```sh
security add-generic-password -a admin -s glkvm -w
```

(`-w` with no value prompts, keeping the password out of shell history.)

## Use

```sh
swift build
swift run comet-cli status     # active port, link state, EDID assignment
swift run comet-cli set 2      # switch to port 2
swift run comet-cli dock       # is the OWC dock attached?
swift test                     # port-mapping tests

make app                       # assemble build/CometBar.app
make install                   # copy to /Applications
```

Override the host or user with `KVM_HOST` / `KVM_USER`.

## Layout

| Path | Purpose |
|---|---|
| `Sources/CometKit` | API client, models, Keychain, IOKit dock watcher. No SwiftUI. |
| `Sources/CometBar` | SwiftUI `MenuBarExtra` app |
| `Sources/comet-cli` | CLI front end — quickest way to test against the device |
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
