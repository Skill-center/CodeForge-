#!/usr/bin/env python3
"""Drafts the userland's notices from the pinned packages' own licence files.

CodeForge's own (Phase 4 W2). ADR-0011: the userland (bash, git, coreutils, ...)
is an aggregate whose licence texts and source offer are published before any
binary release. Termux's build installs every package's licence under
share/doc/<package>/ (scripts/build/termux_step_install_license.sh):

* for a generic licence, `copyright` is a symlink to ../../LICENSES/<id>.txt
  (shipped by termux-licenses), so the link names the licence exactly;
* for a licence that carries its own copyright line (MIT, BSD, ISC, ...), or
  when the recipe names its licence files, the upstream text itself is there,
  as copyright[.N] or under the upstream name (LICENSE, COPYING, ...).

This script reads those files from the pinned bootstrap and .debs (verified
against runtime/pins.json) and rewrites two generated sections and a file:

* THIRD_PARTY_NOTICES.md, between `<!-- userland:begin -->` and
  `<!-- userland:end -->`: a row per package and version with its licence and
  where the licence text sits in the payload;
* SOURCE_OFFER.md, between `<!-- copyleft:begin -->` and
  `<!-- copyleft:end -->`: the packages under a copyleft licence, whose
  corresponding source the offer covers;
* app/assets/licenses/userland.txt (Phase 5 W1): the texts themselves, for
  the app's licence page. Each distinct text once, after the packages that
  carry it and the paths it has in the payload; a link is followed to its
  text (share/LICENSES/<id>.txt, from termux-licenses), and a text that is
  not in the payload fails the run. Line endings, page breaks, other control
  characters and trailing spaces are normalised; nothing else is changed.

A licence named by Termux's link is exact. One read from a text is identified
by its wording and marked with an asterisk, for the review in W7.

Usage:
    notices.py --cache runtime/generated/cache          rewrite them
    notices.py --cache runtime/generated/cache --check  fail if one is stale

Run `pins.py bootstrap` and `pins.py fetch` for both architectures first.
"""

import argparse
import collections
import importlib.util
import io
import os
import posixpath
import re
import sys
import tarfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


pins_tool = _load("pins", "pins.py")
payload = _load("build_sealed_payload", "build-sealed-payload.py")

NOTICES_MARKERS = ("<!-- userland:begin -->", "<!-- userland:end -->")
OFFER_MARKERS = ("<!-- copyleft:begin -->", "<!-- copyleft:end -->")

# The app's copy of the texts (Phase 5 W1), and the line between its entries:
# box-drawing characters, which no licence text uses (checked when written).
# app/lib/services/runtime/userland_licenses.dart reads it.
APP_LICENCES = os.path.join(ROOT, "app", "assets", "licenses", "userland.txt")
ENTRY_SEPARATOR = "\u2500" * 72

# Names Termux gives licence files: copyright[.N] from its own step, and the
# upstream names a recipe's TERMUX_PKG_LICENSE_FILE copies.
LICENCE_FILE = re.compile(
    r"^(copyright|copying|licen[cs]e|notice|unlicense|artistic|bsdl|gpl|lgpl|mit|"
    r"apache|patents|legal)([._ -].*)?$", re.IGNORECASE)
GENERIC_LINK = re.compile(r"(?:^|/)LICENSES/([^/]+)\.txt$")

