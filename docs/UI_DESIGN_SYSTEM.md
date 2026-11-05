# CodeForge UI Design System — "Forge"

**Status:** v1 spec for Phase 1 implementation · Original identity, not a VS Code clone (spec §4)

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
| `accent.ember` | `#FF7A45` | `#E85D2A` | primary actions, active states, brand |
| `accent.emberSoft` | `#FF7A4524` | `#E85D2A1F` | active tab underline glow, selection chips |
| `success` | `#4ADE80` | `#16A34A` | git added, tests pass |
| `warning` | `#FBBF24` | `#B45309` | dirty state, degraded runtime |
| `danger` | `#F87171` | `#DC2626` | errors, deletions |
| `info` | `#60A5FA` | `#2563EB` | links, info diagnostics |

Syntax palette (editor + diff, WCAG AA on `surface.sunken`): keywords `#C792EA`, strings `#A5D6A7`, numbers `#F78C6C`, functions `#82AAFF`, types `#FFCB6B`, comments `#6B7280` italic, operators `#89DDFF`, variables `#E8EAF0`. Light theme variants defined in the same token file. **Contrast rule:** all text tokens ≥ 4.5:1 on their surfaces; automated check in CI (Phase 1 G4).

## 2. Typography

- **UI:** Inter (bundled, offline). Scale: display 24/600, title 18/600, body 14/400, label 12/500, caption 11/400. Height 1.35–1.45.
- **Code/terminal:** JetBrains Mono (bundled) with ligatures optional (default off on mobile for cursor clarity). Editor default 14 sp, user range 10–24.
- Numerals tabular in status bar/tab counts. No system-font fallback for code (metrics stability).

## 3. Spacing, radius, elevation, motion

- **Spacing:** 4 dp grid — `xs 4, sm 8, md 12, lg 16, xl 24, xxl 32`. Touch targets ≥ 48 dp regardless of visual size.
- **Radius:** `sm 6` (chips, inputs), `md 10` (cards, sheets), `lg 14` (dialogs). Never > 14; no pill cards.
- **Elevation:** dark theme uses **borders + surface steps, not shadows**; light theme 1-level soft shadow for overlays only.
- **Motion:** durations `fast 120 ms, base 200 ms, slow 320 ms`; curves: standard `easeOutCubic`, entrance `easeOutQuart`, exit `easeInCubic`. Sheet springs critically damped. **Reduc-motion setting** disables non-essential animation. No decorative loops.

## 4. Layout & breakpoints

`compact < 600 dp · medium 600–840 · expanded > 840` (ARCHITECTURE.md §5). Phone portrait: editor-first, bottom activity bar (Explorer · Search · Run · Git · More), terminal bottom-sheet. Landscape: icon rail. Tablet: persistent sidebar + docked panels + resizable dividers. Status strip (22 dp): branch, runtime status dot, cursor Ln/Col, language, errors count — tappable segments.

## 5. Component inventory (Phase 1 builds all with states)

`CfScaffold` (adaptive) · `CfActivityBar` / `CfNavRail` · `CfTabStrip` (scrollable, dirty dot, close) · `CfPanel` + `CfDivider` (draggable) · `CfBottomSheet` (3-stop) · `CfButton` (primary/ghost/danger, loading) · `CfIconButton` · `CfInput` + `CfSearchField` · `CfListItem` (file row: icon, name, meta, trailing) · `CfTreeTile` · `CfChip` · `CfBanner` (info/warn/error, dismissible) · `CfEmptyState` (illustration-free: icon + title + one action) · `CfDialog` · `CfSnackbar` · `CfSymbolToolbar` (editor/terminal presets) · `CfStatusStrip` · `CfCommandPalette` (Phase 1 skeleton, fuzzy list) · `CfSettingsTile`.

Every component: default/hover(hardware)/pressed/focused/disabled/loading/error states as applicable; semantics labels; golden tests at 3 breakpoints.

## 6. Iconography

Material Symbols Rounded subset (bundled font, tree-shaken to used glyphs) + custom file-type glyphs (16 dp grid, 1.5 px stroke) for top 20 extensions; generic fallback. No emoji in UI chrome.

## 7. Voice & empty states

Copy: concise, technical, never cute. Errors say what happened + what to do ("Runtime not installed — Set up"). Placeholders are honest: Phase 1 editor placeholder reads "Editor arrives in Phase 2" in dev builds, removed as features land — no fake functionality (spec rule 8).

## 8. Accessibility

Contrast gates in CI; text scale 1.0–2.0 without clipping (tested at 1.3); TalkBack labels on all interactive elements; focus order for hardware keyboards; reduced-motion honored; color never the only signal (icons + text accompany status colors).
