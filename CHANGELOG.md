# Changelog

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
