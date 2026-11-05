# CodeForge — Phase 0 Technical Audit & Architecture Proposal

**Status:** Phase 0 analysis complete · 2026-11-05 · Branch `arena/f57c33ee-codeforge`
**Deliverable required by spec §8/§14:** Technical Audit Report + Architecture Decision Records.
**Companion documents:** [EXISTING_RUNTIME_AUDIT.md](EXISTING_RUNTIME_AUDIT.md) (full audit), [ARCHITECTURE.md](ARCHITECTURE.md), [TECH_STACK.md](TECH_STACK.md), [ROADMAP.md](ROADMAP.md), [phases/PHASE_1_PLAN.md](phases/PHASE_1_PLAN.md), [adr/](adr/).

---

## 1. Executive summary

CodeForge is feasible, and the hardest problem is **already solved in an existing asset**.

The spec's "existing Linux environment" is **[m-cyber12/t1](https://github.com/m-cyber12/t1)** — a mature Android coding harness (v0.33.1, PR #81 on branch `arena/f91bdedf-t1`). The audit verified that it already runs **Node v26.12.1, Git 2.56.0, Python (OpenSSL 3.6.5), Perl 5.44.0, Ruby 4.0.7, bash 5.3.9 and ripgrep 15.2.0** inside an app sandbox **at targetSdk 36 on API 36** — the exact combination that defeats naive Android IDE projects — using a **"sealed" execution model**: every executable ships inside the APK as a JNI library, the prefix symlinks into `nativeLibraryDir`, and only read-only data is extracted (hash-verified while written). This is proven by CI gates on emulators (run `40078102513`, both API 34 and API 36 legs green), not by claims.

**Strategy:** CodeForge = a new Flutter workbench (original premium mobile UI) + the proven t1 runtime modules embedded in its Android host. We do not rebuild the runtime; we integrate it. Phase 1 (UI foundation) has **zero runtime dependencies** and can start immediately.

## 2. Corrections to the spec (audit findings)

