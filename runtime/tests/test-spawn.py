#!/usr/bin/env python3
"""Tests for the runtime's command launcher (CodeForge's own, Phase 4 W4; gate G4).

native/runtime-core/src/main/jni/codeforge-spawn.c is the program every
runtime command starts through on the device (libcodeforge-spawn.so). Its
logic is plain Linux, so this compiles it with the host's C compiler and
checks it here, on every CI run; the emulator gate runs the Android build
(RuntimeCommandsTest.kt). It checks that:

  * the command's output, error output and exit status come back, and the
    status file says how it ended;
  * the command runs in a new session and process group of its own, with
    every signal at its default, none blocked, and no core files;
  * a child the command leaves running is ended when the command exits;
  * stopping the launcher (SIGTERM, as Process.destroy() sends) ends the
    whole tree within the grace period, a process that ignores SIGTERM and
    one that keeps starting children included;
  * a process that left the group (setsid, a double fork) is ended too;
  * a program that cannot run is reported (126, 127), and so is a command
    that a signal ended;
  * after every test, no process the test started is left.

Run: python3 runtime/tests/test-spawn.py
"""

import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPOSITORY = os.path.dirname(os.path.dirname(HERE))
SOURCE = os.path.join(REPOSITORY, "native", "runtime-core", "src", "main", "jni", "codeforge-spawn.c")

BUILD = tempfile.mkdtemp(prefix="codeforge-spawn-")
SPAWN = os.path.join(BUILD, "codeforge-spawn")


def setUpModule():
    compiler = os.environ.get("CC") or shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")
    if compiler is None:
        raise RuntimeError("no C compiler on this machine: the launcher cannot be tested")
    # -Werror here: the launcher is CodeForge's own, and its warnings are bugs.
    subprocess.run([compiler, "-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror",
                    "-o", SPAWN, SOURCE], check=True)


def tearDownModule():
    shutil.rmtree(BUILD, ignore_errors=True)


def processes_with(marker):
    """Processes whose command line holds `marker` anywhere (zombies have none).

    Anywhere, not only as a whole argument: the shells that start the marked
    sleeps carry it inside their script, and a broken launcher must not leave
    a shell behind that keeps starting them.
    """
    found = []
    for name in os.listdir("/proc"):
        if not name.isdigit() or int(name) == os.getpid():
            continue
        try:
            with open("/proc/%s/cmdline" % name, "rb") as handle:
                command_line = handle.read()
        except OSError:
            continue
        if marker.encode() in command_line:
            found.append(int(name))
    return found


