#!/usr/bin/env python3
"""The language servers CodeForge ships (Phase 6 W2; docs/adr/0015-language-servers.md).

CodeForge's own. runtime/language-servers/ holds the pins:
  package.json       the servers' npm packages at exact versions, and under
                     "codeforge.servers" what makes up each server: its id,
                     its languages, its packages, the file node runs and its
                     arguments;
  package-lock.json  npm's lockfile (version 3): every package with its
                     tarball on the npm registry and its SHA-512 integrity;
  bundled.json       the packages each shipped package carries inside its own
                     JavaScript, read from its source maps (pnpm's store paths
                     give the versions), each with its tarball and integrity
                     from the registry. The notices need their licence texts,
                     which the shipped packages don't carry.

Commands:
  check    offline: the pins' shape and this file's rules. Every dependency
           exact; every package on the npm registry with a SHA-512 integrity
           and a licence on the allowlist; nothing that ships has an install
           script (an optional package, which never ships, may); every
           package belongs to one server.
  fetch    the shipped packages' tarballs into --cache, each verified against
           its integrity; --bundled fetches the bundled packages' too.
  build    each server into --out: lsp/<id>.zip and lsp/<id>-manifest.txt
           (sha256, size and path of every file, the sealed manifest's
           format, which the app's installer verifies), and lsp/servers.json.
           A package holding native code (a .node, .so, .dylib, .dll or .exe
           file, or an ELF, Mach-O or PE image), a link, a path outside the
           package, or a path the installer would refuse fails the build, as
           does a source map naming a bundled package bundled.json lacks.
  notices  THIRD_PARTY_NOTICES.md's language-server section and
           app/assets/licenses/language-servers.txt, from the tarballs'
           licence files; --check reports them stale instead.
  lock     re-pin: npm writes the lockfile from package.json (npm is needed
           for this one command), then bundled.json is written from the
           source maps and the registry. CI runs it for a [repin] commit.

The archives are reproducible: entries sorted, fixed timestamps, deflated.

Usage: language_servers.py check | fetch [--bundled] | build --out DIR |
       notices [--check] | lock   [--cache DIR] [--pins DIR]
Exit codes: 0 done, 1 refused or stale, 2 usage.
"""

import base64
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import time
import urllib.parse
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DEFAULT_PINS = os.path.join(HERE, "language-servers")
DEFAULT_CACHE = os.path.join(HERE, "generated", "lsp-cache")
NOTICES = os.path.join(REPO, "THIRD_PARTY_NOTICES.md")
APP_LICENSES = os.path.join(REPO, "app", "assets", "licenses", "language-servers.txt")
REGISTRY = "https://registry.npmjs.org/"
USER_AGENT = "codeforge-build"

# The licences a language server's packages may carry, as SPDX identifiers.
# Anything else fails `check`: the owner's licence review decides first.
ALLOWED_LICENSES = (
    "0BSD", "Apache-2.0", "BlueOak-1.0.0", "BSD-2-Clause", "BSD-3-Clause", "ISC", "MIT",
)
NATIVE_SUFFIXES = (".node", ".so", ".dylib", ".dll", ".exe")
EXACT_VERSION = re.compile(r"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$")
SERVER_ID = re.compile(r"^[a-z][a-z0-9-]*$")
LICENSE_FILE = re.compile(
    r"^(?:licen[cs]e|copying|notice|third[-_ ]?party[-_ ]?notices?(?:[-_ ]?text)?)(?:[.-][^/]*)?$",
    re.IGNORECASE)
