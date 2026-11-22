# App icon sources

Black, like Apple's own dark icons, with the accent (blue into teal) in the logo, not the background.

- `icon.svg` — the default icon (black), also used for Dark Home Screens → `AppIcon`
- `icon-light.svg` — the white alternative (More → App Icon → Light) → `AppIcon-Light`
- `icon-tinted.svg` — grayscale glyph on transparent for Tinted Home Screens (iOS colors it)

Rendered at 1024×1024 into `SecondBrain/Assets.xcassets` (plus 240 px previews in `IconDark` /
`IconLight` for the picker). Open an SVG in a browser at 1024 px and save, or use any SVG renderer.
No purple, on purpose.
