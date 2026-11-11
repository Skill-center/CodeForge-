# ADR-0011: License — pending owner decision; GPLv3 exposure mapped; release-gating

**Status:** Pending (owner) · 2026-11-05 · Blocks: first binary release, terminal frontend final choice (ADR-0006) · **2026-11-11:** the owner confirmed that the decision is made by Phase 4's start, and the interim rules stay until then

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

## Interim rules (until decided)
1. All CodeForge-original code keeps clear ownership headers; no license file committed yet (avoid implying a grant).
2. Nothing GPL-derived is vendored before the decision (Phase 4 vendoring starts with the decision).
3. `THIRD_PARTY_NOTICES.md` + source-offer doc drafted at Phase 4 regardless of path.
4. **No binary release under any path until this ADR is Accepted.**

## Consequences
- Phase 1–3 proceed unblocked (no vendored runtime yet).
- The terminal frontend gate (ADR-0006) and this decision resolve together in Phase 4.
- t1 itself should gain an explicit LICENSE (owner action, tracked in ROADMAP). On 2026-11-11 the owner chose to merge t1's PR #81 now, and to add t1's LICENSE once this ADR is decided.
