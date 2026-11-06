# Phase 1 Report — Flutter Foundation & Design System

**Status:** **Accepted by the owner on 2026-11-06**, with the phone checks parked (see below) · **Date:** 2026-11-06 · **Branch:** `arena/f57c33ee-codeforge`
**Plan:** [PHASE_1_PLAN.md](PHASE_1_PLAN.md) · **Spec:** §8 Phase 1 · **Rule:** every claim below cites a CI run or an evidence commit. Where something was not measured or not built, this report says so.

---

## 1. Summary

Phase 1 delivers a real, compilable Android app, built and tested only by GitHub Actions. It's a polished, navigable, adaptive IDE shell (home, workbench, command palette, settings) on the "Forge" design system, with dark and light themes and state that survives process death. Its placeholders are honest: no control pretends to work. Underneath sits the engineering skeleton later phases plug into: service contracts with in-memory fakes, Riverpod controllers, GoRouter, an error zone and logging core, and CI quality gates plus an emulator phase gate that commit their own evidence.

| Gate | Result | Evidence (details in §4) |
|---|---|---|
| G1 Build | ✅ met | CI 42147979279 green on the final tree; debug APK hash in §6 |
| G2 Navigation | ✅ met | tap-only reachability, deep-link and system-back tests (CI 42147979279) |
| G3 Adaptive | ✅ met | goldens at six sizes; zero overflow at every gate size and terminal stop, at 1.3× text and with the soft keyboard up (CI 42147979279) |
| G4 Themes | ✅ met | persisted theme + automated WCAG contrast gate (CI 42147979279) |
| G5 Restore | ✅ met | emulator process-death restore pair, first attempt (gates 42106688923, 42109146834, 42147046358) |
| G6 Performance | ◐ **partially met** | cold start **1148 ms** median vs 1500 ms budget, APK sizes in `perf.json`; **navigation frame profile not measured** (§7) |
| G7 Accessibility | ◐ automated part met | tap-target, label and text-scale suites green; **TalkBack spot-check is an owner action** (§8) |
| G8 Docs | ✅ met | this report, CHANGELOG, README, ROADMAP and as-built doc sync |

**The emulator gate earned its place.** On `915ec70` it failed `restore_a` with a genuine 79 px layout overflow. Gboard opened while the test typed into the command palette, and the workbench sized its terminal from the screen height instead of the space the keyboard left. No widget test had ever raised a keyboard. `dcae041` fixes the layouts and adds a 13-test soft-keyboard suite, and the gate passed again on the fixed tree (§9.3).

**Owner decisions (2026-11-06):** Phase 1 is accepted, with G6 as partially met. The phone checks (the §8 TalkBack checklist and the navigation frame profile on hardware) are **parked** until the owner has time for them. They are tracked in [ROADMAP.md](../ROADMAP.md) under "Parked owner checks".

## 2. Evidence index

All runs are on `Skill-center/CodeForge-`, branch `arena/f57c33ee-codeforge`. `[bootstrap]` runs commit their diagnostics back (`app/ci-results/*.txt`), and gate runs commit `app/ci-results/gate/`; see [BUILD_AND_RELEASE.md §2.1](../BUILD_AND_RELEASE.md).