# (identifier, phrases that must all appear). Compared in lower case with the
# whitespace collapsed. The full texts' title lines carry their dates, which
# keeps one GNU licence from matching another's mention of it.
FINGERPRINTS = (
    ("AGPL-3.0", ("gnu affero general public license version 3, 19 november 2007",)),
    ("GPL-3.0", ("gnu general public license version 3, 29 june 2007",)),
    ("GPL-2.0", ("gnu general public license version 2, june 1991",)),
    ("LGPL-3.0", ("gnu lesser general public license version 3, 29 june 2007",)),
    ("LGPL-2.1", ("gnu lesser general public license version 2.1, february 1999",)),
    ("LGPL-2.0", ("gnu library general public license version 2, june 1991",)),
    ("GFDL-1.3", ("gnu free documentation license version 1.3",)),
    ("Apache-2.0", ("apache license version 2.0, january 2004",)),
    ("MPL-2.0", ("mozilla public license version 2.0",)),
    ("Artistic-2.0", ("the artistic license 2.0",)),
    ("Artistic-1.0", ("the \"artistic license\"",)),
    ("PSF-2.0", ("python software foundation license version 2",)),
    ("Ruby", ("ruby is copyrighted free software",)),
    ("BSL-1.0", ("boost software license - version 1.0",)),
    ("Unlicense", ("this is free and unencumbered software released into the public domain",)),
    ("curl", ("copyright and permission notice",
              "permission to use, copy, modify, and distribute this software for any purpose "
              "with or without fee is hereby granted")),
    ("ISC", ("permission to use, copy, modify, and/or distribute this software for any "
             "purpose with or without fee is hereby granted",)),
    ("MIT", ("permission is hereby granted, free of charge, to any person obtaining a copy",)),
    ("BSD-3-Clause", ("redistribution and use in source and binary forms",
                      "neither the name")),
    ("BSD-2-Clause", ("redistribution and use in source and binary forms",)),
    ("Zlib", ("this software is provided 'as-is', without any express or implied warranty",)),
    ("Unicode-3.0", ("unicode license v3",)),
    ("Unicode-DFS-2016", ("unicode, inc. license agreement - data files and software",)),
    ("bzip2-1.0.6", ("this program, \"bzip2\", the associated library \"libbzip2\"",)),
)
# Short notices ("... either version 2 of the License, or (at your option)
# any later version"), used only when no full GNU text matched.
NOTICES = (
    ("LGPL-2.1-or-later", ("gnu lesser general public license",
                           "either version 2.1 of the license, or (at your option) any later")),
    ("GPL-3.0-or-later", ("gnu general public license",
                          "either version 3 of the license, or (at your option) any later")),
    ("GPL-2.0-or-later", ("gnu general public license",
                          "either version 2 of the license, or (at your option) any later")),
)
# A licence another one's wording contains is dropped when that one matched.
EXCLUSIVE = {"BSD-2-Clause": ("BSD-3-Clause", "bzip2-1.0.6"), "ISC": ("curl",)}

# Phase 4 W7's review (2026-11-18) of the packages the fingerprints could not
# name. Each entry replaces only what they could not name ("unidentified", or
# no licence file at all), and fails the build once they name it themselves.
# Sources, read on 2026-11-18: the package's Termux recipe (termux-packages,
# TERMUX_PKG_LICENSE; a subpackage takes its parent's) and, at the pinned
# version, the upstream licence file the package ships. A subpackage with no
# licence file of its own points to its parent's texts, which must be in the
# payload. Names follow the table's: the fingerprints' and Termux's.
REVIEWED = {
    # Subpackages that carry no licence file: the parent's identification.
    "bzip2": (("bzip2-1.0.6",), ("share/doc/libbz2/copyright",)),          # libbz2's recipe: BSD
    "curl": (("curl",), ("share/doc/libcurl/copyright",)),                 # libcurl's: MIT (curl's)
    "file": (("BSD-2-Clause",), ("share/doc/libmagic/copyright",)),        # libmagic's
    "gpgv": (("GPL-3.0",), ("share/LICENSES/GPL-3.0.txt",)),               # gnupg's: GPL-3.0
    "libsmartcols": (("LGPL-2.1",),                                        # libsmartcols/COPYING:
                     ("share/doc/util-linux/COPYING.LGPL-2.1-or-later",)),  # LGPL-2.1-or-later
    "ncurses-ui-libs": (("MIT",), ("share/doc/ncurses/copyright",)),       # ncurses's
    "openssh-sftp-server": (("BSD-3-Clause",), ("share/doc/openssh/copyright",)),  # openssh's
    "xz-utils": (("0BSD", "GPL-2.0"),                                      # liblzma's; xz's COPYING:
                 ("share/doc/liblzma/COPYING", "share/doc/liblzma/COPYING.GPLv2")),  # the tools
    # are 0BSD, the xzgrep, xzdiff, xzless and xzmore scripts GPL-2.0-or-later.
    # Texts the fingerprints do not know.
    "libicu": (("Unicode-3.0",), ()),           # ICU 79's LICENSE: the Unicode License V3
    "liblzma": (("0BSD",), ()),                 # xz 5.8.4's COPYING: liblzma is 0BSD
    "lsof": (("lsof",), ()),                    # lsof 4.99.5's COPYING: Purdue's own licence
    "pcre2": (("BSD-3-Clause",), ()),           # COPYING points to LICENCE.md (BSD-3-Clause)
    "ripgrep": (("Unlicense",), ()),            # its UNLICENSE; MIT is the other file
    "termux-core": (("MIT",), ()),              # v0.4.0's LICENSE (a Debian copyright file)
    "termux-exec": (("Apache-2.0",), ()),       # v2.4.0's LICENSE (a Debian copyright file)
    "unzip": (("Info-ZIP",), ()),               # its recipe: BSD (Info-ZIP's licence)
}
COPYLEFT = re.compile(r"^(A?GPL|LGPL|GFDL|MPL|EPL|CDDL|EUPL|OSL|CECILL)", re.IGNORECASE)