CODE_SUFFIXES = (".js", ".mjs", ".cjs", ".ts", ".map", ".json")
# pnpm's store, in a source map's paths: .pnpm/<name>@<version>[_peers]/node_modules/<name>/
PNPM = re.compile(r"\.pnpm/([^/]+)/node_modules/((?:@[^/]+/)?[^/]+)/")
FIXED_TIME = (1980, 1, 1, 0, 0, 0)
MAX_TARBALL_BYTES = 64 * 1024 * 1024
BEGIN = "<!-- language-servers:begin -->"
END = "<!-- language-servers:end -->"
WRITTEN_BY = ("<!-- Written by runtime/language_servers.py from runtime/language-servers/. "
              "Do not edit by hand: CI checks it. -->")
# The line between the app file's entries: the same as runtime/notices.py's,
# so the app parses both files alike (app/lib/services/runtime/userland_licenses.dart).
ENTRY_SEPARATOR = "\u2500" * 72


class Refused(Exception):
    """The pins or a package break a rule; the message says which and why."""


# --- the pins ----------------------------------------------------------------

def load(pins_dir):
    """package.json, the lockfile and bundled.json, as parsed JSON."""
    def read(name):
        path = os.path.join(pins_dir, name)
        try:
            with open(path, encoding="utf-8") as handle:
                return json.load(handle)
        except FileNotFoundError:
            raise Refused("%s is missing" % path)
        except ValueError as error:
            raise Refused("%s is not JSON: %s" % (path, error))
    return read("package.json"), read("package-lock.json"), read("bundled.json")


def lock_digest(pins_dir):
    """The SHA-256 of the lockfile and bundled.json: the archives' and cache's key."""
    digest = hashlib.sha256()
    for name in ("package-lock.json", "bundled.json"):
        with open(os.path.join(pins_dir, name), "rb") as handle:
            digest.update(handle.read())
    return digest.hexdigest()


def package_name(path):
    """The package a lockfile path names: node_modules/a/node_modules/@b/c -> @b/c."""
    return path.rsplit("node_modules/", 1)[-1]


def servers_of(manifest):
    servers = (manifest.get("codeforge") or {}).get("servers")
    if not isinstance(servers, list) or not servers:
        raise Refused("package.json names no servers (codeforge.servers)")
    return servers