| Run | Workflow | Head commit | Result | What it proves |
|---|---|---|---|---|
| **42147979279** | CI `[bootstrap]` | `79773c2` (final tree) | ✅ | **final tree:** 236 tests pass, including tap-only G2 reachability; analyze, format, import lint, license gate and lockfile clean; coverage 1616/1886 lines (85.7 %); debug APK + SHA-256 — diagnostics `17da199` |
| **42147046358** | Phase gate | `dcae041` (`lib/` and `integration_test/` identical to the final tree) | ✅ | **final app:** KVM emulator; smoke + restore pair on attempt 1; cold start 1148 ms — evidence `d47db37` |
| 42147046378 | CI `[bootstrap]` | `dcae041` | ✅ | keyboard fix: 234/234 tests including the 13-test keyboard suite; workspace goldens re-baselined (`77acb89`) — diagnostics `30750f5` |
| 42111729217 | CI `[bootstrap]` | `93ddaa4` | ✅ | settings sub-page checks prove the page opened: 221/221, and the off-screen tap warning logged by every run since the accessibility suite landed (`aad9508`) is gone — diagnostics `8068b64` |
| 42110297015 | Phase gate | `915ec70` | ❌ real defect | `restore_a` hit a 79 px editor overflow while Gboard was up; correctly not retried (no infrastructure signature); cold start still sampled (1001 ms) — evidence `9f333f2`; fixed in `dcae041` (§9.3) |
| 42110296990 | CI `[bootstrap]` | `915ec70` | ✅ | code-font ligatures off + typography tests: 221/221; core 91.4 %, services 91.9 % — goldens `a4c0ea4`, diagnostics `fe0731d` |
| 42109146834 | Phase gate | `e452eb2` | ✅ | second consecutive KVM pass: all three integration tests on attempt 1, cold start 1112 ms — evidence `e0e8ff5` |
| 42109146815 | CI `[bootstrap]` | `e452eb2` | ✅ | 215/215; first per-layer coverage — diagnostics `8f45205` |
| 42107593393 | CI `[bootstrap]` | `d7cd1c7` | ✅ | G2 back/deep-link fix: 215/215 including 7 navigation tests — diagnostics `1bf9f58` |
| **42106688923** | Phase gate | `6ee918d` | ✅ | **first valid G5/G6 run:** KVM, boot 60 s, all three integration tests on attempt 1, cold start 1124 ms — evidence `0a5e124` |
| 42106688928 | CI `[bootstrap]` | `6ee918d` | ✅ | G7 fixes: 208/208 including the accessibility suite and new screen goldens — goldens `25ed537`, diagnostics `ef4b14a` |
| 42066068283 | Phase gate | `dd01194` | ✅ gate | first passing restore pair (software emulation) — evidence `7ebd6e2` |
| 42034950382 · 42036581857 | CI | `3651ff0` · `9ee3d82` | ✅ | first green CI: 162/162, APK built (W1 exit) |

Gate runs 1–3 and 5–7 (42036581849, 42040878638, 42049568423, 42077624589, 42085727694, 42092210698) failed or lost their evidence, and gate 10 (42110297015) failed on a real defect. The causes are in §9.3. None of their numbers are used here, except gate 10's cold-start median, which is quoted as history.

## 3. What was built

