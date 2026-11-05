# CodeForge — Project Overview

**A premium, mobile-first Android development environment.** Not a code-editor toy, not a terminal skin, not a WebView wrapped around a desktop IDE — a real, local-first IDE built for phones and tablets, with a proven Linux toolchain underneath.

---

## Vision

Write, run, debug, and ship code **entirely on an Android device**: edit projects with a professional touch-native editor, execute JavaScript/Python/shell locally through a real Linux userland, manage Git, get language intelligence, and extend the environment — all offline-capable, all inside one app.

## Principles (from spec, enforced in review)

1. **Mobile-first** — every interaction designed for touch + IME first, hardware keyboard as an enhancement.
2. **Local-first** — core features never need a server; network is optional (git remotes, packs, extensions).
3. **Professional engineering** — feature-first Clean Architecture, typed boundaries, tested business logic, honest documentation.
4. **Performance** — measured budgets, lazy initialization, no duplicate runtimes (docs/PERFORMANCE.md).
5. **Extensibility** — languages, runtimes, themes, tools plug in without restructuring.
6. **Desktop-inspired, not desktop-copied** — VS Code workflows, original mobile UI.
7. **Native where it matters** — Kotlin host + proven sealed Linux runtime under Flutter.

## The foundation (audited, not assumed)

CodeForge embeds the audited **[m-cyber12/t1](https://github.com/m-cyber12/t1)** sealed runtime: Node 26, Python, Git, bash, Perl, Ruby, ripgrep running **from the APK at targetSdk 36** — the execution model that makes a store-legal Android IDE possible. Full findings: [EXISTING_RUNTIME_AUDIT.md](EXISTING_RUNTIME_AUDIT.md).

## Scope

**In:** workbench, explorer, editor (CM6 candidate), terminal, runtime manager, LSP, Git, extensions, search, settings, debugging, release engineering.
**Out (v1):** iOS/desktop, cloud sync, VS Code Marketplace compatibility, AI assistant integration (architecture leaves room; product decision later), collaborative editing.

## Current status

| | |
|---|---|
| Phase | **0 complete (analysis)** — see [PHASE_0_REPORT.md](PHASE_0_REPORT.md) |
| Next | Phase 1 — Flutter foundation & design system: [phases/PHASE_1_PLAN.md](phases/PHASE_1_PLAN.md) |
| Decisions | 11 ADRs in [adr/](adr/); owner queue in [ROADMAP.md](ROADMAP.md) |
| Builds | None yet — CI becomes the build authority in Phase 1 (honesty rule: no claimed builds before they run) |

## Documentation map

Start here → [PHASE_0_REPORT.md](PHASE_0_REPORT.md) → [ARCHITECTURE.md](ARCHITECTURE.md) → [ROADMAP.md](ROADMAP.md).
Engineering: TECH_STACK · REPOSITORY_STRUCTURE · RUNTIME_INTEGRATION · EDITOR_ARCHITECTURE · TERMINAL_ARCHITECTURE · LSP_ARCHITECTURE · EXTENSION_API · SECURITY · TESTING · PERFORMANCE · BUILD_AND_RELEASE · UI_DESIGN_SYSTEM.
Process: AGENTS.md · CONTRIBUTING.md · CHANGELOG.md.
