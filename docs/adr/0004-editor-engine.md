# ADR-0004: CodeMirror 6 as primary editor candidate; Monaco challenged; device gate decides

**Status:** Proposed (gate in Phase 2) · 2026-11-05

## Context
Spec §3: evaluate Monaco first (VS Code lineage), choose on actual Android device testing. Desk findings: Monaco 0.57.0 upstream states mobile browsers are **not supported**; bundle is multi-MB. CodeMirror 6 (view 6.43.15) is built around native mobile selection/IME, ~135 KB gz core, MIT. Both are WebView-hosted; neither is the IDE itself (workbench is Flutter).

## Decision
- Build the Phase 2 benchmark harness with **both** engines at identical scope.
- **CM6 is the primary candidate**; Monaco must overturn it with measured wins to be chosen.
- Gate metrics (EDITOR_ARCHITECTURE.md §1): cold load ≤ 800 ms, keystroke p95 ≤ 32 ms, zero IME corruption across the Gboard/CJK/hardware matrix, 1 MB file scroll jank < 5%, WebView RSS ≤ 250 MB, bundle ≤ 1.5 MB gz.
- If CM6 fails the IME suite outright: stop, reassess (native Flutter editor study) — never ship a corrupting editor.

## Evidence so far (Phase 2 W3)
- **Harness:** built at identical scope for both engines (`editor/bench/`; how each metric is measured: EDITOR_ARCHITECTURE.md §1, "As built in W3").
- **Desk run, indicative only:** headless Chromium 153 on a Linux sandbox at 412×780, DPR 2, software rendering. This is not an Android WebView and not the gate.

  | Metric | CM6 | Monaco |
  |---|---|---|
  | First frame | 102 ms | 412 ms |
  | Typing p95, engine path | 17.6 ms | 19.6 ms |
  | Input → frame p95, DevTools, Android user agent | 17.8 ms | 11.9 ms (max 72.7) |
  | 1 MiB open | 49 ms | 126 ms |
  | 1 MiB typing p95, mid-file | 133 ms | 34 ms |
  | Composition | 9/9 | 9/9 |
  | Page size, gzip | 293.7 KiB | 1029.4 KiB |

  Both are under the 1.5 MB size budget. CM6 loads faster. Monaco types faster in the middle of a 1 MiB file, which is a lead for W7's large-file policy to answer, for example with highlighting limits.
- **Emulator gate:** pending the first phase-gate run with the benchmark. Its numbers are committed to `app/ci-results/gate/editor_bench.json` and will be added here.
- **Phone:** pending the owner's run of `docs/phases/PHASE_2_PHONE_CHECKLIST.md`. It is non-blocking (PHASE_2_PLAN.md §5).

## Consequences
- Editor workstream 2 starts only after the gate; protocol layer is engine-agnostic so the swap cost is bounded.
- LSP features (completion/hover/diagnostics UI) are wired by us to CM6 — more integration work than Monaco's built-ins, but mobile-correct.
- Decision recorded with raw numbers in PHASE_2_REPORT.md; this ADR flips to Accepted then.
