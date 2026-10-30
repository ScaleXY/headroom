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
#   make dmg-background  redraw assets/dmg-background.tiff, the DMG window background (needs Chrome)
#   make notarize   notarize and staple the DMG (needs NOTARY_PROFILE, see below)
#   make mobile-project   generate Mobile/Headroom.xcodeproj from Mobile/project.yml (needs XcodeGen)
#   make mobile-build     build the iPhone, iPad and Watch apps for the simulators (unsigned)
#   make mobile-previews  render complications, Live Activity, widgets and phone screens to PNGs
#
# Distribution builds need a "Developer ID Application" certificate in the keychain; it is picked
# over Apple Development automatically and signs with a secure timestamp, as notarization requires.
# Store notary credentials once with `xcrun notarytool store-credentials <profile>`, then run
# `make dmg notarize NOTARY_PROFILE=<profile>` (add NOTARY_KEYCHAIN=<path> when the profile lives
# outside the default keychain, as it does in CI).
#
# iPhone & Watch sync needs iCloud entitlements, which macOS only honors with an embedded
# provisioning profile. Put Headroom's at Packaging/profiles/headroom.provisionprofile (gitignored):
# a Developer ID profile for releases, or a macOS development profile with CLOUDKIT_ENV=Development.
# Without one (a build from source) the app is signed exactly as before and runs with sync unavailable.
#
# Tagged releases are built by .github/workflows/release.yml: push a tag `v<version>` and the
# workflow stamps that version in with Scripts/set-version.sh (run it yourself to bump it here).

VERSION   := 0.1.1-beta.5
BUNDLE_ID := com.scalexy.headroom
APP       := build/Headroom.app
DMG       := dist/Headroom-$(VERSION).dmg
RELEASE   := .build/release
SPARKLE   := $(APP)/Contents/Frameworks/Sparkle.framework
WIDGETS   := $(APP)/Contents/PlugIns/HeadroomWidgets.appex
# dmgbuild lays out the DMG window (background, icon positions) without driving Finder.
DMGBUILD  := build/dmgbuild/bin/dmgbuild
# First valid identity of a kind, by SHA-1 (names can be ambiguous).
identity   = $(shell security find-identity -v -p codesigning | grep -v REVOKED | grep "$(1)" | head -1 | awk '{print $$2}')
DEVELOPER_ID := $(call identity,Developer ID Application)
IDENTITY  ?= $(or $(DEVELOPER_ID),$(call identity,Apple Development))
# Notarization needs a secure timestamp; local development builds skip the network round trip.
TIMESTAMP ?= $(if $(DEVELOPER_ID),--timestamp,--timestamp=none)
# iCloud for iPhone & Watch sync (see above). Developer ID builds can only use Production.
PROFILE      ?= Packaging/profiles/headroom.provisionprofile
CLOUDKIT_ENV ?= $(if $(DEVELOPER_ID),Production,Development)
APS_ENV      ?= $(if $(DEVELOPER_ID),production,development)
ENTITLEMENTS := build/Headroom.entitlements
# Profiles can also come from the environment as base64, the way CI stores them. A Development
# build (CLOUDKIT_ENV=Development, for --init-cloudkit-schema) uses the development profile;
# otherwise the Developer ID profile fills in when PROFILE is missing.
ifeq ($(CLOUDKIT_ENV),Development)
  ifneq ($(APPLE_DEVELOPER_ACCOUNT_PROFILE_COM_SCALEXY_HEADROOM_MAC_APP_DEVELOPMENT_BASE64),)
    PROFILE := build/profiles/development.provisionprofile
    $(shell mkdir -p build/profiles && printf '%s' "$$APPLE_DEVELOPER_ACCOUNT_PROFILE_COM_SCALEXY_HEADROOM_MAC_APP_DEVELOPMENT_BASE64" | base64 --decode > $(PROFILE))
    APS_ENV   := development
    TIMESTAMP := --timestamp=none
  endif
