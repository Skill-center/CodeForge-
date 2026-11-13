# Terminal Architecture

**Status:** **Frontend decided 2026-11-12: xterm.js** (ADR-0006 by its rule; the owner chose Apache-2.0, ADR-0011) · Backend: CodeForge's own PTY and session, on t1's environment rules (§1) · Implementation Phase 5

---

## 1. Backend: the existing runtime

The terminal backend **is** the existing runtime, per spec §6.4 — not a replacement:

**Changed 2026-11-12 (ADR-0011, Apache-2.0):** Termux's `terminal-emulator` (`termux.c`, `TerminalSession`) and t1's `HarnessSession`, which is built on it, are not vendored. Phase 5 writes the PTY clean-room (about 200 lines), or reuses `termux.c` only if a legal review verifies its Apache-2.0 jackpal lineage, and a CodeForge session class takes the place of `TerminalSession` and `HarnessSession`. The environment rules below carry over unchanged. xterm.js keeps the scrollback on screen, and the host keeps a buffer while the view is detached.


- `terminal-emulator` JNI (`termux.c`) creates a real PTY; `TerminalSession` (Java) owns the process, scrollback buffer, and resize ioctls.
- `HarnessSession` builds the environment: relocated prefix, `LD_PRELOAD` (`harness-exec.so` first), `HOME/TMPDIR/PATH/PYTHONHOME/…`, workspace cwd, `bash --noprofile --norc -i` (falls back to `/system/bin/sh` if the sealed bash is unavailable — degraded mode is visible, never silent).
- `SessionRegistry` (new Kotlin host code) supervises sessions: ids, lifecycle, foreground service, process-group kill, exit-code events, output streaming to Dart via EventChannel (coalesced ≤ 60 Hz, backpressure-aware).
- Multiple concurrent sessions; each independent of the editor (spec §6.4). Session spec: `{cwd, env overrides, shell, rows, cols, transcriptRows}`.

## 2. Frontend decision (ADR-0006): two candidates, one gate

| | **A. Native `terminal-view` via PlatformView** (primary candidate) | **B. xterm.js 6.0 in WebView** (spec's default table) |
|---|---|---|
| Mobile touch/IME/selection | Proven in Termux for years; native handles | WebView IME quirks; extra work for selection handles |
| Rendering perf | Native canvas, no WebView overhead | Good, but +1 WebView process memory |
| Flutter integration | `AndroidView`/hybrid composition; texture-layer overhead to measure | JS bridge like editor; consistent with editor stack |
| Reuse mandate (spec §2) | Direct reuse of existing asset | Rebuilds frontend that already exists |
| **License** | Termux-modified modules: conservative reading **GPLv3** (audit §7) → app license implications | xterm MIT; PTY-only reuse keeps app permissive-licensable |
| Theming/features | Terminal themes, scrollback, copy/paste already there | Same via addons; search addon available |

**Gate (Phase 4, on arm64 device):** input→echo latency p95 ≤ 50 ms both; IME suite (Gboard + hardware kb) zero lost input; 10 MB output flood no UI freeze; memory delta ≤ 80 MB; PlatformView composition jank < 5% frames > 32 ms.

**Decision rule:** if A passes and owner accepts GPLv3 (ADR-0011) → A. If owner wants permissive licensing → B (PTY JNI reused under its Apache-2.0 jackpal lineage, verified by legal review). If A fails perf → B. Recorded with numbers in PHASE_4_REPORT.md. **Applied 2026-11-12:** the owner chose a permissive licence (Apache-2.0), so B, xterm.js. The gate's budgets apply to xterm.js when Phase 5 builds it.

## 3. Flutter-side terminal UX (either frontend)

- Terminal lives in the workbench panel system: phone = bottom sheet (peek 64 dp / half / full); tablet = docked resizable panel. Sheet gestures never steal terminal scroll (gesture arena: terminal owns vertical drag inside its bounds).
- **Terminal tabs** (Flutter UI): new session, rename, close (confirm if running), swipe between; session survives tab switches; optional persistence across app restarts = reattach if process alive, else "session ended (exit N)" tombstone.
- **Extra-keys row** reuses the editor symbol toolbar component (Esc, Ctrl, Alt, Tab, arrows, |, ~, /) — terminal preset.
- Copy/paste: long-press selection (frontend-native) + Flutter toolbar actions via bridge; paste sanitized (bracketed paste mode on).
- **Run integrations (Phase 5):** "Run Current File" / "Run Project" resolve via RuntimeService capability model → spawn session with execution profile (`node file.js`, `python file.py`, `sh script.sh`, npm scripts discovered from package.json); status chip (running/exit N) + output deep-link. Run never blocks UI; cancellation = SIGTERM→SIGKILL escalation.

## 4. Lifecycle & resource rules

- Sessions owned by foreground service with notification ("2 terminal sessions running") — user can kill all from notification.
- Backgrounded app: sessions keep running (service); the WebView frontend (B, chosen) may be detached — output is buffered in the host session's buffer and reattached on resume.
- Memory pressure: inactive session scrollback trimmed to configured rows; frontends destroyed/recreated lazily; **processes are never killed silently** for memory — only scrollback/renderers are reclaimed.
- Resize: panel/sheet size changes → rows/cols ioctl (A) or `fit` addon (B), debounced 100 ms; rotation tested with `vim`, `htop`, `node` REPL.
