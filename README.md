# CodeForge

**A premium, mobile-first Android development environment.** A real IDE in your pocket: professional editing, a genuine local Linux toolchain (Node 26 · Python · Git · bash · Perl · Ruby), terminal, language intelligence, and version control — offline-first, built for touch, designed like a precision instrument.

> **Status: Phase 0 complete (audit & architecture).** No application code yet — by design. The next step is Phase 1 (Flutter foundation & design system), fully planned and ready to execute.

---

## Start here

| Document | What it answers |
|---|---|
| **[Phase 0 Report](docs/PHASE_0_REPORT.md)** | What we found, what we decided, what's risky, what's next |
| [Runtime Audit](docs/EXISTING_RUNTIME_AUDIT.md) | The existing Linux environment (`m-cyber12/t1`), fully audited |
| [Architecture](docs/ARCHITECTURE.md) · [Repo Structure](docs/REPOSITORY_STRUCTURE.md) | How the system is built and where everything lives |
| [Tech Stack](docs/TECH_STACK.md) | Every dependency, verified versions, rejection reasons |
| [Phase 1 Plan](docs/phases/PHASE_1_PLAN.md) | The detailed MVP implementation plan (workstreams, gates, tests) |
| [Roadmap](docs/ROADMAP.md) | Phases 0–10, dependencies, decision queue |
| [ADRs](docs/adr/) | 11 architecture decision records |

## The foundation

CodeForge stands on an audited, device-proven asset: the **[t1 coding harness](https://github.com/m-cyber12/t1)** (branch `arena/f91bdedf-t1`, PR #81). Its **sealed runtime** ships a Termux-shaped userland *inside the APK* — executables as native libraries, hash-verified data, symlinked prefix — and runs **Node v26.12.1, Git 2.56.0, Python, Perl, Ruby, bash, ripgrep at targetSdk 36 on Android 16**, proven by CI gates on API 34 and 36. That is the hard part of an Android IDE, already solved. CodeForge adds the premium Flutter workbench on top.

Key audit corrections: "Seald" → **sealed** build model; the "~50 MB app" → measured **136 MB base AAB / ~360–380 MB installed** (budgets set accordingly); Node 26 ✅ verified.

## Locked decisions (2026-11-05)

- Flutter UI + Kotlin host + vendored t1 runtime modules (Pigeon/EventChannel boundary)
- Sealed execution model only · compileSdk/targetSdk **36** · minSdk **26** (Phase 4 reconciliation gate)
- Riverpod 3 · GoRouter 18 · Drift (Phase 2+) · CodeMirror 6 primary editor candidate (device gate vs Monaco)
- GitHub Actions as the build authority · GitHub Releases first, Play-compatible AAB second
- License: pending owner decision (ADR-0011) — release-gating, not development-blocking

## Repository layout (today)

```
docs/            ← all Phase 0 deliverables (this is the current product)
  adr/           ← decision records 0001–0011
  phases/        ← PHASE_1_PLAN.md (more per phase)
README.md · AGENTS.md · CONTRIBUTING.md
```

`app/` (Flutter), `editor/` (TS bundles), `native/` + `runtime/` (vendored sealed runtime) arrive with their phases — see [REPOSITORY_STRUCTURE.md](docs/REPOSITORY_STRUCTURE.md). Nothing is scaffolded before it's used.

## Building

There is nothing to build yet. From Phase 1, **GitHub Actions is the build authority** (the development sandbox cannot build Android): every claim of "builds/tests pass" cites a CI run id. Local instructions land in CONTRIBUTING.md as the app appears.

## Principles

Build a real IDE. Design for mobile. Execute locally. Optimize relentlessly.
No fake features, no unverified claims, no phase skipped. See [AGENTS.md](AGENTS.md).

## License

Pending (ADR-0011). Original code is cleanly owned; GPLv3 exposure from Termux-derived terminal modules is mapped, with a permissive path available. Bundled userland components will ship with full notices + source offer before any binary release.
