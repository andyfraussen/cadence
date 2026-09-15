# Publishing Guide, Branding & Product Strategy

This document covers everything needed to brand, enhance, and publish this macOS app on GitHub.

---

### 1. App Name Proposals

When publishing on GitHub, avoid leading with "Cursor" as the main trademark to prevent brand confusion or future trademark disputes with Anysphere (Cursor's parent company). The best practice in the Apple ecosystem is **Distinct Name** with a subtitle like *"for Cursor"*.

| Name | Subtitle / Tagline | Why it works |
| :--- | :--- | :--- |
| **Cadence** *(Recommended)* | *The usage pacer for Cursor* | Elegant, native macOS feel (like Raycast, Alfred, Things). "Cadence" perfectly captures rhythmic pacing of your daily quota. |
| **Pacer** | *Keep your Cursor quota on track* | Direct, functional, memorable. Immediately tells developers what the tool does. |
| **CursorPace** | *Smart quota pacing for Cursor Pro* | Maximizes search discoverability (SEO) while maintaining an independent identity. |
| **Runway** | *Daily AI budget & quota monitor* | Familiar developer metaphor (runway before running out of quota). |
| **QuotaBar** | *Minimal menu bar gauge for Cursor* | Classic Mac utility naming convention (like MenubarX, Stats). |

---

### 2. Logo & App Icon Concepts

#### Visual Motif
Cadence uses a flat black rounded-square tile with a white geometric C: flat-cut terminals, an opening on the right, and a small contained rhythm notch at the top. The code-rendered artwork is shared by the macOS app icon, dashboard, and Settings.

#### Artwork and Regeneration
See `macos/Assets/README.md` for provenance and the regeneration command (`macos/Assets/GenerateAppIcon.swift` reproduces `AppIcon.png` byte-identically). The build produces all required macOS icon sizes from `macos/Assets/AppIcon.png`.

#### Menu Bar Icon
- `CadenceBrand.menuBarIcon` in `macos/Views.swift` draws the same mark (matching ±36° opening and flat cuts, notch omitted at menu size) as a monochrome template in light and dark mode, without shrinking the full tile.

---

### 3. Feature Roadmap & Improvements

#### Quick Wins (High Impact, Low Effort)
1. **Today’s Burn Rate vs. Safe Allowance**:
   - Store local quota snapshots at midnight.
   - Show: `Used today: 2.1% · Safe allowance: 3.5%` so users know if they are over-spending today.
2. **Customizable Menu Bar Compact View**:
   - Toggle between lowest remaining % (e.g. `86%`), icon-only, or full badges (`C: 88% O: 86%`).
3. **Smart Notifications (macOS UserNotifications)**:
   - Alert when remaining quota drops below 10% or 5%.
   - Daily pacing warning: *"You've used more than 2x your safe daily budget today."*

#### Medium-Term Enhancements
1. **Usage Trend Graph / Sparkline**:
   - A lightweight 7-day or 14-day depletion curve inside the popover.
2. **Raycast Extension / Alfred Workflow**:
   - A quick command (`cp`) to view current pacing without clicking the menu bar.
3. **Multi-Account Switching**:
   - Support multiple Cursor profiles (e.g. personal Pro vs. company Pro+).

---

### 4. Step-by-Step GitHub Publishing Guide

#### Step A: Initialize Git Repository
In the project root:
```bash
git init
git add .
git commit -m "Initial release: Cadence macOS menu bar app v1.1.0"
```

#### Step B: Create GitHub Repository & Push
Using GitHub CLI (`gh`):
```bash
gh repo create cadence --public --source=. --remote=origin --push
```
Or create a new empty repository at https://github.com/new, then run:
```bash
git remote add origin https://github.com/<your-username>/<repo-name>.git
git branch -M main
git push -u origin main
```

#### Step C: Automated GitHub Releases (CI/CD)
The repository includes `.github/workflows/release.yml`. Stable tags must have the form `vMAJOR.MINOR.PATCH` and match both `macos/Info.plist` and `package.json`; prerelease and mismatched tags are rejected before publishing. Valid tags trigger tests, a universal build, ZIP/checksum packaging, and a GitHub release. Pull requests and pushes to `main` also run tests and a universal build.

```bash
git tag v1.1.0
git push origin v1.1.0
```

#### Step D: Manual Build & Release (Without CI)
To build and package locally:
```bash
# 1. Run test suite
npm run test:mac

# 2. Build Universal binary (Apple Silicon + Intel)
npm run build:mac:universal

# 3. Package zip & checksum
npm run package:mac

# 4. Create release with GitHub CLI
gh release create v1.1.0 dist/Cadence-1.1.0-universal.zip dist/Cadence-1.1.0-universal.zip.sha256 \
  --title "Cadence v1.1.0" \
  --notes "First public release of Cadence for macOS."
```

---

### 5. Distribution Strategy & macOS Gatekeeper

#### Recommended Distribution: Build from Source
For developer-focused open-source macOS utilities, **building from source is the cleanest distribution model**:
- Compiling locally (`npm run build:mac` or `bash macos/build.sh`) requires zero third-party packages; build time varies.
- Local ad-hoc signing is not Developer ID signing or notarization. Local builds generally avoid download quarantine, but macOS policy and inherited attributes can still affect launch.
- Users have full transparency into the exact code accessing their local Cursor database.

#### Distributing Pre-Built Binaries (GitHub Releases)
If you publish pre-compiled `.zip` release binaries:
1. **Without Apple Developer ID**:
   Downloaded binaries may be quarantined or blocked. Explain this in release notes and provide source and checksum verification instructions. For trusted builds, direct users to System Settings → Privacy & Security → **Open Anyway**, when available; do not advise disabling Gatekeeper or clearing unrelated attributes.
2. **With Apple Developer ID ($99/year)**:
   Follow `macos/SHARING.md` to sign with your Developer ID Application certificate and submit to Apple's notarization service (`xcrun notarytool`). Notarization and stapling support Gatekeeper verification, but do not guarantee a prompt-free launch under every macOS policy.
