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
against runtime/pins.json) and rewrites two generated sections:

* THIRD_PARTY_NOTICES.md, between `<!-- userland:begin -->` and
  `<!-- userland:end -->`: a row per package and version with its licence and
  where the licence text sits in the payload;
* SOURCE_OFFER.md, between `<!-- copyleft:begin -->` and
  `<!-- copyleft:end -->`: the packages under a copyleft licence, whose
  corresponding source the offer covers.

A licence named by Termux's link is exact. One read from a text is identified
by its wording and marked with an asterisk, for the review in W7.

Usage:
    notices.py --cache runtime/generated/cache          rewrite the sections
    notices.py --cache runtime/generated/cache --check  fail if they are stale

Run `pins.py bootstrap` and `pins.py fetch` for both architectures first.
"""

import argparse
import collections
import importlib.util
import io
import os
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
EXCLUSIVE = {"BSD-2-Clause": "BSD-3-Clause", "ISC": "curl"}
COPYLEFT = re.compile(r"^(A?GPL|LGPL|GFDL|MPL|EPL|CDDL|EUPL|OSL|CECILL)", re.IGNORECASE)


def identify(data):
    """Licence identifiers a text's wording matches (possibly several)."""
    text = re.sub(r"\s+", " ", data.decode("utf-8", "replace")).lower()
    found = [name for name, phrases in FINGERPRINTS if all(p in text for p in phrases)]
    found = [name for name in found if EXCLUSIVE.get(name) not in found]
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


def bootstrap_packages(zip_path):
    with zipfile.ZipFile(zip_path) as archive:
        names = archive.namelist()
        status_name = next((n for n in names if n.endswith("var/lib/dpkg/status")), None)
        if status_name is None:
            raise SystemExit("%s has no var/lib/dpkg/status" % zip_path)
        stanzas = pins_tool.t1.parse_stanzas(archive.read(status_name).decode("utf-8", "replace"))
        docs = {}
        for name in names:
            relative = payload.normalize(name)
            if relative.startswith("share/doc/") and not name.endswith("/"):
                docs[relative] = ("file", archive.read(name))
        if "SYMLINKS.txt" in names:
            for line in archive.read("SYMLINKS.txt").decode("utf-8", "replace").splitlines():
                if payload.SYMLINK_SEPARATOR not in line:
                    continue
                target, link = line.split(payload.SYMLINK_SEPARATOR, 1)
                relative = payload.normalize(link.strip())
                if relative.startswith("share/doc/"):
                    docs[relative] = ("link", target.strip())
    packages = {}
    for stanza in stanzas:
        name = stanza.get("Package")
        if not name:
            continue
        prefix = "share/doc/%s/" % name
        own = {p: v for p, v in docs.items() if p.startswith(prefix)}
        packages[name] = Package(name, stanza.get("Version", ""), stanza.get("Homepage"),
                                 own, "bootstrap")
    return packages


def deb_package(path):
    stanzas = pins_tool.t1.parse_stanzas(payload.deb_control(path))
    control = stanzas[0] if stanzas else {}
    docs = {}
    with tarfile.open(fileobj=io.BytesIO(payload.deb_data_tar(path)), mode="r:") as tar:
        for member in tar:
            relative = payload.normalize(member.name)
            if not relative.startswith("share/doc/"):
                continue
            if member.issym():
                docs[relative] = ("link", member.linkname)
            elif member.isfile():
                handle = tar.extractfile(member)
                docs[relative] = ("file", handle.read() if handle else b"")
    return Package(control.get("Package", os.path.basename(path).split("_")[0]),
                   control.get("Version", ""), control.get("Homepage"), docs, "pinned")


def payload_packages(pins, cache, arch):
    """What one architecture's payload holds: the bootstrap, refreshed by the pins."""
    bootstrap = pins["bootstrap"]["files"][arch]
    zip_path = os.path.join(cache, "bootstrap", "bootstrap-%s.zip" % arch)
    if not os.path.isfile(zip_path) or pins_tool.sha256_file(zip_path) != bootstrap["sha256"]:
        raise SystemExit("the pinned %s bootstrap is not in %s: run `pins.py bootstrap` first"
                         % (arch, cache))
    packages = bootstrap_packages(zip_path)
    for entry in pins["packages"][arch]:
        path = os.path.join(cache, "debs", arch, os.path.basename(entry["filename"]))
        if not os.path.isfile(path) or pins_tool.sha256_file(path) != entry["sha256"]:
            raise SystemExit("pinned %s %s (%s) is not in %s: run `pins.py fetch` first"
                             % (entry["package"], entry["version"], arch, cache))
        package = deb_package(path)
        packages[package.name] = package
    return packages


def cell(text):
    return str(text).replace("|", "\\|").replace("\n", " ")


def collect(pins, cache):
    """Rows merged across architectures: (name, version, licence, files, homepage) -> ABIs."""
    rows = collections.OrderedDict()
    counts = {}
    for arch in sorted(pins_tool.ABIS):
        packages = payload_packages(pins, cache, arch)
        counts[arch] = (len(packages),
                        sum(1 for p in packages.values() if p.origin == "pinned"))
        for package in packages.values():
            identifiers, files = package.licences()
            key = (package.name, package.version, tuple(identifiers), tuple(files),
                   package.homepage)
            rows.setdefault(key, []).append(pins_tool.ABIS[arch])
    ordered = sorted(rows.items(), key=lambda item: (item[0][0].lower(), item[0][1]))
    return ordered, counts


def licence_label(identifiers):
    if not identifiers:
        return "none found"
    return ", ".join(name if exact else name + "\\*" for name, exact in identifiers)


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
        "A licence with an asterisk was identified from its text's wording; the others are "
        "named by Termux's link to `share/LICENSES/<id>.txt`, exactly as Termux names them. "
        "The texts ship in the payload at the paths shown (prefix-relative).",
        "",
    ]
    if unidentified:
        lines += ["**To review (W7):** no licence was identified for %s." %
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
    parser.add_argument("--check", action="store_true",
                        help="change nothing; exit 1 when a section is stale")
    arguments = parser.parse_args(argv)

    pins = pins_tool.read_pins(arguments.pins)
    problems = pins_tool.check(pins)
    if problems:
        print("notices: the pins do not pass `pins.py check`:\n  " + "\n  ".join(problems),
              file=sys.stderr)
        return 1
    ordered, counts = collect(pins, arguments.cache)
    stale = []
    for path, markers, section in (
            (arguments.notices, NOTICES_MARKERS, render_notices(pins, ordered, counts)),
            (arguments.source_offer, OFFER_MARKERS, render_offer(pins, ordered))):
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        updated = replace_section(text, markers, section, path)
        if updated == text:
            print("notices: %s is current" % os.path.relpath(path, ROOT))
            continue
        if arguments.check:
            stale.append(os.path.relpath(path, ROOT))
            continue
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(updated)
        print("notices: rewrote the generated section of %s" % os.path.relpath(path, ROOT))
    copyleft = sum(1 for key, _ in ordered if any(COPYLEFT.match(i) for i, _ in key[2]))
    print("notices: %d package versions, %d under a copyleft licence" % (len(ordered), copyleft))
    if stale:
        print("notices: stale: %s. Regenerate with `python3 runtime/notices.py --cache <cache>` "
              "after fetching the pins, or push a [bootstrap] commit (CI rewrites them)."
              % ", ".join(stale), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
