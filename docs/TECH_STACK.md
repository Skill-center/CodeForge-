# Technology Stack & Dependency Decisions

**Verified:** 2026-11-05 against pub tags (git ls-remote), npm registry, and GitHub releases — not from memory. Pins are finalized in Phase 1 W1 when CI proves them; every version below was checked to exist today.

---

## 1. Core stack (locked by spec + audit)

| Component | Choice | Verified version | Why |
|---|---|---|---|
| App framework | **Flutter** (stable) | 3.47.9 | Spec mandate; single UI codebase, first-class Android embedding |
| UI language | Dart (bundled SDK) | ships with Flutter | — |
| Android host | **Kotlin** (+ vendored Java modules) | Kotlin 2.2.x+ (2.4.21 released; pin what Flutter 3.47 template + AGP accept, ≥2.2.21) | Spec; t1 modules are Java — Kotlin host interoperates natively on the JVM |
| Android Gradle Plugin | AGP | 8.13.x (t1 proves 8.13.2) | Match audited runtime build; Flutter 3.47 accepts ≥8.13 |
| Gradle | wrapper | 9.2.1 (t1's wrapper) | Proven with AGP 8.13.2 in t1 CI |
| JDK | Temurin | 17 | t1 CI standard; Flutter/AGP compatible |
| compileSdk / targetSdk | **36 / 36** | — | Spec + Play requirement (Aug 31 2026); sealed model makes it work |
| minSdk | **26** (owner choice) | — | ADR-0007 gate: t1 declares 29; verify or raise in Phase 4 |
| NDK | pinned | 27.2.12479018 (t1) with explicit 16 KB linker flags | 16 KB page support proven in t1; revisit r28 at Phase 10 |
| State management | **Riverpod** | 3.4.3 | Compile-safe DI + reactive state; spec mandate; active maintenance |
| Navigation | **GoRouter** | 18.1.3 | Declarative, deep links, shell routes for workbench; Flutter team-maintained |
| Typed platform channels | **Pigeon** | 29.1.0 | Generates Dart+Kotlin contracts; no hand-rolled MethodChannel string maps |
| WebView | **webview_flutter** | 4.14.1 | Official plugin; Android WebView host for editor |
| Local DB | **Drift** (SQLite) | 2.35.3 | Typed queries, migrations, reactive streams; Phase 2+ |
| Preferences | shared_preferences | 2.5.6 | Settings only; structured state goes to Drift |
| Lints | flutter_lints | 6.0.0 | Baseline + custom import-boundary rules |

## 2. Editor & terminal frontend

| Component | Choice | Verified version | Notes |
|---|---|---|---|
| Editor engine | **CodeMirror 6** (primary candidate) | @codemirror/view 6.43.15, state 6.7.6 | Mobile-native selection/IME, modular, ~135 KB gz core; ADR-0004 device gate decides finally |
| Editor challenger | Monaco | 0.57.0 | Benchmarked in Phase 2 gate; upstream states mobile browsers unsupported — uphill battle, evidence required to overturn CM6 |
| Terminal frontend (fallback) | **@xterm/xterm** | 6.0.0 (+ addon-fit 0.11.0) | Only if ADR-0006 picks WebView route (license-driven or PlatformView perf fails) |
| Terminal frontend (primary candidate) | vendored **terminal-view** (native) | t1 @ 0e26d7a | Proven touch/IME/selection; via Flutter PlatformView; license gate ADR-0011 |
| JS build | **esbuild** | 0.28.2 | Single-file bundle, deterministic, fast CI; no webpack |
| JS language | TypeScript | 5.9.x line (npm `latest` is 7.0.2 — the Go-based rewrite; pin 5.x until ecosystem settles, evaluate in Phase 2) | Type-safe bridge protocol |

## 3. Runtime (vendored, not dependency-managed)

From t1 @ `0e26d7a` — versions as shipped in the audited sealed payload:

| Tool | Version | Status |
|---|---|---|
| Node.js | **26.12.1** | P0, proven from APK at target 36 |
| Python | Termux current (OpenSSL 3.6.5) | P0, proven |
| Git | 2.56.0 | P0, proven |
| bash / coreutils | 5.3.9 / Termux base | P0, proven |
| Perl / Ruby | 5.44.0 / 4.0.7 | P1, proven (already in core tier) |
| ripgrep | 15.2.0 (+pcre2) | workspace search backend, proven |
| clang/cmake/make | Termux current | P1, on-demand pack (PFD / full variant) |
| TypeScript LSP / Pyright | via sealed Node/npm | P1, Phase 6 compatibility spike required |

**Rule:** no runtime binary is downloaded or replaced without re-running the payload pipeline + exec gates. No second copy of any runtime ever ships.

## 4. Dependency strategy

1. **Minimal surface.** Every new dependency needs a one-paragraph justification in the PR (Android/ARM64 compat, license, maintenance, offline behavior, size). Default answer is no.
2. **Pin everything.** `pubspec.lock` committed; exact npm versions + `npm ci`; Gradle versions catalog; bootstrap/payload SHA-256 pinned (t1 pattern). CI fails on uncommitted lockfile drift.
3. **License screening at intake.** Allowed: MIT, BSD, Apache-2.0, ISC, MPL-2.0 (file-level). GPL/LGPL only via the vendored-runtime aggregation path with notices, or via explicit ADR-0011 decision for terminal modules. CI runs a license check on pub + npm trees.
4. **Offline-first.** No dependency may require network at runtime for core features. Fonts, icons, editor bundles, terminal assets all ship in the APK.
5. **Upgrade cadence.** Monthly dependency PR (automated diff + CI), never mid-phase unless security-driven. Flutter/AGP upgrades are their own PR with full gate suite.
6. **Codegen restraint.** Phase 1: no build_runner in the critical path (hand-written immutables). Drift introduces codegen in Phase 2, contained to the data layer.

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
| Melos/multi-package Flutter monorepo (for now) | One app package + clear internal boundaries is enough through Phase 6; split only when a second consumer exists |

## 6. CI toolchain

GitHub Actions (ADR-0009): ubuntu-latest, Temurin 17, Flutter 3.47.x pinned, Node 24 LTS for editor builds, Android SDK 36 + NDK 27.2 via `android-actions/setup-android`, `aosp_atd` x86_64 emulators (TCG) for instrumented gates, arm64 device lab for release gates (Phase 4+). Details: [BUILD_AND_RELEASE.md](BUILD_AND_RELEASE.md).
