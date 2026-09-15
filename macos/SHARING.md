# Cadence 1.1.0

A small, independent macOS menu bar app for Cursor Models, Other Models, and Grok Bot usage. Requires macOS 13 or later. The universal build includes Apple Silicon and Intel binaries.

## Start

1. Unzip the download and drag Cadence.app into Applications.
2. Open the app. Click its Cadence C icon or usage percentages in the menu bar.
3. Sign in to the Cursor desktop app. Cadence picks up that session automatically.
4. Open Settings to choose logo only, limits only, or both; show/hide Grok Bot; use weekday pacing; and enable Launch at Login.

No Node, npm, Python, web server, or project folder is needed to run the built app.

## Automatic Session Sync

Cadence automatically detects and reads your active Cursor desktop app session from local storage (`state.vscdb`) each time usage refreshes. No manual token entry, copying/pasting, or configuration is required. Ensure you are signed in to the Cursor desktop app on your Mac.

## Read the numbers

- **Left until reset:** total unused percentage of the included allowance.
- **Safe per day:** that remaining percentage divided by remaining days, as a percentage of the full quota.
- **Example:** 80% left over 20 days means an average of 4% of the full quota per day from now until reset.
- It is a pacing estimate, not a separate daily cap or a measurement of today's spending. It does not include or limit on-demand charges.
- Both pacing modes count local calendar dates overlapping the interval from now until reset, excluding the reset endpoint. Partial dates count once; daylight-saving transitions do not add or remove dates. Weekday mode assumes no weekend usage and excludes weekends but not holidays.
- C and O have monthly resets; G has its own weekly reset. Each card displays the server-provided reset in your local time zone.
- Failed refreshes retain the last successful balance and mark it stale; stale data has no daily recommendation. An unavailable pool is shown as unavailable, never as 100% remaining.

## Privacy and compatibility

The app reads Cursor's local database in read-only mode and authenticates requests to Cursor's HTTPS API. It does not use analytics or a third-party server. Usage is held in memory; appearance preferences are local. Legacy manual-mode preferences migrate to automatic authentication; old Keychain entries are left untouched and unused. It uses undocumented endpoints and may require updates if Cursor changes them. No affiliation with Cursor or xAI is implied.

## Distribution status & Gatekeeper

This build is ad-hoc signed. When downloaded over the internet, macOS Gatekeeper may block execution or show a security warning because it is not signed with a paid Apple Developer ID certificate or notarized by Apple.

- **Before opening a downloaded build**: Verify its source and compare its checksum with a trusted release. From the folder containing the ZIP and checksum, run `shasum -a 256 -c Cadence-1.1.0-universal.zip.sha256`. A checksum detects corruption, not publisher identity.
- **For a build you trust**: Use System Settings → Privacy & Security → **Open Anyway**, if available for your macOS version and policy. Do not disable Gatekeeper or remove unrelated extended attributes.
- **Building from source**: Review the code and run `npm run build:mac` or `bash macos/build.sh`. This generally avoids download quarantine, but local signing does not guarantee trust or suppress every security warning.
- **For official notarized releases**: The maintainer must sign with an Apple Developer ID Application certificate and notarize via `xcrun notarytool` as detailed below.

## Maintainer: build and package

```sh
npm run test:mac
npm run build:mac:universal
npm run package:mac
```

The package command creates a versioned ZIP and SHA-256 checksum from the built app and this guide.

For a public release, set `SIGNING_IDENTITY` to your installed Developer ID Application identity and build again. Then package, submit the ZIP with `xcrun notarytool submit ... --keychain-profile ... --wait`, staple the app with `xcrun stapler staple 'dist/Cadence.app'`, validate with `xcrun stapler validate`, and run `npm run package:mac` again so the ZIP includes the notarization ticket. Keep credentials in a Keychain profile, not scripts or source files.

Apple's distribution requirements: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
