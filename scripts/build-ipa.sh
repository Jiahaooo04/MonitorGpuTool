#!/usr/bin/env bash
# Build a robust unsigned IPA package for SideStore / Sideloadly on macOS.
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$DIR/app"

echo "==> Navigating to app directory: $APP_DIR"
cd "$APP_DIR"

echo "==> Fetching Flutter dependencies..."
flutter pub get

echo "==> Ensuring iOS platform files exist..."
flutter create --platforms=ios --org com.runmon .

echo "==> Generating launcher icons..."
dart run flutter_launcher_icons

echo "==> Updating Info.plist safely with PlistBuddy..."
PLIST="ios/Runner/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :NSCameraUsageDescription" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :NSCameraUsageDescription string 'RunMon requires camera access to scan server QR codes for pairing.'" "$PLIST"

echo "==> Setting deployment target to iOS 13.0..."
sed -i '' "s/# platform :ios, '12.0'/platform :ios, '13.0'/g" ios/Podfile || true
sed -i '' "s/platform :ios, '12.0'/platform :ios, '13.0'/g" ios/Podfile || true

echo "==> Installing CocoaPods..."
cd ios
pod install --repo-update
cd ..

echo "==> Building Flutter iOS Archive (Release)..."
flutter build ipa --release --no-codesign

echo "==> Packaging into RunMon.ipa..."
APP_PATH="build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app"
if [ ! -d "$APP_PATH" ]; then
  APP_PATH="build/ios/iphoneos/Runner.app"
fi

rm -rf Payload RunMon.ipa
mkdir -p Payload
cp -r "$APP_PATH" Payload/
zip -r -9 RunMon.ipa Payload/
rm -rf Payload

echo "==> SUCCESS! Clean IPA package generated at: $APP_DIR/RunMon.ipa"
