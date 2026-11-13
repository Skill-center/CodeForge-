#!/usr/bin/env python3
"""Tests for runtime/pins.py (CodeForge's own, Phase 4 W2; gate G2).

Against a synthetic Termux repository (tests/fixtures.py) served over file://:

  * resolving pins the whole closure, in install order, with the bootstrap's
    versions, and the result passes the offline check;
  * fetching hands the payload builder exactly the pinned files and t1's
    packages.json, and works from the cache alone;
  * a pinned package that has gone from the repository fails closed, naming
    the package and the way to re-pin (G2: "a missing pinned package fails the
    build closed"); so do changed bytes and a bootstrap that is not the pinned one;
  * a bootstrap package the refresh leaves behind (a subpackage needing its
    parent's exact version) is refreshed too, and one that cannot be fails
    the resolve;
  * the check catches unmet dependencies, the bootstrap's included, versions
    below a constraint and malformed entries;
  * the committed runtime/pins.json passes the check.

Run: python3 runtime/tests/test-pins.py
"""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
RUNTIME = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import fixtures  # noqa: E402

_spec = importlib.util.spec_from_file_location("pins", os.path.join(RUNTIME, "pins.py"))
pins_tool = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pins_tool)

PINS_SCRIPT = os.path.join(RUNTIME, "pins.py")


def run_pins(*arguments):
    result = subprocess.run([sys.executable, PINS_SCRIPT] + list(arguments),
                            capture_output=True, text=True)
    return result.returncode, result.stdout, result.stderr