def identify(data):
    """Licence identifiers a text's wording matches (possibly several)."""
    text = re.sub(r"\s+", " ", data.decode("utf-8", "replace")).lower()
    found = [name for name, phrases in FINGERPRINTS if all(p in text for p in phrases)]
    found = [name for name in found if not any(other in found for other in EXCLUSIVE.get(name, ()))]
    if not any(name.startswith(("GPL", "LGPL", "AGPL")) for name in found):
        for name, phrases in NOTICES:
            if all(p in text for p in phrases):
                found.append(name)
                break
    return found


class Package:
    """One package as it ships for one architecture."""

    def __init__(self, name, version, homepage, docs, origin):
        self.name = name
        self.version = version
        self.homepage = homepage or ""
        self.docs = docs            # prefix path -> ("link", target) | ("file", bytes)
        self.origin = origin        # "bootstrap" | "pinned"

    def licences(self):
        """[(identifier, exact?)], [(payload path, link target or None)]."""
        own = "share/doc/%s/" % self.name
        candidates = {p: v for p, v in self.docs.items() if p.startswith(own)}
        if not candidates:
            # A subpackage can ship its parent's directory: take whatever
            # share/doc directory the package carries.
            candidates = self.docs
        identifiers, files = [], []
        for path, (kind, value) in sorted(candidates.items()):
            if path.count("/") != 3 or not LICENCE_FILE.match(os.path.basename(path)):
                continue                       # only share/doc/<dir>/<licence file>
            if kind == "link":
                match = GENERIC_LINK.search(value)
                if match:
                    identifiers.append((match.group(1), True))
                    files.append((path, "share/LICENSES/%s.txt" % match.group(1)))
                else:
                    files.append((path, value))
                continue
            found = identify(value)
            identifiers.extend((name, False) for name in found)
            if not found:
                identifiers.append(("unidentified", False))
            files.append((path, None))
        unique = []
        for item in identifiers:
            if item not in unique:
                unique.append(item)
        return unique, files


# Where licence texts live: each package's own directory, and the generic
# texts Termux's links point at.
LICENCE_DIRS = ("share/doc/", "share/LICENSES/")


