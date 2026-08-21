SHELL := /bin/zsh

DERIVED_DATA_PATH ?= .build/xcode
APP_PATH := $(DERIVED_DATA_PATH)/Build/Products/Debug/Plainword.app
BUNDLE_ID := com.example.Plainword
LOGIN_KEYCHAIN := $(HOME)/Library/Keychains/login.keychain-db

# The settings sidebar shows CFBundleShortVersionString, which project.yml pins to a
# placeholder. The release workflow overrides it from the pushed tag, so only local
# builds are left claiming to be 1.0.0 forever. `git describe` answers with the latest
# published release, plus how far this working tree has drifted past it.
GIT_VERSION := $(shell git describe --tags --dirty=+dirty --match 'v[0-9]*' 2>/dev/null)
MARKETING_VERSION ?= $(patsubst v%,%,$(GIT_VERSION))
ifneq ($(strip $(MARKETING_VERSION)),)
VERSION_ARGS = MARKETING_VERSION='$(MARKETING_VERSION)'
endif

# macOS records Accessibility approval and Keychain access against the app's code
# signature, not its path or bundle id. An ad-hoc signature is a hash of the binary,
# so it changes on every build and both approvals are silently revoked each time.
# Any stable identity fixes that; an Apple Development certificate is preferred, and
# a local self-signed one works just as well for a debug build.
LOCAL_SIGNING_IDENTITY ?= Plainword Local Dev
DEVELOPMENT_TEAM ?= $(shell security find-certificate -c 'Apple Development' -p 2>/dev/null | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null | sed -En 's/.*OU=([A-Z0-9]{10})(,|$$).*/\1/p' | head -1)
HAS_LOCAL_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -Fc '$(LOCAL_SIGNING_IDENTITY)')

ifneq ($(strip $(DEVELOPMENT_TEAM)),)
SIGNING_ARGS = DEVELOPMENT_TEAM='$(DEVELOPMENT_TEAM)' CODE_SIGN_IDENTITY='Apple Development' -allowProvisioningUpdates
SIGNING_DESCRIPTION := Apple Development ($(DEVELOPMENT_TEAM))
else ifneq ($(HAS_LOCAL_IDENTITY),0)
# Hardened runtime turns on library validation, which will only load a library whose
# Team ID matches the main executable's. A self-signed certificate has no Team ID, so
# the app dies at launch unable to load its own PlainwordCore dylib. Xcode disables
# hardened runtime for ad-hoc builds for exactly this reason; the Apple Development
# branch above keeps it, because there both binaries carry the same real Team ID.
# It is only needed for notarised distribution, which this debug build is not.
SIGNING_ARGS = CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY='$(LOCAL_SIGNING_IDENTITY)' DEVELOPMENT_TEAM='' PROVISIONING_PROFILE_SPECIFIER='' ENABLE_HARDENED_RUNTIME=NO
SIGNING_DESCRIPTION := $(LOCAL_SIGNING_IDENTITY) (self-signed)
else
SIGNING_ARGS =
SIGNING_DESCRIPTION := ad-hoc
endif

.PHONY: project test-core build run verify version signing-identity signing-status \
	reset-accessibility clean-generated

project:
	@command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }
	PLAINWORD_DEVELOPMENT_TEAM='$(DEVELOPMENT_TEAM)' xcodegen generate --spec project.yml

test-core:
	swift test

build: project
	@if [[ '$(SIGNING_DESCRIPTION)' == 'ad-hoc' ]]; then \
		echo ""; \
		echo "warning: signing ad-hoc — no stable code signing identity was found."; \
		echo "         The signature changes on every build, so macOS revokes Accessibility"; \
		echo "         approval and Keychain access each time you rebuild. Symptoms: the"; \
		echo "         keychain password prompt on every launch, and Plainword still not"; \
		echo "         working after you switch Accessibility on."; \
		echo "         Fix once with:  make signing-identity"; \
		echo "         Or add an Apple Development certificate in Xcode > Settings > Accounts."; \
		echo ""; \
	else \
		echo "Signing with: $(SIGNING_DESCRIPTION)"; \
	fi
	xcodebuild \
		-project Plainword.xcodeproj \
		-scheme Plainword \
		-configuration Debug \
		-destination 'generic/platform=macOS' \
		-derivedDataPath '$(DERIVED_DATA_PATH)' \
		$(SIGNING_ARGS) \
		$(VERSION_ARGS) \
		build

## Reports the version this build stamps into the app, as shown in the settings sidebar.
version:
	@if [[ -n '$(strip $(MARKETING_VERSION))' ]]; then \
		echo 'v$(MARKETING_VERSION)'; \
	else \
		echo "No release tag found — the build falls back to project.yml's MARKETING_VERSION."; \
	fi

