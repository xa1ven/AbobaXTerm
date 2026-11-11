# AbobaXTerm build helpers. `make` = generate project + build the app.
SCHEME      := AbobaXTerm
DERIVED     := build/DerivedData
APP         := $(DERIVED)/Build/Products/Debug/AbobaXTerm.app
PACKAGE_DIR := Packages/AbobaXTermKit

XSERVER     := Vendor/xserver/bin/Xvfb

VERSION     := $(shell sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
DIST        := build/dist
DMG         := $(DIST)/AbobaXTerm-$(VERSION).dmg

.PHONY: all project build test run clean open xserver dist

all: build

# The X server bundled with the app. Built once from X.org sources (a few
# minutes, needs network); the result in Vendor/xserver is kept in git.
$(XSERVER):
	Scripts/build-xserver.sh --clean

xserver:
	Scripts/build-xserver.sh

project: $(XSERVER)
	xcodegen generate --quiet

build: project
	xcodebuild -project AbobaXTerm.xcodeproj -scheme $(SCHEME) -configuration Debug \
		-derivedDataPath $(DERIVED) -skipPackagePluginValidation -quiet build

# Installable build: Release app in a disk image with a shortcut to /Applications.
# Apple Silicon only (the bundled X server is arm64). Ad-hoc signed, not notarized:
# a downloaded copy has to be allowed once in System Settings > Privacy & Security.
dist: project
	xcodebuild -project AbobaXTerm.xcodeproj -scheme $(SCHEME) -configuration Release \
		-derivedDataPath $(DERIVED) -skipPackagePluginValidation -quiet ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build
	rm -rf $(DIST) && mkdir -p $(DIST)/image
	ditto $(DERIVED)/Build/Products/Release/AbobaXTerm.app $(DIST)/image/AbobaXTerm.app
	codesign --verify --deep --strict $(DIST)/image/AbobaXTerm.app
	ln -s /Applications $(DIST)/image/Applications
	hdiutil create -quiet -volname AbobaXTerm -srcfolder $(DIST)/image -ov -format UDZO $(DMG)
	rm -rf $(DIST)/image
	@echo "Created $(DMG)"

test:
	cd $(PACKAGE_DIR) && swift test

run: build
	open $(APP)

open: project
	open AbobaXTerm.xcodeproj

clean:
	rm -rf build $(PACKAGE_DIR)/.build