def bootstrap_packages(zip_path):
    """The bootstrap's packages, and its share/LICENSES files."""
    with zipfile.ZipFile(zip_path) as archive:
        names = archive.namelist()
        status_name = next((n for n in names if n.endswith("var/lib/dpkg/status")), None)
        if status_name is None:
            raise SystemExit("%s has no var/lib/dpkg/status" % zip_path)
        stanzas = pins_tool.t1.parse_stanzas(archive.read(status_name).decode("utf-8", "replace"))
        docs, shared = {}, {}
        for name in names:
            relative = payload.normalize(name)
            if relative.startswith(LICENCE_DIRS) and not name.endswith("/"):
                into = docs if relative.startswith("share/doc/") else shared
                into[relative] = ("file", archive.read(name))
        if "SYMLINKS.txt" in names:
            for line in archive.read("SYMLINKS.txt").decode("utf-8", "replace").splitlines():
                if payload.SYMLINK_SEPARATOR not in line:
                    continue
                target, link = line.split(payload.SYMLINK_SEPARATOR, 1)
                relative = payload.normalize(link.strip())
                if relative.startswith(LICENCE_DIRS):
                    into = docs if relative.startswith("share/doc/") else shared
                    into[relative] = ("link", target.strip())
    packages = {}
    for stanza in stanzas:
        name = stanza.get("Package")
        if not name:
            continue
        prefix = "share/doc/%s/" % name
        own = {p: v for p, v in docs.items() if p.startswith(prefix)}
        packages[name] = Package(name, stanza.get("Version", ""), stanza.get("Homepage"),
                                 own, "bootstrap")
    return packages, shared


def deb_package(path):
    """A pinned package, and the share/LICENSES files it ships."""
    stanzas = pins_tool.t1.parse_stanzas(payload.deb_control(path))
    control = stanzas[0] if stanzas else {}
    docs, shared = {}, {}
    with tarfile.open(fileobj=io.BytesIO(payload.deb_data_tar(path)), mode="r:") as tar:
        for member in tar:
            relative = payload.normalize(member.name)
            if not relative.startswith(LICENCE_DIRS):
                continue
            into = docs if relative.startswith("share/doc/") else shared
            if member.issym():
                into[relative] = ("link", member.linkname)
            elif member.isfile():
                handle = tar.extractfile(member)
                into[relative] = ("file", handle.read() if handle else b"")
    package = Package(control.get("Package", os.path.basename(path).split("_")[0]),
                      control.get("Version", ""), control.get("Homepage"), docs, "pinned")
    return package, shared


def payload_packages(pins, cache, arch):
    """What one architecture's payload holds: the bootstrap, refreshed by the pins.

    Returns the packages by name, and the share/LICENSES files: the
    bootstrap's, with a pinned package's own laid over them, as the payload
    builder lays its files over the bootstrap's.
    """
    bootstrap = pins["bootstrap"]["files"][arch]
    zip_path = os.path.join(cache, "bootstrap", "bootstrap-%s.zip" % arch)
    if not os.path.isfile(zip_path) or pins_tool.sha256_file(zip_path) != bootstrap["sha256"]:
        raise SystemExit("the pinned %s bootstrap is not in %s: run `pins.py bootstrap` first"
                         % (arch, cache))
    packages, shared = bootstrap_packages(zip_path)
    for entry in pins["packages"][arch]:
        path = os.path.join(cache, "debs", arch, os.path.basename(entry["filename"]))
        if not os.path.isfile(path) or pins_tool.sha256_file(path) != entry["sha256"]:
            raise SystemExit("pinned %s %s (%s) is not in %s: run `pins.py fetch` first"
                             % (entry["package"], entry["version"], arch, cache))
        package, own_shared = deb_package(path)
        packages[package.name] = package
        shared.update(own_shared)
    return packages, shared


def cell(text):
    return str(text).replace("|", "\\|").replace("\n", " ")


