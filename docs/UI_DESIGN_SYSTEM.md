# CodeForge UI Design System — "Forge"

**Status:** v1.1 — synchronized with the Phase 1 implementation (2026-11-05) · Original identity, not a VS Code clone (spec §4)

**Source of truth:** the token files in `app/lib/design_system/tokens/` (`colors.dart`, `geometry.dart`, `typography.dart`). This document describes them; if the two ever disagree, the code wins and this file is corrected. Contrast is enforced by `app/test/design_system/contrast_test.dart` (G4), targets and labels by `app/test/widget/accessibility_test.dart` (G7).

Direction: **a precision instrument.** Graphite surfaces, ember accent, mono-spaced soul. Calm, dense-but-breathing, zero decoration that doesn't earn its pixels. Think professional workstation hardware, not a neon hacker theme.

---

## 1. Color tokens (dark primary)

| Token | Dark | Light | Use |
|---|---|---|---|
| `surface.base` | `#0F1115` | `#FAFAF8` | app background |
| `surface.panel` | `#161920` | `#FFFFFF` | panels, sheets |
| `surface.raised` | `#1D2129` | `#F1F0EC` | cards, popovers, tab bar |
| `surface.sunken` | `#0B0D10` | `#EFEDE8` | editor background, terminal |
| `border.subtle` | `#262B35` | `#E2E0DA` | separators (1 px, never shadows-as-borders) |
| `border.strong` | `#39404D` | `#C9C6BE` | focus rings, active panel edge |
| `text.primary` | `#E8EAF0` | `#1B1E24` | body |
| `text.secondary` | `#9AA1B0` | `#5B6068` | labels, metadata |
| `text.disabled` | `#5C6270` | `#A6A9AE` | inactive |
| `accent.ember` | `#FF7A45` | `#B93E0C` | primary actions, active states, brand |
| `accent.emberSoft` | `#FF7A4524` | `#B93E0C1F` | active tab underline glow, selection chips |
| `on.accent` | `#1A0E06` | `#FFFFFF` | text/icons on ember fills (7.32:1 dark, 5.59:1 light) |
| `success` | `#4ADE80` | `#166534` | git added, tests pass |
| `warning` | `#FBBF24` | `#92400E` | dirty state, degraded runtime |
| `danger` | `#F87171` | `#B91C1C` | errors, deletions |
| `info` | `#60A5FA` | `#1D4ED8` | links, info diagnostics |

Syntax palette (editor + diff, WCAG AA on `surface.sunken`):

| Role | Dark | Light |
|---|---|---|
| keyword | `#C792EA` | `#7C3AED` |
| string | `#A5D6A7` | `#166534` |
| number | `#F78C6C` | `#B93E0C` |
| function | `#82AAFF` | `#1D4ED8` |
| type | `#FFCB6B` | `#92400E` |
| comment (italic) | `#8A93A6` | `#5B6068` |
| operator | `#89DDFF` | `#0E7490` |
| variable | `text.primary` | `text.primary` |

**Contrast rule:** all text tokens ≥ 4.5:1 on every surface they can appear on; automated check in CI (Phase 1 G4).

> **v1.1 changes (Phase 1 contrast audit, 2026-11-05).** Several v1 values failed WCAG AA and were darkened in code; minimum ratios over the four light surfaces: ember `#E85D2A` 2.98 → `#B93E0C` 4.78 · success `#16A34A` 2.82 → `#166534` 6.09 · warning `#B45309` 4.29 → `#92400E` 6.06 · danger `#DC2626` 4.13 → `#B91C1C` 5.53 · info `#2563EB` 4.42 → `#1D4ED8` 5.73. Dark comment `#6B7280` (4.02 on sunken, 3.34 on raised) → `#8A93A6` (6.30 / 5.23). Added `on.accent`; the light syntax palette is now specified (lowest: operator 4.58 on sunken).

## 2. Typography

- **UI:** Inter (bundled, offline). Scale: display 24/600, title 18/600, body 14/400, label 12/500, caption 11/400. Height 1.35–1.45.
- **Code/terminal:** JetBrains Mono (bundled) with ligatures optional (default off on mobile for cursor clarity). Editor default 14 sp, user range 10–24.
- Numerals tabular in status bar/tab counts. No system-font fallback for code (metrics stability).

## 3. Spacing, radius, elevation, motion

