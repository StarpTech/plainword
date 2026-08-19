SHELL := /bin/zsh

DERIVED_DATA_PATH ?= .build/xcode
APP_PATH := $(DERIVED_DATA_PATH)/Build/Products/Debug/Plainword.app
BUNDLE_ID := com.example.Plainword
DEVELOPMENT_TEAM ?= $(shell security find-certificate -c 'Apple Development' -p 2>/dev/null | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null | sed -En 's/.*OU=([A-Z0-9]{10})(,|$$).*/\1/p' | head -1)
SIGNING_ARGS = $(if $(strip $(DEVELOPMENT_TEAM)),DEVELOPMENT_TEAM='$(DEVELOPMENT_TEAM)' CODE_SIGN_IDENTITY='Apple Development' -allowProvisioningUpdates,)

.PHONY: project test-core build run verify reset-accessibility clean-generated

project:
	@command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }
	PLAINWORD_DEVELOPMENT_TEAM='$(DEVELOPMENT_TEAM)' xcodegen generate --spec project.yml

test-core:
	swift test

build: project
	@if [[ -z "$(DEVELOPMENT_TEAM)" ]]; then \
		echo "Note: no Apple Development certificate found; Accessibility approval resets when this debug binary changes."; \
	elif ! security find-identity -v -p codesigning 2>/dev/null | grep -q 'Apple Development:'; then \
		echo "Apple Development certificate found; asking Xcode to install or repair its signing identity."; \
	fi
	xcodebuild \
		-project Plainword.xcodeproj \
		-scheme Plainword \
		-configuration Debug \
		-destination 'generic/platform=macOS' \
		-derivedDataPath '$(DERIVED_DATA_PATH)' \
		$(SIGNING_ARGS) \
		build

run: build
	@osascript -e 'tell application id "$(BUNDLE_ID)" to quit' >/dev/null 2>&1 || true
	@for attempt in {1..20}; do pgrep -x Plainword >/dev/null || break; sleep 0.1; done
	open -n '$(APP_PATH)'

reset-accessibility:
	@osascript -e 'tell application id "$(BUNDLE_ID)" to quit' >/dev/null 2>&1 || true
	tccutil reset Accessibility '$(BUNDLE_ID)'
	@echo "Accessibility approval reset. Run 'make run', then choose Allow Access in Plainword."

verify: test-core build

clean-generated:
	@if [ -d Plainword.xcodeproj ]; then mv Plainword.xcodeproj "Plainword.xcodeproj.backup.$$(date +%Y%m%d%H%M%S)"; fi