| Workstream | Delivered | Not delivered / changed (see §9) |
|---|---|---|
| **W1 Scaffold + CI** | `app/` (`dev.codeforge.app`), Flutter 3.47.9 pinned, `pubspec.lock` committed; compile/target 36, minSdk 26; release manifest has no permissions (INTERNET is debug-only); predictive back enabled; adaptive icon; `.editorconfig`, strict `analysis_options.yaml`, import-boundary lint, license gate; `ci.yml`; PR template + issue templates | Android pins follow the template (AGP 9.1.0 / Gradle 9.3.1 / Kotlin 2.4.0 / NDK 28.2), as the plan's W1 rule says |
| **W2 Application core** | `Failure` taxonomy + `Result<T>`; error zone (`runZonedGuarded`, `FlutterError.onError`, `PlatformDispatcher.onError`); structured logger with an in-memory ring buffer and redaction; GoRouter (`/`, `/workspace`, `/settings`, `/settings/appearance`, `/settings/about`) with unknown-route → home and system/predictive back handling; lifecycle flush on pause; six service contracts (File, Editor, Terminal, Runtime, Git, Search) + settings/shell stores, with deterministic in-memory fakes | no `ProviderObserver`, no LogViewer screen; on-disk log sink deferred to Phase 2 storage; no keyboard-visibility / hardware-keyboard providers; workbench is a plain route, not a `StatefulShellRoute` |
| **W3 Design system** | colour, spacing, radius, motion and typography tokens; Inter + JetBrains Mono bundled with OFL texts; dark/light `ThemeData`; contrast gate; components: buttons, icon buttons, banner, empty state, status chip, file-tree row, settings tiles, activity bar, nav rail, tab strip, status strip, symbol toolbar; debug gallery (`/settings/gallery`) | Material Icons with a per-extension mapping instead of a Material Symbols subset + 20 bespoke file-type glyphs; no dialog/snackbar/input/panel components yet (theme-styled Material widgets are used) |
| **W4 Adaptive shell** | breakpoints (compact < 600, medium 600–840, expanded > 840) by surface, not device; phone portrait (bottom activity bar, draggable explorer sheet, terminal panel laid out at four stops — closed/peek/half/full — toggled closed ↔ half from the top bar and closable from its header); landscape rail; tablet sidebar with draggable dividers (sidebar 200–420, terminal 120–480); command palette (Ctrl+Shift+P + top-bar button) with real commands only; keyboard-safe layouts (the terminal yields to the soft keyboard; the editor pane, rail and palette never overflow) | the phone activity bar has five direct items (Files, Search, Run, Git, Extensions) instead of four + "More"; Settings is reached from home, the palette or the tablet rail. The terminal is not a draggable sheet, and no control selects peek or full yet (plan 4.2). IME-driven editor behaviour (symbol toolbar floating above the keyboard, hardware-keyboard detection) is Phase 2 work |
| **W5 Screens** | home (demo workspace labelled "Demo", "Open Folder…" disabled with its Phase 3 note); workspace (demo tabs opened from the tree, `main.js` on first entry, with real activate/close and a dirty marker; syntax-coloured read-only specimen, topped by the read-only notice and the demo edit/save actions; expandable demo tree; terminal placeholder); Search/Run/Git/Extensions empty states; settings fully functional (theme, editor font 10–24, reduced motion, toolbar preset, About with licences); first-run welcome sheet | no version footer on home (the version is in Settings → About) |
| **W6 Restoration** | versioned envelopes `codeforge.settings.v1` / `codeforge.shell.v1` (schemaVersion 1); tolerant decode (corrupt or future payloads → defaults, per-field fallback); 400 ms debounce, flushed on pause and dispose; restored before the first frame; emulator process-death test | open tabs are not persisted until the editor exists (Phase 2, Drift) |
| **W7 Tests & quality** | 236 host tests in 19 files + 3 integration tests (§5); per-layer coverage | CI does not upload golden diff images on failure |
| **W8 Docs** | this report; README, CHANGELOG, ROADMAP, TECH_STACK, ARCHITECTURE (§2.4 as built), BUILD_AND_RELEASE (§2.1 evidence channel), TESTING (§1.1), UI_DESIGN_SYSTEM v1.1 | — |

**Size:** 39 Dart files in `lib/` (5,409 lines); 19 host test files + 3 integration tests; 4 CI scripts under `app/tool/ci/`.

## 4. Gate-by-gate

