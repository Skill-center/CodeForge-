# Third-party notices

> **Draft (Phase 4 W2).** ADR-0011's interim rule 3: started from the pinned packages in Phase 4, and completed before the first binary release (W7, ADR-0010). It is not legal advice: W7's licence review checks it.

CodeForge's own code is licensed under the Apache License 2.0 (`LICENSE`). The app also contains, or ships beside it, software by others under their own licences. This file lists that software and says where the full licence texts are.

## 1. Vendored source: t1's sealed runtime

`native/sealed-runtime/` and the vendored scripts in `runtime/` come from https://github.com/m-cyber12/t1 at `d9789a2`, under the Apache License 2.0 (the same text as `LICENSE`). native/PROVENANCE.md lists every file, its SHA-256 and the one change made to it (the Java package).

## 2. The Flutter app's packages

`app/tool/check_licenses.dart` checks the Dart and Flutter packages the app links on every CI run: 107 hosted packages on 2026-11-13. Permissive and weak-copyleft licences pass; GPL, AGPL and SSPL fail the build. Flutter collects their licence texts into the app, where its licence page shows them.

**W7:** the list goes here, generated from `pubspec.lock`.

## 3. The editor page's packages

The editor page is built from `editor/`: CodeMirror 6 and its language packages, all under the MIT licence. Its build records the bundled packages in `manifest.json`, and writes their licence texts to `NOTICES.txt`, which ships beside the page in the APK. `editor/tool/check_licenses.mjs` checks them on every CI run.

**W7:** the list goes here.

## 4. The userland

**What it is.** The runtime payload is an aggregate of Termux packages: the bootstrap plus the pinned core set (runtime/pins.json). Each package keeps its own licence, and many of them are GPL or LGPL. They are separate programs that the app installs and runs, not code linked into it (ADR-0011).

**Where the texts are.** Every package's licence text ships inside the payload, at the path the table gives.

**How the table is made.** runtime/notices.py writes it from the pinned packages' own licence files, and CI checks it against the pins.

**The source.** SOURCE_OFFER.md covers the corresponding source of the copyleft packages.

<!-- userland:begin -->
_Not generated yet: the first `[repin]` CI run resolves the pins and writes this section._
<!-- userland:end -->

## 5. Before the first binary release (W7)

- [ ] Sections 2 and 3 listed, from `pubspec.lock` and the editor's manifest.
- [ ] Every "To review" entry in section 4 resolved, and each licence with an asterisk checked against its text.
- [ ] The app shows these notices: Flutter's licence page, plus the userland's texts.
- [ ] PROVENANCE.md's question answered: whether the vendored files need a notice inside them.