def review(name, identifiers, files, known):
    """[identifiers], [files] with W7's review applied, where one is recorded."""
    entry = REVIEWED.get(name)
    if entry is None:
        return identifiers, files
    if identifiers and not any(i == "unidentified" for i, _ in identifiers):
        raise SystemExit("notices: the fingerprints now name %s's licence: drop its review "
                         "from REVIEWED" % name)
    licences, parent_texts = entry
    named = [item for item in identifiers if item[0] != "unidentified"]
    reviewed = [(licence, "reviewed") for licence in licences
                if licence not in [i for i, _ in named]]
    if identifiers:
        return reviewed + named, files
    if not parent_texts:
        raise SystemExit("notices: %s carries no licence text, and its review names none" % name)
    missing = [path for path in parent_texts if path not in known]
    if missing:
        raise SystemExit("notices: %s's reviewed licence text %s is not in the payload"
                         % (name, ", ".join(missing)))
    return reviewed, [(path, None) for path in parent_texts]


def licence_text(data):
    """A licence file's text as the app shows it: decoded (UTF-8, else Latin-1),
    with its line endings, page breaks, other control characters and trailing
    spaces normalised."""
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        text = data.decode("latin-1")
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", text)
    return "\n".join(line.rstrip() for line in text.split("\n")).strip("\n")


def resolve_text(index, path, owner, arch):
    """(the path whose bytes are the text, the bytes) for a licence file,
    following links; fails, naming the package, when the text is missing."""
    seen = []
    while True:
        entry = index.get(path)
        if entry is None:
            via = " (through %s)" % " -> ".join(seen) if seen else ""
            raise SystemExit("notices: %s's licence text %s%s is not in the %s payload"
                             % (owner, path, via, arch))
        kind, value = entry
        if kind == "file":
            return path, value
        seen.append(path)
        if len(seen) > 8:
            raise SystemExit("notices: %s's licence file %s is a loop of links"
                             % (owner, seen[0]))
        match = GENERIC_LINK.search(value)
        if match:
            path = "share/LICENSES/%s.txt" % match.group(1)
        elif value.startswith("/"):
            path = payload.normalize(value)
        else:
            path = posixpath.normpath(posixpath.join(posixpath.dirname(path), value))


def collect(pins, cache):
    """Rows merged across architectures: (name, version, licence, files, homepage) -> ABIs;
    the counts per architecture; and the texts: text -> ({(name, version)}, {paths})."""
    rows = collections.OrderedDict()
    counts = {}
    texts = {}
    for arch in sorted(pins_tool.ABIS):
        packages, shared = payload_packages(pins, cache, arch)
        index = dict(shared)
        for package in packages.values():
            index.update(package.docs)
        counts[arch] = (len(packages),
                        sum(1 for p in packages.values() if p.origin == "pinned"))
        # Every licence path the payload carries: the share/doc files, and the
        # share/LICENSES texts Termux's links point at (termux-licenses).
        known = set()
        for package in packages.values():
            for path, (kind, value) in package.docs.items():
                known.add(path)
                if kind == "link":
                    match = GENERIC_LINK.search(value)
                    if match:
                        known.add("share/LICENSES/%s.txt" % match.group(1))
        for package in packages.values():
            identifiers, files = package.licences()
            identifiers, files = review(package.name, identifiers, files, known)
            key = (package.name, package.version, tuple(identifiers), tuple(files),
                   package.homepage)
            rows.setdefault(key, []).append(pins_tool.ABIS[arch])
            for path, _ in files:
                where, data = resolve_text(index, path, package.name, pins_tool.ABIS[arch])
                text = licence_text(data)
                if not text:
                    continue
                if ENTRY_SEPARATOR in text:
                    raise SystemExit("notices: %s's licence text %s contains the app file's "
                                     "entry separator" % (package.name, where))
                carriers, paths = texts.setdefault(text, (set(), set()))
                carriers.add((package.name, package.version))
                paths.add(where)
    ordered = sorted(rows.items(), key=lambda item: (item[0][0].lower(), item[0][1]))
    return ordered, counts, texts


def licence_label(identifiers):
    if not identifiers:
        return "none found"
    marks = {True: "", False: "\\*", "reviewed": "\u2020"}
    return ", ".join(name + marks[exact] for name, exact in identifiers)


