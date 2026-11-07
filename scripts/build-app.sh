#!/bin/sh
# Builds LogoLight.app into ./build using only the Command Line Tools (no Xcode needed).
#
#   scripts/build-app.sh
#
# Environment overrides:
#   VERSION          marketing version (default: 1.0.0)
#   BUILD_NUMBER     build number      (default: number of git commits)
#   BUNDLE_ID        bundle identifier (default: io.github.logolight.LogoLight)
#   SIGN_IDENTITY    codesign identity (default: "-", ad-hoc)
set -eu

cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
BUNDLE_ID="${BUNDLE_ID:-io.github.logolight.LogoLight}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

APP="build/LogoLight.app"

echo "==> Building release binary"
swift build -c release --product LogoLight
BIN="$(swift build -c release --product LogoLight --show-bin-path)/LogoLight"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LogoLight"
sed -e "s/\$(BUNDLE_ID)/$BUNDLE_ID/" \
    -e "s/\$(VERSION)/$VERSION/" \
    -e "s/\$(BUILD_NUMBER)/$BUILD_NUMBER/" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Signing ($SIGN_IDENTITY)"
# Always with the hardened runtime (notarization requires it), so ad-hoc test builds run
# the same way as signed releases. A real identity also gets a secure timestamp.
if [ "$SIGN_IDENTITY" = "-" ]; then TIMESTAMP="--timestamp=none"; else TIMESTAMP="--timestamp"; fi
codesign --force --sign "$SIGN_IDENTITY" --options runtime "$TIMESTAMP" "$APP"
codesign --verify --strict "$APP"

echo "==> Built $APP ($VERSION, build $BUILD_NUMBER)"
