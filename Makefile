APP := Vox.app
BIN := .build/release/Vox
SOURCES := $(wildcard Sources/Vox/*.swift)
FRAMEWORKS := -framework AppKit -framework Carbon -framework Security -framework AVFoundation -framework CoreGraphics -framework SwiftUI -framework ServiceManagement -framework Network -framework CryptoKit
SIGN_ID := Vox Dev

# We compile with swiftc directly rather than `swift build`.
# Reason: the Command Line Tools (no full Xcode) ship a buggy SwiftPM
# manifest compiler. swiftc against the system SDK is clean and standard.
# Package.swift is kept for editor/Xcode use.

.PHONY: build bundle run clean

build:
	mkdir -p .build/release
	swiftc -O $(SOURCES) -o $(BIN) $(FRAMEWORKS)

bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp $(BIN) $(APP)/Contents/MacOS/Vox
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	codesign --force --deep --sign "$(SIGN_ID)" $(APP)
	@echo "Built $(APP)"

run: bundle
	open $(APP)

clean:
	rm -rf .build $(APP)