def files_label(files):
    if not files:
        return "—"
    return "<br>".join("`%s` → `%s`" % (path, target) if target else "`%s`" % path
                       for path, target in files)


def render_notices(pins, ordered, counts):
    tally = collections.Counter()
    unidentified = []
    for (name, version, identifiers, files, homepage), abis in ordered:
        for identifier, _ in identifiers:
            tally[identifier] += 1
        if not identifiers or any(i == "unidentified" for i, _ in identifiers):
            unidentified.append(name)
    lines = [
        NOTICES_MARKERS[0],
        "<!-- Written by runtime/notices.py from runtime/pins.json and the pinned files. "
        "Do not edit by hand: CI checks it. -->",
        "",
        "**%d package versions** ship in the payloads: the bootstrap `%s` refreshed by the "
        "pinned core set (resolved %s). Per ABI: %s."
        % (len(ordered), pins["bootstrap"]["version"], pins.get("resolvedAt", "never"),
           "; ".join("%s %d packages, %d of them pinned" % (pins_tool.ABIS[arch], total, pinned)
                     for arch, (total, pinned) in sorted(counts.items()))),
        "",
        "Licences, counted per package version: %s."
        % ", ".join("%s %d" % (name, count) for name, count in
                    sorted(tally.items(), key=lambda item: (-item[1], item[0].lower()))),
        "",
        "A licence with an asterisk was identified from its text's wording; one with a "
        "dagger (\u2020) by Phase 4 W7's review, from the licence the package's Termux recipe "
        "declares (runtime/notices.py, `REVIEWED`); the others are named by Termux's link to "
        "`share/LICENSES/<id>.txt`, exactly as Termux names them. The texts ship in the payload "
        "at the paths shown (prefix-relative); a subpackage's is its parent's.",
        "",
    ]
    if unidentified:
        lines += ["**To review:** no licence was identified for %s (CI fails until it is)." %
                  ", ".join("`%s`" % name for name in sorted(set(unidentified))), ""]
    lines += ["| Package | Version | ABIs | Licence | Licence text in the payload | Homepage |",
              "|---|---|---|---|---|---|"]
    for (name, version, identifiers, files, homepage), abis in ordered:
        lines.append("| %s | %s | %s | %s | %s | %s |" % (
            cell(name), cell(version), ", ".join(sorted(abis)),
            cell(licence_label(identifiers)), files_label(files), cell(homepage) or "—"))
    lines += ["", NOTICES_MARKERS[1]]
    return "\n".join(lines)


def render_offer(pins, ordered):
    copyleft = [(key, abis) for key, abis in ordered
                if any(COPYLEFT.match(identifier) for identifier, _ in key[2])]
    lines = [
        OFFER_MARKERS[0],
        "<!-- Written by runtime/notices.py from runtime/pins.json and the pinned files. "
        "Do not edit by hand: CI checks it. -->",
        "",
        "**%d package versions** are under a copyleft licence (GPL, LGPL, AGPL, GFDL, MPL "
        "and the like), identified as in THIRD_PARTY_NOTICES.md. Bootstrap `%s`, pins "
        "resolved %s." % (len(copyleft), pins["bootstrap"]["version"],
                          pins.get("resolvedAt", "never")),
        "",
        "| Package | Version | ABIs | Licence | Homepage |",
        "|---|---|---|---|---|",
    ]
    for (name, version, identifiers, files, homepage), abis in copyleft:
        lines.append("| %s | %s | %s | %s | %s |" % (
            cell(name), cell(version), ", ".join(sorted(abis)),
            cell(licence_label(identifiers)), cell(homepage) or "—"))
    lines += ["", OFFER_MARKERS[1]]
    return "\n".join(lines)


