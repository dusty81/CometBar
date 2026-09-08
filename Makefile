APP     := CometBar
BUNDLE  := build/$(APP).app
CONFIG  := release

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
app: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp .build/$(CONFIG)/$(APP) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Sources/$(APP)/Info.plist $(BUNDLE)/Contents/Info.plist
	codesign --force --sign - --timestamp=none $(BUNDLE)
	@echo "Built $(BUNDLE) — run it with: open $(BUNDLE)"

# Ad-hoc signed only. Notarisation would need a Developer ID cert; not needed
# for local use.
install: app
	rm -rf /Applications/$(APP).app
	cp -R $(BUNDLE) /Applications/
	@echo "Installed to /Applications/$(APP).app"

clean:
	rm -rf .build build
