#!/usr/bin/env python3
"""Assembles the corresponding source of the userland's copyleft packages.

CodeForge's own (Phase 5 W1). SOURCE_OFFER.md promises, with every binary that
carries the userland, the source of each copyleft package version in it: the
upstream release Termux's recipe names, and Termux's recipe and patches at the
termux-packages commit that built that version, plus Termux's build scripts.
This script writes that archive, one tar, from:

* **the list:** SOURCE_OFFER.md's generated table (`<!-- copyleft:begin -->`),
  which runtime/notices.py writes from the pins and CI keeps current;
* **the recipes:** a clone of https://github.com/termux/termux-packages. A
  blobless one will do: the blobs needed are fetched in batches, and a
  commit-graph with changed-path filters is written if the clone has none;
* **the upstream files:** downloaded with curl from the recipe's own URLs
  or, when a host fails, from the same path on a mirror of it (MIRRORS),
  each verified against the recipe's SHA-256 and kept in a cache by it.

**Which commit built a version.** A pinned package was resolved from Termux's
repository at `resolvedAt` (runtime/pins.json); a package from the bootstrap
was built before the bootstrap's tag (`bootstrap-<version>`). Its recipe is the
newest commit at or before that point, among those that touched the package's
folder, whose `build.sh` gives the version by Termux's rule (`TERMUX_PKG_VERSION`,
then `-TERMUX_PKG_REVISION` when the revision is not 0 or the version holds a
`-`; scripts/build/termux_step_start_build.sh). A subpackage
(`<name>.subpackage.sh`) takes its parent's folder and version.

**What a recipe downloads.** `TERMUX_PKG_SRCURL` and `TERMUX_PKG_SHA256`
(arrays allowed), read by sourcing `build.sh` for each ABI in a bash whose PATH
holds only text filters (FILTERS: `sed` in GNU sed's sandbox, `tr`, `seq` for the
patch loops and the like), so the rest of a recipe's commands do nothing.
A `git+` URL is cloned as Termux's build clones it (TERMUX_PKG_GIT_BRANCH, else
`v<version>`; depth 1, with submodules) and recorded by its commit. Downloads
inside a build step (`termux_download` in a function) need a review, recorded
in STEP_DOWNLOADS: an upstream's own patches are source, and that step is run
the same way to read their URLs and SHA-256s; a download for the build machine
is left out, and the manifest says why. A download nobody reviewed fails the
archive.

**The build system.** At every recipe commit, and at the bootstrap's tag (whose
scripts, generate-bootstraps.sh among them, built the bootstrap):
termux-packages' `build-package.sh`, `scripts/` and `ndk-patches/`. A file
repeated from one commit to another is a hard link to its first copy.

It fails closed: a package whose recipe, version or source can't be found or
verified stops it, named, and nothing is written. The same inputs give the same
bytes.

Usage:
    sources.py plan  --termux <clone> [--json plan.json]
    sources.py build --termux <clone> --cache <dir> --out <file.tar> [--label <name>]

Run its tests: python3 runtime/tests/test-sources.py
"""

import argparse
import calendar
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DEFAULT_PINS = os.path.join(HERE, "pins.json")
DEFAULT_OFFER = os.path.join(ROOT, "SOURCE_OFFER.md")
OFFER_MARKERS = ("<!-- copyleft:begin -->", "<!-- copyleft:end -->")
TERMUX_REPOSITORY = "https://github.com/termux/termux-packages"
CODEFORGE_REPOSITORY = "https://github.com/Skill-center/CodeForge-"
RECIPE_TOPS = ("packages", "root-packages", "x11-packages")
BUILD_SYSTEM = ("build-package.sh", "scripts", "ndk-patches")
ARCHES = {"aarch64": "arm64-v8a", "x86_64": "x86_64"}
ARCH_BITS = {"aarch64": "64", "x86_64": "64", "arm": "32", "i686": "32"}
SHA256 = re.compile(r"^[0-9a-f]{64}$")
BATCHES = (4, 32, 128, 256)   # commits read at a time while walking a folder's history
# The only commands a recipe finds while it is read: text filters, which some recipes use
# to compute a URL (ca-certificates: `$(sed 's/\./-/g' <<< ...)`). Nothing that writes,
# fetches or runs anything else; sed runs with --sandbox, which rejects its e, r and w.
FILTERS = ("basename", "cut", "dirname", "expr", "grep", "head", "sed", "seq", "sort", "tail",
           "tr", "uniq")
DOWNLOAD_ATTEMPTS = 3
TIMEOUT = 300                 # seconds, per download attempt

