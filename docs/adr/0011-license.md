# ADR-0011: License — Apache-2.0 (path B); GPLv3 exposure kept out; release-gating

**Status:** **Accepted (owner decision 2026-11-12): path B, Apache-2.0** · proposed 2026-11-05 ("decide later") · **2026-11-11:** the owner confirmed that the decision is made by Phase 4's start

## Context
Owner chose "decide later". The audit found:
- **t1 has no LICENSE file.** Its original code (harness-core, sealed-runtime, preload JNI, scripts, CI) is owner-written (m-cyber12) — rights held by the owner, freely licensable.
- **terminal-emulator / terminal-view** derive from termux/termux-app @ 8629e632. Upstream root license: **GPLv3-only**, with an exception noting jackpal Android-Terminal-Emulator code is Apache-2.0. Copied files lack headers (one support file carries Apache). Conservative reading: the Termux-modified modules are GPLv3; shipping them makes the combined Android app a GPLv3 work.
- **Userland binaries** (bash, git, coreutils, …) are mixed OSS incl. GPL, shipped as data/executables in the APK — aggregation, compatible with any app license, but requires license texts + a source offer (Termux publishes build sources).
- All Flutter/pub/npm dependencies chosen so far are permissive (MIT/BSD/Apache).

## Decision paths (owner picks one by Phase 4 start)
| Path | App license | Terminal frontend | Obligations |
|---|---|---|---|
| **A. GPLv3 app** | GPLv3 | native terminal-view (max reuse) | Full source public (already is), license texts, userland source offer |
| **B. Permissive app (Apache-2.0/MIT)** | Apache-2.0 or MIT | xterm.js (B in ADR-0006); PTY JNI only under verified Apache-2.0 lineage or rewritten (~200 lines, clean-room) | Do not vendor Termux-modified modules; userland notices + source offer still required |
| **C. Source-available/proprietary** | custom | same constraints as B | Legal review of every vendored file; userland obligations unchanged |

**Found while planning Phase 4 (2026-11-12, [PHASE_4_PLAN](../phases/PHASE_4_PLAN.md) §0):** the runtime core that Phase 4 vendors needs no Termux code. `ExecModelTest`, `SealedShellTest`, the command runner (`ProcessBuilder`), the environment, the toolchain probes, the payload installer, the `sealed-runtime` kernel and the preload helpers are t1's own; only `HarnessSession` (on Termux's `TerminalSession`), the PTY in `termux.c` and `terminal-view` are Termux-derived. So the path decides the terminal, not the runtime core. One more point for path A: t1's pack installer uses Google's Play Feature Delivery library, published under the Play Core Software Development Kit Terms of Service rather than an open-source licence, which a GPLv3 Play build with packs would combine with Termux's GPLv3 code.

## Decision (2026-11-12, the owner)
**Path B, Apache-2.0.** Asked with Phase 4's plan, the owner chose the permissive path with Apache-2.0, as recommended for its explicit patent grant and for keeping both distribution channels free of licence conflicts.
- CodeForge's original code is licensed under the Apache License 2.0: `LICENSE` at the repository's root. Third-party components keep their own licences (THIRD_PARTY_NOTICES.md, drafted in Phase 4).
- No GPL code is linked into the app. Termux's modified `terminal-emulator` and `terminal-view` modules, `termux.c` and t1's `HarnessSession` (built on Termux's `TerminalSession`) are never vendored. Phase 5 writes the PTY clean-room (about 200 lines), or reuses `termux.c` only if a legal review verifies its Apache-2.0 jackpal lineage.
- The terminal frontend follows by ADR-0006's rule: xterm.js (MIT).
- t1 takes the same licence (an owner action). Phase 4 then vendors t1's own code (the `sealed-runtime` kernel, the `harness-core` subset, the preload helpers, the payload scripts) from that commit, with its attribution in `native/PROVENANCE.md`.
- The userland (bash, git, coreutils, …) is still an aggregate: its licence texts and a source offer are published before any binary release (ADR-0010). Play Feature Delivery's library, if a pack ever needs it, raises no conflict with Apache-2.0.

## Interim rules (until decided; ended 2026-11-12)
1. All CodeForge-original code keeps clear ownership headers; no license file committed yet (avoid implying a grant).
2. Nothing GPL-derived is vendored before the decision (Phase 4 vendoring starts with the decision).
3. `THIRD_PARTY_NOTICES.md` + source-offer doc drafted at Phase 4 regardless of path.
4. **No binary release under any path until this ADR is Accepted.**

## Consequences
- Phase 1–3 proceed unblocked (no vendored runtime yet).
- The terminal frontend gate (ADR-0006) and this decision resolve together in Phase 4.
- t1 itself should gain an explicit LICENSE (owner action, tracked in ROADMAP). On 2026-11-11 the owner chose to merge t1's PR #81 now, and to add t1's LICENSE once this ADR is decided. **2026-11-12:** t1's code is merged (PR #229), and its LICENSE is Apache-2.0, like CodeForge's.
