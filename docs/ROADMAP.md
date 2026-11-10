# CodeForge Roadmap

**Status:** Phase 0 complete (analysis) · Phase 1 accepted 2026-11-06 ([report](phases/PHASE_1_REPORT.md)) · **Phase 2 built and CI-verified, awaiting owner acceptance**. Exit report: [phases/PHASE_2_REPORT.md](phases/PHASE_2_REPORT.md) (plan: [phases/PHASE_2_PLAN.md](phases/PHASE_2_PLAN.md))
**Rule:** no phase starts while the previous has unresolved critical issues; every phase exits with a report citing CI run ids (spec §8/§12).

---

## Dependency graph

```
P0 audit ──► P1 foundation ──► P2 editor ──► P3 workspace/files ──► P4 runtime ──► P5 terminal/run
                  │                │                                   │              │
                  │                └── ADR-0004 gate                   │              ├──► P6 LSP ──► P9 debug
                  │                                                    │              │
                  └── design system feeds all UI                       └── ADR-0006/0007/0011 gates
                                                                                       P7 git ◄── P4
                                                                                       P8 extensions ◄── P2,P5
                                                                                       P10 release ◄── all
```

P6 and P7 can run in parallel after P5/P4 respectively; P8 after P2+P5. P1–P3 have **zero runtime dependency** — license/minSdk/terminal decisions (ADR-0006/0007/0011) do not block them.

## Phases

| Phase | Objective | MVP exit (measurable) | Key gates/decisions |
|---|---|---|---|
| **0 — Audit & feasibility** ✅ | Understand t1; validate architecture | This doc set: audit + 11 ADRs + Phase 1 plan | Corrections: sealed≠Seald, 136 MB≠50 MB; Node 26 verified |
| **1 — Foundation & design system** ✅ accepted 2026-11-06 (phone checks parked) | Premium navigable shell, CI alive | Home/workbench/settings + placeholders, adaptive 3 breakpoints, dark/light, goldens green, ci.yml green | Design tokens frozen (UI_DESIGN_SYSTEM v1.1, contrast-gated); G6 nav-frame profiling carried to Phase 2; ADR-0004 prep carried to Phase 2 |
| **2 — Workbench & editor** 🟢 built 2026-11-10, awaiting owner acceptance (phone checks parked; [report](phases/PHASE_2_REPORT.md)) | Real editing of local files | CM6 gate passed; multi-tab, save/restore, IME suite, kill-mid-edit zero loss, 1 MB perf | **ADR-0004 decided with numbers** (CodeMirror 6, 2026-11-06); large-file policy: plain text above 512 KiB, files over 10 MiB refused |
| **3 — Workspace & files** | Project-based IDE | SAF open-folder, explorer CRUD, file watch, state survives restart, recents | Storage scoping security review |
| **4 — Runtime integration** | Sealed userland alive | ExecModel+SealedShell gates green incl. **arm64 device**; versions via UI; ExecAudit=0; warm start ≤100 ms | **ADR-0006 terminal frontend**, **ADR-0007 minSdk**, **ADR-0011 license** resolved |
| **5 — Terminal & execution** | Write→run→output loop | Multi-session, Run File/Project (JS/Py/sh), flood-safe, kill-clean, E2E scenario part 1 | Native-addon limitation UX shipped |
| **6 — Language intelligence** | ≥1 full LSP | Pyright or TS LSP under sealed Node: completion/diagnostics/goto/rename; restart-on-crash; p95 ≤300 ms | LSP server compatibility spike first |
| **7 — Git & source control** | Professional local VCS | init/status/stage/commit/diff/branch on sealed Git; clone/pull/push with Keystore creds; big-repo no-freeze | SAF-tree git strategy decided |
| **8 — Extensions** | Safe extensibility | Manifest+permissions; themes/snippets/commands install/remove/disable; invalid rejected; crash-isolated | EXTENSION_API.md v1; interpreter choice |
| **9 — Debug & advanced** | ≥1 debugger | DAP for Node or Python: breakpoints/step/vars/stack; problems/output panels; multi-editor groups | DAP adapter under sealed runtime |
| **10 — Hardening & release** | Production candidate | All budgets green; device matrix pass; migrations tested; a11y; signed APK+AAB; reproducible pins | Public v1.0.0; Play internal track |