| Spec claim | Audit finding |
|---|---|
| "Seald-based implementation" | It is a **"sealed" build variant** (`sealed-runtime/` module) — a store-legal execution model. "Seald" (the encryption SDK company) is unrelated. |
| "packaged into an application of approximately 50 MB" | **Not reproducible.** Measured: sealed base AAB **136.0 MB per device** (arm64-v8a, under Play's 200 MB cap); installed core userland **~360–380 MB** on an arm64 device. The ~50 MB figure likely refers to an early bootstrap-only APK. Budgets in [PERFORMANCE.md](PERFORMANCE.md) use measured numbers. |
| "Node.js 26" | ✅ Verified: **v26.12.1** executes from the APK on API 34 and 36 emulators. Upstream Node v26.13.0 exists (checked 2026-11-05). |
| Repository URL placeholder | Resolved by owner: `https://github.com/m-cyber12/t1`. **Note:** `main` is an empty README; the code lives on `arena/f91bdedf-t1` (open PR #81). We pin to commit `0e26d7a` until that PR merges. |
| targetSdk 36 feasibility | ✅ Already proven by t1's `ExecModelTest` + `SealedShellTest` gates — but only on **x86_64 emulators**. The arm64 payload is built and shipped; **arm64 device verification is a Phase 4 task**. |

## 3. Decisions (ADR index)

| ADR | Decision | Status |
|---|---|---|
| [0001](adr/0001-flutter-kotlin-hybrid.md) | Flutter UI + Kotlin/Java Android host; embed t1 runtime modules | Accepted |
| [0002](adr/0002-monorepo-layout.md) | Monorepo: one Flutter package + reused Gradle modules + TS editor workspace | Accepted |
| [0003](adr/0003-state-navigation.md) | Riverpod 3.x + GoRouter 18.x | Accepted |
| [0004](adr/0004-editor-engine.md) | CodeMirror 6 primary candidate; Monaco benchmarked, final pick gated on device tests | Proposed |
| [0005](adr/0005-sealed-runtime.md) | Sealed execution model only; targetSdk/compileSdk 36; no apt-at-runtime | Accepted |
| [0006](adr/0006-terminal-frontend.md) | Native Termux `terminal-view` via PlatformView (primary candidate) vs xterm.js (fallback); license + benchmark gate | Proposed |
| [0007](adr/0007-min-sdk.md) | minSdk 26 chosen by owner; t1 declares 29 — reconciliation gate in Phase 4 | Needs decision |
| [0008](adr/0008-persistence.md) | shared_preferences (prefs) + Drift/SQLite (structured state, from Phase 2) | Accepted |
| [0009](adr/0009-ci-github-actions.md) | GitHub Actions; adopt t1's evidence-gate CI philosophy | Accepted |
| [0010](adr/0010-distribution.md) | GitHub Releases first ("full" APK), Play-compatible sealed AAB ("base + on-demand packs") | Accepted |
| [0011](adr/0011-license.md) | License pending owner decision; GPLv3 exposure from Termux-derived terminal modules documented | Pending |

Owner decisions already locked (2026-11-05): **minSdk 26** (subject to ADR-0007 gate), **distribution both channels / GitHub first**, **license TBD**.

## 4. Why this architecture wins

1. **The W^X wall is already climbed.** Android 10+ forbids `execve()` from app-writable storage for apps targeting API 29+ ([Android behavior change](https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission)). t1's sealed model (executables as `lib*.so` in the APK, symlinked prefix, `LD_PRELOAD` path/shebang translation) is the only store-legal approach that keeps a real Termux-shaped userland — and it is implemented, tested, and documented with four device-hardened invariants.
2. **Play policy compliance by construction.** Play forbids downloading executable code post-install ([Device & Network Abuse policy](https://support.google.com/googleplay/android-developer/answer/9888379)). Sealed base ships all core executables; optional toolchains arrive as **Play Feature Delivery** modules (already built: `pack_buildtools`). GitHub builds ship a "full" variant. One execution model, two delivery shapes.
3. **Reuse where reuse is proven.** `sealed-runtime` is a plain-Java, Android-free kernel (8 classes, ~1,100 lines + JVM tests) explicitly designed to be lifted into a host app (`docs/sealed-runtime-port.md` in t1). The PTY/terminal engine, environment/preload layer, payload builder, and CI gates come with it.
4. **Mobile-first editor, honestly chosen.** Monaco's own README states mobile browsers are unsupported; CodeMirror 6 is built around native mobile selection/IME and is an order of magnitude smaller. CM6 is the primary candidate; the final choice is a measured Phase 2 gate, per spec.

## 5. Risk register (top items)

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| R1 | **License ambiguity**: t1 has no LICENSE; upstream Termux is GPLv3-only with an Apache-2.0 exception for jackpal-derived terminal code; copied files lack headers | High (blocks release, not Phase 1) | ADR-0011: owner decision; permissive path exists (xterm.js frontend + own/Apache PTY, own sealed-runtime); GPL path = GPLv3 app. Attribution + source offer for bundled userland either way. |
| R2 | Sealed runtime proven on x86_64 emulators only | Medium | Phase 4 gate: run `SealedShellTest`/`ExecModelTest` on arm64 hardware before declaring MVP 4. |
| R3 | minSdk conflict: owner chose 26, t1 declares 29 | Medium | ADR-0007 gate: verify on API 26–28 emulators in Phase 4, else raise to 29 with owner sign-off. Phase 1 scaffolds at 26. |
| R4 | Editor IME/cursor reliability on Android WebView | High (product-defining) | CM6 + dedicated IME test matrix; Flutter-side symbol toolbar; benchmark gate before Phase 2 exit. |
| R5 | Size: 136 MB base is 2.7× the spec's assumed 50 MB | Medium | Measured budgets, `check-bundle-size.py` gate, hygiene pruning, packs on demand; set store listing expectations. |
| R6 | WebView memory with editor + terminal + LSP | Medium | Single editor WebView (multi-state), lazy terminal surface, LSP in runtime processes not WebViews; memory budgets in CI. |
| R7 | t1 code lives on an unmerged PR branch | Low | Pin commit `0e26d7a`; vendor modules with provenance file; upstream merge tracked as a task. |
| R8 | Node/Python LSP servers on Android/bionic | Medium | Phase 6 spike: pyright & typescript-language-server under sealed Node 26; graceful fallback to syntax-only mode. |

## 6. Phase 0 acceptance criteria — status

| Criterion (spec §8) | Status | Evidence |
|---|---|---|
| Existing repository inspected | ✅ | [EXISTING_RUNTIME_AUDIT.md](EXISTING_RUNTIME_AUDIT.md) |
| Build requirements documented | ✅ | Audit §3 (AGP 8.13.2, Gradle 9.2.1, NDK 27.2, JDK 17; CI builds green) |
| Runtime capabilities verified | ✅ (emulator) / ⚠ arm64 device pending | t1 CI run `40078102513`; R2 |
| Local shell process launches | ✅ (proven in t1's own gates) | `SealedShellTest` — re-verified inside CodeForge in Phase 4 |
| Flutter ↔ native communication PoC | ⏳ Deferred to Phase 1 CI | This sandbox cannot build Android (no Flutter/Java/Android SDK; `dl.google.com` unreachable). GitHub Actions runners can — the PoC is Phase 1 workstream W1, verified in CI, never claimed before it runs. |
| Monaco vs CodeMirror evaluated | ✅ desk evaluation / ⏳ device gate in Phase 2 | [EDITOR_ARCHITECTURE.md](EDITOR_ARCHITECTURE.md) |
| Incompatibilities identified | ✅ | R1–R8 above; W^X, 16 KB pages, Play policy, minSdk, licensing |
| Architecture documented | ✅ | This report + ARCHITECTURE.md + 11 ADRs |

**Honesty note (spec rule 15/16):** nothing in this report claims a CodeForge build or test has run — none has. All "proven" statements refer to t1's published CI evidence, cited by run id. CodeForge's own first build happens in Phase 1, in GitHub Actions.

## 7. What happens next

1. **Owner decisions** (can be made in parallel with Phase 1): license direction (ADR-0011), terminal frontend preference (ADR-0006), minSdk reconciliation appetite (ADR-0007).
2. **Phase 1 — Flutter Foundation & Design System** starts on approval: [phases/PHASE_1_PLAN.md](phases/PHASE_1_PLAN.md). No runtime dependency; CI from day one.
3. **Phase 2 editor benchmark** resolves ADR-0004; **Phase 4 runtime integration** resolves ADR-0006/0007 with device evidence.

*Build a real IDE. Design for mobile. Execute locally. Optimize relentlessly.*
