"""Synthetic Termux repositories for CodeForge's runtime/ script tests.

CodeForge's own (Phase 4 W2). Builds what the real pipeline reads, in Termux's
layout, without a network: .deb files (an ar archive with control.tar.gz and
data.tar.xz under data/data/com.termux/files/usr), a Packages index per
architecture, and bootstrap zips with a dpkg status and SYMLINKS.txt. Served
through file:// URLs, which t1's fetcher supports.
"""

import hashlib
import io
import json
import lzma
import os
import pathlib
import tarfile
import zipfile

PREFIX = "./data/data/com.termux/files/usr/"
ARCHES = ("aarch64", "x86_64")


def make_deb(path, package, version, arch, files=None, links=None, depends=None,
             provides=None, homepage=None):
    """Write a .deb; files: prefix path -> bytes, links: prefix path -> target."""
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode="w") as tar:
        for name, content in sorted((files or {}).items()):
            info = tarfile.TarInfo(PREFIX + name)
            info.size = len(content)
            info.mode = 0o755 if name.startswith("bin/") else 0o644
            tar.addfile(info, io.BytesIO(content))
        for name, target in sorted((links or {}).items()):
            info = tarfile.TarInfo(PREFIX + name)
            info.type = tarfile.SYMTYPE
            info.linkname = target
            tar.addfile(info)
    control = "Package: %s\nArchitecture: %s\nVersion: %s\n" % (package, arch, version)
    if homepage:
        control += "Homepage: %s\n" % homepage
    if depends:
        control += "Depends: %s\n" % depends
    if provides:
        control += "Provides: %s\n" % provides
    control += "Description: synthetic package for CodeForge's tests\n"
    control_tar = io.BytesIO()
    with tarfile.open(fileobj=control_tar, mode="w:gz") as tar:
        blob = control.encode()
        info = tarfile.TarInfo("./control")
        info.size = len(blob)
        tar.addfile(info, io.BytesIO(blob))
    members = [(b"debian-binary", b"2.0\n"),
               (b"control.tar.gz", control_tar.getvalue()),
               (b"data.tar.xz", lzma.compress(data.getvalue()))]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as handle:
        handle.write(b"!<arch>\n")
        for name, payload in members:
            handle.write((name + b"/").ljust(16) + b"0".ljust(12) + b"0".ljust(6)
                         + b"0".ljust(6) + b"100644".ljust(8)
                         + str(len(payload)).encode().ljust(10) + b"`\n")
            handle.write(payload)
            if len(payload) % 2:
                handle.write(b"\n")
    with open(path, "rb") as handle:
        return handle.read()


class Repository:
    """A Termux-shaped apt repository on disk, one Packages index per arch."""

    def __init__(self, root):
        self.root = root
        self.stanzas = {arch: {} for arch in ARCHES}
        os.makedirs(root, exist_ok=True)

    @property
    def url(self):
        return pathlib.Path(self.root).as_uri()

    def add(self, package, version, files=None, links=None, depends=None,
            provides=None, homepage=None, arches=ARCHES):
        """Build the package for each arch and list it in that arch's index."""
        for arch in arches:
            filename = "pool/main/%s/%s/%s_%s_%s.deb" % (package[0], package, package,
                                                         version.split(":")[-1], arch)
            data = make_deb(os.path.join(self.root, filename), package, version, arch,
                            files, links, depends, provides, homepage)
            stanza = ("Package: %s\nArchitecture: %s\nVersion: %s\nFilename: %s\n"
                      "Size: %d\nSHA256: %s\nInstalled-Size: %d\n"
                      % (package, arch, version, filename, len(data),
                         hashlib.sha256(data).hexdigest(), max(1, len(data) // 1024)))
            if homepage:
                stanza += "Homepage: %s\n" % homepage
            if depends:
                stanza += "Depends: %s\n" % depends
            if provides:
                stanza += "Provides: %s\n" % provides
            self.stanzas[arch][package] = stanza
        self.write_indexes()

    def write_indexes(self):
        for arch in ARCHES:
            directory = os.path.join(self.root, "dists", "stable", "main", "binary-" + arch)
            os.makedirs(directory, exist_ok=True)
            text = "\n".join(self.stanzas[arch][name] for name in sorted(self.stanzas[arch]))
            # .xz first: t1's loader tries it first, so no fallback (and no
            # retry delay) happens in the tests.
            with open(os.path.join(directory, "Packages.xz"), "wb") as handle:
                handle.write(lzma.compress(text.encode()))

    def path_of(self, arch, package):
        for line in self.stanzas[arch][package].splitlines():
            if line.startswith("Filename: "):
                return os.path.join(self.root, line.split(": ", 1)[1])
        raise KeyError(package)


def make_bootstrap(path, packages, files=None, symlinks=None):
    """A bootstrap zip: packages name -> (version, homepage or None[, depends]).

    files: prefix path -> bytes; symlinks: link path -> target (SYMLINKS.txt,
    Termux's "target<-link" lines).
    """
    status = []
    for name, fields in sorted(packages.items()):
        version, homepage = fields[0], fields[1]
        depends = fields[2] if len(fields) > 2 else None
        stanza = "Package: %s\nStatus: install ok installed\nVersion: %s\n" % (name, version)
        if homepage:
            stanza += "Homepage: %s\n" % homepage
        if depends:
            stanza += "Depends: %s\n" % depends
        status.append(stanza + "Description: synthetic bootstrap package\n")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("var/lib/dpkg/status", "\n".join(status))
        for name, content in sorted((files or {}).items()):
            archive.writestr(name, content)
        if symlinks:
            archive.writestr("SYMLINKS.txt", "".join(
                "%s\u2190./%s\n" % (target, link) for link, target in sorted(symlinks.items())))
    with open(path, "rb") as handle:
        return handle.read()


def pins_for(repository, bootstraps, requested):
    """Unresolved pins (the inputs a human writes) for a synthetic repository."""
    files = {}
    for arch, path in bootstraps.items():
        with open(path, "rb") as handle:
            files[arch] = {"url": pathlib.Path(path).as_uri(),
                           "sha256": hashlib.sha256(handle.read()).hexdigest()}
    return {
        "schema": 2,
        "repository": {"url": repository.url, "suite": "stable"},
        "bootstrap": {"version": "test-bootstrap", "files": files, "packages": {}},
        "requested": list(requested),
        "packages": {},
    }


def write_json(path, value):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2, sort_keys=True)
        handle.write("\n")
