# Phase 1 Implementation Plan — Flutter Foundation & Design System

**Status:** Ready to execute on approval · Prerequisite: Phase 0 accepted (this doc set) · Blocks: nothing external — no runtime, no license decision, no device needed to start
**Spec reference:** §8 Phase 1 · **Architecture:** ARCHITECTURE.md · **Design:** UI_DESIGN_SYSTEM.md ("Forge") · **CI:** BUILD_AND_RELEASE.md

---

## 1. Objectives

1. A **real, compilable Flutter Android app** — built and proven by GitHub Actions, not by claim.
2. The **complete premium shell**: navigable, adaptive (phone portrait/landscape, tablet), dark/light, original identity.
3. The **engineering skeleton** every later phase plugs into: service interfaces + fakes, Riverpod, GoRouter, error/logging core, CI gates.
4. **Zero fake functionality**: placeholders are honest, labeled, and beautiful — no button pretends to work (spec rules 8/20).

## 2. MVP 1 definition (spec)

A polished, navigable mobile IDE shell with: Home screen · Workspace screen · Editor placeholder · Explorer placeholder · Terminal placeholder · Settings screen (functional) · responsive phone + tablet layouts.

## 3. Workstreams & tasks

Order: W1 → W2 → W3 → W4 → W5 → W6, with W7 continuous and W8 at exit. Estimates are agent work-sessions (1 session ≈ one focused implementation+verify cycle), not calendar time.

### W1 — Scaffold + CI alive (1 session) 🔑 critical path
| # | Task | Detail |
|---|---|---|
| 1.1 | Flutter project | `flutter create app --org dev.codeforge --platforms android` (app id `dev.codeforge.app`, provisional); Flutter **3.47.9** pinned via `.flutter-version`; `pubspec.lock` committed |
| 1.2 | Android config | compileSdk **36**, targetSdk **36**, minSdk **26** (ADR-0007); Kotlin/AGP/Gradle: start from Flutter 3.47 template pins, reconcile toward t1's proven AGP 8.13.2 / Gradle 9.2.1 / JDK 17 **only if CI proves compatible** — template defaults win over aspirational pins; edge-to-edge + predictive back enabled (API 36 behaviors) |
| 1.3 | Manifest | release permissions: **none** (offline shell); debug-only INTERNET for tooling; `android:enableOnBackInvokedCallback="true"`; app label "CodeForge"; adaptive icon placeholder (brand mark: ember anvil glyph, simple vector) |
| 1.4 | Repo hygiene | root `.gitignore` (build/, .dart_tool/, node_modules/, generated assets, keystores); `.editorconfig`; `analysis_options.yaml` = flutter_lints 6 + strict rules; import-boundary lint script (`tool/lint_imports.dart`) enforcing ARCHITECTURE.md §2 rules |
| 1.5 | Dependencies | flutter_riverpod 3.4.x, go_router 18.1.x, shared_preferences 2.5.x, flutter_lints 6.x — exact pins after `pub get` resolves; justification table in PR (TECH_STACK.md policy) |
| 1.6 | **ci.yml** | per BUILD_AND_RELEASE.md §2: analyze · format check · import lint · unit+widget tests · license check · lockfile-drift check · `flutter build apk --debug` · artifact upload. **First green run = W1 done**; run id recorded |
| 1.7 | PR/issue templates | evidence section mandatory (run ids); phase-gate checklist |

**Exit:** CI green with installable debug APK artifact; pins proven, not guessed.

### W2 — Application core (1 session)
| # | Task | Detail |
|---|---|---|
| 2.1 | Error core | `Failure` sealed taxonomy (`StorageFailure`, `BridgeFailure`, `RuntimeFailure`, `ProcessFailure`, `UnexpectedFailure`), `Result<T>`, central error zone in `bootstrap/`, user-facing error sheet component wiring |
| 2.2 | Logging | structured logger (level/tag/event/fields), bounded ring buffer (memory + file sink), redaction hooks, `LogViewer` dev screen (debug builds only) |
| 2.3 | Riverpod bootstrap | `ProviderScope` + observer (debug logging of transitions), app-level providers: settings, platform info, connectivity-free by design |
| 2.4 | GoRouter | routes `/` (home), `/workspace` (StatefulShellRoute workbench), `/settings`, `/settings/appearance`, `/settings/about`; typed params; unknown-route → home; back/predictive-back verified |
| 2.5 | Lifecycle | `AppLifecycleListener` wiring; state-save hooks used by W6; keyboard-visibility + hardware-keyboard detection providers |
| 2.6 | Service interfaces | `FileService`, `EditorService`, `TerminalService`, `RuntimeService`, `GitService`, `SearchService`, `SettingsService` — abstract contracts + **in-memory fakes** with deterministic demo data (clearly labeled `DemoWorkspace`); contract test suites that native impls will re-run later |