else ifeq ($(wildcard $(PROFILE)),)
  ifneq ($(APPLE_DEVELOPER_ACCOUNT_PROFILE_COM_SCALEXY_HEADROOM_MAC_APP_DIRECT_BASE64),)
    PROFILE := build/profiles/developer-id.provisionprofile
    $(shell mkdir -p build/profiles && printf '%s' "$$APPLE_DEVELOPER_ACCOUNT_PROFILE_COM_SCALEXY_HEADROOM_MAC_APP_DIRECT_BASE64" | base64 --decode > $(PROFILE))
  endif
endif
# The Apple Development certificate can come from the environment too (a .p12 as base64, see
# Scripts/p12-signing.sh): Development builds sign with it through a throwaway keychain that only
# lives while `make app` signs.
SIGN_KEYCHAIN :=
ifeq ($(CLOUDKIT_ENV),Development)
  ifneq ($(APPLE_DEVELOPER_ACCOUNT_APPLE_DEVELOPMENT_CERTIFICATE_P12_BASE64),)
    ifneq ($(origin IDENTITY),command line)
      IDENTITY := $(or $(shell Scripts/p12-signing.sh identity),P12_UNREADABLE)
    endif
    SIGN_KEYCHAIN := $(abspath build/signing.keychain-db)
  endif
endif
CODESIGN := codesign $(if $(SIGN_KEYCHAIN),--keychain $(SIGN_KEYCHAIN))
# With a profile, the whole bundle must be signed by a certificate the profile lists; any other
# gets the app killed at launch.
ifneq ($(wildcard $(PROFILE)),)
  PROFILE_CERTS := $(shell Scripts/profile-certificates.sh $(PROFILE))
  ifneq ($(SIGN_KEYCHAIN),)
    ifeq ($(filter $(IDENTITY),$(PROFILE_CERTS)),)
      SIGN_ERROR := The certificate from APPLE_DEVELOPER_ACCOUNT_APPLE_DEVELOPMENT_CERTIFICATE_P12_BASE64 ($(IDENTITY)) isn't in $(PROFILE), which lists $(PROFILE_CERTS).
    endif
  else ifneq ($(origin IDENTITY),command line)
    KEYCHAIN_IDS := $(shell security find-identity -v -p codesigning | awk '/\)/ {print $$2}')
    IDENTITY := $(or $(firstword $(filter $(PROFILE_CERTS),$(KEYCHAIN_IDS))),NO_PROFILE_CERTIFICATE)
    ifeq ($(IDENTITY),NO_PROFILE_CERTIFICATE)
      SIGN_ERROR := None of the certificates in $(PROFILE) ($(PROFILE_CERTS)) can sign here. Set the APPLE_DEVELOPER_ACCOUNT_APPLE_DEVELOPMENT_CERTIFICATE_* variables, or edit the profile to list your certificate.
    endif
  endif
endif

.PHONY: all build test app install icon clean bench screenshots appstore release dmg dmg-background notarize \
        mobile-project mobile-build mobile-previews

all: build

build:
	swift build -c release --product HeadroomApp
	swift build -c release --product headroom
	swift build -c release --product HeadroomFanHelper
	swift build -c release --product HeadroomWidgets

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

dmg: app $(DMGBUILD)
	rm -f $(DMG)* && mkdir -p dist
	$(DMGBUILD) -s Packaging/dmg_settings.py -D app=$(APP) Headroom $(DMG)
	codesign --force $(TIMESTAMP) --sign "$(IDENTITY)" $(DMG)
	cd dist && shasum -a 256 $(notdir $(DMG)) > $(notdir $(DMG)).sha256
	@cat $(DMG).sha256

$(DMGBUILD):
	python3 -m venv build/dmgbuild
	build/dmgbuild/bin/pip install --quiet dmgbuild==1.6.7

dmg-background:
	python3 -I Scripts/dmg_background.py