run: build
	@osascript -e 'tell application id "$(BUNDLE_ID)" to quit' >/dev/null 2>&1 || true
	@for attempt in {1..20}; do pgrep -x Plainword >/dev/null || break; sleep 0.1; done
	open -n '$(APP_PATH)'

## Reports which identity a build would use, and what the last build actually used.
signing-status:
	@echo "Would sign with: $(SIGNING_DESCRIPTION)"
	@if [[ -d '$(APP_PATH)' ]]; then \
		echo "Last build:"; \
		codesign -dv --verbose=2 '$(APP_PATH)' 2>&1 | grep -E '^(Identifier|Signature|TeamIdentifier|Authority)' | sed 's/^/  /'; \
		echo "  designated requirement:"; \
		codesign -d -r- '$(APP_PATH)' 2>/dev/null | sed -n 's/^# *designated =>/    designated =>/p'; \
	else \
		echo "No build at $(APP_PATH) yet."; \
	fi

## Creates a self-signed code signing identity, once, so every later build carries
## the same designated requirement.
##
## Prefer an Apple Development certificate if you have an Apple ID in Xcode — this
## exists for machines that do not. macOS prompts for your login password while the
## key is trusted; nothing here can or should answer those prompts for you.
##
## The PKCS#12 flags are not decoration. macOS's importer rejects the bundle that
## LibreSSL writes by default ("MAC verification failed ... wrong password?"), so the
## key and certificate are wrapped with the legacy SHA-1/3DES algorithms it accepts,
## under a throwaway password — an empty one is refused as well. The certificate also
## has to be trusted for code signing before `codesign` will use it: imported but
## untrusted, it is not listed as a valid identity at all.
signing-identity:
	@set -e; \
	if security find-identity -v -p codesigning 2>/dev/null | grep -Fq '$(LOCAL_SIGNING_IDENTITY)'; then \
		echo "'$(LOCAL_SIGNING_IDENTITY)' already exists — nothing to do."; \
		exit 0; \
	fi; \
	echo "Creating the self-signed code signing identity '$(LOCAL_SIGNING_IDENTITY)'."; \
	echo "macOS will ask you to authorise this: once to trust the certificate for code"; \
	echo "signing, and once to let codesign use its key without asking again."; \
	work=$$(mktemp -d); \
	trap 'rm -rf "$$work"' EXIT; \
	pass=$$(openssl rand -hex 16); \
	openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
		-keyout "$$work/key.pem" -out "$$work/cert.pem" \
		-subj '/CN=$(LOCAL_SIGNING_IDENTITY)' \
		-addext 'basicConstraints=critical,CA:false' \
		-addext 'keyUsage=critical,digitalSignature' \
		-addext 'extendedKeyUsage=critical,codeSigning' >/dev/null 2>&1; \
	openssl pkcs12 -export -inkey "$$work/key.pem" -in "$$work/cert.pem" \
		-name '$(LOCAL_SIGNING_IDENTITY)' -out "$$work/identity.p12" \
		-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
		-passout "pass:$$pass" >/dev/null; \
	security import "$$work/identity.p12" -k '$(LOGIN_KEYCHAIN)' -P "$$pass" \
		-T /usr/bin/codesign -T /usr/bin/security >/dev/null; \
	security add-trusted-cert -r trustRoot -p codeSign -k '$(LOGIN_KEYCHAIN)' "$$work/cert.pem"; \
	security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
		-l '$(LOCAL_SIGNING_IDENTITY)' '$(LOGIN_KEYCHAIN)' >/dev/null; \
	if security find-identity -v -p codesigning 2>/dev/null | grep -Fq '$(LOCAL_SIGNING_IDENTITY)'; then \
		echo ""; \
		echo "'$(LOCAL_SIGNING_IDENTITY)' is ready. Now run:"; \
		echo "  make reset-accessibility   # clear the approval recorded against the old signature"; \
		echo "  make run                   # rebuild, then choose Allow Access once more"; \
		echo "Approvals survive every rebuild from here on."; \
	else \
		echo ""; \
		echo "error: the certificate exists but is not valid for code signing, so builds"; \
		echo "       would still fall back to ad-hoc. The trust step was most likely"; \
		echo "       cancelled. Open Keychain Access, find '$(LOCAL_SIGNING_IDENTITY)' under"; \
		echo "       login > My Certificates, and set Trust > Code Signing to Always Trust."; \
		exit 1; \
	fi

reset-accessibility:
	@osascript -e 'tell application id "$(BUNDLE_ID)" to quit' >/dev/null 2>&1 || true
	tccutil reset Accessibility '$(BUNDLE_ID)'
	@echo "Accessibility approval reset. Run 'make run', then choose Allow Access in Plainword."

verify: test-core build

clean-generated:
	@if [ -d Plainword.xcodeproj ]; then mv Plainword.xcodeproj "Plainword.xcodeproj.backup.$$(date +%Y%m%d%H%M%S)"; fi
