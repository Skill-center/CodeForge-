# Testing Strategy

**Status:** Accepted Phase 0 · Grows with each phase · Rule: no feature is "done" without its tests running green in CI (spec rules 11/15/16)

---

## 1. Test pyramid

| Level | Tool | Scope | When |
|---|---|---|---|
| Dart unit | `flutter test` | domain, controllers (with fake services), protocol codecs, settings, migrations | every PR |
| Dart widget | `flutter test` + golden files | components, navigation, adaptive layouts (3 breakpoints × orientation), theme switching | every PR |
| Bridge contract | Dart test + vitest, shared JSON fixtures | every message type round-trips; unknown version/type rejected | every PR touching protocol |
| JS unit | vitest | CM6 change-set apply/rebase, protocol validation, search regex semantics | every PR touching editor/ |
| Kotlin/JVM unit | Gradle `test` | host services with fakes; vendored sealed-runtime tests unchanged | every PR touching android/native |
| Android instrumented | `connectedAndroidTest` on emulator | Pigeon channels end-to-end, SAF flows, WebView bridge, lifecycle/process-death | nightly + phase gates |
| Runtime gates | ported `ExecModelTest`/`SealedShellTest` | exec model + sealed userland on API 34/36 x86_64 **and arm64 device** | Phase 4 gate, then nightly |
| E2E workflow | `integration_test` | spec §10 scenario: open project → create file → edit → save → run → output → edit → commit | phase gates from Ph. 5/7 |
| Performance | benchmark suite (PERFORMANCE.md) | startup, editor latency, memory, terminal flood, large files | phase gates + release |

### 1.1 As built in Phase 1

