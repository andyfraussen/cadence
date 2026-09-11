### Cadence code review — 2026-09-11

Reviewed all five Swift application files, the test suite and runner, build/package scripts, release workflow, bundle metadata, package configuration, branding, and user/distribution documentation. The deleted Python/web implementation was not treated as active code.

### Resolution — 2026-09-11

All seven numbered findings below are fixed. The original findings and line references are retained as a historical snapshot, not a description of the current implementation.

| Finding | Resolution |
| --- | --- |
| 1. Calendar pacing | Both modes enumerate local calendar dates overlapping `[now, reset)`. Partial dates count once; midnight reset excludes that date. Tests cover partial weekdays and both DST transitions. |
| 2. Legacy manual authentication | Automatic-only authentication; obsolete auth preferences are removed at initialization. Legacy Keychain credentials are neither accessed nor deleted. Recovery messages and documentation point to Cursor desktop login. |
| 3. Coupled refreshes | Independent publication, busy flags, cancellation, and account-generation guards. Hidden Grok makes no request; completed pools can retry while another is pending. |
| 4. Misleading Settings status | Fetching, connected, stale, unavailable, idle, and demo states; last-success timestamp and Retry. A periodic view update ages status without requiring a response. |
| 5. Checksum portability | Basename-only checksums and staging cleanup on success/failure; tested after relocating archive/checksum pairs. |
| 6. Boolean timestamps | Explicit non-boolean number or numeric-string parsing; boolean, null, nonfinite, overflow, and boundary cases rejected. |
| 7. Release/version mismatch | Stable-only semantic tags must match bundle and package versions. Settings reads the bundle version. Prerelease tags are deliberately rejected rather than published as stable. |

Additional maintenance: PR/main test-and-build CI, cached in-app artwork, and corrected signing/quarantine guidance. Future feature proposals and optional redirect/HTTP/SQLite hardening below remain recommendations, not implemented features or established security defects.

**Verification:** 46 parser/pacing checks, injected model regressions (including account switches, obsolete results, asymmetric failures, hidden/re-enabled Grok, credential loss/recovery, and status aging), portable packaging/cleanup checks, and 26 release-tag cases pass. Calendar and hidden-Grok regressions failed before the fixes; the checksum relocation regression also failed before its fix. Universal `x86_64`/`arm64` build, signing verification, packaging, and adjacent-file checksum validation pass. Demo/dashboard/Settings launch produced no logged errors; no live credentials/API testing or physical Intel/macOS 13 validation was performed.

### Original findings, prioritized (historical)

#### 1. Medium — Weekday pacing miscounts partial days and DST transitions

- **Location:** `macos/Usage.swift:17–29`.
- The loop length is rounded-up elapsed 24-hour periods, but each iteration classifies a calendar date at the original clock time. This does not enumerate weekdays that actually overlap the remaining interval.
- **Reproduced:** Sunday `2026-09-13 12:00 UTC` to Monday `2026-09-14 12:00 UTC` reports zero workdays and no allowance, despite the available Monday morning.
- **Reproduced:** Sunday `2026-11-01 00:00` to Monday `2026-11-02 00:00` in `America/Los_Angeles` reports one workday and a 50% weekday allowance for a 50%-remaining quota. That 25-hour DST interval contains only Sunday before reset.
- **Recommendation:** Define the partial-day policy explicitly, then enumerate local calendar-day intervals overlapping `[now, reset)`. Exclude the reset endpoint. Add both DST transitions and partial-weekday regression tests. Decide separately whether ordinary daily pacing means calendar dates or rounded-up 24-hour periods.

#### 2. Medium — Persisted manual authentication can strand an automatic-sync user

