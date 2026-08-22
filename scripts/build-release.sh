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
SPARKLE_ACCOUNT="${M_IMAGO_SPARKLE_ACCOUNT:-com.modus.imago}"
SPARKLE_TOOLS_DIR="$PROJECT_DIR/ThirdParty/Sparkle/bin"
RELEASE_NOTES_PATH="$PROJECT_DIR/updates/release-notes.md"

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
if [[ ! -f "$RELEASE_NOTES_PATH" ]]; then
  print -u2 "Missing Sparkle release notes: $RELEASE_NOTES_PATH"
  exit 1
fi

BUILD_ROOT="$PROJECT_DIR/.build/$ARCH-apple-macosx/release"
APP_DIR="$PROJECT_DIR/.build/release/M-Imago.app"
DIST_DIR="$PROJECT_DIR/dist/v$VERSION"
DMG_PATH="$DIST_DIR/M-Imago-v$VERSION-$ARCH.dmg"
ZIP_PATH="$DIST_DIR/M-Imago-v$VERSION-$ARCH.zip"
APPCAST_PATH="$DIST_DIR/appcast.xml"

swift build --package-path "$PROJECT_DIR" -c release --arch "$ARCH"

rm -rf "$PROJECT_DIR/.build/release"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks" "$DIST_DIR"
cp "$BUILD_ROOT/MImago" "$APP_DIR/Contents/MacOS/MImago"
cp -R "$BUILD_ROOT/Sparkle.framework" "$APP_DIR/Contents/Frameworks/"
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

APPCAST_WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$APPCAST_WORK_DIR"' EXIT
cp "$ZIP_PATH" "$APPCAST_WORK_DIR/"
cp "$RELEASE_NOTES_PATH" "$APPCAST_WORK_DIR/${ZIP_PATH:t:r}.md"
"$SPARKLE_TOOLS_DIR/generate_appcast" \
  --account "$SPARKLE_ACCOUNT" \
  --download-url-prefix "https://github.com/mdzz-debug/Modus-IMAGO/releases/download/v$VERSION/" \
  --link "https://github.com/mdzz-debug/Modus-IMAGO/releases/tag/v$VERSION" \
  --embed-release-notes \
  --maximum-versions 5 \
  --maximum-deltas 0 \
  -o "$APPCAST_PATH" \
  "$APPCAST_WORK_DIR"
cp "$APPCAST_PATH" "$PROJECT_DIR/updates/appcast.xml"

(
  cd "$DIST_DIR"
  shasum -a 256 "${DMG_PATH:t}" "${ZIP_PATH:t}" "${APPCAST_PATH:t}" > SHA256SUMS.txt
)

print "Release artifacts:"
print "$DMG_PATH"
print "$ZIP_PATH"
print "$APPCAST_PATH"
print "$DIST_DIR/SHA256SUMS.txt"
print ""
print "Commit and push updates/appcast.xml before publishing the Release."
print "Publish the DMG, ZIP, appcast.xml, and SHA256SUMS.txt under GitHub Release tag: v$VERSION"
