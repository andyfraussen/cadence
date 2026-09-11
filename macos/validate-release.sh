#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 1 ]]; then
  printf 'Usage: bash macos/validate-release.sh vMAJOR.MINOR.PATCH\n' >&2
  exit 1
fi
tag="$1"
if [[ ! "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  printf 'Release tag must be stable SemVer: vMAJOR.MINOR.PATCH (no leading zeros, prerelease, or build metadata).\n' >&2
  exit 1
fi
version="${tag#v}"
bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' macos/Info.plist)"
package_version="$(/usr/bin/plutil -extract version raw -o - package.json)"
if [[ "$version" != "$bundle_version" || "$version" != "$package_version" ]]; then
  printf 'Release version mismatch: tag=%s, CFBundleShortVersionString=%s, package.json=%s\n' \
    "$version" "$bundle_version" "$package_version" >&2
  exit 1
fi
printf 'Validated stable release %s.\n' "$tag"