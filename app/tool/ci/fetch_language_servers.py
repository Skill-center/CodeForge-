#!/usr/bin/env python3
"""Fetches Phase 6 W1's candidate language servers for the instrumented tests.

docs/phases/PHASE_6_PLAN.md §3 (W1): the compatibility spike runs each
candidate server under the sealed runtime's node, from the test APK's assets.
This script reads the pins (tool/ci/language_servers.json: each package's
name, version, tarball URL on the npm registry and the registry's SHA-512
integrity), then for each package:
  * downloads its tarball (or takes it from --cache) and checks it against
    its integrity: a mismatch fails, naming the package;
  * refuses a tarball holding native code (a .node, .so, .dylib, .dll or .exe
    file, or an ELF anywhere), a link, or a path outside the package: the
    servers ship as JavaScript, which the runtime's node runs, never as
    programs (docs/SECURITY.md §2);
  * writes it as <name>.zip, without npm's top folder (package/), so the test
    unpacks it with java.util.zip into node_modules/<name>/.
servers.json beside the zips names each package, its version, integrity,
licence and size; the test reads it. The output folder is the test APK's
assets (android/app/src/androidTest/assets/lsp/), which Git ignores. W2 moves
the chosen servers into the payload, pinned in runtime/language-servers/.

Usage:
  fetch_language_servers.py --pins tool/ci/language_servers.json --out DIR [--cache DIR]
  fetch_language_servers.py --self-test
Exit codes: 0 done, 1 refused or failed, 2 usage.
"""

import base64
import hashlib
import io
import json
import os
import sys
import tarfile
import tempfile
import time
import urllib.request
import zipfile

REGISTRY = "https://registry.npmjs.org/"
NATIVE_SUFFIXES = (".node", ".so", ".dylib", ".dll", ".exe")
MAX_TARBALL_BYTES = 64 * 1024 * 1024
ALGORITHMS = ("sha512", "sha384", "sha256")
DEFAULT_PINS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "language_servers.json")


class Refused(Exception):
    """A package that must not reach the test APK, with the reason."""


def check_integrity(data, integrity):
    """Raises Refused unless data hashes to integrity (a Subresource Integrity string)."""
    algorithm, _, expected = integrity.partition("-")
    if algorithm not in ALGORITHMS or not expected:
        raise Refused("unsupported integrity %r" % integrity)
    actual = base64.b64encode(hashlib.new(algorithm, data).digest()).decode("ascii")
    if actual != expected:
        raise Refused("integrity mismatch: the pins say %s, the tarball is %s-%s" % (integrity, algorithm, actual))


def validate(pins):
    """The pins' servers, each checked for shape; raises Refused on a bad entry."""
    if not isinstance(pins, dict) or pins.get("schema") != 1:
        raise Refused("the pins are not schema 1")
    servers = pins.get("servers")
    if not isinstance(servers, list) or not servers:
        raise Refused("the pins name no servers")
    seen = set()
    for server in servers:
        for key in ("name", "version", "tarball", "integrity"):
            if not isinstance(server.get(key), str) or not server[key]:
                raise Refused("a server without its %s: %r" % (key, server))
        name = server["name"]
        if name in seen:
            raise Refused("%s is pinned twice" % name)
        seen.add(name)
        if "/" in name or name.startswith("."):
            raise Refused("%s: a scoped or hidden name needs a folder rule first" % name)
        if not server["tarball"].startswith(REGISTRY):
            raise Refused("%s: its tarball is not on the npm registry: %s" % (name, server["tarball"]))
        algorithm = server["integrity"].partition("-")[0]
        if algorithm not in ALGORITHMS:
            raise Refused("%s: unsupported integrity %s" % (name, server["integrity"]))
    return servers


