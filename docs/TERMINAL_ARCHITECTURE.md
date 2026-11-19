# Terminal Architecture

**Status:** **Frontend decided 2026-11-12: xterm.js** (ADR-0006 by its rule; the owner chose Apache-2.0, ADR-0011) · **Backend built in Phase 5 W2** (§1, [ADR-0014](adr/0014-pty-and-sessions.md)): the PTY in CodeForge's launcher, CodeForge's own sessions, on t1's environment rules · The view: Phase 5 W3

---

## 1. Backend: the existing runtime, as built (Phase 5 W2)

The terminal backend **is** the existing runtime, per spec §6.4: the same sealed prefix, the same launcher and the same environment rules as one-shot commands (SECURITY §2.1), with a pseudo-terminal in between. All of it is CodeForge's own, written from POSIX's and Linux's manuals (AGENTS §4). Termux's `terminal-emulator` (`termux.c`, `TerminalSession`) and t1's `HarnessSession` are not vendored (ADR-0011), and nothing of them is copied.

```
Dart (W3's view) ──TerminalApi──▶ TerminalHost ──▶ RuntimeHub ──▶ Terminals ──▶ TerminalSession
        ◀──TerminalEvents──                                                        │ stdin: frames
                                                                                   ▼ stdout: bytes
                                        libcodeforge-spawn.so --terminal ROWSxCOLS  (the relay)
                                                                                   │ PTY master
                                                                                   ▼
                                                   bash -i (or node, python…) on the PTY slave
```

