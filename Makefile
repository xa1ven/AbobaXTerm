# AbobaXTerm build helpers. `make` = generate project + build the app.
SCHEME      := AbobaXTerm
DERIVED     := build/DerivedData
APP         := $(DERIVED)/Build/Products/Debug/AbobaXTerm.app
PACKAGE_DIR := Packages/AbobaXTermKit

.PHONY: all project build test run clean open

all: build

project:
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