- **Location:** `macos/AppModel.swift:24`, `macos/Authentication.swift:49–56`, `macos/Views.swift:181–258`.
- The model still honors persisted `authMode=manual`; that path reads only Keychain. Settings now exposes no authentication switch, token replacement, or recovery control.
- **Scenario:** A previous manual configuration with an expired/missing token cannot recover by signing into Cursor. A still-valid manual token can continue to select a different account from Cursor's active session. This is a static control-flow finding; no personal preferences or credentials were changed to reproduce it.
- **Recommendation:** Either deliberately migrate to automatic-only authentication or restore a supported authentication/recovery section. Align error messages and the manual-token claims in `README.md:64,146` with that decision.

#### 3. Medium — Grok blocks monthly refresh publication even when hidden

- **Location:** `macos/AppModel.swift:45–73`.
- Both requests start concurrently, but `await (monthlyResult, grokResult)` waits for both before publishing either. `showGrok=false` does not suppress the Grok request.
- **Scenario:** A fast monthly success stays invisible while Grok stalls, leaving the dashboard blank on first load or showing old balances until the slower request finishes. The global refreshing flag also prevents another refresh during that wait.
- **Recommendation:** Publish results independently with the existing generation/account guard. Avoid requesting hidden pools, or at least ensure they cannot block visible ones. Test asymmetric success, failure, delay, and account changes with an injected API client.

#### 4. Medium — Settings always presents a healthy automatic-sync status

- **Location:** `macos/Views.swift:240–245`.
- The green dot and “Syncing automatically with Cursor desktop app” text are unconditional. They remain green for missing authentication, expired credentials, network failures, and legacy manual mode.
- **Recommendation:** Derive status from the model and actual authentication source. Distinguish fetching, connected, stale, and unavailable; include last success and a recovery action. This is especially important while finding 2 remains unresolved.

#### 5. Low — Published checksums reference the build machine's absolute path

- **Location:** `macos/package.sh:16–18`.
- The checksum command receives the absolute archive path and writes that same path into the checksum file. The generated artifact was inspected and confirms this behavior.
- **Impact:** A recipient running `shasum -a 256 -c Cadence-1.1.0-universal.zip.sha256` attempts to open a path on the maintainer's machine or CI runner, rather than the adjacent download.
- **Recommendation:** Generate the checksum from inside `dist` using the archive basename. Verify it after copying the pair to a different directory. The digest itself is valid; the filename makes standard verification non-portable.

#### 6. Low — Boolean billing-cycle timestamps pass validation

- **Location:** `macos/Usage.swift:47–56`.
- **Reproduced payload:** `{"billingCycleEnd":true,"planUsage":{"autoPercentUsed":0,"apiPercentUsed":0}}` produces two quotas with a reset approximately one millisecond after the Unix epoch instead of throwing a parsing error.
- `JSONSerialization` bridges `true` to a boolean `NSNumber`, which the string-based timestamp conversion accepts as `1`. The existing `percent()` implementation already explicitly excludes booleans.
- **Impact:** Malformed data becomes stale 100%-remaining balances rather than a clear invalid-response error; it is not shown as a fresh allowance.
- **Recommendation:** Reject boolean timestamps explicitly while retaining supported numeric and numeric-string inputs. Add boolean, null, infinity, overflow, and exact upper-bound cases.

#### 7. Low — Release tags are not validated against release type or bundle version

- **Location:** `.github/workflows/release.yml:5–6,26–34`, `macos/Info.plist:9–10`, `macos/Views.swift:161`, `package.json:3`.
- Every `v*` tag is published with `prerelease: false`; a tag such as `v1.2.0-beta.1` therefore becomes a non-prerelease. No check ensures the tag agrees with the bundle version used for the ZIP filename. The Settings version is also hard-coded independently.
- **Recommendation:** Validate release tags against the bundle version, derive prerelease status from the tag or restrict the workflow to stable tags, and read the displayed version from the bundle.

### Coverage and maintainability