**Code:** `native/runtime-core/src/main/jni/codeforge-spawn.c` (the launcher), `app/android/app/src/main/kotlin/dev/codeforge/app/runtime/` (`TerminalSession.kt`, `Terminals.kt`, `SessionRegistry.kt`, `RuntimeEnvironment.kt`, `RuntimeHub.kt`), `…/terminal/TerminalHost.kt` and `app/pigeons/terminal_api.dart` (the API), `app/lib/services/terminal/native/pigeon_terminal_service.dart` (Dart's client).

### 1.1 The PTY: the launcher's terminal mode (ADR-0014, design (a))
- `libcodeforge-spawn.so [--status F] [--grace MS] --terminal ROWSxCOLS -- PROGRAM [ARG...]`. The launcher opens the pair (`posix_openpt(O_RDWR|O_NOCTTY|O_CLOEXEC)`, `grantpt`, `unlockpt`, `ptsname_r`), opens the slave without becoming its controlling process, sets `IUTF8` and the window's size, and forks. The child calls `setsid`, takes the slave as its controlling terminal (`TIOCSCTTY`), makes it fds 0 to 2 and executes the program. The launcher stays outside that session: it is still the tree's subreaper and leads its own group, as for a command (SECURITY §2.1, E4).
- **The relay:** `poll` over the master, the launcher's stdin and stdout, and a `signalfd`, all non-blocking. Output is buffered up to 64 KiB, input up to 128 KiB. While the app does not take output, the launcher stops reading the master, so a flooding program blocks in the kernel's terminal buffer.
- **Nothing forks inside the app's process:** the host starts the launcher with `ProcessBuilder`, as it starts commands.

### 1.2 The protocol
- **stdin, frames:** a type byte, a big-endian 16-bit length, the payload. Type 1 is input, written to the terminal as typed. Type 2 is a window size, rows then columns, each a big-endian 16-bit number brought into 1 to 9999; the launcher sets it (`TIOCSWINSZ`) and the kernel sends `SIGWINCH`. Any other frame ends the session (`stop_cause=protocol`). Sizes travel as frames, not on a FIFO as the plan had it, so a resize keeps its place among the keystrokes (ADR-0014).
- **stdout:** the terminal's bytes, unchanged.
- **The status file** (`<runtime root>/codeforge/terminal/terminal-*.status`): `pid`, `group`, `subreaper`, `mode=terminal`, `tty`, `child`, then `reason` (`exited`, `signaled`, `stopped`, `exec_failed`, `spawn_failed` or `terminal_failed`), `exit` or `signal`, `stop_signal`, `stop_cause` (`signal`, `input_closed`, `output_closed`, `protocol` or `relay_failed`), `ended` and `remaining`.
- **Ending:** the end of stdin, a broken stdout, `SIGTERM`, `SIGINT` or `SIGHUP` stop the session. The launcher sends `SIGHUP`, `SIGTERM` and `SIGCONT` to the whole tree (an interactive bash ignores `SIGTERM`, not `SIGHUP`), then `SIGKILL` after the grace period. It relays what is left for at most 500 ms after a stop, and up to 10 s after the program's own exit (2 s once nothing is taken).

### 1.3 A session: `TerminalSession`
- **States:** starting, running, exited. An exit carries the shell's exit code, or how it ended otherwise: `ended` (the app ended it), `signaled`, `lost` (the relay stopped), `cannot_start`, `terminal_failed` or `launch_failed`, with the processes ended and left.
- **Output:** a reader thread takes the launcher's stdout into a ring buffer, which keeps the last 1 MiB (64 KiB to 8 MiB, per session). A view that attaches later gets the buffer first, from a line's start.
- **Batches:** a view gets at most one batch every 16 ms (60 a second), and the first bytes after a quiet moment at once, so an echo never waits for a batch.
- **Credit:** the view acknowledges what it has drawn; the reader reads at most 256 KiB past that (the window). A flood then blocks in the kernel, behind the launcher and the pipe: nothing is lost, and the app holds at most the window for the view. Without a view, or once the session is ending, the reader reads freely into the ring. After the launcher exits, it still waits for credit, but never more than 2 s at a time.
- **Input:** `write` and `resize` queue frames for a writer thread, in order, at most 1 MiB, so no caller blocks on a full pipe. Neither is taken once the session is ending or gone.

### 1.4 Starting one: `Terminals`
- **The spec:** a project, a program, its arguments, environment overrides, rows, columns, the buffer's size and a label (`TerminalSpec`). Kotlin checks all of it again (SECURITY §2.2):
  - the program is a name in the runtime's `bin` (E1);
  - the folder is the runtime's home, or a project's folder that the host resolves itself from its folder name in `<filesDir>/workspaces`, links resolved (E3, widened): never a path from Dart;
  - an override cannot replace the runtime's own variables, Android's locations, or any `LD_*` or `TERMUX_*` (E2);
  - sizes are brought into range.
- **The shell:** the runtime's bash, `bash --noprofile --rcfile <root>/codeforge/terminal/bashrc -i`. The rc file is CodeForge's, rewritten before each session: a prompt, then the user's `~/.bashrc` when there is one. Without bash in the runtime, nothing starts (`not_found`): the shell never falls back to another one silently.
- **Exited sessions** stay listed, with their buffers, until removed (the oldest beyond 8 are forgotten).

### 1.5 The registry: `SessionRegistry`
- One registry for commands and terminals. **At most 8 terminals:** a place is reserved before the launcher starts, so the ninth is refused (`too_many`) without starting anything.
- **End all** (the user's) ends every terminal and waits for them, and takes new ones at once. An install's ends every session of both kinds, refuses new ones, and ends them again once it holds the prefix's write lock: a terminal holds the read lock only while it starts.
- **The last resort,** when a launcher outlives its own kill phase: `SIGKILL` to its group, and to every group of the shell's session, which `/proc` lists.
- Commands, probes and terminal starts run on a bounded pool of 16 threads; each session has its reader and writer threads, and one thread delivers every session's batches.

### 1.6 The environment
A command's (SECURITY §2.1, E2), with four differences: `TERM=xterm-256color` and `COLORTERM=truecolor` instead of `dumb`; `SHELL` is the runtime's bash; and `TERMINFO` names the payload's terminal descriptions (`<prefix>/share/terminfo`, which Termux's ncurses package carries), because ncurses looks for them under Termux's official prefix, which the preload translates for `exec` only.

### 1.7 The API (`pigeons/terminal_api.dart`)
- `TerminalApi`: `start`, `sessions`, `write`, `resize`, `acknowledge`, `attach`, `detach`, `end`, `endAll`, `remove`. Every refusal is a typed code.
- `TerminalEvents`, a Flutter API: `output(sessionId, offset, bytes)` and `changed(info)`, on the main thread, in order. A Flutter API rather than an event channel, as the runtime and search send their events: one mechanism, typed, and the credit window already bounds what is in flight (ADR-0014).
- The engine is the view of the sessions it starts or attaches. When it goes, every session is detached and keeps reading into its buffer. The workbench uses the honest fake until W3's view.

**Changed from the design before W2:** `termux.c` and `HarnessSession` gave way to the launcher's terminal mode and CodeForge's classes (ADR-0011, ADR-0014); output reaches Dart through a Flutter API, not an EventChannel; the shell runs with CodeForge's rc file instead of `--norc`; and a missing bash is an error, never a fallback to `/system/bin/sh`. Multiple concurrent sessions, each independent of the editor (spec §6.4), as planned.

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
