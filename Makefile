.PHONY: gen build install run test kit-test ssh-test mobile-build clean

# GooseAgentMobile / HerdrSSH are arm64-only (libssh2 + OpenSSL xcframeworks).
# Keep code signing on so Simulator Keychain (device SSH key) works; unsigned
# builds log errSecMissingEntitlement (-34018) on every launch.
MOBILE_BUILD = xcodebuild -project GooseHerdr.xcodeproj -scheme GooseAgentMobile \
	-configuration Debug \
	-destination 'platform=iOS Simulator,name=iPhone 17,arch=arm64' \
	-derivedDataPath build-ios build \
	-skipPackagePluginValidation \
	ARCHS=arm64 ONLY_ACTIVE_ARCH=YES EXCLUDED_ARCHS=x86_64

SSH_TEST = cd Packages/HerdrSSH && xcodebuild test \
	-scheme HerdrSSH \
	-destination 'platform=iOS Simulator,name=iPhone 17,arch=arm64' \
	-derivedDataPath ../../build/HerdrSSHDerivedData \
	-collect-test-diagnostics never \
	-parallel-testing-enabled NO

CODE_SIGN_IDENTITY ?= -
APP_BUNDLE = Goose Agent.app
APP_BUILT = build/Build/Products/Debug/$(APP_BUNDLE)

gen:
	xcodegen generate

# Compile, then install into /Applications (quit → replace → relaunch if needed).
build: gen
	set -o pipefail; xcodebuild -project GooseHerdr.xcodeproj -scheme GooseAgent -configuration Debug -derivedDataPath build build CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)" CODE_SIGN_STYLE=Manual -skipPackagePluginValidation | tee /tmp/goose-herdr-build.log | tail -8
	./scripts/install-app.sh "$(CURDIR)/$(APP_BUILT)"

# Install only (no rebuild) from the last Debug product.
install:
	./scripts/install-app.sh "$(CURDIR)/$(APP_BUILT)"

run: build
	open "/Applications/$(APP_BUNDLE)"

kit-test:
	cd Packages/HerdrKit && swift test

# HerdrSSH Swift Testing on iOS Simulator (Session-driver e2e skips without a live sshd fixture).
ssh-test:
	$(SSH_TEST)

# Compile gate for GooseAgentMobile + HerdrSSH.
mobile-build: gen
	$(MOBILE_BUILD)

test: kit-test

clean:
	rm -rf build build-ios build/HerdrSSHDerivedData GooseHerdr.xcodeproj \
		Packages/HerdrKit/.build Packages/HerdrSSH/.build