class PinsTest(unittest.TestCase):

    def setUp(self):
        self.work = tempfile.mkdtemp(prefix="codeforge-pins-")
        self.addCleanup(shutil.rmtree, self.work, True)
        self.repository = fixtures.Repository(os.path.join(self.work, "repo"))
        repo = self.repository
        repo.add("app", "2.0", files={"bin/app": b"\x7fELF app"},
                 depends="libfoo (>= 1.2), libbar | libbaz, libold")
        repo.add("libfoo", "1.3", files={"lib/libfoo.so": b"\x7fELF foo"}, depends="libc++")
        repo.add("libbaz", "1.0", files={"lib/libbaz.so": b"\x7fELF baz"})
        repo.add("libold", "1.1", files={"lib/libold.so": b"\x7fELF old new"})
        repo.add("libc++", "27", files={"lib/libc++_shared.so": b"\x7fELF c++"})
        repo.add("tool", "0.5", files={"bin/tool": b"\x7fELF tool"}, depends="vsh")
        repo.add("shell", "3.0", files={"bin/sh": b"\x7fELF sh"}, provides="vsh")
        self.bootstraps = {}
        for arch in fixtures.ARCHES:
            # The bootstrap ships libbaz at the repository's version (skipped)
            # and an older libold (refreshed from the repository).
            self.bootstraps[arch] = os.path.join(self.work, "bootstrap-%s.zip" % arch)
            fixtures.make_bootstrap(self.bootstraps[arch], {
                "libbaz": ("1.0", None), "libold": ("1.0", None), "bash": ("5.2", None)})
        self.pins_path = os.path.join(self.work, "pins.json")
        fixtures.write_json(self.pins_path, fixtures.pins_for(
            self.repository, self.bootstraps, ["app", "tool"]))
        self.cache = os.path.join(self.work, "cache")

    def resolve(self):
        code, out, err = run_pins("--pins", self.pins_path, "resolve", "--cache", self.cache)
        self.assertEqual(code, 0, err)
        with open(self.pins_path, encoding="utf-8") as handle:
            return json.load(handle)

    def fetch(self, arch="x86_64", cache=None, out=None):
        out = out or os.path.join(self.work, "debs", arch)
        return run_pins("--pins", self.pins_path, "fetch", "--arch", arch,
                        "--cache", cache or self.cache, "--out", out) + (out,)

    # ------------------------------------------------------------------ resolve

    def test_resolve_pins_the_closure_in_install_order(self):
        pins = self.resolve()
        for arch in fixtures.ARCHES:
            names = [entry["package"] for entry in pins["packages"][arch]]
            # t1's breadth-first order: the virtual vsh is queued as "shell"
            # only after libfoo has queued libc++.
            self.assertEqual(names, ["app", "tool", "libfoo", "libold", "libc++", "shell"])
            for entry in pins["packages"][arch]:
                with open(self.repository.path_of(arch, entry["package"]), "rb") as handle:
                    data = handle.read()
                self.assertEqual(entry["sha256"], hashlib.sha256(data).hexdigest())
                self.assertEqual(entry["size"], len(data))
            self.assertEqual({name: entry["version"] for name, entry
                              in pins["bootstrap"]["packages"][arch].items()},
                             {"bash": "5.2", "libbaz": "1.0", "libold": "1.0"})
            self.assertEqual(pins["consistency"][arch], [])
        self.assertTrue(pins["resolvedAt"].endswith("Z"))
        self.assertEqual(pins_tool.check(pins), [])

    def with_bootstrap_package(self, name, version, depends):
        """Rebuild the bootstraps with one more package, and re-pin their hashes."""
        for arch in fixtures.ARCHES:
            fixtures.make_bootstrap(self.bootstraps[arch], {
                "libbaz": ("1.0", None), "libold": ("1.0", None), "bash": ("5.2", None),
                name: (version, None, depends)})
        fixtures.write_json(self.pins_path, fixtures.pins_for(
            self.repository, self.bootstraps, ["app", "tool"]))

    def test_a_bootstrap_package_left_behind_by_the_refresh_is_refreshed_too(self):
        # The bootstrap's oldtool needs its libold exactly; the closure
        # refreshes libold 1.0 -> 1.1, so oldtool must follow.
        self.repository.add("oldtool", "1.1", files={"bin/oldtool": b"\x7fELF old"},
                            depends="libold (= 1.1)")
        self.with_bootstrap_package("oldtool", "1.0", "libold (= 1.0)")
        pins = self.resolve()
        for arch in fixtures.ARCHES:
            versions = {e["package"]: e["version"] for e in pins["packages"][arch]}
            self.assertEqual(versions["oldtool"], "1.1")
            self.assertEqual(versions["libold"], "1.1")
            self.assertEqual(pins["consistency"][arch], ["oldtool"])
        self.assertEqual(pins_tool.check(pins), [])
        code, stdout, err = run_pins("--pins", self.pins_path, "check")
        self.assertEqual(code, 0, err)
        self.assertIn("(1 for consistency)", stdout)

    def test_a_bootstrap_package_that_cannot_follow_fails_the_resolve(self):
        self.with_bootstrap_package("orphan", "1.0", "libold (= 1.0)")
        code, _, err = run_pins("--pins", self.pins_path, "resolve", "--cache", self.cache)
        self.assertEqual(code, 1)
        self.assertIn("the payload cannot be made consistent", err)
        self.assertIn("bootstrap's orphan 1.0: Depends on libold (= 1.0) is not met", err)

    def test_check_reports_a_bootstrap_package_left_behind(self):
        self.repository.add("oldtool", "1.1", files={"bin/oldtool": b"\x7fELF old"},
                            depends="libold (= 1.1)")
        self.with_bootstrap_package("oldtool", "1.0", "libold (= 1.0)")
        pins = self.resolve()
        pins["packages"]["x86_64"] = [e for e in pins["packages"]["x86_64"]
                                      if e["package"] != "oldtool"]
        problems = pins_tool.check(pins)
        self.assertIn("x86_64 bootstrap's oldtool 1.0: Depends on libold (= 1.0) is not met by "
                      "the pinned set or the bootstrap", problems)
        self.assertIn("x86_64: consistency lists oldtool, which is not pinned", problems)

    def test_unresolved_pins_fail_the_check_and_name_the_fix(self):
        code, _, err = run_pins("--pins", self.pins_path, "check")
        self.assertEqual(code, 1)
        self.assertIn("no packages are pinned for aarch64", err)
        self.assertIn("[repin]", err)

    # -------------------------------------------------------------------- fetch

    def test_fetch_hands_over_exactly_the_pinned_files(self):
        pins = self.resolve()
        out = os.path.join(self.work, "debs", "x86_64")
        os.makedirs(out)
        with open(os.path.join(out, "stale_0.1_x86_64.deb"), "wb") as handle:
            handle.write(b"left over from another pin")
        code, stdout, err, out = self.fetch(out=out)
        self.assertEqual(code, 0, err)
        expected = sorted(os.path.basename(entry["filename"])
                          for entry in pins["packages"]["x86_64"])
        self.assertEqual(sorted(n for n in os.listdir(out) if n.endswith(".deb")), expected)
        with open(os.path.join(out, "packages.json"), encoding="utf-8") as handle:
            manifest = json.load(handle)
        self.assertEqual(manifest["arch"], "x86_64")
        self.assertEqual([entry["package"] for entry in manifest["packages"]],
                         [entry["package"] for entry in pins["packages"]["x86_64"]])
        self.assertEqual(set(manifest["packages"][0]),
                         {"package", "version", "file", "sha256", "installedSize"})
        self.assertIn("fetched 6 pinned packages for x86_64", stdout)

    def test_fetch_works_from_the_cache_alone(self):
        self.resolve()
        self.assertEqual(self.fetch()[0], 0)
        shutil.rmtree(self.repository.root)
        code, stdout, err, _ = self.fetch(out=os.path.join(self.work, "again"))
        self.assertEqual(code, 0, err)
        self.assertIn("(6 from the cache", stdout)

    def test_a_corrupt_cache_entry_is_fetched_again(self):
        pins = self.resolve()
        entry = pins["packages"]["x86_64"][0]
        cached = os.path.join(self.cache, "debs", "x86_64", os.path.basename(entry["filename"]))
        with open(cached, "wb") as handle:
            handle.write(b"truncated")
        code, stdout, err, _ = self.fetch()
        self.assertEqual(code, 0, err)
        self.assertIn("(5 from the cache", stdout)
        self.assertEqual(pins_tool.sha256_file(cached), entry["sha256"])

    def test_a_missing_pinned_package_fails_closed_and_names_it(self):
        self.resolve()
        # Termux moves on: libfoo 1.3 is replaced by 1.4, and 1.3's file is gone.
        os.remove(self.repository.path_of("x86_64", "libfoo"))
        self.repository.add("libfoo", "1.4", files={"lib/libfoo.so": b"\x7fELF foo 1.4"},
                            depends="libc++")
        code, stdout, err, out = self.fetch(cache=os.path.join(self.work, "empty-cache"))
        self.assertEqual(code, 1)
        self.assertIn("pinned package libfoo 1.3 (x86_64) is no longer in the repository", err)
        self.assertIn("the index now lists 1.4", err)
        self.assertIn("[repin]", err)
        self.assertFalse(os.path.exists(os.path.join(out, "packages.json")),
                         "nothing may be handed to the payload builder")

    def test_every_missing_package_is_named_at_once(self):
        self.resolve()
        for name in ("libfoo", "shell"):
            os.remove(self.repository.path_of("aarch64", name))
        code, _, err, _ = self.fetch("aarch64", cache=os.path.join(self.work, "empty-cache"))
        self.assertEqual(code, 1)
        self.assertIn("libfoo 1.3 (aarch64)", err)
        self.assertIn("shell 3.0 (aarch64)", err)

    def test_changed_bytes_fail_closed(self):
        self.resolve()
        with open(self.repository.path_of("x86_64", "tool"), "ab") as handle:
            handle.write(b"tampered")
        code, _, err, _ = self.fetch(cache=os.path.join(self.work, "empty-cache"))
        self.assertEqual(code, 1)
        self.assertIn("pinned package tool 0.5 (x86_64): the repository serves different bytes",
                      err)

    def test_a_bootstrap_that_is_not_the_pinned_one_fails_closed(self):
        with open(self.bootstraps["aarch64"], "ab") as handle:
            handle.write(b"not the pinned zip")
        code, _, err = run_pins("--pins", self.pins_path, "bootstrap", "--arch", "aarch64",
                                "--cache", self.cache, "--out", os.path.join(self.work, "b"))
        self.assertEqual(code, 1)
        self.assertIn("the bootstrap for aarch64 does not match its pin", err)

    def test_the_pinned_bootstrap_is_handed_over(self):
        code, stdout, err = run_pins("--pins", self.pins_path, "bootstrap", "--arch", "x86_64",
                                     "--cache", self.cache, "--out", os.path.join(self.work, "b"))
        self.assertEqual(code, 0, err)
        self.assertTrue(os.path.isfile(os.path.join(self.work, "b", "bootstrap-x86_64.zip")))

    # -------------------------------------------------------------------- check

    def test_check_reports_an_unmet_dependency(self):
        pins = self.resolve()
        pins["packages"]["x86_64"] = [e for e in pins["packages"]["x86_64"]
                                      if e["package"] != "libfoo"]
        problems = pins_tool.check(pins)
        self.assertIn("x86_64 app: Depends on libfoo (>= 1.2) is not met by the pinned set "
                      "or the bootstrap", problems)

    def test_check_reports_a_version_below_its_constraint(self):
        pins = self.resolve()
        for entry in pins["packages"]["aarch64"]:
            if entry["package"] == "libfoo":
                entry["version"] = "1.1"
        self.assertTrue(any("aarch64 app: Depends on libfoo (>= 1.2)" in p
                            for p in pins_tool.check(pins)))

    def test_check_accepts_a_virtual_package_and_the_bootstrap(self):
        pins = self.resolve()
        # tool depends on the virtual vsh (shell provides it); app's
        # "libbar | libbaz" is met by the bootstrap's libbaz.
        self.assertEqual(pins_tool.check(pins), [])

    def test_check_rejects_malformed_entries(self):
        pins = self.resolve()
        entries = pins["packages"]["x86_64"]
        entries.append(dict(entries[0]))
        entries[1]["sha256"] = "ABC"
        entries[2]["filename"] = "/abs/" + os.path.basename(entries[2]["filename"])
        entries[3]["size"] = 0
        del pins["bootstrap"]["files"]["aarch64"]
        problems = "\n".join(pins_tool.check(pins))
        self.assertIn("x86_64 app is pinned twice", problems)
        self.assertIn("sha256 is not 64 lowercase hex digits", problems)
        self.assertIn("must be repository-relative", problems)
        self.assertIn("size must be a positive integer", problems)
        self.assertIn("bootstrap.files must pin exactly aarch64, x86_64", problems)

    # ---------------------------------------------------------- committed pins

    def test_the_committed_pins_pass_the_check(self):
        pins = pins_tool.read_pins(pins_tool.DEFAULT_PINS)
        self.assertEqual(pins_tool.check_inputs(pins), [])
        self.assertTrue(pins["repository"]["url"].startswith("https://"))
        for entry in pins["bootstrap"]["files"].values():
            self.assertTrue(entry["url"].startswith("https://"))
        self.assertEqual(pins["bootstrap"]["files"]["aarch64"]["sha256"],
                         "ea2aeba8819e517db711f8c32369e89e7c52cee73e07930ff91185e1ab93f4f3")
        self.assertEqual(pins["bootstrap"]["files"]["x86_64"]["sha256"],
                         "b7fd0f2e3a4de534be3144f9f91acc768630fc463eaf134ab2e64c545e834f7a")
        if pins.get("packages"):
            # Once resolved (the first [repin] commit), the whole set must hold.
            self.assertEqual(pins_tool.check(pins), [])


if __name__ == "__main__":
    unittest.main(verbosity=1)
