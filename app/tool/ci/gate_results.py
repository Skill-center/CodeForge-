#!/usr/bin/env python3
"""Turns an instrumentation run into the runtime gates' evidence (Phase 4 W5).

The rule is t1's scripts/assert-gate-results.py: a skipped test is not a pass,
and a gate passes only when every class it expects ran, unskipped and green,
at least as many tests as it names (floors, so adding a test needs no change
here). It reads the run from either side:
  --am FILE          `am instrument -r` output (the emulator legs);
  --junit FILE       a JUnit XML report (Test Lab's test_result_N.xml);
and the run's figures, written by the tests as key=value:
  --figures FILE     the tests' report files (key=value lines), or a device
                     log, where the lines carry "RUNTIME_GATE key=value";
  --document TAG FILE  numbered "TAG i/n <chunk>" lines in a device log,
                     joined into one JSON document (CODEFORGE_SYNC_JSON).
What must hold:
  --expect CLASS:N   CLASS ran at least N tests, none failed or skipped;
  --require KEY=VAL  the figure KEY was recorded, with the value VAL;
  --need-document TAG  the document TAG was found whole.
And the evidence:
  --meta KEY=VAL     facts about the leg (device, image), kept as given;
  --out-json FILE, --out-txt FILE.

Usage: gate_results.py [options]   |   gate_results.py --self-test
Exit codes: 0 the gate passed, 1 it did not, 2 usage.
"""

import json
import os
import re
import sys
import tempfile
import xml.etree.ElementTree as ET

STATUS = "INSTRUMENTATION_STATUS: "
STATUS_CODE = "INSTRUMENTATION_STATUS_CODE: "
RESULT = "INSTRUMENTATION_RESULT: "
# AndroidJUnitRunner's status codes (androidx.test.internal.runner.listener).
CODES = {0: "passed", -1: "failed", -2: "failed", -3: "skipped", -4: "skipped"}
FIGURE = re.compile(r"RUNTIME_GATE ([A-Za-z0-9_.-]+)=(.*?)\s*$")
PLAIN_FIGURE = re.compile(r"^([a-z0-9_.-]+)=(.*?)\s*$")


def new_class():
    return {"tests": 0, "passed": 0, "failed": 0, "skipped": 0, "failures": []}


def parse_am(text):
    """(classes, problems) from `am instrument -r` output."""
    tests = {}
    order = []
    problems = []
    current, key = {}, None
    for line in text.splitlines():
        if line.startswith(STATUS):
            key, _, value = line[len(STATUS):].partition("=")
            current[key] = value
        elif line.startswith(STATUS_CODE):
            code = int(line[len(STATUS_CODE):].strip() or 0)
            name = (current.get("class"), current.get("test"))
            if name[0] and name[1]:
                if name not in tests:
                    order.append(name)
                    tests[name] = (None, "")
                if code != 1:
                    stack = current.get("stack", "").strip().splitlines()
                    tests[name] = (code, stack[0].strip() if stack else "")
            current, key = {}, None
        elif line.startswith(RESULT):
            key = None
            name, _, value = line[len(RESULT):].partition("=")
            if name == "shortMsg":
                problems.append("the run ended early: %s" % value.strip())
        elif line.startswith("INSTRUMENTATION_FAILED"):
            problems.append(line.strip())
        elif key is not None and key in current:
            current[key] += "\n" + line
    classes = {}
    for name in order:
        cls, test = name
        code, first = tests[name]
        entry = classes.setdefault(cls, new_class())
        entry["tests"] += 1
        outcome = CODES.get(code, "failed")
        entry[outcome] += 1
        if code is None:
            entry["failures"].append("%s: no result (the run stopped inside it)" % test)
        elif outcome == "failed":
            entry["failures"].append("%s: %s" % (test, first[:300]))
    return classes, problems


