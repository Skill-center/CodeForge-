#!/usr/bin/env python3
"""Pins every input of the sealed runtime, and fetches exactly what is pinned.

CodeForge's own (Phase 4 W2), not vendored. It imports t1's fetch-core-debs.py
for the index parsing, the dependency resolver and the downloads, and adds what
t1 left open: t1's fetcher takes whatever versions the repository lists today,
and Termux keeps only the latest versions, so the same commit could build a
different payload tomorrow, or none at all.

runtime/pins.json holds:

* the bootstrap for each architecture: its release, URL and SHA-256;
* the core set CodeForge asks for (t1's), and what resolving it gave: every
  package and dependency with its version, repository file, size and SHA-256,
  in install order, plus the bootstrap's own packages (version and
  dependencies, from its dpkg status).

The payload is the bootstrap with the pinned packages replacing the
bootstrap's copies (t1's "refresh"). A Termux subpackage depends on its
parent's exact version, so replacing a library can strand a bootstrap package
built against the old one (the bootstrap's curl needs its own libcurl).
`resolve` therefore adds every bootstrap package a replacement leaves unmet to
the request, and resolves again until the whole payload is consistent; those
packages are listed under `consistency`.

Commands:

  check      validate pins.json without a network: its shape and hashes, and
             that every dependency in the payload, the bootstrap's packages
             included, is met by the pinned set and the bootstrap, by version
             (t1's invariant 3);
  fetch      download exactly the pinned packages of one architecture into a
             cache, verify each against its pin, and give the payload builder
             a directory that holds only them (with t1's packages.json). A
             pinned file the repository no longer has fails closed, naming
             the package;
  bootstrap  the same for the pinned bootstrap zip;
  resolve    re-pin: resolve the core set against the live repository with
             t1's resolver and rewrite pins.json. Re-pinning is a deliberate
             commit: CI runs this for a commit whose message has [repin].

Usage:
    pins.py check
    pins.py fetch --arch x86_64 --cache runtime/generated/cache \\
        --out runtime/generated/debs/x86_64
    pins.py bootstrap --arch x86_64 --cache runtime/generated/cache \\
        --out runtime/generated/bootstrap
    pins.py resolve --cache runtime/generated/cache

Exit codes: 0 success, 1 the pins or the repository failed a check, 2 usage.
"""

import argparse
import datetime
import hashlib
import importlib.util
import json
import os
import re
import shutil
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_PINS = os.path.join(HERE, "pins.json")
SCHEMA = 2
# How many times `resolve` may widen the request to keep the payload consistent.
CONSISTENCY_ROUNDS = 10
# Termux's architecture names, and the Android ABI each one's payload is for.
ABIS = {"aarch64": "arm64-v8a", "x86_64": "x86_64"}
HEX64 = re.compile(r"^[0-9a-f]{64}$")
PACKAGE_NAME = re.compile(r"^[a-z0-9][a-z0-9+.-]*$")
USER_AGENT = "codeforge-build"
REPIN_HINT = ("Termux keeps only the latest versions. Re-pin deliberately: push "
              "a commit whose message has [repin] (CI runs `runtime/pins.py "
              "resolve` and commits the new pins back), then review the new "
              "versions before building on them.")


