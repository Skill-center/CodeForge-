# CodeForge

**A premium, mobile-first Android development environment.** A real IDE in your pocket: professional editing, a genuine local Linux toolchain (Node 26 · Python · Git · bash · Perl · Ruby), terminal, language intelligence, and version control — offline-first, built for touch, designed like a precision instrument.

> **Status: Phase 6, language intelligence, was accepted on 2026-11-23 ([report](docs/phases/PHASE_6_REPORT.md)), and Phase 7, Git and source control, is under way ([plan](docs/phases/PHASE_7_PLAN.md)): its first work package proved the runtime's git on every target, and fixed `git init`, `git clone` and HTTPS in the terminal; the second gave the app its own Git host, the real branch chip and the identity in Settings; the third added clone, fetch, pull and push, with tokens and SSH keys kept in the Android Keystore and handed to git only through its credential helper; the fourth gave the workbench its *Source control* panel — the changes staged, discarded and committed, branches, history, and a stopped merge resolved — with the explorer coloured by Git. Phase 5, the terminal and running code, was accepted on 2026-11-21 ([report](docs/phases/PHASE_5_REPORT.md)). Phase 4, runtime integration, was accepted on 2026-11-18 ([report](docs/phases/PHASE_4_REPORT.md)), Phase 3, workspace and files, on 2026-11-12 ([report](docs/phases/PHASE_3_REPORT.md)), and Phase 2, the workbench and code editor, on 2026-11-10 ([report](docs/phases/PHASE_2_REPORT.md)).** CodeForge edits real files, in projects and in folders on the device:
> - Projects live in the app's own storage, and folders open through Android's own picker, with no storage permission.
> - Home lists the recent projects and folders with their status, and each keeps its tabs, unsaved text and explorer view.
> - The explorer creates, renames, moves, copies and deletes, and Go to File finds a file by name.
> - Files changed by other apps show as it happens, and unsaved text is never overwritten.
> - CodeMirror 6 runs in a hardened Android System WebView, with many tabs, find and replace, a symbol toolbar and hardware shortcuts. Unsaved text survives the app being killed.
> - Android backup is the user's choice, off by default.
>
> Phase 6 ([plan](docs/phases/PHASE_6_PLAN.md), [report](docs/phases/PHASE_6_REPORT.md)) understands your code, offline:
> - **Language servers inside the app:** Pyright for Python, and TypeScript 6.0.3 with typescript-language-server for JavaScript and TypeScript, under the runtime's own node. They ship in the APK, pinned and verified, and install the first time a file of their language opens.
> - **In the editor:** completion as you type, problems underlined and listed in a *Problems* sheet, go to definition, rename across files (all files or none, with undo), and what the server knows about a name on a long press. Folders from shared storage get all of it through their copy.
> - **Within budget on a Pixel 8a,** on 200-file projects: completion lists drawn within 139.0 ms (Python) and 64.5 ms (TypeScript) at the 95th percentile (the budget is 300 ms), problems shown within 476.9 and 657.7 ms of a save (1 s), and each server within 169.9 and 246.5 MB of its own 300 MB.
> - **Never a broken editor:** a server that crashes or goes silent comes back with its files, and after repeated failures the status strip offers *Restart* while the editor goes on editing.
>
> Phase 5 ([plan](docs/phases/PHASE_5_PLAN.md), [report](docs/phases/PHASE_5_REPORT.md)) runs your code:
> - **A terminal:** bash on a pseudo-terminal CodeForge writes itself, drawn by xterm.js, with tabs, a row of extra keys, copy and paste, and up to 8 sessions. On a Pixel 8a a keystroke's echo is drawn in 37.2 ms at the 95th percentile (the budget is 50 ms), and 10 MiB of output arrives whole in 3.3 s, with none of the app's frames taking over 32 ms to draw.
> - **Run:** the open file (JavaScript, Python, shell, Ruby, Perl) or a project's npm script, each in a terminal, with Stop, its exit code, and `file:line` in the output opening the editor there. A folder from shared storage runs in a copy, and the files a run made can be exported back.
> - **Sessions that last:** a foreground service keeps them running while you use other apps, with a notification that counts them and ends them all. After Android ends the app, each session's tab says how it ended. Each session runs under limits measured on Android 8.0 to 16 and the Pixel 8a first.
> - **Releases, ready for the owner's keys:** the release workflow builds the signed App Bundle and APK with the source archive beside them (dry runs so far), and About shows the source offer and every licence. Nothing is distributed before the licence review.
>
> The runtime arrived in Phase 4 ([plan](docs/phases/PHASE_4_PLAN.md), [report](docs/phases/PHASE_4_REPORT.md)): t1's sealed Linux userland in the APK, verified as it installs and checked at every start, its seven tools at their pinned versions, search across files, and the real-device gates on Android 8.0 to 16 emulators and a physical Pixel 8a in Firebase Test Lab.
>
> Every claim is backed by a CI run: see the **[Phase 6 Report](docs/phases/PHASE_6_REPORT.md)**, the **[Phase 5 Report](docs/phases/PHASE_5_REPORT.md)** and the **[Phase 4 Report](docs/phases/PHASE_4_REPORT.md)**.

---

## Start here