| Gate | Criterion (plan §4) | Result | Evidence |
|---|---|---|---|
| **G1** | CI green; run id; APK hash | ✅ | CI 42147979279 green on `79773c2`; debug APK 169,812,582 B, sha256 `9525444c251fcdc90f1e5683f1c3b869fc05d1d6dfc81af8daacd771c266fa6b` (`app/ci-results/apk.txt`); artifact `codeforge-debug-apk` on that run |
| **G2** | every destination ≤ 2 taps; back/predictive back correct; deep links `/workspace`, `/settings` resolve | ✅ | `app_flow_test` proves each path by taps alone. From home, every destination is ≤ 2 taps: workspace 1, settings 1, Appearance and About 2. From the workbench, settings takes 2 taps on a phone (home, then settings) and 1 on a tablet (the rail). About, a Settings sub-page, is 3 taps from the workbench. `navigation_test` drives the engine's own `pushRouteInformation` / `popRoute` messages: deep links resolve (including a nested page); unknown locations land on home; back from `/workspace` and `/settings` returns home without exiting; back on a nested page pops to its parent; a dialog closes first; back on home exits. Predictive back commits through the same pop path. |
| **G3** | 360×800, 412×915, 800×1280, 1280×800 + landscape pairs; zero overflow; 1.3× text | ✅ | `workbench_layout_test`: no overflow at every gate size and terminal stop. `keyboard_insets_test`: a raised soft keyboard at every gate size × terminal stop × 1.0/1.3 text, the palette at every size, and the compact editor's 191 dp floor (added after gate 10 caught a real overflow). `screens_golden_test`: home and workspace at 360×800, 800×360, 412×915, 915×412, 800×1280 and 1280×800 in dark, light at 412×915 and 1280×800, settings at 412×915. `accessibility_test`: 1.3× sweep including scrolled settings and the palette; since `93ddaa4` its sub-page checks first prove the page opened |
| **G4** | theme switch persists; text contrast ≥ 4.5:1, automated | ✅ | `contrast_test` (every text/background pair and syntax colour, both themes); settings store and controller tests (write-through, restore across containers); the restore pair asserts the light theme after process death |
| **G5** | process-death restore | ✅ | Gate evidence (`app/ci-results/gate/`): `restore_a` sets the light theme, `/workspace` and terminal half → `prefs_after_a.txt` shows both envelopes on disk → `am force-stop` → `process_after_kill.txt`: "no dev.codeforge.app process … process death confirmed" → `restore_b` relaunches and asserts route, theme and terminal stop. Passed on attempt 1 in 42106688923, 42109146834 and 42147046358. Gate 42110297015 failed inside `restore_a` on a G3 defect (keyboard overflow), not a restore defect (§9.3) |
| **G6** | cold start ≤ 1.5 s (median of 10); nav frames ≤ 5 % over 32 ms; APK size in perf JSON | ◐ | cold start median **1148 ms** (42147046358; earlier KVM gates: 1124, 1112 and 1001 ms); APK sizes in `perf.json`. **Frame profile not measured** — see §7 |
| **G7** | labels on all interactive elements; ≥ 48 dp; TalkBack pass | ◐ | `accessibility_test` at the five gate sizes: Flutter's Android tap-target and labeled-tap-target guidelines, plus a direct sweep that every enabled ink target is ≥ 48×48 dp. Chrome bars are 48 dp touch rows + 1 px hairline. TalkBack: §8, owner |
| **G8** | report + CHANGELOG + docs | ✅ | this commit |

## 5. Tests

The CI totals are authoritative (`app/ci-results/test.txt`: "+236: All tests passed!").

| Suite | Files | Proves |
|---|---|---|
| Unit — core | `test/core/{breakpoints,command_registry,failure,logger}_test.dart` | surface-based breakpoints, command registry, failure/result types, logger redaction and ring buffer |
| Unit — services | `test/services/{settings_store,shell_state,fakes}_test.dart` | envelope round-trip, corrupt and future payloads → defaults, per-field fallback, clamping, restart survival; fakes behave as contracts |
| Unit — application | `test/application/controllers_test.dart` | write-through, debounce + flush, restore across containers, restorable-route whitelist, tabs open/activate/close/dirty |
| Design system | `test/design_system/{contrast,typography}_test.dart` | WCAG ≥ 4.5:1 for every pair in both themes; type scale, code font with ligatures off, tabular status figures |
| Widget | `test/widget/{app_flow,navigation,palette,editor_tabs,workbench_layout}_test.dart` | first run, tap-only ≤ 2 reachability, deep links and back, palette, tabs, adaptive layouts without overflow |
| Soft keyboard | `test/widget/keyboard_insets_test.dart` | a raised keyboard at every gate size × terminal stop × 1.0/1.3 text; the palette at every size; the compact editor keeps its 191 dp floor |
| Accessibility | `test/widget/accessibility_test.dart` | tap-target and label guidelines, 48 dp ink sweep, 1.3× text at all gate sizes |
| Golden | `test/goldens/{gallery,screens}_golden_test.dart` | design-system gallery (dark/light) and screens at six sizes; baselines are generated on the Linux runner |
| Integration (emulator) | `integration_test/{smoke,restore_a,restore_b}_test.dart` | welcome → demo → tabs → terminal → settings; process-death restore pair |