def to_zip(data):
    """The tarball's files as a zip without its top folder: (zip bytes, files, bytes)."""
    out = io.BytesIO()
    files = 0
    total = 0
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar, \
            zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as archive:
        for member in tar.getmembers():
            if member.isdir():
                continue
            if not member.isfile():
                raise Refused("not a regular file (a link or a device): %s" % member.name)
            parts = member.name.split("/")
            inside = parts[1:]
            if len(parts) < 2 or parts[0] in ("", ".", "..") or any(p in ("", ".", "..") for p in inside):
                raise Refused("a path outside the package: %s" % member.name)
            relative = "/".join(inside)
            body = tar.extractfile(member).read()
            if relative.lower().endswith(NATIVE_SUFFIXES) or body[:4] == b"\x7fELF":
                raise Refused("native code: %s" % relative)
            archive.writestr(relative, body)
            files += 1
            total += len(body)
    if files == 0:
        raise Refused("an empty package")
    return out.getvalue(), files, total


def download(url, integrity, cache):
    """The tarball at url, checked against integrity, from cache when it holds it."""
    cached = None
    if cache:
        cached = os.path.join(cache, hashlib.sha256(integrity.encode("ascii")).hexdigest() + ".tgz")
        if os.path.isfile(cached):
            with open(cached, "rb") as handle:
                data = handle.read()
            try:
                check_integrity(data, integrity)
                return data
            except Refused:
                os.remove(cached)
    failure = None
    data = None
    for attempt in range(4):
        try:
            with urllib.request.urlopen(url, timeout=120) as response:
                data = response.read(MAX_TARBALL_BYTES + 1)
            break
        except OSError as error:
            failure = error
            time.sleep(5 * (attempt + 1))
    if data is None:
        raise Refused("could not download %s: %s" % (url, failure))
    if len(data) > MAX_TARBALL_BYTES:
        raise Refused("%s is over %d bytes" % (url, MAX_TARBALL_BYTES))
    check_integrity(data, integrity)
    if cached:
        os.makedirs(cache, exist_ok=True)
        with open(cached, "wb") as handle:
            handle.write(data)
    return data


def fetch(pins_path, out, cache, get=download):
    """Writes every pinned server into out; returns the manifest's entries."""
    with open(pins_path, encoding="utf-8") as handle:
        servers = validate(json.load(handle))
    os.makedirs(out, exist_ok=True)
    entries = []
    for server in servers:
        name = server["name"]
        try:
            data = get(server["tarball"], server["integrity"], cache)
            archive, files, total = to_zip(data)
        except Refused as refused:
            raise Refused("%s@%s: %s" % (name, server["version"], refused))
        with open(os.path.join(out, name + ".zip"), "wb") as handle:
            handle.write(archive)
        entry = {
            "name": name,
            "version": server["version"],
            "integrity": server["integrity"],
            "license": server.get("license"),
            "files": files,
            "bytes": total,
            "zip_bytes": len(archive),
        }
        entries.append(entry)
        print("%s@%s: integrity ok, no native code, %d files, %d bytes, %d in its zip"
              % (name, server["version"], files, total, len(archive)))
    with open(os.path.join(out, "servers.json"), "w", encoding="utf-8") as handle:
        json.dump({"schema": 1, "servers": entries}, handle, indent=2)
        handle.write("\n")
    return entries


def _tarball(files, links=()):
    """A gzipped tarball of {path: bytes}, plus symbolic links (path, target)."""
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w:gz") as tar:
        for path, body in files.items():
            info = tarfile.TarInfo(path)
            info.size = len(body)
            tar.addfile(info, io.BytesIO(body))
        for path, target in links:
            info = tarfile.TarInfo(path)
            info.type = tarfile.SYMTYPE
            info.linkname = target
            tar.addfile(info)
    return raw.getvalue()


def _integrity(data):
    return "sha512-" + base64.b64encode(hashlib.sha512(data).digest()).decode("ascii")


