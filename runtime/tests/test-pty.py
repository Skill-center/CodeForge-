#!/usr/bin/env python3
"""Tests for the launcher's terminal mode (CodeForge's own, Phase 5 W2; gate G2).

native/runtime-core/src/main/jni/codeforge-spawn.c runs a terminal session's
shell on a pseudo-terminal it opens, and relays between the terminal and its
own stdin and stdout (`--terminal ROWSxCOLS`). Its logic is plain Linux, so
this compiles it with the host's C compiler and drives it here with real
pseudo-terminals and the host's bash, on every CI run; the runtime gates run
the Android build (TerminalSessionTest.kt). It checks that:

  * bash echoes what is typed, and bytes pass unchanged both ways;
  * `stty size` follows a resize, and the job in front gets SIGWINCH;
  * Ctrl-C reaches the job in front, not the shell;
  * the shell leads a session of its own with the terminal as its
    controlling terminal from its first instruction, apart from the
    launcher, and the terminal is in UTF-8 mode;
  * the exit code comes back, with what the shell wrote just before it;
  * stopping the launcher, closing its stdin, breaking its stdout or a frame
    of an unknown kind ends the session with the whole tree, a job that
    ignores SIGHUP and SIGTERM included; a job left running ends with the
    shell;
  * a 10 MB flood arrives whole, while a reader that pauses blocks the
    program writing it and the launcher's memory stays bounded; input larger
    than every buffer arrives whole to a program that reads it late;
  * a program that cannot start is reported, and so is a bad size;
  * after every test, no process the test started is left.

It also measures what the relay adds to a keystroke's echo (ADR-0014): the
terminal's own echo, read straight from a pseudo-terminal and through the
launcher, printed as a RELAY_ECHO line.

Run: python3 runtime/tests/test-pty.py
"""

import os
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPOSITORY = os.path.dirname(os.path.dirname(HERE))
SOURCE = os.path.join(REPOSITORY, "native", "runtime-core", "src", "main", "jni", "codeforge-spawn.c")

BUILD = tempfile.mkdtemp(prefix="codeforge-pty-")
SPAWN = os.path.join(BUILD, "codeforge-spawn")
BASH = shutil.which("bash") or "/bin/bash"
CAT = shutil.which("cat") or "/bin/cat"

FRAME_INPUT = 1
FRAME_SIZE = 2


def setUpModule():
    compiler = os.environ.get("CC") or shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")
    if compiler is None:
        raise RuntimeError("no C compiler on this machine: the launcher cannot be tested")
    # -Werror here: the launcher is CodeForge's own, and its warnings are bugs.
    subprocess.run([compiler, "-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror",
                    "-o", SPAWN, SOURCE], check=True)


def tearDownModule():
    shutil.rmtree(BUILD, ignore_errors=True)


def frame(kind, payload):
    return bytes([kind]) + struct.pack(">H", len(payload)) + payload


def input_frames(data):
    return b"".join(frame(FRAME_INPUT, data[i:i + 65535]) for i in range(0, len(data), 65535))


def size_frame(rows, columns):
    return frame(FRAME_SIZE, struct.pack(">HH", rows, columns))


def command_line(pid):
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as handle:
            return handle.read()
    except OSError:
        return b""


def processes_with(marker):
    """Processes whose command line holds `marker` anywhere (zombies have none)."""
    found = []
    for name in os.listdir("/proc"):
        if not name.isdigit() or int(name) == os.getpid():
            continue
        if marker.encode() in command_line(int(name)):
            found.append(int(name))
    return found


def stat_fields(pid):
    """/proc/<pid>/stat after the command name: state, ppid, pgrp, session, tty_nr, tpgid, ..."""
    with open("/proc/%d/stat" % pid) as handle:
        text = handle.read()
    return text[text.rindex(")") + 2:].split()


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(fraction * (len(ordered) - 1))))]