**Coverage** (final tree, 42147979279): 1616/1886 lines (85.7 %). Per layer: core 85/93 (91.4 %), services 217/236 (91.9 %), design_system 478/512 (93.4 %), application 156/189 (82.5 %), features 658/829 (79.4 %), app root 22/27 (81.5 %). The plan's W7 target (≥ 90 % on core and the service fakes) is **met**.

## 6. Build artifacts

| Artifact | Size | SHA-256 | Where |
|---|---|---|---|
| Debug APK (final tree) | 169,812,582 B | `9525444c251fcdc90f1e5683f1c3b869fc05d1d6dfc81af8daacd771c266fa6b` | artifact `codeforge-debug-apk` on CI 42147979279 (90-day retention) |
| Release APK, x86_64, debug-signed (gate-only, for cold start) | 21,218,206 B | not recorded (not a distributable) | built inside gate 42147046358 |
| Coverage `lcov.info` · gate results | — | — | artifacts `coverage` (CI) and `phase-gate-results` (gate) |

Debug APKs are not bit-reproducible across CI builds. Identical `lib/` trees produced `dbf518cd…` (42107593393) and `14a67dbd…` (42109146815), both 169,807,686 B, `3ee4c4dc…` (42110296990) and `e573ebda…` (42111729217), both 169,807,742 B, and `303cb83b…` (42147046378) and `9525444c…` (42147979279), both 169,812,582 B. Each hash is therefore quoted with its run. Reproducible release builds are a Phase 10 concern (BUILD_AND_RELEASE §1.5).

No binary is published. The licence is still TBD (ADR-0011), and the BUILD_AND_RELEASE §5 licence gate blocks releases until it's resolved.

## 7. Performance (G6)

| Metric | Value | Budget | Notes |
|---|---|---|---|
| Cold start, median of 10 | **1148 ms** (42147046358) | ≤ 1500 ms | `am force-stop` then `am start -W`, `TotalTime`; every sample `LaunchState: COLD`, `Status: ok` |
| Samples (42147046358) | 1065, 1148, 1148, 1208, 1108, 1414, 1571, 1045, 1111, 1331 ms | — | `app/ci-results/gate/coldstart.txt` |
| Earlier medians, same method | 1124 ms (42106688923) · 1112 ms (42109146834) · 1001 ms (42110297015) | — | single samples vary: gate 9 had one at 1614 ms; the budget applies to the median |
| Release x86_64 APK | 21,218,206 B | — | `perf.json`; the same size in every KVM gate (8–11), although each run builds it fresh from its own commit |
| Debug APK | 169,812,582 B | — | `perf.json` (debug build of the gate run) |
| Navigation frames > 32 ms | **not measured** | ≤ 5 % | see below |

**Environment:** API 36 `google_apis` x86_64 emulator on a GitHub-hosted runner (4 vCPU, 16 GB), **KVM-accelerated** (`host.txt`: "KVM (version 12) is installed and usable"), software GPU (SwiftShader), boot ≈ 60 s. This is indicative, not a device measurement: the CPU is a fast x86 host and the GPU is software. The arm64 hardware measurement belongs to the Phase 4 device lab, or earlier on the owner's phone.

