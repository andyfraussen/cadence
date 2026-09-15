# App icon

`AppIcon.png` is a code-rendered geometric mark (2048×2048 PNG with transparency): a flat black rounded-square tile with a clean white C opened on the right and flat-cut terminals. It is deliberately Cursor-adjacent in formula (monochrome tile + geometric mark) while remaining its own letter — it does not copy the official Cursor logo. The build script creates the complete macOS ICNS size set and bundles the original PNG for the dashboard and Settings. `CadenceBrand.menuBarIcon` in `macos/Views.swift` draws the same mark as a monochrome template (matching ±36° opening and flat cuts) for menu bar legibility in light and dark mode, also used as the in-app fallback.

To regenerate byte-identically from source:

```sh
xcrun swiftc macos/Assets/GenerateAppIcon.swift -o /tmp/cadence-icon-gen -framework AppKit
/tmp/cadence-icon-gen flat macos/Assets/AppIcon.png
# Variants: round (rounded terminals), charcoal (softer tile)
```
