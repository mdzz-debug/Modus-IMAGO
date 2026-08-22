#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SIGNING_DIR="$(cd "$PROJECT_DIR/../Signing" && pwd)"
BUNDLE_IDENTIFIER="com.modus.imago"
SIGNING_IDENTITY="${M_IMAGO_SIGNING_IDENTITY:-Modus App Signing - $BUNDLE_IDENTIFIER}"
VERSION="${1:-}"
BUILD_NUMBER="${2:-}"
ARCH="${M_IMAGO_RELEASE_ARCH:-arm64}"

if [[ -z "$VERSION" || -z "$BUILD_NUMBER" ]]; then
  print -u2 "Usage: zsh scripts/build-release.sh <version> <build-number>"
  print -u2 "Example: zsh scripts/build-release.sh 0.1.0 1"
  exit 64
fi
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' ]]; then
  print -u2 "Invalid semantic version: $VERSION"
  exit 64
fi
if [[ ! "$BUILD_NUMBER" =~ '^[1-9][0-9]*$' ]]; then
  print -u2 "Build number must be a positive integer: $BUILD_NUMBER"
  exit 64
fi
if ! security find-identity -v -p codesigning | grep -Fq '"'"$SIGNING_IDENTITY"'"'; then
  print -u2 "Missing code-signing identity: $SIGNING_IDENTITY"
  exit 1
fi

BUILD_ROOT="$PROJECT_DIR/.build/$ARCH-apple-macosx/release"
APP_DIR="$PROJECT_DIR/.build/release/M-Imago.app"
DIST_DIR="$PROJECT_DIR/dist/v$VERSION"
DMG_PATH="$DIST_DIR/M-Imago-v$VERSION-$ARCH.dmg"
ZIP_PATH="$DIST_DIR/M-Imago-v$VERSION-$ARCH.zip"

swift build --package-path "$PROJECT_DIR" -c release --arch "$ARCH"

rm -rf "$PROJECT_DIR/.build/release"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$DIST_DIR"
cp "$BUILD_ROOT/MImago" "$APP_DIR/Contents/MacOS/MImago"
cp -R "$BUILD_ROOT/MImago_MImago.bundle" "$APP_DIR/"
cp -R "$BUILD_ROOT/FormaUI_FormaUI.bundle" "$APP_DIR/"
cp "$PROJECT_DIR/BrandAssets/AppIcon/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/Packaging/Info.plist" "$APP_DIR/Contents/Info.plist"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_DIR/Contents/Info.plist"

codesign \
  --force \
  --deep \
  --sign "$SIGNING_IDENTITY" \
  --identifier "$BUNDLE_IDENTIFIER" \
  --timestamp=none \
  --no-strict \
  "$APP_DIR"
codesign --verify --deep --no-strict --verbose=2 "$APP_DIR"

rm -f "$DMG_PATH" "$ZIP_PATH"
zsh "$SIGNING_DIR/scripts/package-dmg.sh" \
  --app "$APP_DIR" \
  --output "$DMG_PATH" \
  --volume-name "M · Imago $VERSION" \
  --product-name "M · Imago" \
  --volume-icon "$PROJECT_DIR/BrandAssets/AppIcon/AppIcon.icns" \
  --certificate "$SIGNING_DIR/FriendPackage/Modus-Friends-Root-CA.cer" \
  --instructions "$SIGNING_DIR/FriendPackage/安装说明.md"

ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
(
  cd "$DIST_DIR"
  shasum -a 256 "${DMG_PATH:t}" "${ZIP_PATH:t}" > SHA256SUMS.txt
)

print "Release artifacts:"
print "$DMG_PATH"
print "$ZIP_PATH"
print "$DIST_DIR/SHA256SUMS.txt"
print ""
print "Publish them under GitHub Release tag: v$VERSION"