| Document | What it answers |
|---|---|
| **[Phase 6 Report](docs/phases/PHASE_6_REPORT.md)** | What Phase 6 built (the servers in the APK, their host, the client in Dart, completion, diagnostics, definition, rename and hover in the editor, the language budgets on a phone), gate-by-gate evidence, the measurements, what is not met, and what the owner decides |
| [Phase 6 phone checklist](docs/phases/PHASE_6_PHONE_CHECKLIST.md) | The language servers on your phone: completion with Gboard, the long press for hover and definition, a rename, the Problems sheet, in about 20 minutes |
| [LSP Architecture](docs/LSP_ARCHITECTURE.md) · [ADR-0015](docs/adr/0015-language-servers.md) | How the language servers work as built, and why these servers |
| [Phase 5 Report](docs/phases/PHASE_5_REPORT.md) | What Phase 5 built (the release workflow, the PTY and sessions, the terminal, Run, sessions that last, the terminal's budgets on a phone), gate-by-gate evidence, the measurements, what is not met, and what the owner decides |
| [Phase 5 phone checklist](docs/phases/PHASE_5_PHONE_CHECKLIST.md) | The terminal on your phone: Gboard and the extra keys, taps and typing in the terminal and the editor, nano across a turn, a run, a long session in the background, the tombstones, in about 35 minutes |
| [Phase 4 Report](docs/phases/PHASE_4_REPORT.md) | What Phase 4 built (the toolchain, the sealed runtime in the app, its tools, the real-device gates, search, the notices and Play's drafts), gate-by-gate evidence, the measurements, what is not met, and what the owner decides |
| [Phase 4 phone checklist](docs/phases/PHASE_4_PHONE_CHECKLIST.md) | The runtime on your phone: the install time, the audit, the tools' versions, search, in about 20 minutes |
| [Play drafts](docs/store/README.md) | The listing, the Data safety answers, the privacy policy, the release checklist, and the proposed closed test |
| [Phase 3 Report](docs/phases/PHASE_3_REPORT.md) | What Phase 3 built (projects, folders, the explorer, outside changes), gate-by-gate evidence, the measurements, what is not met, and the owner's decisions |
| [Phase 3 phone checklist](docs/phases/PHASE_3_PHONE_CHECKLIST.md) | The exit session: every check parked since Phase 1, on one phone, in about 75 minutes |
| [Phase 2 Report](docs/phases/PHASE_2_REPORT.md) | What Phase 2 built (the editor), gate-by-gate evidence (CI run ids, hashes, measurements), parked phone checks, limitations, what's next |
| [Phase 1 Report](docs/phases/PHASE_1_REPORT.md) | What Phase 1 built (the shell and the design system), with its evidence |
| [Editor Architecture](docs/EDITOR_ARCHITECTURE.md) · [ADR-0004](docs/adr/0004-editor-engine.md) | How the editor works as built; why CodeMirror 6, measured against Monaco |
| [Terminal Architecture](docs/TERMINAL_ARCHITECTURE.md) · [ADR-0006](docs/adr/0006-terminal-frontend.md) · [ADR-0014](docs/adr/0014-pty-and-sessions.md) | How the terminal works as built: the PTY and the sessions, the page, Run, the lifecycle, and the budgets measured on a phone |
| [Phase 0 Report](docs/PHASE_0_REPORT.md) | What we found, what we decided, what's risky, what's next |
| [Runtime Audit](docs/EXISTING_RUNTIME_AUDIT.md) | The existing Linux environment (`m-cyber12/t1`), fully audited |
| [Architecture](docs/ARCHITECTURE.md) · [Repo Structure](docs/REPOSITORY_STRUCTURE.md) | How the system is built and where everything lives |
| [Tech Stack](docs/TECH_STACK.md) | Every dependency, verified versions, rejection reasons |
| **[Phase 7 Plan](docs/phases/PHASE_7_PLAN.md)** · [Phase 6 Plan](docs/phases/PHASE_6_PLAN.md) · [Phase 5 Plan](docs/phases/PHASE_5_PLAN.md) · [Phase 4 Plan](docs/phases/PHASE_4_PLAN.md) · [Phase 3 Plan](docs/phases/PHASE_3_PLAN.md) · [Phase 2 Plan](docs/phases/PHASE_2_PLAN.md) · [Phase 1 Plan](docs/phases/PHASE_1_PLAN.md) · [UI Design System](docs/UI_DESIGN_SYSTEM.md) | The phase plans (work packages, gates, tests, and what each package built) · the "Forge" tokens, contrast-audited |
| [Roadmap](docs/ROADMAP.md) | Phases 0–10, dependencies, decision queue |
| [ADRs](docs/adr/) | 15 architecture decision records |

## The foundation

CodeForge stands on an audited, device-proven asset: the **[t1 coding harness](https://github.com/m-cyber12/t1)** (branch `arena/f91bdedf-t1`, PR #81). Its **sealed runtime** ships a Termux-shaped userland *inside the APK* — executables as native libraries, hash-verified data, symlinked prefix — and runs **Node v26.12.1, Git 2.56.0, Python, Perl, Ruby, bash, ripgrep at targetSdk 36 on Android 16**, proven by CI gates on API 34 and 36. That is the hard part of an Android IDE, already solved. CodeForge adds the premium Flutter workbench on top.

Key audit corrections: "Seald" → **sealed** build model; the "~50 MB app" → measured **136 MB base AAB / ~360–380 MB installed** (budgets set accordingly); Node 26 ✅ verified.

## Locked decisions (2026-11-05; open items decided 2026-11-11)

- Flutter UI + Kotlin host + vendored t1 runtime modules (Pigeon/EventChannel boundary)
- Sealed execution model only · compileSdk/targetSdk **36** · minSdk **26**, confirmed by the Phase 4 reconciliation gate on API 26–28 (ADR-0007, Accepted 2026-11-18)
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
.github/workflows/       ← ci.yml (every push: Flutter + editor jobs; with [phase-gate], the emulator and runtime gates too)
docs/                    ← architecture, ADRs 0001–0013, phase plans and reports; store/ = the Play drafts
README.md · AGENTS.md · CONTRIBUTING.md · LICENSE · THIRD_PARTY_NOTICES.md · SOURCE_OFFER.md
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