def check(manifest, lockfile, bundled):
    """Every problem with the pins, as sentences; empty when they hold."""
    problems = []
    dependencies = manifest.get("dependencies") or {}
    if not dependencies:
        problems.append("package.json has no dependencies")
    for name, version in sorted(dependencies.items()):
        if not isinstance(version, str) or not EXACT_VERSION.match(version):
            problems.append("%s is not pinned to an exact version: %r" % (name, version))
    if manifest.get("devDependencies") or manifest.get("optionalDependencies"):
        problems.append("package.json may only have dependencies")

    try:
        servers = servers_of(manifest)
    except Refused as refused:
        problems.append(str(refused))
        servers = []
    ids = set()
    owned = {}
    for server in servers:
        sid = server.get("id")
        if not isinstance(sid, str) or not SERVER_ID.match(sid):
            problems.append("a server's id is not a lower-case name: %r" % (sid,))
            continue
        if sid in ids:
            problems.append("server %s is named twice" % sid)
        ids.add(sid)
        if not server.get("languages") or not all(isinstance(x, str) for x in server["languages"]):
            problems.append("server %s names no languages" % sid)
        packages = server.get("packages") or []
        if not packages:
            problems.append("server %s names no packages" % sid)
        for name in packages:
            if name not in dependencies:
                problems.append("server %s names %s, which package.json does not pin" % (sid, name))
            elif name in owned:
                problems.append("%s belongs to both %s and %s" % (name, owned[name], sid))
            else:
                owned[name] = sid
        entry = server.get("entry") or ""
        if not any(entry.startswith("node_modules/%s/" % name) for name in packages) or ".." in entry:
            problems.append("server %s's entry %r is not inside one of its packages" % (sid, entry))
        if not isinstance(server.get("arguments", []), list):
            problems.append("server %s's arguments are not a list" % sid)
    for name in sorted(set(dependencies) - set(owned)):
        problems.append("%s is pinned but belongs to no server" % name)

    if lockfile.get("lockfileVersion") != 3:
        problems.append("the lockfile is not version 3 (npm 7 or later writes it)")
    entries = lockfile.get("packages") or {}
    root = entries.get("") or {}
    if (root.get("dependencies") or {}) != dependencies:
        problems.append("the lockfile is stale: its dependencies differ from package.json's "
                        "(run `language_servers.py lock`)")
    for path, entry in sorted(entries.items()):
        if path == "":
            continue
        name = package_name(path)
        if not path.startswith("node_modules/"):
            problems.append("%s: a workspace or link, not a registry package" % path)
            continue
        if entry.get("link"):
            problems.append("%s: a link, not a registry package" % path)
            continue
        problems.extend(check_package(path, name, entry))
        if entry.get("dev"):
            problems.append("%s: a dev dependency in the lockfile" % path)
        if entry.get("hasInstallScript") and not entry.get("optional"):
            problems.append("%s: it has an install script, and it would ship" % path)
    for name in dependencies:
        if "node_modules/%s" % name not in entries:
            problems.append("the lockfile does not resolve %s" % name)

    if not isinstance(bundled, dict) or bundled.get("schema") != 1:
        problems.append("bundled.json is not schema 1")
        return problems
    shipped = {"%s@%s" % (package_name(p), e.get("version")) for p, e in entries.items()
               if p and not e.get("optional")}
    seen = set()
    for item in bundled.get("packages") or []:
        key = "%s@%s" % (item.get("name"), item.get("version"))
        if key in seen:
            problems.append("bundled.json lists %s twice" % key)
        seen.add(key)
        problems.extend(check_package("bundled " + key, item.get("name") or "", item, field="tarball"))
        carriers = item.get("in") or []
        if not carriers:
            problems.append("bundled.json: %s is in no shipped package" % key)
        for carrier in carriers:
            if carrier not in shipped:
                problems.append("bundled.json: %s is in %s, which does not ship" % (key, carrier))
    return problems


def check_package(label, name, entry, field="resolved"):
    problems = []
    version = entry.get("version") or ""
    url = entry.get(field) or ""
    if not EXACT_VERSION.match(version):
        problems.append("%s: no exact version" % label)
    if not url.startswith(REGISTRY):
        problems.append("%s: its tarball is not on the npm registry: %r" % (label, url))
    if not (entry.get("integrity") or "").startswith("sha512-"):
        problems.append("%s: no SHA-512 integrity" % label)
    licence = entry.get("license")
    if licence not in ALLOWED_LICENSES and not entry.get("optional"):
        problems.append("%s: licence %r is not on the allowlist (%s)"
                        % (label, licence, ", ".join(ALLOWED_LICENSES)))
    if not name:
        problems.append("%s: no name" % label)
    return problems


def shipped_packages(manifest, lockfile, server):
    """The lockfile entries a server ships: its packages and their dependencies,
    as node would resolve them from the lockfile's paths, optional ones left out."""
    entries = lockfile.get("packages") or {}
    chosen = {}
    pending = ["node_modules/%s" % name for name in server["packages"]]
    while pending:
        path = pending.pop()
        if path in chosen:
            continue
        entry = entries.get(path)
        if entry is None:
            raise Refused("the lockfile has no %s" % path)
        chosen[path] = entry
        for dependency in sorted(entry.get("dependencies") or {}):
            found = resolve(entries, path, dependency)
            if found is None:
                raise Refused("%s needs %s, which the lockfile does not resolve" % (path, dependency))
            if not entries[found].get("optional"):
                pending.append(found)
    return sorted(chosen.items())


def resolve(entries, path, dependency):
    """Node's lookup: path/node_modules/dep, then each parent's, then the root's."""
    base = path
    while True:
        candidate = "%s/node_modules/%s" % (base, dependency) if base else "node_modules/%s" % dependency
        if candidate in entries:
            return candidate
        if not base:
            return None
        cut = base.rfind("/node_modules/")
        base = base[:cut] if cut > 0 else ""


