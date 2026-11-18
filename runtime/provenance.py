#!/usr/bin/env python3
"""Checks that native/PROVENANCE.md accounts for every vendored file.

CodeForge's own (Phase 4 W2). AGENTS.md: vendoring requires native/PROVENANCE.md
(repository, commit, licence) and t1's tests passing unchanged. Two tables in
PROVENANCE.md are the record:

* between `<!-- vendored:begin -->` and `<!-- vendored:end -->`, every file
  CodeForge took from t1: its t1 path, the one change made, and the SHA-256 of
  both copies. The change is one of three:
  - `package`: the Java package line renamed from io.mcyber12.sealed to
    dev.codeforge.runtime.sealed, the way t1's scripts/export-sealed-runtime.sh
    does it (the kernel, Phase 4 W2);
  - `rename`: t1's two packages renamed on the `package` and `import` lines
    and nowhere else: io.mcyber12.codingharness.core becomes
    dev.codeforge.runtime.core, and io.mcyber12.sealed becomes
    dev.codeforge.runtime.sealed (the runtime core, Phase 4 W3);
  - `none`: byte for byte;
  and since 2026-11-18 (the owner: CodeForge may change t1's code) a change may
  carry patches after it, `package + t1-0001-runtime-manifest-read.patch`:
  files in native/patches/, written against t1's tree as `git format-patch`
  writes them. They apply to t1's file before the change does;
* between `<!-- own:begin -->` and `<!-- own:end -->`, every file under
  native/ and runtime/ that is CodeForge's own (the patches among them).

`check` proves, offline:

* each vendored file exists and has its recorded SHA-256;
* undoing its recorded change, then taking its patches off, gives t1's
  recorded SHA-256 exactly, so the file differs from t1 in its package (and
  import) lines and its recorded patches, and nowhere else;
* every file under native/ and runtime/ is in exactly one table, so nothing
  arrives unrecorded (generated/, ci-results/ and caches excepted);
* the header names the repository, a full commit and the licence.

`copy --t1 <checkout>` writes every vendored file from a t1 checkout at the
commit PROVENANCE.md names, with its recorded change applied (and t1's file
mode): how the runtime core is copied, since t1's export script covers only
the kernel. `record --t1 <checkout>` then rewrites the vendored table's hashes:
the last step of a re-vendor.

Usage:
    provenance.py check
    provenance.py copy --t1 /path/to/t1
    provenance.py record --t1 /path/to/t1
"""

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.dirname(HERE)
RECORD = "native/PROVENANCE.md"
PATCHES = "native/patches"
SCOPES = ("native", "runtime")
IGNORED_PARTS = {"generated", "ci-results", "__pycache__", "build", ".gradle", ".cxx"}
VENDORED = ("<!-- vendored:begin -->", "<!-- vendored:end -->")
OWN = ("<!-- own:begin -->", "<!-- own:end -->")
T1_PACKAGE = b"package io.mcyber12.sealed;"
CODEFORGE_PACKAGE = b"package dev.codeforge.runtime.sealed;"
# `rename`: t1's package -> CodeForge's, on package and import lines only. The
# longer name first, so that neither replacement can touch the other's result.
RENAMES = ((b"io.mcyber12.codingharness.core", b"dev.codeforge.runtime.core"),
           (b"io.mcyber12.sealed", b"dev.codeforge.runtime.sealed"))
DECLARATION = re.compile(rb"(?m)^(?:package|import)[ \t][^\n]*$")
CHANGES = ("package", "rename", "none")
RENAMED = ("package", "rename")
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
        row = dict(zip(("path", "t1", "cell", "t1_sha", "sha"), cells))
        parts = [part.strip() for part in row["cell"].split("+")]
        row["change"], row["patches"] = parts[0], [part for part in parts[1:] if part]
        rows.append(row)
    return rows


def own_paths(text):
    return [cells[0] for cells in table_rows(section(text, OWN))]


def _declarations(data, pairs):
    """Apply (old, new) replacements on package and import lines only."""
    def replace(match):
        line = match.group(0)
        for old, new in pairs:
            line = line.replace(old, new)
        return line
    return DECLARATION.sub(replace, data)


def forward(data, change):
    """t1's bytes -> CodeForge's: export-sealed-runtime.sh's sed, or the rename."""
    if change == "none":
        return data
    if change == "rename":
        return _declarations(data, RENAMES)
    return re.sub(rb"(?m)^" + re.escape(T1_PACKAGE), CODEFORGE_PACKAGE, data)


def backward(data, change):
    if change == "none":
        return data
    if change == "rename":
        return _declarations(data, [(new, old) for old, new in reversed(RENAMES)])
    return re.sub(rb"(?m)^" + re.escape(CODEFORGE_PACKAGE), T1_PACKAGE, data)


