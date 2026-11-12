# AbobaXTerm build helpers. `make` = generate project + build the app.
SCHEME      := AbobaXTerm
DERIVED     := build/DerivedData
APP         := $(DERIVED)/Build/Products/Debug/AbobaXTerm.app
PACKAGE_DIR := Packages/AbobaXTermKit

XSERVER     := Vendor/xserver/bin/Xvfb

VERSION     := $(shell sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
DIST        := build/dist
DMG         := $(DIST)/AbobaXTerm-$(VERSION).dmg

.PHONY: all project build test run clean open xserver dist icon

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

# Installable build: Release app in a disk image with a shortcut to /Applications
# (window layout and background: Scripts/make-dmg.sh).
# Apple Silicon only (the bundled X server is arm64). Ad-hoc signed, not notarized:
# a downloaded copy has to be allowed once in System Settings > Privacy & Security.
dist: project
	xcodebuild -project AbobaXTerm.xcodeproj -scheme $(SCHEME) -configuration Release \
		-derivedDataPath $(DERIVED) -skipPackagePluginValidation -quiet ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build
	codesign --verify --deep --strict $(DERIVED)/Build/Products/Release/AbobaXTerm.app
	rm -rf $(DIST) && mkdir -p $(DIST)
	Scripts/make-dmg.sh $(DERIVED)/Build/Products/Release/AbobaXTerm.app $(DMG)

# App icon: all sizes of the AppIcon set from Scripts/art/AppIcon.svg.
icon:
	Scripts/make-icon.sh

test:
	cd $(PACKAGE_DIR) && swift test

run: build
	open $(APP)

open: project
	open AbobaXTerm.xcodeproj

clean:
	rm -rf build $(PACKAGE_DIR)/.build