class SpawnTest(unittest.TestCase):
    marker = None

    def setUp(self):
        self.directory = tempfile.mkdtemp(prefix="spawn-test-")
        self.status_file = os.path.join(self.directory, "status")
        # A sleep no other process runs: its duration names this test's
        # processes, and is about a minute, so that even a launcher too broken
        # for the clean-up below leaves nothing for long.
        SpawnTest.serial = getattr(SpawnTest, "serial", 0) + 1
        self.marker = "%d.%04d" % (50 + SpawnTest.serial, os.getpid() % 10000)

    def tearDown(self):
        left = []
        for _ in range(20):
            left = processes_with(self.marker)
            if not left:
                break
            time.sleep(0.05)
        # Whatever is left is killed, the shells first, until nothing is.
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

    def run_spawn(self, *program, grace=300, stop_after=None, status=True, signal_to_send=signal.SIGTERM,
                  preexec=None, restore_signals=True):
        arguments = [SPAWN]
        if status:
            arguments += ["--status", self.status_file]
        arguments += ["--grace", str(grace), "--"] + list(program)
        started = time.monotonic()
        process = subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, preexec_fn=preexec,
                                   restore_signals=restore_signals)
        if stop_after is not None:
            time.sleep(stop_after)
            process.send_signal(signal_to_send)
        out, err = process.communicate(timeout=30)
        self.elapsed = time.monotonic() - started
        return process.returncode, out.decode(), err.decode()

    def status(self):
        with open(self.status_file) as handle:
            return dict(line.split("=", 1) for line in handle.read().splitlines() if "=" in line)

    def sleep(self):
        return "sleep %s" % self.marker

    def test_the_output_the_error_output_and_the_exit_status_come_back(self):
        code, out, err = self.run_spawn("/bin/sh", "-c", "echo out; echo err >&2; exit 3")
        self.assertEqual((code, out, err), (3, "out\n", "err\n"))
        status = self.status()
        self.assertEqual(status["reason"], "exited")
        self.assertEqual(status["exit"], "3")
        self.assertEqual(status["ended"], "0")
        self.assertEqual(status["remaining"], "0")
        self.assertEqual(status["subreaper"], "1")
        self.assertTrue(status["pid"].isdigit())
        self.assertEqual(status["group"], status["pid"], "the launcher does not lead its own group")

    def test_the_command_runs_in_a_session_and_a_group_of_its_own(self):
        code, out, _ = self.run_spawn("/bin/sh", "-c", "cat /proc/$$/stat")
        self.assertEqual(code, 0)
        fields = out[out.rindex(")") + 2:].split()
        group, session = fields[2], fields[3]
        spawner = self.status()["pid"]
        self.assertEqual(group, spawner, "the command is not in the launcher's group")
        self.assertEqual(session, spawner, "the command is not in the launcher's session")
        self.assertNotEqual(group, str(os.getpgrp()))

    def test_every_signal_is_at_its_default_and_none_is_blocked(self):
        def hostile():
            # What an app process may hand down: an ignored SIGPIPE, a blocked signal.
            signal.signal(signal.SIGPIPE, signal.SIG_IGN)
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGUSR1, signal.SIGTERM})
        code, out, _ = self.run_spawn("/bin/cat", "/proc/self/status", preexec=hostile, restore_signals=False)
        self.assertEqual(code, 0)
        masks = dict(line.split(":\t", 1) for line in out.splitlines() if ":\t" in line)
        self.assertEqual(int(masks["SigIgn"], 16), 0, "signals still ignored: %s" % masks["SigIgn"])
        self.assertEqual(int(masks["SigBlk"], 16), 0, "signals still blocked: %s" % masks["SigBlk"])

    def test_a_crash_writes_no_core_file(self):
        code, out, _ = self.run_spawn("/bin/sh", "-c", "ulimit -c")
        self.assertEqual((code, out.strip()), (0, "0"))

    def test_a_child_left_running_is_ended_when_the_command_exits(self):
        code, out, _ = self.run_spawn("/bin/sh", "-c", self.sleep() + " & echo started")
        self.assertEqual((code, out), (0, "started\n"))
        self.assertLess(self.elapsed, 3.0)
        status = self.status()
        self.assertEqual(status["reason"], "exited")
        self.assertEqual(status["ended"], "1")
        self.assertEqual(status["remaining"], "0")

    def test_stopping_ends_the_tree_and_a_child_that_ignores_sigterm(self):
        script = "%s & (trap '' TERM; %s) & %s" % (self.sleep(), self.sleep(), self.sleep())
        code, _, _ = self.run_spawn("/bin/sh", "-c", script, grace=300, stop_after=0.5)
        self.assertEqual(code, 128 + signal.SIGTERM)
        self.assertLess(self.elapsed, 4.0)
        status = self.status()
        self.assertEqual(status["reason"], "stopped")
        self.assertEqual(status["stop_signal"], str(int(signal.SIGTERM)))
        self.assertEqual(status["signal"], str(int(signal.SIGTERM)))
        self.assertGreaterEqual(int(status["ended"]), 4)
        self.assertEqual(status["remaining"], "0")

    def test_sigint_and_sighup_stop_it_too(self):
        for sent in (signal.SIGINT, signal.SIGHUP):
            code, _, _ = self.run_spawn("/bin/sh", "-c", self.sleep(), stop_after=0.3, signal_to_send=sent)
            self.assertEqual(self.status()["stop_signal"], str(int(sent)))
            self.assertEqual(self.status()["remaining"], "0")
            self.assertGreaterEqual(code, 128)

    def test_a_process_that_left_the_group_is_ended(self):
        if shutil.which("setsid") is None:
            self.skipTest("no setsid program here")
        code, out, _ = self.run_spawn("/bin/sh", "-c", "setsid %s & sleep 0.2; echo left" % self.sleep())
        self.assertEqual((code, out), (0, "left\n"))
        self.assertGreaterEqual(int(self.status()["ended"]), 1)
        self.assertEqual(self.status()["remaining"], "0")

    def test_a_double_forked_daemon_is_ended(self):
        if shutil.which("setsid") is None:
            self.skipTest("no setsid program here")
        script = "(setsid sh -c '%s &' &); sleep 0.3; echo daemonized" % self.sleep()
        code, out, _ = self.run_spawn("/bin/sh", "-c", script)
        self.assertEqual((code, out), (0, "daemonized\n"))
        self.assertGreaterEqual(int(self.status()["ended"]), 1)
        self.assertEqual(self.status()["remaining"], "0")

    def test_many_children_are_ended(self):
        script = "for i in $(seq 1 40); do %s & done; %s" % (self.sleep(), self.sleep())
        code, _, _ = self.run_spawn("/bin/sh", "-c", script, stop_after=0.8)
        self.assertGreaterEqual(int(self.status()["ended"]), 41)
        self.assertEqual(self.status()["remaining"], "0")
        self.assertEqual(code, 128 + signal.SIGTERM)

    def test_a_process_that_keeps_starting_children_is_killed(self):
        # Bounded (400 children at most), in case the launcher fails to kill it.
        script = ("trap '' TERM; i=0; while [ $i -lt 400 ]; do %s & i=$((i + 1)); sleep 0.02; done"
                  % self.sleep())
        code, _, _ = self.run_spawn("/bin/sh", "-c", script, grace=200, stop_after=0.3)
        self.assertEqual(code, 128 + signal.SIGKILL)
        status = self.status()
        self.assertEqual(status["signal"], str(int(signal.SIGKILL)))
        self.assertEqual(status["remaining"], "0")
        self.assertLess(self.elapsed, 6.0)

    def test_a_command_ended_by_a_signal_is_reported(self):
        code, _, _ = self.run_spawn("/bin/sh", "-c", "kill -KILL $$")
        self.assertEqual(code, 128 + signal.SIGKILL)
        status = self.status()
        self.assertEqual(status["reason"], "signaled")
        self.assertEqual(status["signal"], str(int(signal.SIGKILL)))

    def test_a_program_that_is_not_there_is_reported(self):
        code, _, _ = self.run_spawn(os.path.join(self.directory, "missing"))
        self.assertEqual(code, 127)
        self.assertEqual(self.status()["reason"], "exec_failed")
        self.assertEqual(self.status()["exec_errno"], "2")

    def test_a_file_that_cannot_run_is_reported(self):
        plain = os.path.join(self.directory, "plain")
        with open(plain, "w") as handle:
            handle.write("not a program\n")
        os.chmod(plain, 0o644)
        code, _, _ = self.run_spawn(plain)
        self.assertEqual(code, 126)
        self.assertEqual(self.status()["exec_errno"], "13")

    def test_it_runs_without_a_status_file(self):
        code, out, _ = self.run_spawn("/bin/echo", "plain", status=False)
        self.assertEqual((code, out), (0, "plain\n"))

    def test_a_call_without_a_program_is_refused(self):
        process = subprocess.run([SPAWN, "--grace", "10"], capture_output=True, text=True)
        self.assertEqual(process.returncode, 125)
        self.assertIn("usage", process.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=1)
