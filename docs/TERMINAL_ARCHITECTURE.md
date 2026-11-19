# Terminal Architecture

**Status:** **Frontend decided 2026-11-12: xterm.js** (ADR-0006 by its rule; the owner chose Apache-2.0, ADR-0011) · **Backend built in Phase 5 W2** (§1, [ADR-0014](adr/0014-pty-and-sessions.md)): the PTY in CodeForge's launcher, CodeForge's own sessions, on t1's environment rules · **View built in Phase 5 W3** (§2.1, §3): xterm.js in a WebView of its own, behind the terminal protocol v1

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

### 2.1 The terminal page, as built (Phase 5 W3)

```
TerminalPane ── TerminalController ──TerminalService (Pigeon, §1.7)──▶ the sessions
                     │      ▲
          requests,  │      │ input, sizes, acks, title, bell,
          writes     ▼      │ selection, focus, modifiers
                  TerminalView ──surface── WebView: terminal.html (xterm.js, one terminal per session)
```

**The page** is built in `editor/` beside the editor's, with the same kit (`tool/page_kit.mjs`): one self-contained document (`tool/build_terminal.mjs` → `app/assets/terminal/terminal.html`, `manifest.json`, `NOTICES.txt`), inline script and style, the bundled JetBrains Mono, a CSP that pins the script's SHA-256 and denies everything else, no request at all. The app verifies it against its manifest before loading it (`services/terminal/terminal_page.dart`), under its own origin (`https://appassets.androidplatform.net/terminal/`). xterm.js 6.0.0 with addon-fit 0.11.0 (the panel's size) and addon-unicode11 0.9.0 (wide characters and emoji); the DOM renderer, no blinking cursor (nothing animates forever). At W3: 545.4 KiB, 174.2 KiB gzipped, against a budget of 256 KiB.

**The terminal protocol v1** (`editor/src/terminal/protocol.ts` and `validate.ts`, mirrored by `app/lib/core/terminal/terminal_protocol.dart`; 36 valid and 31 invalid fixtures in `editor/test/fixtures/terminal/`, run by vitest and by Dart). The editor protocol's envelope and rules: `{v: 1, id, type, payload}`, unknown versions, types and fields rejected, every request answered once, except an accepted `session.write`, which `session.ack` answers.

| From the host | | From the page | |
|---|---|---|---|
| `terminal.configure` | theme (21 colours from the tokens), font size, scrollback | `terminal.ready` | protocol, engine, version |
| `terminal.focus` | give the shown terminal the keyboard, or take it | `terminal.focus` | the terminal took or lost the keyboard |
| `terminal.modifiers` | Ctrl and Alt latched for the next key | `terminal.modifiers` | the latched keys were used |
| `session.open` / `activate` / `close` | a session's view; open answers its fitted size | `session.input` | keys, the input method's text, mouse reports (`binary`) |
| `session.write` | output, with a sequence number | `session.ack` | that write is parsed |
| `session.key` | an extra key, by name or as one character, with modifiers | `session.resized` | the view's new size |
| `session.paste` | text to paste | `session.title`, `session.bell` | the program's title, a bell |
| `session.select`, `session.copy` | select all or nothing; the selection's text | `session.selection` | a selection began or ended |
| `session.clear`, `session.snapshot` | clear the scrollback; the screen as text | `session.link` | a tapped link (W4's `file:line`) |
| | | `terminal.log`, `response` | |

**Output and flow control.** `TerminalController` decodes each session's bytes as UTF-8, holding back a sequence split between two batches, and writes each batch to its view with a sequence number. When xterm.js has parsed a write, the page sends `session.ack`, and only then does the controller acknowledge the batch's end to the host (§1.3). So the host's window, 256 KiB, is what the page has not yet parsed: a flood waits in the kernel, never in the app or the WebView. Output that arrives before a view is open (it can beat the start's answer) waits in the controller.

**Input.** What xterm.js sends goes to the session as UTF-8; a mouse report marked `binary` as one byte per character. The extra keys travel as `session.key`, so the page sends the sequence the terminal's modes expect: `ESC O A` for Up once a program has asked for application cursor keys, `ESC [ 1 ; 5 A` for Ctrl+Up. Ctrl and Alt latch on the extra-keys row: the page applies them to the next typed character (Ctrl to C0, Alt as an ESC prefix) and reports them released. The input method goes through xterm.js's own composition handling; the composition suite proves it on the emulator (G3, `bench/terminal_composition_cases.json`).

**Paste.** Pasted text, from the app's Paste or the WebView's own, loses every control character but tab and line breaks (an ESC could end bracketed paste early and run what follows), and its line breaks become CR. xterm.js then brackets it when the program asked. At most 256 Ki characters.

**Touch.** xterm.js 6 reads no touch, so the page does (`touch.ts`): a drag scrolls the scrollback, or sends arrow keys in the alternate screen (less, man, nano), as Termux does; a long press selects the word under the finger (paths included) and moving on extends the selection; a tap focuses the terminal, which brings up the keyboard. The page cancels a drag's and a long press's touches (and the long press's menu), never a tap's: the WebView takes the app's focus only from a tap it sees, and Chromium dispatches no focus event to a page whose view lacks the focus. The first build canceled every touch, and in the phase gate (44520440304, then 44557551890) a tap never brought the keyboard. A tap also reaches a program that asked for the mouse, as a click.

**Sizes.** addon-fit sizes the shown terminal to the panel when the panel changes (at most every 50 ms). The page reports `session.resized`, and the controller resizes the session (`TIOCSWINSZ`, §1.1). New sessions start at the last size seen, so the shell rarely starts at 80×24.

**A page restart.** The page lives as long as the app (`terminalViewProvider`) and loads with the first terminal. If it restarts, every session's view is opened again and refilled from the session's buffer (`TerminalService.attach`), skipping what the buffer already held.

**The surface.** The terminal page runs in a WebView of its own, hardened as the editor's (`WebViewEditorSurface` with the terminal's origin; SECURITY §3). Android's WebViews share one renderer process, so the terminal adds its page's memory rather than a process; ADR-0006's budget, a delta of 80 MB or less, is measured in W6.

## 3. Flutter-side terminal UX, as built (Phase 5 W3)

- **The panel** is the workbench's terminal pane, on the three stops it has had since Phase 1 (phone: peek, half, full; tablet and landscape: docked and resizable). It keeps its page across a rotation, as the editor pane does (a GlobalKey). Without a terminal host (tests, the honest fake) it says the terminal needs Android.
- **Maximize and Restore size** are in the panel's menu: the full stop. On a phone held upright that is 70 % of the screen, the editor keeping its floor. Docked, it is all but the chrome and a 48 dp peek of the editor: the dock's own cap keeps 320 dp for the chrome and the editor, which on a phone on its side (about 360 to 410 dp of body) left an open terminal its header and a row or two, or hid it.
- **Tabs** (`features/workbench/panels/terminal_pane.dart`): New terminal (in the open project's folder; a folder from shared storage starts in the runtime's home until W4's copy), rename by a long press, close (a running session asks first: closing ends what it started), and a swipe across the tabs for the next or the previous. They share the header's width; the shown tab keeps a close button when there is room, and the menu always offers Close, Rename, Clear scrollback and End all (which asks first). A dot shows each session's state, and a bell rung in a hidden tab.
- **The extra-keys row** is the editor's symbol toolbar component (`CfSymbolToolbar`) with the terminal's keys (`core/terminal/extra_keys.dart`): Esc, Ctrl, Alt, Tab, the arrows, `|`, `~`, `/`, then `-`, Home, End, PgUp and PgDn. Ctrl and Alt are latching keys (`CfToolbarKey.toggled`). At its end: Copy and Select all while there is a selection, then Paste and the keyboard. The row shows while the shown session runs and the panel has room for it (not at the peek stop).
- **Copy and paste:** a long press selects in the page; Copy puts the selection on the clipboard and drops it; Paste sends the clipboard's text, which the page sanitizes.
- **Endings:** a session that ended keeps its tab and its output, with a line saying how it ended (`exited with code N`, `ended`, `ended by signal N`) and Close. Persistence across app restarts (tombstones) comes with W5's foreground service.
- **The appearance** follows the theme, the editor's font size and the user's text scale (`terminal_appearance.dart`): the tokens give the background, foreground, cursor, selection and an ANSI palette (red, green, yellow and blue are the status colours; magenta and cyan the keyword and operator colours).
- **Run integrations (W4):** "Run Current File" / "Run Project" resolve via RuntimeService capability model → spawn session with execution profile (`node file.js`, `python file.py`, `sh script.sh`, npm scripts discovered from package.json); status chip (running/exit N) + output deep-link. Run never blocks UI; cancellation = SIGTERM→SIGKILL escalation.

## 4. Lifecycle & resource rules

- Sessions owned by foreground service with notification ("2 terminal sessions running") — user can kill all from notification.
- Backgrounded app: sessions keep running (service); the WebView frontend (B, chosen) may be detached — output is buffered in the host session's buffer and reattached on resume.
- Memory pressure: inactive session scrollback trimmed to configured rows; frontends destroyed/recreated lazily; **processes are never killed silently** for memory — only scrollback/renderers are reclaimed.
- Resize: panel/sheet size changes → the `fit` addon (at most every 50 ms) → `session.resized` → the session's `TIOCSWINSZ` (§2.1). The emulator gate turns the phone with `nano` and `top` (G3); `vim` and `htop` are not in the runtime.