# --- tarballs ----------------------------------------------------------------

def check_integrity(data, integrity):
    algorithm, _, expected = integrity.partition("-")
    if algorithm != "sha512" or not expected:
        raise Refused("unsupported integrity %r" % integrity)
    actual = base64.b64encode(hashlib.sha512(data).digest()).decode("ascii")
    if actual != expected:
        raise Refused("integrity mismatch: the pins say %s, the tarball is sha512-%s" % (integrity, actual))


def cached_path(cache, integrity):
    return os.path.join(cache, hashlib.sha256(integrity.encode("ascii")).hexdigest() + ".tgz")


def fetch_one(url, integrity, cache, opener=None):
    """The tarball at url, verified, from the cache when it holds a good copy."""
    path = cached_path(cache, integrity)
    if os.path.isfile(path):
        with open(path, "rb") as handle:
            data = handle.read()
        try:
            check_integrity(data, integrity)
            return data
        except Refused:
            os.remove(path)
    opener = opener or _download
    data = opener(url)
    check_integrity(data, integrity)
    os.makedirs(cache, exist_ok=True)
    partial = path + ".part"
    with open(partial, "wb") as handle:
        handle.write(data)
    os.replace(partial, path)
    return data


def _download(url):
    failure = None
    for attempt in range(4):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(request, timeout=120) as response:
                data = response.read(MAX_TARBALL_BYTES + 1)
            if len(data) > MAX_TARBALL_BYTES:
                raise Refused("%s is over %d bytes" % (url, MAX_TARBALL_BYTES))
            return data
        except OSError as error:
            failure = error
            time.sleep(5 * (attempt + 1))
    raise Refused("could not download %s: %s" % (url, failure))


def read_package(data, label):
    """A tarball's files as {relative path: bytes}, without its top folder.
    Refuses links, devices and paths outside the package."""
    files = {}
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
        top = None
        for member in tar.getmembers():
            if member.isdir():
                continue
            if not member.isfile():
                raise Refused("%s: not a regular file (a link or a device): %s" % (label, member.name))
            parts = member.name.split("/")
            if len(parts) < 2 or any(p in ("", ".", "..") for p in parts):
                raise Refused("%s: a path outside the package: %s" % (label, member.name))
            if top is None:
                top = parts[0]
            elif parts[0] != top:
                raise Refused("%s: more than one top folder (%s, %s)" % (label, top, parts[0]))
            relative = "/".join(parts[1:])
            files[relative] = tar.extractfile(member).read()
    if not files:
        raise Refused("%s: an empty package" % label)
    return files


