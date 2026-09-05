# Aza — production icon assets

Approved appearance: graphite tile, lime Aza lettering. The rounded lettering is fixed.

- `app-icon.png`: full-colour artwork with transparent outer margins, prepared with the built-in image_gen tool.
- `menu-bar-mark.png`: monochrome lettering with transparency, prepared with the built-in image_gen tool.
- `aza-rounded-graphite-lime.png`: approved original concept, preserved as a reference. Graphite #303438–#191D21, lime lettering #B6F36B.
- Run `swift Tools/generate-icons.swift` from the repository root to regenerate the AppIcon and MenuBarMark asset catalog images using native macOS rendering. It checks transparent margins and generated image sizes.
- The app icon feeds Finder, Dock, system notifications, the settings/onboarding header, the menu header, and the standard About panel. The menu bar uses the monochrome template mark, allowing macOS to adapt it to light and dark appearances.
- UI control colors remain governed by `AzaStyle`; lime is the icon's brand accent.

## Image generation prompts

Integration verified on 05.09.2026: 74 XCTest tests passed; native previews
confirmed small icon sizes, both menu-bar appearances and the About button layout.
The Release asset catalog contains all 10 macOS icon renditions (16–1024 px)
and the menu-bar template. The signed `dist/Aza-1.0.dmg` was mounted read-only;
its contents match the Release app and its checksum and signatures verify.
The running user application was not replaced or restarted.

### app

Edit the approved Aza icon attached. This is production asset preparation, NOT a redesign.
Preserve exactly the graphite rounded-square tile, vivid lime-green Aza lettering, all glyph contours, letter sizes and spacing, original colors, subtle gradient and optical balance.
Remove ONLY the white background outside the rounded-square tile. The outside margin must have real PNG alpha transparency, zero alpha. No checkerboard, no white halo, no shadow outside the silhouette. The dark tile, including its corners and all internal spaces of the word, remains fully opaque. A precise smooth cutout following the existing tile silhouette.
Fit the entire unchanged tile uniformly into the center of a square canvas so the visible tile occupies 82% of canvas width and height with transparent margins. Do not crop any part of the tile or wordmark. Preserve shape ratios. Return one square production PNG with alpha. Nothing else.

### menu

Extract ONLY the exact approved Aza LETTERING from the attached app icon, for use as a small monochrome macOS menu-bar template image.
Preserve the exact existing font and letter silhouettes: arch-shaped capital A with crossbar, rounded lowercase z, round single-storey a. Preserve stroke thickness, counters, spacing and proportions. Do not redraw, re-typeset or redesign.
Remove the entire graphite tile and the white canvas and everything except the three letter shapes. Change the letters from lime-green to solid black, with fully opaque black interiors and clean antialiased edges. The background and every internal counter and gap must be genuine PNG alpha transparency. This is a transparent-background stencil, not black text on white, and not a checkerboard.
Crop the canvas closely to the wordmark, with only a small transparent margin on all sides. Flat pure black, no shading, no gradients, no shadows, no outline, no glow. Exactly one original Aza wordmark and nothing else.

## Final transparent cutouts

### app

Remove the white background outside this dark rounded-square Aza app icon. Transparent background PNG cutout. Keep the icon and its lime Aza lettering exactly unchanged. The whole exterior is transparent; all of the dark icon tile is opaque. Clean smooth edges, no exterior shadow.

### menu

Remove the pale checkered background from this black Aza wordmark. Transparent background PNG. Only the three solid black letters should remain, with transparent holes and transparent gaps. Preserve every letter shape exactly. No white canvas, no checkerboard, no border, no shadow.
