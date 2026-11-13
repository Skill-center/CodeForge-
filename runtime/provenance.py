#!/usr/bin/env python3
"""Checks that native/PROVENANCE.md accounts for every vendored file.

CodeForge's own (Phase 4 W2). AGENTS.md: vendoring requires native/PROVENANCE.md
(repository, commit, licence) and t1's tests passing unchanged. Two tables in
PROVENANCE.md are the record:

* between `<!-- vendored:begin -->` and `<!-- vendored:end -->`, every file
  CodeForge took from t1: its t1 path, the one change made, and the SHA-256 of
  both copies. The only change is `package`: the Java package line renamed
  from io.mcyber12.sealed to dev.codeforge.runtime.sealed, the way t1's
  scripts/export-sealed-runtime.sh does it; `none` means byte for byte;
* between `<!-- own:begin -->` and `<!-- own:end -->`, every file under
  native/ and runtime/ that is CodeForge's own.

`check` proves, offline:

* each vendored file exists and has its recorded SHA-256;
* undoing its recorded change gives t1's recorded SHA-256 exactly, so the file
  differs from t1 in its package line and nowhere else;
* every file under native/ and runtime/ is in exactly one table, so nothing
  arrives unrecorded (generated/, ci-results/ and caches excepted);
* the header names the repository, a full commit and the licence.

`record --t1 <checkout>` rewrites the vendored table's hashes from a t1
checkout at the commit PROVENANCE.md names: the last step of a re-vendor.

Usage:
    provenance.py check
    provenance.py record --t1 /path/to/t1
"""

import argparse
import hashlib
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.dirname(HERE)
RECORD = "native/PROVENANCE.md"
SCOPES = ("native", "runtime")
IGNORED_PARTS = {"generated", "ci-results", "__pycache__", "build", ".gradle"}
VENDORED = ("<!-- vendored:begin -->", "<!-- vendored:end -->")
OWN = ("<!-- own:begin -->", "<!-- own:end -->")
T1_PACKAGE = b"package io.mcyber12.sealed;"
CODEFORGE_PACKAGE = b"package dev.codeforge.runtime.sealed;"
CHANGES = ("package", "none")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
VENDORED_HEADER = ("| CodeForge file | t1 file | Change | t1 SHA-256 | CodeForge SHA-256 |",
                   "|---|---|---|---|---|")


class ProvenanceError(Exception):
    pass


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def section(text, markers):
    begin, end = markers
    if text.count(begin) != 1 or text.count(end) != 1 or text.index(begin) > text.index(end):
        raise ProvenanceError("%s needs exactly one %s ... %s section" % (RECORD, begin, end))
    return text[text.index(begin) + len(begin):text.index(end)]


def code(cell):
    cell = cell.strip()
    if cell.startswith("`") and cell.endswith("`"):
        cell = cell[1:-1]
    return cell


def table_rows(block):
    rows = []
    for line in block.splitlines():
        line = line.strip()
        if not line.startswith("|") or line.startswith("|---"):
            continue
        cells = [code(cell) for cell in line.strip("|").split("|")]
        if cells[0] in ("CodeForge file",):
            continue
        rows.append(cells)
    return rows


def vendored_rows(text):
    rows = []
    for cells in table_rows(section(text, VENDORED)):
        if len(cells) != 5:
            raise ProvenanceError("a vendored row needs 5 cells: %s" % " | ".join(cells))
        rows.append(dict(zip(("path", "t1", "change", "t1_sha", "sha"), cells)))
    return rows


def own_paths(text):
    return [cells[0] for cells in table_rows(section(text, OWN))]


def forward(data, change):
    """t1's bytes -> CodeForge's, exactly as export-sealed-runtime.sh's sed."""
    if change == "none":
        return data
    return re.sub(rb"(?m)^" + re.escape(T1_PACKAGE), CODEFORGE_PACKAGE, data)


def backward(data, change):
    if change == "none":
        return data
    return re.sub(rb"(?m)^" + re.escape(CODEFORGE_PACKAGE), T1_PACKAGE, data)


def files_in_scope(root):
    found = []
    for scope in SCOPES:
        for directory, subdirectories, files in os.walk(os.path.join(root, scope)):
            subdirectories[:] = sorted(d for d in subdirectories if d not in IGNORED_PARTS)
            for name in sorted(files):
                if name.endswith((".pyc", ".part")):
                    continue
                found.append(os.path.relpath(os.path.join(directory, name), root)
                             .replace(os.sep, "/"))
    return found


def header_problems(text):
    problems = []
    if not re.search(r"^- \*\*Repository:\*\* https://github\.com/\S+", text, re.M):
        problems.append("the header has no `- **Repository:** https://github.com/...` line")
    if not re.search(r"^- \*\*Commit:\*\* `?[0-9a-f]{40}`?", text, re.M):
        problems.append("the header has no `- **Commit:**` line with a full 40-digit sha")
    if not re.search(r"^- \*\*Licence:\*\* .*Apache-2\.0", text, re.M):
        problems.append("the header has no `- **Licence:**` line naming Apache-2.0")
    return problems


