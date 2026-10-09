#!/bin/bash
#
# Builds, signs, notarizes and packages Postie as a DMG for a GitHub release.
#
# Usage: scripts/release.sh <version>      e.g. scripts/release.sh 0.2.0
#
# Environment (same names the fastlane setup uses):
#   APP_STORE_CONNECT_API_KEY_ID      App Store Connect API key ID
#   APP_STORE_CONNECT_API_ISSUER_ID   App Store Connect issuer ID
#   APP_STORE_CONNECT_API_KEY_PATH    path to the AuthKey_XXXX.p8 file
# Optional:
#   BUILD_NUMBER                      defaults to the number of commits
#
# The DMG is also signed for Sparkle with the EdDSA key in the login Keychain
# (created once with Sparkle's generate_keys) and appcast.xml is generated next to it.
#
# Output: build/release/Postie-<version>.dmg, its .sha256 and appcast.xml

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
VERSION="${VERSION#v}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version>" >&2
  exit 1
fi

for var in APP_STORE_CONNECT_API_KEY_ID APP_STORE_CONNECT_API_ISSUER_ID APP_STORE_CONNECT_API_KEY_PATH; do
  if [[ -z "${!var:-}" ]]; then
    echo "Missing environment variable $var" >&2
    exit 1
  fi
done
if [[ ! -f "$APP_STORE_CONNECT_API_KEY_PATH" ]]; then
  echo "API key not found at $APP_STORE_CONNECT_API_KEY_PATH" >&2
  exit 1
fi

BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
OUT="build/release"
ARCHIVE="$OUT/Postie.xcarchive"
EXPORT="$OUT/export"
APP="$EXPORT/Postie.app"
DMG="$OUT/Postie-$VERSION.dmg"
PACKAGES="build/SourcePackages"
SPARKLE_BIN="$PACKAGES/artifacts/sparkle/Sparkle/bin"
REPO="igorkulman/Postie"

AUTH=(
  -allowProvisioningUpdates
  -authenticationKeyPath "$APP_STORE_CONNECT_API_KEY_PATH"
  -authenticationKeyID "$APP_STORE_CONNECT_API_KEY_ID"
  -authenticationKeyIssuerID "$APP_STORE_CONNECT_API_ISSUER_ID"
)
NOTARY=(
  --key "$APP_STORE_CONNECT_API_KEY_PATH"
  --key-id "$APP_STORE_CONNECT_API_KEY_ID"
  --issuer "$APP_STORE_CONNECT_API_ISSUER_ID"
)

rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> Archiving Postie $VERSION ($BUILD_NUMBER)"
xcodebuild archive \
  -project Postie.xcodeproj \
  -scheme Postie \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  -clonedSourcePackagesDirPath "$PACKAGES" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  "${AUTH[@]}" \
  | tail -n 5

echo "==> Exporting with Developer ID"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist scripts/ExportOptions.plist \
  "${AUTH[@]}" \
  | tail -n 5

codesign --verify --deep --strict --verbose=2 "$APP"
IDENTITY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application:.*\)$/\1/p' | head -n 1)"
if [[ -z "$IDENTITY" ]]; then
  echo "The exported app is not signed with a Developer ID Application certificate" >&2
  exit 1
fi
echo "Signed as: $IDENTITY"

echo "==> Notarizing the app"
ditto -c -k --keepParent "$APP" "$OUT/Postie.zip"
xcrun notarytool submit "$OUT/Postie.zip" "${NOTARY[@]}" --wait
xcrun stapler staple "$APP"
rm "$OUT/Postie.zip"

echo "==> Creating the DMG"
STAGING="$OUT/dmg"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Postie" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

if security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
  codesign --sign "$IDENTITY" --timestamp "$DMG"
else
  echo "Warning: '$IDENTITY' is not in the local keychain, so the DMG itself is not signed" >&2
fi

echo "==> Notarizing the DMG"
xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait
xcrun stapler staple "$DMG"

echo "==> Verifying"
xcrun stapler validate "$DMG"
spctl --assess --type execute --verbose=2 "$APP"

echo "==> Generating the Sparkle appcast"
if [[ ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
  echo "Sparkle tools not found at $SPARKLE_BIN" >&2
  exit 1
fi
# generate_appcast works on a folder of archives; release notes are picked up from a .md next to the DMG
FEED="$OUT/appcast"
mkdir -p "$FEED"
cp "$DMG" "$FEED/"
awk -v v="$VERSION" '
  /^## \[/ { printing = index($0, "## [" v "]") == 1; next }
  printing { print }
' CHANGELOG.md > "$FEED/Postie-$VERSION.md"
if [[ ! -s "$FEED/Postie-$VERSION.md" ]]; then
  echo "Warning: no CHANGELOG.md section for $VERSION, the update dialog will have no release notes" >&2
  rm "$FEED/Postie-$VERSION.md"
fi
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --embed-release-notes \
  "$FEED"
cp "$FEED/appcast.xml" "$OUT/appcast.xml"
rm -rf "$FEED"

(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

echo
echo "Done: $DMG"
cat "$DMG.sha256"

echo
echo "Publish with:"
echo "  gh release create v$VERSION $DMG $OUT/appcast.xml --title v$VERSION"
echo "The appcast must be attached to every release: Postie looks it up under releases/latest."