def _load_t1_fetcher():
    spec = importlib.util.spec_from_file_location(
        "fetch_core_debs", os.path.join(HERE, "fetch-core-debs.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


t1 = _load_t1_fetcher()


class PinError(Exception):
    """A pin, a pinned file or the repository failed a check (exit code 1)."""


def log(message):
    print(message, file=sys.stderr)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_pins(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def write_pins(path, pins):
    text = json.dumps(pins, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    temporary = path + ".part"
    with open(temporary, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.replace(temporary, path)


def write_atomically(path, data):
    temporary = path + ".part"
    with open(temporary, "wb") as handle:
        handle.write(data)
    os.replace(temporary, path)


def link_or_copy(source, target):
    if os.path.lexists(target):
        os.remove(target)
    try:
        os.link(source, target)
    except OSError:
        shutil.copy2(source, target)


def download(url):
    """The bytes at url, or None when the server says the file is gone.

    A 404 or 410 is an answer, not a hiccup, so it is not retried; anything
    else goes through t1's fetch, which retries a flaky mirror.
    """
    if url.startswith("file://"):
        path = urllib.request.url2pathname(urllib.parse.urlparse(url).path)
        if not os.path.isfile(path):
            return None
        with open(path, "rb") as handle:
            return handle.read()
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        if error.code in (404, 410):
            return None
    except Exception:                                  # retried below
        pass
    try:
        return t1.fetch(url)
    except urllib.error.HTTPError as error:
        if error.code in (404, 410):
            return None
        raise PinError("HTTP %d for %s" % (error.code, url))
    except Exception as error:
        raise PinError("could not download %s: %s" % (url, error))


# --------------------------------------------------------------------------- #
# check
# --------------------------------------------------------------------------- #

def split_provides(value):
    names = []
    for item in (value or "").split(","):
        item = re.sub(r"\([^)]*\)", "", item).strip()
        if item:
            names.append(item)
    return names


def describe(alternative):
    name, operator, required = alternative
    return "%s (%s %s)" % (name, operator, required) if operator else name


def unmet_dependencies(bootstrap, pinned):
    """Every dependency the payload does not meet.

    bootstrap and pinned map a name to {version, depends, preDepends,
    provides}. The payload is the bootstrap with the pinned packages
    replacing its copies. Returns (origin, name, version, field label,
    alternatives) tuples, origin being "bootstrap" or "pinned".
    """
    composed = {name: ("bootstrap", entry) for name, entry in bootstrap.items()}
    composed.update({name: ("pinned", entry) for name, entry in pinned.items()})
    versions = {name: entry.get("version", "") for name, (_, entry) in composed.items()}
    virtual = set()
    for _, entry in composed.values():
        virtual.update(split_provides(entry.get("provides", "")))

    def met(alternative):
        name, operator, required = alternative
        if name in t1.ALWAYS_SKIP:
            return True
        if name in versions:
            return t1.satisfies(versions[name], operator, required)
        return name in virtual

    unmet = []
    for name, (origin, entry) in sorted(composed.items()):
        for field, label in (("preDepends", "Pre-Depends"), ("depends", "Depends")):
            for alternatives in t1.split_dependencies(entry.get(field, "")):
                if not any(met(alternative) for alternative in alternatives):
                    unmet.append((origin, name, entry.get("version", ""), label, alternatives))
    return unmet


def describe_unmet(arch, item):
    origin, name, version, label, alternatives = item
    who = "%s %s" % (arch, name) if origin == "pinned" else \
        "%s bootstrap's %s %s" % (arch, name, version)
    return ("%s: %s on %s is not met by the pinned set or the bootstrap"
            % (who, label, " | ".join(describe(a) for a in alternatives)))


def check_inputs(pins):
    """Problems with what a human writes: the repository, bootstrap, core set."""
    problems = []
    if pins.get("schema") != SCHEMA:
        problems.append("schema is %r; this tool reads %d" % (pins.get("schema"), SCHEMA))
    repository = pins.get("repository") or {}
    # file:// serves the tests' synthetic repositories; the committed pins use
    # https (test-pins.py checks that).
    if not str(repository.get("url", "")).startswith(("https://", "file://")):
        problems.append("repository.url must be an https URL")
    if not repository.get("suite"):
        problems.append("repository.suite is missing")
    bootstrap = pins.get("bootstrap") or {}
    if not bootstrap.get("version"):
        problems.append("bootstrap.version is missing")
    files = bootstrap.get("files") or {}
    if sorted(files) != sorted(ABIS):
        problems.append("bootstrap.files must pin exactly %s (it pins %s)"
                        % (", ".join(sorted(ABIS)), ", ".join(sorted(files)) or "none"))
    for arch, entry in sorted(files.items()):
        if not str(entry.get("url", "")).startswith(("https://", "file://")):
            problems.append("bootstrap.files.%s.url must be an https URL" % arch)
        if not HEX64.match(str(entry.get("sha256", ""))):
            problems.append("bootstrap.files.%s.sha256 is not 64 lowercase hex digits" % arch)
    requested = pins.get("requested") or []
    if not requested:
        problems.append("requested is empty")
    for name in requested:
        if not PACKAGE_NAME.match(str(name)):
            problems.append("requested name %r is not a package name" % (name,))
    if len(set(requested)) != len(requested):
        problems.append("requested names a package twice")
    return problems


def check_resolved(pins):
    """Problems with what `resolve` writes: the pinned set, arch by arch."""
    problems = []
    requested = pins.get("requested") or []
    packages = pins.get("packages") or {}
    bootstrap_packages = (pins.get("bootstrap") or {}).get("packages") or {}
    if not pins.get("resolvedAt"):
        problems.append("resolvedAt is missing: the pins were never resolved "
                        "(push a [repin] commit)")
    for arch in sorted(ABIS):
        entries = packages.get(arch) or []
        if not entries:
            problems.append("no packages are pinned for %s: resolve them with a "
                            "[repin] commit (runtime/pins.py resolve)" % arch)
            continue
        base = bootstrap_packages.get(arch)
        if not base:
            problems.append("bootstrap.packages.%s is missing (resolve writes it "
                            "from the bootstrap's dpkg status)" % arch)
            base = {}
        malformed = sorted(name for name, entry in base.items()
                           if not isinstance(entry, dict) or not entry.get("version"))
        if malformed:
            problems.append("bootstrap.packages.%s: %s need a version (and their "
                            "dependencies); re-pin" % (arch, ", ".join(malformed[:5])))
            base = {name: entry for name, entry in base.items() if name not in malformed}
        pinned = {}
        for index, entry in enumerate(entries):
            name = entry.get("package")
            if not PACKAGE_NAME.match(str(name)):
                problems.append("%s package #%d has no valid name" % (arch, index + 1))
                continue
            label = "%s %s" % (arch, name)
            if name in pinned:
                problems.append("%s is pinned twice" % label)
            pinned[name] = entry
            if not entry.get("version"):
                problems.append("%s has no version" % label)
            filename = str(entry.get("filename", ""))
            if (not filename.endswith(".deb")
                    or not os.path.basename(filename).startswith(name + "_")):
                problems.append("%s: filename %r is not a .deb of that package"
                                % (label, filename))
            if filename.startswith("/") or ".." in filename.split("/"):
                problems.append("%s: filename %r must be repository-relative"
                                % (label, filename))
            if not HEX64.match(str(entry.get("sha256", ""))):
                problems.append("%s: sha256 is not 64 lowercase hex digits" % label)
            size = entry.get("size")
            if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
                problems.append("%s: size must be a positive integer" % label)
        for name in requested:
            if name not in pinned and name not in base:
                problems.append("%s: requested %s is neither pinned nor in the bootstrap"
                                % (arch, name))
        # The payload: the bootstrap, with pinned packages replacing the
        # bootstrap's copies (t1's "refresh"). Every dependency in it, the
        # bootstrap's own included, must be met.
        for item in unmet_dependencies(base, pinned):
            problems.append(describe_unmet(arch, item))
        for name in (pins.get("consistency") or {}).get(arch) or []:
            if name not in pinned:
                problems.append("%s: consistency lists %s, which is not pinned" % (arch, name))
    return problems


def check(pins):
    return check_inputs(pins) + check_resolved(pins)


def summary(pins):
    parts = []
    for arch in sorted(ABIS):
        count = len((pins.get("packages") or {}).get(arch) or [])
        extra = len((pins.get("consistency") or {}).get(arch) or [])
        parts.append("%d for %s (%d for consistency)" % (count, arch, extra))
    return ("pins: OK - %s on bootstrap %s; resolved %s"
            % (", ".join(parts), pins["bootstrap"]["version"], pins.get("resolvedAt", "never")))


# --------------------------------------------------------------------------- #
# bootstrap / fetch
# --------------------------------------------------------------------------- #

def fetch_bootstrap(pins, arch, cache, out=None):
    """The pinned bootstrap zip for arch, verified, from the cache or its URL."""
    entry = pins["bootstrap"]["files"][arch]
    directory = os.path.join(cache, "bootstrap")
    os.makedirs(directory, exist_ok=True)
    cached = os.path.join(directory, "bootstrap-%s.zip" % arch)
    if os.path.isfile(cached) and sha256_file(cached) == entry["sha256"]:
        log("bootstrap %-8s from the cache" % arch)
    else:
        log("bootstrap %-8s %s" % (arch, entry["url"]))
        data = download(entry["url"])
        if data is None:
            raise PinError("the pinned bootstrap for %s (%s) is gone: %s"
                           % (arch, pins["bootstrap"]["version"], entry["url"]))
        digest = hashlib.sha256(data).hexdigest()
        if digest != entry["sha256"]:
            raise PinError("the bootstrap for %s does not match its pin\n  pinned: %s\n  served: %s"
                           % (arch, entry["sha256"], digest))
        write_atomically(cached, data)
    if out:
        os.makedirs(out, exist_ok=True)
        link_or_copy(cached, os.path.join(out, "bootstrap-%s.zip" % arch))
    return cached


def repository_versions(pins, arch, names):
    """What the live index lists now for names (best effort, for the message)."""
    repository = pins["repository"]
    try:
        index, _ = t1.load_index(repository["url"], repository["suite"], arch)
    except (Exception, SystemExit) as error:          # t1 exits when no index loads
        log("(the index could not be read for the report: %s)" % error)
        return {}
    return {name: (index.get(name) or {}).get("Version") for name in names}


def fetch(pins, arch, cache, out):
    """Exactly the pinned packages of arch into out, each verified; fails closed."""
    problems = check(pins)
    if problems:
        raise PinError("the pins do not pass `pins.py check`:\n  " + "\n  ".join(problems))
    repository = pins["repository"]
    base_url = repository["url"].rstrip("/")
    entries = pins["packages"][arch]
    directory = os.path.join(cache, "debs", arch)
    os.makedirs(directory, exist_ok=True)
    located, gone, different = [], [], []
    from_cache = 0
    for entry in entries:
        cached = os.path.join(directory, os.path.basename(entry["filename"]))
        if os.path.isfile(cached) and sha256_file(cached) == entry["sha256"]:
            located.append((entry, cached))
            from_cache += 1
            continue
        url = "%s/%s" % (base_url, entry["filename"].lstrip("/"))
        log("fetch %-24s %-26s %s" % (entry["package"], entry["version"],
                                      os.path.basename(entry["filename"])))
        try:
            data = download(url)
        except PinError as error:
            raise PinError("%s %s (%s): %s" % (entry["package"], entry["version"], arch, error))
        if data is None:
            gone.append(entry)
            continue
        digest = hashlib.sha256(data).hexdigest()
        if digest != entry["sha256"]:
            different.append((entry, digest))
            continue
        write_atomically(cached, data)
        located.append((entry, cached))
    if gone or different:
        lines = []
        now = repository_versions(pins, arch, [entry["package"] for entry in gone]) if gone else {}
        for entry in gone:
            current = now.get(entry["package"])
            lines.append("pinned package %s %s (%s) is no longer in the repository: %s%s"
                         % (entry["package"], entry["version"], arch, entry["filename"],
                            "; the index now lists %s" % current if current else ""))
        for entry, digest in different:
            lines.append("pinned package %s %s (%s): the repository serves different bytes\n"
                         "    pinned: %s\n    served: %s"
                         % (entry["package"], entry["version"], arch, entry["sha256"], digest))
        lines.append(REPIN_HINT)
        raise PinError("\n".join(lines))

    os.makedirs(out, exist_ok=True)
    for name in os.listdir(out):
        if name.endswith(".deb") or name == "packages.json":
            os.remove(os.path.join(out, name))
    manifest = []
    for entry, cached in located:
        filename = os.path.basename(cached)
        link_or_copy(cached, os.path.join(out, filename))
        manifest.append({
            "package": entry["package"],
            "version": entry["version"],
            "file": filename,
            "sha256": entry["sha256"],
            "installedSize": entry.get("installedSize", "0"),
        })
    # t1's packages.json, so build-sealed-payload.py reads it unchanged.
    with open(os.path.join(out, "packages.json"), "w", encoding="utf-8") as handle:
        json.dump({"arch": arch, "repo": repository["url"], "suite": repository["suite"],
                   "packages": manifest}, handle, indent=2, sort_keys=True)
    total = sum(entry["size"] for entry in entries)
    print("fetched %d pinned packages for %s (%d from the cache, %.1f MB)"
          % (len(located), arch, from_cache, total / 1e6))
    return manifest


# --------------------------------------------------------------------------- #
# resolve (re-pin)
# --------------------------------------------------------------------------- #

def bootstrap_status(zip_path):
    """name -> {version, depends, preDepends, provides}, from the bootstrap's dpkg status."""
    with zipfile.ZipFile(zip_path) as archive:
        names = [name for name in archive.namelist() if name.endswith("var/lib/dpkg/status")]
        if not names:
            return {}
        text = archive.read(names[0]).decode("utf-8", "replace")
    status = {}
    for stanza in t1.parse_stanzas(text):
        name = stanza.get("Package")
        if name:
            status[name] = {"version": stanza.get("Version", ""),
                            "depends": stanza.get("Depends", ""),
                            "preDepends": stanza.get("Pre-Depends", ""),
                            "provides": stanza.get("Provides", "")}
    return status


def stanza_entry(stanza):
    return {"version": stanza.get("Version", ""), "depends": stanza.get("Depends", ""),
            "preDepends": stanza.get("Pre-Depends", ""), "provides": stanza.get("Provides", "")}


def resolve_consistently(arch, requested, index, provided, status, base):
    """t1's resolution, widened until the whole payload's dependencies are met.

    Replacing a bootstrap package can strand another bootstrap package built
    against it (a Termux subpackage depends on its parent's exact version).
    Each stranded package is added to the request, so t1's resolver takes it
    from the repository too, until nothing is stranded. Returns the install
    order and the names added. Fails closed when a stranded package cannot be
    taken from the repository.
    """
    request = list(requested)
    added = []
    for _ in range(CONSISTENCY_ROUNDS):
        order, missing = t1.resolve(request, index, provided, base, set(t1.ALWAYS_SKIP))
        if missing:
            raise PinError("%s: unresolved dependencies: %s"
                           % (arch, ", ".join(sorted(set(missing)))))
        pinned = {name: stanza_entry(index[name]) for name in order}
        unmet = unmet_dependencies(status, pinned)
        if not unmet:
            return order, added
        stranded = sorted({item[1] for item in unmet if item[0] == "bootstrap"})
        new = [name for name in stranded if name not in request]
        if not new:
            raise PinError("%s: the payload cannot be made consistent:\n  %s"
                           % (arch, "\n  ".join(describe_unmet(arch, item) for item in unmet)))
        log("%s: %s left behind by the refresh; resolving again with %s"
            % (arch, ", ".join(new), "them" if len(new) > 1 else "it"))
        request.extend(new)
        added.extend(new)
    raise PinError("%s: the payload was still inconsistent after %d rounds"
                   % (arch, CONSISTENCY_ROUNDS))

def resolve(pins, cache, now=None):
    """Re-pin: resolve the core set against the live repository, arch by arch."""
    problems = check_inputs(pins)
    if problems:
        raise PinError("the pins' inputs do not pass the check:\n  " + "\n  ".join(problems))
    repository = pins["repository"]
    packages, bootstrap_status_by_arch, consistency = {}, {}, {}
    for arch in sorted(ABIS):
        zip_path = fetch_bootstrap(pins, arch, cache)
        status = bootstrap_status(zip_path)
        if not status:
            raise PinError("the %s bootstrap has no var/lib/dpkg/status" % arch)
        base = {name: entry["version"] for name, entry in status.items()}
        try:
            index, provided = t1.load_index(repository["url"], repository["suite"], arch)
        except SystemExit as error:
            raise PinError(str(error))
        order, added = resolve_consistently(arch, pins["requested"], index, provided, status,
                                            base)
        directory = os.path.join(cache, "debs", arch)
        os.makedirs(directory, exist_ok=True)
        entries = []
        for name in order:
            stanza = index[name]
            try:
                path, version, digest = t1.download_deb(repository["url"], stanza,
                                                        directory, arch)
            except SystemExit as error:               # t1 exits on a hash mismatch
                raise PinError("%s %s: %s" % (arch, name, error))
            entries.append({
                "package": name,
                "version": version,
                "filename": stanza["Filename"],
                "sha256": digest,
                "size": int(stanza.get("Size") or os.path.getsize(path)),
                "installedSize": stanza.get("Installed-Size", "0"),
                "depends": stanza.get("Depends", ""),
                "preDepends": stanza.get("Pre-Depends", ""),
                "provides": stanza.get("Provides", ""),
            })
        packages[arch] = entries
        bootstrap_status_by_arch[arch] = dict(sorted(status.items()))
        consistency[arch] = added
        print("resolved %d packages for %s (the bootstrap provides %d; %d added for "
              "consistency%s)" % (len(entries), arch, len(base), len(added),
                                  ": " + ", ".join(added) if added else ""))
    resolved = json.loads(json.dumps(pins))
    resolved["packages"] = packages
    resolved["bootstrap"]["packages"] = bootstrap_status_by_arch
    resolved["consistency"] = consistency
    resolved["resolvedAt"] = now or datetime.datetime.now(datetime.timezone.utc) \
        .replace(microsecond=0).isoformat().replace("+00:00", "Z")
    problems = check(resolved)
    if problems:
        raise PinError("the resolved set does not pass the check:\n  " + "\n  ".join(problems))
    return resolved


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--pins", default=DEFAULT_PINS, help="default: runtime/pins.json")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="validate the pins offline")
    for name, text in (("fetch", "download exactly the pinned packages of one architecture"),
                       ("bootstrap", "download the pinned bootstrap of one architecture")):
        command = commands.add_parser(name, help=text)
        command.add_argument("--arch", required=True, choices=sorted(ABIS),
                             help="Termux architecture name (not the Android ABI name)")
        command.add_argument("--cache", required=True,
                             help="kept between builds (CI caches it under the pins' hash)")
        command.add_argument("--out", required=True)
    command = commands.add_parser("resolve", help="re-pin against the live repository")
    command.add_argument("--cache", required=True)
    arguments = parser.parse_args(argv)

    try:
        pins = read_pins(arguments.pins)
    except (OSError, ValueError) as error:
        log("pins: cannot read %s: %s" % (arguments.pins, error))
        return 1
    try:
        if arguments.command == "check":
            problems = check(pins)
            for problem in problems:
                log("pins: " + problem)
            if problems:
                log("pins: %d problem(s)" % len(problems))
                return 1
            print(summary(pins))
        elif arguments.command == "fetch":
            fetch(pins, arguments.arch, arguments.cache, arguments.out)
        elif arguments.command == "bootstrap":
            problems = check_inputs(pins)
            if problems:
                raise PinError("\n  ".join(["the pins' inputs do not pass the check:"] + problems))
            fetch_bootstrap(pins, arguments.arch, arguments.cache, arguments.out)
            print("bootstrap %s for %s verified" % (pins["bootstrap"]["version"], arguments.arch))
        elif arguments.command == "resolve":
            resolved = resolve(pins, arguments.cache)
            write_pins(arguments.pins, resolved)
            print("wrote %s" % arguments.pins)
            print(summary(resolved))
    except PinError as error:
        log("pins: %s" % error)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