def render_app_licences(pins, texts):
    """app/assets/licenses/userland.txt: each distinct text once, after the
    packages that carry it and its paths in the payload."""
    def order(package):
        return (package[0].lower(), package[0], package[1])

    entries = sorted(((sorted(carriers, key=order), sorted(paths), text)
                      for text, (carriers, paths) in texts.items()),
                     key=lambda entry: ([order(p) for p in entry[0]], entry[1], entry[2]))
    versions = {package for carriers, _, _ in entries for package in carriers}
    lines = [
        "CodeForge's Linux userland: the licence texts its Termux packages carry.",
        "",
        "Written by runtime/notices.py from runtime/pins.json and the pinned files.",
        "Do not edit by hand: CI checks it.",
        "Bootstrap %s, pins resolved %s." % (pins["bootstrap"]["version"],
                                             pins.get("resolvedAt", "never")),
        "%d package versions, %d distinct texts." % (len(versions), len(entries)),
        "",
        "Each entry names the packages (name and version) whose licence files hold",
        "the text, and the text's paths in the payload, then gives the text, with",
        "its line endings, page breaks and trailing spaces normalised.",
    ]
    for carriers, paths, text in entries:
        lines += [
            ENTRY_SEPARATOR,
            "Packages: " + ", ".join("%s %s" % package for package in carriers),
            "Files: " + ", ".join(paths),
            "",
            text,
        ]
    return "\n".join(lines) + "\n"


def replace_section(text, markers, section, path):
    begin, end = markers
    if text.count(begin) != 1 or text.count(end) != 1 or text.index(begin) > text.index(end):
        raise SystemExit("%s needs exactly one %s ... %s section" % (path, begin, end))
    head = text[:text.index(begin)]
    tail = text[text.index(end) + len(end):]
    return head + section + tail


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--pins", default=pins_tool.DEFAULT_PINS)
    parser.add_argument("--cache", required=True)
    parser.add_argument("--notices", default=os.path.join(ROOT, "THIRD_PARTY_NOTICES.md"))
    parser.add_argument("--source-offer", default=os.path.join(ROOT, "SOURCE_OFFER.md"))
    parser.add_argument("--app-licences", default=APP_LICENCES,
                        help="the licence texts for the app's licence page")
    parser.add_argument("--check", action="store_true",
                        help="change nothing; exit 1 when a section is stale")
    arguments = parser.parse_args(argv)

    pins = pins_tool.read_pins(arguments.pins)
    problems = pins_tool.check(pins)
    if problems:
        print("notices: the pins do not pass `pins.py check`:\n  " + "\n  ".join(problems),
              file=sys.stderr)
        return 1
    ordered, counts, texts = collect(pins, arguments.cache)
    stale = []
    for path, markers, section in (
            (arguments.notices, NOTICES_MARKERS, render_notices(pins, ordered, counts)),
            (arguments.source_offer, OFFER_MARKERS, render_offer(pins, ordered)),
            (arguments.app_licences, None, render_app_licences(pins, texts))):
        text = ""
        if markers or os.path.isfile(path):
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
        updated = replace_section(text, markers, section, path) if markers else section
        if updated == text:
            print("notices: %s is current" % os.path.relpath(path, ROOT))
            continue
        if arguments.check:
            stale.append(os.path.relpath(path, ROOT))
            continue
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(updated)
        print("notices: rewrote %s%s" % ("the generated section of " if markers else "",
                                         os.path.relpath(path, ROOT)))
    copyleft = sum(1 for key, _ in ordered if any(COPYLEFT.match(i) for i, _ in key[2]))
    print("notices: %d package versions, %d under a copyleft licence; %d distinct licence texts"
          % (len(ordered), copyleft, len(texts)))
    unnamed = sorted({key[0] for key, _ in ordered
                      if not key[2] or any(i == "unidentified" for i, _ in key[2])})
    if unnamed:
        # Written (or checked) all the same, so the section shows them.
        print("notices: no licence identified for %s: review each and add it to REVIEWED"
              % ", ".join(unnamed), file=sys.stderr)
        return 1
    if stale:
        print("notices: stale: %s. Regenerate with `python3 runtime/notices.py --cache <cache>` "
              "after fetching the pins, or push a [bootstrap] commit (CI rewrites them)."
              % ", ".join(stale), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
