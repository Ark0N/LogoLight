#!/bin/sh
# Builds LogoLight.app into ./build. The app itself needs only the Command Line Tools; its Control
# Center control (Controls/) needs Xcode 26 or later, and is left out without it.
#
#   scripts/build-app.sh
#
# Environment overrides:
#   VERSION          marketing version (default: 1.1.0)
#   BUILD_NUMBER     build number      (default: number of git commits)
#   BUNDLE_ID        bundle identifier (default: app.logolight.LogoLight)
#   SIGN_IDENTITY    codesign identity (default: "-", ad-hoc)
set -eu

cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
BUNDLE_ID="${BUNDLE_ID:-app.logolight.LogoLight}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

APP="build/LogoLight.app"
APPEX="$APP/Contents/PlugIns/LogoLightControls.appex"

# Fills in a template's $(BUNDLE_ID), $(VERSION) and $(BUILD_NUMBER).
fill() {
    sed -e "s/\$(BUNDLE_ID)/$BUNDLE_ID/g" \
        -e "s/\$(VERSION)/$VERSION/g" \
        -e "s/\$(BUILD_NUMBER)/$BUILD_NUMBER/g" \
        "$1" > "$2"
    plutil -lint "$2" >/dev/null
}

echo "==> Building release binary"
# SwiftPM's default build system records the deployment target (14.0) as the SDK the app was built
# with, so newer macOS treats it as an old app. Control Center's gallery then showed a blank icon for
# it (Xcode-built apps, which record the real SDK, are fine). So tell the linker the real SDK.
# The 14.0 must match `platforms` in Package.swift and LSMinimumSystemVersion in Resources/Info.plist.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
swift build -c release --product LogoLight \
    -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$SDK_VERSION"