- **Good foundations:** Small native implementation; read-only SQLite access; Keychain support; ephemeral HTTPS requests; strict percentage validation; same-account error retention with stale indicators; generation checks around account changes. Refresh-on-wake and Launch at Login already exist and are not missing features.
- **Existing verification:** `bash macos/test.sh` passes 26 parser/pacing checks. It compiles authentication but has no ordinary non-live authentication behavior tests; it does not compile/test `AppModel.swift`.
- **Highest-value tests:** Inject token loading and endpoint fetching into the model. Cover in-flight account switches, obsolete response rejection, partial endpoint failures, hidden Grok, missing credentials, and stale transitions. Add deterministic clocks/calendars, temporary SQLite fixtures, and HTTP status/cancellation/redirect cases. Avoid using real Keychain entries or session tokens in ordinary tests.
- **Security hardening, not a proven leak:** The API client has no explicit application-level redirect policy. Test same-origin, cross-origin, and HTTPS-to-HTTP redirects; consider rejecting unnecessary redirects. The review did not establish bearer-token leakage, and ephemeral sessions alone do not enforce an origin policy.
- **CI:** Tests currently run on release tags only. Add pull-request checks for tests and compilation before changes reach a release.
- **Documentation:** Claims of guaranteed Gatekeeper bypass/local trust in `README.md:75–77,116–121`, `PUBLISHING.md:110–119`, and `macos/SHARING.md:34–37` are too absolute. Explain signing and quarantine caveats, and prefer trusted-source verification and scoped quarantine guidance over blanket `xattr -cr` advice.
- **Small cleanup opportunities:** Cache the in-app decoded artwork rather than load it in each view evaluation; remove package staging directories on exit. Neither is a release-blocking defect.

### Recommended features and settings

| Priority | Feature / setting | Suggested behavior | Relative effort |
| --- | --- | --- | --- |
| 1 | Connection and recovery panel | Actual account source, per-pool last success, retry, and actionable auth errors; diagnostics must redact credentials. | Small–medium |
| 2 | Configurable quota alerts | Per-pool 10%/5% thresholds, once-per-cycle deduplication, quiet hours, and permission requested only when enabled. Suppress stale-data alerts. | Medium |
| 3 | Custom work schedule and reserve | Select working weekdays, exclude holidays/vacation, and retain a configurable quota reserve before computing the allowance. Fix interval counting first. | Medium |
| 4 | Compact menu-bar modes | Lowest remaining pool, selected pool, or safe daily allowance; preserve a visible stale/error signal in every mode. | Small |
| 5 | Optional local usage history | Today’s observed usage and 7/30-day sparklines; reset/account-aware snapshots, retention limit, delete/export controls, and explicit opt-in. Do not present unobserved overnight usage as exact spending today. | Medium–large |
| 6 | Refresh policy | Independent per-pool retry, bounded refresh intervals, network-aware backoff, and manual refresh. Refresh-on-wake is already implemented. | Medium |
| 7 | Keyboard access | Configurable global shortcut to open the popover, plus keyboard-friendly refresh/settings actions. | Small–medium |

**Suggested next iteration:** Fix findings 1–4 and add model tests first, then ship configurable alerts and compact menu-bar modes. Historical usage and multiple-account profiles should follow only after account/reset isolation is well tested.

### Validation performed and limits

- All 26 existing parser/pacing checks passed; the universal app built for `x86_64` and `arm64`, including strict code-signature verification. Packaging succeeded and the archive contains both icon resources.
- The bundled PNG matches the supplied source. An offscreen branding harness checked transparency, the template flag, and the C silhouette at 1×/2×; an enlarged rendered mark was visually inspected. Scratch harnesses and previews live in ignored `.build` files, not the normal test suite.
- The app launched with `--demo --preview --settings`, ran without logged errors, and was stopped. No live API or personal authentication test was run; interactive behavior on both macOS menu-bar themes and actual Intel/macOS 13 machines was not verified.
- Deterministic diagnostic probes confirmed both calendar examples and boolean timestamp acceptance above. Remaining control-flow findings are static review results, not claims of end-to-end reproduction. No unrelated bug fixes or proposed features were implemented.