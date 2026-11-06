APP := build/LogoLight.app
INSTALL_DIR ?= /Applications

.PHONY: build test app run install uninstall clean

## build: compile everything (debug)
build:
	swift build

## test: run the test suite
test:
	swift run LogoLightTests

## app: build build/LogoLight.app
app:
	scripts/build-app.sh

## run: build and open the app
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
