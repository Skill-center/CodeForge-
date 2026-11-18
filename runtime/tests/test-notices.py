#!/usr/bin/env python3
"""Tests for runtime/notices.py (CodeForge's own, Phase 4 W2).

Builds a synthetic repository and bootstrap in Termux's layout, pins and
fetches them with runtime/pins.py, and checks the drafted notices:

  * a licence Termux links to share/LICENSES/<id>.txt is named exactly;
  * a licence text is identified by its wording (and marked), including the
    GNU texts that mention each other, BSD's clause count and short notices;
  * a pinned package replaces the bootstrap's copy;
  * a package without a licence file is listed for review;
  * only copyleft packages reach the source offer;
  * the sections are rewritten in place, and --check reports them stale;
  * the app's licence file holds each text once, after the packages that
    carry it, following links to share/LICENSES and failing closed when a
    text is not in the payload (Phase 5 W1).

Run: python3 runtime/tests/test-notices.py
"""

import contextlib
import importlib.util
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
RUNTIME = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import fixtures  # noqa: E402

_spec = importlib.util.spec_from_file_location("notices", os.path.join(RUNTIME, "notices.py"))
notices = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(notices)

GPL2 = b"""                    GNU GENERAL PUBLIC LICENSE
                       Version 2, June 1991
 Some other Free Software Foundation software is covered by
the GNU Lesser General Public License instead."""
LGPL21 = b"""                  GNU LESSER GENERAL PUBLIC LICENSE
                       Version 2.1, February 1999
  This license, the Lesser General Public License, applies to some
specially designated software ... the GNU General Public License"""
MIT = b"""Copyright (c) 2020 Someone
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software")"""
BSD3 = b"""Redistribution and use in source and binary forms, with or without
modification, are permitted provided that ...
3. Neither the name of the copyright holder nor the names of its contributors"""
BSD2 = b"""Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met"""
GPL3 = b"""                    GNU GENERAL PUBLIC LICENSE\r
                       Version 3, 29 June 2007\r
\x0c\r
 Everyone is permitted to copy and distribute verbatim copies   \r
"""
GPL3_NOTICE = b"""This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version."""

NOTICES_TEMPLATE = "# Notices\n\nHand-written.\n\n<!-- userland:begin -->\nold\n<!-- userland:end -->\n\nTail.\n"
OFFER_TEMPLATE = "# Offer\n\n<!-- copyleft:begin -->\n<!-- copyleft:end -->\n"


class IdentifyTest(unittest.TestCase):

    def test_gnu_texts_do_not_match_each_other(self):
        self.assertEqual(notices.identify(GPL2), ["GPL-2.0"])
        self.assertEqual(notices.identify(LGPL21), ["LGPL-2.1"])

    def test_bsd_clause_count(self):
        self.assertEqual(notices.identify(BSD3), ["BSD-3-Clause"])
        self.assertEqual(notices.identify(BSD2), ["BSD-2-Clause"])

    def test_permissive_and_notices(self):
        self.assertEqual(notices.identify(MIT), ["MIT"])
        self.assertEqual(notices.identify(GPL3_NOTICE), ["GPL-3.0-or-later"])
        self.assertEqual(notices.identify(b"All rights reserved."), [])

    def test_several_texts_in_one_file(self):
        self.assertEqual(notices.identify(MIT + b"\n\n" + GPL2), ["GPL-2.0", "MIT"])