BIN="$(swift build -c release --product LogoLight --show-bin-path)/LogoLight"
vtool -show-build "$BIN" | grep -q "sdk $SDK_VERSION" || { echo "error: $BIN doesn't record SDK $SDK_VERSION" >&2; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LogoLight"
fill Resources/Info.plist "$APP/Contents/Info.plist"
# Drawn by scripts/make-icon.swift. With Xcode's actool, it also goes in an asset catalog
# (CFBundleIconName), which newer parts of macOS, like Control Center's gallery, look for.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if ACTOOL="$(xcrun --find actool 2>/dev/null)"; then
    ASSETS="build/assets/Assets.xcassets"
    rm -rf build/assets
    mkdir -p "$ASSETS/AppIcon.appiconset"
    iconutil -c iconset Resources/AppIcon.icns -o build/assets/AppIcon.iconset
    cp build/assets/AppIcon.iconset/*.png "$ASSETS/AppIcon.appiconset/"
    {
        printf '{ "images": [\n'
        sep=""
        for size in 16 32 128 256 512; do
            for scale in 1 2; do
                [ "$scale" = 1 ] && file="icon_${size}x${size}.png" || file="icon_${size}x${size}@2x.png"
                printf '%s  { "idiom": "mac", "size": "%sx%s", "scale": "%sx", "filename": "%s" }' "$sep" "$size" "$size" "$scale" "$file"
                sep=",
"
            done
        done
        printf '\n], "info": { "version": 1, "author": "xcode" } }\n'
    } > "$ASSETS/AppIcon.appiconset/Contents.json"
    printf '{ "info": { "version": 1, "author": "xcode" } }\n' > "$ASSETS/Contents.json"
    "$ACTOOL" --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 14.0 \
        --app-icon AppIcon --output-partial-info-plist build/assets/partial.plist \
        --output-format human-readable-text --errors "$ASSETS" > build/assets/actool.log 2>&1 \
        || { cat build/assets/actool.log >&2; exit 1; }
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$APP/Contents/Info.plist"
fi

# The Control Center control: a WidgetKit extension, built the way Xcode builds one, without a project.
# The system needs its App Intents metadata, which Xcode's appintentsmetadataprocessor extracts from
# the constant values swiftc writes (the protocol list in Controls/const_extract_protocols.json is
# the one Xcode passes). It's an Apple-silicon-only app (the logo is on Apple silicon MacBooks), so arm64.
PROCESSOR="$(xcrun --find appintentsmetadataprocessor 2>/dev/null || true)"
SDK_MAJOR="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null | cut -d. -f1)"
if [ -n "$PROCESSOR" ] && [ "${SDK_MAJOR:-0}" -ge 26 ]; then
    echo "==> Building the Control Center control"
    OBJ="build/controls"
    TARGET="arm64-apple-macos26.0"
    SDK="$(xcrun --sdk macosx --show-sdk-path)"
    TOOLCHAIN="$(cd "$(dirname "$PROCESSOR")/../.." && pwd)"
    rm -rf "$OBJ"
    mkdir -p "$OBJ" "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
    SOURCES="Controls/BacklightControl.swift Sources/LogoLightCore/ControlLink.swift"
    # shellcheck disable=SC2086 # SOURCES is a list
    xcrun swiftc -module-name LogoLightControls -O -whole-module-optimization -swift-version 6 \
        -sdk "$SDK" -target "$TARGET" -application-extension -parse-as-library \
        -emit-const-values-path "$OBJ/LogoLightControls.swiftconstvalues" \
        -const-gather-protocols-list Controls/const_extract_protocols.json \
        -Xlinker -application_extension -Xlinker -e -Xlinker _NSExtensionMain \
        -o "$APPEX/Contents/MacOS/LogoLightControls" $SOURCES
    fill Controls/Info.plist "$APPEX/Contents/Info.plist"
    printf '%s\n' $SOURCES > "$OBJ/sources.txt"
    echo "$OBJ/LogoLightControls.swiftconstvalues" > "$OBJ/constvalues.txt"
    : > "$OBJ/none.txt"
    "$PROCESSOR" --toolchain-dir "$TOOLCHAIN" --module-name LogoLightControls --sdk-root "$SDK" \
        --xcode-version "$(xcodebuild -version | awk '/Build version/ { print $3 }')" \
        --platform-family macOS --deployment-target 26.0 --target-triple "$TARGET" \
        --bundle-identifier "$BUNDLE_ID.Controls" --output "$APPEX/Contents/Resources" \
        --binary-file "$APPEX/Contents/MacOS/LogoLightControls" --source-file-list "$OBJ/sources.txt" \
        --swift-const-vals-list "$OBJ/constvalues.txt" --metadata-file-list "$OBJ/none.txt" \
        --static-metadata-file-list "$OBJ/none.txt" --compile-time-extraction --deployment-aware-processing \
        --no-app-shortcuts-localization > "$OBJ/metadata.log" 2>&1 \
        || { cat "$OBJ/metadata.log" >&2; exit 1; }
    test -d "$APPEX/Contents/Resources/Metadata.appintents" \
        || { echo "error: no App Intents metadata (see $OBJ/metadata.log)" >&2; exit 1; }
    fill Controls/Controls.entitlements "$OBJ/Controls.entitlements"
elif [ "$SIGN_IDENTITY" != "-" ] && [ "${ALLOW_NO_CONTROLS:-0}" != 1 ]; then
    echo "error: a release would be missing the Control Center control: it needs Xcode 26 or later" >&2
    echo "       (select it with xcode-select, or set ALLOW_NO_CONTROLS=1 to build without it)" >&2
    exit 1
else
    echo "==> Leaving out the Control Center control (it needs Xcode 26 or later)"
fi

echo "==> Signing ($SIGN_IDENTITY)"
# Always with the hardened runtime (notarization requires it), so ad-hoc test builds run
# the same way as signed releases. A real identity also gets a secure timestamp.
# Inside out: the extension, with its sandbox, then the app around it.
if [ "$SIGN_IDENTITY" = "-" ]; then TIMESTAMP="--timestamp=none"; else TIMESTAMP="--timestamp"; fi
if [ -d "$APPEX" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --options runtime "$TIMESTAMP" \
        --entitlements build/controls/Controls.entitlements "$APPEX"
fi
codesign --force --sign "$SIGN_IDENTITY" --options runtime "$TIMESTAMP" "$APP"
codesign --verify --strict --deep "$APP"

echo "==> Built $APP ($VERSION, build $BUILD_NUMBER)"