**Why the frame profile is missing:** meaningful frame timing needs a profile or release build, and Flutter's tooling refuses profile mode on emulators. Frame times rendered by a software GPU would not mean anything against a 32 ms budget anyway. The plan anticipated this (risk table: software emulation → relative budgets). **Proposal:** measure navigation frames in profile mode on hardware at the start of Phase 2 (the editor makes frame time matter most), and treat it as a Phase 2 entry check.

## 8. Device checklist — TalkBack spot-check (owner, parked 2026-11-06)

Automated coverage is in §4 (G7). Run the manual check on a phone with TalkBack on, using the APK from §6:

1. **Home:** the welcome sheet is read in order; "Explore Demo Workspace" is announced as a button; "Open Folder…" is announced as disabled with its Phase 3 note.
2. **Workbench, phone portrait:** each activity-bar item announces its name and selected state; top-bar buttons (home, palette, terminal) are named; each tab and its close button announce the file name.
3. **Explorer sheet:** rows announce name and expanded/collapsed state; double-tap toggles.
4. **Terminal panel:** the header's title and close button are named; the placeholder text is readable.
5. **Command palette:** the input is labelled, results are announced, and activation runs the command.
6. **Settings:** the theme selector announces the selected option; the font-size slider announces its value; the reduced-motion switch announces its state; About → licences is reachable.
7. **Back:** from the workspace or settings, back returns home; from home, back leaves the app.
8. **System font size 130 % and 200 %:** no clipped or overlapping labels on home, workspace and settings.
9. **Landscape and tablet:** nav-rail items announce name and selected state.
10. **Soft keyboard (TalkBack off is fine):** with the terminal half-open, open the palette so the keyboard appears; the workbench behind it stays intact, with no clipped or striped panes.

Record the device, Android version, build hash and the date. Any failure becomes a Phase 2 entry item.

## 9. Deviations and known limitations

### 9.1 Deviations from the plan (accepted under its own rules, or documented as built)
- **Android pins = Flutter 3.47.9 template:** AGP 9.1.0, Gradle 9.3.1, Kotlin 2.4.0, NDK 28.2.13676358, rather than t1's AGP 8.13.2 / Gradle 9.2.1 / NDK 27.2 (plan W1 rule; TECH_STACK §1).
- **Skia instead of Impeller.** Impeller's OpenGLES backend never sized its surface on the software-GL CI emulator, so it's disabled in the manifest. Re-enabling it needs hardware validation (TECH_STACK §1).
- **Emulator gate:** `google_apis` + KVM replaced `aosp_atd` + software emulation (TECH_STACK §6, BUILD_AND_RELEASE §3).
- **Evidence is committed back to the branch:** BUILD_AND_RELEASE principle 4 is applied with this one exception, because the authoring sandbox cannot reach GitHub's log and artifact hosts (§2.1 there).
- **Structure:** an app-level `lib/application/` instead of per-feature application folders + `routing/`; flat feature folders; the workbench is not a `StatefulShellRoute` (ARCHITECTURE §2.4).

### 9.2 Known limitations, carried forward
| Item | Impact | Where it goes |
|---|---|---|
| G6 navigation frame profile not measured | G6 partially met | Phase 2 entry check, profile mode on hardware |
| Cold start measured on an emulator | indicative only | Phase 4 device lab, or the owner's phone earlier |
| TalkBack spot-check not yet run | G7 manual part open | owner, §8 |
| Symbol-toolbar keys are disabled in Phase 1 and only 36 dp tall (≥ 40 dp wide) | will fail the 48 dp rule once enabled | Phase 2: resize when the editor enables them |
| Terminal peek/full stops have no control, and the panel doesn't drag between stops | phones get closed and half only | Phase 5, with the real terminal (all four stops are already laid out and overflow-tested) |
| Status chips in the 24 dp status strip | display-only by design (not tap targets) | revisit if they become interactive |
| Debug gallery excluded from the G7 sweep (24 dp demo chips) | debug builds only | — |
| Features import service-layer value types, and three call the `FileService` provider directly | weaker layering than ARCHITECTURE rule 1 | Phase 2, before real file I/O (ARCHITECTURE §2.4) |
| Not built from the plan: `ProviderObserver`, LogViewer, on-disk log sink, keyboard/hardware-keyboard providers, Material Symbols subset + bespoke file glyphs, dialog/snackbar/input components, golden diff upload | none of them is gate-relevant | Phase 2 (logging sink, keyboard/IME, components), Phase 3 (file glyphs) |
| Licence TBD (ADR-0011) | no binary release | owner decision |

