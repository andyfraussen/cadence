#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
root="$PWD"
mkdir -p "$root/.build"
work="$(mktemp -d "$root/.build/release-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fixture="$work/project"
mkdir -p "$fixture/macos" "$fixture/.build" "$fixture/dist/Cadence.app/Contents/MacOS" "$work/download"
cp macos/package.sh "$fixture/macos/"
cp macos/Info.plist "$fixture/macos/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 1.2.3' "$fixture/macos/Info.plist"
cp "$fixture/macos/Info.plist" "$fixture/dist/Cadence.app/Contents/Info.plist"
printf '# Cadence 1.2.3\n\nTest sharing instructions Cadence-1.2.3-universal.zip.\n' > "$fixture/macos/SHARING.md"
printf '{"version":"1.2.3"}\n' > "$fixture/package.json"
printf 'int main(void) { return 0; }\n' > "$work/main.c"
xcrun clang -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 "$work/main.c" \
  -o "$fixture/dist/Cadence.app/Contents/MacOS/Cadence"
codesign --force --sign - "$fixture/dist/Cadence.app"
bash "$fixture/macos/package.sh"
archive='Cadence-1.2.3-universal.zip'
cp "$fixture/dist/$archive" "$fixture/dist/$archive.sha256" "$work/download/"
rm "$fixture/dist/$archive" "$fixture/dist/$archive.sha256"
(cd "$work/download" && shasum -a 256 -c "$archive.sha256")
if [[ "$(awk '{print $2}' "$work/download/$archive.sha256")" != "$archive" ]]; then
  printf 'FAIL: checksum must reference only the archive basename.\n' >&2
  exit 1
fi
shopt -s nullglob
stages=("$fixture/.build/"package.*)
if [[ ${#stages[@]} != 0 ]]; then
  printf 'FAIL: successful packaging left staging directories.\n' >&2
  exit 1
fi
printf 'PASS: relocated checksum and successful staging cleanup.\n'

rm "$fixture/macos/SHARING.md"
if bash "$fixture/macos/package.sh" > "$work/package-failure.log" 2>&1; then
  printf 'FAIL: packaging succeeded without sharing instructions.\n' >&2
  exit 1
fi
stages=("$fixture/.build/"package.*)
if [[ ${#stages[@]} != 0 ]]; then
  printf 'FAIL: failed packaging left staging directories.\n' >&2
  exit 1
fi
printf 'PASS: failed packaging cleans staging directories.\n'

cp "$root/macos/validate-release.sh" "$fixture/macos/"
printf '# Cadence 1.2.3\n\nTest sharing instructions Cadence-1.2.3-universal.zip.\n' > "$fixture/macos/SHARING.md"
checks=0
expect_tag() {
  local expected="$1" tag="$2" status=0
  bash "$fixture/macos/validate-release.sh" "$tag" > "$work/validation.log" 2>&1 || status=$?
  if [[ "$expected" == pass && "$status" != 0 ]] || [[ "$expected" == fail && "$status" == 0 ]]; then
    printf 'FAIL: expected %s for tag <%s>, got exit %s.\n' "$expected" "$tag" "$status" >&2
    exit 1
  fi
  checks=$((checks + 1))
}

expect_tag pass v1.2.3
for tag in '' 1.2.3 V1.2.3 v1 v1.2 v1.2.3.4 v01.2.3 v1.02.3 v1.2.03 \
  v1.2.3-rc.1 v1.2.3+build.1 v1.2.3- v1.2.3+ v-1.2.3 v1.a.3 \
  'v1.2.3 ' ' v1.2.3' $'v1.2.3\n' refs/tags/v1.2.3 v9.9.9; do
  expect_tag fail "$tag"
done
printf '{"version":"1.2.4"}\n' > "$fixture/package.json"
expect_tag fail v1.2.3
printf '{"version":"1.2.3"}\n' > "$fixture/package.json"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 1.2.4' "$fixture/macos/Info.plist"
expect_tag fail v1.2.3
for version in 0.0.0 10.20.300; do
  printf '{"version":"%s"}\n' "$version" > "$fixture/package.json"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$fixture/macos/Info.plist"
  printf '# Cadence %s\n\nTest sharing instructions Cadence-%s-universal.zip.\n' "$version" "$version" > "$fixture/macos/SHARING.md"
  expect_tag pass "v$version"
done
printf '# Cadence 1.2.3\n\nTest sharing instructions Cadence-1.2.3-universal.zip.\n' > "$fixture/macos/SHARING.md"
printf '{"version":"01.2.3"}\n' > "$fixture/package.json"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 01.2.3' "$fixture/macos/Info.plist"
expect_tag fail v01.2.3
printf '{"version":"1.2.3"}\n' > "$fixture/package.json"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 1.2.3' "$fixture/macos/Info.plist"
printf '# Cadence 9.9.9\n\nStale sharing instructions.\n' > "$fixture/macos/SHARING.md"
expect_tag fail v1.2.3
printf 'PASS: %s release tag checks.\n' "$checks"