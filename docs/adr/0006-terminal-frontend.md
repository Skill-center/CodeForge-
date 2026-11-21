# ADR-0006: Terminal frontend — xterm.js (decided by the licence, 2026-11-12); native terminal-view not used

**Status:** **Accepted (2026-11-12, by its rule): Candidate B, xterm.js.** The owner chose a permissive licence (ADR-0011, Apache-2.0), so Termux's terminal modules are not vendored · proposed 2026-11-05 · **2026-11-11:** the owner confirmed the decision rule below

## Context
Spec's stack table names xterm.js. Spec §2 also mandates reusing existing assets: t1 ships the Termux `terminal-view`/`terminal-emulator` modules — a native Android terminal frontend with years of mobile touch/IME/selection hardening. Two complications: (a) Flutter embedding of a native View (PlatformView) has composition overhead to measure; (b) the Termux-modified modules carry a conservative GPLv3 reading (audit §7), while xterm.js is MIT.

## Decision
- Backend is settled either way: vendored PTY JNI + `TerminalSession` + `HarnessSession` (TERMINAL_ARCHITECTURE.md §1).
- **Candidate A (primary):** native `terminal-view` via Flutter PlatformView — maximum reuse, best-known mobile behavior.
- **Candidate B (fallback):** xterm.js 6.0 in a hardened WebView — spec-table default, MIT-clean, consistent with the editor stack.
- Phase 4 gate on arm64 hardware: echo latency p95 ≤ 50 ms; IME matrix zero loss; 10 MB flood keeps UI responsive; memory delta ≤ 80 MB; composition jank < 5%.
- Decision rule: A passes + owner accepts GPLv3 → A. Owner wants permissive license → B (PTY reuse under Apache-2.0 jackpal lineage, legal-reviewed). A fails perf → B.

## Outcome (2026-11-12)
- **xterm.js** in a hardened WebView, built in Phase 5 with the editor's page kit and bridge rules. The Phase 4 gate's budgets (input-to-echo p95 ≤ 50 ms, zero lost IME input, a 10 MB flood without a frozen UI, a memory delta ≤ 80 MB) become xterm.js's budgets in Phase 5's terminal gate, on arm64 hardware (Test Lab) and, for the IME, the owner's phone. A PlatformView's composition cost no longer applies.
- **The backend changes with it:** the PTY and the session are CodeForge's own (ADR-0011), on t1's environment rules (TERMINAL_ARCHITECTURE §1). Of the PTY stack, only t1's preload helpers travel.

## Consequences
- Flutter-side terminal UX (tabs, sheets, extra-keys, run integration) is frontend-agnostic — built once.
- If B: the terminal parser/view modules are not vendored; only PTY JNI + preload travel; license exposure shrinks (feeds ADR-0011).
- Either way the terminal connects to the existing Linux environment, never a replacement (spec §6.4).

## As built (Phase 5 W6, 2026-11-21): the budgets measured, the renderer chosen
- **Measured on Test Lab's Pixel 8a with Android 14** (CI 44868218258, a profile build), in the real app with a session at the panel's full stop (TERMINAL_ARCHITECTURE §2.2 has the method):
  - **input to echo:** 48.4 ms at the 95th percentile with WebGL, within 50 ms; 62.3 ms with the DOM renderer;
  - **zero lost input through the IME:** the emulator's composition suite, 10 cases, lost nothing (phase gate 44870622961); Gboard on a phone is the owner's checklist (PHASE_5_PLAN W7);
  - **a 10 MB flood without a frozen UI:** whole, in 3.0 s, with 0.5 % of Flutter's frames over 32 ms and none frozen;
  - **a memory delta of 80 MB or less: not met at first.** The terminal open with no output cost 85.2 MB at the full stop (73.5 MB at half), most of it a second WebView's surfaces; once settled after the flood, 153.7 MB, most of the growth garbage V8 had not collected and WebGL's buffers. Recorded with the breakdown in PHASE_5_PLAN *As built (W6)*, and decided by the owner (below).
- **The renderer: WebGL** (`@xterm/addon-webgl` 0.19.0) where the GPU is real, xterm.js's DOM renderer elsewhere (no WebGL2, a software GPU, a lost context). With WebGL the flood took 3.0 s against 4.1 s, the page's slow frames were 13.2 % against 44.4 %, and only WebGL kept the echo within budget. It costs about 35 MB in the renderer and 17 MB of graphics after a flood.
- **The memory budget, as the owner decided on 2026-11-21** (PHASE_5_PLAN §10, item 7: work it down first, then judge what remains as found). The memory work: **Hybrid Composition++ app-wide** (the manifest's `EnableHcpp`: on Android 14 and later with Vulkan the engine composes both WebViews with SurfaceControl rather than copying them into textures), **the host's messages through a MessagePort** rather than a script per batch, and **WebGL for the shown session only.** On the same phone (CI 44889362793): **53.6 MB with the terminal open** at its full stop (38.1 MB at half), within 80 MB, and **114.8 MB once settled after the flood**; echo 37.5 ms at the 95th percentile (40.6 ms with the DOM renderer), and none of Flutter's frames over 32 ms during the flood. **The budget as built:** the terminal open and idle at the panel's full stop, against the app before any terminal, **within 90 MB**, judged on Test Lab's phone (CI 44893095694 passed it with 55.3 MB, and Phase 5's exit gate, CI 44900930980, with 44.6 MB); a flood's growth is recorded, not judged (52 of its 61 MB on the phone were the app's graphics, where Android's WebView keeps its GPU memory, the same after the DOM renderer's flood).
- **The renderer stays WebGL** after the memory work: with Hybrid Composition++ the DOM renderer is within budget too, but phones without it (Android 13 and older, or no Vulkan) keep Flutter's texture layer, where only WebGL kept the echo within 50 ms.
- **Candidate A's composition cost** (a PlatformView's jank) has no counterpart: the terminal is a WebView like the editor's, and Flutter's frames are what the flood is judged on.

