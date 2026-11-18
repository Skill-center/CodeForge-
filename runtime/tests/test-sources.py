#!/usr/bin/env python3
"""Tests for runtime/sources.py (CodeForge's own, Phase 5 W1).

Builds a small termux-packages history in a local git repository (commits at
set dates, a bootstrap tag), upstream files served from file:// URLs and a git
upstream, pins and a source offer for them, and checks that:

  * a version maps to the newest commit at or before the pins' date (or the
    bootstrap's tag) whose recipe gives it, with Termux's revision and epoch
    rules, and a subpackage maps to its parent's folder;
  * an upstream's patches, downloaded in a reviewed step, are sources, and a
    reviewed build-machine download is left out with its reason;
  * the archive holds the recipes, the build system at every commit, the
    verified upstream files and a manifest, with repeated files hard-linked,
    and is the same bytes when built again;
  * a file its host can't give comes from a mirror in its group, only with the
    recipe's SHA-256, and the archive is the same bytes; a host that failed
    goes last for the rest of the run;
  * it fails closed, naming the package: a wrong checksum, a version no commit
    gives, a missing recipe, a row the pins don't have, an unreviewed download,
    a missing bootstrap tag; and it writes nothing then;
  * reading a recipe runs none of its commands but text filters.

No network: every URL is file://. Run: python3 runtime/tests/test-sources.py
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
import tarfile
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
RUNTIME = os.path.dirname(HERE)

_spec = importlib.util.spec_from_file_location("sources", os.path.join(RUNTIME, "sources.py"))
sources = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sources)

BOOTSTRAP = "2026.01.15-r1+apt.android-7"
RESOLVED = "2026-02-01T00:00:00Z"
REVIEWED = {
    ("hello", "termux_step_pre_configure"): None,
    ("tool", "termux_step_host_build"): "a compiler for the build machine",
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def git(cwd, *arguments, date=None):
    env = dict(os.environ, GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
               GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid",
               GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    if date:
        env["GIT_AUTHOR_DATE"] = env["GIT_COMMITTER_DATE"] = date
    return subprocess.run(["git", "-C", cwd] + list(arguments), env=env, check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.decode().strip()


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb" if isinstance(data, bytes) else "w") as handle:
        handle.write(data)


class Fixture:
    """A termux-packages history, its upstream files, pins and an offer, in one folder."""

    def __init__(self, root):
        self.root = root
        self.upstream = os.path.join(root, "upstream")
        self.termux = os.path.join(root, "termux-packages")
        self.files = {}
        for name, data in {"hello-1.0.tar.gz": b"hello one point oh\n",
                           "hello-1.1.tar.gz": b"hello one point one\n",
                           "hello11-001": b"--- a\n+++ b\n@@ first patch\n",
                           "hello11-002": b"--- a\n+++ b\n@@ second patch\n",
                           "hello-1.2.tar.gz": b"hello one point two\n",
                           "tool-2.0.tar.xz": b"tool two\n",
                           "evil-1.0.tar.gz": b"evil\n"}.items():
            write(os.path.join(self.upstream, name), data)
            self.files[name] = sha(data)
        # A git upstream with the tag Termux's build clones.
        self.gitpkg = os.path.join(self.upstream, "gitpkg")
        os.makedirs(self.gitpkg)
        git(self.gitpkg, "init", "-q", "-b", "main")
        write(os.path.join(self.gitpkg, "configure.ac"), "AC_INIT([gitpkg], [3.0])\n")
        write(os.path.join(self.gitpkg, "src", "main.c"), "int main(void) { return 0; }\n")
        git(self.gitpkg, "add", "-A")
        git(self.gitpkg, "commit", "-q", "-m", "gitpkg 3.0", date="2025-12-01T00:00:00Z")
        git(self.gitpkg, "tag", "v3.0")
        self.gitpkg_commit = git(self.gitpkg, "rev-parse", "HEAD")
        self.commits = {}
        self._history()

    def url(self, name):
        return "file://" + os.path.join(self.upstream, name)

    def hello(self, version, revision, extra=""):
        source = "hello-%s.tar.gz" % version
        return ('TERMUX_PKG_HOMEPAGE=https://example.invalid/hello\n'
                'TERMUX_PKG_LICENSE="GPL-3.0"\n'
                'TERMUX_PKG_VERSION=%s\n'
                'TERMUX_PKG_REVISION=%s\n'
                'TERMUX_PKG_SRCURL=%s\n'
                'TERMUX_PKG_SHA256=%s\n%s'
                % (version, revision, self.url(source).replace(version, "${TERMUX_PKG_VERSION}"),
                   self.files.get(source, "0" * 64), extra))

    def patches(self):
        # Like bash's recipe: the upstream's patches, by number, with their checksums.
        return ('\ntermux_step_pre_configure() {\n'
                '\tlocal PATCH_NUM\n'
                '\tlocal -A PATCH_CHECKSUMS=()\n'
                '\tPATCH_CHECKSUMS[001]=%s\n'
                '\tPATCH_CHECKSUMS[002]=%s\n'
                '\tfor PATCH_NUM in $(seq -f "%%03g" 2); do\n'
                '\t\ttermux_download \\\n'
                '\t\t\t"%s/hello11-$PATCH_NUM" \\\n'
                '\t\t\t"$TERMUX_PKG_CACHEDIR/hello_patch_$PATCH_NUM" \\\n'
                '\t\t\t"${PATCH_CHECKSUMS[$PATCH_NUM]}"\n'
                '\t\tpatch -p0 -i "$TERMUX_PKG_CACHEDIR/hello_patch_$PATCH_NUM"\n'
                '\tdone\n'
                '}\n' % (self.files["hello11-001"], self.files["hello11-002"],
                         "file://" + self.upstream))

    def commit(self, label, date, files, remove=()):
        for path, text in files.items():
            write(os.path.join(self.termux, path), text)
            if path.endswith(".sh") and path.count("/") <= 1:   # the build system's scripts
                os.chmod(os.path.join(self.termux, path), 0o755)
        for path in remove:
            os.remove(os.path.join(self.termux, path))
        git(self.termux, "add", "-A")
        git(self.termux, "commit", "-q", "-m", label, date=date)
        self.commits[label] = git(self.termux, "rev-parse", "HEAD")

    def _history(self):
        os.makedirs(self.termux)
        git(self.termux, "init", "-q", "-b", "master")
        self.commit("one", "2026-01-01T00:00:00Z", {
            "build-package.sh": "#!/bin/bash\necho building\n",
            "scripts/build/termux_step_start_build.sh": "termux_step_start_build() { :; }\n",
            "scripts/generate-bootstraps.sh": "#!/bin/bash\necho bootstrap\n",
            "ndk-patches/stdio.h.patch": "--- stdio.h\n",
            "packages/hello/build.sh": self.hello("1.0", "0"),
            "packages/hello/fix.patch": "--- hello.c\n+++ hello.c\n",
            "packages/termux-licenses/build.sh": 'TERMUX_PKG_VERSION=2.1\n'
                                                 'TERMUX_PKG_SKIP_SRC_EXTRACT=true\n',
            "packages/termux-licenses/LICENSES/GPL-3.0.txt": "GNU GENERAL PUBLIC LICENSE\n",
            "packages/gitpkg/build.sh": 'TERMUX_PKG_VERSION="3.0"\n'
                                        'TERMUX_PKG_SRCURL=git+file://%s\n'
                                        'TERMUX_PKG_GIT_BRANCH="v${TERMUX_PKG_VERSION}"\n'
                                        % self.gitpkg,
            # An epoch, a revision, a URL computed with sed (a text filter), and a
            # build-machine download reviewed as left out.
            "packages/tool/build.sh": 'TERMUX_PKG_VERSION="2:2.0"\n'
                                      'TERMUX_PKG_REVISION=1\n'
                                      'TERMUX_PKG_SRCURL=%s/tool-$(sed "s/^2://" <<< '
                                      '$TERMUX_PKG_VERSION).tar.xz\n'
                                      'TERMUX_PKG_SHA256=%s\n'
                                      'termux_step_host_build() {\n'
                                      '\ttermux_download https://example.invalid/cc.tar '
                                      '"$TERMUX_PKG_CACHEDIR/cc.tar" %s\n'
                                      '}\n' % ("file://" + self.upstream,
                                               self.files["tool-2.0.tar.xz"], "1" * 64),
        })
        self.commit("two", "2026-01-10T00:00:00Z", {
            "packages/hello/build.sh": self.hello("1.1", "2", self.patches()),
            "packages/hello/libhello.subpackage.sh": 'TERMUX_SUBPKG_DESCRIPTION="libhello"\n',
            "scripts/build/termux_step_start_build.sh": "termux_step_start_build() { true; }\n",
        })
        git(self.termux, "tag", "bootstrap-" + BOOTSTRAP)
        self.commit("three", "2026-01-20T00:00:00Z", {
            "packages/hello/build.sh": "# A comment, the same version.\n"
                                       + self.hello("1.1", "2", self.patches()),
        })
        self.commit("four", "2026-02-20T00:00:00Z", {
            "packages/hello/build.sh": self.hello("1.2", "0"),
        })

    def pins(self, pinned=None, bootstrap=None):
        pinned = pinned if pinned is not None else [("hello", "1.1-2"), ("tool", "2:2.0-1")]
        bootstrap = bootstrap if bootstrap is not None else {
            "libhello": "1.1-2", "gitpkg": "3.0", "termux-licenses": "2.1"}
        packages, boot = {}, {}
        for arch in ("aarch64", "x86_64"):
            packages[arch] = [{"package": name, "version": version,
                               "filename": "pool/main/%s/%s/%s_%s_%s.deb"
                                           % (name[0], name, name, version, arch),
                               "sha256": sha(("%s %s %s" % (name, version, arch)).encode())}
                              for name, version in pinned]
            boot[arch] = {name: {"version": version} for name, version in bootstrap.items()}
        return {"resolvedAt": RESOLVED, "repository": {"url": "https://example.invalid/apt"},
                "bootstrap": {"version": BOOTSTRAP, "packages": boot, "files": {
                    arch: {"url": "https://example.invalid/bootstrap-%s.zip" % arch,
                           "sha256": sha(arch.encode())} for arch in ("aarch64", "x86_64")}},
                "packages": packages}

    def offer(self, rows=None):
        rows = rows if rows is not None else [
            ("gitpkg", "3.0", "GPL-2.0-or-later"), ("hello", "1.1-2", "GPL-3.0-or-later"),
            ("libhello", "1.1-2", "LGPL-2.1-or-later"), ("termux-licenses", "2.1", "GPL-3.0"),
            ("tool", "2:2.0-1", "GPL-2.0-only \\| MIT")]
        table = "\n".join("| %s | %s | arm64-v8a, x86_64 | %s |" % row for row in rows)
        path = os.path.join(self.root, "SOURCE_OFFER.md")
        write(path, "# Source offer\n\n<!-- copyleft:begin -->\n"
                    "| Package | Version | ABIs | Licence |\n|---|---|---|---|\n%s\n"
                    "<!-- copyleft:end -->\n" % table)
        return path


class SourcesTest(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="codeforge-sources-")
        cls.fixture = Fixture(cls.tmp)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def setUp(self):
        self.patch = mock.patch.dict(sources.STEP_DOWNLOADS, REVIEWED, clear=True)
        self.patch.start()
        # The hosts a download failed from: state of one run, so of one test.
        sources.FAILED_MIRRORS.clear()
        self.addCleanup(sources.FAILED_MIRRORS.clear)
        self.work = tempfile.mkdtemp(dir=self.tmp)

    def tearDown(self):
        self.patch.stop()

    def plan(self, pins=None, rows=None):
        termux = sources.Termux(self.fixture.termux)
        return sources.plan(termux, pins or self.fixture.pins(),
                            sources.copyleft_rows(self.fixture.offer(rows)))

    def build(self, pins=None, rows=None, cache=None, name="out.tar"):
        out = os.path.join(self.work, name)
        manifest = sources.build(sources.Termux(self.fixture.termux), pins or self.fixture.pins(),
                                 sources.copyleft_rows(self.fixture.offer(rows)),
                                 cache or os.path.join(self.work, "cache"), out, "9.9.9")
        return out, manifest

    def by_name(self, planned):
        return {package["name"]: package for package in planned["packages"]}

    # --- which commit ---------------------------------------------------------------------------

    def test_full_version_follows_termuxs_rule(self):
        self.assertEqual(sources.full_version("1.0", "0"), "1.0")
        self.assertEqual(sources.full_version("1.0", ""), "1.0")
        self.assertEqual(sources.full_version("1.0", "2"), "1.0-2")
        self.assertEqual(sources.full_version("1.3-20240307", "1"), "1.3-20240307-1")
        self.assertEqual(sources.full_version("1.3-20240307", "0"), "1.3-20240307-0")
        self.assertEqual(sources.full_version("2:0.9", "0"), "2:0.9")

    def test_a_pinned_version_takes_the_newest_commit_before_the_pins_date(self):
        hello = self.by_name(self.plan())["hello"]
        self.assertEqual([recipe["commit"] for recipe in hello["recipes"]],
                         [self.fixture.commits["three"]])
        self.assertEqual(hello["recipes"][0]["origin"], ["pinned"])
        self.assertEqual(hello["recipes"][0]["folder"], "packages/hello")

    def test_a_bootstrap_package_takes_the_tag_and_a_subpackage_its_parents_folder(self):
        libhello = self.by_name(self.plan())["libhello"]
        recipe = libhello["recipes"][0]
        self.assertEqual(recipe["commit"], self.fixture.commits["two"])
        self.assertEqual(recipe["folder"], "packages/hello")
        self.assertEqual(recipe["subpackage"], "libhello.subpackage.sh")
        self.assertEqual(recipe["origin"], ["bootstrap"])
        self.assertEqual([binary["from"] for binary in libhello["binaries"]],
                         ["bootstrap", "bootstrap"])

    def test_an_epoch_and_a_revision_are_matched_and_sed_computes_the_url(self):
        tool = self.by_name(self.plan())["tool"]
        self.assertEqual(tool["recipes"][0]["commit"], self.fixture.commits["one"])
        self.assertEqual(tool["recipes"][0]["sources"], [{
            "kind": "archive", "url": self.fixture.url("tool-2.0.tar.xz"),
            "sha256": self.fixture.files["tool-2.0.tar.xz"]}])
        self.assertEqual(tool["recipes"][0]["leftOut"], [
            {"step": "termux_step_host_build", "reason": "a compiler for the build machine"}])
        self.assertEqual(tool["licence"], "GPL-2.0-only | MIT")

    def test_an_upstreams_patches_are_sources(self):
        hello = self.by_name(self.plan())["hello"]
        self.assertEqual([(source["kind"], os.path.basename(source["url"]))
                          for source in hello["recipes"][0]["sources"]],
                         [("archive", "hello-1.1.tar.gz"), ("patch", "hello11-001"),
                          ("patch", "hello11-002")])
        self.assertEqual(hello["recipes"][0]["sources"][1]["sha256"],
                         self.fixture.files["hello11-001"])

    def test_a_git_source_uses_its_branch_and_a_recipe_without_a_source_has_none(self):
        planned = self.by_name(self.plan())
        self.assertEqual(planned["gitpkg"]["recipes"][0]["sources"], [
            {"kind": "git", "url": "file://" + self.fixture.gitpkg, "ref": "v3.0"}])
        self.assertEqual(planned["termux-licenses"]["recipes"][0]["sources"], [])

    def test_the_binaries_are_named_with_their_hashes(self):
        hello = self.by_name(self.plan())["hello"]
        self.assertEqual([(binary["abi"], binary["from"]) for binary in hello["binaries"]],
                         [("arm64-v8a", "pinned"), ("x86_64", "pinned")])
        self.assertEqual(hello["binaries"][0]["sha256"], sha(b"hello 1.1-2 aarch64"))
        self.assertTrue(hello["binaries"][0]["file"].endswith("hello_1.1-2_aarch64.deb"))

    # --- the archive ----------------------------------------------------------------------------

    def test_the_archive_holds_recipes_build_system_sources_and_a_manifest(self):
        out, manifest = self.build()
        top = "codeforge-9.9.9-sources"
        with tarfile.open(out) as tar:
            members = {member.name: member for member in tar.getmembers()}
            one, two, three = (self.fixture.commits[label] for label in ("one", "two", "three"))

            def read(path):
                return tar.extractfile(members["%s/%s" % (top, path)]).read()

            self.assertEqual(read("upstream/hello-1.1-2/hello-1.1.tar.gz"),
                             b"hello one point one\n")
            self.assertEqual(read("upstream/hello-1.1-2/hello11-002"),
                             b"--- a\n+++ b\n@@ second patch\n")
            self.assertEqual(read("upstream/tool-2_2.0-1/tool-2.0.tar.xz"), b"tool two\n")
            self.assertIn(b"# A comment, the same version.",
                          read("termux-packages/%s/packages/hello/build.sh" % three))
            self.assertIn("%s/termux-packages/%s/packages/hello/fix.patch" % (top, three), members)
            self.assertIn("%s/termux-packages/%s/packages/termux-licenses/LICENSES/GPL-3.0.txt"
                          % (top, one), members)
            # The build system at every commit (two is also the bootstrap's tag).
            for commit in (one, two, three):
                self.assertIn("%s/termux-packages/%s/build-package.sh" % (top, commit), members)
                self.assertIn("%s/termux-packages/%s/scripts/generate-bootstraps.sh"
                              % (top, commit), members)
            # A recipe folder only at the commit that built it.
            self.assertNotIn("%s/termux-packages/%s/packages/tool/build.sh" % (top, three),
                             members)
            # Repeated files are hard links to their first copy, in the tar's order.
            first, *later = sorted([one, two, three])
            link = members["%s/termux-packages/%s/build-package.sh" % (top, later[0])]
            self.assertTrue(link.islnk())
            self.assertEqual(link.linkname, "%s/termux-packages/%s/build-package.sh" % (top, first))
            self.assertEqual(members["%s/termux-packages/%s/build-package.sh"
                                     % (top, first)].mode, 0o755)
            # The git source, as a tar of its tree at the recorded commit.
            git_tar = [name for name in members if name.startswith(
                "%s/upstream/gitpkg-3.0/gitpkg-v3.0.git-" % top)]
            self.assertEqual(len(git_tar), 1)
            with tarfile.open(fileobj=io.BytesIO(tar.extractfile(members[git_tar[0]]).read())) as inner:
                self.assertEqual(sorted(inner.getnames()), [
                    "gitpkg-v3.0/configure.ac", "gitpkg-v3.0/src", "gitpkg-v3.0/src/main.c"])
            self.assertEqual(json.loads(read("MANIFEST.json")), manifest)
            self.assertIn(b"| hello | 1.1-2 | GPL-3.0-or-later | `packages/hello` at `%s` |"
                          % three[:12].encode(), read("README.md"))
            for member in members.values():
                self.assertEqual((member.uid, member.gid, member.uname, member.gname),
                                 (0, 0, "", ""))
        gitpkg = [package for package in manifest["packages"] if package["name"] == "gitpkg"][0]
        self.assertEqual(gitpkg["recipes"][0]["sources"][0]["commit"], self.fixture.gitpkg_commit)
        self.assertEqual(manifest["termuxPackages"]["bootstrapCommit"],
                         self.fixture.commits["two"])
        self.assertEqual(manifest["pins"]["resolvedAt"], RESOLVED)

    def test_the_archive_is_the_same_bytes_when_built_again_from_the_cache(self):
        cache = os.path.join(self.work, "shared-cache")
        first, _ = self.build(cache=cache, name="first.tar")
        os.remove(os.path.join(self.fixture.upstream, "hello11-001"))   # now only in the cache
        try:
            second, _ = self.build(cache=cache, name="second.tar")
        finally:
            write(os.path.join(self.fixture.upstream, "hello11-001"), b"--- a\n+++ b\n@@ first patch\n")
        with open(first, "rb") as one, open(second, "rb") as two:
            self.assertEqual(one.read(), two.read())

    # --- mirrors --------------------------------------------------------------------------------

    def mirror(self, *names):
        """A folder holding copies of these upstream files, as a mirror would."""
        folder = os.path.join(self.work, "mirror")
        os.makedirs(folder, exist_ok=True)
        for name in names:
            shutil.copy(os.path.join(self.fixture.upstream, name), os.path.join(folder, name))
        return folder

    def test_download_urls_try_the_recipes_host_then_its_group(self):
        url = "https://mirrors.kernel.org/gnu/bash/bash-5.3-patches/bash53-001"
        self.assertEqual([candidate for _, candidate in sources.download_urls(url)],
                         [url, "https://ftp.gnu.org/gnu/bash/bash-5.3-patches/bash53-001",
                          "https://ftpmirror.gnu.org/bash/bash-5.3-patches/bash53-001"])
        sources.FAILED_MIRRORS.add("https://mirrors.kernel.org/gnu/")
        self.assertEqual([candidate for _, candidate in sources.download_urls(url)],
                         ["https://ftp.gnu.org/gnu/bash/bash-5.3-patches/bash53-001",
                          "https://ftpmirror.gnu.org/bash/bash-5.3-patches/bash53-001", url])
        node = "https://nodejs.org/dist/v26.13.1/node-v26.13.1.tar.xz"
        self.assertEqual(sources.download_urls(node), [(None, node)])
        # A prefix can end inside a file's name.
        db = "https://fossies.org/linux/misc/db-18.1.40.tar.gz"
        self.assertEqual([candidate for _, candidate in sources.download_urls(db)],
                         [db, "https://download.oracle.com/berkeley-db/db-18.1.40.tar.gz",
                          "https://distcache.freebsd.org/ports-distfiles/bdb/db-18.1.40.tar.gz"])
        other = "https://fossies.org/linux/misc/other-1.0.tar.gz"
        self.assertEqual(sources.download_urls(other), [(None, other)])
        nano = "https://nano-editor.org/dist/latest/nano-8.7.1.tar.xz"
        self.assertEqual([candidate for _, candidate in sources.download_urls(nano)],
                         [nano, "https://nano-editor.org/dist/v8/nano-8.7.1.tar.xz",
                          "https://ftp.gnu.org/gnu/nano/nano-8.7.1.tar.xz"])
        # Each prefix is a web address, in one group only.
        prefixes = [prefix for group in sources.MIRRORS for prefix in group]
        self.assertTrue(all(prefix.startswith(("https://", "http://")) for prefix in prefixes))
        self.assertEqual(len(prefixes), len(set(prefixes)))

    def test_a_file_its_host_lacks_comes_from_a_mirror_and_the_archive_is_unchanged(self):
        first, _ = self.build(name="first.tar")
        # A mirror holds every file; the host loses one.
        mirror = self.mirror(*self.fixture.files)
        group = ("file://%s/" % self.fixture.upstream, "file://%s/" % mirror)
        moved = os.path.join(self.work, "moved")
        os.rename(os.path.join(self.fixture.upstream, "hello11-001"), moved)
        try:
            with mock.patch.object(sources, "MIRRORS", (group,)), \
                    mock.patch.object(sources.time, "sleep"), \
                    contextlib.redirect_stderr(io.StringIO()) as notes:
                second, manifest = self.build(cache=os.path.join(self.work, "cold"),
                                              name="second.tar")
        finally:
            os.rename(moved, os.path.join(self.fixture.upstream, "hello11-001"))
        # The same file, so the same archive; the manifest names the recipe's URL.
        with open(first, "rb") as one, open(second, "rb") as two:
            self.assertEqual(one.read(), two.read())
        urls = [source["url"] for package in manifest["packages"]
                for recipe in package["recipes"] for source in recipe["sources"]]
        self.assertIn(self.fixture.url("hello11-001"), urls)
        self.assertIn("mirror: hello 1.1-2: hello11-001 from file://%s/hello11-001" % mirror,
                      notes.getvalue())
        self.assertEqual(sources.FAILED_MIRRORS, {group[0]})

    def test_a_host_that_failed_costs_its_retries_once(self):
        cache = os.path.join(self.work, "cache")
        mirror = self.mirror("hello-1.0.tar.gz", "hello-1.1.tar.gz")
        dead = os.path.join(self.work, "dead")
        group = ("file://%s/" % dead, "file://%s/" % mirror)
        with mock.patch.object(sources, "MIRRORS", (group,)), \
                mock.patch.object(sources.time, "sleep") as sleep, \
                contextlib.redirect_stderr(io.StringIO()) as notes:
            for name in ("hello-1.0.tar.gz", "hello-1.1.tar.gz"):
                path = sources.fetch("file://%s/%s" % (dead, name), self.fixture.files[name],
                                     cache, "hello")
                self.assertEqual(sources.sha256_file(path), self.fixture.files[name])
                # The dead host's retries, for the first file only.
                self.assertEqual(sleep.call_count, sources.DOWNLOAD_ATTEMPTS - 1)
        self.assertEqual(notes.getvalue().count(" failed ("), 1)

    def test_a_mirror_must_serve_the_recipes_checksum(self):
        mirror = self.mirror()
        write(os.path.join(mirror, "hello-1.0.tar.gz"), b"not hello\n")
        dead = os.path.join(self.work, "dead")
        group = ("file://%s/" % dead, "file://%s/" % mirror)
        cache = os.path.join(self.work, "cache")
        with mock.patch.object(sources, "MIRRORS", (group,)), \
                mock.patch.object(sources.time, "sleep"), \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertFails(lambda: sources.fetch("file://%s/hello-1.0.tar.gz" % dead,
                                                   self.fixture.files["hello-1.0.tar.gz"], cache,
                                                   "hello 1.0"),
                             "hello 1.0", "from it or its mirrors",
                             "file://%s/hello-1.0.tar.gz (curl" % dead,
                             "file://%s/hello-1.0.tar.gz (SHA-256 %s)" % (mirror,
                                                                         sha(b"not hello\n")),
                             self.fixture.files["hello-1.0.tar.gz"])
        self.assertEqual(os.listdir(cache), [])

    # --- it fails closed ------------------------------------------------------------------------

    def assertFails(self, call, *needles):
        with self.assertRaises(sources.SourceError) as caught:
            call()
        for needle in needles:
            self.assertIn(needle, str(caught.exception))
        self.assertEqual([name for name in os.listdir(self.work) if name.endswith(".tar")], [])

    def test_a_wrong_checksum_fails_naming_the_package(self):
        path = os.path.join(self.fixture.upstream, "hello-1.1.tar.gz")
        with open(path, "rb") as handle:
            original = handle.read()
        write(path, b"tampered\n")
        try:
            self.assertFails(self.build, "hello 1.1-2", "hello-1.1.tar.gz", sha(b"tampered\n"),
                             self.fixture.files["hello-1.1.tar.gz"])
        finally:
            write(path, original)
        self.assertFalse([name for name in os.listdir(os.path.join(self.work, "cache"))
                          if name.endswith(".part")])

    def test_a_download_that_fails_names_the_package_after_its_retries(self):
        with mock.patch.object(sources.time, "sleep") as sleep:
            self.assertFails(lambda: sources.fetch(self.fixture.url("nowhere.tar.gz"), "2" * 64,
                                                   os.path.join(self.work, "cache"), "ghost 1.0"),
                             "ghost 1.0", "nowhere.tar.gz", "could not be downloaded")
        self.assertEqual(sleep.call_count, sources.DOWNLOAD_ATTEMPTS - 1)

    def test_a_version_no_commit_gives_fails(self):
        self.assertFails(lambda: self.plan(pins=self.fixture.pins(pinned=[("hello", "1.1-3")]),
                                           rows=[("hello", "1.1-3", "GPL-3.0")]),
                         "hello 1.1-3", "no termux-packages commit", "packages/hello/build.sh")

    def test_a_version_after_the_pins_date_is_not_found(self):
        self.assertFails(lambda: self.plan(pins=self.fixture.pins(pinned=[("hello", "1.2")]),
                                           rows=[("hello", "1.2", "GPL-3.0")]),
                         "hello 1.2", "no termux-packages commit")

    def test_a_package_without_a_recipe_fails(self):
        self.assertFails(lambda: self.plan(pins=self.fixture.pins(pinned=[("ghost", "1.0")]),
                                           rows=[("ghost", "1.0", "GPL-3.0")]),
                         "no recipe for ghost")

    def test_a_row_the_pins_do_not_have_fails(self):
        self.assertFails(lambda: self.plan(rows=[("hello", "0.9", "GPL-3.0")]),
                         "hello 0.9", "notices.py --check")

    def test_a_missing_bootstrap_tag_fails(self):
        pins = self.fixture.pins()
        pins["bootstrap"]["version"] = "2099.01.01-r1"
        self.assertFails(lambda: self.plan(pins=pins), "bootstrap-2099.01.01-r1")

    def test_an_unreviewed_download_fails_naming_the_step(self):
        self.fixture.commit("evil", "2026-01-25T00:00:00Z", {
            "packages/evil/build.sh": 'TERMUX_PKG_VERSION=1.0\n'
                                      'TERMUX_PKG_SRCURL=%s\nTERMUX_PKG_SHA256=%s\n'
                                      'termux_step_post_make_install() {\n'
                                      '\ttermux_download https://example.invalid/x x %s\n}\n'
                                      % (self.fixture.url("evil-1.0.tar.gz"),
                                         self.fixture.files["evil-1.0.tar.gz"], "3" * 64)})
        try:
            self.assertFails(lambda: self.plan(pins=self.fixture.pins(pinned=[("evil", "1.0")]),
                                               rows=[("evil", "1.0", "GPL-3.0")]),
                             "evil 1.0", "termux_step_post_make_install", "STEP_DOWNLOADS")
        finally:
            git(self.fixture.termux, "reset", "-q", "--hard", self.fixture.commits["four"])
            subprocess.run(["git", "-C", self.fixture.termux, "commit-graph", "write",
                            "--reachable", "--changed-paths"], check=True)

    def test_an_offer_without_its_table_fails(self):
        path = os.path.join(self.work, "OFFER.md")
        write(path, "# Source offer\n\nNo table.\n")
        with self.assertRaises(sources.SourceError):
            sources.copyleft_rows(path)

    # --- reading a recipe -----------------------------------------------------------------------

    def test_reading_a_recipe_runs_nothing_but_text_filters(self):
        marker = os.path.join(self.work, "marker")
        declared = sources.evaluate((
            'TERMUX_PKG_VERSION=1.0\n'
            'touch %s-touch\n'
            'echo x > /dev/null; cp /etc/hostname %s-cp\n'
            'X=$(echo a | sed "w %s-sed")\n'
            'TERMUX_PKG_SRCURL=https://example.invalid/$(echo 1.0 | tr . _).tar\n'
            'TERMUX_PKG_SHA256=%s\n' % (marker, marker, marker, "4" * 64)).encode(), "probe")
        self.assertEqual(declared["srcurl"], ["https://example.invalid/1_0.tar"])
        self.assertEqual([name for name in os.listdir(self.work) if name.startswith("marker")], [])

    def test_a_recipe_that_exits_still_gives_its_values(self):
        declared = sources.evaluate(b'TERMUX_PKG_VERSION=4.5\nTERMUX_PKG_REVISION=3\nexit 1\n',
                                    "quits")
        self.assertEqual((declared["version"], declared["revision"]), ("4.5", "3"))

    def test_download_steps_finds_each_call_and_its_function(self):
        text = ('TERMUX_PKG_VERSION=1\n'
                'termux_step_get_source() {\n\ttermux_download a b c\n}\n'
                '# termux_download in a comment\n'
                'termux_download top level\n'
                'other() { termux_download_ubuntu_packages libffi8; }\n')
        self.assertEqual(sources.download_steps(text), [
            ("termux_step_get_source", 3), ("", 6), ("other", 7)])

    # --- the real files -------------------------------------------------------------------------

    def test_the_real_offer_parses(self):
        rows = sources.copyleft_rows(sources.DEFAULT_OFFER)
        self.assertGreater(len(rows), 0)
        self.assertEqual(len(rows), len({(name, version) for name, version, _, _ in rows}))
        for name, version, abis, licence in rows:
            self.assertTrue(set(abis) <= set(sources.ARCHES.values()), (name, abis))
            self.assertTrue(licence, name)

    def test_the_command_line_plans_and_rejects_a_build_without_its_paths(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = sources.main(["plan", "--termux", self.fixture.termux,
                                 "--pins", self.write_pins(), "--offer", self.fixture.offer()])
        self.assertEqual(code, 0)
        self.assertIn("sources: 5 package versions, 3 recipe commits", out.getvalue())
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            sources.main(["build", "--termux", self.fixture.termux])
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            sources.main(["build", "--termux", self.fixture.termux, "--cache", "c", "--out", "o",
                          "--label", "../x"])

    def write_pins(self):
        path = os.path.join(self.work, "pins.json")
        write(path, json.dumps(self.fixture.pins()))
        return path


if __name__ == "__main__":
    unittest.main(verbosity=1)
