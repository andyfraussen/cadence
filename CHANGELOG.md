# Changelog

## 1.4.1 — 2026-10-28

### Changed

- Claude limits are checked at most every five minutes, including on popover open and wake; Retry still checks immediately. Claude’s usage endpoint rate-limits aggressively, so a 429 now waits for `Retry-After` or backs off from five minutes up to thirty. Claude readings stay fresh for 15 minutes instead of three.

### Fixed

- An expired copy of Claude Code’s sign-in in `~/.claude/.credentials.json` no longer hides the “press Retry” prompt when the keychain has not been read yet.

## 1.4.0 — 2026-10-28

### Added

- Claude limits: the 5-hour session and weekly windows for the account signed in to Claude Code, with the same fixed daily budget and menu bar `Cl` readout as the other providers. Cadence reads Claude Code’s token from the login keychain (choose **Always Allow**) and never refreshes or stores it.

## 1.3.5 — 2026-10-23

### Fixed

- Current Cursor builds seal the desktop session in the macOS login keychain. Cadence unlocks that session instead of sending the sealed value to Cursor’s API.
- The keychain dialog wants this Mac’s login password, not the Google account password. Choose **Always Allow**. Opening the menu, wake, and the minute timer do not ask again; **Retry** does.

## 1.3.4 — 2026-09-26

### Fixed

- Codex daily usage no longer stays stuck after the weekly limit resets.

## 1.3.3 — 2026-09-26

### Fixed

- Codex limits still resolve after ChatGPT moved the bundled Codex executable.
