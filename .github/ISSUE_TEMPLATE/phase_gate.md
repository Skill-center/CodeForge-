---
name: Phase gate checklist
about: Track a phase's exit gates to acceptance (one issue per phase)
labels: phase-gate
---

## Phase

<!-- e.g. Phase 2 — Workbench & editor. Plan: docs/phases/PHASE_N_PLAN.md -->

## Gates

Every row needs evidence: a CI run id, an evidence commit, or an owner
sign-off with device + build hash. "Not met" and "partially met" are
acceptable answers; an unbacked "met" is not.

| Gate | Criterion | Status | Evidence |
|---|---|---|---|
| G1 | | | |
| G2 | | | |

## Exit report

- [ ] `docs/phases/PHASE_N_REPORT.md` cites run ids, artifact hashes and measurements
- [ ] README, CHANGELOG and ROADMAP updated
- [ ] Known limitations and carried-over items listed
- [ ] Manual checks done by the owner (device, build hash, date)
- [ ] Owner acceptance recorded