- **Spacing:** 4 dp grid — `xs 4, sm 8, md 12, lg 16, xl 24, xxl 32`. Touch targets ≥ 48 dp regardless of visual size (`CfSpacing.minTouchTarget`).
- **Chrome metrics (as built):** top bar, tab strip and terminal header are a 48 dp touch row + 1 px hairline (`CfSpacing.hairline`; a border insets its children, so bars holding targets add it on top) · tab close 48×48 · explorer tree rows 48 · palette rows ≥ 48 · settings rows ≥ 48 · activity bar 56 (items fill their slot) · nav rail 64 wide (items fill the rail) · symbol toolbar 48 + hairline, keys ≥ 48 wide (Phase 2 W6) · status strip 24. The active-tab indicator is painted as a foreground decoration so it never shrinks the tab. v1.1 raised the tab strip (40), tree rows (36), terminal header (36) and top-bar buttons (40) to 48 for G7.
- **Radius:** `sm 6` (chips, inputs), `md 10` (cards, sheets), `lg 14` (dialogs). Never > 14; no pill cards.
- **Elevation:** dark theme uses **borders + surface steps, not shadows**; light theme 1-level soft shadow for overlays only.
- **Motion:** durations `fast 120 ms, base 200 ms, slow 320 ms`; curves: standard `easeOutCubic`, entrance `easeOutQuart`, exit `easeInCubic`. Sheet springs critically damped. **Reduc-motion setting** disables non-essential animation. No decorative loops.

## 4. Layout & breakpoints

`compact < 600 dp · medium 600–840 · expanded > 840` (ARCHITECTURE.md §5). Phone portrait: editor-first, bottom activity bar (Explorer · Search · Run · Git · More), terminal bottom-sheet. Landscape: icon rail. Tablet: persistent sidebar + docked panels + resizable dividers. Status strip (24 dp): branch, runtime status dot, cursor Ln/Col, language, errors count. In Phase 1 the segments are informational (tooltips, no tap action — so they are not touch targets); each becomes tappable in the phase that delivers its feature, and must then meet the 48 dp target rule (e.g. via a bottom sheet of actions rather than 24 dp hit areas).

## 5. Component inventory (Phase 1 builds all with states)

`CfScaffold` (adaptive) · `CfActivityBar` / `CfNavRail` · `CfTabStrip` (scrollable, dirty dot, close) · `CfPanel` + `CfDivider` (draggable) · `CfBottomSheet` (3-stop) · `CfButton` (primary/ghost/danger, loading) · `CfIconButton` · `CfInput` + `CfSearchField` · `CfListItem` (file row: icon, name, meta, trailing) · `CfTreeTile` · `CfChip` · `CfBanner` (info/warn/error, dismissible) · `CfEmptyState` (illustration-free: icon + title + one action) · `CfDialog` · `CfSnackbar` · `CfSymbolToolbar` (editor/terminal presets) · `CfStatusStrip` · `CfCommandPalette` (Phase 1 skeleton, fuzzy list) · `CfSettingsTile`.

Every component: default/hover(hardware)/pressed/focused/disabled/loading/error states as applicable; semantics labels; golden tests at 3 breakpoints.

**As built in Phase 1:** `CfButton` · `CfIconButton` · `CfBanner` · `CfEmptyState` · `CfStatusChip` · `CfSectionHeader` · `CfSettingsTile` · `CfTreeRow` · `CfTabStrip` · `CfActivityBar` / `CfNavRail` · `CfStatusStrip` · `CfSymbolToolbar` (keys disabled until Phase 2; they were 36 dp tall. Since W6 the keys are live 48 dp targets: docs/EDITOR_ARCHITECTURE.md §9) · command palette (`features/palette`). Golden coverage: the component gallery (dark + light) and screen goldens for home / workspace / settings at the G3 gate sizes (`app/test/goldens/`). The remaining inventory items (`CfPanel`/`CfDivider` as standalone widgets, `CfBottomSheet`, `CfInput`/`CfSearchField`, `CfChip`, `CfDialog`, `CfSnackbar`) land with the features that need them.

**Added in Phase 3 W4:** the explorer's row menu (long-press, the ⋯ button on the selected row, the context-menu key or Shift+F10) with New File, New Folder, Rename, Move to…, Duplicate, Copy Path and Delete in three groups; the name dialog, the folder chooser for Move to… and the delete question (`features/workbench/explorer_dialogs.dart`, `file_dialogs.dart`); a *deleted on disk* banner over the editor and a struck-through tab; Go to File (`features/palette/go_to_file.dart`), which looks like the command palette, with each match's file glyph, its name and folder, the matched letters in the accent colour, and a status line under the list; and a *Save* action in About → Recent logs. `CfTreeRow` draws a file's glyph (§6).