def parse_junit(paths):
    classes = {}
    for path in paths:
        try:
            root = ET.parse(path).getroot()
        except (ET.ParseError, OSError) as error:
            return classes, ["%s is not a JUnit report: %s" % (path, error)]
        for case in root.iter("testcase"):
            entry = classes.setdefault(case.get("classname", ""), new_class())
            entry["tests"] += 1
            failure = case.find("failure")
            if failure is None:
                failure = case.find("error")
            if failure is not None:
                entry["failed"] += 1
                text = (failure.get("message") or failure.text or "").strip().splitlines()
                entry["failures"].append("%s: %s" % (case.get("name"), (text[0] if text else "")[:300]))
            elif case.find("skipped") is not None:
                entry["skipped"] += 1
            else:
                entry["passed"] += 1
    return classes, []


def read_figures(paths):
    figures = {}
    for path in paths:
        if not os.path.exists(path):
            continue
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                match = FIGURE.search(line) or PLAIN_FIGURE.match(line)
                if match:
                    figures[match.group(1)] = match.group(2)
    return figures


def read_document(tag, path):
    """The last complete TAG document in the log, or None."""
    if not os.path.exists(path):
        return None
    pattern = re.compile(re.escape(tag) + r" (\d+)/(\d+) (.*?)\r?$")
    parts, found = {}, None
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            match = pattern.search(line.rstrip("\n"))
            if not match:
                continue
            index, total, chunk = int(match.group(1)), int(match.group(2)), match.group(3)
            if index == 1:
                parts = {}
            parts[index] = chunk
            if len(parts) == total and all(i in parts for i in range(1, total + 1)):
                try:
                    found = json.loads("".join(parts[i] for i in range(1, total + 1)))
                except ValueError:
                    pass
    return found


def judge(classes, run_problems, expected, figures, required, documents, needed):
    problems = list(run_problems)
    for cls, minimum in expected:
        entry = classes.get(cls)
        if not entry:
            problems.append("%s did not run" % cls)
            continue
        if entry["tests"] < minimum:
            problems.append("%s ran %d test(s), expected at least %d" % (cls, entry["tests"], minimum))
        if entry["failed"]:
            problems.append("%s has %d failure(s): %s" % (cls, entry["failed"], "; ".join(entry["failures"])))
        if entry["skipped"]:
            problems.append("%s skipped %d test(s) - a skip is not a pass" % (cls, entry["skipped"]))
    for key, value in required:
        if key not in figures:
            problems.append("figure %s was not recorded" % key)
        elif figures[key] != value:
            problems.append("figure %s=%s, required %s" % (key, figures[key], value))
    for tag in needed:
        if documents.get(tag) is None:
            problems.append("no complete %s document in the device log" % tag)
    return problems


def write(args, classes, problems, figures, documents):
    verdict = "pass" if not problems else "fail"
    evidence = {"verdict": verdict, "problems": problems, "meta": dict(args["meta"]),
                "expected": {cls: minimum for cls, minimum in args["expect"]},
                "classes": classes, "figures": figures, "documents": documents}
    lines = ["verdict=%s" % verdict]
    lines += ["%s=%s" % (key, value) for key, value in args["meta"]]
    for cls in sorted(classes):
        entry = classes[cls]
        lines.append("class %s tests=%d passed=%d failed=%d skipped=%d" % (
            cls, entry["tests"], entry["passed"], entry["failed"], entry["skipped"]))
    lines += ["problem: %s" % problem for problem in problems]
    lines += ["%s=%s" % (key, figures[key]) for key in sorted(figures)]
    for tag, document in sorted(documents.items()):
        lines.append("%s=%s" % (tag, "absent" if document is None else json.dumps(document, sort_keys=True)))
    text = "\n".join(lines) + "\n"
    for path, content in ((args["out-json"], json.dumps(evidence, indent=1, sort_keys=True) + "\n"),
                          (args["out-txt"], text)):
        if path:
            os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(content)
    return verdict, text


def pairs(values, separator):
    found = []
    for value in values:
        key, sep, rest = value.partition(separator)
        if not sep or not key:
            raise ValueError(value)
        found.append((key, rest))
    return found


