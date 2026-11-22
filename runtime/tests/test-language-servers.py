#!/usr/bin/env python3
"""Tests for runtime/language_servers.py (CodeForge's own, Phase 6 W2).

Builds pins and npm tarballs in memory, without the network, and checks:

  * the pins' rules: exact versions, the npm registry, SHA-512, the licence
    allowlist, no install script that would ship (an optional package may
    have one), every package in one server, the lockfile against
    package.json, and bundled.json against what ships;
  * a server's packages: its dependencies resolved as node resolves them
    from the lockfile's paths, optional ones left out;
  * the build: one archive and manifest per server, reproducible, the
    manifest's SHA-256 as the server's identity; native code (by name or by
    its first bytes), links, paths outside the package and paths the app's
    installer would refuse fail it, as does a source map naming a bundled
    package bundled.json lacks;
  * the bundled packages read from pnpm's store paths, scoped names and peer
    suffixes included, and a bundled path without a version refused;
  * the notices: the table, each distinct text once in the app's file, a
    package without a licence file named, and --check reporting staleness;
  * the cache: a good tarball reused, a bad one replaced, a mismatch refused.

Run: python3 runtime/tests/test-language-servers.py
"""

import base64
import hashlib
import importlib.util
import io
import json
import os
import shutil
import tarfile
import tempfile
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
RUNTIME = os.path.dirname(HERE)

_spec = importlib.util.spec_from_file_location("language_servers", os.path.join(RUNTIME, "language_servers.py"))
ls = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ls)

MIT = "MIT License\n\nCopyright (c) %s\n\nPermission is hereby granted, free of charge.\n"


def tgz(files, links=(), top="package"):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w:gz") as tar:
        for path, body in files.items():
            if isinstance(body, str):
                body = body.encode("utf-8")
            info = tarfile.TarInfo("%s/%s" % (top, path) if top else path)
            info.size = len(body)
            tar.addfile(info, io.BytesIO(body))
        for path, target in links:
            info = tarfile.TarInfo("%s/%s" % (top, path))
            info.type = tarfile.SYMTYPE
            info.linkname = target
            tar.addfile(info)
    return raw.getvalue()


def integrity(data):
    return "sha512-" + base64.b64encode(hashlib.sha512(data).digest()).decode("ascii")


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def write_json(path, document):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(document, handle)


def url(name, version):
    return "%s%s/-/%s-%s.tgz" % (ls.REGISTRY, name, name.rsplit("/", 1)[-1], version)


class Fixture:
    """A pins folder and the tarballs its fetch serves, by URL."""

    def __init__(self, work):
        self.pins = os.path.join(work, "pins")
        self.cache = os.path.join(work, "cache")
        os.makedirs(self.pins)
        self.tarballs = {}
        self.server_js = {
            "package.json": '{"name": "alpha-server", "version": "1.0.0"}',
            "lib/server.js": "require('alpha-util'); console.log('alpha')\n",
            "lib/server.js.map": json.dumps({"version": 3, "sources": [
                "../node_modules/.pnpm/inner@2.0.0/node_modules/inner/index.js",
                "../node_modules/.pnpm/@scope+deep@1.2.3_peer@4.0.0/node_modules/@scope/deep/lib/a.js",
                "../src/server.ts",
            ]}),
            "LICENSE": MIT % "Alpha",
        }
        self.util_js = {"package.json": '{"name": "alpha-util"}', "index.js": "module.exports = 1\n",
                        "LICENSE.md": MIT % "Util"}
        self.beta_js = {"package.json": '{"name": "beta"}', "cli.mjs": "console.log('beta')\n",
                        "LICENSE": MIT % "Alpha"}
        self.inner_js = {"package.json": '{"name": "inner"}', "license": MIT % "Inner"}
        self.deep_js = {"package.json": '{"name": "@scope/deep"}', "index.js": "1\n"}
        self.manifest = {
            "name": "test-servers", "private": True, "license": "Apache-2.0",
            "dependencies": {"alpha-server": "1.0.0", "beta": "2.0.0"},
            "codeforge": {"servers": [
                {"id": "alpha", "languages": ["alpha-lang"], "packages": ["alpha-server"],
                 "entry": "node_modules/alpha-server/lib/server.js", "arguments": ["--stdio"]},
                {"id": "beta", "languages": ["beta-lang"], "packages": ["beta"],
                 "entry": "node_modules/beta/cli.mjs", "arguments": []},
            ]},
        }
        self.write()

    def package(self, name, version, files, **extra):
        data = tgz(files)
        self.tarballs[url(name, version)] = data
        entry = {"version": version, "resolved": url(name, version), "integrity": integrity(data), "license": "MIT"}
        entry.update(extra)
        return entry

    def write(self, lock_extra=None, bundled_extra=None):
        packages = {
            "": {"name": "test-servers", "license": "Apache-2.0", "dependencies": dict(self.manifest["dependencies"])},
            "node_modules/alpha-server": self.package("alpha-server", "1.0.0", self.server_js,
                                                      dependencies={"alpha-util": "^1.0.0"},
                                                      optionalDependencies={"mac-only": "1.0.0"}),
            "node_modules/alpha-server/node_modules/alpha-util": self.package("alpha-util", "1.1.0", self.util_js),
            "node_modules/beta": self.package("beta", "2.0.0", self.beta_js),
            "node_modules/mac-only": self.package("mac-only", "1.0.0", {"package.json": "{}", "x.node": "native"},
                                                  optional=True, hasInstallScript=True, os=["darwin"]),
        }
        packages.update(lock_extra or {})
        bundled = [
            {"name": "inner", "version": "2.0.0", "license": "ISC", "tarball": url("inner", "2.0.0"),
             "integrity": self.bundle("inner", "2.0.0", self.inner_js), "in": ["alpha-server@1.0.0"]},
            {"name": "@scope/deep", "version": "1.2.3", "license": "MIT", "tarball": url("@scope/deep", "1.2.3"),
             "integrity": self.bundle("@scope/deep", "1.2.3", self.deep_js), "in": ["alpha-server@1.0.0"]},
        ] + (bundled_extra or [])
        with open(os.path.join(self.pins, "package.json"), "w") as handle:
            json.dump(self.manifest, handle)
        with open(os.path.join(self.pins, "package-lock.json"), "w") as handle:
            json.dump({"name": "test-servers", "lockfileVersion": 3, "requires": True, "packages": packages}, handle)
        with open(os.path.join(self.pins, "bundled.json"), "w") as handle:
            json.dump({"schema": 1, "packages": bundled}, handle)

    def bundle(self, name, version, files):
        data = tgz(files)
        self.tarballs[url(name, version)] = data
        return integrity(data)

    def fetch(self, address, expected, cache):
        data = self.tarballs[address]
        ls.check_integrity(data, expected)
        return data

    def load(self):
        return ls.load(self.pins)