**Added elsewhere in Phase 3:**
- **Home as the launcher (W2, W3):** the recents, one row per project or folder with its kind, its place and its status (*missing*, *access lost*), and a menu per row (Open; Rename… and Delete… for projects; Reconnect… and Remove from recents… for folders); the dialogs for a new project, a rename, a delete and removing a folder.
- **Settings → Privacy (W1):** one switch, *Back up with Android*, whose text says what Android copies, where and on what terms, and a status row under it.
- **Outside changes (W5):** a notice when a clean file was reloaded, and for a file changed under unsaved text a banner over the editor, not a dialog, with *Keep mine* and *Use the file*.
- **Settings → Developer → Log viewer (W6, debug and profile builds):** the session's records, newest first, with a level filter and a tag menu whose rows are 48 dp tall.
- **Goldens:** W6 added four for this chrome: Home's recents in every status, the explorer's menu, the changed-on-disk banner and Privacy (`app/test/goldens/chrome/`).

## 6. Iconography

Material Symbols Rounded subset (bundled font, tree-shaken to used glyphs) + custom file-type glyphs (16 dp grid, 1.5 px stroke) for top 20 extensions; generic fallback. No emoji in UI chrome.

**As built (Phase 3 W4):**
- **Icons:** `CfIcons` (`lib/design_system/tokens/icons.dart`) names each icon the app uses, as a Material Symbols Rounded codepoint. The bundled font holds only those (63), instanced unfilled at optical size 20 and weight 400, since most icons here are drawn at 16 to 20 dp. Directional icons mirror in right-to-left text, as Flutter's did. App bars' automatic back and close buttons use them through the theme; Flutter's other built-in widgets (the licence page, a dropdown's arrow) keep Material Icons. Adding an icon means a constant plus a re-run of `tool/fonts/subset_symbols.py`; `icons_test.dart` fails until the font matches.
- **File glyphs:** `CfFileGlyphs.forName` picks one of 20 glyphs from a few whole names (`.gitignore`, `.bashrc`, `LICENSE`, `.env*`), then from the extension: Dart (a dart), JavaScript and TypeScript (“JS”, “TS”, with JSX and TSX), Python, Kotlin, Go and Rust (“PY”, “KT”, “GO”, “RS”), C and C++ (“C”), Java (a cup), JSON (braces), YAML (an indented list), Markdown (“M↓”), HTML and XML (`</>`), CSS and its dialects (`#`), shell scripts (a prompt), TOML, INI, properties and `.env` (sliders), text and logs (a page with lines), images (a picture), lock files (a padlock) and Git's files (a branch). Everything else is a plain page. The explorer draws them at 16 dp in `textSecondary`, beside the name, so the glyph is never the only signal. The component gallery shows all 21, so its goldens cover each one.

## 7. Voice & empty states

Copy: concise, technical, never cute. Errors say what happened + what to do ("Runtime not installed — Set up"). Placeholders are honest: Phase 1 editor placeholder reads "Editor arrives in Phase 2" in dev builds, removed as features land — no fake functionality (spec rule 8).

**At Phase 3's exit (W7):** what the app says is still to come names ROADMAP's phases. Settings' *Coming in later phases* lists the Linux runtime (Phase 4) and extensions (Phase 8); Phase 3's *Storage & folders* left it, since folders open from Home. The workbench's placeholder panels say search arrives in Phase 4 (moved there by the owner on 2026-11-11), source control in Phase 7, extensions in Phase 8, and running in Phase 5 with debugging in Phase 9. Three of the four had named the wrong phase. `later_phases_test.dart` pins them all.

## 8. Accessibility

Contrast gates in CI; text scale 1.0–2.0 without clipping (tested at 1.3); TalkBack labels on all interactive elements; focus order for hardware keyboards; reduced-motion honored; color never the only signal (icons + text accompany status colors).

- **Automated (G7):** `accessibility_test.dart` runs Flutter's `androidTapTargetGuideline` and `labeledTapTargetGuideline` on every Phase 1 screen at all gate sizes, plus a direct ≥ 48×48 dp measurement of every enabled `InkWell` — the stock guideline skips targets touching a scrollable or screen edge, which would otherwise exempt tabs, tree rows, palette rows and the top bar.
- **Rows with a trailing control** (switch, checkbox) are one semantics node: `CfSettingsTile` wraps its row in `MergeSemantics`, as `SwitchListTile` does, so a screen reader announces title, subtitle and switch state as one item instead of focusing an unlabeled switch.
- **Phase 3:** the tab strip tells TalkBack which tab is active and which have unsaved changes (W1). Since W6 the sweeps also cover Home's recents and dialogs, a recent's actions, the explorer's menu, Settings → Privacy (at 1.3× text too) and the log viewer, and `keyboard_insets_test` opens Home's dialogs beside the keyboard at every gate size.
- **Manual:** a TalkBack spot-check on a device is part of each phase exit (owner).