def run(argv):
    args = {"am": [], "junit": [], "figures": [], "document": [], "expect": [], "require": [],
            "need-document": [], "meta": [], "out-json": None, "out-txt": None}
    rest = list(argv)
    try:
        while rest:
            flag = rest.pop(0)
            name = flag[2:] if flag.startswith("--") else None
            if name not in args:
                raise ValueError(flag)
            if name == "document":
                args[name].append((rest.pop(0), rest.pop(0)))
            elif isinstance(args[name], list):
                args[name].append(rest.pop(0))
            else:
                args[name] = rest.pop(0)
        args["expect"] = [(cls, int(n)) for cls, n in pairs(args["expect"], ":")]
        args["require"] = pairs(args["require"], "=")
        args["meta"] = pairs(args["meta"], "=")
    except (ValueError, IndexError):
        print(__doc__, file=sys.stderr)
        return 2
    classes, problems = {}, []
    for path in args["am"]:
        with open(path, encoding="utf-8", errors="replace") as handle:
            found, issues = parse_am(handle.read())
        classes.update(found)
        problems += issues
    if args["junit"]:
        found, issues = parse_junit(args["junit"])
        classes.update(found)
        problems += issues
    figures = read_figures(args["figures"])
    documents = {tag: read_document(tag, path) for tag, path in args["document"]}
    problems = judge(classes, problems, args["expect"], figures, args["require"], documents,
                     args["need-document"])
    verdict, text = write(args, classes, problems, figures, documents)
    sys.stdout.write(text)
    return 0 if verdict == "pass" else 1


SAMPLE_AM = """INSTRUMENTATION_STATUS: class=dev.codeforge.app.runtime.ExecModelTest
INSTRUMENTATION_STATUS: current=1
INSTRUMENTATION_STATUS: id=AndroidJUnitRunner
INSTRUMENTATION_STATUS: numtests=3
INSTRUMENTATION_STATUS: stream=
dev.codeforge.app.runtime.ExecModelTest:
INSTRUMENTATION_STATUS: test=dataDirectoryExecutionFollowsTargetSdk
INSTRUMENTATION_STATUS_CODE: 1
INSTRUMENTATION_STATUS: class=dev.codeforge.app.runtime.ExecModelTest
INSTRUMENTATION_STATUS: current=1
INSTRUMENTATION_STATUS: id=AndroidJUnitRunner
INSTRUMENTATION_STATUS: numtests=3
INSTRUMENTATION_STATUS: stream=.
INSTRUMENTATION_STATUS: test=dataDirectoryExecutionFollowsTargetSdk
INSTRUMENTATION_STATUS_CODE: 0
INSTRUMENTATION_STATUS: class=dev.codeforge.app.runtime.SealedShellTest
INSTRUMENTATION_STATUS: current=2
INSTRUMENTATION_STATUS: id=AndroidJUnitRunner
INSTRUMENTATION_STATUS: numtests=3
INSTRUMENTATION_STATUS: stream=
dev.codeforge.app.runtime.SealedShellTest:
INSTRUMENTATION_STATUS: test=a_shellAndToolsRunFromTheApkPayload
INSTRUMENTATION_STATUS_CODE: 1
INSTRUMENTATION_STATUS: class=dev.codeforge.app.runtime.SealedShellTest
INSTRUMENTATION_STATUS: current=2
INSTRUMENTATION_STATUS: id=AndroidJUnitRunner
INSTRUMENTATION_STATUS: numtests=3
INSTRUMENTATION_STATUS: stack=java.lang.AssertionError: bash did not run (exit 127): 
\tat org.junit.Assert.fail(Assert.java:88)
INSTRUMENTATION_STATUS: stream=
Error in a_shellAndToolsRunFromTheApkPayload(dev.codeforge.app.runtime.SealedShellTest):
java.lang.AssertionError: bash did not run (exit 127):
INSTRUMENTATION_STATUS: test=a_shellAndToolsRunFromTheApkPayload
INSTRUMENTATION_STATUS_CODE: -2
INSTRUMENTATION_STATUS: class=dev.codeforge.app.runtime.SealedShellTest
INSTRUMENTATION_STATUS: current=3
INSTRUMENTATION_STATUS: id=AndroidJUnitRunner
INSTRUMENTATION_STATUS: numtests=3
INSTRUMENTATION_STATUS: stream=
INSTRUMENTATION_STATUS: test=b_startupInstallsOnceAndDpkgAgrees
INSTRUMENTATION_STATUS_CODE: 1
INSTRUMENTATION_STATUS: class=dev.codeforge.app.runtime.SealedShellTest
INSTRUMENTATION_STATUS: current=3
INSTRUMENTATION_STATUS: id=AndroidJUnitRunner
INSTRUMENTATION_STATUS: numtests=3
INSTRUMENTATION_STATUS: stack=org.junit.AssumptionViolatedException: not the sealed variant
INSTRUMENTATION_STATUS: stream=
INSTRUMENTATION_STATUS: test=b_startupInstallsOnceAndDpkgAgrees
INSTRUMENTATION_STATUS_CODE: -4
INSTRUMENTATION_RESULT: stream=

Time: 12.3

FAILURES!!!
Tests run: 3,  Failures: 1


INSTRUMENTATION_CODE: -1
"""

