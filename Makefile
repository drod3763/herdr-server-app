# Builds "Herdr Server.app": a bundled, resident parent for `herdr server` so macOS can grant
# it Local Network / TCC consent (herdrdev/herdr#808).
#
#   make            build the bundle under build/
#   make sign       ad-hoc sign it (default; set IDENTITY="Developer ID Application: ..." to use a cert)
#   make check      lint the plist, verify the signature, print --version
#   make zip        build/Herdr-Server-<VERSION>.zip + .sha256 (what the release workflow publishes)
#   make smoke      run tests/smoke.sh against the built launcher
#   make install    copy the bundle to /Applications (prefer the Homebrew cask)
#
# The Local Network grant binds to the ad-hoc signature's cdhash, so a granted install must not
# be rebuilt in place; ship one artifact per version through releases instead.

VERSION  ?= $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0)
IDENTITY ?= -
APP_NAME  = Herdr Server
BUILD     = build
APP       = $(BUILD)/$(APP_NAME).app
BIN       = $(APP)/Contents/MacOS/herdr-server-launcher
ZIP       = $(BUILD)/Herdr-Server-$(VERSION).zip
CC       ?= cc
CFLAGS   ?= -O2 -Wall -Wextra -Werror -mmacosx-version-min=13.0
ARCHS    ?= -arch arm64 -arch x86_64

.PHONY: all sign check zip smoke install clean

all: sign

$(BIN): launcher/launcher.c launcher/Info.plist
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	$(CC) $(CFLAGS) $(ARCHS) -DHERDR_SERVER_VERSION='"$(VERSION)"' -o "$(BIN)" launcher/launcher.c
	sed 's/__VERSION__/$(VERSION)/g' launcher/Info.plist > "$(APP)/Contents/Info.plist"
	printf 'APPL????' > "$(APP)/Contents/PkgInfo"

sign: $(BIN)
	codesign --force --sign "$(IDENTITY)" --timestamp=none "$(APP)"

check: sign
	plutil -lint "$(APP)/Contents/Info.plist"
	codesign --verify --strict --verbose=2 "$(APP)"
	codesign --display --verbose=2 "$(APP)" 2>&1 | grep -E '^(Identifier|Signature|TeamIdentifier)'
	"$(BIN)" --version

zip: check
	rm -f "$(ZIP)" "$(ZIP).sha256"
	cd "$(BUILD)" && ditto -c -k --keepParent "$(APP_NAME).app" "$(notdir $(ZIP))"
	cd "$(BUILD)" && shasum -a 256 "$(notdir $(ZIP))" > "$(notdir $(ZIP)).sha256"
	cat "$(ZIP).sha256"

smoke: sign
	tests/smoke.sh "$(BIN)"

install: check
	rm -rf "/Applications/$(APP_NAME).app"
	ditto "$(APP)" "/Applications/$(APP_NAME).app"

clean:
	rm -rf "$(BUILD)"
