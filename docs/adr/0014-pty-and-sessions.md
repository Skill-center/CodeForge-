# ADR-0014: The PTY in CodeForge's launcher, and CodeForge's own terminal sessions

**Status:** Accepted · 2026-11-19 · Phase 5 W2 ([PHASE_5_PLAN.md](../phases/PHASE_5_PLAN.md) W2, which assigns this decision to W2's start, with a measurement) · decided by the agent, as the plan asks · built and described in [TERMINAL_ARCHITECTURE.md](../TERMINAL_ARCHITECTURE.md) §1

## Context
- **Termux's terminal code is not available to CodeForge.** Its `terminal-emulator` (`termux.c` and `TerminalSession`) and t1's `HarnessSession`, built on it, are not vendored since the owner chose Apache-2.0 (ADR-0011), and AGENTS §4 rules out copying Termux's code. Phase 5 writes the PTY and the session itself, from POSIX's and Linux's manuals.
- **What a terminal needs:** a pseudo-terminal whose slave is the shell's controlling terminal, so that Ctrl-C reaches the foreground job and job control works; window sizes; the shell's exit code; the whole tree ended when the session is; and a flood that neither loses output nor exhausts the app.
- **What exists:** since Phase 4 W4 every runtime command starts through CodeForge's launcher, `libcodeforge-spawn.so`, which leads the command's tree as a child subreaper and ends it whole (SECURITY §2.1, E4). It is plain C, tested on CI's Linux machine with real processes (`runtime/tests/test-spawn.py`).
- **The budget:** ADR-0006's input-to-echo p95 of 50 ms on an arm64 phone, for the whole path including xterm.js (G6).

## Options
- **(a) The launcher makes the PTY and relays.** A terminal mode of the launcher opens the pair, starts the program on the slave as a session leader with the slave as its controlling terminal, and relays between the master and its own stdin and stdout. The host starts it as it starts commands.
- **(b) JNI forks the shell** from the app's process and hands the master to Kotlin, as Termux does. It saves the relay's copy, but forks inside ART's multithreaded process, puts native code in the app's process, and needs ending a tree built a second time, apart from the launcher's.

And three smaller choices: window sizes on a FIFO in the session's folder (the plan's sketch) or in-band; output to Dart on an event channel or a Flutter API; and how a flood is bounded.

## Measured
- **The relay's own cost, on Linux** (the authoring machine, 2 CPUs; 300 samples a run): a byte's echo read straight from the master took p50 4 µs and p95 7 µs; through the relay p50 121 µs and p95 145 µs. Over 13 runs the relay's p95 ranged from 111 to 213 µs: about 0.3 % of the budget.
- **The whole host path, on Linux** (JVM `TerminalSessionTest`, six runs): the writer thread, the launcher, the terminal's echo, the reader thread, the batching and the view took p50 0.53 to 0.61 ms and p95 0.64 to 0.79 ms.
- **The whole host path, on the emulators** (phase gate 44461809588, `TerminalSessionTest` (d), 50 samples each after quiet moments):

  | API | p50 | p95 | max |
  |---|---|---|---|
  | 26 | 0.71 ms | 1.22 ms | 1.25 ms |
  | 27 | 0.54 ms | 0.73 ms | 1.13 ms |
  | 28 | 1.21 ms | 1.47 ms | 8.94 ms |
  | 34 | 0.72 ms | 0.88 ms | 1.08 ms |
  | 36 | 0.61 ms | 0.77 ms | 0.98 ms |

  The first phase gate, 44454605348, measured p95 between 0.71 and 5.12 ms on the same images (API 36's 5.1 ms the highest), and the third, 44475934378, between 0.68 and 3.19 ms (API 26's the highest, with one sample of 14.9 ms). On the emulators the whole host path costs a few percent of the budget at most, and their scheduling dominates it.
- **The whole host path, on an arm64 phone** (Test Lab in CI 44482754814, a Google Pixel 8a with Android 14, the same test): p50 3.85 ms, p95 8.38 ms, max 10.26 ms. That is about ten times the emulators' median p95 (0.88 ms over the fifteen legs of the three gates), and 17 % of the budget. Each sample follows 40 ms of quiet, and an echo wakes several threads in turn, so idle cores are the likely cause.
- **Floods:** through the relay alone, 10,588,896 bytes arrived whole; with the reader paused, the producer blocked after 983,816 bytes, and the launcher's peak RSS was 880 to 924 KiB. Through the host on Linux, 10 MiB arrived whole in 81 batches in 1.78 s with a 128 KiB window, never more than the window unacknowledged. On the emulators (phase gates 44461809588 and 44475934378, `TerminalSessionTest` (e)), 10 MiB arrived whole on every leg in 0.67 to 0.88 s (41 to 43 batches), with exactly the window, 256 KiB, unacknowledged at most, and the app's Java heap at most 2,155 KiB larger after it than before (garbage not yet collected included). On the phone it arrived whole in 1.04 s (43 batches), again with at most the window unacknowledged.

## Decision
- **(a), the launcher's terminal mode.** Its cost is a tenth of a millisecond against a 50 ms budget, and it brings what (b) would have to build again: nothing forks inside the app's process; a session's tree ends through the same subreaper and kill phase as a command's; and the PTY code is plain C that CI tests with real terminals (`runtime/tests/test-pty.py`, 19 tests; nine broken copies of the launcher each fail some).
- **Window sizes travel in-band,** as frames on the launcher's stdin beside the input: a type byte, a 16-bit length, the payload. So a resize keeps its place among the keystrokes, and a session needs no file. A frame of an unknown type ends the session, so the relay never guesses.
- **Output reaches Dart through a Flutter API** (`TerminalEvents`), as the runtime's and search's events do: one mechanism for every host, typed, in order on the main thread. An event channel's own buffering would add nothing, because the credit window already bounds what is in flight.
- **Floods are bounded by credit.** The view acknowledges what it has drawn, and the host reads at most a window (256 KiB) past that. The program then blocks in the kernel, behind the launcher, which stops reading the terminal when its stdout is full. Nothing is lost, and the app holds at most a window for the view plus a 1 MiB buffer per session. Batches go at most every 16 ms, the first bytes after a quiet moment at once.
- **The shell is the runtime's bash** with CodeForge's rc file, and nothing else: without bash a session fails, never falling back silently.

## Consequences
- Each session costs one more process, the launcher (under 1 MiB resident), and one copy of each byte.
- Throughput is bounded by the window per batch: about 16 MB/s at the defaults, more than a terminal view draws.
- A view that stops acknowledging stalls its program, by design, and never the app. An end always gets through: an ending session reads freely, and so does one whose launcher has exited once its view has been silent for 2 s.
- On the phone the host's part of an echo takes up to about 8 ms (p95), which leaves about 41 ms of the budget for the bridge to the page, the WebView and xterm.js. W6 measures the whole path there.
- W3's view must acknowledge what xterm.js has written (its write callback). W5's foreground service keeps the process, and so the sessions, alive in the background.
- `termux.c` stays out, so it needs no legal review.
