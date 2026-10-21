# Transcript app — macOS app icon

Speech bubble (teal, tail pointing to an off-canvas speaker) over a navy typewriter on an orange gradient.

## Contents

| Path | What it is |
|---|---|
| `AppIcon.appiconset/` | Drop-in Xcode asset catalog icon set (all 10 macOS sizes + `Contents.json`). |
| `AppIcon.icns` | Prebuilt icon file, for non-Xcode builds (SwiftPM bundles, scripts). |
| `AppIcon-large.svg` | Master vector, macOS grid (824 pt rounded body centered in 1024 canvas, with shadow), declared at 4096 px. |
| `AppIcon-1024.png` | 1024 px raster of the master. |
| `source/AppIcon-macOS-1024.svg` | Same master at 1024 declared size; regenerate PNGs from this. |
| `source/AppIcon-artwork-square-*.{svg,png}` | Full-bleed square artwork with no corner mask or shadow, for Icon Composer (`.icon`) or iOS, where the system applies the mask. |

## Instructions for Claude Code

1. In the Xcode project's `Assets.xcassets`, replace the existing `AppIcon.appiconset` folder with the one in this package (keep the folder name `AppIcon.appiconset`).
2. Confirm the target's build setting `ASSETCATALOG_COMPILER_APPICON_NAME` is `AppIcon` (Build Settings → "Primary App Icon Set Name").
3. If the app is built without an asset catalog, copy `AppIcon.icns` into `Contents/Resources/` and set `CFBundleIconFile` to `AppIcon` in `Info.plist`.
4. Build, then check the icon in the Dock and Finder. If the old icon persists, run `killall Dock` or clear the icon cache.
5. For a macOS 26 Liquid Glass `.icon` (Icon Composer), start from `source/AppIcon-artwork-square-1024.svg`; separate the bubble and typewriter into layers there.

The PNGs already include the macOS rounded-rectangle shape and drop shadow, matching Apple's macOS icon grid, so do not apply any further masking.

## Palette

| Element | Hex |
|---|---|
| Background gradient (top → bottom) | `#FF9A3D` → `#EE4E2A` |
| Bubble | `#1FB5A8` |
| Bubble text | `#FFFFFF` |
| Page | `#FFF6E8` |
| Typewriter and page text | `#1D2B53` |
