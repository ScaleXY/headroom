# Headroom: build, assemble, sign and install.
#   make            build release binaries
#   make test       run the test suites
#   make app        assemble and sign build/Headroom.app
#   make install    install to /Applications, link the CLI and man page, restart the app
#   make icon       regenerate assets/AppIcon.icns from assets/icon.svg
#   make screenshots  render the README images in media/ from fixtures (needs Google Chrome)
#   make appstore   render the Mac App Store screenshots, app preview and icon into appstore/ (needs Chrome, ffmpeg)
#   make release    zip the signed app into dist/ with a SHA-256 checksum
#   make dmg        build dist/Headroom-<version>.dmg (drag to Applications) with a SHA-256 checksum
#   make notarize   notarize and staple the DMG (needs NOTARY_PROFILE, see below)
#
# Distribution builds need a "Developer ID Application" certificate in the keychain; it is picked
# over Apple Development automatically and signs with a secure timestamp, as notarization requires.
# Store notary credentials once with `xcrun notarytool store-credentials <profile>`, then run
# `make dmg notarize NOTARY_PROFILE=<profile>`.

VERSION   := 0.1.0-beta.4
BUNDLE_ID := com.scalexy.headroom
APP       := build/Headroom.app
DMG       := dist/Headroom-$(VERSION).dmg
RELEASE   := .build/release
# First valid identity of a kind, by SHA-1 (names can be ambiguous).
identity   = $(shell security find-identity -v -p codesigning | grep -v REVOKED | grep "$(1)" | head -1 | awk '{print $$2}')
DEVELOPER_ID := $(call identity,Developer ID Application)
IDENTITY  ?= $(or $(DEVELOPER_ID),$(call identity,Apple Development))
# Notarization needs a secure timestamp; local development builds skip the network round trip.
TIMESTAMP ?= $(if $(DEVELOPER_ID),--timestamp,--timestamp=none)

.PHONY: all build test app install icon clean bench screenshots appstore release dmg notarize

all: build

build:
	swift build -c release --product HeadroomApp
	swift build -c release --product headroom

test:
	swift test

bench:
	swift run -c release HeadroomBench

icon:
	Scripts/make-icon.sh

screenshots:
	python3 -I Scripts/readme_media.py

appstore:
	python3 -I Scripts/appstore_media.py

release: app
	mkdir -p dist && rm -f dist/Headroom-$(VERSION).zip*
	ditto -c -k --sequesterRsrc --keepParent $(APP) dist/Headroom-$(VERSION).zip
	cd dist && shasum -a 256 Headroom-$(VERSION).zip > Headroom-$(VERSION).zip.sha256
	@cat dist/Headroom-$(VERSION).zip.sha256

dmg: app
	rm -rf build/dmg $(DMG)* && mkdir -p build/dmg dist
	ditto $(APP) build/dmg/Headroom.app
	ln -s /Applications build/dmg/Applications
	hdiutil create -volname Headroom -srcfolder build/dmg -fs HFS+ -format UDZO -ov $(DMG)
	codesign --force $(TIMESTAMP) --sign "$(IDENTITY)" $(DMG)
	cd dist && shasum -a 256 $(notdir $(DMG)) > $(notdir $(DMG)).sha256
	@cat $(DMG).sha256

notarize:
	@test -n "$(NOTARY_PROFILE)" || { echo "Set NOTARY_PROFILE to a profile from 'xcrun notarytool store-credentials'."; exit 1; }
	@test -n "$(DEVELOPER_ID)" || { echo "Notarization needs a Developer ID Application certificate."; exit 1; }
	xcrun notarytool submit $(DMG) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(DMG)
	xcrun stapler staple $(APP)
	cd dist && shasum -a 256 $(notdir $(DMG)) > $(notdir $(DMG)).sha256
	@cat $(DMG).sha256

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources/brand
	cp Packaging/Info.plist $(APP)/Contents/Info.plist
	cp $(RELEASE)/HeadroomApp $(APP)/Contents/MacOS/HeadroomApp
	cp $(RELEASE)/headroom $(APP)/Contents/MacOS/headroom
	cp -R $(RELEASE)/Headroom_HeadroomKit.bundle $(APP)/Contents/Resources/
	cp assets/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	cp assets/brand/claude.svg assets/brand/openai.svg $(APP)/Contents/Resources/brand/
	cp Packaging/headroom.1 $(APP)/Contents/Resources/headroom.1
	strip -x $(APP)/Contents/MacOS/HeadroomApp $(APP)/Contents/MacOS/headroom
	codesign --force $(TIMESTAMP) --options runtime --sign "$(IDENTITY)" $(APP)/Contents/MacOS/headroom
	codesign --force $(TIMESTAMP) --options runtime --sign "$(IDENTITY)" $(APP)
	codesign --verify --deep --strict $(APP)
	@du -sh $(APP)/Contents/MacOS/HeadroomApp $(APP)/Contents/MacOS/headroom

install: app
	-osascript -e 'tell application id "$(BUNDLE_ID)" to quit' 2>/dev/null
	-pkill -x HeadroomApp
	rm -rf /Applications/Headroom.app
	ditto $(APP) /Applications/Headroom.app
	mkdir -p $(HOME)/.local/bin $(HOME)/.local/share/man/man1
	ln -sf /Applications/Headroom.app/Contents/MacOS/headroom $(HOME)/.local/bin/headroom
	ln -sf /Applications/Headroom.app/Contents/Resources/headroom.1 $(HOME)/.local/share/man/man1/headroom.1
	open /Applications/Headroom.app

clean:
	rm -rf build .build dist
