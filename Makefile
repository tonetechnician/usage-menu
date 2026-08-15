SHELL := /bin/sh

PROJECT := UsageMenu.xcodeproj
SCHEME := UsageMenu
DESTINATION := platform=macOS
BUILD_DIR := $(CURDIR)/.build
DERIVED_DATA := $(BUILD_DIR)/DerivedData
CONFIGURATION ?= Debug
PACKAGE_DIR := $(CURDIR)/dist
VERSION := $(shell tr -d '\r\n' < VERSION)
BUNDLE_BUILD ?= 1
PACKAGE_ZIP := UsageMenu-$(VERSION)-universal-adhoc.zip
PACKAGE_PKG := UsageMenu-$(VERSION)-universal-unsigned.pkg
DIAGNOSTIC := $(BUILD_DIR)/usage-menu-diagnostic

.PHONY: help build test check validate-release test-release test-release-workflow diagnose diagnose-fixture live-test package clean

help:
	@printf '%s\n' \
		'make build             Build the Debug app into ignored .build/' \
		'make test              Run deterministic tests into ignored .build/' \
		'make check             Clean, build, and test from source' \
		'make validate-release  Validate VERSION, optional tag, and CHANGELOG.md' \
		'make package           Create verified versioned zip, unsigned pkg, and SHA256SUMS in dist/' \
		'make diagnose          Run redacted diagnostics against local sources' \
		'make diagnose-fixture  Run deterministic, redacted diagnostic fixtures' \
		'make live-test CODEX_PATH=/absolute/path/to/codex' \
		'                       Opt in to provider-owned local-session smoke tests' \
		'make clean             Remove generated .build/ and dist/'

build:
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" \
		-destination '$(DESTINATION)' -derivedDataPath "$(DERIVED_DATA)" \
		-configuration "$(CONFIGURATION)" MARKETING_VERSION="$(VERSION)" CURRENT_PROJECT_VERSION="$(BUNDLE_BUILD)" build

test:
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" \
		-destination '$(DESTINATION)' -derivedDataPath "$(DERIVED_DATA)" \
		-configuration "$(CONFIGURATION)" MARKETING_VERSION="$(VERSION)" CURRENT_PROJECT_VERSION="$(BUNDLE_BUILD)" test

check: clean build test test-release test-release-workflow

validate-release:
	@bin/release-validate

test-release:
	@bin/release-test

test-release-workflow:
	@ruby bin/release-workflow-test

diagnose: $(DIAGNOSTIC)
	"$(DIAGNOSTIC)"

diagnose-fixture: $(DIAGNOSTIC)
	"$(DIAGNOSTIC)" --fixture

$(DIAGNOSTIC): \
	UsageMenu/Domain/UsageModels.swift \
	UsageMenu/Providers/OpenAI/CodexAppServer.swift \
	UsageMenu/Providers/OpenAI/CodexExecutableDiscovery.swift \
	UsageMenu/Providers/Anthropic/AnthropicQuotaSource.swift \
	UsageMenu/Diagnostics/RedactedDiagnostics.swift \
	UsageMenu/Diagnostics/DiagnosticMain.swift
	@mkdir -p "$(BUILD_DIR)"
	xcrun swiftc -O -framework Security $^ -o "$@"

