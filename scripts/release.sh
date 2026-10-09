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
# Packaging (DMG, Sparkle signature, appcast.xml) is done by scripts/package.sh, which can also be
# run on its own for an app exported from Xcode.
#
# Output: build/release/Postie-<version>.dmg, its .sha256, appcast.xml and the release notes

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
PACKAGES="build/SourcePackages"

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

NOTARY_PROFILE="" OUT="$OUT" "$(dirname "$0")/package.sh" "$VERSION" "$APP"
