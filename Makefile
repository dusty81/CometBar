APP        := CometBar
BUNDLE     := build/$(APP).app
CONFIG     := release
# A stable local self-signed identity, not ad-hoc (-). Ad-hoc signatures have
# no certificate identity, so Keychain access-control entries end up pinned
# to the exact binary hash — every rebuild produces a new hash, so macOS
# re-prompted for the Keychain password on every single rebuild. Signing with
# a real (if local-only) certificate keeps that identity stable across
# rebuilds. Set up once via:
#   openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
#     -subj "/CN=CometBar Local Dev" -addext "keyUsage=critical,digitalSignature" \
#     -addext "extendedKeyUsage=codeSigning" -addext "basicConstraints=critical,CA:true"
#   openssl pkcs12 -export -legacy -out cometbar.p12 -inkey key.pem -in cert.pem -passout pass:temporary
#   security import cometbar.p12 -k ~/Library/Keychains/login.keychain-db -P temporary -T /usr/bin/codesign -A
#   security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db cert.pem
SIGN_IDENTITY := CometBar Local Dev

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