def patch(root, name, t1_path, data, reverse=False):
    """[data], t1's file at [t1_path], with the patch [name] applied (or taken off)."""
    source = os.path.join(root, PATCHES, name)
    if not os.path.isfile(source):
        raise ProvenanceError("%s: the patch %s is not in %s" % (t1_path, name, PATCHES))
    with tempfile.TemporaryDirectory(prefix="codeforge-patch-") as work:
        target = os.path.join(work, t1_path)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "wb") as handle:
            handle.write(data)
        command = ["git", "apply", "--include=" + t1_path]
        if reverse:
            command.append("--reverse")
        command.append(os.path.abspath(source))
        # Never a repository around it: git would apply relative to its root.
        environment = dict(os.environ, GIT_CEILING_DIRECTORIES=os.path.dirname(work))
        try:
            result = subprocess.run(command, cwd=work, capture_output=True, text=True,
                                    env=environment)
        except OSError as error:
            raise ProvenanceError("a patched file needs git to check: %s" % error)
        if result.returncode != 0:
            raise ProvenanceError("%s does not %s %s: %s"
                                  % (name, "come off" if reverse else "apply to", t1_path,
                                     result.stderr.strip()))
        with open(target, "rb") as handle:
            changed = handle.read()
    if changed == data:
        raise ProvenanceError("%s changes nothing in %s" % (name, t1_path))
    return changed


def forward_row(root, row, upstream):
    """t1's file -> CodeForge's: its patches, then its change."""
    data = upstream
    for name in row["patches"]:
        data = patch(root, name, row["t1"], data)
    return forward(data, row["change"])


def backward_row(root, row, ours):
    """CodeForge's file -> t1's: its change undone, then its patches taken off."""
    data = backward(ours, row["change"])
    for name in reversed(row["patches"]):
        data = patch(root, name, row["t1"], data, reverse=True)
    return data


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
        if row["change"] == "rename":
            if b"io.mcyber12" in data or not re.search(rb"(?m)^package dev\.codeforge\.", data):
                problems.append("%s: expected a `package dev.codeforge...` line and no "
                                "io.mcyber12 anywhere (a t1 name outside a package or "
                                "import line cannot be renamed)" % label)
        try:
            original = backward_row(root, row, data)
        except ProvenanceError as error:
            problems.append("%s: %s" % (label, error))
            continue
        if sha256(original) != row["t1_sha"]:
            problems.append("%s differs from t1's %s beyond the recorded change (%s)"
                            % (label, row["t1"], row["cell"]))
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


def _checkout_matches(text, t1_root):
    """The record's text; refuses a t1 checkout at another commit."""
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


def copy(root, t1_root):
    """Every vendored file from t1, with its recorded change and t1's mode."""
    with open(os.path.join(root, RECORD), encoding="utf-8") as handle:
        text = handle.read()
    _checkout_matches(text, t1_root)
    count = 0
    for row in vendored_rows(text):
        if row["change"] not in CHANGES:
            raise ProvenanceError("%s: change %r is not one of %s"
                                  % (row["path"], row["change"], ", ".join(CHANGES)))
        source = os.path.join(t1_root, row["t1"])
        with open(source, "rb") as handle:
            upstream = handle.read()
        ours = forward_row(root, row, upstream)
        if row["change"] == "rename" and b"io.mcyber12" in ours:
            raise ProvenanceError("%s names a t1 package outside its package and import "
                                  "lines, which the rename does not reach: it cannot be "
                                  "vendored unchanged" % row["t1"])
        target = os.path.join(root, row["path"])
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "wb") as handle:
            handle.write(ours)
        shutil.copymode(source, target)
        count += 1
    return count


def record(root, t1_root):
    path = os.path.join(root, RECORD)
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    _checkout_matches(text, t1_root)
    lines = list(VENDORED_HEADER)
    for row in vendored_rows(text):
        if row["change"] not in CHANGES:
            raise ProvenanceError("%s: change %r is not one of %s"
                                  % (row["path"], row["change"], ", ".join(CHANGES)))
        with open(os.path.join(t1_root, row["t1"]), "rb") as handle:
            upstream = handle.read()
        with open(os.path.join(root, row["path"]), "rb") as handle:
            ours = handle.read()
        if forward_row(root, row, upstream) != ours:
            raise ProvenanceError("%s is not t1's %s with the change %s applied: copy it again "
                                  "(`provenance.py copy`)" % (row["path"], row["t1"], row["cell"]))
        lines.append("| `%s` | `%s` | %s | `%s` | `%s` |"
                     % (row["path"], row["t1"], row["cell"], sha256(upstream), sha256(ours)))
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
    for name in ("copy", "record"):
        command = commands.add_parser(name)
        command.add_argument("--t1", required=True, help="a t1 checkout at the recorded commit")
    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "copy":
            count = copy(arguments.root, arguments.t1)
            print("provenance: copied %d vendored files" % count)
            return 0
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
    renamed = sum(1 for row in rows if row["change"] in RENAMED)
    patched = sum(1 for row in rows if row["patches"])
    print("provenance: OK - %d vendored files (%d with the package renamed, %d byte for byte; "
          "%d patched) and %d of CodeForge's own"
          % (len(rows), renamed, len(rows) - renamed, patched, len(own)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
