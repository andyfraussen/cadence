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
for architecture in "${architectures[@]}"; do
  binary="$PWD/.build/Cadence-$architecture"
  xcrun swiftc macos/main.swift macos/Usage.swift macos/Authentication.swift macos/AppModel.swift macos/Views.swift \
    -o "$binary" -O -target "$architecture-apple-macosx13.0" \
    -module-cache-path "$CACHE" -framework AppKit -framework SwiftUI -framework ServiceManagement -framework Security -lsqlite3
  binaries+=("$binary")
done
if [[ "${#binaries[@]}" == 1 ]]; then
  cp "${binaries[0]}" "$APP/Contents/MacOS/Cadence"
else
  lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/Cadence"
fi
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
printf 'Built %s\n' "$APP"