### 9.3 Gate history (why early numbers are not used)
- **Gate 1:** the `aosp_atd` image's stripped services crashed and Impeller never sized its surface → `google_apis` + Skia.
- **Gate 2:** `flutter test` uninstalls the app between runs, which wiped the restore state → `--no-uninstall` and a prefs dump.
- **Gate 3** passed, but its evidence commit-back failed. **Gate 5** (cold start moved first) failed, and its commit-back failed too. **Gate 6** failed (see next point).
- **Gates 1–6 never used KVM.** The KVM probe raced the asynchronous udev trigger and fell back to software emulation (boots of 273–937 s, framework watchdog restarts). The fix settles udev before probing, records the acceleration actually used, and checks framework readiness with three probes.
- **Gate 7:** the emulator kept writing into the workspace after an un-awaited stop, so the evidence rebase refused a dirty tree and the evidence was lost. The fix keeps emulator logs outside the workspace, reaps the emulator before collecting, uses a reset-based commit-back, and publishes check-run annotations as a second channel.
- **Gate 4 (42066068283)** was the first passing restore pair, but under software emulation, so only its G5 result counts. **42106688923** is the first run with valid G5 *and* G6 evidence.
- **Gate 10 (42110297015)** failed for a real reason, which is what the gate is for. `restore_a` typed into the palette with the terminal half-open. On the `google_apis` image Gboard opened and the Scaffold shrank the body, but the compact layout sized its terminal from the screen height, so the editor was squeezed until its fixed chrome overflowed by 79 px. Inside a Scaffold body `MediaQuery.viewInsets` reads 0, so only layout constraints reveal the keyboard. (Flutter prints the render-object dump lazily, which is why the logged `h=346.8` is the height after the keyboard closed.) The failure matched no infrastructure signature, so the gate correctly did not retry it, and its evidence commit-back worked on a failing run (`9f333f2`). Gates 8 and 9 passed the same test, most likely because the palette closed before the keyboard's insets reached the app. `dcae041` sizes the terminal from the body's real constraints, makes the editor pane, nav rail and palette keyboard-safe, and adds `keyboard_insets_test`. **Gate 11 (42147046358)** then passed on the fixed tree: smoke and the restore pair on attempt 1, no overflow in any test log, cold start 1148 ms (evidence `d47db37`).

## 10. Next-phase readiness (Phase 2 — Workbench & editor)

**Ready:** editor pane and tab controller seams; `EditorService` / `FileService` contracts with fakes; design tokens and chrome metrics frozen (UI_DESIGN_SYSTEM v1.1, contrast-gated); keyboard-safe layout rules (panels size from the body's real constraints) for the editor's IME work to build on; CI with commit-back diagnostics; a KVM emulator gate that runs integration tests and measures cold start in about 13 minutes; restore machinery ready to extend to tabs.

**Phase 2 entry items:** owner acceptance of Phase 1 (done 2026-11-06); a navigation frame profile on hardware (parked with the phone checks); ADR-0004 decided with numbers (the CM6 gate); `editor/` workspace pins (Node 24 LTS, esbuild 0.28.2, TypeScript 5.9.x, CodeMirror 6); routing feature → service access through controllers; 48 dp symbol-toolbar keys; on-disk log sink with storage.