def native_reason(path, body):
    """Why a file is native code, or None."""
    lower = path.lower()
    if lower.endswith(NATIVE_SUFFIXES):
        return "a %s file" % lower[lower.rfind("."):]
    head = body[:4]
    if head == b"\x7fELF":
        return "an ELF image"
    if head in (b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe"):
        return "a Mach-O image"
    if body[:2] == b"MZ" and len(body) > 0x40:
        offset = int.from_bytes(body[0x3c:0x40], "little")
        if body[offset:offset + 4] == b"PE\0\0":
            return "a PE image"
    return None


def installer_refuses(path):
    """Why the app's installer (the kernel's RuntimeManifest.normalize, and its
    tab-separated manifest) would refuse or change this path, or None."""
    if ".." in path:
        return "it contains '..'"
    if any(c in path for c in "\t\n\r\\"):
        return "it contains a tab, a line break or a backslash"
    if path != path.strip() or path.startswith(("/", "./")):
        return "it starts or ends with a space, or is not relative"
    return None


def bundled_in(files, label):
    """{(name, version)} the package's source maps say it carries inside its JavaScript."""
    found = set()
    for path in sorted(files):
        if not path.endswith(".map"):
            continue
        try:
            sources = json.loads(files[path].decode("utf-8")).get("sources") or []
        except ValueError:
            raise Refused("%s: %s is not a source map" % (label, path))
        for source in sources:
            if "node_modules/" not in source:
                continue
            matches = list(PNPM.finditer(source))
            if not matches:
                raise Refused("%s: %s names bundled code without its version: %s" % (label, path, source))
            store, name = matches[-1].group(1), matches[-1].group(2)
            flat = name.replace("/", "+") + "@"
            if not store.startswith(flat):
                raise Refused("%s: %s: a pnpm store path that does not name %s: %s" % (label, path, name, store))
            version = store[len(flat):].split("_")[0].split("(")[0]
            found.add((name, version))
    return found


def licence_files(files):
    """The package's licence and notice files, by path, with their text."""
    chosen = {}
    for path in sorted(files):
        base = path.rsplit("/", 1)[-1]
        if "node_modules/" in path or not LICENSE_FILE.match(base):
            continue
        if base.lower().endswith(CODE_SUFFIXES):
            continue
        chosen[path] = files[path].decode("utf-8", errors="replace")
    return chosen


# --- build -------------------------------------------------------------------

def build(pins_dir, cache, out, fetch=fetch_one):
    """Writes lsp/<id>.zip, lsp/<id>-manifest.txt and lsp/servers.json into out."""
    manifest, lockfile, bundled = load(pins_dir)
    problems = check(manifest, lockfile, bundled)
    if problems:
        raise Refused("the pins do not hold: " + "; ".join(problems))
    expected_bundled = {}
    for item in bundled.get("packages") or []:
        for carrier in item["in"]:
            expected_bundled.setdefault(carrier, set()).add((item["name"], item["version"]))
    target = os.path.join(out, "lsp")
    os.makedirs(target, exist_ok=True)
    described = []
    for server in servers_of(manifest):
        sid = server["id"]
        tree = {}
        packages = []
        for path, entry in shipped_packages(manifest, lockfile, server):
            name = package_name(path)
            label = "%s@%s" % (name, entry["version"])
            data = fetch(entry["resolved"], entry["integrity"], cache)
            files = read_package(data, label)
            found = bundled_in(files, label)
            if found != expected_bundled.get(label, set()):
                missing = sorted("%s@%s" % p for p in found - expected_bundled.get(label, set()))
                extra = sorted("%s@%s" % p for p in expected_bundled.get(label, set()) - found)
                raise Refused("%s: bundled.json is stale (its source maps add %s and drop %s; "
                              "run `language_servers.py lock`)" % (label, missing or "nothing", extra or "nothing"))
            for relative, body in files.items():
                reason = native_reason(relative, body)
                if reason:
                    raise Refused("%s: native code: %s is %s" % (label, relative, reason))
                full = "%s/%s" % (path, relative)
                refused = installer_refuses(full)
                if refused:
                    raise Refused("%s: the installer would refuse %s: %s" % (label, full, refused))
                tree[full] = body
            packages.append({"name": name, "version": entry["version"], "license": entry["license"]})
        if server["entry"] not in tree:
            raise Refused("server %s: its entry %s is not in its packages" % (sid, server["entry"]))
        archive = os.path.join(target, "%s.zip" % sid)
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as handle:
            for path in sorted(tree):
                info = zipfile.ZipInfo(path, FIXED_TIME)
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o644 << 16
                handle.writestr(info, tree[path])
        lines = ["# sha256\tsize\tpath within the server's folder"]
        lines += ["%s\t%d\t%s" % (hashlib.sha256(tree[p]).hexdigest(), len(tree[p]), p) for p in sorted(tree)]
        text = "\n".join(lines) + "\n"
        with open(os.path.join(target, "%s-manifest.txt" % sid), "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
        size = os.path.getsize(archive)
        described.append({
            "id": sid,
            "languages": server["languages"],
            "entry": server["entry"],
            "arguments": server.get("arguments", []),
            "packages": packages,
            "archive": "lsp/%s.zip" % sid,
            "manifest": "lsp/%s-manifest.txt" % sid,
            "identity": hashlib.sha256(text.encode("utf-8")).hexdigest(),
            "files": len(tree),
            "bytes": sum(len(b) for b in tree.values()),
            "archiveBytes": size,
        })
        print("server %s: %d packages, %d files, %d bytes, %d in its archive"
              % (sid, len(packages), len(tree), described[-1]["bytes"], size))
    with open(os.path.join(target, "servers.json"), "w", encoding="utf-8", newline="\n") as handle:
        json.dump({"schema": 1, "pins": lock_digest(pins_dir), "servers": described}, handle, indent=2)
        handle.write("\n")
    return described


# --- notices -----------------------------------------------------------------

def gather(pins_dir, cache, fetch=fetch_one):
    """Every package that ships, shipped or bundled, with its licence files."""
    manifest, lockfile, bundled = load(pins_dir)
    problems = check(manifest, lockfile, bundled)
    if problems:
        raise Refused("the pins do not hold: " + "; ".join(problems))
    rows = []
    server_of = {}
    for server in servers_of(manifest):
        for path, entry in shipped_packages(manifest, lockfile, server):
            label = "%s@%s" % (package_name(path), entry["version"])
            server_of[label] = server["id"]
            files = read_package(fetch(entry["resolved"], entry["integrity"], cache), label)
            rows.append({"name": package_name(path), "version": entry["version"], "license": entry["license"],
                         "server": server["id"], "bundled_in": None, "texts": licence_files(files)})
    for item in sorted(bundled.get("packages") or [], key=lambda i: (i["name"], i["version"])):
        label = "%s@%s" % (item["name"], item["version"])
        files = read_package(fetch(item["tarball"], item["integrity"], cache), label)
        for carrier in item["in"]:
            rows.append({"name": item["name"], "version": item["version"], "license": item["license"],
                         "server": server_of[carrier], "bundled_in": carrier, "texts": licence_files(files)})
    return manifest, rows


def normalise(text):
    lines = [line.rstrip() for line in text.replace("\r\n", "\n").replace("\r", "\n").replace("\f", "").split("\n")]
    while lines and not lines[0]:
        lines.pop(0)
    while lines and not lines[-1]:
        lines.pop()
    return "\n".join(lines)


def render(manifest, rows):
    """(THIRD_PARTY_NOTICES.md's section, the app's file)."""
    names = {s["id"]: s for s in servers_of(manifest)}
    title = {"pyright": "Pyright", "typescript": "the TypeScript server"}
    shipped = [r for r in rows if r["bundled_in"] is None]
    inside = [r for r in rows if r["bundled_in"] is not None]
    counts = {}
    for row in rows:
        counts[row["license"]] = counts.get(row["license"], 0) + 1
    licences = ", ".join("%s %d" % (k, v) for k, v in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])))
    per_server = []
    for sid in names:
        own = [r for r in shipped if r["server"] == sid]
        carried = [r for r in inside if r["server"] == sid]
        per_server.append("%s: %s, with %d bundled inside" % (
            title.get(sid, sid), " and ".join("`%s` %s" % (r["name"], r["version"]) for r in own), len(carried)))
    lines = [BEGIN, WRITTEN_BY, "",
             "**%d package versions** ship in the language servers: %d as their own files and %d bundled "
             "inside their JavaScript. %s. Licences, counted per package version: %s." % (
                 len(rows), len(shipped), len(inside), "; ".join(per_server), licences),
             "",
             "| Package | Version | Licence | Server | Ships | Licence text |",
             "|---|---|---|---|---|---|"]
    without = []
    for row in sorted(rows, key=lambda r: (r["bundled_in"] is not None, r["name"], r["version"], r["bundled_in"] or "")):
        ships = "its own files" if row["bundled_in"] is None else "bundled in `%s`" % row["bundled_in"]
        if row["texts"]:
            text = ", ".join("`%s`" % p for p in row["texts"])
        else:
            text = "none in its package"
            without.append("%s@%s" % (row["name"], row["version"]))
        lines.append("| %s | %s | %s | %s | %s | %s |" % (
            row["name"], row["version"], row["license"], title.get(row["server"], row["server"]), ships, text))
    lines.append("")
    if without:
        lines.append("**Without a licence text in their package** (%d): %s. Their package.json names the licence; "
                     "the text is for the licence review." % (len(without), ", ".join(without)))
        lines.append("")
    lines.append(END)
    section = "\n".join(lines)

    groups = {}
    order = []
    for row in rows:
        for path, raw in row["texts"].items():
            text = normalise(raw)
            if ENTRY_SEPARATOR in text:
                raise Refused("%s@%s's %s holds the app file's separator" % (row["name"], row["version"], path))
            if text not in groups:
                groups[text] = {"packages": [], "files": []}
                order.append(text)
            label = "%s %s" % (row["name"], row["version"])
            if label not in groups[text]["packages"]:
                groups[text]["packages"].append(label)
            where = "%s@%s/%s" % (row["name"], row["version"], path)
            if row["bundled_in"]:
                where += " (bundled in %s)" % row["bundled_in"]
            if where not in groups[text]["files"]:
                groups[text]["files"].append(where)
    app = ["CodeForge's language servers: the licence texts their packages carry.", "",
           "Written by runtime/language_servers.py from runtime/language-servers/.",
           "Do not edit by hand: CI checks it.",
           "%d package versions, %d distinct texts." % (len(rows), len(order)), "",
           "Each entry names the packages (name and version) whose licence files hold",
           "the text, and where each file is, then gives the text, with its line",
           "endings, page breaks and trailing spaces normalised."]
    for text in order:
        app += [ENTRY_SEPARATOR, "Packages: " + ", ".join(groups[text]["packages"]),
                "Files: " + ", ".join(groups[text]["files"]), "", text]
    return section, "\n".join(app) + "\n"


