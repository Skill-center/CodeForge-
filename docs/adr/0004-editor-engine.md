# ADR-0004: CodeMirror 6 is the editor engine (Monaco challenged and measured)

**Status:** **Accepted** 2026-11-06 (Phase 2 W3): CodeMirror 6, on the emulator gate and the owner's phone run · proposed 2026-11-05

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
- **Emulator gate** (phase gate [42206498197](https://github.com/Skill-center/CodeForge-/actions/runs/42206498197), evidence in `app/ci-results/gate/editor_bench.json`): API 36 `google_apis` x86_64 with KVM, a software GPU (swiftshader) and WebView Chrome 133. It ran a debug APK, because Flutter refuses profile mode on emulators. The figures are medians of 3 fresh runs per engine; the driver figures come from one session per engine.

  | Metric (budget) | CM6 | Monaco |
  |---|---|---|
  | Cold load → first editor frame (≤ 800 ms) | **364.8 ms** ✓ | 1145.7 ms ✗ |
  | Typing p95, engine path (≤ 32 ms) | 164.3 ms ✗ (p50 96.3) | 178 ms ✗ (p50 84.7) |
  | Input → frame p95, DevTools keys (≤ 32 ms) | 126.9 ms ✗ (p50 43.7) | 136.3 ms ✗ (p50 68.7) |
  | 1 MiB scroll, frames over 32 ms (< 5 %) | 95.2 % ✗ | 94.7 % ✗ |
  | Composition failures, 9 cases (0) | **0** ✓ | **0** ✓ |
  | Memory, app + renderer PSS (≤ 250 MB) | 509.2 MB ✗ (renderer 121.5) | 633.2 MB ✗ (renderer 186.7) |
  | Size, gzip (≤ 1.5 MB) | **300,795 B** ✓ | 1,054,113 B ✓ |
  | 1 MiB open / typing p95 | 240 / 188 ms | 529 / 233.4 ms |

- **Reading the emulator numbers:**
  - **The emulator's rendering rate bounds every frame-timed number, not the engine.** While scrolling, both engines produced 18–22 frames in 3 s, about 7 fps, with intervals of 217–267 ms on the 16.7 ms vsync grid. In the desk run the same pages scrolled with 0–1 % slow frames. The typing, input and scrolling budgets therefore can't be judged on the CI emulator.
  - **Memory is inflated the same way.** The debug app process carries the Dart JIT VM and, with software GL, WebView's in-process GPU buffers.
  - **CM6 is ahead on every metric but one.** It loads 3× faster, opens 1 MiB 2.2× faster, uses 124 MB less memory, is 3.5× smaller, has lower DevTools input latency (p50 and p95) and engine-path typing p95, and matches Monaco's composition correctness. Monaco's one lead is engine-path typing p50, by 12 ms. Monaco has no measured win that could overturn CM6.
  - **A re-run kept the ranking, with noisy absolutes.** After the selection fix, phase gate [42216855184](https://github.com/Skill-center/CodeForge-/actions/runs/42216855184) (commit 58d91fa) measured, CM6 against Monaco: cold load 307.6 against 522.1 ms, DevTools input p95 45.7 against 95.2 ms, memory 505.9 against 571.9 MB, 1 MiB open 184.6 against 478.1 ms, and 0 composition failures for both. Engine-path typing p95 was 134.5 against 129.4 ms, so Monaco led that one by 5 ms this time. Monaco's cold load moved from 1145.7 to 522.1 ms between the two runs, so a single emulator figure is noisy. The decision rests on the phone run.
- **Status after the emulator gate:** CM6 passes the composition suite, so there is no stop-and-reassess. Cold load, composition and size are within budget. The typing, input, scrolling and memory budgets are not met on the emulator, and only hardware can settle them; the phone run below does.
- **Phone run** (owner, 2026-11-06): a **realme C51** (RMX3830: Unisoc T612, 2× Cortex-A75 + 6× A55 at 1.8 GHz, Mali-G57, 4 GB RAM, 720×1600, Android 13), a deliberately low-end phone, running the profile arm64 APK from gate 42206498197. It did two benchmark sessions of 3 runs per engine; the values are the session medians (`docs/phases/evidence/phase2-phone-2026-11-06/`).

  | Metric (budget) | CM6, session 1 / 2 | Monaco, session 1 / 2 |
  |---|---|---|
  | Cold load → first editor frame (≤ 800 ms) | **217.1 / 228.2 ms** ✓ | 743.2 / 743.7 ms ✓ |
  | Typing p95, engine path (≤ 32 ms) | **21.7 / 22.4 ms** ✓ (p50 19.5) | 25.4 / 24.4 ms ✓ (p50 19.6 / 19.4) |
  | 1 MiB scroll, frames over 32 ms (< 5 %) | **1.7 %** ✓ / 9.8 % ✗ | 37.4 / 35.7 % ✗ |
  | 1 MiB open | 89.8 / 88.7 ms | 266.2 / 346.2 ms |
  | 1 MiB typing p95, mid-file | 133.2 / 136.0 ms | **45.4 / 37.2 ms** |
  | Features and highlighting | ok | ok |

  The owner reported a smooth experience with a well-behaved cursor, and one selection bug. On the cursor's line, selected text showed handles but no highlight: the active line's opaque background covered CodeMirror's selection layer, in the shipped editor as well as the benchmark page. It was fixed in the same change (`editor/src/editor/active_line.ts`): as in VS Code, a line is highlighted only around a plain cursor. Before and after renders are kept with the evidence. A second quirk was that a selection ending at the start of a line showed its end handle at the end of the previous line; it is listed for W6's selection matrix.

## Decision (2026-11-06)

**CodeMirror 6.** On a low-end phone it meets the cold-load budget (3.3–3.4× faster than Monaco) and the typing budget, and it has 3.6–22× fewer slow frames than Monaco when scrolling a 1 MiB file. It is 3.5× smaller and uses 124 MB less memory on the emulator, and it passes every composition case, as Monaco does. Monaco's only measured win is typing in the middle of a 1 MiB file (37–45 vs 133–136 ms p95). That does not overturn CM6: it is a large-file problem that W7 owns.

Carried forward, not met yet:
- **Large files (W7, G7):** CM6 typing p95 of 133–136 ms in the middle of a 1 MiB file, and scrolling at 1.7–9.8 % slow frames on the low-end phone. The large-file policy (for example, limiting highlighting above a size threshold) must bring both within budget, measured again on hardware.
- **Memory:** the ≤ 250 MB budget was only measured on the emulator's debug build (CM6: 509 MB for app + renderer; 121.5 MB for the renderer alone). A release-like measurement on hardware is still needed; W7 adds it.
- **Selection handles at line boundaries:** part of W6's manual selection matrix.

**Answered in W7** (PHASE_2_PLAN.md, As built W7; EDITOR_ARCHITECTURE.md §10):
- **Large files:** the large-file policy opens a document over 512 KiB as plain text, so a 1 MiB file is highlighted only if the user asks. On the emulator, a 1 MiB `.js` file then typed like a plain-text file of the same size and had no long tasks after the open (gate 42659207710). Whether that brings the phone within the typing and scroll budgets needs the phone. The runs on hardware are parked (PHASE_2_PLAN.md §5), so this stays open until one. The emulator's scroll numbers cannot answer it: 85 to 100 % of frames are slow for every file, highlighted or not, because it renders in software.
- **Memory:** a release build on the emulator, restoring a session with the 1 MiB file open, took 236 MB highlighted (gate 42616081317), and 224.5 to 227.6 MB as plain text (gates 42659207710, 42665305004 and 42676631509). All four are within the 250 MB budget. A measurement on hardware is on the parked list too.
- **Selection handles:** parked with the manual selection matrix (PHASE_2_SELECTION_MATRIX.md, W6).

## Consequences
- Editor workstream 2 starts only after the gate; protocol layer is engine-agnostic so the swap cost is bounded.
- LSP features (completion/hover/diagnostics UI) are wired by us to CM6 — more integration work than Monaco's built-ins, but mobile-correct.
- The raw numbers are above and in the evidence files; PHASE_2_REPORT.md cites them when Phase 2 closes.