**Exit:** core unit tests green; fakes drive all later widgets; zero platform calls yet.

### W3 — Design system "Forge" (2 sessions)
| # | Task | Detail |
|---|---|---|
| 3.1 | Tokens | `design_system/tokens/`: colors (dark+light tables from UI_DESIGN_SYSTEM.md), spacing, radius, motion, elevation as `ThemeExtension`s; single source of truth, no hardcoded colors elsewhere (lint) |
| 3.2 | Typography | bundle **Inter** + **JetBrains Mono** (OFL; attribution in `assets/fonts/OFL.txt` + notices); text theme scale per spec; tabular numerals in status contexts |
| 3.3 | Themes | `CfTheme.dark()/light()` ThemeData builders; system/dark/light mode via SettingsService; **automated WCAG AA contrast test** over token pairs (G4) |
| 3.4 | Components | full inventory (UI_DESIGN_SYSTEM.md §5) with states: CfScaffold, CfActivityBar/CfNavRail, CfTabStrip, CfPanel/CfDivider, CfBottomSheet (3-stop), CfButton, CfIconButton, CfInput/CfSearchField, CfListItem/CfTreeTile, CfChip, CfBanner, CfEmptyState, CfDialog, CfSnackbar, CfSymbolToolbar (editor+terminal presets), CfStatusStrip, CfCommandPalette (skeleton: open/close, fuzzy filter over registered demo commands), CfSettingsTile |
| 3.5 | Icons | Material Symbols subset bundled + 20 file-type glyphs + fallback; no network icon fonts |
| 3.6 | Goldens | golden tests per component × theme × breakpoint; deterministic font loading in tests; CI golden job |

**Exit:** component gallery screen (debug route `/dev/gallery`) renders everything; goldens green; contrast gate green.

### W4 — Adaptive workbench shell (2 sessions)
| # | Task | Detail |
|---|---|---|
| 4.1 | Layout engine | `WorkbenchLayout` model + breakpoint resolver (compact <600 / medium 600–840 / expanded >840); orientation handling; layout state object (active activity, panel sizes, sheet stop) |
| 4.2 | Phone portrait | editor-first scaffold; bottom activity bar: Explorer · Search · Run · Git · More(Extensions, Settings); explorer as full-height sheet; terminal as 3-stop bottom sheet; status strip |
| 4.3 | Phone landscape | icon rail left; editor center; collapsible terminal panel; scrolling tab strip |
| 4.4 | Tablet | persistent explorer sidebar; docked resizable terminal panel (drag dividers); editor group center; status strip expanded |
| 4.5 | Command palette | Ctrl/Cmd+Shift+P (hardware) + status-strip button; registers commands via `CommandRegistry` (core); Phase 1 commands: navigation, theme toggle, about — real actions only |
| 4.6 | Gesture/IME behavior | sheet drags vs. content scroll arena rules; keyboard insets animate panels; hardware keyboard collapses symbol toolbar |

**Exit:** layout widget tests at 6 surface sizes × 2 orientations, zero overflow; navigation ≤ 2 taps to every destination.

### W5 — MVP screens (1–2 sessions)
| # | Screen | Phase 1 behavior (honest scope) |
|---|---|---|
| 5.1 | **Home** | recent-workspaces list from fake `DemoWorkspace` (labeled "Demo"), empty state with primary action "Open folder" → **disabled-with-tooltip** ("Arrives in Phase 3") + "Explore demo workspace" → workbench; brand header, version footer |
| 5.2 | **Workspace** | tab strip with 2 demo tabs (dirty-dot/close functional on demo docs); editor placeholder surface: styled code specimen (real syntax-colored static text, not an editor) + banner "Editor engine arrives in Phase 2"; explorer placeholder: fake tree (expand/collapse real, file ops disabled-with-tooltip); terminal placeholder: panel with "Terminal arrives in Phase 4–5" + extra-keys row demo (keys insert nothing, visibly inert) |
| 5.3 | **Search / Git / Extensions / Run** | activity destinations with designed empty states + one-line phase roadmap copy; no fake controls |
| 5.4 | **Settings** | fully functional: theme mode (system/dark/light), editor font size (live preview specimen), reduced motion toggle, symbol toolbar preset picker (preview), About (version, licenses screen via `LicenseRegistry`, docs links); persisted via SettingsService |
| 5.5 | First-run | one-time welcome sheet: what CodeForge is, what works today, what's next — dismiss persisted |

**Exit:** every MVP 1 screen present, polished, honest; widget tests per screen; no dead-end navigation.

