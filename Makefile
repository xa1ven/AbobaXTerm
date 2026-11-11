# AbobaXTerm build helpers. `make` = generate project + build the app.
SCHEME      := AbobaXTerm
DERIVED     := build/DerivedData
APP         := $(DERIVED)/Build/Products/Debug/AbobaXTerm.app
PACKAGE_DIR := Packages/AbobaXTermKit

XSERVER     := Vendor/xserver/bin/Xvfb

.PHONY: all project build test run clean open xserver

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

test:
	cd $(PACKAGE_DIR) && swift test

run: build
	open $(APP)

open: project
	open AbobaXTerm.xcodeproj

clean:
	rm -rf build $(PACKAGE_DIR)/.build