def check(root):
    path = os.path.join(root, RECORD)
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    problems = header_problems(text)
    rows = vendored_rows(text)
    own = own_paths(text)
    listed = {}
    for row in rows:
        label = row["path"]
        if row["change"] not in CHANGES:
            problems.append("%s: change %r is not one of %s" % (label, row["change"],
                                                               ", ".join(CHANGES)))
            continue
        if not HEX64.match(row["t1_sha"]) or not HEX64.match(row["sha"]):
            problems.append("%s: both SHA-256 cells need 64 hex digits (run `record`)" % label)
            continue
        listed[label] = "vendored"
        file_path = os.path.join(root, label)
        if not os.path.isfile(file_path):
            problems.append("%s is listed as vendored but does not exist" % label)
            continue
        with open(file_path, "rb") as handle:
            data = handle.read()
        if sha256(data) != row["sha"]:
            problems.append("%s changed: its SHA-256 is %s, PROVENANCE records %s. A vendored "
                            "file changes only by re-vendoring (PROVENANCE.md, \"Re-vendoring\")"
                            % (label, sha256(data), row["sha"]))
            continue
        if row["change"] == "package":
            if data.count(CODEFORGE_PACKAGE) != 1 or b"io.mcyber12" in data:
                problems.append("%s: expected exactly one `%s` line and no io.mcyber12"
                                % (label, CODEFORGE_PACKAGE.decode()))
        if sha256(backward(data, row["change"])) != row["t1_sha"]:
            problems.append("%s differs from t1's %s beyond the recorded change (%s)"
                            % (label, row["t1"], row["change"]))
    for label in own:
        if label in listed:
            problems.append("%s is listed both as vendored and as CodeForge's own" % label)
        listed[label] = "own"
        if not os.path.isfile(os.path.join(root, label)):
            problems.append("%s is listed as CodeForge's own but does not exist" % label)
    for label in files_in_scope(root):
        if label not in listed:
            problems.append("%s is not in PROVENANCE.md: add it to the vendored table (with "
                            "`record`) or to CodeForge's own" % label)
    return problems, rows, own


def record(root, t1_root):
    path = os.path.join(root, RECORD)
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    commit = re.search(r"^- \*\*Commit:\*\* `?([0-9a-f]{40})`?", text, re.M)
    if not commit:
        raise ProvenanceError("PROVENANCE.md names no full commit")
    try:
        head = subprocess.run(["git", "-C", t1_root, "rev-parse", "HEAD"], capture_output=True,
                              text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        head = None
    if head is not None and head != commit.group(1):
        raise ProvenanceError("the t1 checkout is at %s; PROVENANCE.md names %s"
                              % (head, commit.group(1)))
    lines = list(VENDORED_HEADER)
    for row in vendored_rows(text):
        if row["change"] not in CHANGES:
            raise ProvenanceError("%s: change %r is not one of %s"
                                  % (row["path"], row["change"], ", ".join(CHANGES)))
        with open(os.path.join(t1_root, row["t1"]), "rb") as handle:
            upstream = handle.read()
        with open(os.path.join(root, row["path"]), "rb") as handle:
            ours = handle.read()
        if forward(upstream, row["change"]) != ours:
            raise ProvenanceError("%s is not t1's %s with the change %s applied: copy it again "
                                  "(export-sealed-runtime.sh for the Java files)"
                                  % (row["path"], row["t1"], row["change"]))
        lines.append("| `%s` | `%s` | %s | `%s` | `%s` |"
                     % (row["path"], row["t1"], row["change"], sha256(upstream), sha256(ours)))
    begin, end = VENDORED
    updated = (text[:text.index(begin) + len(begin)] + "\n" + "\n".join(lines) + "\n"
               + text[text.index(end):])
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(updated)
    return len(lines) - 2


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=DEFAULT_ROOT, help="the repository's root")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check")
    command = commands.add_parser("record")
    command.add_argument("--t1", required=True, help="a t1 checkout at the recorded commit")
    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "record":
            count = record(arguments.root, arguments.t1)
            print("provenance: recorded %d vendored files" % count)
            return 0
        problems, rows, own = check(arguments.root)
    except (ProvenanceError, OSError) as error:
        print("provenance: %s" % error, file=sys.stderr)
        return 1
    for problem in problems:
        print("provenance: %s" % problem, file=sys.stderr)
    if problems:
        print("provenance: %d problem(s)" % len(problems), file=sys.stderr)
        return 1
    renamed = sum(1 for row in rows if row["change"] == "package")
    print("provenance: OK - %d vendored files (%d with the package renamed, %d byte for byte) "
          "and %d of CodeForge's own" % (len(rows), renamed, len(rows) - renamed, len(own)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