class NoticesTest(unittest.TestCase):

    def setUp(self):
        self.work = tempfile.mkdtemp(prefix="codeforge-notices-")
        self.addCleanup(shutil.rmtree, self.work, True)
        repo = fixtures.Repository(os.path.join(self.work, "repo"))
        repo.add("git", "2.51.0", files={"bin/git": b"\x7fELF git",
                                         "share/doc/git/README": b"not a licence"},
                 links={"share/doc/git/copyright": "../../LICENSES/GPL-2.0.txt"},
                 depends="libcurl, zlib", homepage="https://git-scm.com/")
        repo.add("libcurl", "8.11.0", files={"lib/libcurl.so": b"\x7fELF curl",
                                             "share/doc/libcurl/copyright": MIT},
                 homepage="https://curl.se/")
        repo.add("zlib", "1.3.1", files={"lib/libz.so": b"\x7fELF z new",
                                         "share/doc/zlib/LICENSE": BSD3})
        repo.add("mystery", "1.0", files={"bin/mystery": b"\x7fELF ?"})
        bootstraps = {}
        for arch in fixtures.ARCHES:
            bootstraps[arch] = os.path.join(self.work, "bootstrap-%s.zip" % arch)
            fixtures.make_bootstrap(
                bootstraps[arch],
                {"bash": ("5.2.37", "https://www.gnu.org/software/bash/"),
                 "zlib": ("1.3.0", None),
                 "libandroid": ("0.1", None)},
                files={"share/doc/zlib/LICENSE": BSD3,
                       "share/doc/libandroid/copyright": LGPL21,
                       # termux-licenses' generic texts, which Termux's links name.
                       "share/LICENSES/GPL-2.0.txt": GPL2,
                       "share/LICENSES/GPL-3.0.txt": GPL3},
                symlinks={"share/doc/bash/copyright": "../../LICENSES/GPL-3.0.txt"})
        self.pins_path = os.path.join(self.work, "pins.json")
        fixtures.write_json(self.pins_path, fixtures.pins_for(repo, bootstraps,
                                                              ["git", "mystery"]))
        self.cache = os.path.join(self.work, "cache")
        pins_script = os.path.join(RUNTIME, "pins.py")
        steps = [["resolve", "--cache", self.cache]]
        for arch in fixtures.ARCHES:
            steps.append(["bootstrap", "--arch", arch, "--cache", self.cache,
                          "--out", os.path.join(self.work, "b")])
            steps.append(["fetch", "--arch", arch, "--cache", self.cache,
                          "--out", os.path.join(self.work, "debs", arch)])
        for step in steps:
            result = subprocess.run([sys.executable, pins_script, "--pins", self.pins_path]
                                    + step, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.notices_path = os.path.join(self.work, "THIRD_PARTY_NOTICES.md")
        self.offer_path = os.path.join(self.work, "SOURCE_OFFER.md")
        # Never the repository's own file.
        self.app_path = os.path.join(self.work, "app", "userland.txt")
        with open(self.notices_path, "w") as handle:
            handle.write(NOTICES_TEMPLATE)
        with open(self.offer_path, "w") as handle:
            handle.write(OFFER_TEMPLATE)

    def run_notices(self, *extra):
        # Quiet: CI's digest reads this test's output.
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return notices.main(["--pins", self.pins_path, "--cache", self.cache,
                                 "--notices", self.notices_path,
                                 "--source-offer", self.offer_path,
                                 "--app-licences", self.app_path] + list(extra))

    def read(self, path):
        with open(path, encoding="utf-8") as handle:
            return handle.read()

    def reviewed(self):
        # W7's review, as REVIEWED records one: mystery ships no licence file,
        # so it points to a text another package carries.
        return mock.patch.dict(notices.REVIEWED,
                               {"mystery": (("BSD-3-Clause",), ("share/doc/zlib/LICENSE",))})

    def row(self, text, name):
        rows = [line for line in text.splitlines() if line.startswith("| %s |" % name)]
        self.assertEqual(len(rows), 1, "one row for %s in:\n%s" % (name, text))
        return rows[0]

    def test_the_sections_are_drafted_from_the_licence_files(self):
        # mystery's licence is unnamed: the sections are written all the same,
        # showing it, and the run fails.
        self.assertEqual(self.run_notices(), 1)
        text = self.read(self.notices_path)
        self.assertTrue(text.startswith("# Notices\n\nHand-written.\n\n<!-- userland:begin -->"))
        self.assertTrue(text.endswith("<!-- userland:end -->\n\nTail.\n"))
        self.assertNotIn("\nold\n", text)
        git = self.row(text, "git")
        self.assertIn("| 2.51.0 | arm64-v8a, x86_64 | GPL-2.0 |", git)
        self.assertIn("`share/doc/git/copyright` → `share/LICENSES/GPL-2.0.txt`", git)
        self.assertNotIn("README", git)
        self.assertIn("https://git-scm.com/", git)
        self.assertIn("| MIT\\* |", self.row(text, "libcurl"))
        self.assertIn("| GPL-3.0 |", self.row(text, "bash"))
        self.assertIn("| LGPL-2.1\\* |", self.row(text, "libandroid"))
        # The pinned zlib replaces the bootstrap's 1.3.0.
        self.assertIn("| 1.3.1 |", self.row(text, "zlib"))
        self.assertNotIn("1.3.0", text)
        self.assertIn("| none found |", self.row(text, "mystery"))
        self.assertIn("**To review:** no licence was identified for `mystery` "
                      "(CI fails until it is).", text)
        self.assertIn("**6 package versions** ship in the payloads", text)

    def test_a_review_completes_the_table(self):
        with self.reviewed():
            self.assertEqual(self.run_notices(), 0)
        text = self.read(self.notices_path)
        self.assertIn("| BSD-3-Clause\u2020 | `share/doc/zlib/LICENSE` |", self.row(text, "mystery"))
        self.assertNotIn("To review", text)

    def test_only_copyleft_reaches_the_source_offer(self):
        with self.reviewed():
            self.assertEqual(self.run_notices(), 0)
        offer = self.read(self.offer_path)
        for name in ("git", "bash", "libandroid"):
            self.row(offer, name)
        for name in ("libcurl", "zlib", "mystery"):
            self.assertNotIn("| %s |" % name, offer)
        self.assertIn("**3 package versions** are under a copyleft licence", offer)

    def test_check_reports_stale_sections_and_changes_nothing(self):
        with self.reviewed():
            self.assertEqual(self.run_notices("--check"), 1)
            self.assertEqual(self.read(self.notices_path), NOTICES_TEMPLATE)
            self.assertFalse(os.path.exists(self.app_path))
            self.assertEqual(self.run_notices(), 0)
            self.assertEqual(self.run_notices("--check"), 0)
            # The app's file alone, edited by hand, is stale too.
            with open(self.app_path, "a", encoding="utf-8") as handle:
                handle.write("edited\n")
            edited = self.read(self.app_path)
            self.assertEqual(self.run_notices("--check"), 1)
            self.assertEqual(self.read(self.app_path), edited)

    def test_the_output_is_stable(self):
        with self.reviewed():
            self.assertEqual(self.run_notices(), 0)
            first = (self.read(self.notices_path), self.read(self.offer_path),
                     self.read(self.app_path))
            self.assertEqual(self.run_notices(), 0)
        self.assertEqual((self.read(self.notices_path), self.read(self.offer_path),
                          self.read(self.app_path)), first)

    def app_entries(self):
        """The app file's entries: (packages line, files line, text)."""
        sections = self.read(self.app_path).split("\n%s\n" % notices.ENTRY_SEPARATOR)
        entries = []
        for section in sections[1:]:
            lines = section.rstrip("\n").split("\n")
            self.assertTrue(lines[0].startswith("Packages: "), section)
            self.assertTrue(lines[1].startswith("Files: "), section)
            self.assertEqual(lines[2], "", section)
            entries.append((lines[0][len("Packages: "):], lines[1][len("Files: "):],
                            "\n".join(lines[3:])))
        return sections[0], entries

    def test_the_app_gets_each_text_once_after_the_packages_that_carry_it(self):
        with self.reviewed():
            self.assertEqual(self.run_notices(), 0)
        preamble, entries = self.app_entries()
        self.assertIn("\n6 package versions, 5 distinct texts.\n", preamble)
        by_packages = {packages: (files, text) for packages, files, text in entries}
        self.assertEqual(len(by_packages), 5)
        # A link is followed to termux-licenses' text.
        self.assertEqual(by_packages["git 2.51.0"][0], "share/LICENSES/GPL-2.0.txt")
        self.assertEqual(by_packages["git 2.51.0"][1], GPL2.decode())
        self.assertEqual(by_packages["bash 5.2.37"][0], "share/LICENSES/GPL-3.0.txt")
        # A text another package carries is listed once, under both (mystery's
        # review points to zlib's), in name order.
        self.assertEqual(by_packages["mystery 1.0, zlib 1.3.1"][0], "share/doc/zlib/LICENSE")
        self.assertEqual(by_packages["mystery 1.0, zlib 1.3.1"][1], BSD3.decode())
        self.assertEqual(by_packages["libcurl 8.11.0"][1], MIT.decode())
        self.assertEqual(by_packages["libandroid 0.1"][0], "share/doc/libandroid/copyright")
        # The bootstrap's zlib 1.3.0 was replaced, and a README is no licence.
        self.assertNotIn("1.3.0", self.read(self.app_path))
        self.assertNotIn("not a licence", self.read(self.app_path))

    def test_the_app_texts_are_normalised(self):
        with self.reviewed():
            self.assertEqual(self.run_notices(), 0)
        _, entries = self.app_entries()
        bash = [text for packages, _, text in entries if packages == "bash 5.2.37"][0]
        # GPL3's CRLF endings, its page break and its trailing spaces are gone;
        # its indentation stays.
        self.assertEqual(bash, "                    GNU GENERAL PUBLIC LICENSE\n"
                               "                       Version 3, 29 June 2007\n"
                               "\n"
                               " Everyone is permitted to copy and distribute verbatim copies")
        self.assertNotIn("\r", self.read(self.app_path))

    def test_a_missing_section_is_an_error(self):
        with open(self.offer_path, "w") as handle:
            handle.write("# Offer without markers\n")
        with self.assertRaises(SystemExit):
            self.run_notices()


class AppTextsTest(unittest.TestCase):

    INDEX = {
        "share/doc/a/copyright": ("link", "../../LICENSES/GPL-3.0.txt"),
        "share/doc/b/copyright": ("link", "../a/copyright"),
        "share/doc/c/copyright": ("link", "/data/data/com.termux/files/usr/share/doc/d/LICENSE"),
        "share/doc/d/LICENSE": ("file", b"d's own"),
        "share/LICENSES/GPL-3.0.txt": ("file", b"the GPL"),
        "share/doc/loop/one": ("link", "two"),
        "share/doc/loop/two": ("link", "one"),
        "share/doc/gone/copyright": ("link", "../../LICENSES/Gone-1.0.txt"),
    }

    def test_links_are_followed_to_their_text(self):
        self.assertEqual(notices.resolve_text(self.INDEX, "share/doc/a/copyright", "a", "x"),
                         ("share/LICENSES/GPL-3.0.txt", b"the GPL"))
        self.assertEqual(notices.resolve_text(self.INDEX, "share/doc/b/copyright", "b", "x"),
                         ("share/LICENSES/GPL-3.0.txt", b"the GPL"))
        self.assertEqual(notices.resolve_text(self.INDEX, "share/doc/c/copyright", "c", "x"),
                         ("share/doc/d/LICENSE", b"d's own"))

    def test_a_missing_text_fails_naming_the_package(self):
        with self.assertRaises(SystemExit) as caught:
            notices.resolve_text(self.INDEX, "share/doc/gone/copyright", "gone", "arm64-v8a")
        self.assertEqual(str(caught.exception),
                         "notices: gone's licence text share/LICENSES/Gone-1.0.txt (through "
                         "share/doc/gone/copyright) is not in the arm64-v8a payload")
        with self.assertRaises(SystemExit):
            notices.resolve_text(self.INDEX, "share/doc/none/copyright", "none", "x")

    def test_a_loop_of_links_fails(self):
        with self.assertRaises(SystemExit) as caught:
            notices.resolve_text(self.INDEX, "share/doc/loop/one", "loop", "x")
        self.assertIn("loop of links", str(caught.exception))

    def test_texts_are_decoded_and_normalised(self):
        self.assertEqual(notices.licence_text(b"\n\na  \r\n\tb\x0c\r\nc\x1b\n\n"), "a\n\tb\nc")
        self.assertEqual(notices.licence_text("J\u00fcrgen".encode("latin-1")), "J\u00fcrgen")
        self.assertEqual(notices.licence_text("J\u00fcrgen".encode("utf-8")), "J\u00fcrgen")
        self.assertEqual(notices.licence_text(b" \r\n\x0c"), "")
        # A lone carriage return (old Mac line endings) still ends a line.
        self.assertEqual(notices.licence_text(b"one\rtwo"), "one\ntwo")


class ReviewTest(unittest.TestCase):
    """Phase 4 W7's review of the licences the fingerprints could not name."""

    def test_a_subpackage_without_a_text_takes_its_parents(self):
        ids, files = notices.review("curl", [], [], {"share/doc/libcurl/copyright"})
        self.assertEqual(ids, [("curl", "reviewed")])
        self.assertEqual(files, [("share/doc/libcurl/copyright", None)])
        self.assertEqual(notices.licence_label(ids), "curl\u2020")

    def test_a_parents_text_must_be_in_the_payload(self):
        with self.assertRaises(SystemExit) as caught:
            notices.review("xz-utils", [], [], {"share/doc/liblzma/COPYING"})
        self.assertIn("share/doc/liblzma/COPYING.GPLv2 is not in the payload",
                      str(caught.exception))

    def test_only_what_the_fingerprints_missed_is_replaced(self):
        ids, files = notices.review(
            "liblzma", [("unidentified", False), ("GPL-2.0", False)],
            [("share/doc/liblzma/COPYING", None)], set())
        self.assertEqual(ids, [("0BSD", "reviewed"), ("GPL-2.0", False)])
        self.assertEqual(files, [("share/doc/liblzma/COPYING", None)])
        self.assertEqual(notices.licence_label(ids), "0BSD\u2020, GPL-2.0\\*")
        # A pointer file whose licence another file already names adds nothing.
        ids, _ = notices.review("pcre2", [("unidentified", False), ("BSD-3-Clause", False)],
                                [], set())
        self.assertEqual(ids, [("BSD-3-Clause", False)])

    def test_a_review_the_fingerprints_made_needless_fails(self):
        with self.assertRaises(SystemExit) as caught:
            notices.review("ripgrep", [("MIT", False)], [("share/doc/ripgrep/copyright", None)],
                           set())
        self.assertIn("drop its review", str(caught.exception))
        # A package with no review is left as it is.
        self.assertEqual(notices.review("bash", [("GPL-3.0", True)], [], set()),
                         ([("GPL-3.0", True)], []))

    def test_bzip2s_own_licence_is_not_called_bsd(self):
        text = (b'This program, "bzip2", the associated library "libbzip2", and all\n'
                b"documentation, are copyright (C) 1996-2019 Julian R Seward.\n"
                b"Redistribution and use in source and binary forms, with or without\n"
                b"modification, are permitted provided that ...")
        self.assertEqual(notices.identify(text), ["bzip2-1.0.6"])

if __name__ == "__main__":
    unittest.main(verbosity=1)