# Hosts that serve the same files, by URL prefix (added after the first dry
# run, CI 44389009942, where mirrors.kernel.org never answered the runner; 36
# of the 69 upstream files name it). When a download fails, the same path is
# tried under the group's other prefixes, in order. A file counts only with
# the recipe's SHA-256, wherever it came from, and the manifest names the
# recipe's URL, so the archive is the same whichever host answered. A prefix
# that failed goes after the others for the rest of the run, so a host that
# is down costs its retries once.
MIRRORS = (
    # GNU's tree: kernel.org's copy, GNU's own server, and GNU's redirector to
    # a mirror near the client.
    ("https://mirrors.kernel.org/gnu/", "https://ftp.gnu.org/gnu/", "https://ftpmirror.gnu.org/"),
    # kernel.org's own files.
    ("https://mirrors.kernel.org/pub/", "https://www.kernel.org/pub/", "https://cdn.kernel.org/pub/",
     "https://mirrors.edge.kernel.org/pub/"),
    # Savannah's releases, and its main mirror.
    ("http://download.savannah.gnu.org/releases/", "https://download.savannah.gnu.org/releases/",
     "https://download-mirror.savannah.gnu.org/releases/"),
    # GnuPG's releases, and a mirror gnupg.org lists.
    ("https://www.gnupg.org/ftp/gcrypt/", "https://gnupg.org/ftp/gcrypt/",
     "https://mirrors.dotsrc.org/gcrypt/"),
    # nano's latest/ holds its newest release only (8.7.1 is pinned, and 9.3 was
    # the newest on 2026-11-18); every 8.x stays under v8/, and GNU has them.
    ("https://nano-editor.org/dist/latest/", "https://nano-editor.org/dist/v8/",
     "https://ftp.gnu.org/gnu/nano/"),
    # Thomas Dickey's archives, and their mirror.
    ("https://invisible-island.net/archives/", "https://invisible-mirror.net/archives/"),
    # fossies.org moves a superseded version to old/.
    ("https://fossies.org/linux/misc/", "https://fossies.org/linux/misc/old/"),
    # SourceForge's project pages, and its download host.
    ("https://sourceforge.net/projects/net-tools/files/",
     "https://downloads.sourceforge.net/project/net-tools/"),
    ("https://sourceforge.net/projects/procps-ng/files/",
     "https://downloads.sourceforge.net/project/procps-ng/"),
)
FAILED_MIRRORS = set()        # the prefixes a download failed from, in this run

# Downloads inside a recipe's build steps, reviewed in Phase 5 W1 (2026-11-18):
# (recipe folder, function) -> None if the files are source (they go into the
# archive), or the reason they are left out (they serve the build machine, not
# the binaries the payload ships). A download of the recipe's own
# TERMUX_PKG_SRCURL is the main source, and counts once.
STEP_DOWNLOADS = {
    ("bash", "termux_step_pre_configure"): None,         # bash's official patches
    ("readline", "termux_step_pre_configure"): None,     # readline's official patches
    ("libmpfr", "termux_step_post_get_source"): None,    # MPFR's official patches
    ("gnupg", "termux_step_host_build"):
        "libgpg-error's source, unpacked on the build machine to build the documentation "
        "tool yat2m; libgpg-error's own source is in this archive",
    ("ca-certificates", "termux_step_make_install"):
        "the certificate bundle, which is the recipe's own source (here), and keyutil, a Java "
        "tool that builds the keystore of the ca-certificates-java subpackage, which the "
        "payload does not carry",
    ("nodejs", "termux_step_host_build"):
        "ICU's source and Chromium's prebuilt clang, for the tools node's build runs on the "
        "build machine",
    ("nodejs", "termux_step_configure"):
        "Ubuntu's libffi8 package, for the build machine",
}

FUNCTION = re.compile(r"^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\)")
DOWNLOAD_CALL = re.compile(r"\btermux_download\w*\b")

EVALUATE = r'''
set +eu
exec 3>&1 1>/dev/null 2>&1
command_not_found_handle() { return 0; }
termux_download() { printf 'DOWNLOAD\t%s\t%s\0' "${1:-}" "${3:-}" >&3; }
termux_download_ubuntu_packages() { :; }
termux_error_exit() { exit 1; }
TERMUX_PKG_VERSION=""; TERMUX_PKG_REVISION="0"; TERMUX_PKG_SRCURL=""; TERMUX_PKG_SHA256=""
TERMUX_PKG_GIT_BRANCH=""; TERMUX_PKG_SKIP_SRC_EXTRACT="false"
TERMUX_PREFIX=/data/data/com.termux/files/usr; TERMUX_ARCH="$3"; TERMUX_ARCH_BITS="$4"
TERMUX_PKG_NAME="$2"; TERMUX_PKG_BUILDER_DIR="$5/recipe"; TERMUX_SCRIPTDIR="$5/root"
TERMUX_PKG_CACHEDIR="$5/cache"; TERMUX_PKG_SRCDIR="$5/src"; TERMUX_PKG_BUILDDIR="$5/build"
TERMUX_PKG_TMPDIR="$5/tmp"; TERMUX_PKG_HOSTBUILD_DIR="$5/host"; TERMUX_TOPDIR="$5/top"
__values() {
    printf 'VERSION\t%s\0' "${TERMUX_PKG_VERSION}" >&3
    printf 'REVISION\t%s\0' "${TERMUX_PKG_REVISION}" >&3
    for v in "${TERMUX_PKG_SRCURL[@]}"; do printf 'SRCURL\t%s\0' "$v" >&3; done
    for v in "${TERMUX_PKG_SHA256[@]}"; do printf 'SHA256\t%s\0' "$v" >&3; done
    printf 'GIT_BRANCH\t%s\0' "${TERMUX_PKG_GIT_BRANCH}" >&3
    printf 'SKIP_SRC_EXTRACT\t%s\0' "${TERMUX_PKG_SKIP_SRC_EXTRACT}" >&3
    printf 'END\t\0' >&3
}
trap __values EXIT
. "$1"
trap - EXIT
__values
shift 5
for step in "$@"; do
    printf 'STEP\t%s\0' "$step" >&3
    if declare -F "$step" >/dev/null; then
        ( cd "$TERMUX_PKG_SRCDIR" && "$step" )
    fi
done
'''


class SourceError(Exception):
    """A package whose recipe or source can't be found or verified."""


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def full_version(version, revision):
    """Termux's TERMUX_PKG_FULLVERSION (scripts/build/termux_step_start_build.sh)."""
    revision = revision or "0"
    if revision != "0" or "-" in version:
        return "%s-%s" % (version, revision)
    return version


