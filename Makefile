SHELL := /bin/sh

PROJECT := UsageMenu.xcodeproj
SCHEME := UsageMenu
DESTINATION := platform=macOS
BUILD_DIR := $(CURDIR)/.build
DERIVED_DATA := $(BUILD_DIR)/DerivedData
CONFIGURATION ?= Debug
PACKAGE_DIR := $(CURDIR)/dist
PACKAGE_NAME := UsageMenu-universal-adhoc.zip
DIAGNOSTIC := $(BUILD_DIR)/usage-menu-diagnostic

.PHONY: help build test check diagnose diagnose-fixture live-test package clean

help:
	@printf '%s\n' \
		'make build             Build the Debug app into ignored .build/' \
		'make test              Run deterministic tests into ignored .build/' \
		'make check             Clean, build, and test from source' \
		'make diagnose          Run redacted diagnostics against local sources' \
		'make diagnose-fixture  Run deterministic, redacted diagnostic fixtures' \
		'make live-test CODEX_PATH=/absolute/path/to/codex' \
		'                       Opt in to provider-owned local-session smoke tests' \
		'make package           Create a verified ad-hoc archive in ignored dist/' \
		'make clean             Remove generated .build/ and dist/'

build:
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" \
		-destination '$(DESTINATION)' -derivedDataPath "$(DERIVED_DATA)" \
		-configuration "$(CONFIGURATION)" build

test:
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" \
		-destination '$(DESTINATION)' -derivedDataPath "$(DERIVED_DATA)" \
		-configuration "$(CONFIGURATION)" test

check: clean build test

diagnose: $(DIAGNOSTIC)
	"$(DIAGNOSTIC)"

diagnose-fixture: $(DIAGNOSTIC)
	"$(DIAGNOSTIC)" --fixture

$(DIAGNOSTIC): \
	UsageMenu/Domain/UsageModels.swift \
	UsageMenu/Codex/CodexAppServer.swift \
	UsageMenu/Codex/CodexExecutableDiscovery.swift \
	UsageMenu/Anthropic/AnthropicQuotaSource.swift \
	UsageMenu/Diagnostics/RedactedDiagnostics.swift \
	UsageMenu/Diagnostics/DiagnosticMain.swift
	@mkdir -p "$(BUILD_DIR)"
	xcrun swiftc -O -framework Security $^ -o "$@"

# Explicit opt-in. This consumes provider-owned local sessions only in memory.
# An executable path is passed only to this invocation and is never persisted.
live-test:
	@test -n "$(CODEX_PATH)" || { echo 'CODEX_PATH=/absolute/path/to/codex is required' >&2; exit 2; }
	@case "$(CODEX_PATH)" in /*) ;; *) echo 'CODEX_PATH must be an absolute path' >&2; exit 2;; esac
	USAGE_MENU_RUN_LIVE_TESTS=1 USAGE_MENU_RUN_ANTHROPIC_LIVE_TESTS=1 \
	USAGE_MENU_CODEX_PATH="$(CODEX_PATH)" \
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" \
		-destination '$(DESTINATION)' -derivedDataPath "$(DERIVED_DATA)" \
		-testPlan UsageMenuLive test

# Generates an ad-hoc universal archive locally. It never uploads, notarizes, or
# reads Apple Developer credentials. Verification failures remove the archive.
package:
	@set -eu; \
	DERIVED="$(BUILD_DIR)/PackageDerivedData"; \
	APP="$$DERIVED/Build/Products/Release/UsageMenu.app"; \
	ZIP="$(PACKAGE_DIR)/$(PACKAGE_NAME)"; \
	ROUND="$(BUILD_DIR)/package-roundtrip"; \
	rm -rf "$$DERIVED" "$$ROUND"; mkdir -p "$(PACKAGE_DIR)" "$$ROUND"; \
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" \
		-configuration Release -destination 'generic/platform=macOS' \
		-derivedDataPath "$$DERIVED" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
		CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- clean build; \
	test -d "$$APP" || { echo 'REFUSING: build produced no app bundle' >&2; exit 1; }; \
	codesign --force --deep --sign - --timestamp=none "$$APP"; \
	SLICES=$$(lipo -info "$$APP/Contents/MacOS/UsageMenu"); \
	echo "$$SLICES" | grep -q arm64 || { echo "REFUSING: arm64 slice missing — $$SLICES" >&2; exit 1; }; \
	echo "$$SLICES" | grep -q x86_64 || { echo "REFUSING: x86_64 slice missing — $$SLICES" >&2; exit 1; }; \
	codesign -dvv "$$APP" 2>&1 | grep -q 'Signature=adhoc' || { echo 'REFUSING: signature is not ad-hoc' >&2; exit 1; }; \
	codesign --verify --deep --strict "$$APP"; \
	rm -f "$$ZIP"; ditto -c -k --sequesterRsrc --keepParent "$$APP" "$$ZIP"; \
	ditto -x -k "$$ZIP" "$$ROUND"; \
	EXTRACTED="$$ROUND/UsageMenu.app"; test -d "$$EXTRACTED" || { rm -f "$$ZIP"; echo 'REFUSING: archive does not contain the app' >&2; exit 1; }; \
	RSLICES=$$(lipo -info "$$EXTRACTED/Contents/MacOS/UsageMenu"); \
	echo "$$RSLICES" | grep -q arm64 && echo "$$RSLICES" | grep -q x86_64 || { rm -f "$$ZIP"; echo "REFUSING: archive lost a slice — $$RSLICES" >&2; exit 1; }; \
	codesign --verify --deep --strict "$$EXTRACTED" || { rm -f "$$ZIP"; echo 'REFUSING: archive broke the signature' >&2; exit 1; }; \
	shasum -a 256 "$$ZIP"; \
	echo "Generated $$ZIP"

clean:
	rm -rf "$(BUILD_DIR)" "$(PACKAGE_DIR)"