class LanguageServersTest(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.mkdtemp()
        self.fixture = Fixture(self.work)

    def tearDown(self):
        shutil.rmtree(self.work)

    def problems(self):
        return ls.check(*self.fixture.load())

    def build(self, name="out"):
        out = os.path.join(self.work, name)
        return ls.build(self.fixture.pins, self.fixture.cache, out, fetch=self.fixture.fetch), os.path.join(out, "lsp")

    def refused(self, action):
        with self.assertRaises(ls.Refused) as caught:
            action()
        return str(caught.exception)

    # --- check ---

    def test_good_pins_hold(self):
        self.assertEqual([], self.problems())

    def test_a_range_is_not_a_pin(self):
        self.fixture.manifest["dependencies"]["beta"] = "^2.0.0"
        self.fixture.write()
        self.assertTrue(any("not pinned to an exact version" in p for p in self.problems()), self.problems())

    def test_a_tarball_off_the_registry_is_refused(self):
        self.fixture.write(lock_extra={"node_modules/beta": {
            "version": "2.0.0", "resolved": "https://example.com/beta.tgz", "integrity": "sha512-AAAA", "license": "MIT"}})
        self.assertTrue(any("not on the npm registry" in p for p in self.problems()), self.problems())

    def test_a_licence_off_the_allowlist_is_refused(self):
        entry = self.fixture.package("beta", "2.0.0", self.fixture.beta_js)
        entry["license"] = "GPL-3.0-only"
        self.fixture.write(lock_extra={"node_modules/beta": entry})
        self.assertTrue(any("not on the allowlist" in p for p in self.problems()), self.problems())

    def test_an_install_script_that_would_ship_is_refused_and_an_optional_one_is_not(self):
        entry = self.fixture.package("beta", "2.0.0", self.fixture.beta_js, hasInstallScript=True)
        self.fixture.write(lock_extra={"node_modules/beta": entry})
        problems = self.problems()
        self.assertTrue(any("node_modules/beta: it has an install script" in p for p in problems), problems)
        self.assertFalse(any("mac-only" in p for p in problems), problems)

    def test_a_package_in_no_server_is_refused(self):
        self.fixture.manifest["codeforge"]["servers"][1]["packages"] = []
        self.fixture.write()
        problems = self.problems()
        self.assertTrue(any("beta is pinned but belongs to no server" in p for p in problems), problems)

    def test_a_stale_lockfile_is_refused(self):
        self.fixture.manifest["dependencies"]["beta"] = "2.0.1"
        with open(os.path.join(self.fixture.pins, "package.json"), "w") as handle:
            json.dump(self.fixture.manifest, handle)
        self.assertTrue(any("the lockfile is stale" in p for p in self.problems()), self.problems())

    def test_bundled_in_a_package_that_does_not_ship_is_refused(self):
        self.fixture.write(bundled_extra=[{"name": "x", "version": "1.0.0", "license": "MIT", "tarball": url("x", "1.0.0"),
                                           "integrity": "sha512-AAAA", "in": ["mac-only@1.0.0"]}])
        self.assertTrue(any("which does not ship" in p for p in self.problems()), self.problems())

    def test_an_entry_outside_the_servers_packages_is_refused(self):
        self.fixture.manifest["codeforge"]["servers"][1]["entry"] = "node_modules/alpha-server/lib/server.js"
        self.fixture.write()
        self.assertTrue(any("entry" in p and "beta" in p for p in self.problems()), self.problems())

    # --- the closure ---

    def test_a_server_ships_its_dependencies_as_node_resolves_them_and_no_optional_one(self):
        manifest, lockfile, _ = self.fixture.load()
        paths = [path for path, _ in ls.shipped_packages(manifest, lockfile, manifest["codeforge"]["servers"][0])]
        self.assertEqual(["node_modules/alpha-server", "node_modules/alpha-server/node_modules/alpha-util"], paths)

    # --- build ---

    def test_the_build_writes_each_server_with_its_manifest_and_identity(self):
        described, out = self.build()
        self.assertEqual(["alpha", "beta"], [s["id"] for s in described])
        alpha = described[0]
        with zipfile.ZipFile(os.path.join(out, "alpha.zip")) as archive:
            names = archive.namelist()
            self.assertIn("node_modules/alpha-server/lib/server.js", names)
            self.assertIn("node_modules/alpha-server/node_modules/alpha-util/index.js", names)
            self.assertFalse(any("mac-only" in n for n in names), names)
            self.assertEqual(sorted(names), names)
            body = archive.read("node_modules/alpha-server/lib/server.js")
        manifest = read(os.path.join(out, "alpha-manifest.txt"))
        self.assertEqual(hashlib.sha256(manifest.encode("utf-8")).hexdigest(), alpha["identity"])
        line = "%s\t%d\tnode_modules/alpha-server/lib/server.js" % (hashlib.sha256(body).hexdigest(), len(body))
        self.assertIn(line, manifest.splitlines())
        self.assertEqual(len(names), alpha["files"])
        servers = json.loads(read(os.path.join(out, "servers.json")))
        self.assertEqual(1, servers["schema"])
        self.assertEqual(alpha["identity"], servers["servers"][0]["identity"])
        self.assertEqual(["alpha-lang"], servers["servers"][0]["languages"])

    def test_the_build_is_reproducible(self):
        _, first = self.build("one")
        _, second = self.build("two")
        for name in ("alpha.zip", "beta.zip", "alpha-manifest.txt", "servers.json"):
            with open(os.path.join(first, name), "rb") as a, open(os.path.join(second, name), "rb") as b:
                self.assertEqual(a.read(), b.read(), name)

    def test_native_code_is_refused_by_name_and_by_its_first_bytes(self):
        for name, body in (("build/Release/addon.node", "anything"), ("bin/tool", b"\x7fELF\x02\x01\x01" + b"\0" * 64),
                           ("lib/x.dylib", "x"), ("bin/macho", b"\xcf\xfa\xed\xfe" + b"\0" * 64)):
            self.fixture.beta_js = {"package.json": "{}", "cli.mjs": "1\n", name: body}
            self.fixture.write()
            self.assertIn("native code", self.refused(self.build), name)

    def test_a_link_is_refused(self):
        data = tgz({"package.json": "{}", "cli.mjs": "1\n"}, links=[("evil.js", "/etc/passwd")])
        self.fixture.tarballs[url("beta", "2.0.0")] = data
        self.fixture.write()
        self.fixture.tarballs[url("beta", "2.0.0")] = data
        lock = json.loads(read(os.path.join(self.fixture.pins, "package-lock.json")))
        lock["packages"]["node_modules/beta"]["integrity"] = integrity(data)
        write_json(os.path.join(self.fixture.pins, "package-lock.json"), lock)
        self.assertIn("not a regular file", self.refused(self.build))

    def test_a_path_the_installer_would_refuse_fails_the_build(self):
        self.fixture.beta_js = {"package.json": "{}", "cli.mjs": "1\n", "lib/a..b.js": "1\n"}
        self.fixture.write()
        self.assertIn("the installer would refuse", self.refused(self.build))

    def test_a_bundled_package_bundled_json_lacks_fails_the_build(self):
        self.fixture.write()
        bundled = json.loads(read(os.path.join(self.fixture.pins, "bundled.json")))
        bundled["packages"] = [p for p in bundled["packages"] if p["name"] != "inner"]
        write_json(os.path.join(self.fixture.pins, "bundled.json"), bundled)
        self.assertIn("bundled.json is stale", self.refused(self.build))

    def test_a_missing_entry_fails_the_build(self):
        self.fixture.manifest["codeforge"]["servers"][1]["entry"] = "node_modules/beta/missing.mjs"
        self.fixture.write()
        self.assertIn("is not in its packages", self.refused(self.build))

    # --- bundled packages ---

    def test_bundled_packages_come_from_pnpm_store_paths(self):
        files = {"a.js.map": json.dumps({"sources": [
            "webpack://x/../node_modules/.pnpm/vscode-jsonrpc@9.0.1/node_modules/vscode-jsonrpc/lib/a.js",
            "../node_modules/.pnpm/@yarnpkg+fslib@2.10.4/node_modules/@yarnpkg/fslib/lib/b.js",
            "../node_modules/.pnpm/chalk@4.1.2_supports-color@7.2.0/node_modules/chalk/source/index.js",
            "../src/own.ts"]}).encode()}
        self.assertEqual({("vscode-jsonrpc", "9.0.1"), ("@yarnpkg/fslib", "2.10.4"), ("chalk", "4.1.2")},
                         ls.bundled_in(files, "x@1"))

    def test_a_bundled_path_without_its_version_is_refused(self):
        files = {"a.js.map": json.dumps({"sources": ["../node_modules/lodash/index.js"]}).encode()}
        self.assertIn("without its version", self.refused(lambda: ls.bundled_in(files, "x@1")))

    # --- notices ---

    def notices_files(self):
        notices = os.path.join(self.work, "NOTICES.md")
        with open(notices, "w") as handle:
            handle.write("# Notices\n\nbefore\n\n%s\n%s\n\nafter\n" % (ls.BEGIN, ls.END))
        return notices, os.path.join(self.work, "language-servers.txt")

    def test_the_notices_list_every_package_and_each_text_once(self):
        notices, app = self.notices_files()
        stale = ls.notices(self.fixture.pins, self.fixture.cache, False, notices, app, fetch=self.fixture.fetch)
        self.assertEqual([notices, app], stale)
        document = read(notices)
        self.assertIn("before", document)
        self.assertIn("after", document)
        self.assertIn("| alpha-server | 1.0.0 | MIT | alpha | its own files | `LICENSE` |", document)
        self.assertIn("| inner | 2.0.0 | ISC | alpha | bundled in `alpha-server@1.0.0` | `license` |", document)
        self.assertIn("**Without a licence text in their package** (1): @scope/deep@1.2.3.", document)
        text = read(app)
        # alpha-server and beta carry the same text: one entry lists both.
        self.assertIn("Packages: alpha-server 1.0.0, beta 2.0.0\nFiles: alpha-server@1.0.0/LICENSE, beta@2.0.0/LICENSE\n", text)
        self.assertIn("Files: inner@2.0.0/license (bundled in alpha-server@1.0.0)", text)
        self.assertEqual(1, text.count("Copyright (c) Alpha"))

    def test_check_reports_stale_notices_and_then_current_ones(self):
        notices, app = self.notices_files()
        self.assertEqual([notices, app], ls.notices(self.fixture.pins, self.fixture.cache, True, notices, app,
                                                    fetch=self.fixture.fetch))
        ls.notices(self.fixture.pins, self.fixture.cache, False, notices, app, fetch=self.fixture.fetch)
        self.assertEqual([], ls.notices(self.fixture.pins, self.fixture.cache, True, notices, app,
                                        fetch=self.fixture.fetch))

    # --- the cache ---

    def test_the_cache_reuses_a_good_tarball_replaces_a_bad_one_and_refuses_a_mismatch(self):
        data = tgz({"package.json": "{}"})
        calls = []

        def opener(address):
            calls.append(address)
            return data

        self.assertEqual(data, ls.fetch_one("u", integrity(data), self.fixture.cache, opener))
        self.assertEqual(data, ls.fetch_one("u", integrity(data), self.fixture.cache, opener))
        self.assertEqual(1, len(calls), "a good cached tarball was downloaded again")
        with open(ls.cached_path(self.fixture.cache, integrity(data)), "wb") as handle:
            handle.write(b"damaged")
        self.assertEqual(data, ls.fetch_one("u", integrity(data), self.fixture.cache, opener))
        self.assertEqual(2, len(calls))
        self.assertIn("integrity mismatch", self.refused(lambda: ls.fetch_one(
            "u", integrity(b"something else"), self.fixture.cache, opener)))


if __name__ == "__main__":
    unittest.main(verbosity=2)