def copyleft_rows(offer_path):
    """[(package, version, [abi], licence)] from SOURCE_OFFER.md's generated table."""
    with open(offer_path, encoding="utf-8") as handle:
        text = handle.read()
    begin, end = OFFER_MARKERS
    if text.count(begin) != 1 or text.count(end) != 1:
        raise SourceError("%s needs exactly one %s ... %s section" % (offer_path, begin, end))
    rows = []
    for line in text[text.index(begin):text.index(end)].splitlines():
        if not line.startswith("| ") or line.startswith("| Package "):
            continue
        cells = [cell.strip() for cell in re.split(r"(?<!\\)\|", line.strip())[1:-1]]
        if len(cells) < 4 or not cells[0] or not cells[1]:
            raise SourceError("unexpected row in %s: %s" % (offer_path, line))
        name, version, abis, licence = cells[:4]
        rows.append((name, version, [abi.strip() for abi in abis.split(",")],
                     licence.replace("\\|", "|").replace("\\*", "*")))
    if not rows:
        raise SourceError("%s's copyleft table lists no package" % offer_path)
    return rows


def binaries(pins, name, version, abis):
    """Where each ABI's binary of a row came from: [{abi, from, file, sha256}]."""
    found = []
    for arch, abi in ARCHES.items():
        if abi not in abis:
            continue
        pinned = [entry for entry in pins["packages"].get(arch, [])
                  if entry["package"] == name and entry["version"] == version]
        if pinned:
            found.append({"abi": abi, "from": "pinned", "file": pinned[0]["filename"],
                          "sha256": pinned[0]["sha256"]})
        elif pins["bootstrap"]["packages"].get(arch, {}).get(name, {}).get("version") == version:
            bootstrap = pins["bootstrap"]["files"][arch]
            found.append({"abi": abi, "from": "bootstrap", "file": bootstrap["url"],
                          "sha256": bootstrap["sha256"]})
        else:
            raise SourceError("%s %s (%s) is neither pinned nor in the bootstrap: is "
                              "SOURCE_OFFER.md current? (runtime/notices.py --check)"
                              % (name, version, abi))
    if not found:
        raise SourceError("%s %s names no ABI this build knows (%s)"
                          % (name, version, ", ".join(abis)))
    return found


