#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/arm64-apple-macosx/debug"
APP_DIR="$PROJECT_DIR/.build/M-Imago.app"
BUNDLE_IDENTIFIER="com.modus.imago"
SIGNING_IDENTITY="${M_IMAGO_SIGNING_IDENTITY:-Modus App Signing - $BUNDLE_IDENTIFIER}"

swift build --package-path "$PROJECT_DIR"
if pgrep -x MImago >/dev/null; then
  pkill -x MImago
  for _ in {1..50}; do
    pgrep -x MImago >/dev/null || break
    sleep 0.1
  done
fi
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"
cp "$BUILD_DIR/MImago" "$APP_DIR/Contents/MacOS/MImago"
cp -R "$BUILD_DIR/Sparkle.framework" "$APP_DIR/Contents/Frameworks/"
cp -R "$BUILD_DIR/MImago_MImago.bundle" "$APP_DIR/"
cp -R "$BUILD_DIR/FormaUI_FormaUI.bundle" "$APP_DIR/"
cp "$PROJECT_DIR/BrandAssets/AppIcon/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/Packaging/Info.plist" "$APP_DIR/Contents/Info.plist"

if ! security find-identity -v -p codesigning | grep -Fq '"'"$SIGNING_IDENTITY"'"'; then
  print -u2 "Missing code-signing identity: $SIGNING_IDENTITY"
  print -u2 "Run ../Signing/scripts/setup-modus-signing.sh first."
  exit 1
fi

# Re-sign the completed bundle with the app-specific Modus certificate. The stable
# certificate chain and Bundle ID allow macOS privacy permissions to survive rebuilds.
codesign \
  --force \
  --deep \
  --sign "$SIGNING_IDENTITY" \
  --timestamp=none \
  --no-strict \
  "$APP_DIR"

# SwiftPM resource bundles are intentionally located at the bundle root because
# Bundle.module resolves them there. Verify the complete signature without the
# strict layout check, which rejects that valid SwiftPM resource layout.
codesign --verify --deep --no-strict --verbose=2 "$APP_DIR"

"$APP_DIR/Contents/MacOS/MImago" >/tmp/mimago.log 2>&1 &
disown
