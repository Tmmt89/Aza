# Aza — Rise Academy × EL principles

Source: Superdesign project `3604693f-c712-443e-bf48-c4f141869670`, adapted for a native macOS Dynamic Island surface.

## Foundations

- Stage: `#0E0E10`
- Panel: `#1E2128`
- Deep: `#0A0A0C`
- Ink: `#F5F5F5`
- Muted: `#B3B9C4`
- Line: `#2C313B`
- Rise blue: `#2F0DFF`
- Acid: `#C7FF54`
- Destructive states use macOS system red.

The physical notch and Aza's outer silhouette remain pure black so they read as one shape. Stage, panel, and deep colors are used only inside the expanded surface.

## App identity

The approved app icon is graphite with lime Aza lettering. This is a brand accent,
independent of the blue settings controls and the island's functional colors.
Use the system application icon in headers and About; use the monochrome
`MenuBarMark` template in the macOS menu bar. Canonical artwork and regeneration:
`Design/app-icon-production.md`. The old tower icon is historical.

## Typography

Rise uses Roboto Condensed for display and Manrope for body. Aza maps those roles to the native macOS system family: condensed heavy display text for prayer times and compact headings, regular system text for controls and body copy. Use tabular numerals for time.

- Eyebrow labels: 9–11 pt, semibold, uppercase, modest tracking.
- Controls and metadata: 10–12 pt, semibold.
- Body and locations: 13–15 pt.
- Display prayer time: 30–34 pt, semibold, condensed, tabular.

## Components

- Outer island: one pure-black shape attached to the top edge, 34 pt continuous lower corners.
- Content panels: Deep or Panel fill, 1 pt Line border, 24 pt continuous corners.
- Primary action: Rise blue fill with Ink content.
- Current/selected state: Acid fill with black content.
- Secondary action: Panel fill with Line border.
- Chips: capsules; Acid for active, Panel + Line for inactive.
- Clipboard cards: 20 pt corners, Deep fill; selected card uses Panel fill and a 2 pt Acid outline.
- No gradients or glass inside the island.

## Spacing and motion

Use an 8 pt rhythm with 4 pt optical adjustments. Keep the island wide and shallow, with dense typography and no large empty areas. Expansion uses the native snappy animation at 240–320 ms. Hover/focus changes use 120–180 ms. Reduced Motion falls back to opacity.

## Accessibility

Keep full keyboard navigation, visible shape-based selection, VoiceOver labels, and WCAG AA text contrast. Do not place actionable content under the camera cutout.

## Settings and menu bar — September 2026

The persistent settings window uses a calm native macOS treatment, separate from transient island status colors.
- Sidebar: graphite #161618, monochrome SF Symbols, neutral selection fill #262629 with a small #69A9F6 marker.
- Navigation: Application (General, Access and data), Text (Dictation, Correction, Clipboard, Phrases), Reminders (Prayer).
- One blue accent across all settings controls. Reserve warning/red for actual warning and destructive states.
- Window 820×680 logical points, resizable down to 700×560. Stable header/footer; only the detail pane scrolls.
- Group cards: 12pt radius, 16pt padding, 22pt between groups. Each card has a meaningful visible heading.
- Explain common toggles inline. Native switches, labeled pickers, and standard confirmation alerts preserve accessibility.
- Hotkeys remain next to the corresponding feature. Data cleanup distinguishes retaining favorites from deleting all history.
- Reference: Apple HIG [Settings](https://developer.apple.com/design/human-interface-guidelines/settings), [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars), [Color](https://developer.apple.com/design/human-interface-guidelines/color).