def replace_section(document, section):
    start = document.find(BEGIN)
    end = document.find(END)
    if start < 0 or end < start:
        raise Refused("THIRD_PARTY_NOTICES.md has no %s ... %s section" % (BEGIN, END))
    return document[:start] + section + document[end + len(END):]


def notices(pins_dir, cache, check_only, notices_path=NOTICES, app_path=APP_LICENSES, fetch=fetch_one):
    manifest, rows = gather(pins_dir, cache, fetch)
    section, app = render(manifest, rows)
    with open(notices_path, encoding="utf-8") as handle:
        document = handle.read()
    updated = replace_section(document, section)
    current_app = None
    if os.path.isfile(app_path):
        with open(app_path, encoding="utf-8") as handle:
            current_app = handle.read()
    stale = []
    if updated != document:
        stale.append(notices_path)
    if current_app != app:
        stale.append(app_path)
    if check_only:
        return stale
    if updated != document:
        with open(notices_path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(updated)
    if current_app != app:
        os.makedirs(os.path.dirname(app_path), exist_ok=True)
        with open(app_path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(app)
    return stale


# --- lock --------------------------------------------------------------------

def registry_metadata(name, version):
    url = REGISTRY + urllib.parse.quote(name, safe="@") + "/" + version
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def lock(pins_dir, cache, run=subprocess.run, metadata=registry_metadata, fetch=fetch_one):
    """npm writes the lockfile; bundled.json is written from the source maps and the registry."""
    run(["npm", "install", "--package-lock-only", "--ignore-scripts", "--no-audit", "--no-fund"],
        cwd=pins_dir, check=True)
    with open(os.path.join(pins_dir, "package-lock.json"), encoding="utf-8") as handle:
        lockfile = json.load(handle)
    carried = {}
    for path, entry in sorted((lockfile.get("packages") or {}).items()):
        if not path or entry.get("optional"):
            continue
        label = "%s@%s" % (package_name(path), entry["version"])
        files = read_package(fetch(entry["resolved"], entry["integrity"], cache), label)
        for pair in bundled_in(files, label):
            carried.setdefault(pair, []).append(label)
    packages = []
    for (name, version), carriers in sorted(carried.items()):
        meta = metadata(name, version)
        licence = meta.get("license")
        if isinstance(licence, dict):
            licence = licence.get("type")
        packages.append({"name": name, "version": version, "license": licence,
                         "tarball": meta["dist"]["tarball"], "integrity": meta["dist"]["integrity"],
                         "in": sorted(carriers)})
    document = {
        "schema": 1,
        "note": "Written by runtime/language_servers.py lock: the packages each shipped package carries inside "
                "its own JavaScript, from its source maps, with their tarballs and integrity from the npm registry. "
                "The notices take their licence texts from these tarballs.",
        "packages": packages,
    }
    with open(os.path.join(pins_dir, "bundled.json"), "w", encoding="utf-8", newline="\n") as handle:
        json.dump(document, handle, indent=2)
        handle.write("\n")
    return document


# --- the command line --------------------------------------------------------

def main(argv):
    if not argv or argv[0] not in ("check", "fetch", "build", "notices", "lock"):
        print(__doc__, file=sys.stderr)
        return 2
    command, rest = argv[0], argv[1:]
    options = {"--cache": DEFAULT_CACHE, "--pins": DEFAULT_PINS, "--out": None}
    flags = set()
    index = 0
    while index < len(rest):
        key = rest[index]
        if key in ("--check", "--bundled"):
            flags.add(key)
            index += 1
        elif key in options and index + 1 < len(rest):
            options[key] = rest[index + 1]
            index += 2
        else:
            print(__doc__, file=sys.stderr)
            return 2
    pins, cache = options["--pins"], options["--cache"]
    try:
        if command == "check":
            problems = check(*load(pins))
            for problem in problems:
                print("problem: %s" % problem)
            print("language servers: %s" % ("%d problems" % len(problems) if problems else "the pins hold"))
            return 1 if problems else 0
        if command == "fetch":
            manifest, lockfile, bundled = load(pins)
            problems = check(manifest, lockfile, bundled)
            if problems:
                raise Refused("the pins do not hold: " + "; ".join(problems))
            count = 0
            for path, entry in sorted((lockfile.get("packages") or {}).items()):
                if path and not entry.get("optional"):
                    fetch_one(entry["resolved"], entry["integrity"], cache)
                    count += 1
            if "--bundled" in flags:
                for item in bundled.get("packages") or []:
                    fetch_one(item["tarball"], item["integrity"], cache)
                    count += 1
            print("fetched %d tarballs, each verified, into %s" % (count, cache))
            return 0
        if command == "build":
            if not options["--out"]:
                print(__doc__, file=sys.stderr)
                return 2
            build(pins, cache, options["--out"])
            return 0
        if command == "notices":
            stale = notices(pins, cache, "--check" in flags)
            if "--check" in flags:
                for path in stale:
                    print("stale: %s (run `python3 runtime/language_servers.py notices`)" % os.path.relpath(path, REPO))
                print("language-server notices: %s" % ("stale" if stale else "current"))
                return 1 if stale else 0
            print("language-server notices: %s" % ("rewritten" if stale else "already current"))
            return 0
        document = lock(pins, cache)
        print("locked; bundled.json lists %d bundled package versions" % len(document["packages"]))
        return 0
    except (Refused, OSError, ValueError, tarfile.TarError, zipfile.BadZipFile, subprocess.CalledProcessError) as failure:
        print("refused: %s" % failure, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