class Termux:
    """A termux-packages clone, read through git."""

    def __init__(self, path):
        self.path = path
        if subprocess.run(["git", "-C", path, "rev-parse", "--git-dir"], stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE).returncode != 0:
            raise SourceError("%s is not a git clone of termux-packages" % path)
        promisor = self.git("config", "--get", "remote.origin.promisor", check=False).strip()
        self.partial = promisor == b"true"
        self._trees = {}
        self._blobs = {}
        # Path-limited history over ~66,000 commits takes seconds per folder without
        # a commit-graph's changed-path filters, and a fraction of a second with them.
        graph = self.git("rev-parse", "--git-path", "objects/info/commit-graph").decode().strip()
        if not os.path.isabs(graph):
            graph = os.path.join(path, graph)
        if not os.path.exists(graph):
            self.git("commit-graph", "write", "--reachable", "--changed-paths")

    def git(self, *arguments, data=None, check=True):
        result = subprocess.run(["git", "-C", self.path] + list(arguments), input=data,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if check and result.returncode != 0:
            raise SourceError("git %s: %s" % (" ".join(arguments[:2]),
                                              result.stderr.decode("utf-8", "replace").strip()))
        return result.stdout

    def commit(self, spec):
        return self.git("rev-parse", "--verify", "--end-of-options",
                        "%s^{commit}" % spec).decode().strip()

    def before(self, moment):
        found = self.git("rev-list", "-1", "--before=%s" % moment, "HEAD").decode().strip()
        if not found:
            raise SourceError("termux-packages has no commit before %s" % moment)
        return found

    def date(self, commit):
        return self.git("log", "-1", "--format=%cI", commit).decode().strip()

    def tree(self, commit, *paths):
        """[(mode, blob id, path)] under paths at commit (no blob is fetched)."""
        key = (commit, paths)
        if key not in self._trees:
            entries = []
            for item in self.git("ls-tree", "-r", "-z", commit, "--", *paths).split(b"\0"):
                if not item:
                    continue
                meta, path = item.split(b"\t", 1)
                mode, kind, oid = meta.decode().split()
                if kind == "blob":
                    entries.append((mode, oid, path.decode("utf-8", "surrogateescape")))
            self._trees[key] = entries
        return self._trees[key]

    def history(self, commit, path):
        """Commits at or before commit that touched path, newest first, in growing batches."""
        skip = 0
        for size in BATCHES:
            batch = self.git("log", "--format=%H", "-n", str(size), "--skip", str(skip),
                             commit, "--", path).decode().split()
            if batch:
                yield batch
            if len(batch) < size:
                return
            skip += len(batch)

    def oids(self, specs):
        """{"<commit>:<path>": blob id or None}, in one `git cat-file --batch-check`."""
        specs = list(dict.fromkeys(specs))
        if not specs:
            return {}
        out = self.git("cat-file", "--batch-check=%(objectname) %(objecttype)",
                       data=("\n".join(specs) + "\n").encode()).decode().splitlines()
        found = {}
        for spec, line in zip(specs, out):
            parts = line.split()
            found[spec] = parts[0] if len(parts) == 2 and parts[1] == "blob" else None
        return found

    def oid(self, commit, path):
        spec = "%s:%s" % (commit, path)
        return self.oids([spec])[spec]

    def prefetch(self, oids):
        """Fetches a blobless clone's missing blobs, 500 to a request."""
        wanted = [oid for oid in dict.fromkeys(oids) if oid and oid not in self._blobs]
        if not self.partial or not wanted:
            return
        present = self.git("cat-file", "--batch-check=%(objectname)", data=(
            "\n".join(wanted) + "\n").encode(), check=False).decode().split()
        missing = [oid for oid in wanted if oid not in set(present)]
        for start in range(0, len(missing), 500):
            self.git("fetch", "-q", "--no-tags", "--no-write-fetch-head", "--filter=blob:none",
                     "origin", *missing[start:start + 500])

    def read(self, oids):
        """{blob id: bytes}, in one `git cat-file --batch`."""
        wanted = [oid for oid in dict.fromkeys(oids) if oid not in self._blobs]
        if wanted:
            self.prefetch(wanted)
            out = self.git("cat-file", "--batch", data=("\n".join(wanted) + "\n").encode())
            position = 0
            for oid in wanted:
                newline = out.index(b"\n", position)
                header = out[position:newline].decode().split()
                if len(header) != 3 or header[1] != "blob":
                    raise SourceError("termux-packages: object %s is missing" % oid)
                start = newline + 1
                self._blobs[oid] = out[start:start + int(header[2])]
                position = start + int(header[2]) + 1
        return {oid: self._blobs[oid] for oid in oids}

    def recipe_dir(self, name, commit):
        """(folder, subpackage file or None) of a package at commit."""
        paths = {path for _, _, path in self.tree(commit, *RECIPE_TOPS)}
        for top in RECIPE_TOPS:
            if "%s/%s/build.sh" % (top, name) in paths:
                return "%s/%s" % (top, name), None
        suffix = "/%s.subpackage.sh" % name
        parents = sorted(os.path.dirname(path) for path in paths
                         if path.endswith(suffix) and path.count("/") == 2)
        if len(parents) == 1:
            return parents[0], os.path.basename(parents[0] + suffix)
        if parents:
            raise SourceError("%s is a subpackage of several recipes at %s: %s"
                              % (name, commit[:12], ", ".join(parents)))
        raise SourceError("termux-packages has no recipe for %s at %s" % (name, commit[:12]))


def download_steps(text):
    """[(function or "", line)] of each download call in a recipe's text."""
    sites, function = [], ""
    for number, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        match = FUNCTION.match(line)
        if match:
            function = match.group(1)
        elif line and not line[0].isspace() and line.strip() not in ("}", "fi", "done"):
            function = ""
        if DOWNLOAD_CALL.search(line):
            sites.append((function, number))
    return sites


def evaluate(build_sh, name, arch="aarch64", steps=()):
    """What a recipe declares for one ABI, then the downloads its given steps make.

    Returns version, revision, srcurl, sha256, git_branch, skip_extract and
    downloads: [(step, url, sha256)] in the order the steps made them.
    """
    bash = shutil.which("bash")
    found = {tool: shutil.which(tool) for tool in FILTERS}
    missing = [tool for tool, path in found.items() if not path]
    if not bash or missing:
        raise SourceError("evaluating a recipe needs bash and %s" % ", ".join(missing or FILTERS))
    with tempfile.TemporaryDirectory() as work:
        tools = os.path.join(work, "bin")
        os.makedirs(tools)
        for tool, path in found.items():
            if tool == "sed":
                with open(os.path.join(tools, tool), "w", encoding="utf-8") as handle:
                    handle.write("#!/bin/sh\nexec %s --sandbox \"$@\"\n" % path)
                os.chmod(os.path.join(tools, tool), 0o755)
            else:
                os.symlink(path, os.path.join(tools, tool))
        for sub in ("recipe", "root", "cache", "src", "build", "tmp", "host", "top"):
            os.makedirs(os.path.join(work, sub))
        script = os.path.join(work, "recipe", "build.sh")
        with open(script, "wb") as handle:
            handle.write(build_sh)
        try:
            result = subprocess.run(
                [bash, "--noprofile", "--norc", "-c", EVALUATE, "_", script, name, arch,
                 ARCH_BITS.get(arch, "64"), work] + list(steps),
                env={"PATH": tools, "HOME": work, "LC_ALL": "C"}, cwd=work,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=120)
        except subprocess.TimeoutExpired:
            raise SourceError("%s's recipe did not finish evaluating in 120 s" % name)
    values = {"VERSION": [], "REVISION": [], "SRCURL": [], "SHA256": [], "GIT_BRANCH": [],
              "SKIP_SRC_EXTRACT": []}
    downloads, step, ended = [], None, False
    for item in result.stdout.decode("utf-8", "replace").split("\0"):
        key, tab, value = item.partition("\t")
        if not tab:
            continue
        if key == "END":
            ended = True
        elif key == "STEP":
            step = value
        elif key == "DOWNLOAD" and step is not None:
            url, _, checksum = value.partition("\t")
            downloads.append((step, url, checksum))
        elif key in values and not ended:
            values[key].append(value)
    if not ended or not values["VERSION"] or not values["VERSION"][0]:
        raise SourceError("%s's recipe could not be evaluated" % name)
    return {
        "version": values["VERSION"][0],
        "revision": (values["REVISION"] or ["0"])[0],
        "srcurl": [url for url in values["SRCURL"] if url],
        "sha256": [value for value in values["SHA256"] if value],
        "git_branch": (values["GIT_BRANCH"] or [""])[0],
        "skip_extract": (values["SKIP_SRC_EXTRACT"] or ["false"])[0] == "true",
        "downloads": downloads,
    }


def recipe_sources(name, version, folder, commit, text, arches):
    """The sources a recipe commit names for the given ABIs, and what it leaves out."""
    base = os.path.basename(folder)
    source_steps, left_out = [], []
    for function, line in download_steps(text.decode("utf-8", "replace")):
        key = (base, function)
        if key not in STEP_DOWNLOADS:
            raise SourceError("%s %s: %s/build.sh (at %s) downloads in %s, line %d, which "
                              "STEP_DOWNLOADS in runtime/sources.py has not reviewed: add it as "
                              "source, or as left out with the reason"
                              % (name, version, folder, commit[:12],
                                 function or "its top level", line))
        if STEP_DOWNLOADS[key] is None:
            if function not in source_steps:
                source_steps.append(function)
        elif all(entry["step"] != function for entry in left_out):
            left_out.append({"step": function, "reason": STEP_DOWNLOADS[key]})
    sources = []

    def add(source):
        if all(other["url"] != source["url"] for other in sources):
            sources.append(source)

    for arch in arches:
        declared = evaluate(text, base, arch, source_steps)
        urls, hashes = declared["srcurl"], declared["sha256"]
        if urls and urls[0].startswith("git+"):
            if len(urls) != 1:
                raise SourceError("%s %s: a git source must be the only TERMUX_PKG_SRCURL"
                                  % (name, version))
            ref = declared["git_branch"] or "v" + declared["version"].split(":", 1)[-1]
            add({"kind": "git", "url": urls[0][4:], "ref": ref})
        else:
            if len(hashes) != len(urls):
                raise SourceError("%s %s: %d source URLs but %d SHA-256s in %s at %s (%s)"
                                  % (name, version, len(urls), len(hashes), folder, commit[:12],
                                     arch))
            for url, checksum in zip(urls, hashes):
                if not SHA256.match(checksum):
                    raise SourceError("%s %s: %s has no SHA-256 in its recipe (%r)"
                                      % (name, version, url, checksum))
                add({"kind": "archive", "url": url, "sha256": checksum})
        for step, url, checksum in declared["downloads"]:
            if not url or url in urls:
                continue
            if not SHA256.match(checksum or ""):
                raise SourceError("%s %s: %s, downloaded in %s, has no SHA-256 in the recipe"
                                  % (name, version, url, step))
            add({"kind": "patch", "url": url, "sha256": checksum, "step": step})
    return sources, left_out


def resolve(termux, pins, row):
    """One copyleft row -> its binaries, and its recipe (one per distinct commit)."""
    name, version, abis, licence = row
    built = binaries(pins, name, version, abis)
    arches = [arch for arch, abi in ARCHES.items() if abi in abis]
    snapshots = []
    if any(binary["from"] == "pinned" for binary in built):
        snapshots.append(("pinned", termux.before(pins["resolvedAt"])))
    if any(binary["from"] == "bootstrap" for binary in built):
        tag = "bootstrap-%s" % pins["bootstrap"]["version"]
        try:
            snapshots.append(("bootstrap", termux.commit("refs/tags/" + tag)))
        except SourceError:
            raise SourceError("termux-packages has no tag %s, the bootstrap's" % tag)
    recipes = []
    for origin, snapshot in snapshots:
        folder, subpackage = termux.recipe_dir(name, snapshot)
        match = None
        for batch in termux.history(snapshot, folder):
            found = termux.oids("%s:%s/build.sh" % (commit, folder) for commit in batch)
            termux.prefetch(oid for oid in found.values() if oid)
            for commit in batch:
                oid = found["%s:%s/build.sh" % (commit, folder)]
                if not oid:
                    continue
                text = termux.read([oid])[oid]
                declared = evaluate(text, os.path.basename(folder), arches[0])
                if full_version(declared["version"], declared["revision"]) == version:
                    match = (commit, text)
                    break
            if match:
                break
        if not match:
            raise SourceError("%s %s: no termux-packages commit at or before %s gives that "
                              "version (%s/build.sh)" % (name, version, snapshot[:12], folder))
        commit, text = match
        if subpackage and not termux.oid(commit, "%s/%s" % (folder, subpackage)):
            raise SourceError("%s %s: %s at %s has no %s"
                              % (name, version, folder, commit[:12], subpackage))
        same = next((recipe for recipe in recipes if recipe["commit"] == commit), None)
        if same:
            same["origin"].append(origin)
            continue
        sources, left_out = recipe_sources(name, version, folder, commit, text, arches)
        recipes.append({"origin": [origin], "commit": commit, "date": termux.date(commit),
                        "folder": folder, "subpackage": subpackage, "sources": sources,
                        "leftOut": left_out})
    return {"name": name, "version": version, "abis": abis, "licence": licence,
            "binaries": built, "recipes": recipes}


def plan(termux, pins, rows):
    """Every row resolved, or SourceError naming the first that is not."""
    packages = [resolve(termux, pins, row) for row in rows]
    commits = sorted({recipe["commit"] for package in packages for recipe in package["recipes"]})
    bootstrap = None
    if any(binary["from"] == "bootstrap" for package in packages
           for binary in package["binaries"]):
        bootstrap = termux.commit("refs/tags/bootstrap-%s" % pins["bootstrap"]["version"])
    return {"packages": packages, "commits": commits, "bootstrapCommit": bootstrap,
            "termuxHead": termux.commit("HEAD")}


# --- downloads ---------------------------------------------------------------------------------

def file_name(url):
    name = os.path.basename(urllib.parse.urlparse(url).path.rstrip("/")) or "source"
    return re.sub(r"[^A-Za-z0-9._+~-]", "_", name)


def download_urls(url):
    """[(mirror prefix or None, URL)]: the recipe's URL, then the same path
    under the other prefixes of the MIRRORS group whose prefix it starts with
    (the longest, where prefixes nest); a prefix that failed earlier in the
    run goes last."""
    matches = [(prefix, group) for group in MIRRORS for prefix in group if url.startswith(prefix)]
    if not matches:
        return [(None, url)]
    prefix, group = max(matches, key=lambda match: len(match[0]))
    rest = url[len(prefix):]
    ordered = [prefix] + [other for other in group if other != prefix]
    ordered.sort(key=lambda candidate: candidate in FAILED_MIRRORS)
    return [(candidate, candidate + rest) for candidate in ordered]


def download(curl, url, partial):
    """Downloads url to partial with retries; None, or the last error."""
    error = ""
    for attempt in range(1, DOWNLOAD_ATTEMPTS + 1):
        result = subprocess.run(
            [curl, "--fail", "--location", "--silent", "--show-error", "--proto",
             "=https,http,ftp,file", "--connect-timeout", "30", "--max-time", str(TIMEOUT),
             "--user-agent", "CodeForge-sources/1 (+%s)" % CODEFORGE_REPOSITORY,
             "--output", partial, url], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode == 0:
            return None
        error = result.stderr.decode("utf-8", "replace").strip() or "curl exit %d" % (
            result.returncode)
        if os.path.exists(partial):
            os.remove(partial)
        if attempt < DOWNLOAD_ATTEMPTS:
            time.sleep(5 * attempt)
    return error


def fetch(url, checksum, cache, label):
    """The verified file for (url, SHA-256): from the cache, or downloaded
    with curl from the URL or, when that fails, from its mirrors."""
    os.makedirs(cache, exist_ok=True)
    path = os.path.join(cache, checksum)
    if os.path.isfile(path):
        if sha256_file(path) == checksum:
            return path
        os.remove(path)
    curl = shutil.which("curl")
    if not curl:
        raise SourceError("downloading the sources needs curl")
    partial = path + ".part"
    failures = []
    for prefix, candidate in download_urls(url):
        error = download(curl, candidate, partial)
        if error is None:
            got = sha256_file(partial)
            if got == checksum:
                os.replace(partial, path)
                if candidate != url:
                    print("  mirror: %s: %s from %s" % (label, file_name(url), candidate),
                          file=sys.stderr)
                return path
            os.remove(partial)
            error = "SHA-256 %s" % got
        failures.append((candidate, error))
        if prefix is not None and prefix not in FAILED_MIRRORS:
            FAILED_MIRRORS.add(prefix)
            print("  mirror: %s failed (%s); its group's other hosts go first from now on"
                  % (prefix, error), file=sys.stderr)
    if len(failures) == 1:
        candidate, error = failures[0]
        if error.startswith("SHA-256 "):
            raise SourceError("%s: %s has %s, but its recipe says %s"
                              % (label, url, error, checksum))
        raise SourceError("%s: %s could not be downloaded (%s)" % (label, url, error))
    raise SourceError("%s: %s could not be downloaded with its recipe's SHA-256 %s, from it or "
                      "its mirrors: %s" % (label, url, checksum, "; ".join(
                          "%s (%s)" % failure for failure in failures)))


def git_source(url, ref, cache, label):
    """(tar path, commit, SHA-256) of a git source at ref, cloned as Termux's build does."""
    os.makedirs(cache, exist_ok=True)
    record = os.path.join(cache, "git-%s.json" % hashlib.sha256(
        ("%s\0%s" % (url, ref)).encode()).hexdigest()[:32])
    if os.path.isfile(record):
        with open(record, encoding="utf-8") as handle:
            known = json.load(handle)
        path = os.path.join(cache, known["sha256"])
        if os.path.isfile(path) and sha256_file(path) == known["sha256"]:
            return path, known["commit"], known["sha256"]
    with tempfile.TemporaryDirectory() as work:
        checkout = os.path.join(work, "checkout")
        steps = (["clone", "-q", "--depth", "1", "--branch", ref, url, checkout],
                 ["-C", checkout, "submodule", "update", "-q", "--init", "--recursive",
                  "--depth", "1"])
        for arguments in steps:
            result = subprocess.run(["git", "-c", "advice.detachedHead=false",
                                     "-c", "protocol.file.allow=always"] + arguments,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode != 0:
                raise SourceError("%s: git %s of %s at %s failed: %s" % (
                    label, arguments[0] if arguments[0] != "-C" else arguments[2], url, ref,
                    result.stderr.decode("utf-8", "replace").strip()))
        commit, stamp = subprocess.run(["git", "-C", checkout, "log", "-1", "--format=%H %ct"],
                                       stdout=subprocess.PIPE, check=True).stdout.decode().split()
        prefix = "%s-%s" % (re.sub(r"\.git$", "", file_name(url)), ref)
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode="w", format=tarfile.PAX_FORMAT) as tar:
            for directory, folders, files in os.walk(checkout):
                folders[:] = sorted(folder for folder in folders if folder != ".git")
                for entry in sorted(folders + [name for name in files if name != ".git"]):
                    path = os.path.join(directory, entry)
                    info = tar.gettarinfo(path, "%s/%s" % (prefix, os.path.relpath(path, checkout)))
                    normalise(info, int(stamp))
                    if info.isreg():
                        with open(path, "rb") as handle:
                            tar.addfile(info, handle)
                    else:
                        tar.addfile(info)
        payload = data.getvalue()
    checksum = hashlib.sha256(payload).hexdigest()
    path = os.path.join(cache, checksum)
    with open(path, "wb") as handle:
        handle.write(payload)
    with open(record, "w", encoding="utf-8") as handle:
        json.dump({"url": url, "ref": ref, "commit": commit, "sha256": checksum}, handle)
    return path, commit, checksum


# --- the archive -------------------------------------------------------------------------------

def normalise(info, mtime):
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    info.mtime = mtime
    if info.isdir():
        info.mode = 0o755
    elif info.isreg() or info.islnk():
        info.mode = 0o755 if info.mode & 0o111 else 0o644
    return info


class Archive:
    """A deterministic tar: members sorted by path, one mtime, no owners.

    Members added with the same content key are written once: the first in the
    tar's order holds the data, and the rest are hard links to it.
    """

    def __init__(self, mtime):
        self.mtime = mtime
        self.members = {}   # path -> (kind "data" | "file", bytes | file path, mode, key)

    def add_bytes(self, path, data, mode=0o644, key=None):
        self.members.setdefault(path, ("data", data, mode, key))

    def add_file(self, path, source, mode=0o644, key=None):
        self.members.setdefault(path, ("file", source, mode, key))

    def write(self, out_path, top):
        directories = set()
        for path in self.members:
            parts = path.split("/")[:-1]
            for index in range(1, len(parts) + 1):
                directories.add("/".join(parts[:index]))
        order = sorted(directories | set(self.members), key=lambda path: path.split("/"))
        written = {}
        partial = out_path + ".part"
        with tarfile.open(partial, "w", format=tarfile.PAX_FORMAT) as tar:
            for path in order:
                info = tarfile.TarInfo("%s/%s" % (top, path))
                if path not in self.members:
                    info.type = tarfile.DIRTYPE
                    tar.addfile(normalise(info, self.mtime))
                    continue
                kind, payload, mode, key = self.members[path]
                if key is not None and key in written:
                    info.type = tarfile.LNKTYPE
                    info.linkname = "%s/%s" % (top, written[key])
                    info.mode = mode
                    tar.addfile(normalise(info, self.mtime))
                    continue
                info.mode = mode
                if kind == "data":
                    info.size = len(payload)
                    tar.addfile(normalise(info, self.mtime), io.BytesIO(payload))
                else:
                    info.size = os.path.getsize(payload)
                    with open(payload, "rb") as handle:
                        tar.addfile(normalise(info, self.mtime), handle)
                if key is not None:
                    written[key] = path
        os.replace(partial, out_path)


def build(termux, pins, rows, cache, out_path, label):
    """Plans, downloads, verifies and writes the archive; returns its manifest."""
    planned = plan(termux, pins, rows)
    archive = Archive(calendar.timegm(time.strptime(pins["resolvedAt"], "%Y-%m-%dT%H:%M:%SZ")))
    top = "codeforge-%s-sources" % label

    # termux-packages: the build system at every commit and at the bootstrap's tag, and
    # each commit's recipe folders.
    commits = sorted(set(planned["commits"]) | ({planned["bootstrapCommit"]} - {None}))
    folders = {}
    for package in planned["packages"]:
        for recipe in package["recipes"]:
            folders.setdefault(recipe["commit"], set()).add(recipe["folder"])
    trees = []
    for commit in commits:
        entries = list(termux.tree(commit, *BUILD_SYSTEM))
        if not any(path == "build-package.sh" for _, _, path in entries):
            raise SourceError("termux-packages at %s has no build-package.sh" % commit[:12])
        for folder in sorted(folders.get(commit, ())):
            entries += termux.tree(commit, folder)
        trees.append((commit, entries))
    termux.prefetch(oid for _, entries in trees for _, oid, _ in entries)
    for commit, entries in trees:
        blobs = termux.read([oid for _, oid, _ in entries])
        for mode, oid, path in entries:
            # A symbolic link is kept as a small file holding its target.
            executable = 0o755 if mode == "100755" else 0o644
            archive.add_bytes("termux-packages/%s/%s" % (commit, path), blobs[oid], executable,
                              key="blob:%s:%o" % (oid, executable))

    # The upstream sources, verified.
    entries = []
    for package in planned["packages"]:
        label_name = "%s %s" % (package["name"], package["version"])
        recipes = []
        for recipe in package["recipes"]:
            directory = "upstream/%s-%s" % (os.path.basename(recipe["folder"]),
                                            package["version"].replace(":", "_"))
            files = []
            for source in recipe["sources"]:
                if source["kind"] == "git":
                    path, commit, checksum = git_source(source["url"], source["ref"], cache,
                                                        label_name)
                    name = "%s-%s.git-%s.tar" % (re.sub(r"\.git$", "", file_name(source["url"])),
                                                 file_name(source["ref"]), commit[:12])
                    record = {"kind": "git", "url": source["url"], "ref": source["ref"],
                              "commit": commit, "sha256": checksum}
                else:
                    path = fetch(source["url"], source["sha256"], cache, label_name)
                    name, checksum = file_name(source["url"]), source["sha256"]
                    record = dict(source)
                archive.add_file("%s/%s" % (directory, name), path, key="sha256:" + checksum)
                record["file"] = "%s/%s" % (directory, name)
                files.append(record)
            recipes.append(dict(recipe, sources=files, path="termux-packages/%s/%s" % (
                recipe["commit"], recipe["folder"]), origin=sorted(recipe["origin"])))
        entries.append(dict(package, recipes=recipes))

    manifest = {
        "schema": 1,
        "label": label,
        "generatedBy": "runtime/sources.py",
        "termuxPackages": {"repository": TERMUX_REPOSITORY, "head": planned["termuxHead"],
                           "commits": commits, "bootstrapCommit": planned["bootstrapCommit"]},
        "pins": {"resolvedAt": pins["resolvedAt"], "bootstrap": pins["bootstrap"]["version"],
                 "repository": pins.get("repository")},
        "packages": entries,
    }
    archive.add_bytes("MANIFEST.json",
                      (json.dumps(manifest, indent=1, sort_keys=True) + "\n").encode())
    archive.add_bytes("README.md", readme(manifest).encode())
    archive.write(out_path, top)
    return manifest


def readme(manifest):
    packages = manifest["packages"]
    bootstrap = manifest["termuxPackages"]["bootstrapCommit"]
    lines = [
        "# The corresponding source of CodeForge's userland (%s)" % manifest["label"],
        "",
        "CodeForge carries a Linux userland built from Termux packages. This archive holds the "
        "source of each package version in it that is under a copyleft licence (GPL, LGPL, "
        "MPL and the like): %d package versions. CodeForge's own code is public at %s, under "
        "the Apache License 2.0. The written offer is SOURCE_OFFER.md there, and in the app's "
        "About." % (len(packages), CODEFORGE_REPOSITORY),
        "",
        "## What is here",
        "",
        "- `upstream/<recipe>-<version>/`: the upstream release each recipe builds, from the "
        "URL the recipe names, verified against the recipe's SHA-256, and the patches an "
        "upstream publishes that the recipe applies. A git source is a tar of its tree at the "
        "commit MANIFEST.json records.",
        "- `termux-packages/<commit>/`: %s at that commit: the recipes built there "
        "(`packages/<name>/`: `build.sh`, its patches and files), and Termux's build system "
        "(`build-package.sh`, `scripts/`, `ndk-patches/`). A file repeated from one commit to "
        "another is a hard link to its first copy." % TERMUX_REPOSITORY,
        "- `MANIFEST.json`: for each package version, its licence; the binary CodeForge ships "
        "(the `.deb` from Termux's repository, or the bootstrap archive it came in) with its "
        "SHA-256; the recipe's commit and folder; each source with its URL and SHA-256; and "
        "what a recipe downloads only for the build machine, left out, with the reason.",
    ]
    if bootstrap:
        lines.append("- The bootstrap (`%s`) was built by Termux's scripts at "
                     "`termux-packages/%s/scripts/` (generate-bootstraps.sh and "
                     "build-bootstraps.sh)." % (manifest["pins"]["bootstrap"], bootstrap))
    lines += [
        "",
        "## Rebuilding a package",
        "",
        "Use the package's commit folder here (or check out termux-packages at that commit), "
        "put the upstream files where Termux's build caches its downloads, and run "
        "`./build-package.sh <package>` as termux-packages' documentation describes (in "
        "Termux's builder image). The recipe for a version is the newest commit at or before "
        "the pins' date (%s) for a package CodeForge pins, or the bootstrap's tag for one "
        "from the bootstrap, whose recipe gives that version."
        % manifest["pins"]["resolvedAt"],
        "",
        "## The packages",
        "",
        "| Package | Version | Licence | Recipe | Sources |",
        "|---|---|---|---|---|",
    ]
    for package in packages:
        for recipe in package["recipes"]:
            lines.append("| %s | %s | %s | `%s` at `%s` | %s |" % (
                package["name"], package["version"], package["licence"].replace("|", "\\|"),
                recipe["folder"], recipe["commit"][:12],
                ", ".join("`%s`" % os.path.basename(source["file"])
                          for source in recipe["sources"]) or "the recipe's own files"))
    lines.append("")
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("command", choices=("plan", "build"))
    parser.add_argument("--termux", required=True, help="a clone of termux-packages")
    parser.add_argument("--pins", default=DEFAULT_PINS)
    parser.add_argument("--offer", default=DEFAULT_OFFER)
    parser.add_argument("--cache", help="build: upstream files, kept by SHA-256")
    parser.add_argument("--out", help="build: the tar to write")
    parser.add_argument("--label", default="unreleased", help="build: names the archive")
    parser.add_argument("--json", help="plan: also write the plan here")
    arguments = parser.parse_args(argv)
    if not re.match(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$", arguments.label):
        parser.error("--label: letters, digits and ._+- only")
    if arguments.command == "build" and not (arguments.cache and arguments.out):
        parser.error("build needs --cache and --out")
    with open(arguments.pins, encoding="utf-8") as handle:
        pins = json.load(handle)
    try:
        rows = copyleft_rows(arguments.offer)
        termux = Termux(arguments.termux)
        if arguments.command == "plan":
            planned = plan(termux, pins, rows)
            for package in planned["packages"]:
                for recipe in package["recipes"]:
                    kinds = [source["kind"] for source in recipe["sources"]]
                    print("%-18s %-24s %-26s %s %s  %s%s" % (
                        package["name"], package["version"], recipe["folder"],
                        recipe["commit"][:12], recipe["date"][:10],
                        ", ".join("%d %s" % (kinds.count(kind), kind)
                                  for kind in dict.fromkeys(kinds)) or "the recipe only",
                        "; %d left out" % len(recipe["leftOut"]) if recipe["leftOut"] else ""))
            print("sources: %d package versions, %d recipe commits"
                  % (len(planned["packages"]), len(planned["commits"])))
            if arguments.json:
                with open(arguments.json, "w", encoding="utf-8") as handle:
                    json.dump(planned, handle, indent=1, sort_keys=True)
            return 0
        manifest = build(termux, pins, rows, arguments.cache, arguments.out, arguments.label)
    except SourceError as error:
        print("sources: FAILED: %s" % error, file=sys.stderr)
        return 1
    files = sum(len(recipe["sources"]) for package in manifest["packages"]
                for recipe in package["recipes"])
    print("sources: %s, %d bytes, sha256 %s: %d package versions, %d upstream files, "
          "%d termux-packages commits" % (
              os.path.basename(arguments.out), os.path.getsize(arguments.out),
              sha256_file(arguments.out), len(manifest["packages"]), files,
              len(manifest["termuxPackages"]["commits"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
