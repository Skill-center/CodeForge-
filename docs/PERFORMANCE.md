# Performance

**Status:** Budgets accepted Phase 0 from audited measurements · Benchmark suite built incrementally (spec §9: measure, never assume)

---

## 1. Size truth (baseline from audit, not the spec's 50 MB assumption)

| Metric | Baseline (t1 measured) | CodeForge budget | Gate |
|---|---|---|---|
| Sealed base AAB per device (arm64) | 136.0 MB | ≤ 180 MB incl. Flutter engine + editor assets (Play cap 200) · **Phase 4 W3: 147.3 MB** (phase gate 43808489945) | `check-bundle-size.py` every release build; in the phase gate since Phase 4 W3 |
| GitHub "full" APK (core + build-tools) | ~250 MB est. (136 + ~110 pack compressed) | ≤ 300 MB; measured at Phase 4 · **W3, without build-tools:** 164.2 MB (arm64, the phone's profile build), 149.4 MB (release x86_64) | release gate |
| Installed core userland | 360–380 MB on-device | unchanged (reuse, no duplication) · **Phase 4 W3, emulator:** the prefix holds 274.8 MB in 13,894 files, each counted once; its folder takes 397.3 MB on disk (`du -sk`), beside 140.0 MB of libraries Android extracted | RuntimeService size report (Settings → Runtime) |
| Editor bundle (gz) | — | ≤ 1.5 MB | editor build gate |
| Flutter UI assets (fonts/icons) | — | ≤ 3 MB | build gate |

Rule carried from t1: **unique-inode bytes are storage truth** (hardlinks make naive sums lie ~4×); size reports use dpkg Installed-Size + unique walk.

## 2. Runtime budgets

| Metric | Budget | Measured how |
|---|---|---|
| Cold start → interactive shell UI (no runtime) | ≤ 1.5 s mid-range | `adb shell am start -W` + frame trace, 10-run median |
| Runtime first install (payload extract+verify) | ≤ 60 s mid-range (t1: 13,858 files verified) · **Phase 4 W3, emulator:** 3.5 s for 13,894 files, 6.6 s through the app (phase gate 43808489945); the phone figure in W5 | instrumented timing event |
| Runtime warm start (re-verify skip) | ≤ 100 ms (t1 measured 11 ms) · **Phase 4 W3, emulator:** 18 ms, the median of five (phase gate 43808489945) | instrumented timing (`RuntimeInstallTest` c) |
| Search a project (ripgrep), 10,000 files | **Proposed in Phase 4 W6:** the first result ≤ 0.5 s and all ≤ 2 s on a mid-range phone · **measured:** a Pixel 8a 61 ms / 118 ms, medians of three, debug build (Test Lab, CI 44275357542); the emulator 58 / 146 ms (phase gate 44275357542). The first search after a start: 159 / 267 ms on the phone | the gate's `search` group; Test Lab's phone search |
| Search a folder from shared storage (the scan), 1,000 files | **Proposed in Phase 4 W6:** all ≤ 6 s on a mid-range phone, each result shown as soon as its file is read · **measured, emulator only:** 4.6 s for the gate folder's 1,007 files, four read at a time (phase gate 44275357542); 5.1 s one at a time (phase gate 44264577788). Each file is an open the documents provider answers | the gate's `search` group (Test Lab can't answer the folder picker; a phone session can) |
| Stop a search | **Proposed in Phase 4 W6:** ≤ 250 ms from Stop to its summary, with nothing left running · **measured:** 85 ms and 67 ms on the emulator, no `rg` left | the gate's `search` group |
| Editor keystroke→glyph p95 | ≤ 32 ms | CM6 perf marks + systrace |
| Terminal input→echo p95 | ≤ 50 ms | timestamped probe loop |
| Terminal flood (10 MB) | UI stays responsive; ≤ 5% frames > 32 ms | frame metrics during flood test |
| App RSS: shell idle | ≤ 250 MB | `dumpsys meminfo` sampling |
| App RSS: editor + 1 terminal + LSP | ≤ 600 MB on 6 GB device | same |
| WebView count steady-state | ≤ 2 (editor + optional terminal) | instance counter assertion |
| Battery: 1 h idle with sessions open | ≤ 2%/h | Battery Historian run at Phase 10 |
| LSP completion round-trip p95 | ≤ 300 ms warm | LSP client timings |

## 3. Principles (enforced in review)

1. **Lazy everything:** runtime install on first workspace open; LSP per-language on first relevant file; terminal frontend on first open; WebViews destroyed under pressure after state persist.
2. **Incremental sync:** CM6 change sets, never full-doc per keystroke; EventChannel output coalesced ≤ 60 Hz.
3. **No duplicate runtimes** (spec §2): one sealed userland; packs extend it; npm/pip global installs discouraged in UX (project-local, pure-JS/wheel preferred — native addon limitation documented in SECURITY.md §2).
4. **Rebuild discipline:** Riverpod select/`autoDispose`; `const` widgets; list virtualization (`SliverList`) for explorer/search; no setState above leaf level.
5. **Cache with bounds:** file icons LRU, search index incremental with cancellation, language detection cached per extension+content sample.

## 4. Benchmark suite

`app/integration_test/bench/` + `scripts/perf/`: startup, editor latency (synthetic typing driver), large-file (1 MB/5 MB) open+scroll, terminal flood, workspace tree (10k files) render, search (100 MB corpus) timing, memory sampling. Runs nightly on emulator (relative regression detection, ±15% alert) and on the mid-range arm64 device at phase gates (absolute budgets). Results appended to `docs/phases/PHASE_N_REPORT.md`; release requires no red budget.

As built in Phase 2: the phase gate runs two benchmarks on the KVM emulator, on every `[phase-gate]` commit (no nightly run, by the owner's decision of 2026-11-11):
- **The editor engine benchmark** (W3): `app/integration_test/editor_bench_test.dart` plus the DevTools driver `editor/tool/bench_cdp.mjs`. It writes `app/ci-results/gate/editor_bench.json`; the method is in EDITOR_ARCHITECTURE.md §1.
- **The large-file group** (W7): `app/integration_test/large_files_test.dart` plus `editor/tool/large_cdp.mjs`. At 1, 5 and 10 MiB it records the open, the page's work, long tasks, scrolling, typing, memory and the save. It also records the session store's write costs and a release build's memory with a 1 MiB file restored. It writes `large_files.json`/`.txt`; the method is in EDITOR_ARCHITECTURE.md §10.

Every gate also measures cold start on a release x86_64 APK (`perf.json`). On a device, the engine suite runs from Settings → Developer → Editor benchmark, and Settings → Developer → Frame timing records frame build and raster times. The Phase 2 numbers are in [PHASE_2_REPORT.md](phases/PHASE_2_REPORT.md) §7.

As built in Phase 3, the gate adds two timed groups:
- **The `watch` group** (W5, `app/integration_test/watch_test.dart`) times each reload of a file changed behind the app's back, from the write, on the device's clock, in a project and in a folder from shared storage (G4: within 2 s).
- **The `measure` group** (W6, `app/integration_test/measure_test.dart`): a project of 10,000 files opened and Go to File's index built; 1 and 10 MiB written and read through `dart:io` in a project and through the storage broker in a folder; a folder of 1,000 entries listed; and frames counted while 10 MiB is digested on the UI isolate and on a background one. It writes `measure.json` and `measure.txt`, recorded and never judged on the emulator.

Since W6 the cold-start group times the shipped APK, which renders with Impeller, then the same build with Skia, then the shipped one again (`cold_start_skia` and `cold_start_again` in `perf.json`; only the first block is held to the budget). The Phase 3 numbers are in [PHASE_3_REPORT.md](phases/PHASE_3_REPORT.md) §7.

As built in Phase 4 W6, search adds two timed runs:
- **The gate's `search` group** (`app/integration_test/search_test.dart`, on the build with the x86_64 payload): ripgrep on a project of 10,000 files the test writes, three timed runs and six more searches with exact counts; a stop at the first result; a result opened from the panel; the gate folder (1,000 small files in `many/`) scanned three times through Android's picker and provider; and the folder copied into the app's storage for ADR-0013. It writes `search.json` and `search.txt`, recorded and never judged on the emulator. Times are taken twice: in the controller, as the user sees them, and in the host.
- **Test Lab's phone search** (`app/integration_test/phone_search_test.dart`, in the Test Lab job's entrypoint since W6): the same project on the phone, searched by ripgrep, with the times in the run's evidence as `CODEFORGE_SEARCH_JSON`. The folder scan needs the picker, so it is timed on the emulator alone.

## 5. Regression policy

A merged PR that worsens a tracked metric > 15% gets a follow-up issue tagged `perf-regression` and must be fixed or consciously re-budgeted (ADR) before the next phase gate. Numbers live in artifacts, summaries in docs — never vibes.