notarize:
	@test -n "$(NOTARY_PROFILE)" || { echo "Set NOTARY_PROFILE to a profile from 'xcrun notarytool store-credentials'."; exit 1; }
	@test -n "$(DEVELOPER_ID)" || { echo "Notarization needs a Developer ID Application certificate."; exit 1; }
	xcrun notarytool submit $(DMG) --keychain-profile "$(NOTARY_PROFILE)" $(if $(NOTARY_KEYCHAIN),--keychain "$(NOTARY_KEYCHAIN)") --wait
	xcrun stapler staple $(DMG)
	xcrun stapler staple $(APP)
	cd dist && shasum -a 256 $(notdir $(DMG)) > $(notdir $(DMG)).sha256
	@cat $(DMG).sha256

app: build
	@$(if $(SIGN_ERROR),echo "error: $(SIGN_ERROR)"; exit 1)
	@$(if $(filter P12_UNREADABLE,$(IDENTITY)),echo "error: couldn't read the .p12 from the environment (see above)."; exit 1)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources/brand $(APP)/Contents/Library/LaunchDaemons
	cp Packaging/Info.plist $(APP)/Contents/Info.plist
	cp $(RELEASE)/HeadroomApp $(APP)/Contents/MacOS/HeadroomApp
	cp $(RELEASE)/headroom $(APP)/Contents/MacOS/headroom
	mkdir -p $(APP)/Contents/Frameworks
	ditto $(RELEASE)/Sparkle.framework $(APP)/Contents/Frameworks/Sparkle.framework
	@# Headroom isn't sandboxed, so Sparkle's XPC services go unused (Sparkle's docs allow removing them).
	rm -rf $(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices $(APP)/Contents/Frameworks/Sparkle.framework/XPCServices
	cp $(RELEASE)/HeadroomFanHelper $(APP)/Contents/MacOS/HeadroomFanHelper
	cp Packaging/$(BUNDLE_ID).fan.plist $(APP)/Contents/Library/LaunchDaemons/
	cp -R $(RELEASE)/Headroom_HeadroomKit.bundle $(APP)/Contents/Resources/
	cp assets/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	cp assets/brand/claude.svg assets/brand/openai.svg $(APP)/Contents/Resources/brand/
	cp Packaging/headroom.1 $(APP)/Contents/Resources/headroom.1
	@# The desktop widgets: a WidgetKit extension that reads widgets.json, versioned with the app.
	mkdir -p $(WIDGETS)/Contents/MacOS $(WIDGETS)/Contents/Resources/brand
	cp Packaging/Widgets/Info.plist $(WIDGETS)/Contents/Info.plist
	plutil -replace CFBundleShortVersionString -string "$$(plutil -extract CFBundleShortVersionString raw Packaging/Info.plist)" $(WIDGETS)/Contents/Info.plist
	plutil -replace CFBundleVersion -string "$$(plutil -extract CFBundleVersion raw Packaging/Info.plist)" $(WIDGETS)/Contents/Info.plist
	cp $(RELEASE)/HeadroomWidgets $(WIDGETS)/Contents/MacOS/HeadroomWidgets
	cp assets/brand/claude.svg assets/brand/openai.svg $(WIDGETS)/Contents/Resources/brand/
	strip -x $(APP)/Contents/MacOS/HeadroomApp $(APP)/Contents/MacOS/headroom $(APP)/Contents/MacOS/HeadroomFanHelper $(WIDGETS)/Contents/MacOS/HeadroomWidgets
	@$(if $(SIGN_KEYCHAIN),Scripts/p12-signing.sh open $(SIGN_KEYCHAIN))
	$(CODESIGN) --force $(TIMESTAMP) --options runtime --sign "$(IDENTITY)" $(APP)/Contents/MacOS/headroom
	@# Sparkle inside out: its helpers, then the framework, then the app.
	$(CODESIGN) --force $(TIMESTAMP) --options runtime --sign "$(IDENTITY)" $(SPARKLE)/Versions/B/Autoupdate
	$(CODESIGN) --force $(TIMESTAMP) --options runtime --sign "$(IDENTITY)" $(SPARKLE)/Versions/B/Updater.app
	$(CODESIGN) --force $(TIMESTAMP) --options runtime --sign "$(IDENTITY)" $(SPARKLE)
	@# The fan helper and the app each check that the other carries this identifier and their team.
	$(CODESIGN) --force $(TIMESTAMP) --options runtime --identifier $(BUNDLE_ID).fan --sign "$(IDENTITY)" $(APP)/Contents/MacOS/HeadroomFanHelper
	$(CODESIGN) --force $(TIMESTAMP) --options runtime --entitlements Packaging/Widgets/HeadroomWidgets.entitlements --sign "$(IDENTITY)" $(WIDGETS)
	@# With the profile: iCloud entitlements for sync. Without: as before, and sync says it's unavailable.
	@if [ -f "$(PROFILE)" ]; then \
		cp "$(PROFILE)" $(APP)/Contents/embedded.provisionprofile; \
		team=$$(security cms -D -i "$(PROFILE)" | plutil -extract TeamIdentifier.0 raw -o - -); \
		sed -e "s/@TEAM_ID@/$$team/g" -e "s/@CLOUDKIT_ENV@/$(CLOUDKIT_ENV)/" -e "s/@APS_ENV@/$(APS_ENV)/" \
			Packaging/Headroom.entitlements.in > $(ENTITLEMENTS); \
		Scripts/check-entitlements.sh "$(PROFILE)" $(ENTITLEMENTS); \
		$(CODESIGN) --force $(TIMESTAMP) --options runtime --entitlements $(ENTITLEMENTS) --sign "$(IDENTITY)" $(APP); \
	else \
		echo "No $(PROFILE): building without iPhone & Watch sync."; \
		$(CODESIGN) --force $(TIMESTAMP) --options runtime --sign "$(IDENTITY)" $(APP); \
	fi
	@$(if $(SIGN_KEYCHAIN),Scripts/p12-signing.sh close $(SIGN_KEYCHAIN))
	codesign --verify --deep --strict $(APP)
	@du -sh $(APP)/Contents/MacOS/HeadroomApp $(APP)/Contents/MacOS/headroom $(APP)/Contents/MacOS/HeadroomFanHelper $(WIDGETS)

install: app
	-osascript -e 'tell application id "$(BUNDLE_ID)" to quit' 2>/dev/null
	-pkill -x HeadroomApp
	rm -rf /Applications/Headroom.app
	ditto $(APP) /Applications/Headroom.app
	mkdir -p $(HOME)/.local/bin $(HOME)/.local/share/man/man1
	ln -sf /Applications/Headroom.app/Contents/MacOS/headroom $(HOME)/.local/bin/headroom
	ln -sf /Applications/Headroom.app/Contents/Resources/headroom.1 $(HOME)/.local/share/man/man1/headroom.1
	open /Applications/Headroom.app

# iPhone, iPad and Apple Watch. The project is generated, never committed.
MOBILE_DD := build/mobile

mobile-project:
	@command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }
	cd Mobile && xcodegen generate --spec project.yml

mobile-build: mobile-project
	xcodebuild -project Mobile/Headroom.xcodeproj -scheme Headroom -destination "generic/platform=iOS Simulator" \
		-derivedDataPath $(MOBILE_DD) CODE_SIGNING_ALLOWED=NO build
	xcodebuild -project Mobile/Headroom.xcodeproj -scheme HeadroomWatch -destination "generic/platform=watchOS Simulator" \
		-derivedDataPath $(MOBILE_DD) CODE_SIGNING_ALLOWED=NO build

mobile-previews:
	swift run HeadroomWidgetPreview build/previews --mobile

clean:
	rm -rf build .build dist
