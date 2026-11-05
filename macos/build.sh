#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/dist/Cadence.app"
CACHE="$PWD/.build/swift-module-cache"
ICONSET="$PWD/.build/AppIcon.iconset"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$CACHE" "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" macos/Assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" macos/Assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp macos/Assets/AppIcon.png "$APP/Contents/Resources/AppIcon.png"
cp macos/Info.plist "$APP/Contents/Info.plist"
architectures=("$(uname -m)")
if [[ "${1:-}" == "--universal" ]]; then architectures=(arm64 x86_64); fi
binaries=()
widget_binaries=()
for architecture in "${architectures[@]}"; do
  binary="$PWD/.build/Cadence-$architecture"
  xcrun swiftc macos/main.swift macos/Usage.swift macos/KeychainReader.swift macos/Authentication.swift macos/CodexUsage.swift macos/ClaudeUsage.swift macos/AppModel.swift macos/Views.swift macos/WidgetSnapshot.swift macos/WidgetStore.swift macos/CodeyFrames.swift \
    -o "$binary" -O -warn-concurrency -target "$architecture-apple-macosx13.0" \
    -module-cache-path "$CACHE" -framework AppKit -framework SwiftUI -framework WidgetKit -framework ServiceManagement -framework Security -framework LocalAuthentication -framework Network -framework ImageIO -framework CoreGraphics -lsqlite3
  binaries+=("$binary")
  widget="$PWD/.build/CadenceWidget-$architecture"
  xcrun swiftc macos/WidgetSnapshot.swift macos/WidgetStore.swift macos/widget/CadenceWidget.swift \
    -module-name CadenceWidget -parse-as-library \
    -o "$widget" -O -warn-concurrency -target "$architecture-apple-macosx13.0" \
    -module-cache-path "$CACHE" -framework AppKit -framework SwiftUI -framework WidgetKit
  widget_binaries+=("$widget")
done
if [[ "${#binaries[@]}" == 1 ]]; then
  cp "${binaries[0]}" "$APP/Contents/MacOS/Cadence"
else
  lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/Cadence"
fi
WIDGET="$APP/Contents/PlugIns/CadenceWidget.appex"
mkdir -p "$WIDGET/Contents/MacOS"
if [[ "${#widget_binaries[@]}" == 1 ]]; then
  cp "${widget_binaries[0]}" "$WIDGET/Contents/MacOS/CadenceWidget"
else
  lipo -create "${widget_binaries[@]}" -output "$WIDGET/Contents/MacOS/CadenceWidget"
fi
cp macos/widget/Info.plist "$WIDGET/Contents/Info.plist"
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --entitlements macos/widget/Widget.entitlements --sign "$SIGNING_IDENTITY" "$WIDGET"
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
else
  codesign --force --entitlements macos/widget/Widget.entitlements --sign - "$WIDGET"
  codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
printf 'Built %s\n' "$APP"
