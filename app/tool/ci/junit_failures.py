#!/usr/bin/env python3
"""What a failing JUnit test said, from the XML reports.

Gradle's plain console names a failing test and the first frame of its
stack; it never prints the exception's message, and this repository cannot
download a run's reports (only what CI commits back to ci-results is
readable). So every failure and error in a reports folder is summarised
here: the class, the test, the exception, its message, and the first frames
of the stack, with the output the test wrote around it.

Usage:
  junit_failures.py <folder with TEST-*.xml> [more folders]
  junit_failures.py --self-test    shows it reading a passing report, a
                                   failing one and a damaged one

Writes nothing when every test passed, so it can always be appended.
"""

from __future__ import annotations

import glob
import os
import sys
import tempfile
import xml.etree.ElementTree as ElementTree

#: The most characters of one failure's message.
MESSAGE_CHARS = 2000

#: The most lines of one failure's stack.
STACK_LINES = 25

#: The most characters of a failing test's own output.
OUTPUT_CHARS = 1200


def _text(element: ElementTree.Element) -> str:
    return (element.text or "").strip()


def _report(path: str) -> list[str]:
    """One XML report's failures, as lines."""
    try:
        tree = ElementTree.parse(path)
    except ElementTree.ParseError as broken:
        return [f"{os.path.basename(path)}: unreadable ({broken})"]
    lines: list[str] = []
    suite = tree.getroot()
    for case in suite.iter("testcase"):
        problems = list(case.findall("failure")) + list(case.findall("error"))
        if not problems:
            continue
        name = f"{case.get('classname', '?')} > {case.get('name', '?')}"
        for problem in problems:
            kind = problem.tag
            message = (problem.get("message") or "").strip()
            lines.append(f"{kind}: {name}")
            lines.append(f"  type: {problem.get('type', '?')}")
            if message:
                lines.append("  message: " + message[:MESSAGE_CHARS].replace("\n", "\n    "))
            stack = _text(problem).splitlines()
            # The message is repeated at the top of the stack; the frames follow.
            frames = [line for line in stack if line.strip().startswith("at ")]
            for frame in frames[:STACK_LINES]:
                lines.append("  " + frame.strip())
    out = suite.find("system-out")
    err = suite.find("system-err")
    if lines:
        for label, element in (("stdout", out), ("stderr", err)):
            if element is None:
                continue
            said = _text(element)
            if said:
                lines.append(f"  {label}: " + said[-OUTPUT_CHARS:].replace("\n", "\n    "))
    return lines


PASSING = """<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="dev.codeforge.app.git.GitUrlsTest" tests="2" skipped="0" failures="0" errors="0">
  <testcase name="a" classname="dev.codeforge.app.git.GitUrlsTest" time="0.1"/>
  <testcase name="b" classname="dev.codeforge.app.git.GitUrlsTest" time="0.2"/>
</testsuite>
"""

FAILING = """<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="dev.codeforge.app.git.GitRemoteRunnerTest" tests="2" skipped="0" failures="1" errors="1">
  <testcase name="aCloneAsksOnce" classname="dev.codeforge.app.git.GitRemoteRunnerTest" time="1.2"/>
  <testcase name="anSshKeyIsMade" classname="dev.codeforge.app.git.GitRemoteRunnerTest" time="2.0">
    <failure message="ssh-keygen did not make the key: exit=1 asked=[]" type="dev.codeforge.app.git.GitRefused">dev.codeforge.app.git.GitRefused: ssh-keygen did not make the key
	at dev.codeforge.app.git.SshKeys.create(SshKeys.kt:84)
	at dev.codeforge.app.git.GitRemoteRunnerTest.anSshKeyIsMade(GitRemoteRunnerTest.kt:310)
</failure>
  </testcase>
  <testcase name="aStoreIsSealed" classname="dev.codeforge.app.git.GitRemoteRunnerTest" time="0.4">
    <error message="the Keystore is not here" type="java.lang.IllegalStateException">java.lang.IllegalStateException: the Keystore is not here
	at dev.codeforge.app.git.CredentialStore.put(CredentialStore.kt:167)
</error>
  </testcase>
  <system-err><![CDATA[a line the test wrote]]></system-err>
</testsuite>
"""

DAMAGED = "<testsuite tests=\"1\" "


def self_test() -> bool:
    """Reads a passing report, a failing one and a damaged one."""
    ok = True
    with tempfile.TemporaryDirectory() as folder:
        with open(os.path.join(folder, "TEST-passing.xml"), "w", encoding="utf-8") as handle:
            handle.write(PASSING)
        lines = _report(os.path.join(folder, "TEST-passing.xml"))
        print(f"self-test: a passing report -> {'nothing, as it should' if not lines else 'FAIL ' + str(lines)}")
        ok &= not lines

        with open(os.path.join(folder, "TEST-failing.xml"), "w", encoding="utf-8") as handle:
            handle.write(FAILING)
        lines = _report(os.path.join(folder, "TEST-failing.xml"))
        said = "\n".join(lines)
        wanted = [
            "failure: dev.codeforge.app.git.GitRemoteRunnerTest > anSshKeyIsMade",
            "ssh-keygen did not make the key",
            "at dev.codeforge.app.git.SshKeys.create(SshKeys.kt:84)",
            "error: dev.codeforge.app.git.GitRemoteRunnerTest > aStoreIsSealed",
            "the Keystore is not here",
            "a line the test wrote",
        ]
        for want in wanted:
            found = want in said
            print(f"self-test: a failing report says {want[:48]!r} -> {'yes' if found else 'MISSED'}")
            ok &= found
        passing_named = "aCloneAsksOnce" in said
        print(f"self-test: a passing test is not named -> {'MISSED' if passing_named else 'yes'}")
        ok &= not passing_named

        with open(os.path.join(folder, "TEST-damaged.xml"), "w", encoding="utf-8") as handle:
            handle.write(DAMAGED)
        lines = _report(os.path.join(folder, "TEST-damaged.xml"))
        caught = bool(lines) and "unreadable" in lines[0]
        print(f"self-test: a damaged report -> {'said so' if caught else 'MISSED'}")
        ok &= caught
    return ok


def main(folders: list[str]) -> int:
    reports: list[str] = []
    for folder in folders:
        reports.extend(sorted(glob.glob(os.path.join(folder, "TEST-*.xml"))))
    lines: list[str] = []
    for report in reports:
        lines.extend(_report(report))
    if not lines:
        return 0
    print("--- failing tests, as the reports have them:")
    for line in lines:
        print(line)
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        raise SystemExit(2)
    if sys.argv[1] == "--self-test":
        raise SystemExit(0 if self_test() else 1)
    raise SystemExit(main(sys.argv[1:]))
