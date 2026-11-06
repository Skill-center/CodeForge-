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
- **Status after the emulator gate:** CM6 passes the composition suite, so there is no stop-and-reassess. Cold load, composition and size are within budget. The typing, input, scrolling and memory budgets are not met on the emulator, and only hardware can settle them. This ADR stays Proposed until the phone run.
- **Phone:** pending the owner's run of `docs/phases/PHASE_2_PHONE_CHECKLIST.md`. It is non-blocking (PHASE_2_PLAN.md §5).

## Consequences
- Editor workstream 2 starts only after the gate; protocol layer is engine-agnostic so the swap cost is bounded.
- LSP features (completion/hover/diagnostics UI) are wired by us to CM6 — more integration work than Monaco's built-ins, but mobile-correct.
- Decision recorded with raw numbers in PHASE_2_REPORT.md; this ADR flips to Accepted then.
