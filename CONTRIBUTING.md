# Contributing to CodeForge

Thanks for building the pocket workstation with us. Read **[AGENTS.md](AGENTS.md)** first — its rules apply to humans and agents alike.

## Current state

Phase 0 (audit & architecture) is complete; the repository contains documentation only. Application code starts in Phase 1 per **[docs/phases/PHASE_1_PLAN.md](docs/phases/PHASE_1_PLAN.md)**. Setup instructions below activate as the corresponding directories land.

## How to contribute right now

- **Review the Phase 0 deliverables** — especially [docs/PHASE_0_REPORT.md](docs/PHASE_0_REPORT.md) and the [ADRs](docs/adr/). Challenge decisions with evidence; that's what ADRs are for.
- **Owner decisions** are queued in [docs/ROADMAP.md](docs/ROADMAP.md), with those already made: the licence (Apache-2.0, ADR-0011), the terminal frontend (xterm.js, ADR-0006), arm64 runs on Firebase Test Lab (ADR-0009) and minSdk 26 pending its Phase 4 check (ADR-0007).
- Open issues for risks, corrections, or ideas — tag ideas `backlog` so they don't creep into the active phase.

## Development setup (from Phase 1)

```bash
# Prerequisites: Flutter 3.47.x (see .flutter-version), JDK 17, Android SDK 36.
cd app
flutter pub get
flutter test                 # unit + widget + goldens
flutter build apk --debug    # or let CI build it — CI is the authority
```

The development sandbox used by agents cannot build Android (no SDK access); **GitHub Actions builds and tests everything**. Every "it works" claim in a PR must cite a CI run id.

## Branch & PR conventions

- Agents work on their session `arena/*` branch; humans: feature branches off `main` (`feat/…`, `fix/…`, `docs/…`).
- One logical change per PR; include: what/why, acceptance evidence (run ids, artifacts), doc updates, dependency justifications if any.
- PR template checklist is mandatory — incomplete evidence = not reviewed.
- Commits: imperative mood, scoped prefix (`phase1: …`, `docs: …`, `runtime: …`).

## Quality bar

- Tests with the change (unit/widget/contract as applicable); goldens for UI; no red CI.
- Architecture boundaries per [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) §2 (import lint enforces).
- Performance budgets per [docs/PERFORMANCE.md](docs/PERFORMANCE.md); regressions > 15% need an issue.
- Security review for anything touching a boundary ([docs/SECURITY.md](docs/SECURITY.md)).
- No secrets, keystores, payloads, or build outputs in Git.

## Dependencies

Exact pins + committed lockfiles; justification paragraph (Android/ARM64 compatibility, license, maintenance, offline behavior, size). Allowed licenses: MIT/BSD/Apache-2.0/ISC/MPL-2.0; anything copyleft needs an ADR. Monthly update cadence; security fixes out-of-band.

## Reporting security issues

Use GitHub private security advisories (enabled from Phase 1). Do not open public issues for vulnerabilities. Triage ≤ 72 h.

## License

Apache License 2.0 ([LICENSE](LICENSE); owner decision 2026-11-12, ADR-0011). Contributions are accepted under the same licence (its section 5). Bundled runtime components carry their own open-source licences, with notices and a source offer.
