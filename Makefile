APP := build/LogoLight.app
INSTALL_DIR ?= /Applications

.PHONY: build test app dist run install uninstall clean

## build: compile everything (debug)
build:
	swift build

## test: run the test suite
test:
	swift run LogoLightTests

## app: build build/LogoLight.app
app:
	scripts/build-app.sh

## dist: build, sign, notarize and zip into dist/ (needs SIGN_IDENTITY and NOTARY_PROFILE)
dist:
	@test -n "$(SIGN_IDENTITY)" || { echo "Set SIGN_IDENTITY to your Developer ID Application identity"; exit 1; }
	scripts/build-app.sh
	scripts/notarize.sh

## run: build and open the app (pkill quits LogoLight cleanly, returning the logo to normal)
run: app
	-pkill -x LogoLight
	open $(APP)

## install: copy the app to /Applications (override with INSTALL_DIR=...)
install: app
	-pkill -x LogoLight
	rm -rf "$(INSTALL_DIR)/LogoLight.app"
	cp -R $(APP) "$(INSTALL_DIR)/"
	open "$(INSTALL_DIR)/LogoLight.app"

## uninstall: remove the app (turn off "Toggle Without Password" first to remove its sudoers rule)
uninstall:
	-pkill -x LogoLight
	rm -rf "$(INSTALL_DIR)/LogoLight.app"

clean:
	rm -rf .build build