### W6 — State restoration (1 session)
| # | Task | Detail |
|---|---|---|
| 6.1 | Shell state envelope | versioned JSON (`schemaVersion: 1`) in shared_preferences: last route/activity, layout sizes, sheet stop, theme, welcome-seen |
| 6.2 | Save/restore | save on lifecycle pause + debounce on change; restore in bootstrap before first frame (no flash); corrupt envelope → defaults + logged warning, never crash |
| 6.3 | Process-death test | integration test: set state → kill → relaunch → assert restored (G5) |

**Exit:** G5 green; envelope migration hook in place for Phase 2 (Drift takes over structured state then).

### W7 — Testing & quality (continuous + 1 consolidation session)
- Unit: core (Result/Failure, logger redaction, settings store, layout resolver, command registry, state envelope codec) — target ≥ 90% on core/services-fakes.
- Widget: navigation flows, adaptive layouts, theme switching, component states, empty states, tooltip-disabled actions.
- Goldens: W3/W4 suites; CI diff artifacts on failure.
- Integration (`integration_test/`, CI emulator API 36 x86_64): launch → welcome → demo workspace → navigate all activities → settings change → kill/restore smoke; frame-timing collection during navigation; `am start -W` cold-start capture.
- A11y: semantics audit test (labels, 48 dp targets), text-scale 1.3 sweep, contrast gate; manual TalkBack spot-check checklist in exit report.

### W8 — Documentation & phase exit (0.5 session)
- Update README status, CHANGELOG, TECH_STACK (proven pins), UI_DESIGN_SYSTEM (any token amendments as v1.1 diff), ARCHITECTURE (as-built deltas).
- Write `docs/phases/PHASE_1_REPORT.md`: completed functionality, files, dependencies, **tests executed with run ids**, build artifacts + hashes, measured perf numbers, known limitations, next-phase readiness.
- Phase-gate workflow run; owner review.

## 4. Acceptance criteria (measurable gates)

| Gate | Criterion | Evidence |
|---|---|---|
| **G1 Build** | `ci.yml` green: analyze, format, import-lint, tests, debug APK artifact | run id + APK hash |
| **G2 Navigation** | all destinations ≤ 2 taps; back/predictive back correct; deep links `/workspace`, `/settings` resolve | widget + integration tests |
| **G3 Adaptive** | goldens at 360×800, 412×915, 800×1280, 1280×800 (+landscape pairs): **zero overflow errors**; text scale 1.3 no clipping | golden suite + overflow assertions |
| **G4 Theme** | dark/light/system switch works, persists across restart; **all text token pairs ≥ 4.5:1** (automated) | contrast test + persistence test |
| **G5 Restoration** | process death → relaunch restores activity, layout, theme, welcome-seen | integration test |
| **G6 Performance** | cold start ≤ 1.5 s on CI emulator (median of 10, `am start -W`); nav frame profile ≤ 5% frames > 32 ms; debug APK size recorded (baseline, no budget yet) | perf artifact JSON |
| **G7 Accessibility** | semantics labels on all interactive elements; targets ≥ 48 dp; TalkBack spot-check pass | a11y tests + manual checklist |
| **G8 Docs** | docs synchronized; PHASE_1_REPORT.md with run ids; CHANGELOG updated | review |

**Definition of done (spec §12):** all gates green with cited evidence; no critical issues open; owner accepts the report. Only then Phase 2 starts.

## 5. Out of scope (guardrails against creep)

Real editor engine (P2) · real file I/O / SAF (P3) · runtime/PTY/terminal execution (P4–5) · LSP (P6) · Git (P7) · extensions (P8) · Drift (P2) · vendoring t1 modules (P4) · license decision (owner, by P4) · iOS/desktop · flavors/pack splits (P4) · release signing (P4+).

## 6. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Flutter 3.47 template pins vs t1's AGP/Gradle differ | W1 rule: template defaults first, CI proves; reconcile toward t1 pins only when Phase 4 vendoring needs it |
| Golden-test flakiness (fonts, rendering) | bundled fonts loaded in test bootstrap; fixed surface sizes; `--update-goldens` only in dedicated PRs |
| CI emulator variance (TCG, no KVM) | relative budgets on CI (regression %), absolute budgets later on arm64 hardware; generous adb timeouts (t1 lesson) |
| Placeholder UX feels "fake" | design effort on empty states + honest copy; demo data labeled; disabled actions explain themselves |
| Scope creep from excitement | §5 list enforced in review; new ideas → ROADMAP backlog, not Phase 1 |
| Sandbox cannot build | CI is the authority (ADR-0009); every W1+ claim carries a run id |

## 7. Deliverables summary

Installable debug APK (CI artifact) · `app/` Flutter codebase with core+design system+shell+screens · fakes & contract tests · `ci.yml` + templates · golden/perf/a11y suites · updated docs + `PHASE_1_REPORT.md` · proven dependency pins.

**Estimated total: 8–10 work-sessions.** First user-visible milestone (navigable shell on a device via CI APK) lands after W4.