## Cross-phase tracks (continuous)

- **Testing:** pyramid grows per phase (TESTING.md). Since Phase 2 the emulator suite runs in the phase gate on every `[phase-gate]` commit; a nightly schedule is not set up yet.
- **Performance:** benchmark suite from Phase 2; budgets enforced at every gate (PERFORMANCE.md). *As built in Phase 2: the engine benchmark and the large-file group run in every gate, which records the editor's budget misses as evidence instead of failing, because the emulator renders in software.*
- **Security:** review at each boundary introduction (SECURITY.md); supply-chain pins from Phase 4.
- **Docs:** every PR updates its doc; phase exit writes `docs/phases/PHASE_N_REPORT.md`; CHANGELOG per release.
- **Upstream:** track t1 PR #81 merge; re-vendor procedure in native/PROVENANCE.md; contribute fixes upstream where generic.

## Parked owner checks

On 2026-11-06 the owner parked every check that needs their phone. Where an emulator can stand in, an automated counterpart keeps running in CI. Each check will be run when the owner resumes phone testing. [PHASE_2_REPORT.md](phases/PHASE_2_REPORT.md) §8 says what each Phase 2 check needs, and which builds to use.

| Check | From | What it needs | Emulator counterpart |
|---|---|---|---|
| TalkBack spot-check (10 items, plus 5 for Phase 2's chrome) | Phase 1 report §8, Phase 2 report §8 | a phone with TalkBack, the CI debug APK | `accessibility_test` (tap targets, labels, 1.3× text, the new chrome) |
| ~~Navigation frame profile in profile mode~~ **done 2026-11-06** | Phase 1 G6 | a phone (Flutter refuses profile mode on emulators) | result: 3.4 % of frames over 32 ms on a realme C51 (PHASE_1_REPORT §7) |
| ~~Editor engine benchmark on arm64 (ADR-0004)~~ **done 2026-11-06** | Phase 2 G1 | a phone, the in-app benchmark screen (profile APK) | result: CodeMirror 6 chosen (ADR-0004 Accepted); the emulator runs the same benchmark in every phase gate |
| Gboard IME matrix (swipe, voice, CJK, emoji) | Phase 2 G1 | a phone with Gboard | scripted composition events on the emulator |
| Selection matrix: handles at line boundaries, copy and paste, undo and redo | Phase 2 W6 (an ADR-0004 carry-over) | a phone, about 10 minutes ([PHASE_2_SELECTION_MATRIX.md](phases/PHASE_2_SELECTION_MATRIX.md)) | none: Android System WebView draws the handles |
| Large files on arm64 with the policy: 1 MiB typing and scrolling (ADR-0004) | Phase 2 W7 | a phone with a large file in the workspace. That needs a computer in Phase 2; the report proposes a Developer action that writes the gate's files | the gate's large-file group |
| Memory on hardware (ADR-0004) | Phase 2 W7 | a phone and a computer with adb (`dumpsys meminfo`) | the gate's release-build measurement (224.6 MB) |
| FULL against NORMAL on flash, and the save pause (ADR-0008) | Phase 2 W7 | a phone with a large file (the same blocker), or adb | the gate's session-store timings |

## Owner decision queue (non-blocking for P1–P3)

| Decision | Needed by | ADR |
|---|---|---|
| Android Auto Backup: opt out until Phase 10 designs backup, or keep it and tell the user (found in Phase 2 W8) | Phase 3 start | SECURITY §4 |
| License direction (GPLv3 vs permissive-with-xterm) | Phase 4 start (affects terminal frontend) | 0011 |
| minSdk 26 verification appetite vs raise to 29 | Phase 4 exit | 0007 |
| arm64 device access for gates (self-hosted runner or manual) | Phase 4 exit | 0009 |
| Play Console account + upload key | Phase 10 (prep at Phase 4) | 0010 |
