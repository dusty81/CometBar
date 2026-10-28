APP        := CometBar
BUNDLE     := build/$(APP).app
CONFIG     := release
# A stable certificate identity, not ad-hoc (-). Ad-hoc signatures have no
# certificate identity, so Keychain access-control entries end up pinned to
# the exact binary hash — every rebuild produces a new hash, so macOS
# re-prompted for the Keychain password on every single rebuild.
#
# Was a self-signed "CometBar Local Dev" cert until 2026-10, when it went
# missing from the login keychain; switched to the Developer ID identity,
# which is stable across rebuilds and machines. Override with
# `make SIGN_IDENTITY="..."` if needed.
SIGN_IDENTITY := Developer ID Application: Dustin Schnabel (7A5993N4F2)

.PHONY: all build test cli app install clean

all: build

build:
	swift build -c $(CONFIG)

test:
	swift test

cli:
	swift run comet-cli status

# SwiftPM produces a bare executable; MenuBarExtra needs a real .app bundle
# with an Info.plist (LSUIElement=1 keeps it out of the Dock and app switcher).
#
# The clamshell daemon travels with the bundle too (built binary + its
# install/uninstall scripts, under Contents/Resources) so copying CometBar.app
# to another Mac carries everything needed — no separate repo checkout to set
# up the LaunchDaemon there. See scripts/install-clamshell-daemon.sh.
app: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp .build/$(CONFIG)/$(APP) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Sources/$(APP)/Info.plist $(BUNDLE)/Contents/Info.plist
	cp Sources/$(APP)/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	cp .build/$(CONFIG)/kvm-clamshelld $(BUNDLE)/Contents/Resources/kvm-clamshelld
	cp scripts/install-clamshell-daemon.sh $(BUNDLE)/Contents/Resources/install-clamshell-daemon.sh
	cp scripts/uninstall-clamshell-daemon.sh $(BUNDLE)/Contents/Resources/uninstall-clamshell-daemon.sh
	chmod +x $(BUNDLE)/Contents/Resources/*.sh
	codesign --force --sign "$(SIGN_IDENTITY)" --timestamp=none $(BUNDLE)
	@echo "Built $(BUNDLE) — run it with: open $(BUNDLE)"
	@echo "Install the clamshell daemon with:"
	@echo "  sudo $(BUNDLE)/Contents/Resources/install-clamshell-daemon.sh"

# Locally signed only (see SIGN_IDENTITY above), not notarized — Gatekeeper
# will still quarantine this on any Mac other than the one it was built on.
# Notarisation would need a real Developer ID cert; not needed for local use.
install: app
	rm -rf /Applications/$(APP).app
	cp -R $(BUNDLE) /Applications/
	@echo "Installed to /Applications/$(APP).app"

clean:
	rm -rf .build build
