# ADR-0004: CodeMirror 6 as primary editor candidate; Monaco challenged; device gate decides

**Status:** Proposed (gate in Phase 2) · 2026-11-05

## Context
Spec §3: evaluate Monaco first (VS Code lineage), choose on actual Android device testing. Desk findings: Monaco 0.57.0 upstream states mobile browsers are **not supported**; bundle is multi-MB. CodeMirror 6 (view 6.43.15) is built around native mobile selection/IME, ~135 KB gz core, MIT. Both are WebView-hosted; neither is the IDE itself (workbench is Flutter).

## Decision
- Build the Phase 2 benchmark harness with **both** engines at identical scope.
- **CM6 is the primary candidate**; Monaco must overturn it with measured wins to be chosen.
- Gate metrics (EDITOR_ARCHITECTURE.md §1): cold load ≤ 800 ms, keystroke p95 ≤ 32 ms, zero IME corruption across the Gboard/CJK/hardware matrix, 1 MB file scroll jank < 5%, WebView RSS ≤ 250 MB, bundle ≤ 1.5 MB gz.
- If CM6 fails the IME suite outright: stop, reassess (native Flutter editor study) — never ship a corrupting editor.

## Consequences
- Editor workstream 2 starts only after the gate; protocol layer is engine-agnostic so the swap cost is bounded.
- LSP features (completion/hover/diagnostics UI) are wired by us to CM6 — more integration work than Monaco's built-ins, but mobile-correct.
- Decision recorded with raw numbers in PHASE_2_REPORT.md; this ADR flips to Accepted then.
