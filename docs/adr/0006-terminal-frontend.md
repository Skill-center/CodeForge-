# ADR-0006: Terminal frontend — native terminal-view (primary candidate) vs xterm.js (fallback), gated in Phase 4

**Status:** Proposed (gate in Phase 4; interacts with ADR-0011) · 2026-11-05

## Context
Spec's stack table names xterm.js. Spec §2 also mandates reusing existing assets: t1 ships the Termux `terminal-view`/`terminal-emulator` modules — a native Android terminal frontend with years of mobile touch/IME/selection hardening. Two complications: (a) Flutter embedding of a native View (PlatformView) has composition overhead to measure; (b) the Termux-modified modules carry a conservative GPLv3 reading (audit §7), while xterm.js is MIT.

## Decision
- Backend is settled either way: vendored PTY JNI + `TerminalSession` + `HarnessSession` (TERMINAL_ARCHITECTURE.md §1).
- **Candidate A (primary):** native `terminal-view` via Flutter PlatformView — maximum reuse, best-known mobile behavior.
- **Candidate B (fallback):** xterm.js 6.0 in a hardened WebView — spec-table default, MIT-clean, consistent with the editor stack.
- Phase 4 gate on arm64 hardware: echo latency p95 ≤ 50 ms; IME matrix zero loss; 10 MB flood keeps UI responsive; memory delta ≤ 80 MB; composition jank < 5%.
- Decision rule: A passes + owner accepts GPLv3 → A. Owner wants permissive license → B (PTY reuse under Apache-2.0 jackpal lineage, legal-reviewed). A fails perf → B.

## Consequences
- Flutter-side terminal UX (tabs, sheets, extra-keys, run integration) is frontend-agnostic — built once.
- If B: the terminal parser/view modules are not vendored; only PTY JNI + preload travel; license exposure shrinks (feeds ADR-0011).
- Either way the terminal connects to the existing Linux environment, never a replacement (spec §6.4).
