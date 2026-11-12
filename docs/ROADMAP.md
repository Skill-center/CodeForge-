# CodeForge Roadmap

**Status:** Phase 0 complete (analysis) · Phase 1 accepted 2026-11-06 ([report](phases/PHASE_1_REPORT.md)) · Phase 2 accepted 2026-11-10 ([report](phases/PHASE_2_REPORT.md)) · **Phase 3 in progress** (W1, W2 and W3 done): [phases/PHASE_3_PLAN.md](phases/PHASE_3_PLAN.md)
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
| **2 — Workbench & editor** ✅ accepted 2026-11-10 (phone checks parked; [report](phases/PHASE_2_REPORT.md)) | Real editing of local files | CM6 gate passed; multi-tab, save/restore, IME suite, kill-mid-edit zero loss, 1 MB perf | **ADR-0004 decided with numbers** (CodeMirror 6, 2026-11-06); large-file policy: plain text above 512 KiB, files over 10 MiB refused |
| **3 — Workspace & files** ✅ accepted 2026-11-12 (phone checks: one session, after the next slice; [plan](phases/PHASE_3_PLAN.md), [report](phases/PHASE_3_REPORT.md)) | Project-based IDE | SAF open-folder, explorer CRUD, file watch, state survives restart, recents | Storage scoping security review |
| **4 — Runtime integration** 🟡 planned 2026-11-12 ([plan](phases/PHASE_4_PLAN.md)); W1 is the toolchain upgrade | Sealed userland alive | ExecModel+SealedShell gates green incl. **arm64 device** (Firebase Test Lab); versions via UI; ExecAudit=0; warm start ≤100 ms; search across files (ripgrep for projects, the app scans SAF folders) | **ADR-0006 terminal frontend** (by its rule), **ADR-0007 minSdk** (26 if the API 26–28 gate passes), **ADR-0011 license** decided by the phase's start |
| **5 — Terminal & execution** | Write→run→output loop | Multi-session, Run File/Project (JS/Py/sh), flood-safe, kill-clean, E2E scenario part 1 | Native-addon limitation UX shipped |
| **6 — Language intelligence** | ≥1 full LSP | Pyright or TS LSP under sealed Node: completion/diagnostics/goto/rename; restart-on-crash; p95 ≤300 ms | LSP server compatibility spike first |
| **7 — Git & source control** | Professional local VCS | init/status/stage/commit/diff/branch on sealed Git; clone/pull/push with Keystore creds; big-repo no-freeze | SAF-tree git strategy decided |
| **8 — Extensions** | Safe extensibility | Manifest+permissions; themes/snippets/commands install/remove/disable; invalid rejected; crash-isolated | EXTENSION_API.md v1; interpreter choice |
| **9 — Debug & advanced** | ≥1 debugger | DAP for Node or Python: breakpoints/step/vars/stack; problems/output panels; multi-editor groups | DAP adapter under sealed runtime |
| **10 — Hardening & release** | Production candidate | All budgets green; device matrix pass; migrations tested; a11y; signed APK+AAB; reproducible pins | Public v1.0.0; Play internal track |

## Cross-phase tracks (continuous)

- **Testing:** pyramid grows per phase (TESTING.md). Since Phase 2 the emulator suite runs in the phase gate on every `[phase-gate]` commit. There is no nightly run: by the owner's decision (2026-11-11), the gate runs once per work package.
- **Performance:** benchmark suite from Phase 2; budgets enforced at every gate (PERFORMANCE.md). *As built in Phase 2: the engine benchmark and the large-file group run in every gate, which records the editor's budget misses as evidence instead of failing, because the emulator renders in software.*
- **Security:** review at each boundary introduction (SECURITY.md); supply-chain pins from Phase 4.
- **Docs:** every PR updates its doc; phase exit writes `docs/phases/PHASE_N_REPORT.md`; CHANGELOG per release.
- **Upstream:** the owner merges t1 PR #81 (decision 2026-11-11), and t1's LICENSE follows ADR-0011; re-vendor procedure in native/PROVENANCE.md; contribute fixes upstream where generic.
- **Repository:** all work stays on the working branch `arena/f57c33ee-codeforge` until v1 or later, and `main` keeps its initial commit (owner decision 2026-11-11). GitHub runs scheduled workflows only from the default branch, so none is scheduled.

## Parked owner checks

On 2026-11-06 the owner parked every check that needs their phone. Where an emulator can stand in, an automated counterpart keeps running in CI. On 2026-11-11 the owner chose to run them all in one session at Phase 3's exit: [PHASE_3_PHONE_CHECKLIST.md](phases/PHASE_3_PHONE_CHECKLIST.md) (Phase 3 W7) has every open check below. The owner runs it after the next slice of work (decided 2026-11-12). [PHASE_2_REPORT.md](phases/PHASE_2_REPORT.md) §8 says what each Phase 2 check needs, and which builds to use.

