#!/bin/sh
# Publishes the website (site/public) to logolight.app, after checking for what has gone wrong with a
# deploy, or would:
# - a checkout behind origin/main: one put an older style.css live for a few minutes;
# - the app's zip, which isn't in git, so a Mac that didn't make the release has none and the site's
#   download would be a 404; or a zip that isn't the release the page names, or isn't notarized.
#
#   scripts/deploy-site.sh           check, then deploy
#   scripts/deploy-site.sh --check   check only
set -eu

cd "$(dirname "$0")/.."

fail() {
    echo "error: $*" >&2
    exit 1
}

case "${1:-}" in
    "") CHECK_ONLY=0 ;;
    --check) CHECK_ONLY=1 ;;
    *) fail "unknown argument: $1" ;;
esac

echo "==> Checking the checkout"
git fetch --quiet origin
BEHIND="$(git rev-list --count HEAD..origin/main)"
[ "$BEHIND" = 0 ] || fail "this checkout is $BEHIND commits behind origin/main; pull first"
CHANGED="$(git status --porcelain -- site)"
if [ -n "$CHANGED" ]; then
    echo "note: site/ has changes that aren't committed yet:"
    echo "$CHANGED"
fi

echo "==> Checking the download"
ZIP="site/public/LogoLight.zip"
PAGE_VERSION="$(sed -n 's/.*"softwareVersion": "\([^"]*\)".*/\1/p' site/public/index.html)"
[ -n "$PAGE_VERSION" ] || fail "site/public/index.html has no softwareVersion"
grep -q "Current version: $PAGE_VERSION," site/public/llms.txt \
    || fail "site/public/llms.txt doesn't say version $PAGE_VERSION, as index.html does"
if [ ! -f "$ZIP" ]; then
    echo "error: $ZIP is missing, so the site's download would be a 404." >&2
    echo "       It isn't in git. Copy the notarized dist/LogoLight-$PAGE_VERSION.zip there, or fetch a release's:" >&2
    echo "       gh release download v$PAGE_VERSION -R Ark0N/LogoLight -p LogoLight-$PAGE_VERSION.zip -O $ZIP" >&2
    exit 1
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ditto -x -k "$ZIP" "$WORK"
APP="$WORK/LogoLight.app"
[ -d "$APP" ] || fail "$ZIP doesn't hold LogoLight.app"
ZIP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
[ "$ZIP_VERSION" = "$PAGE_VERSION" ] || fail "$ZIP holds LogoLight $ZIP_VERSION, but the page says $PAGE_VERSION"
spctl --assess --type execute "$APP" 2> /dev/null \
    || fail "the app in $ZIP isn't notarized, so Gatekeeper would refuse it (is it a 'make app' build?)"
echo "    LogoLight $ZIP_VERSION (build $ZIP_BUILD), notarized"

if [ "$CHECK_ONLY" = 1 ]; then
    echo "==> The checks passed. Not deploying (--check)."
    exit 0
fi

echo "==> Deploying"
(cd site && npx wrangler deploy)
echo "==> Deployed. If the page changed, tell the search engines (IndexNow):"
echo '    curl "https://api.indexnow.org/indexnow?url=https://logolight.app/&key=5ac2b92d275422183e47b25b5e0e0a4d"'
