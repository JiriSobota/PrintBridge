#!/bin/zsh
# Builds PrintBridge.app as a universal binary (Apple Silicon + Intel).
# Only the Xcode Command Line Tools are required – no Xcode project.
#
#   ./build.sh            → build/PrintBridge.app
#   ./build.sh --zip      → also build/PrintBridge-<version>.zip for GitHub Releases
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
ARCHS=(arm64 x86_64)
SLICES="build/slices"
mkdir -p "$SLICES"

# Self-tests of the protocol layer (run natively).
swift build -c release --product BrotherKitSelfTest
"$(swift build -c release --show-bin-path)/BrotherKitSelfTest" > /dev/null && echo "Protocol tests: OK"

# Main app – one slice per architecture (SwiftPM writes both into the same folder, so copy each out).
for arch in $ARCHS; do
  swift build -c release --product PrintBridge --triple "$arch-apple-macosx14.0"
  cp "$(swift build -c release --triple "$arch-apple-macosx14.0" --show-bin-path)/PrintBridge" "$SLICES/PrintBridge-$arch"
done

# Share extension (.appex) – compiled directly with swiftc.
for arch in $ARCHS; do
  swiftc -O -module-name PrintBridgeShare -target "$arch-apple-macos14.0" \
    -framework Cocoa -framework UniformTypeIdentifiers \
    -Xlinker -e -Xlinker _NSExtensionMain \
    ShareExtension/ShareViewController.swift -o "$SLICES/PrintBridgeShare-$arch"
done

APP="build/PrintBridge.app"
APPEX="$APP/Contents/PlugIns/PrintBridgeShare.appex"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS"
lipo -create "$SLICES"/PrintBridge-* -output "$APP/Contents/MacOS/PrintBridge"
lipo -create "$SLICES"/PrintBridgeShare-* -output "$APPEX/Contents/MacOS/PrintBridgeShare"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp ShareExtension/Info.plist "$APPEX/Contents/Info.plist"
for lproj in Resources/Localization/*.lproj; do
  cp -R "$lproj" "$APP/Contents/Resources/"
done

if [[ ! -f build/AppIcon.icns ]]; then
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET"
  swift scripts/make_icon.swift "$ICONSET"
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
  rm -rf "$ICONSET"
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature (the extension must be sandboxed and is signed first).
codesign --force --sign - --entitlements ShareExtension/Share.entitlements "$APPEX"
codesign --force --sign - "$APP"

# Register with Launch Services (Open With, Services, Share).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true
pluginkit -a "$APPEX" 2>/dev/null || true

lipo -info "$APP/Contents/MacOS/PrintBridge"
echo "Built: $PWD/$APP"

if [[ "${1:-}" == "--zip" ]]; then
  ZIP="build/PrintBridge-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  shasum -a 256 "$ZIP"
  echo "Release archive: $PWD/$ZIP"
fi