| Check | From | What it needs | Emulator counterpart |
|---|---|---|---|
| TalkBack spot-check (16 items over Phases 1–3's chrome, [checklist](phases/PHASE_3_PHONE_CHECKLIST.md) §7) | Phase 1 report §8, Phase 2 report §8 | a phone with TalkBack, the CI debug APK | `accessibility_test` (tap targets, labels, 1.3× text, the new chrome) |
| ~~Navigation frame profile in profile mode~~ **done 2026-11-06** | Phase 1 G6 | a phone (Flutter refuses profile mode on emulators) | result: 3.4 % of frames over 32 ms on a realme C51 (PHASE_1_REPORT §7) |
| ~~Editor engine benchmark on arm64 (ADR-0004)~~ **done 2026-11-06** | Phase 2 G1 | a phone, the in-app benchmark screen (profile APK) | result: CodeMirror 6 chosen (ADR-0004 Accepted); the emulator runs the same benchmark in every phase gate |
| Gboard IME matrix (swipe, voice, CJK, emoji) | Phase 2 G1 | a phone with Gboard | scripted composition events on the emulator |
| Selection matrix: handles at line boundaries, copy and paste, undo and redo | Phase 2 W6 (an ADR-0004 carry-over) | a phone, about 10 minutes ([PHASE_2_SELECTION_MATRIX.md](phases/PHASE_2_SELECTION_MATRIX.md)) | none: Android System WebView draws the handles |
| Large files on arm64 with the policy: 1 MiB typing and scrolling (ADR-0004) | Phase 2 W7 | **a phone only, since Phase 3 W1:** Settings → Developer → *Create large test files* writes the gate's files into the workspace, and the engine benchmark's plain-text pass measures the 1 MiB file as plain text (phone profile APK; [checklist](phases/PHASE_2_PHONE_CHECKLIST.md)) | the gate's large-file group |
| Memory on hardware (ADR-0004) | Phase 2 W7 | a phone and a computer with adb (`dumpsys meminfo`) | the gate's release-build measurement (224.6 MB) |
| FULL against NORMAL on flash, and the save pause (ADR-0008) | Phase 2 W7 | the save pause: **a phone only, since Phase 3 W1** (the Developer action's files); FULL against NORMAL: a phone and adb, to time the store | the gate's session-store timings; FULL against NORMAL moved to Phase 4's Firebase Test Lab (owner decision 2026-11-12) |
| Backup with a real Google account | Phase 3 W1 (ADR-0012) | a phone with a Google account and device backup on, the W1 phone APK ([checklist](phases/PHASE_2_PHONE_CHECKLIST.md) §8.2) | the gate's `backup` group (Android's local transport) |
| Folder picker and a folder workspace on the owner's phone, and since W3 the picker opening at a folder's old place (*Reconnect*) | Phase 3 W2 | a phone, whose picker may differ from the emulator's | the gate's `folders` group, and since W3 the restore pair |
| Impeller on hardware (W6 switched to it), and the release cold start with it (median of 10), which went over 1500 ms in two of Phase 3's five Impeller gates on the emulator | Phase 3 W6 | a phone, the profile APK (a release build starts no slower), a computer with adb for the cold start | the gate runs with Impeller (43238952262 and later), and times the same build with Skia (since 4ca62ed) |

## Owner decision queue (non-blocking for P1–P3)

| Decision | Needed by | ADR |
|---|---|---|
| ~~Android Auto Backup: opt out until Phase 10 designs backup, or keep it and tell the user (found in Phase 2 W8)~~ **decided 2026-11-10:** an offer to the user, off by default; built in Phase 3 W1 | Phase 3 start | 0012 |
| License direction (GPLv3 vs permissive-with-xterm) · **2026-11-11:** the owner decides by Phase 4's start; the interim rules stay | Phase 4 start (affects terminal frontend) | 0011 |
| ~~Terminal frontend~~ **decided 2026-11-11:** ADR-0006's rule: Termux's terminal view if the licence is GPLv3 and it passes Phase 4's arm64 gate, otherwise xterm.js | Phase 4 | 0006 |
| ~~minSdk 26 verification appetite vs raise to 29~~ **decided 2026-11-11:** keep 26 and verify it on API 26–28 emulators in Phase 4; a raise to 29 needs the owner's sign-off | Phase 4 exit | 0007 |
| ~~arm64 device access for gates (self-hosted runner or manual)~~ **decided 2026-11-11:** Firebase Test Lab's real phones, for the tests that need no computer attached; owner action by Phase 4: a free Firebase project and one CI credential · **2026-11-12:** the owner adds it after the next slice | Phase 4 exit | 0009 |
| ~~Play Console account + upload key~~ **decided 2026-11-11:** prepared at Phase 4; the closed test that new personal accounts need (12 testers, 14 days) starts well before Phase 10 | Phase 10 (prep at Phase 4) | 0010 |
| t1: merge PR #81 and add a LICENSE · **2026-11-11:** the owner merges PR #81 now; the LICENSE follows ADR-0011 · **merged 2026-11-11** as PR #229 (the same branch; main `7b496c3`, the audited tree); the LICENSE still follows ADR-0011 | Phase 4 (vendoring) | 0011 |
| ~~G7's release cold start with Impeller: over 1500 ms on the emulator in two of Phase 3's five Impeller gates~~ **decided 2026-11-12:** the exit session's phone figure decides, for now; Impeller stays | Phase 3 acceptance | — |
| ~~Flutter 3.50.0, which needs AGP 9.1.1 and KGP 2.4.10 or later~~ **decided 2026-11-12:** all upgraded together, to the 3.50.0 template's AGP 9.3.1, Kotlin 2.4.20 and Gradle 9.5.0 (BUILD_AND_RELEASE §3) | after Phase 3's acceptance | — |
| arm64 tests after Firebase Test Lab shuts down on 2027-09-30 (found 2026-11-12; its successor, Google Cloud's Developer Device Platform, needs billing): the successor platform, the owner's phone sessions, or both ([PHASE_4_PLAN](phases/PHASE_4_PLAN.md) §0) | before 2027-09-30 | 0009 |

## Placed later, phase not chosen yet

- **Text encodings other than UTF-8:** open, edit and save in the original encoding (owner decision 2026-11-11). Until then they are refused, never converted.
