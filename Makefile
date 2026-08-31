.PHONY: help lint lint-fix format check setup-hooks build test app run-app dist dist-prereqs
.DEFAULT_GOAL := help

APP_NAME = Tethersnap
APP_BUNDLE = .build/$(APP_NAME).app

# Distribution (make dist): Developer ID signing + notarized DMG.
SIGN_ID ?= Developer ID Application
NOTARY_PROFILE ?= tethersnap-notary
VERSION = $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Support/Info.plist)
DIST_DIR = dist
DMG = $(DIST_DIR)/$(APP_NAME)-$(VERSION).dmg

help:
	@echo "Project targets:"
	@echo "  make build        swift build or xcodebuild"
	@echo "  make test         swift test or xcodebuild test"
	@echo "  make app          Build release Tethersnap.app bundle into .build/"
	@echo "  make run-app      Build and open Tethersnap.app"
	@echo "  make dist         Developer ID signed + notarized DMG into dist/"
	@echo "  make lint         Run SwiftLint"
	@echo "  make lint-fix     Run SwiftLint --fix"
	@echo "  make format       Run SwiftFormat (modifies files)"
	@echo "  make check        Strict lint + format check (CI gate)"
	@echo "  make setup-hooks  Install pre-commit hooks"

lint:
	swiftlint

lint-fix:
	swiftlint --fix

format:
	swiftformat .

check:
	swiftlint --strict
	swiftformat --lint .

setup-hooks:
	git config core.hooksPath Scripts/git-hooks
	@echo "Git hooks configured to Scripts/git-hooks/"

build:
	swift build

test:
	swift test

app:
	swift build -c release --product TethersnapApp
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	cp .build/release/TethersnapApp $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp Support/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	cp Support/Tethersnap.icns $(APP_BUNDLE)/Contents/Resources/
	cp -R .build/release/Tethersnap_TethersnapKit.bundle $(APP_BUNDLE)/Contents/Resources/
	cp -R .build/release/Tethersnap_TethersnapApp.bundle $(APP_BUNDLE)/Contents/Resources/
	codesign --force --sign - $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE)"

run-app: app
	open $(APP_BUNDLE)

# Full release pipeline: hardened-runtime Developer ID signature, notarize the
# app, staple it, wrap in a DMG, notarize and staple that too, then verify with
# Gatekeeper. Needs a "Developer ID Application" certificate in the keychain
# and stored notarytool credentials; dist-prereqs explains how to set up both.
dist: dist-prereqs app
	codesign --force --options runtime --timestamp --sign "$(SIGN_ID)" $(APP_BUNDLE)
	codesign --verify --strict $(APP_BUNDLE)
	rm -rf $(DIST_DIR)
	mkdir -p $(DIST_DIR)/staging
	ditto -c -k --keepParent $(APP_BUNDLE) $(DIST_DIR)/$(APP_NAME).zip
	xcrun notarytool submit $(DIST_DIR)/$(APP_NAME).zip --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(APP_BUNDLE)
	cp -R $(APP_BUNDLE) $(DIST_DIR)/staging/
	ln -s /Applications $(DIST_DIR)/staging/Applications
	hdiutil create -volname $(APP_NAME) -srcfolder $(DIST_DIR)/staging -ov -format UDZO $(DMG)
	codesign --force --sign "$(SIGN_ID)" $(DMG)
	xcrun notarytool submit $(DMG) --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(DMG)
	rm -rf $(DIST_DIR)/staging $(DIST_DIR)/$(APP_NAME).zip
	spctl -a -vv -t install $(DMG)
	@echo "Ready for the GitHub release: $(DMG)"

dist-prereqs:
	@security find-identity -v -p codesigning | grep -q "$(SIGN_ID)" || { \
	  echo "error: no '$(SIGN_ID)' certificate in the keychain."; \
	  echo "Create one at developer.apple.com -> Certificates -> Developer ID Application"; \
	  echo "(Account Holder role required; Xcode -> Settings -> Accounts -> Manage"; \
	  echo "Certificates can also create it), download, double-click to install."; \
	  exit 1; }
	@xcrun notarytool history --keychain-profile $(NOTARY_PROFILE) >/dev/null 2>&1 || { \
	  echo "error: notarytool credentials '$(NOTARY_PROFILE)' not stored. Run once:"; \
	  echo "  xcrun notarytool store-credentials $(NOTARY_PROFILE) \\"; \
	  echo "    --apple-id <your Apple ID email> --team-id 8KBV9T7MS7 \\"; \
	  echo "    --password <app-specific password from account.apple.com>"; \
	  exit 1; }
