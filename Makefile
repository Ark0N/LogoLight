APP := build/LogoLight.app
INSTALL_DIR ?= /Applications

# Quits a running LogoLight (yours only) and waits up to 2 s for it to exit. It quits cleanly, returning
# the logo to normal first, and `open` would otherwise find the old one still running.
QUIT_APP = pkill -x -U "$$(id -u)" LogoLight; for i in $$(seq 20); do pgrep -x -U "$$(id -u)" LogoLight > /dev/null || break; sleep 0.1; done; true

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

## run: build and open the app
run: app
	$(QUIT_APP)
	open $(APP)

## install: copy the app to /Applications (override with INSTALL_DIR=...)
install: app
	$(QUIT_APP)
	rm -rf "$(INSTALL_DIR)/LogoLight.app"
	cp -R $(APP) "$(INSTALL_DIR)/"
	open "$(INSTALL_DIR)/LogoLight.app"

## uninstall: remove the app (uncheck "Disable Password" first to remove its sudoers rule)
uninstall:
	$(QUIT_APP)
	rm -rf "$(INSTALL_DIR)/LogoLight.app"

clean:
	rm -rf .build build
