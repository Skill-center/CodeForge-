# CodeForge

**A premium, mobile-first Android development environment.** A real IDE in your pocket: professional editing, a genuine local Linux toolchain (Node 26 · Python · Git · bash · Perl · Ruby), terminal, language intelligence, and version control — offline-first, built for touch, designed like a precision instrument.

> **Status: Phase 3, workspace and files, was accepted on 2026-11-12 ([report](docs/phases/PHASE_3_REPORT.md)), and Phase 2, the workbench and code editor, on 2026-11-10 ([report](docs/phases/PHASE_2_REPORT.md)).** CodeForge edits real files, in projects and in folders on the device:
> - Projects live in the app's own storage, and folders open through Android's own picker, with no storage permission.
> - Home lists the recent projects and folders with their status, and each keeps its tabs, unsaved text and explorer view.
> - The explorer creates, renames, moves, copies and deletes, and Go to File finds a file by name.
> - Files changed by other apps show as it happens, and unsaved text is never overwritten.
> - CodeMirror 6 runs in a hardened Android System WebView, with many tabs, find and replace, a symbol toolbar and hardware shortcuts. Unsaved text survives the app being killed.
> - Android backup is the user's choice, off by default.
>
> The runtime and the terminal arrive in Phases 4–5, and the screens say so honestly. Phase 4 is under way ([plan](docs/phases/PHASE_4_PLAN.md)): its first package moved CodeForge to Flutter 3.50.0, and its second vendored t1's sealed-runtime kernel and pinned every input of the runtime. Every claim is backed by a CI run: see the **[Phase 3 Report](docs/phases/PHASE_3_REPORT.md)**.

---

## Start here

| Document | What it answers |
|---|---|
| **[Phase 3 Report](docs/phases/PHASE_3_REPORT.md)** | What Phase 3 built (projects, folders, the explorer, outside changes), gate-by-gate evidence, the measurements, what is not met, and the owner's decisions |
| [Phase 3 phone checklist](docs/phases/PHASE_3_PHONE_CHECKLIST.md) | The exit session: every check parked since Phase 1, on one phone, in about 75 minutes |
| [Phase 2 Report](docs/phases/PHASE_2_REPORT.md) | What Phase 2 built (the editor), gate-by-gate evidence (CI run ids, hashes, measurements), parked phone checks, limitations, what's next |
| [Phase 1 Report](docs/phases/PHASE_1_REPORT.md) | What Phase 1 built (the shell and the design system), with its evidence |
| [Editor Architecture](docs/EDITOR_ARCHITECTURE.md) · [ADR-0004](docs/adr/0004-editor-engine.md) | How the editor works as built; why CodeMirror 6, measured against Monaco |
| [Phase 0 Report](docs/PHASE_0_REPORT.md) | What we found, what we decided, what's risky, what's next |
| [Runtime Audit](docs/EXISTING_RUNTIME_AUDIT.md) | The existing Linux environment (`m-cyber12/t1`), fully audited |
| [Architecture](docs/ARCHITECTURE.md) · [Repo Structure](docs/REPOSITORY_STRUCTURE.md) | How the system is built and where everything lives |
| [Tech Stack](docs/TECH_STACK.md) | Every dependency, verified versions, rejection reasons |
| [Phase 3 Plan](docs/phases/PHASE_3_PLAN.md) · [Phase 2 Plan](docs/phases/PHASE_2_PLAN.md) · [Phase 1 Plan](docs/phases/PHASE_1_PLAN.md) · [UI Design System](docs/UI_DESIGN_SYSTEM.md) | The phase plans (work packages, gates, tests, and what each package built) · the "Forge" tokens, contrast-audited |
| [Roadmap](docs/ROADMAP.md) | Phases 0–10, dependencies, decision queue |
| [ADRs](docs/adr/) | 12 architecture decision records |

## The foundation