| Suite | Where | What it proves |
|---|---|---|
| Unit | `test/core`, `test/services`, `test/application` | breakpoints, command registry, failures, logger redaction; settings/shell envelopes (round-trip, corrupt/future payloads → defaults, per-field fallback, clamping); controllers (write-through, debounce + flush, restore across containers) |
| Widget | `test/widget` | first-run flow, ≤2-tap reachability, palette, editor tabs, adaptive layouts with zero overflow, deep links / system back (`navigation_test.dart`), accessibility (`accessibility_test.dart`: Android tap-target + labeled-target guidelines, every enabled ink target ≥ 48 dp, 1.3× text scale at all gate sizes, settings sub-pages proven open before checking), soft keyboard (`keyboard_insets_test.dart`: a raised IME at every gate size × terminal stop × 1.0/1.3 text, the command palette at every size, and the compact editor's 191 dp floor) |
| Design system | `test/design_system` | contrast (`contrast_test.dart`: every text/background pair and syntax colour ≥ 4.5:1 in both themes); typography (`typography_test.dart`: the UI type scale, the code font with `calt`/`liga` off, tabular figures in status text) |
| Golden | `test/goldens` | design-system gallery (dark/light) + home/workspace/settings at 360×800, 800×360, 412×915, 915×412, 800×1280, 1280×800; baselines are generated on the Linux CI runner (`[bootstrap]`), never locally |
| Integration (emulator) | `integration_test/` via `tool/ci/emulator_gate.sh` | smoke flow; process-death restore pair (`restore_a` mutates state → force-stop → `restore_b` relaunches and asserts the restored route, theme and terminal stop) |

Manual: TalkBack spot-check checklist in the Phase 1 report (owner, on hardware).

### 1.2 Added in Phase 2 (so far: W1 editor page, W2 host and bridge, W3 engine benchmark, W4 files and tabs)

| Suite | Where | What it proves |
|---|---|---|
| Editor page | `editor/test` (vitest + happy-dom), CI job `editor` | protocol validation, change-set round trips against CodeMirror, the controller (open/activate/close, batching, snapshots), the bridge, the cursor-only active line (`active_line.test.ts`: never over selected text, line-break and line-start boundaries), the built page's integrity (`tool/verify_bundle.mjs`) |
| Contract | `app/test/core/editor_protocol_test.dart` | the same JSON fixtures as vitest (`editor/test/fixtures/`): every valid message per direction parses, every invalid one fails with the expected error code, every change-set case applies identically; the Dart constants equal those in `types.ts` |
| Unit | `test/core/editor_core_test.dart`, `test/application/editor_host_test.dart`, `test/services/editor_page_test.dart` | change sets, shadow documents, language detection, the rate limiter; the host over a scripted page (ready and sync, request timeouts, edits applied or refused with a snapshot resync, page restarts reopening every document, rate limiting); page verification (hash match, one-byte tamper, malformed manifests) and the bundled page's hash and notices |
| Widget | `test/widget/editor_tabs_test.dart`, `test/widget/editor_surface_test.dart` | typing marks the tab dirty and save writes the editor's text; closing a tab closes the document in the editor; the configuration is valid in both themes and follows the text scale; a failed start shows the reason and retries; the page survives the tab strip and toolbar leaving in one layout |
| Files (W4, G2) | `test/core/text_codec_test.dart`, `test/core/workspace_path_test.dart`, `test/services/local_file_service_test.dart` | the codec: BOM and CRLF kept byte for byte, mixed line endings flagged, binary, malformed UTF-8 and UTF-16/32 refused; every path rule; `LocalFileService` on a real temporary folder (plain `test()`, since `dart:io` cannot finish inside a widget test's fake-async zone): first-run seeding, `..` and symlink escapes refused while an inside link works, a save interrupted just before its rename leaving the old file and no temp file, changed-on-disk refusal, exclusive creation |
| Documents (W4, G3) | `test/application/document_controller_test.dart`, `test/widget/documents_test.dart` | open, dedupe, refuse (binary, missing, invalid), language by name and shebang; dirty against the saved text (undoing back is clean); a racing edit stays dirty; Save As keeps the editor document and re-highlights it; New File; close falling back to the last-used tab; 12 tabs keeping their own text; the close prompt's Cancel / Don't Save / Save; Save As and New File dialogs with their refusals; CRLF and BOM chips; Ctrl+S, Ctrl+Tab and the page's forwarded shortcuts; close others; tabs reopening after a restart |
| Integration (emulator) | `integration_test/editor_bridge_test.dart`, run by `tool/ci/emulator_gate.sh` | the real, verified page in the Android System WebView, over real files: it starts, an edit round-trips as an incremental change, a page reload restores every document from the shadows, and save writes exactly the editor's text to the device. W4 adds a CRLF + BOM file edited and saved byte for byte, Save As, and 12 tabs that each keep their text, cursor, scroll position and undo history across switches |
| Restore pair (emulator) | `integration_test/restore_a_test.dart` → `am force-stop` → `restore_b_test.dart` | Phase 1's theme, route and terminal restore after a real process death; W4 adds the open tabs, in order, with the same tab active |
| Benchmark (JS) | `editor/test/bench.test.ts`, `editor/test/page_kit.test.mjs` | nearest-rank percentiles, frame summaries and the first differing UTF-16 unit; a sample per benchmark language, the 60-character typing text and the deterministic 1 MiB file; the same stub completions for both engines; well-formed composition cases covering CJK, Hangul and multi-code-point emoji; the page kit's licence filter, `<!--` escaping, CSP hash pin and literal placeholder filling |
| Benchmark (Dart) | `test/services/bench_pages_test.dart`, `test/services/frame_stats_test.dart`, `test/application/editor_bench_runner_test.dart`, `test/widget/developer_tools_test.dart` | benchmark manifest parsing (a page outside its directory is refused), hash verification, a build without pages; frame statistics against the 16.7 and 32 ms lines; the runner over scripted pages (ABBA order, fresh page per run, medians, a page that never starts or fails verification, typing checks, the driver hand-over and its timeout); Settings → Developer, a full run, the on-screen typing check and frame timing's copy and reset |
| Benchmark (emulator) | `integration_test/editor_bench_test.dart` + `editor/tool/bench_cdp.mjs`, run by `tool/ci/emulator_gate.sh` | both engines' verified pages in the real WebView: 3 runs each with every scope check (highlighting, replace-all, completion), then the DevTools driver's input latency, composition cases and memory; merged into `app/ci-results/gate/editor_bench.json` by `editor/tool/bench_report.mjs` |

Widget tests run the real `EditorHost` against a scripted Dart page (`test/support/fake_editor_surface.dart`) because platform views cannot run under `flutter test`; the scripted page validates every host message with the production protocol code. Files in widget tests come from `MemoryFileService` (`test/support/memory_file_service.dart`), which uses the production path rules and codec, so a refused path or a binary file behaves as on a device; `TestHarness` shares one across restarts of the app within a test. The benchmark screens work the same way, over scripted benchmark pages (`test/support/fake_bench_surface.dart`), and `TestHarness` gives every app-level test a build without benchmark pages.

The benchmark group in the phase gate fails only if a run cannot complete (a page that does not start, a failed scope check, a missing run). Budget misses are recorded in `editor_bench.json` as evidence for ADR-0004 and do not fail the gate. The DevTools driver runs in the background for the whole group and needs the debug APK (WebView debugging is off in profile and release builds).

Every test run is bounded so a hang fails fast and says where. `test/flutter_test_config.dart` gives each widget test 2 minutes instead of the binding's default 10 (`flutter test --timeout` does not reach `testWidgets`). In CI, coreutils `timeout` caps the golden run at 10 minutes and the full suite at 15, which also catches a test that spins, where no per-test timeout can fire.

A widget test runs in a fake-async zone, so whatever its body awaits has to complete inside that zone. Code a test awaits must not await `StreamSubscription.cancel()`: it completes through a root-zone future. That resumes the test outside the zone's control, and the next thing it awaits never completes, so the test stalls until its timeout. For this reason `EditorHost.dispose()` stops its streams without awaiting them.

## 2. Fakes-first discipline

Every service interface ships with an in-memory fake in Phase 1. Widget/controller tests run against fakes — fast, deterministic, no device. Native implementations are validated by contract tests that run the **same test suite** against fake and native impls (interface contract tests), so divergence is caught mechanically.

## 3. Device matrix (spec §10)

| Class | Example target | Purpose |
|---|---|---|
| Low-memory | 3–4 GB RAM arm64, API 26–29 | OOM behavior, WebView lifecycle, degraded modes |
| Mid-range | 6–8 GB arm64, API 33–35 | primary perf budgets |
| High-end | flagship arm64, API 36 | 120 Hz, tablet layouts, multi-window |
| Tablet | ≥ 600 dp width | expanded layouts, hardware keyboard |
| Emulators (CI) | `aosp_atd` x86_64 API 34 & 36 | gates without hardware (t1-proven pattern) |

External keyboard tests: hardware keymap suite on tablet + phone (OTG/BT). IME matrix: Gboard (swipe/voice/CJK/emoji), Samsung Keyboard, hardware.

## 4. Lifecycle & data-safety tests (non-negotiable)

- Kill process mid-edit → relaunch → buffer restored from journal, zero loss (Phase 2 gate).
- Rotate/split-screen/fold mid-edit and mid-terminal → state intact.
- Payload byte-flip → install fails typed, never marked ready (Phase 4 gate).
- DB migration N→N+1 with real fixture data (every schema change).
- Session close → zero orphan child processes (instrumented assertion).

## 5. CI integration

- PR pipeline: analyze + unit + widget + contract + JS + JVM tests + debug build. Target < 15 min.
- Nightly: instrumented emulator suite + runtime gates + perf smoke.
- Phase gates: full matrix incl. arm64 device runs (self-hosted or owner device via `adb` over network for gates; documented in BUILD_AND_RELEASE.md).
- Evidence: test reports + perf numbers uploaded as workflow artifacts; phase exit reports cite run ids (t1 discipline). **A claim of "green" without a run id is a process violation.**

## 6. Manual test charters (per phase)

Exploratory charters for feel-level quality (touch targets, animation jank, empty states, error copy) recorded in `docs/phases/PHASE_N_REPORT.md` with device + build hash. Automation covers correctness; humans cover premium.