SAMPLE_CRASH = """INSTRUMENTATION_STATUS: class=dev.codeforge.app.runtime.ExecModelTest
INSTRUMENTATION_STATUS: test=dataDirectoryExecutionFollowsTargetSdk
INSTRUMENTATION_STATUS_CODE: 1
INSTRUMENTATION_RESULT: shortMsg=Process crashed.
INSTRUMENTATION_CODE: 0
"""

SAMPLE_JUNIT = """<?xml version='1.0' encoding='UTF-8' ?>
<testsuite name="" tests="4" failures="0" flakes="0" errors="0" skipped="0" time="61.2">
  <testcase name="dataDirectoryExecutionFollowsTargetSdk" classname="dev.codeforge.app.runtime.ExecModelTest" time="1.2" />
  <testcase name="a_shellAndToolsRunFromTheApkPayload" classname="dev.codeforge.app.runtime.SealedShellTest" time="20.1" />
  <testcase name="b_startupInstallsOnceAndDpkgAgrees" classname="dev.codeforge.app.runtime.SealedShellTest" time="30.4" />
  <testcase name="store: synchronous NORMAL against FULL" classname="dev.codeforge.app.syncmodes.SyncModesTest" time="9.5" />
</testsuite>
"""

SAMPLE_LOG = """11-18 10:00:00.100  4242  4260 I CodeForgeRuntimeGate: exec-model: targetSdk=36 sdk=36 abi=arm64-v8a
11-18 10:00:00.120  4242  4260 I CodeForgeRuntimeGate: RUNTIME_GATE exec_model_audit_outside_apk=0
11-18 10:00:01.000  4242  4260 I CodeForgeRuntimeGate: RUNTIME_GATE sealed_shell_audit_outside_apk=0
11-18 10:00:01.100  4242  4260 I CodeForgeRuntimeGate: RUNTIME_GATE first_install_ms=21034
11-18 10:00:09.000  4242  4242 I flutter : CODEFORGE_SYNC_JSON 1/2 {"test": "sync_modes", "st
11-18 10:00:09.001  4242  4242 I flutter : CODEFORGE_SYNC_JSON 2/2 ore": {"changes": {"count": 20}}}
"""


