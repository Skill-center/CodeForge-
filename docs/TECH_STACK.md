# Technology Stack & Dependency Decisions

**Verified:** 2026-11-05 against pub tags (git ls-remote), npm registry, and GitHub releases — not from memory. Pins are finalized in Phase 1 W1 when CI proves them; every version below was checked to exist today.

**Phase 1 update (2026-11-06):** the Flutter, Dart-package and Android build rows below are now **as built and CI-proven** — every Phase 1 CI run builds with exactly these pins (run ids in [phases/PHASE_1_REPORT.md](phases/PHASE_1_REPORT.md)). Per the plan's W1 rule ("template defaults win over aspirational pins"), the Android toolchain follows the Flutter 3.47.9 template rather than t1's older AGP 8.13.2 / Gradle 9.2.1 / NDK 27.2; reconciling toward t1 is a Phase 4 task, only if vendoring the runtime modules requires it.

**Phase 2 update (2026-11-10):** the editor and persistence rows below are now **as built and CI-proven**: the WebView plugin, CodeMirror 6, the editor toolchain, Drift and SQLite (run ids in [phases/PHASE_2_REPORT.md](phases/PHASE_2_REPORT.md)). ADR-0004 chose CodeMirror 6 over Monaco. Every npm version is an exact pin in `editor/package.json`, installed with `npm ci` from the committed lockfile.

