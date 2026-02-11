#!/bin/bash
# Build unsigned IPA for sideloading (AltStore / Sideloadly / TrollStore)
set -e

DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
APP_DIR=$(find "$DERIVED_DATA" -path "*/FFmpegDemo-*/Build/Products/Debug-iphoneos/FFmpegDemo.app" -type d | head -1)

if [ -z "$APP_DIR" ]; then
    echo "❌ FFmpegDemo.app not found. Build first with:"
    echo "   xcodebuild -project Example/FFmpegDemo.xcodeproj -scheme FFmpegDemo -sdk iphoneos -arch arm64 -configuration Debug build CODE_SIGN_IDENTITY=\"\" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO"
    exit 1
fi

echo "📦 Found app: $APP_DIR"

OUTPUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/build-output"
mkdir -p "$OUTPUT_DIR/Payload"

# Copy .app into Payload/
rm -rf "$OUTPUT_DIR/Payload/FFmpegDemo.app"
cp -R "$APP_DIR" "$OUTPUT_DIR/Payload/"

# Create IPA
cd "$OUTPUT_DIR"
rm -f FFmpegDemo.ipa
zip -r -q FFmpegDemo.ipa Payload/

# Cleanup
rm -rf Payload

echo "✅ IPA created: $OUTPUT_DIR/FFmpegDemo.ipa"
echo ""
echo "📱 Install with one of:"
echo "   • AltStore / AltServer"
echo "   • Sideloadly"
echo "   • TrollStore (if jailbroken/TrollStore installed)"
echo "   • ios-deploy (if you have a dev cert)"
