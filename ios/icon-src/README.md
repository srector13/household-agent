# App icon sources

Four abstract marks, each on a black tile and on a white tile — eight icons you pick from in
More → App Icon. The accent (blue into teal) lives only in the mark, never the tile. No purple,
on purpose (hue 232–335 is banned by CI).

| Mark | Black | White |
| --- | --- | --- |
| Caught thought — an open circle holding one dot | `AppIcon` (default) | `AppIcon-CaughtLight` |
| Two minds — two overlapping rings | `AppIcon-Minds` | `AppIcon-MindsLight` |
| Loop — one line winding inward to a point | `AppIcon-Loop` | `AppIcon-LoopLight` |
| Orbit — a dot circling a ring | `AppIcon-Orbit` | `AppIcon-OrbitLight` |

Every icon set has a tinted variant (light glyph on transparent; iOS colors it for Tinted Home
Screens). Black sets also carry the same art as their dark variant. Each icon has a 240 px
`IconPreview-*` image for the picker.

Render everything (SVG sources here, PNGs into `SecondBrain/Assets.xcassets`):

    node ios/icon-src/render.js

It uses the Chromium that ships with Playwright. The mark geometry lives in `render.js` (100×100
box); the `*-black.svg`, `*-white.svg` and `*-tinted.svg` files are its output, kept for reference.
The list of alternates in `project.yml` (`ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`) and in
`SecondBrain/Design/AppIcons.swift` must match the asset names above.