class Session:
    """One launcher in terminal mode, with its stdin and stdout as pipes."""

    def __init__(self, test, program, size="24x80", grace=300):
        self.status_file = os.path.join(test.directory, "status")
        # Readline's bracketed paste puts escape sequences around every
        # command's output, which the patterns below would have to skip.
        inputrc = os.path.join(test.directory, "inputrc")
        with open(inputrc, "w") as handle:
            handle.write("set enable-bracketed-paste off\n")
        environment = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": test.directory,
            "TERM": "xterm-256color",
            "PS1": "$ ",
            "LANG": "C.UTF-8",
            "INPUTRC": inputrc,
        }
        self.process = subprocess.Popen(
            [SPAWN, "--status", self.status_file, "--grace", str(grace), "--terminal", size, "--"] + program,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=environment, cwd=test.directory)
        self.output = b""
        # Where the last match ended: the shell's next prompt comes after it.
        self.seen = 0

    def write(self, data):
        self.process.stdin.write(data)
        self.process.stdin.flush()

    def type(self, text):
        self.write(input_frames(text.encode() if isinstance(text, str) else text))

    def resize(self, rows, columns):
        self.write(size_frame(rows, columns))

    def read_some(self, timeout):
        ready, _, _ = select.select([self.process.stdout], [], [], timeout)
        if not ready:
            return None
        data = os.read(self.process.stdout.fileno(), 1 << 16)
        self.output += data
        return data

    def expect(self, pattern, timeout=10.0, start=0):
        """Reads until `pattern` (bytes, a regular expression) matches the output after `start`."""
        expression = re.compile(pattern, re.DOTALL)
        deadline = time.monotonic() + timeout
        while True:
            match = expression.search(self.output, start)
            if match:
                self.seen = match.end()
                return match
            left = deadline - time.monotonic()
            if left <= 0:
                raise AssertionError("no %r within %.1f s in %r" % (pattern, timeout, self.output[-2000:]))
            if self.read_some(min(left, 0.2)) == b"":
                match = expression.search(self.output, start)
                if match:
                    self.seen = match.end()
                    return match
                raise AssertionError("output ended before %r: %r" % (pattern, self.output[-2000:]))

    def prompt(self, timeout=10.0):
        """Waits for the shell's prompt after the last match, whether it has come or not."""
        return self.expect(rb"\$ $", timeout, self.seen)

    def finish(self, timeout=20.0):
        """Reads to the end of the output; answers the launcher's exit status."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.read_some(0.2) == b"":
                break
        return self.process.wait(max(0.1, deadline - time.monotonic()))

    def status(self):
        with open(self.status_file) as handle:
            return dict(line.split("=", 1) for line in handle.read().splitlines() if "=" in line)

    def close(self):
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            try:
                stream.close()
            except OSError:
                pass
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait(10)


class TerminalModeTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.mkdtemp(prefix="pty-test-")
        # A sleep no other process runs: its duration names this test's
        # processes, and is about a minute, so that even a launcher too broken
        # for the clean-up below leaves nothing for long.
        TerminalModeTest.serial = getattr(TerminalModeTest, "serial", 0) + 1
        self.marker = "%d.%04d" % (70 + TerminalModeTest.serial, os.getpid() % 10000)
        self.sessions = []

    def tearDown(self):
        for session in self.sessions:
            session.close()
        left = []
        for _ in range(40):
            left = processes_with(self.marker)
            if not left:
                break
            time.sleep(0.05)
        deadline = time.monotonic() + 10
        survivors = left
        while survivors and time.monotonic() < deadline:
            for pid in survivors:
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass
            time.sleep(0.05)
            survivors = processes_with(self.marker)
        shutil.rmtree(self.directory, ignore_errors=True)
        self.assertEqual(left, [], "processes left behind: %s" % left)

    def start(self, program=None, **options):
        session = Session(self, program or [BASH, "--norc", "--noprofile", "-i"], **options)
        self.sessions.append(session)
        return session

    def shell(self, **options):
        session = self.start(**options)
        session.prompt()
        return session

    def sleep(self):
        return "sleep %s" % self.marker

    def wait_for_sleeps(self, count, timeout=10.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            sleeps = [pid for pid in processes_with(self.marker)
                      if command_line(pid).split(b"\0")[0].endswith(b"sleep")]
            if len(sleeps) >= count:
                return sleeps
            time.sleep(0.05)
        self.fail("fewer than %d sleeps started" % count)

    # ── Echo, size, signals ─────────────────────────────────────────────

    def test_bash_echoes_what_is_typed(self):
        session = self.shell()
        mark = len(session.output)
        session.type("echo $((6 * 7))\r")
        session.expect(rb"echo \$\(\(6 \* 7\)\)", start=mark)
        session.expect(rb"\r\n42\r\n", start=mark)

    def test_stty_size_follows_a_resize_and_the_job_in_front_hears_of_it(self):
        session = self.shell(size="24x80")
        mark = len(session.output)
        session.type("stty size\r")
        session.expect(rb"\r\n24 80\r\n", start=mark)
        session.prompt()
        mark = len(session.output)
        # The job in front hears SIGWINCH; the size and the next keystrokes keep their order.
        session.type("trap 'echo WIN''CH $(stty size)' WINCH; sleep 2 & wait\r")
        time.sleep(0.5)
        session.resize(40, 120)
        session.expect(rb"WINCH 40 120", start=mark)
        session.prompt()
        mark = len(session.output)
        session.resize(30, 100)
        session.type("stty size\r")
        session.expect(rb"\r\n30 100\r\n", start=mark)

    def test_ctrl_c_reaches_the_job_in_front_not_the_shell(self):
        session = self.shell()
        session.type(self.sleep() + "\r")
        self.wait_for_sleeps(1)
        mark = len(session.output)
        session.type(b"\x03")
        session.expect(rb"\^C", start=mark)
        session.prompt()
        self.assertEqual(processes_with(self.marker), [], "the job in front did not end")
        mark = len(session.output)
        session.type("echo rc=$?\r")
        session.expect(rb"\r\nrc=130\r\n", start=mark)
        self.assertIsNone(session.process.poll(), "the shell ended with its job")

    def test_the_shell_leads_a_session_of_its_own_on_the_terminal(self):
        session = self.shell()
        mark = len(session.output)
        session.type("echo SH=$$ TTY=$(tty) STAT=$(cut -d' ' -f1-8 /proc/$$/stat)\r")
        match = session.expect(rb"\r\nSH=(\d+) TTY=(\S+) STAT=(.*?)\r\n", start=mark)
        shell = int(match.group(1))
        status = session.status()
        launcher = int(status["pid"])
        self.assertEqual(status["mode"], "terminal")
        self.assertEqual(status["child"], str(shell))
        self.assertEqual(match.group(2).decode(), status["tty"])
        self.assertTrue(status["tty"].startswith("/dev/pts/"), status["tty"])
        fields = match.group(3).decode().split()
        # pid (comm) state ppid pgrp session tty_nr tpgid
        self.assertEqual(int(fields[3]), launcher, "the shell is not the launcher's child")
        self.assertEqual(int(fields[4]), shell, "the shell does not lead its process group")
        self.assertEqual(int(fields[5]), shell, "the shell does not lead its session")
        self.assertNotEqual(int(fields[6]), 0, "the shell has no controlling terminal")
        launcher_fields = stat_fields(launcher)
        self.assertEqual(int(launcher_fields[2]), launcher, "the launcher does not lead its own group")
        self.assertEqual(int(launcher_fields[3]), launcher, "the launcher is not in a session of its own")
        self.assertEqual(int(launcher_fields[4]), 0, "the launcher took the terminal itself")

    def test_the_program_has_the_terminal_from_its_first_instruction(self):
        # bash takes a terminal itself when it finds none, which would hide a
        # launcher that never gave it one; this program takes nothing.
        script = ("import os; f = open('/proc/self/stat').read().rsplit(')', 1)[1].split(); "
                  "print('PID=%d SESSION=%s GROUP=%s TTY_NR=%s TPGID=%s FOREGROUND=%d' "
                  "% (os.getpid(), f[3], f[2], f[4], f[5], os.tcgetpgrp(0)))")
        session = self.start([sys.executable, "-c", script])
        match = session.expect(rb"PID=(\d+) SESSION=(\d+) GROUP=(\d+) TTY_NR=(\d+) TPGID=(-?\d+) FOREGROUND=(\d+)")
        pid = match.group(1)
        self.assertEqual(match.group(2), pid, "the program does not lead its session")
        self.assertEqual(match.group(3), pid, "the program does not lead its group")
        self.assertNotEqual(match.group(4), b"0", "the program has no controlling terminal")
        self.assertEqual(match.group(5), pid, "the program is not the terminal's job in front")
        self.assertEqual(match.group(6), pid)
        self.assertEqual(session.finish(), 0)

    def test_the_terminal_is_in_utf8_mode_and_bytes_pass_unchanged(self):
        session = self.shell()
        mark = len(session.output)
        session.type("stty -a | tr ' ' '\\n' | grep -x iutf8\r")
        session.expect(rb"\r\niutf8\r\n", start=mark)
        session.prompt()
        # Output: a NUL byte and UTF-8, as written.
        mark = len(session.output)
        session.type("printf 'A\\000B caf\\303\\251 \\342\\202\\254 \\360\\237\\230\\200 Z\\n'\r")
        session.expect(re.escape("A\0B café € 😀 Z\r\n".encode()), start=mark)
        session.prompt()
        # Input: the bytes typed reach the program as typed.
        mark = len(session.output)
        session.type("read -r line; printf '%s' \"$line\" | od -An -tx1 | tr -d ' \\n'; echo\r")
        session.expect(rb"; echo\r\n", start=mark)
        session.type("é€😀\r".encode())
        session.expect(rb"\r\nc3a9e282acf09f9880\r\n", start=mark)

    # ── Exit ────────────────────────────────────────────────────────────

    def test_the_exit_code_comes_back_with_what_was_written_before_it(self):
        session = self.shell()
        # 200,000 bytes and an exit at once: the relay drains them after the shell is gone.
        # Z is \\132, so the echoed command line holds none.
        session.type("head -c 200000 /dev/zero | tr '\\0' '\\132'; printf 'last words'; exit 7\r")
        session.expect(rb"last words", timeout=20)
        said = time.monotonic()
        code = session.finish()
        # Once no process holds the terminal, its reads end (EIO) and the
        # launcher exits: it does not wait out the drain's idle limit.
        self.assertLess(time.monotonic() - said, 1.5)
        self.assertEqual(code, 7)
        self.assertEqual(session.output.count(b"Z"), 200000)
        self.assertIn(b"last words", session.output)
        status = session.status()
        self.assertEqual(status["reason"], "exited")
        self.assertEqual(status["exit"], "7")
        self.assertEqual(status["ended"], "0")
        self.assertEqual(status["remaining"], "0")
        self.assertNotIn("stop_cause", status)

    def test_output_still_waiting_when_the_shell_exits_is_relayed(self):
        session = self.shell()
        shell = int(session.status()["child"])
        # Nobody reads while the shell writes 100,000 bytes and exits: they wait
        # in the pipe, in the launcher and in the terminal when it is gone.
        session.type("head -c 100000 /dev/zero | tr '\\0' '\\132'; printf 'last words'; exit 5\r")
        deadline = time.monotonic() + 15
        while os.path.exists("/proc/%d" % shell) and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertFalse(os.path.exists("/proc/%d" % shell), "the shell did not exit")
        time.sleep(0.3)
        self.assertEqual(session.finish(), 5)
        self.assertEqual(session.output.count(b"Z"), 100000)
        self.assertTrue(session.output.endswith(b"last words") or b"last words" in session.output[-64:])

    def test_a_job_left_running_ends_with_the_shell(self):
        session = self.shell()
        session.type(self.sleep() + " &\r")
        self.wait_for_sleeps(1)
        session.type("exit 0\r")
        self.assertEqual(session.finish(), 0)
        status = session.status()
        self.assertEqual(status["reason"], "exited")
        self.assertEqual(status["ended"], "1")
        self.assertEqual(status["remaining"], "0")

    # ── Ending ──────────────────────────────────────────────────────────

    def start_a_tree(self, session):
        """A job in the background, one that ignores SIGHUP and SIGTERM, and one in front."""
        session.type("%s & (trap '' HUP TERM; %s) & %s\r" % (self.sleep(), self.sleep(), self.sleep()))
        self.wait_for_sleeps(3)

    def assert_ended_whole(self, session, cause):
        status = session.status()
        self.assertEqual(status["reason"], "stopped")
        self.assertEqual(status.get("stop_cause"), cause)
        # bash and the three sleeps (bash's subshell execs its last command).
        self.assertGreaterEqual(int(status["ended"]), 4, status)
        self.assertEqual(status["remaining"], "0")
        # The shell ended on the hang-up (an interactive bash ignores SIGTERM),
        # not on the SIGKILL that comes after the grace period.
        self.assertEqual(status["signal"], str(int(signal.SIGHUP)), status)
        self.assertEqual(processes_with(self.marker), [])
        return status

    def test_stopping_the_launcher_ends_the_whole_tree(self):
        session = self.shell()
        self.start_a_tree(session)
        started = time.monotonic()
        session.process.send_signal(signal.SIGTERM)
        code = session.finish()
        self.assertLess(time.monotonic() - started, 6.0)
        self.assertGreaterEqual(code, 128)
        status = self.assert_ended_whole(session, "signal")
        self.assertEqual(status["stop_signal"], str(int(signal.SIGTERM)))

    def test_closing_its_stdin_hangs_up_the_session(self):
        session = self.shell()
        self.start_a_tree(session)
        session.process.stdin.close()
        session.finish()
        status = self.assert_ended_whole(session, "input_closed")
        self.assertEqual(status["stop_signal"], "0")

    def test_a_broken_stdout_ends_the_session(self):
        session = self.shell()
        self.start_a_tree(session)
        session.process.stdout.close()
        # The shell's job writes; the launcher finds nobody reading.
        session.type("echo anyone\r")
        session.process.wait(15)
        self.assert_ended_whole(session, "output_closed")

    def test_a_frame_of_an_unknown_kind_ends_the_session(self):
        session = self.shell()
        self.start_a_tree(session)
        session.write(frame(9, b"rm -rf ~\r"))
        session.finish()
        self.assert_ended_whole(session, "protocol")
        self.assertNotIn(b"rm -rf", session.output, "a bad frame reached the shell")

    def test_a_size_frame_of_the_wrong_length_ends_the_session(self):
        session = self.shell()
        session.write(frame(FRAME_SIZE, b"\x00\x28"))
        session.finish()
        self.assertEqual(session.status().get("stop_cause"), "protocol")

    # ── Flow control ────────────────────────────────────────────────────

    def test_a_flood_arrives_whole_and_a_paused_reader_blocks_its_writer(self):
        count = 1300000  # 9,288,896 bytes from seq, 10,588,896 with the terminal's \r
        session = self.shell()
        session.type("printf '%%s\\n' BE''GIN; seq 1 %d; printf '%%s\\n' EN''D\r" % count)
        begin = session.expect(rb"\r\nBEGIN\r\n")
        while len(session.output) - begin.end() < 1_000_000:
            session.read_some(5)
        writer = None
        for pid in processes_with("1300000"):
            if command_line(pid).split(b"\0")[:3] == [b"seq", b"1", b"1300000"] or \
                    command_line(pid).split(b"\0")[0].endswith(b"/seq"):
                writer = pid
        self.assertIsNotNone(writer, "seq is not running")

        def written():
            with open("/proc/%d/io" % writer) as handle:
                return int(dict(line.split(": ") for line in handle.read().splitlines())["wchar"])

        # Nobody reads: seq fills the terminal, the launcher's buffer and the pipe, then waits.
        time.sleep(0.6)
        first = written()
        time.sleep(0.9)
        second = written()
        self.assertEqual(first, second, "seq kept writing while nobody read")
        launcher = int(session.status()["pid"])
        with open("/proc/%d/status" % launcher) as handle:
            memory = dict(line.split(":", 1) for line in handle.read().splitlines())
        peak_kib = int(memory["VmHWM"].split()[0])
        end = session.expect(rb"\r\nEND\r\n", timeout=120, start=begin.end())
        body = session.output[begin.end():end.start() + 2]
        expected = b"".join(b"%d\r\n" % i for i in range(1, count + 1))
        self.assertEqual(len(body), len(expected))
        self.assertTrue(body == expected, "the flood did not arrive whole")
        print("\nFLOOD bytes=%d seq_blocked_at=%d launcher_peak_rss_kib=%d" % (len(body), first, peak_kib))
        self.assertLess(peak_kib, 16 * 1024, "the launcher's memory grew with the flood")

    def test_input_larger_than_every_buffer_arrives_whole_when_read_late(self):
        session = self.shell()
        session.type("stty -echo; printf '%s\\n' RE''ADY; sleep 1; wc -c\r")
        session.expect(rb"\r\nREADY\r\n")
        lines = 3000
        data = (b"a" * 99 + b"\r") * lines + b"\x04"
        # The frames fill the terminal, the launcher's buffer and the pipe while wc
        # sleeps, so the writing blocks; a thread of its own does it.
        writer = threading.Thread(target=session.type, args=(data,))
        writer.start()
        session.expect(rb"\r\n%d\r\n" % (100 * lines), timeout=30)
        writer.join(10)
        self.assertFalse(writer.is_alive())

    # ── Failures ────────────────────────────────────────────────────────

    def test_a_program_that_cannot_start_is_reported(self):
        session = self.start([os.path.join(self.directory, "missing")])
        self.assertEqual(session.finish(), 127)
        status = session.status()
        self.assertEqual(status["reason"], "exec_failed")
        self.assertEqual(status["exec_errno"], "2")
        self.assertEqual(status["mode"], "terminal")

    def test_a_bad_size_is_refused(self):
        for size in ("0x80", "24x0", "24", "x80", "24x80x1", "-24x80", "24xab"):
            process = subprocess.run([SPAWN, "--terminal", size, "--", CAT], capture_output=True, text=True,
                                     stdin=subprocess.DEVNULL, timeout=10)
            self.assertEqual(process.returncode, 125, size)
            self.assertIn("usage", process.stderr, size)

    # ── The measurement (ADR-0014) ──────────────────────────────────────

    def test_what_the_relay_adds_to_an_echo(self):
        samples = 300
        warm_up = 20

        def measure(write, read_one):
            times = []
            for index in range(samples + warm_up):
                started = time.perf_counter()
                write(b"x")
                read_one()
                if index >= warm_up:
                    times.append((time.perf_counter() - started) * 1e6)
            return times

        # Straight: the terminal's own echo, read from its master by this process.
        master, slave = os.openpty()
        direct = subprocess.Popen([CAT], stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        os.close(slave)
        try:
            def read_master():
                select.select([master], [], [], 5)
                self.assertEqual(os.read(master, 16), b"x")
            straight = measure(lambda data: os.write(master, data), read_master)
        finally:
            direct.kill()
            direct.wait(5)
            os.close(master)

        # Through the launcher: frames in, the same echo out.
        session = self.start([CAT])
        time.sleep(0.2)

        def read_relayed():
            data = session.read_some(5)
            self.assertEqual(data, b"x")
        relayed = measure(lambda data: session.write(input_frames(data)), read_relayed)
        # The line typed so far, then end-of-file for cat.
        session.type(b"\r\x04")
        session.finish()

        figures = {
            "direct_p50_us": percentile(straight, 0.50), "direct_p95_us": percentile(straight, 0.95),
            "relay_p50_us": percentile(relayed, 0.50), "relay_p95_us": percentile(relayed, 0.95),
        }
        figures["added_p50_us"] = figures["relay_p50_us"] - figures["direct_p50_us"]
        figures["added_p95_us"] = figures["relay_p95_us"] - figures["direct_p95_us"]
        print("\nRELAY_ECHO samples=%d %s" % (samples, " ".join("%s=%d" % item for item in figures.items())))
        # ADR-0006's budget for a keystroke's echo is 50 ms at p95; the relay
        # must stay well inside it (PHASE_5_PLAN §3, W2).
        self.assertLess(figures["relay_p95_us"], 10_000)


if __name__ == "__main__":
    unittest.main(verbosity=1)
