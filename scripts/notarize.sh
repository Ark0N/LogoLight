#!/bin/sh
# Notarizes and staples build/LogoLight.app, then zips it into dist/ for distribution.
#
#   NOTARY_PROFILE=logolight scripts/notarize.sh
#
# The app must already be built with a Developer ID identity (SIGN_IDENTITY=... make app).
# Create the keychain profile once with:
#   xcrun notarytool store-credentials logolight --apple-id YOU@EXAMPLE.COM --team-id TEAMID
# (it asks for an app-specific password from appleid.apple.com).
set -eu

cd "$(dirname "$0")/.."

APP="build/LogoLight.app"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile (see the comment at the top)}"

if codesign -dvv "$APP" 2>&1 | grep -q "Signature=adhoc"; then
    echo "error: $APP is ad-hoc signed; build it with SIGN_IDENTITY=\"Developer ID Application: …\" first" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
mkdir -p dist
UPLOAD="dist/LogoLight-$VERSION-upload.zip"
ZIP="dist/LogoLight-$VERSION.zip"

echo "==> Submitting to the notary service"
ditto -c -k --keepParent "$APP" "$UPLOAD"
xcrun notarytool submit "$UPLOAD" --keychain-profile "$NOTARY_PROFILE" --wait
rm -f "$UPLOAD"

echo "==> Stapling"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" "$ZIP"
echo "==> $ZIP is ready"