# Explicit opt-in. This consumes provider-owned local sessions only in memory.
live-test:
	@test -n "$(CODEX_PATH)" || { echo 'CODEX_PATH=/absolute/path/to/codex is required' >&2; exit 2; }
	@case "$(CODEX_PATH)" in /*) ;; *) echo 'CODEX_PATH must be an absolute path' >&2; exit 2;; esac
	USAGE_MENU_RUN_LIVE_TESTS=1 USAGE_MENU_RUN_ANTHROPIC_LIVE_TESTS=1 \
	USAGE_MENU_CODEX_PATH="$(CODEX_PATH)" \
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -destination '$(DESTINATION)' \
		-derivedDataPath "$(DERIVED_DATA)" -testPlan UsageMenuLive test

# Builds one universal app, ad-hoc signs it, and verifies that exact app through both
# archive formats. The installer package is intentionally unsigned and not notarized.
package: validate-release
	@set -eu; \
	DERIVED="$(BUILD_DIR)/PackageDerivedData"; APP="$$DERIVED/Build/Products/Release/UsageMenu.app"; \
	ZIP="$(PACKAGE_DIR)/$(PACKAGE_ZIP)"; PKG="$(PACKAGE_DIR)/$(PACKAGE_PKG)"; SUMS="$(PACKAGE_DIR)/SHA256SUMS"; \
	ROUND="$(BUILD_DIR)/package-roundtrip"; EXPANDED="$(BUILD_DIR)/package-expanded"; \
	trap 'rm -f "$$ZIP" "$$PKG" "$$SUMS"' EXIT HUP INT TERM; \
	rm -rf "$$DERIVED" "$$ROUND" "$$EXPANDED"; mkdir -p "$(PACKAGE_DIR)" "$$ROUND"; \
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration Release -destination 'generic/platform=macOS' \
		-derivedDataPath "$$DERIVED" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- \
		MARKETING_VERSION="$(VERSION)" CURRENT_PROJECT_VERSION="$(BUNDLE_BUILD)" clean build; \
	test -d "$$APP" || { echo 'REFUSING: build produced no app bundle' >&2; exit 1; }; \
	codesign --force --deep --sign - --timestamp=none "$$APP"; \
	SLICES=$$(lipo -info "$$APP/Contents/MacOS/UsageMenu"); echo "$$SLICES" | grep -q arm64 && echo "$$SLICES" | grep -q x86_64 || { echo "REFUSING: universal slices missing — $$SLICES" >&2; exit 1; }; \
	codesign -dvv "$$APP" 2>&1 | grep -q 'Signature=adhoc' || { echo 'REFUSING: signature is not ad-hoc' >&2; exit 1; }; codesign --verify --deep --strict "$$APP"; \
	rm -f "$$ZIP" "$$PKG" "$$SUMS"; ditto -c -k --sequesterRsrc --keepParent "$$APP" "$$ZIP"; ditto -x -k "$$ZIP" "$$ROUND"; \
	EXTRACTED="$$ROUND/UsageMenu.app"; test -d "$$EXTRACTED" || { rm -f "$$ZIP"; echo 'REFUSING: archive does not contain app' >&2; exit 1; }; \
	RSLICES=$$(lipo -info "$$EXTRACTED/Contents/MacOS/UsageMenu"); echo "$$RSLICES" | grep -q arm64 && echo "$$RSLICES" | grep -q x86_64 || { rm -f "$$ZIP"; echo 'REFUSING: archive lost a slice' >&2; exit 1; }; codesign --verify --deep --strict "$$EXTRACTED" || { rm -f "$$ZIP"; echo 'REFUSING: archive broke signature' >&2; exit 1; }; \
	pkgbuild --component "$$APP" --install-location /Applications "$$PKG"; \
	pkgutil --check-signature "$$PKG" 2>&1 | grep -Eqi 'unsigned|not signed' || { rm -f "$$PKG"; echo 'REFUSING: installer must be unsigned' >&2; exit 1; }; \
	pkgutil --payload-files "$$PKG" | grep -qx './UsageMenu.app/Contents/MacOS/UsageMenu' || { rm -f "$$PKG"; echo 'REFUSING: installer payload lacks UsageMenu.app' >&2; exit 1; }; \
	pkgutil --expand-full "$$PKG" "$$EXPANDED"; test -f "$$EXPANDED/PackageInfo" && grep -q 'install-location="/Applications"' "$$EXPANDED/PackageInfo" || { echo 'REFUSING: installer location is not /Applications' >&2; exit 1; }; \
	PAYLOAD_APP="$$EXPANDED/Payload/UsageMenu.app"; test -d "$$PAYLOAD_APP" || { echo 'REFUSING: installer payload is malformed' >&2; exit 1; }; \
	PSLICES=$$(lipo -info "$$PAYLOAD_APP/Contents/MacOS/UsageMenu"); echo "$$PSLICES" | grep -q arm64 && echo "$$PSLICES" | grep -q x86_64 || { echo 'REFUSING: installer payload lost a slice' >&2; exit 1; }; codesign --verify --deep --strict "$$PAYLOAD_APP" || { echo 'REFUSING: installer payload broke signature' >&2; exit 1; }; \
	(cd "$(PACKAGE_DIR)" && shasum -a 256 "$(PACKAGE_ZIP)" "$(PACKAGE_PKG)" > SHA256SUMS && shasum -a 256 -c SHA256SUMS); \
	test "$$(awk 'END { print NR }' "$$SUMS")" = 2 && awk '{ if ($$2 !~ /^UsageMenu-[0-9]+\.[0-9]+\.[0-9]+-universal-(adhoc\.zip|unsigned\.pkg)$$/) exit 1 } END { exit NR == 2 ? 0 : 1 }' "$$SUMS" || { echo 'REFUSING: checksums must name only release basenames' >&2; exit 1; }; \
	trap - EXIT HUP INT TERM; echo "Generated unsigned/not notarized $$ZIP, $$PKG, and $$SUMS"

clean:
	rm -rf "$(BUILD_DIR)" "$(PACKAGE_DIR)"
