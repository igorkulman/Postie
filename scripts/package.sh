#!/bin/bash
#
# Turns an already exported, notarized and stapled Postie.app into a release:
# a signed and notarized DMG plus a Sparkle appcast.xml for GitHub releases.
# release.sh calls this after archiving, and it can be used on its own with an app
# exported from the Xcode Organizer (Distribute App > Direct Distribution).
#
# Usage: scripts/package.sh <version> <path to Postie.app>
#        e.g. scripts/package.sh 0.2.0 ~/Desktop/Postie.app
#
# Notarizing the DMG needs one of (otherwise this step is skipped with a warning):
#   NOTARY_PROFILE                    a notarytool keychain profile name, or
#   APP_STORE_CONNECT_API_KEY_ID, APP_STORE_CONNECT_API_ISSUER_ID,
#   APP_STORE_CONNECT_API_KEY_PATH    an App Store Connect API key
# Optional:
#   OUT                               output folder, defaults to build/release
#
# The DMG is signed for Sparkle with the EdDSA key in the login Keychain (created once with
# Sparkle's generate_keys).
#
# Output: $OUT/Postie-<version>.dmg, its .sha256, appcast.xml and Postie-<version>.md (release notes)

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
VERSION="${VERSION#v}"
APP="${2:-}"
if [[ -z "$VERSION" || -z "$APP" ]]; then
  echo "Usage: $0 <version> <path to Postie.app>" >&2
  exit 1
fi
APP="${APP%/}"
if [[ ! -d "$APP" ]]; then
  echo "App not found at $APP" >&2
  exit 1
fi

OUT="${OUT:-build/release}"
DMG="$OUT/Postie-$VERSION.dmg"
NOTES="$OUT/Postie-$VERSION.md"
PACKAGES="build/SourcePackages"
SPARKLE_BIN="$PACKAGES/artifacts/sparkle/Sparkle/bin"
REPO="igorkulman/Postie"
mkdir -p "$OUT"

NOTARY=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${APP_STORE_CONNECT_API_KEY_ID:-}" && -n "${APP_STORE_CONNECT_API_ISSUER_ID:-}" && -f "${APP_STORE_CONNECT_API_KEY_PATH:-}" ]]; then
  NOTARY=(--key "$APP_STORE_CONNECT_API_KEY_PATH" --key-id "$APP_STORE_CONNECT_API_KEY_ID" --issuer "$APP_STORE_CONNECT_API_ISSUER_ID")
fi

echo "==> Checking $APP"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [[ "$APP_VERSION" != "$VERSION" ]]; then
  echo "The app is version $APP_VERSION, not $VERSION" >&2
  exit 1
fi
if ! /usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$APP/Contents/Info.plist" >/dev/null 2>&1; then
  echo "The app has no SUPublicEDKey, so it could not verify updates" >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "$APP"
IDENTITY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application:.*\)$/\1/p' | head -n 1)"
if [[ -z "$IDENTITY" ]]; then
  echo "The app is not signed with a Developer ID Application certificate" >&2
  exit 1
fi
echo "Signed as: $IDENTITY"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

echo "==> Creating the DMG"
STAGING="$OUT/dmg"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/Postie.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Postie" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

if security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
  codesign --sign "$IDENTITY" --timestamp "$DMG"
else
  echo "Warning: '$IDENTITY' is not in the local keychain, so the DMG itself is not signed" >&2
fi

if [[ ${#NOTARY[@]} -gt 0 ]]; then
  echo "==> Notarizing the DMG"
  xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
else
  echo "Warning: no notarization credentials (NOTARY_PROFILE or the App Store Connect API key variables), the DMG itself is not notarized" >&2
fi

(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

echo "==> Generating the Sparkle appcast"
if [[ ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
  xcodebuild -resolvePackageDependencies -project Postie.xcodeproj -scheme Postie \
    -clonedSourcePackagesDirPath "$PACKAGES" >/dev/null
fi
# generate_appcast works on a folder of archives; release notes are picked up from a .md next to the DMG
awk -v v="$VERSION" '
  /^## \[/ { printing = index($0, "## [" v "]") == 1; next }
  printing { print }
' CHANGELOG.md > "$NOTES"
if [[ ! -s "$NOTES" ]]; then
  echo "Warning: no CHANGELOG.md section for $VERSION, the update dialog will have no release notes" >&2
  rm "$NOTES"
fi
FEED="$OUT/appcast"
rm -rf "$FEED"
mkdir -p "$FEED"
cp "$DMG" "$FEED/"
[[ -f "$NOTES" ]] && cp "$NOTES" "$FEED/"
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --embed-release-notes \
  "$FEED"
cp "$FEED/appcast.xml" "$OUT/appcast.xml"
rm -rf "$FEED"
grep -q 'sparkle:edSignature' "$OUT/appcast.xml" || { echo "The appcast is missing the EdDSA signature" >&2; exit 1; }

echo
echo "Done: $DMG"
cat "$DMG.sha256"
echo
echo "Publish with:"
echo "  gh release create v$VERSION $DMG $OUT/appcast.xml --title v$VERSION --notes-file $NOTES"
echo "The appcast must be attached to every release: Postie looks it up under releases/latest."
