#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/dist/Cadence.app"
codesign --verify --deep --strict "$APP"
architectures="$(lipo -archs "$APP/Contents/MacOS/Cadence")"
if [[ "$architectures" != *arm64* || "$architectures" != *x86_64* ]]; then
  printf 'Run npm run build:mac:universal before packaging.\n' >&2
  exit 1
fi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
mkdir -p "$PWD/.build"
stage="$(mktemp -d "$PWD/.build/package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/Cadence"
ditto "$APP" "$stage/Cadence/Cadence.app"
cp macos/SHARING.md "$stage/Cadence/READ ME.md"
archive="$PWD/dist/Cadence-$version-universal.zip"
ditto -c -k --sequesterRsrc --keepParent "$stage/Cadence" "$archive"
(cd "$(dirname "$archive")" && shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256")
printf 'Packaged %s\n' "$archive"
