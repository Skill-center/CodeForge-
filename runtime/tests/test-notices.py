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
  * the sections are rewritten in place, and --check reports them stale.

Run: python3 runtime/tests/test-notices.py
"""

import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

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
                       "share/doc/libandroid/copyright": LGPL21},
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
        with open(self.notices_path, "w") as handle:
            handle.write(NOTICES_TEMPLATE)
        with open(self.offer_path, "w") as handle:
            handle.write(OFFER_TEMPLATE)

    def run_notices(self, *extra):
        return notices.main(["--pins", self.pins_path, "--cache", self.cache,
                             "--notices", self.notices_path,
                             "--source-offer", self.offer_path] + list(extra))

    def read(self, path):
        with open(path, encoding="utf-8") as handle:
            return handle.read()

    def row(self, text, name):
        rows = [line for line in text.splitlines() if line.startswith("| %s |" % name)]
        self.assertEqual(len(rows), 1, "one row for %s in:\n%s" % (name, text))
        return rows[0]

    def test_the_sections_are_drafted_from_the_licence_files(self):
        self.assertEqual(self.run_notices(), 0)
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
        self.assertIn("**To review (W7):** no licence was identified for `mystery`.", text)
        self.assertIn("**6 package versions** ship in the payloads", text)

    def test_only_copyleft_reaches_the_source_offer(self):
        self.assertEqual(self.run_notices(), 0)
        offer = self.read(self.offer_path)
        for name in ("git", "bash", "libandroid"):
            self.row(offer, name)
        for name in ("libcurl", "zlib", "mystery"):
            self.assertNotIn("| %s |" % name, offer)
        self.assertIn("**3 package versions** are under a copyleft licence", offer)

    def test_check_reports_stale_sections_and_changes_nothing(self):
        self.assertEqual(self.run_notices("--check"), 1)
        self.assertEqual(self.read(self.notices_path), NOTICES_TEMPLATE)
        self.assertEqual(self.run_notices(), 0)
        self.assertEqual(self.run_notices("--check"), 0)

    def test_the_output_is_stable(self):
        self.assertEqual(self.run_notices(), 0)
        first = self.read(self.notices_path), self.read(self.offer_path)
        self.assertEqual(self.run_notices(), 0)
        self.assertEqual((self.read(self.notices_path), self.read(self.offer_path)), first)

    def test_a_missing_section_is_an_error(self):
        with open(self.offer_path, "w") as handle:
            handle.write("# Offer without markers\n")
        with self.assertRaises(SystemExit):
            self.run_notices()


if __name__ == "__main__":
    unittest.main(verbosity=1)
