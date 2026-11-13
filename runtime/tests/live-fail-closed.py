#!/usr/bin/env python3
"""G2 against the real repository: a missing pinned package fails closed.

CodeForge's own (Phase 4 W2). test-pins.py proves the behaviour on a synthetic
repository; this runs the same `pins.py fetch` against the live Termux
repository, so CI shows the real server's answer is handled too. It copies
runtime/pins.json, points one pinned x86_64 package at a version that does not
exist, and fetches. It passes only when the fetch exits 1, names the package and
the re-pin, and hands nothing to the payload builder.

It uses the build's cache (CI runs it after fetching the pins), so every other
package comes from there and only the missing one reaches the network: the
situation a build meets when Termux drops a pinned version.

Needs the network, so it is not a test-*.py file: CI runs it in its own step.

Run: python3 runtime/tests/live-fail-closed.py [cache, default runtime/generated/cache]
"""

import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
RUNTIME = os.path.dirname(HERE)
MISSING_VERSION = "0.0.0-codeforge-missing"


def main(argv):
    cache = argv[1] if len(argv) > 1 else os.path.join(RUNTIME, "generated", "cache")
    with open(os.path.join(RUNTIME, "pins.json"), encoding="utf-8") as handle:
        pins = json.load(handle)
    entries = (pins.get("packages") or {}).get("x86_64") or []
    if not entries:
        print("live-fail-closed: the pins are not resolved yet", file=sys.stderr)
        return 1
    entry = entries[0]
    name = entry["package"]
    directory = os.path.dirname(entry["filename"])
    entry["version"] = MISSING_VERSION
    entry["filename"] = "%s/%s_%s_x86_64.deb" % (directory, name, MISSING_VERSION)
    with tempfile.TemporaryDirectory(prefix="codeforge-live-") as work:
        pins_path = os.path.join(work, "pins.json")
        with open(pins_path, "w", encoding="utf-8") as handle:
            json.dump(pins, handle)
        out = os.path.join(work, "debs")
        result = subprocess.run(
            [sys.executable, os.path.join(RUNTIME, "pins.py"), "--pins", pins_path, "fetch",
             "--arch", "x86_64", "--cache", cache, "--out", out],
            capture_output=True, text=True, timeout=1800)
        handed_over = os.path.exists(os.path.join(out, "packages.json"))
    expected = "pinned package %s %s (x86_64) is no longer in the repository" % (
        name, MISSING_VERSION)
    print(result.stderr.strip())
    if result.returncode == 1 and expected in result.stderr and "[repin]" in result.stderr \
            and not handed_over:
        print("live-fail-closed: OK - fetching a pinned %s that the repository does not have "
              "exited 1, named it, and handed nothing over" % name)
        return 0
    print("live-fail-closed: FAILED - exit %d, handed over: %s" % (result.returncode, handed_over),
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
