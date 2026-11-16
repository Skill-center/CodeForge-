#!/usr/bin/env python3
"""Tests for runtime/provenance.py (CodeForge's own, Phase 4 W2; gate G2).

Builds a miniature repository and t1 checkout in a temporary directory and
checks that the record catches each way vendored code can drift:

  * `record` fills both hashes, and `check` then passes;
  * a vendored file edited anywhere but its package line fails;
  * an edited package line fails;
  * the runtime core's `rename` reaches the package and import lines and
    nothing else, round-trips exactly, and an edit beyond it fails;
  * `copy` writes every vendored file with its change and t1's mode, and
    refuses a file naming a t1 package where the rename cannot reach;
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
CORE = (b"package io.mcyber12.codingharness.core.exec;\n\nimport android.content.Context;\n\n"
        b"import io.mcyber12.codingharness.core.HarnessConfig;\n"
        b"import io.mcyber12.sealed.SealedInstaller;\n\n"
        b"/** Adapter: package and import lines name t1, nothing else does. */\n"
        b"public final class Adapter {\n    String imports = \"import nothing\";\n}\n")
COMMIT = "0123456789abcdef0123456789abcdef01234567"
RECORD = """# Provenance

- **Repository:** https://github.com/example/t1
- **Commit:** `%s`
- **Licence:** Apache-2.0

<!-- vendored:begin -->
| CodeForge file | t1 file | Change | t1 SHA-256 | CodeForge SHA-256 |
|---|---|---|---|---|
| `native/kernel/src/main/java/dev/codeforge/runtime/sealed/Kernel.java` | `sealed-runtime/Kernel.java` | package | `-` | `-` |
| `native/core/src/main/java/dev/codeforge/runtime/core/exec/Adapter.java` | `harness-core/Adapter.java` | rename | `-` | `-` |
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
        os.chmod(os.path.join(self.t1, "scripts", "payload.py"), 0o755)
        write(os.path.join(self.t1, "harness-core", "Adapter.java"), CORE)
        self.core = os.path.join(self.root, "native", "core", "src", "main", "java", "dev",
                                 "codeforge", "runtime", "core", "exec", "Adapter.java")
        write(self.core, provenance.forward(CORE, "rename"))
        self.java = os.path.join(self.root, "native", "kernel", "src", "main", "java", "dev",
                                 "codeforge", "runtime", "sealed", "Kernel.java")
        write(self.java, provenance.forward(JAVA, "package"))
        write(os.path.join(self.root, "runtime", "payload.py"), SCRIPT)
        write(os.path.join(self.root, "runtime", "own.py"), b"# ours\n")
        write(os.path.join(self.root, "runtime", "generated", "cache.bin"), b"ignored")
        write(os.path.join(self.root, "native", "PROVENANCE.md"), (RECORD % COMMIT).encode())
        self.assertEqual(provenance.record(self.root, self.t1), 3)

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

    def test_the_rename_reaches_package_and_import_lines_only(self):
        renamed = provenance.forward(CORE, "rename")
        self.assertIn(b"package dev.codeforge.runtime.core.exec;", renamed)
        self.assertIn(b"import dev.codeforge.runtime.core.HarnessConfig;", renamed)
        self.assertIn(b"import dev.codeforge.runtime.sealed.SealedInstaller;", renamed)
        self.assertIn(b"import android.content.Context;", renamed)
        self.assertIn(b'String imports = "import nothing";', renamed)
        self.assertNotIn(b"io.mcyber12", renamed)
        self.assertEqual(provenance.backward(renamed, "rename"), CORE)

    def test_an_edit_to_a_renamed_file_fails(self):
        with open(self.core, "rb") as handle:
            data = handle.read()
        write(self.core, data.replace(b"nothing else does", b"nothing else did"))
        self.assertIn("Adapter.java changed", self.problems())
        write(self.core, data.replace(b"import android.content.Context;",
                                      b"import android.content.Intent;"))
        self.assertIn("Adapter.java changed", self.problems())

    def test_copy_writes_each_file_with_its_change_and_mode(self):
        os.remove(self.core)
        os.remove(os.path.join(self.root, "runtime", "payload.py"))
        self.assertEqual(provenance.copy(self.root, self.t1), 3)
        self.assertEqual(self.problems(), "")
        mode = os.stat(os.path.join(self.root, "runtime", "payload.py")).st_mode & 0o777
        self.assertEqual(mode, 0o755)

    def test_copy_refuses_a_t1_name_the_rename_cannot_reach(self):
        write(os.path.join(self.t1, "harness-core", "Adapter.java"),
              CORE.replace(b"/** Adapter:", b"/** See io.mcyber12.sealed.SealedLayout. Adapter:"))
        with self.assertRaises(provenance.ProvenanceError):
            provenance.copy(self.root, self.t1)

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
        self.assertIn("23 vendored files (14 with the package renamed, 9 byte for byte)",
                      result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=1)