def self_test():
    failed = 0

    def check(name, condition, shown=""):
        nonlocal failed
        failed += not condition
        print("self-test %-6s %s%s" % ("ok" if condition else "FAILED", name,
                                       (": %s" % (shown,)) if shown else ""))

    def refusal(action):
        try:
            action()
        except Refused as refused:
            return str(refused)
        return None

    good = _tarball({"package/package.json": b'{"name": "x"}', "package/lib/server.js": b"console.log(1)\n"})
    archive, files, total = to_zip(good)
    names = sorted(zipfile.ZipFile(io.BytesIO(archive)).namelist())
    check("a package becomes a zip without its top folder", names == ["lib/server.js", "package.json"], names)
    check("its files and bytes are counted", files == 2 and total == 28, (files, total))
    check("a matching integrity passes", refusal(lambda: check_integrity(good, _integrity(good))) is None)
    check("a changed byte fails the integrity",
          "integrity mismatch" in (refusal(lambda: check_integrity(good + b"!", _integrity(good))) or ""))
    check("an unknown hash algorithm is refused",
          "unsupported" in (refusal(lambda: check_integrity(good, "md5-AAAA")) or ""))
    elf = _tarball({"package/bin/tool": b"\x7fELF\x02\x01\x01" + b"\0" * 32})
    check("an ELF anywhere is refused", "native code" in (refusal(lambda: to_zip(elf)) or ""))
    addon = _tarball({"package/build/Release/addon.node": b"not really"})
    check("a .node file is refused, whatever it holds", "native code" in (refusal(lambda: to_zip(addon)) or ""))
    escape = _tarball({"package/../evil.js": b"x"})
    check("a path outside the package is refused", "outside" in (refusal(lambda: to_zip(escape)) or ""))
    linked = _tarball({"package/a.js": b"x"}, links=[("package/b.js", "/etc/passwd")])
    check("a link is refused", "not a regular file" in (refusal(lambda: to_zip(linked)) or ""))
    check("a tarball off the npm registry is refused", "not on the npm registry" in (refusal(lambda: validate(
        {"schema": 1, "servers": [{"name": "x", "version": "1", "tarball": "https://example.com/x.tgz",
                                   "integrity": _integrity(good)}]})) or ""))
    check("a server pinned twice is refused", "twice" in (refusal(lambda: validate(
        {"schema": 1, "servers": [{"name": "x", "version": "1", "tarball": REGISTRY + "x/-/x-1.tgz",
                                   "integrity": _integrity(good)}] * 2})) or ""))
    with open(DEFAULT_PINS, encoding="utf-8") as handle:
        pinned = validate(json.load(handle))
    check("the committed pins are well formed, and name the three candidates",
          [s["name"] for s in pinned] == ["pyright", "typescript", "typescript-language-server"],
          [s["name"] for s in pinned])
    with tempfile.TemporaryDirectory() as work:
        pins = os.path.join(work, "pins.json")
        with open(pins, "w", encoding="utf-8") as handle:
            json.dump({"schema": 1, "servers": [{"name": "x", "version": "1", "license": "MIT",
                                                 "tarball": REGISTRY + "x/-/x-1.tgz",
                                                 "integrity": _integrity(good)}]}, handle)
        out = os.path.join(work, "out")

        def served(url, integrity, cache):
            check_integrity(good, integrity)
            return good

        entries = fetch(pins, out, None, get=served)
        with open(os.path.join(out, "servers.json"), encoding="utf-8") as handle:
            manifest = json.load(handle)
        check("fetch writes the zip and a manifest with the counts",
              os.path.isfile(os.path.join(out, "x.zip")) and manifest["servers"] == entries
              and entries[0]["files"] == 2, manifest)

        def tampered(url, integrity, cache):
            check_integrity(good + b"!", integrity)
            return good

        reason = refusal(lambda: fetch(pins, out, None, get=tampered)) or ""
        check("a refusal names the package and its version", reason.startswith("x@1: integrity mismatch"), reason)
    print("self-test: %d failed" % failed)
    return 1 if failed else 0


def main(argv):
    if argv == ["--self-test"]:
        return self_test()
    args = {"--pins": None, "--out": None, "--cache": None}
    index = 0
    while index < len(argv):
        key = argv[index]
        if key not in args or index + 1 >= len(argv):
            print(__doc__, file=sys.stderr)
            return 2
        args[key] = argv[index + 1]
        index += 2
    if not args["--pins"] or not args["--out"]:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        entries = fetch(args["--pins"], args["--out"], args["--cache"])
    except (Refused, OSError, ValueError, tarfile.TarError, zipfile.BadZipFile) as failure:
        print("refused: %s" % failure, file=sys.stderr)
        return 1
    print("%d servers in %s" % (len(entries), args["--out"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
