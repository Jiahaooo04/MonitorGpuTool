#!/usr/bin/env bash
# Build an unsigned IPA package for SideStore / AltStore sideloading on macOS.
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$DIR/app"

echo "==> Navigating to app directory: $APP_DIR"
cd "$APP_DIR"

echo "==> Fetching Flutter dependencies..."
flutter pub get

echo "==> Ensuring iOS platform files exist..."
flutter create --platforms=ios .

echo "==> Generating launcher icons..."
dart run flutter_launcher_icons

PLIST_PATH="ios/Runner/Info.plist"
if ! grep -q "NSCameraUsageDescription" "$PLIST_PATH"; then
  echo "==> Injecting NSCameraUsageDescription into Info.plist..."
  sed -i '' '/<dict>/a\
  <key>NSCameraUsageDescription</key>\
  <string>RunMon requires camera access to scan server QR codes for pairing.</string>
  ' "$PLIST_PATH"
fi

echo "==> Building iOS Release without codesign..."
flutter build ios --release --no-codesign

echo "==> Packaging into RunMon.ipa for SideStore..."
rm -rf Payload RunMon.ipa
mkdir -p Payload
cp -r build/ios/iphoneos/Runner.app Payload/
zip -r RunMon.ipa Payload/
rm -rf Payload

echo "==> SUCCESS! IPA package generated at: $APP_DIR/RunMon.ipa"