CodeForge stands on an audited, device-proven asset: the **[t1 coding harness](https://github.com/m-cyber12/t1)** (branch `arena/f91bdedf-t1`, PR #81). Its **sealed runtime** ships a Termux-shaped userland *inside the APK* — executables as native libraries, hash-verified data, symlinked prefix — and runs **Node v26.12.1, Git 2.56.0, Python, Perl, Ruby, bash, ripgrep at targetSdk 36 on Android 16**, proven by CI gates on API 34 and 36. That is the hard part of an Android IDE, already solved. CodeForge adds the premium Flutter workbench on top.

Key audit corrections: "Seald" → **sealed** build model; the "~50 MB app" → measured **136 MB base AAB / ~360–380 MB installed** (budgets set accordingly); Node 26 ✅ verified.

## Locked decisions (2026-11-05; open items decided 2026-11-11)

- Flutter UI + Kotlin host + vendored t1 runtime modules (Pigeon/EventChannel boundary)
- Sealed execution model only · compileSdk/targetSdk **36** · minSdk **26**, to be verified by the Phase 4 reconciliation gate (owner decision 2026-11-11)
- Riverpod 3 · GoRouter 18 · Drift (Phase 2+) · CodeMirror 6 primary editor candidate (device gate vs Monaco) — *chosen 2026-11-06 ([ADR-0004](docs/adr/0004-editor-engine.md))*
- GitHub Actions as the build authority · GitHub Releases first, Play-compatible AAB second
- License: **Apache-2.0** (owner decision 2026-11-12, ADR-0011), so the terminal frontend is xterm.js (ADR-0006's rule)
- arm64 device runs on Firebase Test Lab from Phase 4 (ADR-0009) · Play Console prepared at Phase 4 (ADR-0010) · all work stays on the working branch until v1 ([ROADMAP](docs/ROADMAP.md))

## Repository layout (today)

```
app/                     ← the Flutter app
  lib/                   ← application/ (controllers, router) · core/ · design_system/ · features/ · services/ (+ fakes)
  test/                  ← unit · widget · accessibility · contrast · golden suites; drift/ schema tests
  integration_test/      ← emulator suites: smoke, editor bridge, editing, keys, engine benchmark, large files, restore and edit pairs
  tool/                  ← import-boundary + license gates; tool/ci/ gate scripts
  ci-results/            ← CI-generated evidence (never hand-edited); gate/ = emulator gate, editor/ = editor job
  drift_schemas/         ← Drift schema dumps (CI-generated)
  android/               ← Kotlin host, minSdk 26 / target 36
editor/                  ← the editor page: TypeScript + CodeMirror 6, protocol v1, benchmark pages, build and verify tools
.github/workflows/       ← ci.yml (every push: Flutter + editor jobs) · phase-gate.yml (emulator gate)
docs/                    ← architecture, ADRs 0001–0012, phase plans and reports
README.md · AGENTS.md · CONTRIBUTING.md
```

`native/` (the vendored sealed-runtime kernel; [PROVENANCE](native/PROVENANCE.md)) and `runtime/` (its pinned supply chain; [README](runtime/README.md)) arrived in Phase 4 W2 — see [REPOSITORY_STRUCTURE.md](docs/REPOSITORY_STRUCTURE.md). Nothing is scaffolded before it's used.

## Building

```bash
# Flutter 3.50.0 (see .flutter-version), JDK 17, Android SDK 36, Node 24 (editor/.nvmrc)
(cd editor && npm ci && npm run build)   # the editor page → app/assets/editor/ (gitignored; the APK needs it)
cd app
flutter pub get
flutter test                 # unit, widget, accessibility, contrast, goldens
flutter build apk --debug
```

**GitHub Actions is the build authority** (the development sandbox cannot build Android): every claim that something builds or passes cites a CI run id. Golden baselines are generated on the Linux runner, so local golden runs on other platforms may differ by anti-aliasing. How CI evidence is produced (`[bootstrap]`, `[phase-gate]`, `app/ci-results/`): [BUILD_AND_RELEASE.md §2.1](docs/BUILD_AND_RELEASE.md).

## Principles

Build a real IDE. Design for mobile. Execute locally. Optimize relentlessly.
No fake features, no unverified claims, no phase skipped. See [AGENTS.md](AGENTS.md).

## License

CodeForge is licensed under the [Apache License 2.0](LICENSE) (owner decision 2026-11-12, [ADR-0011](docs/adr/0011-license.md)). Third-party components keep their own licences, and no Termux-derived terminal code is used. The bundled userland's components (bash, git, coreutils and others, some of them GPL) will ship with their licence texts and a source offer before any binary release.
