#!/usr/bin/env python3
"""Tests for runtime/provenance.py (CodeForge's own, Phase 4 W2; gate G2).

Builds a miniature repository and t1 checkout in a temporary directory and
checks that the record catches each way vendored code can drift:

  * `record` fills both hashes, and `check` then passes;
  * a vendored file edited anywhere but its package line fails;
  * an edited package line fails;
  * a file under native/ or runtime/ in neither table fails;
  * a listed file that is gone fails;
  * `record` refuses a file that is not t1's with the recorded change;
  * the header must name the repository, a full commit and the licence;
  * the repository's own native/PROVENANCE.md passes.

Run: python3 runtime/tests/test-provenance.py
"""

import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
RUNTIME = os.path.dirname(HERE)

_spec = importlib.util.spec_from_file_location("provenance",
                                               os.path.join(RUNTIME, "provenance.py"))
provenance = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(provenance)

JAVA = (b"package io.mcyber12.sealed;\n\nimport java.io.File;\n\n"
        b"/** Kernel class. */\npublic final class Kernel {\n}\n")
SCRIPT = b"#!/usr/bin/env python3\nprint('payload')\n"
COMMIT = "0123456789abcdef0123456789abcdef01234567"
RECORD = """# Provenance

- **Repository:** https://github.com/example/t1
- **Commit:** `%s`
- **Licence:** Apache-2.0

<!-- vendored:begin -->
| CodeForge file | t1 file | Change | t1 SHA-256 | CodeForge SHA-256 |
|---|---|---|---|---|
| `native/kernel/src/main/java/dev/codeforge/runtime/sealed/Kernel.java` | `sealed-runtime/Kernel.java` | package | `-` | `-` |
| `runtime/payload.py` | `scripts/payload.py` | none | `-` | `-` |
<!-- vendored:end -->

<!-- own:begin -->
| CodeForge file | What it is |
|---|---|
| `native/PROVENANCE.md` | this record |
| `runtime/own.py` | CodeForge's |
<!-- own:end -->
"""


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as handle:
        handle.write(data)


class ProvenanceTest(unittest.TestCase):

    def setUp(self):
        self.work = tempfile.mkdtemp(prefix="codeforge-provenance-")
        self.addCleanup(shutil.rmtree, self.work, True)
        self.t1 = os.path.join(self.work, "t1")
        self.root = os.path.join(self.work, "codeforge")
        write(os.path.join(self.t1, "sealed-runtime", "Kernel.java"), JAVA)
        write(os.path.join(self.t1, "scripts", "payload.py"), SCRIPT)
        self.java = os.path.join(self.root, "native", "kernel", "src", "main", "java", "dev",
                                 "codeforge", "runtime", "sealed", "Kernel.java")
        write(self.java, provenance.forward(JAVA, "package"))
        write(os.path.join(self.root, "runtime", "payload.py"), SCRIPT)
        write(os.path.join(self.root, "runtime", "own.py"), b"# ours\n")
        write(os.path.join(self.root, "runtime", "generated", "cache.bin"), b"ignored")
        write(os.path.join(self.root, "native", "PROVENANCE.md"), (RECORD % COMMIT).encode())
        self.assertEqual(provenance.record(self.root, self.t1), 2)

    def problems(self):
        return "\n".join(provenance.check(self.root)[0])

    def test_record_then_check_passes(self):
        self.assertEqual(self.problems(), "")
        with open(os.path.join(self.root, "native", "PROVENANCE.md")) as handle:
            text = handle.read()
        self.assertNotIn("`-`", text)

    def test_an_edit_beyond_the_package_line_fails(self):
        with open(self.java, "rb") as handle:
            data = handle.read()
        write(self.java, data.replace(b"Kernel class", b"Kernel klass"))
        problems = self.problems()
        self.assertIn("Kernel.java changed", problems)
        # Once the hash is updated by hand, the backward check still catches it.
        text = open(os.path.join(self.root, "native", "PROVENANCE.md")).read()
        row = [line for line in text.splitlines() if "Kernel.java" in line][0]
        recorded = row.split("|")[5].strip().strip("`")
        actual = provenance.sha256(open(self.java, "rb").read())
        write(os.path.join(self.root, "native", "PROVENANCE.md"),
              text.replace(recorded, actual).encode())
        self.assertIn("differs from t1's sealed-runtime/Kernel.java beyond the recorded change",
                      self.problems())

    def test_an_edited_package_line_fails(self):
        with open(self.java, "rb") as handle:
            data = handle.read()
        write(self.java, data.replace(b"dev.codeforge.runtime.sealed", b"dev.codeforge.other"))
        self.assertIn("Kernel.java changed", self.problems())

    def test_an_unrecorded_file_fails(self):
        write(os.path.join(self.root, "runtime", "stray.py"), b"# who wrote this?\n")
        self.assertIn("runtime/stray.py is not in PROVENANCE.md", self.problems())

    def test_a_missing_listed_file_fails(self):
        os.remove(os.path.join(self.root, "runtime", "own.py"))
        self.assertIn("runtime/own.py is listed as CodeForge's own but does not exist",
                      self.problems())

    def test_record_refuses_a_file_that_is_not_t1s(self):
        write(os.path.join(self.root, "runtime", "payload.py"), SCRIPT + b"# local edit\n")
        with self.assertRaises(provenance.ProvenanceError):
            provenance.record(self.root, self.t1)

    def test_the_header_is_required(self):
        path = os.path.join(self.root, "native", "PROVENANCE.md")
        text = open(path).read()
        write(path, text.replace("- **Commit:** `%s`" % COMMIT, "- **Commit:** main").encode())
        self.assertIn("full 40-digit sha", self.problems())

    def test_the_repositorys_record_passes(self):
        result = subprocess.run([sys.executable, os.path.join(RUNTIME, "provenance.py"), "check"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("18 vendored files (11 with the package renamed, 7 byte for byte)",
                      result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=1)