def self_test():
    failed = 0

    def check(name, condition, shown=""):
        nonlocal failed
        failed += not condition
        print("self-test %-6s %s%s" % ("ok" if condition else "FAILED", name,
                                       (": %s" % (shown,)) if shown else ""))

    classes, problems = parse_am(SAMPLE_AM)
    shell = classes.get("dev.codeforge.app.runtime.SealedShellTest", {})
    check("am: a pass, a failure and an assumption failure are told apart",
          classes["dev.codeforge.app.runtime.ExecModelTest"]["passed"] == 1
          and shell.get("failed") == 1 and shell.get("skipped") == 1 and not problems,
          {k: (v["passed"], v["failed"], v["skipped"]) for k, v in classes.items()})
    check("am: the failure keeps its first line",
          shell.get("failures") == ["a_shellAndToolsRunFromTheApkPayload: java.lang.AssertionError: "
                                    "bash did not run (exit 127):"], shell.get("failures"))
    verdict = judge(classes, problems, [("dev.codeforge.app.runtime.SealedShellTest", 2)], {}, [], {}, [])
    check("am: a failure and a skip both fail the gate", len(verdict) == 2, verdict)

    classes, problems = parse_am(SAMPLE_CRASH)
    exec_model = classes["dev.codeforge.app.runtime.ExecModelTest"]
    check("am: a crash is a problem, and the test it stopped in a failure",
          problems == ["the run ended early: Process crashed."] and exec_model["failed"] == 1,
          (problems, exec_model["failures"]))

    with tempfile.TemporaryDirectory() as work:
        junit = os.path.join(work, "test_result_1.xml")
        log = os.path.join(work, "logcat")
        with open(junit, "w", encoding="utf-8") as handle:
            handle.write(SAMPLE_JUNIT)
        with open(log, "w", encoding="utf-8") as handle:
            handle.write(SAMPLE_LOG)
        classes, problems = parse_junit([junit])
        figures = read_figures([log])
        document = read_document("CODEFORGE_SYNC_JSON", log)
        check("junit: four tests in three classes, all passed",
              sum(c["passed"] for c in classes.values()) == 4 and len(classes) == 3, sorted(classes))
        check("log: RUNTIME_GATE figures read, other lines left",
              figures == {"exec_model_audit_outside_apk": "0", "sealed_shell_audit_outside_apk": "0",
                          "first_install_ms": "21034"}, figures)
        check("log: the numbered document joined",
              document == {"test": "sync_modes", "store": {"changes": {"count": 20}}}, document)
        expected = [("dev.codeforge.app.runtime.ExecModelTest", 1),
                    ("dev.codeforge.app.runtime.SealedShellTest", 2),
                    ("dev.codeforge.app.syncmodes.SyncModesTest", 1)]
        required = [("exec_model_audit_outside_apk", "0"), ("sealed_shell_audit_outside_apk", "0")]
        verdict = judge(classes, problems, expected, figures, required,
                        {"CODEFORGE_SYNC_JSON": document}, ["CODEFORGE_SYNC_JSON"])
        check("junit + log: the gate passes", verdict == [], verdict)
        verdict = judge(classes, problems, expected + [("dev.codeforge.app.runtime.RuntimeInstallTest", 6)],
                        figures, required + [("audit_outside_apk", "0")], {"CODEFORGE_SYNC_JSON": None},
                        ["CODEFORGE_SYNC_JSON"])
        check("a class that did not run, a missing figure and a missing document fail it",
              len(verdict) == 3, verdict)
        out_json, out_txt = os.path.join(work, "leg.json"), os.path.join(work, "leg.txt")
        code = run(["--junit", junit, "--figures", log, "--document", "CODEFORGE_SYNC_JSON", log,
                    "--expect", "dev.codeforge.app.runtime.SealedShellTest:2",
                    "--require", "first_install_ms=21034", "--meta", "device=model=x,version=36",
                    "--out-json", out_json, "--out-txt", out_txt])
        with open(out_json, encoding="utf-8") as handle:
            evidence = json.load(handle)
        check("the command line writes the evidence",
              code == 0 and evidence["verdict"] == "pass"
              and evidence["meta"] == {"device": "model=x,version=36"}, (code, evidence["verdict"]))
    print("self-test: %s" % ("all cases pass" if not failed else "%d case(s) failed" % failed))
    return 1 if failed else 0


def main(argv):
    if argv[1:] == ["--self-test"]:
        return self_test()
    return run(argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