**Phase 3 update (2026-11-12):** Pigeon (the storage broker's typed API), schema v2, the Kotlin unit tests in CI and the renderer (Impeller since W6) are **as built and CI-proven** (run ids in [phases/PHASE_3_REPORT.md](phases/PHASE_3_REPORT.md)). Phase 3 added two dependencies, both for development: Pigeon 29.2.0 and, for the Kotlin tests, JUnit 4.13.2. It added two fonts: a subset of Material Symbols Rounded (Apache-2.0) and CodeForge's own file glyphs (UI_DESIGN_SYSTEM). Phase 3 ended on Flutter 3.47.9. At acceptance (2026-11-12) the owner decided to move to 3.50.0, which needs AGP 9.1.1 and KGP 2.4.10 or later, with both plugins upgraded together (BUILD_AND_RELEASE §3).

**Phase 4 update (2026-11-13, W1; the runtime's rows in §3 as built at Phase 4's end, 2026-11-18):** Flutter **3.50.0** with the Android pins of its template (Kotlin's Gradle plugin 2.4.20, Gradle 9.5.0, and AGP 9.3.3, the 9.3 line's latest patch rather than the template's 9.3.1, whose lint crashes on JDK 17 in release builds), upgraded together as the owner decided, and `package:material_ui` 1.10.0 in place of the framework's Material library, which 3.50 deprecates, are **as built and CI-proven**: CI 43373527631 (`+846: All tests passed!`, analysis clean, 230 files formatted with none changed, 44 Kotlin tests). All 87 files that imported the framework's Material moved by Flutter's own fix, and none of the 26 golden images changed. The workflows moved to the Node 24 majors of GitHub's actions in W1 as well (§6).

**Phase 5 update (2026-11-21, at its exit):** the terminal's four npm packages are **as built and CI-proven**: @xterm/xterm 6.0.0 with addon-fit 0.11.0 and addon-unicode11 0.9.0 since W3, and addon-webgl 0.19.0 since W6, each an exact pin in `editor/package.json` with AGENTS §5's justification (§2), all MIT and without dependencies of their own. The terminal page is 211.0 KiB gzipped against its 256 KiB budget. Phase 5 added no Dart package and no Android library. Its native code is CodeForge's own: the launcher's terminal mode (C, built with the pinned NDK) and the Kotlin host. Hybrid Composition++ (W6) is a setting of the Flutter engine already pinned (`io.flutter.embedding.android.EnableHcpp` in the manifest), not a dependency. Run ids are in [phases/PHASE_5_REPORT.md](phases/PHASE_5_REPORT.md).

---

## 1. Core stack (locked by spec + audit)

| Component | Choice | Verified version | Why |
|---|---|---|---|
| App framework | **Flutter** (stable) | **3.50.0** — as built (Phase 4 W1; 3.47.9 in Phases 1–3) | Spec mandate; single UI codebase, first-class Android embedding |
| UI language | Dart (bundled SDK) | ships with Flutter | — |
| Android host | **Kotlin** (+ vendored Java modules) | **2.4.20** — as built (Flutter 3.50.0 template; CI-proven; 2.4.0 until Phase 4 W1) | Spec; t1 modules are Java — Kotlin host interoperates natively on the JVM |
| Android Gradle Plugin | AGP | **9.3.3** — as built (Phase 4 W1: the 9.3 line's latest patch, above the 3.50.0 template's 9.3.1, whose lint crashes on JDK 17 in every release build, Google issue 522845800, fixed in 9.3.2; 9.1.0 before; `android.newDsl=false`, `android.builtInKotlin=false` keep the Flutter Gradle plugin on the classic DSL) | t1 proves 8.13.2; reconcile in Phase 4 only if vendoring needs it |
| Gradle | wrapper | **9.5.0** — as built (wrapper committed; 9.3.1 until Phase 4 W1) | Template default; AGP 9.3 needs 9.5.0 or later |
| JDK | Temurin | 17 | t1 CI standard; Flutter/AGP compatible |
| compileSdk / targetSdk | **36 / 36** | — | Spec + Play requirement (Aug 31 2026); sealed model makes it work |
| minSdk | **26** (owner choice) | — | ADR-0007 gate: t1 declares 29; verify or raise in Phase 4 |
| NDK | pinned | **28.2.13676358** — as built (`flutter.ndkVersion` of 3.47.9 and of 3.50.0); no first-party native code in Phase 1. **Phase 4 (W2–W3):** the same NDK builds the vendored `native/runtime-core` (its JNI libraries and the launcher, `libcodeforge-spawn.so`), stated in its build script because a library cannot read Flutter's value | Re-evaluated in Phase 4: t1's 27.2.12479018 is not needed. NDK r28 aligns to 16 KB pages by default, and t1's explicit linker flags (`-Wl,-z,max-page-size=16384`) are kept. CI checks the release APK: all 257 shipped userland objects and the 3 built here are 16 KB aligned (CI 44300179086) |
| Renderer | Flutter engine | **Impeller** since Phase 3 W6, Flutter's default (no `EnableImpeller` entry in the manifest); **Skia** in Phases 1–2 (`EnableImpeller=false`) | Phase 1 chose Skia because Impeller's OpenGLES backend never sized its surface on the software-GL CI emulator (gate run 1). Flutter 3.47 deprecates the opt-out. W6's gate run with Impeller (43238952262) passed every group on its OpenGLES backend, so Impeller stays (PHASE_3_PLAN W6); its cold start on the emulator, timed beside the same build on Skia, is in PHASE_3_PLAN *As built (W6)*. Impeller on a phone joins the exit session's checklist (W7) |
| State management | **Riverpod** | 3.4.3 | Compile-safe DI + reactive state; spec mandate; active maintenance |
| Material widgets | **material_ui** (flutter/packages, BSD-3-Clause) | 1.10.0 (Phase 4 W1) | Flutter 3.50 deprecates the framework's Material library, and analysis fails on the deprecation, so the app imports `package:material_ui` instead. The Flutter team's own package: the framework's Material code, frozen there since 3.44, developed here since (1.0.0 matched the frozen copy). Pure Dart, so no ABI or native-code concern; no network; it replaces the framework copy in the build rather than adding to it. Pinned at the version the lockfile already resolved for go_router 18.1.3, which imports it. Routes keep go_router's `NoTransitionPage` (built explicitly since W1). `analysis_options.yaml` enables `migrate_design_widgets`, so a new import of the framework's copy fails analysis |
| Navigation | **GoRouter** | 18.1.3 | Declarative, deep links, shell routes for workbench; Flutter team-maintained |
| Typed platform channels | **Pigeon** | 29.2.0 (dev dependency, Phase 3 W2) | Generates Dart+Kotlin contracts; no hand-rolled MethodChannel string maps. The storage broker's `StorageApi` (`app/pigeons/storage_api.dart`) is the first: CI generates `lib/services/files/native/storage_api.g.dart` and `StorageApi.g.kt` (`[bootstrap]` commits them) and fails when the committed copies are stale. Its methods answer through callbacks (`@asyncCallback`), so the generated Kotlin needs no coroutines library. Three small plain MethodChannels stay as they are: `dev.codeforge/paths` (Phase 2 W4), `dev.codeforge/keyboard` (W6) and `dev.codeforge/backup` (Phase 3 W1) |
| WebView | **webview_flutter** | 4.14.1 | Official plugin; Android WebView host for editor |
| WebView (Android) | webview_flutter_android | 4.14.1 | Pinned alongside: the editor host hardens the WebView through its Android-only API (file/content access off, debugging in debug builds only). It exposes no request interception and no `onRenderProcessGone` (see SECURITY.md §3) |
| Hashing | crypto | 3.0.8 | SHA-256 check of the bundled editor page against its manifest before it runs; it was already in the lockfile as a transitive dependency, now declared directly |
| Local DB | **Drift** (SQLite) | **2.35.3** — as built (Phase 2 W5) | Typed queries, migrations, reactive streams. Schema v1 held workspaces, open tabs and the hot-exit journal; v2 (Phase 3 W3, the first migration) adds each workspace's kind and place and its explorer view (ADR-0008). SQLite comes from the `sqlite3` package's build hook (3.9.0, a prebuilt, hash-checked library per ABI), so there is no `sqlite3_flutter_libs` and no NDK build. Codegen: drift_dev 2.35.2 and build_runner 2.17.1, dev dependencies that CI runs (BUILD_AND_RELEASE §2.1) |
| Preferences | shared_preferences | 2.5.6 | Settings only; structured state goes to Drift |
| Lints | flutter_lints | 6.0.0 | Baseline + custom import-boundary rules |
| Icons | **Material Symbols Rounded** (google/material-design-icons, Apache-2.0) | **2.978**, commit `10ecc14` (2026-10-23) — as built (Phase 3 W4) | UI_DESIGN_SYSTEM §6. `app/assets/fonts/MaterialSymbolsRounded.ttf` is a static instance (unfilled, grade 0, optical size 20, weight 400) holding only the 67 icons the app names in `lib/design_system/tokens/icons.dart` (Phase 5 W4 added Run's stop and replay): 14.9 KB, against 15.2 MB for the variable source. `app/tool/fonts/subset_symbols.py` (fontTools 4.68.0) rebuilds it from the checksummed source, byte for byte; the font's description and About → Bundled font licenses say it is modified. Flutter's own widgets still use Material Icons (`uses-material-design`) |
| File-type glyphs | CodeForge's own (`CfFileGlyphs`) | 1.000 — as built (Phase 3 W4) | 20 glyphs and a generic page, drawn as SVG paths on a 16 dp grid with a 1.5 px stroke in `app/tool/fonts/build_file_glyphs.py`, outlined by skia-pathops 0.8.0.post2 into a 5.6 KB font; letters are drawn, not typeset. `icons_test.dart` checks both fonts against the code that names their codepoints |

## 2. Editor & terminal frontend

| Component | Choice | Verified version | Notes |
|---|---|---|---|
| Editor engine | **CodeMirror 6** (chosen: ADR-0004 Accepted 2026-11-06) | @codemirror/view **6.43.15**, state **6.7.6**, commands 6.11.1, language 6.13.1, search 6.7.2, autocomplete 6.20.4, @lezer/highlight 1.2.5, and the language packages for JavaScript 6.2.5, Python 6.2.1, JSON 6.0.2, HTML 6.4.12, CSS 6.3.1 and Markdown 6.5.2 | Mobile-native selection and IME, modular. As built, the shipped page with all of it is 285.1 KiB gzipped (budget 1.5 MB). It was chosen over Monaco on the emulator gate and the owner's low-end phone (PHASE_2_REPORT §7.1) |
| Editor challenger | Monaco | 0.57.0 | Benchmarked in the Phase 2 gate; upstream states mobile browsers unsupported — uphill battle, evidence required to overturn CM6. As built (W3): an exact-pinned **dev** dependency of `editor/`, used only for the benchmark page (no web workers, in-process fallback); never part of the shipped editor page. Its bundled third-party notices (marked, DOMPurify) ship with the benchmark page |
| Terminal frontend | **@xterm/xterm** | **6.0.0** + @xterm/addon-fit **0.11.0** + @xterm/addon-unicode11 **0.9.0** + @xterm/addon-webgl **0.19.0** (since Phase 5 W6) — exact pins, re-verified on npm (each is `latest`) | **Chosen 2026-11-12** by ADR-0006's rule: the licence is permissive (Apache-2.0, ADR-0011). The terminal page (TERMINAL_ARCHITECTURE §2.1) is 174.2 KiB gzipped at W3 and 210.7 KiB at W6 (budget 256 KiB). WebGL draws where the GPU is real, chosen with W6's numbers (§2.2); addon-search and addon-web-links are not used |
| ~~Terminal frontend (primary candidate)~~ | ~~vendored **terminal-view** (native)~~ | — | **Not used** (2026-11-12): Termux-derived, conservatively GPLv3, which the Apache-2.0 app does not ship (ADR-0011) |
| JS build | **esbuild** | 0.28.2 | Single-file bundle, deterministic, fast CI; no webpack |
| JS language | TypeScript | **5.9.3** — as built (exact pin). npm `latest` is the 7.x Go-based rewrite; Phase 2 stayed on 5.9, and moving is a separate upgrade | Type-safe bridge protocol |
| JS tests | **vitest** + happy-dom | 5.1.0 + 21.0.4 — as built | The page's unit and contract tests (187 at the Phase 2 exit) and the bundle verifier's DOM |

### The terminal page's dependencies (Phase 5 W3)

Each with AGENTS §5's paragraph; all three are exact pins in `editor/package.json`, installed with `npm ci` from the lockfile, checked by `tool/check_licenses.mjs` and listed in THIRD_PARTY_NOTICES §3.

- **@xterm/xterm 6.0.0.** *Android and ARM64:* plain JavaScript and DOM, nothing native; it runs in Android's System WebView like the editor page (Chromium 87 or later is the floor both pages are built for), and the DOM renderer needs no GPU. *Licence:* MIT. *Maintenance:* the terminal behind VS Code, released by the xterm.js organisation; 6.0.0 is npm's `latest`, with betas of 6.1 in progress. *Offline:* bundled into the page, which makes no request. *Size:* 345 KB minified, about 90 KB gzipped, within the page's 256 KiB budget with the font. No dependencies of its own.
- **@xterm/addon-fit 0.11.0.** Sizes the terminal to its panel, which is how the panel's size reaches the session. *Android and ARM64:* plain JavaScript. *Licence:* MIT. *Maintenance:* the same repository and release train as xterm.js. *Offline:* bundled. *Size:* 2 KB.
- **@xterm/addon-unicode11 0.9.0.** Unicode 11 character widths, so wide characters and emoji take the cells the program expects. *Android and ARM64:* plain JavaScript. *Licence:* MIT. *Maintenance:* as above. *Offline:* bundled. *Size:* 31 KB minified.
- **@xterm/addon-webgl 0.19.0** (since Phase 5 W6). xterm.js's WebGL2 renderer, which drew W6's flood on a Pixel 8a in 3.0 s against the DOM renderer's 4.1 s and kept the echo within 50 ms. *Android and ARM64:* WebGL2 in the System WebView; the page keeps the DOM renderer where there is none, the GPU is software, or the context is lost. *Licence:* MIT. *Maintenance:* as above, released with xterm.js 6.0.0. *Offline:* bundled. *Size:* 124 KB minified, 36 KB gzipped. No dependencies.

## 3. Runtime (vendored, not dependency-managed)

From t1 @ `0e26d7a`, the audited sealed payload, rebuilt by CodeForge from pinned inputs since Phase 4 W2: the bootstrap `2026.02.12-r1+apt.android-7` refreshed by the core set in `runtime/pins.json` (resolved 2026-11-13T09:43:19Z), 112 packages, each with its SHA-256. **As built** (Phase 4; checked on the device by Settings → Linux runtime and by the runtime gates on API 26 to 36 and an arm64 phone):

| Tool | Version | Status |
|---|---|---|
| Node.js / npm | **26.13.1** / 12.2.2 | P0, runs from the APK at target 36 (Phase 4 W4–W5) |
| Python / pip | 3.14.10 / 26.3 (OpenSSL 3.6.5) | P0, runs |
| Git | 2.56.1 | P0, runs |
| bash / coreutils | 5.3.9 / 9.9 | P0, runs |
| Perl / Ruby | 5.44.0-1 / 4.0.9 | P1, runs (already in the core set) |
| ripgrep | 15.2.0 (+pcre2 10.49) | search across files in projects since Phase 4 W6 |
| clang/cmake/make | Termux current | P1, on-demand pack (PFD / full variant) |
| TypeScript LSP / Pyright | via sealed Node/npm | P1, Phase 6 compatibility spike required |

**Rule:** no runtime binary is downloaded or replaced without re-running the payload pipeline + exec gates. No second copy of any runtime ever ships.

## 4. Dependency strategy

1. **Minimal surface.** Every new dependency needs a one-paragraph justification in the PR (Android/ARM64 compat, license, maintenance, offline behavior, size). Default answer is no.
2. **Pin everything.** `pubspec.lock` committed; exact npm versions + `npm ci`; Gradle versions catalog; bootstrap/payload SHA-256 pinned (t1 pattern). CI fails on uncommitted lockfile drift.
3. **License screening at intake.** Allowed: MIT, BSD, Apache-2.0, ISC, MPL-2.0 (file-level). GPL/LGPL only via the vendored-runtime aggregation path with notices: the app itself is Apache-2.0 since 2026-11-12 (ADR-0011), so no GPL code is linked into it. CI runs a license check on pub + npm trees.
4. **Offline-first.** No dependency may require network at runtime for core features. Fonts, icons, editor bundles, terminal assets all ship in the APK.
5. **Upgrade cadence.** Monthly dependency PR (automated diff + CI), never mid-phase unless security-driven. Flutter/AGP upgrades are their own PR with full gate suite.
6. **Codegen restraint.** Phase 1: no build_runner in the critical path (hand-written immutables). Drift introduces codegen in Phase 2, contained to the data layer. *As built: Drift's code is the only generated code. CI generates it and fails any run whose committed copy differs.*

## 5. Explicitly rejected (with reasons)

| Rejected | Reason |
|---|---|
| WebView-wrapped desktop VS Code (code-server / OpenVSCode) | Violates spec §1; desktop UI on mobile; memory; offline server process |
| Building a new Linux bootstrap from scratch | t1's sealed runtime already solves W^X + Play policy with device evidence; spec §2 forbids unnecessary rebuild |
| proot/PRoot-based distro (Debian/Ubuntu rootfs) | Larger, slower syscall translation, ptrace fragility on modern Android; unnecessary — Termux-shaped native userland is proven |
| `system_linker_exec` linker hack | t1 docs + Termux maintainers: fragile, policy-violating; not a product foundation |
| JGit as primary Git | Spec says prefer existing binary; sealed Git 2.56.0 proven; JGit adds JVM weight + behavioral divergence. Revisit only for a measured need |
| Bloc/Riverpod hybrid, GetX | One state system; spec mandates Riverpod |
| Monaco as default | Upstream: no mobile browser support; CM6 chosen pending measured gate (ADR-0004) |
| Firebase/analytics/crash SaaS | Offline-first; local structured logs + opt-in export only |
| path_provider (W4) | The app needs one folder, `Context.getFilesDir()`. path_provider 2.1.6 brings path_provider_android 2.3.x, which depends on `jni` and `jni_flutter` and so adds an NDK build to every APK job. One MainActivity method answers the same question (ARCHITECTURE.md §2.5) |
| Melos/multi-package Flutter monorepo (for now) | One app package + clear internal boundaries is enough through Phase 6; split only when a second consumer exists |

## 6. CI toolchain

GitHub Actions (ADR-0009). **As built in Phase 1:** ubuntu-latest, Temurin 17, Flutter **3.47.9** (**3.50.0** since Phase 4 W1) from `.flutter-version` via `subosito/flutter-action` (read by the workflows and checked since 2026-11-11: before that the action did not read the file and installed the latest stable, which was 3.47.9 until Flutter 3.50.0; BUILD_AND_RELEASE §3), the runner's preinstalled Android SDK (platform 36; NDK 28.2 resolved by the Flutter Gradle plugin), and for instrumented gates an API 36 **`google_apis` x86_64** emulator — hardware-accelerated through KVM (udev rule + settle), with software emulation (TCG) only as a recorded fallback. The `aosp_atd` image planned in Phase 0 was rejected after gate run 1 (stripped system services crashed). As built in Phase 2: Node 24 LTS (`editor/.nvmrc`) runs the editor job with `npm ci`. The arm64 device lab for release gates comes in Phase 4+. Details: [BUILD_AND_RELEASE.md](BUILD_AND_RELEASE.md).

**Actions (Phase 4 W1):** the Node 24 majors, each changed in its own commit after reading its release notes: `actions/checkout` v7, `setup-java` v6, `cache` v6 (restore and save), `upload-artifact` v7, `download-artifact` v8 and `setup-node` v7. `subosito/flutter-action@v2` is a composite action that already runs `actions/cache@v5`.
