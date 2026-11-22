# Third-party notices

> **Completed in Phase 4 W7** (2026-11-18), from the pinned packages (Phase 4 W2) and the app's resolved dependencies. ADR-0011's interim rule 3 and ADR-0010: published before the first binary release. Its generated sections are checked by CI on every push, so they follow the dependencies. It is not legal advice; the open points are in section 7.

CodeForge's own code is licensed under the Apache License 2.0 (`LICENSE`). The app also contains, or ships beside it, software by others under their own licences. This file lists that software and says where the full licence texts are. In the app, About → *Open-source licenses* shows Flutter's, the Dart packages', the editor page's and (since Phase 5 W1) the userland's texts, About → *Bundled font licenses* the fonts', and About → *CodeForge's license* CodeForge's own.

## 1. Vendored source: t1's sealed runtime

`native/sealed-runtime/`, `native/runtime-core/` and the vendored scripts in `runtime/` come from https://github.com/m-cyber12/t1 at `d9789a2`, under the Apache License 2.0 (the same text as `LICENSE`), by the same owner as CodeForge. native/PROVENANCE.md lists every file, its SHA-256 and the change made to it: the Java package, and for two files of the kernel CodeForge's recorded patch (`native/patches/`, Phase 4 W7).

## 2. The Flutter app's packages

The Dart and Flutter packages in the app's dependency closure: `pubspec.yaml`'s regular dependencies and everything they need, as `flutter pub deps` resolves it. The list is a superset of what the app holds, since the compiler keeps only the code the app reaches. It includes test libraries (`test_api`, `matcher`, the leak trackers) because flutter_riverpod and riverpod 3 declare `flutter_test` and `test_api` as regular dependencies. `app/tool/check_licenses.dart` writes this section and checks it on every CI run, with each package's licence as its own licence file names it; GPL, AGPL and SSPL fail the build. Flutter collects these texts into the app, where its licence page shows them. Dev-only tools (code generators, test frameworks) are not distributed and are left out.

<!-- dart:begin -->
<!-- Written by app/tool/check_licenses.dart from the app's resolved dependencies. Do not edit by hand: CI checks it. -->

**70 packages** are in the app's dependency closure: BSD-3-Clause 60, MIT 7, Apache-2.0 3. The compiler keeps only the code the app reaches, so the app holds a subset of them.

| Package | Version | Licence |
|---|---|---|
| args | 2.7.0 | BSD-3-Clause |
| async | 2.13.1 | BSD-3-Clause |
| boolean_selector | 2.1.2 | BSD-3-Clause |
| characters | 1.4.1 | BSD-3-Clause |
| clock | 1.1.3 | Apache-2.0 |
| code_assets | 2.1.0 | BSD-3-Clause |
| collection | 1.19.1 | BSD-3-Clause |
| convert | 3.1.2 | BSD-3-Clause |
| crypto | 3.0.8 | BSD-3-Clause |
| cupertino_ui | 1.1.6 | BSD-3-Clause |
| drift | 2.35.3 | MIT |
| fake_async | 1.3.3 | Apache-2.0 |
| ffi | 2.2.0 | BSD-3-Clause |
| file | 7.0.1 | BSD-3-Clause |
| fixnum | 1.1.1 | BSD-3-Clause |
| flutter_riverpod | 3.4.3 | MIT |
| glob | 2.2.0 | BSD-3-Clause |
| go_router | 18.1.3 | BSD-3-Clause |
| hooks | 2.2.0 | BSD-3-Clause |
| intl | 0.20.3 | BSD-3-Clause |
| jni | 1.1.2 | BSD-3-Clause |
| jni_util | 1.0.0 | BSD-3-Clause |
| leak_tracker | 11.0.2 | BSD-3-Clause |
| leak_tracker_flutter_testing | 3.0.10 | BSD-3-Clause |
| leak_tracker_testing | 3.0.2 | BSD-3-Clause |
| listen | 1.0.1 | BSD-3-Clause |
| logging | 1.3.0 | BSD-3-Clause |
| matcher | 0.12.20 | BSD-3-Clause |
| material_color_utilities | 0.13.0 | Apache-2.0 |
| material_ui | 1.10.0 | BSD-3-Clause |
| meta | 1.19.0 | BSD-3-Clause |
| native_toolchain_c | 0.19.5 | BSD-3-Clause |
| objective_c | 9.6.2 | BSD-3-Clause |
| package_config | 3.0.0 | BSD-3-Clause |
| path | 1.9.1 | BSD-3-Clause |
| path_provider_linux | 2.2.2 | BSD-3-Clause |
| path_provider_platform_interface | 2.1.3 | BSD-3-Clause |
| path_provider_windows | 2.3.0 | BSD-3-Clause |
| platform | 3.2.0 | BSD-3-Clause |
| plugin_platform_interface | 2.1.8 | BSD-3-Clause |
| process | 5.0.6 | BSD-3-Clause |
| pub_semver | 2.2.1 | BSD-3-Clause |
| record_use | 1.1.1 | BSD-3-Clause |
| riverpod | 3.4.3 | MIT |
| shared_preferences | 2.5.6 | BSD-3-Clause |
| shared_preferences_android | 2.5.4 | BSD-3-Clause |
| shared_preferences_foundation | 2.6.1 | BSD-3-Clause |
| shared_preferences_linux | 2.4.1 | BSD-3-Clause |
| shared_preferences_platform_interface | 2.4.2 | BSD-3-Clause |
| shared_preferences_web | 2.4.3 | BSD-3-Clause |
| shared_preferences_windows | 2.4.1 | BSD-3-Clause |
| source_span | 1.10.2 | BSD-3-Clause |
| sqlite3 | 3.9.0 | MIT |
| stack_trace | 1.12.2 | BSD-3-Clause |
| state_notifier | 1.0.0 | MIT |
| stream_channel | 2.1.4 | BSD-3-Clause |
| string_scanner | 1.4.1 | BSD-3-Clause |
| term_glyph | 1.2.2 | BSD-3-Clause |
| test_api | 0.7.14 | BSD-3-Clause |
| typed_data | 1.4.0 | BSD-3-Clause |
| uuid | 4.6.0 | MIT |
| vector_math | 2.4.4 | BSD-3-Clause |
| vm_service | 15.4.0 | BSD-3-Clause |
| web | 1.1.2 | BSD-3-Clause |
| webview_flutter | 4.14.1 | BSD-3-Clause |
| webview_flutter_android | 4.14.1 | BSD-3-Clause |
| webview_flutter_platform_interface | 2.15.1 | BSD-3-Clause |
| webview_flutter_wkwebview | 3.27.2 | BSD-3-Clause |
| xdg_directories | 1.1.0 | BSD-3-Clause |
| yaml | 3.1.4 | MIT |

<!-- dart:end -->

## 3. The web pages' packages

Two pages are built from `editor/`: the editor (CodeMirror 6 and its language packages) and, since Phase 5 W3, the terminal (xterm.js 6 with its fit and Unicode 11 addons, and since W6 its WebGL addon, all MIT). Each page's build writes its packages' licence texts to a `NOTICES.txt` that ships beside the page in the APK and appears in the app's licence page. `editor/tool/check_licenses.mjs` checks their licences, and `editor/tool/notices.mjs` writes and checks this list, on every CI run.

<!-- editor:begin -->
<!-- Written by editor/tool/notices.mjs from editor/package-lock.json. Do not edit by hand: CI checks it. -->

**31 packages** can end up in the editor's or the terminal's page: MIT 31. Their licence texts ship in the app beside each page (`assets/editor/NOTICES.txt`, `assets/terminal/NOTICES.txt`) and appear in its licence page.

| Package | Version | Licence |
|---|---|---|
| @codemirror/autocomplete | 6.20.4 | MIT |
| @codemirror/commands | 6.11.1 | MIT |
| @codemirror/lang-css | 6.3.1 | MIT |
| @codemirror/lang-html | 6.4.12 | MIT |
| @codemirror/lang-javascript | 6.2.5 | MIT |
| @codemirror/lang-json | 6.0.2 | MIT |
| @codemirror/lang-markdown | 6.5.2 | MIT |
| @codemirror/lang-python | 6.2.1 | MIT |
| @codemirror/language | 6.13.1 | MIT |
| @codemirror/lint | 6.9.7 | MIT |
| @codemirror/search | 6.7.2 | MIT |
| @codemirror/state | 6.7.6 | MIT |
| @codemirror/streamparser | 6.0.0 | MIT |
| @codemirror/view | 6.43.15 | MIT |
| @lezer/common | 1.5.5 | MIT |
| @lezer/css | 1.3.9 | MIT |
| @lezer/highlight | 1.2.5 | MIT |
| @lezer/html | 1.3.13 | MIT |
| @lezer/javascript | 1.5.6 | MIT |
| @lezer/json | 1.0.3 | MIT |
| @lezer/lr | 1.4.12 | MIT |
| @lezer/markdown | 1.8.1 | MIT |
| @lezer/python | 1.1.19 | MIT |
| @marijn/find-cluster-break | 1.0.4 | MIT |
| @xterm/addon-fit | 0.11.0 | MIT |
| @xterm/addon-unicode11 | 0.9.0 | MIT |
| @xterm/addon-webgl | 0.19.0 | MIT |
| @xterm/xterm | 6.0.0 | MIT |
| crelt | 1.0.7 | MIT |
| style-mod | 4.1.4 | MIT |
| w3c-keyname | 2.2.8 | MIT |

<!-- editor:end -->

## 4. Flutter, its engine, and the fonts

- **Flutter** (the framework, the engine and the Dart runtime) is under the BSD 3-Clause licence. The engine includes third-party libraries (Skia and Impeller's dependencies, ICU, HarfBuzz, FreeType, libpng, zlib, BoringSSL and others) under their own licences. Flutter's build gathers all of their texts into the app (`assets/flutter_assets/NOTICES.Z`), and the licence page shows them.
- **Fonts**, in `app/assets/fonts/` with their licence texts beside them, shown in About → *Bundled font licenses*: Inter and JetBrains Mono under the SIL Open Font License 1.1 (`Inter-OFL.txt`, `JetBrainsMono-OFL.txt`), Material Symbols under the Apache License 2.0 (`MaterialSymbols-LICENSE.txt`). `CfFileGlyphs.ttf` is CodeForge's own.

## 5. The userland

**What it is.** The runtime payload is an aggregate of Termux packages: the bootstrap plus the pinned core set (runtime/pins.json). Each package keeps its own licence, and many of them are GPL or LGPL. They are separate programs that the app installs and runs, not code linked into it (ADR-0011).

**Where the texts are.** Every package's licence text ships inside the payload, at the path the table gives. Since Phase 5 W1 the app also carries them as `app/assets/licenses/userland.txt`, each distinct text once after the packages that carry it, so its licence page lists them before the runtime is installed.

**How the table is made.** runtime/notices.py writes it, and the app's file, from the pinned packages' own licence files, and CI checks both against the pins.

**The source.** SOURCE_OFFER.md covers the corresponding source of the copyleft packages.

<!-- userland:begin -->
<!-- Written by runtime/notices.py from runtime/pins.json and the pinned files. Do not edit by hand: CI checks it. -->

**112 package versions** ship in the payloads: the bootstrap `2026.02.12-r1+apt.android-7` refreshed by the pinned core set (resolved 2026-11-13T09:43:19Z). Per ABI: arm64-v8a 112 packages, 50 of them pinned; x86_64 112 packages, 50 of them pinned.

Licences, counted per package version: GPL-3.0 24, GPL-2.0 23, MIT 18, BSD-3-Clause 14, BSD-2-Clause 13, LGPL-2.1 11, Apache-2.0 6, LGPL-3.0 5, curl 3, ISC 3, Public Domain 3, 0BSD 2, Artistic-License-2.0 2, bzip2-1.0.6 2, LGPL-2.0 2, Unicode-3.0 2, Zlib 2, AGPL-3.0-only 1, Artistic-2.0 1, GPL-2.0-or-later 1, GPL-3.0-or-later 1, Info-ZIP 1, lsof 1, MPL-2.0 1, NCSA 1, PSF-2.0 1, Ruby 1, Unlicense 1.

A licence with an asterisk was identified from its text's wording; one with a dagger (†) by Phase 4 W7's review, from the licence the package's Termux recipe declares (runtime/notices.py, `REVIEWED`); the others are named by Termux's link to `share/LICENSES/<id>.txt`, exactly as Termux names them. The texts ship in the payload at the paths shown (prefix-relative); a subpackage's is its parent's.

A text with a double dagger (‡) is not in the payload under the name the link gives: Termux renamed it after the bootstrap was built, and the bootstrap's termux-licenses carries the same text under its old name, the last path shown (runtime/notices.py, `RENAMED_TEXTS`).

| Package | Version | ABIs | Licence | Licence text in the payload | Homepage |
|---|---|---|---|---|---|
| apt | 2.8.1-2 | arm64-v8a, x86_64 | GPL-2.0 | `share/doc/apt/copyright` → `share/LICENSES/GPL-2.0.txt` | https://packages.debian.org/apt |
| attr | 2.5.2-1 | arm64-v8a, x86_64 | GPL-2.0\*, LGPL-2.1\*, GPL-2.0 | `share/doc/attr/COPYING`<br>`share/doc/attr/COPYING.LGPL`<br>`share/doc/attr/copyright` → `share/LICENSES/GPL-2.0.txt` | http://savannah.nongnu.org/projects/attr/ |
| bash | 5.3.9 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/bash/copyright` → `share/LICENSES/GPL-3.0.txt` | https://www.gnu.org/software/bash/ |
| bzip2 | 1.0.8-8 | arm64-v8a, x86_64 | bzip2-1.0.6† | `share/doc/libbz2/copyright` | http://www.bzip.org/ |
| c-ares | 1.34.9 | arm64-v8a, x86_64 | MIT\* | `share/doc/c-ares/copyright` | https://c-ares.org/ |
| ca-certificates | 1:2026.11.05-1 | arm64-v8a, x86_64 | MPL-2.0 | `share/doc/ca-certificates/copyright` → `share/LICENSES/MPL-2.0.txt` | https://curl.se/docs/caextract.html |
| command-not-found | 3.2-16 | arm64-v8a, x86_64 | Apache-2.0 | `share/doc/command-not-found/copyright` → `share/LICENSES/Apache-2.0.txt` | https://github.com/termux/command-not-found |
| coreutils | 9.9 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/coreutils/copyright` → `share/LICENSES/GPL-3.0.txt` | https://www.gnu.org/software/coreutils/ |
| curl | 8.23.0 | arm64-v8a, x86_64 | curl† | `share/doc/libcurl/copyright` | https://curl.se/ |
| dash | 0.5.12-2 | arm64-v8a, x86_64 | BSD-3-Clause\* | `share/doc/dash/copyright` | http://gondor.apana.org.au/~herbert/dash/ |
| debianutils | 5.23.2-1 | arm64-v8a, x86_64 | GPL-2.0 | `share/doc/debianutils/copyright` → `share/LICENSES/GPL-2.0.txt` | https://packages.debian.org/debianutils |
| dialog | 1.3-20240307-1 | arm64-v8a, x86_64 | LGPL-2.1 | `share/doc/dialog/copyright` → `share/LICENSES/LGPL-2.1.txt` | https://invisible-island.net/dialog/ |
| diffutils | 3.12-2 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/diffutils/copyright` → `share/LICENSES/GPL-3.0.txt` | https://www.gnu.org/software/diffutils/ |
| dos2unix | 7.5.2-1 | arm64-v8a, x86_64 | BSD-2-Clause\* | `share/doc/dos2unix/COPYING.txt` | https://waterlan.home.xs4all.nl/dos2unix.html |
| dpkg | 1.22.6-5 | arm64-v8a, x86_64 | GPL-2.0 | `share/doc/dpkg/copyright` → `share/LICENSES/GPL-2.0.txt` | https://packages.debian.org/dpkg |
| ed | 1.22.5 | arm64-v8a, x86_64 | GPL-2.0 | `share/doc/ed/copyright` → `share/LICENSES/GPL-2.0.txt` | https://www.gnu.org/software/ed/ |
| file | 5.48-3 | arm64-v8a, x86_64 | BSD-2-Clause† | `share/doc/libmagic/copyright` | https://darwinsys.com/file/ |
| findutils | 4.10.0-1 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/findutils/copyright` → `share/LICENSES/GPL-3.0.txt` | https://www.gnu.org/software/findutils/ |
| gawk | 5.3.1-2 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/gawk/copyright` → `share/LICENSES/GPL-3.0.txt` | https://www.gnu.org/software/gawk/ |
| gdbm | 1.26-1 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/gdbm/copyright` → `share/LICENSES/GPL-3.0.txt` | https://www.gnu.org.ua/software/gdbm/ |
| git | 2.56.1 | arm64-v8a, x86_64 | GPL-2.0 | `share/doc/git/copyright` → `share/LICENSES/GPL-2.0.txt` | https://git-scm.com/ |
| gpgv | 2.5.17 | arm64-v8a, x86_64 | GPL-3.0† | `share/LICENSES/GPL-3.0.txt` | https://www.gnupg.org/ |
| grep | 3.12-3 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/grep/copyright` → `share/LICENSES/GPL-3.0.txt` | https://www.gnu.org/software/grep/ |
| gzip | 1.14-1 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/gzip/copyright` → `share/LICENSES/GPL-3.0.txt` | https://www.gnu.org/software/gzip/ |
| inetutils | 2.6-1 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/inetutils/copyright` → `share/LICENSES/GPL-3.0.txt` | https://www.gnu.org/software/inetutils/ |
| jq | 1.8.2 | arm64-v8a, x86_64 | MIT\*, BSD-2-Clause\* | `share/doc/jq/COPYING`<br>`share/doc/jq/copyright` | https://jqlang.org/ |
| krb5 | 1.22.3 | arm64-v8a, x86_64 | curl\*, MIT\*, BSD-3-Clause\* | `share/doc/krb5/NOTICE` | https://web.mit.edu/kerberos |
| ldns | 1.9.2 | arm64-v8a, x86_64 | BSD-3-Clause\* | `share/doc/ldns/copyright` | https://www.nlnetlabs.nl/projects/ldns/ |
| less | 710 | arm64-v8a, x86_64 | GPL-3.0\*, BSD-2-Clause\* | `share/doc/less/COPYING`<br>`share/doc/less/LICENSE` | https://www.greenwoodsoftware.com/less/ |
| libacl | 2.3.2 | arm64-v8a, x86_64 | LGPL-2.1, GPL-2.0 | `share/doc/libacl/copyright` → `share/LICENSES/LGPL-2.1.txt`<br>`share/doc/libacl/copyright.1` → `share/LICENSES/GPL-2.0.txt` | http://savannah.nongnu.org/projects/acl |
| libandroid-execinfo | 0.1-3 | arm64-v8a, x86_64 | BSD-2-Clause\* | `share/doc/libandroid-execinfo/copyright` | https://man7.org/linux/man-pages/man3/backtrace.3.html |
| libandroid-glob | 0.6-3 | arm64-v8a, x86_64 | BSD-3-Clause\* | `share/doc/libandroid-glob/copyright` | https://man7.org/linux/man-pages/man3/glob.3.html |
| libandroid-posix-semaphore | 0.1-4 | arm64-v8a, x86_64 | MIT\* | `share/doc/libandroid-posix-semaphore/copyright` | https://man7.org/linux/man-pages/man7/sem_overview.7.html |
| libandroid-selinux | 14.0.0.11-1 | arm64-v8a, x86_64 | Public Domain | `share/doc/libandroid-selinux/copyright` → `share/LICENSES/Public Domain.txt` | https://selinuxproject.org |
| libandroid-support | 29-1 | arm64-v8a, x86_64 | MIT\* | `share/doc/libandroid-support/LICENSE.txt`<br>`share/doc/libandroid-support/LICENSE.txt.1` | https://github.com/termux/libandroid-support |
| libandroid-utimes | 0.4 | arm64-v8a, x86_64 | BSD-2-Clause\* | `share/doc/libandroid-utimes/LICENSE` | https://github.com/termux/libandroid-utimes |
| libassuan | 3.0.2-1 | arm64-v8a, x86_64 | GPL-2.0 | `share/doc/libassuan/copyright` → `share/LICENSES/GPL-2.0.txt` | https://www.gnupg.org/related_software/libassuan/ |
| libbz2 | 1.0.8-8 | arm64-v8a, x86_64 | bzip2-1.0.6\* | `share/doc/libbz2/copyright` | http://www.bzip.org/ |
| libc++ | 30 | arm64-v8a, x86_64 | NCSA | `share/doc/libc++/copyright` → `share/LICENSES/NCSA.txt` | https://libcxx.llvm.org/ |
| libcap-ng | 2:0.9 | arm64-v8a, x86_64 | LGPL-2.1 | `share/doc/libcap-ng/copyright` → `share/LICENSES/LGPL-2.1.txt` | https://people.redhat.com/sgrubb/libcap-ng/ |
| libcrypt | 0.2-6 | arm64-v8a, x86_64 | BSD-2-Clause\* | `share/doc/libcrypt/copyright` | http://michael.dipperstein.com/crypt/ |
| libcurl | 8.23.0 | arm64-v8a, x86_64 | curl\* | `share/doc/libcurl/copyright` | https://curl.se/ |
| libdb | 18.1.40-6 | arm64-v8a, x86_64 | AGPL-3.0-only | `share/doc/libdb/copyright` → `share/LICENSES/AGPL-3.0-only.txt`‡ → `share/LICENSES/AGPL-V3.txt` | https://www.oracle.com/database/berkeley-db |
| libedit | 20260512-3.1-0 | arm64-v8a, x86_64 | BSD-3-Clause\* | `share/doc/libedit/copyright` | https://thrysoee.dk/editline/ |
| libevent | 2.1.12-3 | arm64-v8a, x86_64 | MIT\*, BSD-2-Clause\* | `share/doc/libevent/copyright` | https://libevent.org/ |
| libexpat | 2.10.0 | arm64-v8a, x86_64 | MIT\* | `share/doc/libexpat/copyright` | https://libexpat.github.io/ |
| libffi | 3.8.0 | arm64-v8a, x86_64 | MIT\* | `share/doc/libffi/copyright` | https://sourceware.org/libffi/ |
| libgcrypt | 1.11.2-1 | arm64-v8a, x86_64 | GPL-2.0\*, LGPL-2.1\* | `share/doc/libgcrypt/COPYING`<br>`share/doc/libgcrypt/COPYING.LIB` | https://www.gnu.org/software/libgcrypt/ |
| libgmp | 6.3.0-2 | arm64-v8a, x86_64 | LGPL-3.0 | `share/doc/libgmp/copyright` → `share/LICENSES/LGPL-3.0.txt` | https://gmplib.org/ |
| libgnutls | 3.8.11 | arm64-v8a, x86_64 | LGPL-2.1, GPL-3.0 | `share/doc/libgnutls/copyright` → `share/LICENSES/LGPL-2.1.txt`<br>`share/doc/libgnutls/copyright.1` → `share/LICENSES/GPL-3.0.txt` | https://www.gnutls.org/ |
| libgpg-error | 1.58 | arm64-v8a, x86_64 | LGPL-2.1 | `share/doc/libgpg-error/copyright` → `share/LICENSES/LGPL-2.1.txt` | https://www.gnupg.org/related_software/libgpg-error/ |
| libiconv | 1.19.1 | arm64-v8a, x86_64 | LGPL-2.1, GPL-3.0 | `share/doc/libiconv/copyright` → `share/LICENSES/LGPL-2.1.txt`<br>`share/doc/libiconv/copyright.1` → `share/LICENSES/GPL-3.0.txt` | https://www.gnu.org/software/libiconv/ |
| libicu | 79.1 | arm64-v8a, x86_64 | Unicode-3.0† | `share/doc/libicu/LICENSE` | http://site.icu-project.org/home |
| libidn2 | 2.3.8-1 | arm64-v8a, x86_64 | LGPL-3.0, GPL-2.0, GPL-3.0 | `share/doc/libidn2/copyright` → `share/LICENSES/LGPL-3.0.txt`<br>`share/doc/libidn2/copyright.1` → `share/LICENSES/GPL-2.0.txt`<br>`share/doc/libidn2/copyright.2` → `share/LICENSES/GPL-3.0.txt` | https://www.gnu.org/software/libidn/#libidn2 |
| liblz4 | 1.10.0-1 | arm64-v8a, x86_64 | GPL-2.0 | `share/doc/liblz4/copyright` → `share/LICENSES/GPL-2.0.txt` | https://lz4.github.io/lz4/ |
| liblzma | 5.8.4 | arm64-v8a, x86_64 | 0BSD†, GPL-2.0\*, GPL-3.0\*, LGPL-2.1\* | `share/doc/liblzma/COPYING`<br>`share/doc/liblzma/COPYING.GPLv2`<br>`share/doc/liblzma/COPYING.GPLv3`<br>`share/doc/liblzma/COPYING.LGPLv2.1` | https://tukaani.org/xz/ |
| libmagic | 5.48-3 | arm64-v8a, x86_64 | BSD-2-Clause\* | `share/doc/libmagic/copyright` | https://darwinsys.com/file/ |
| libmd | 1.1.0-1 | arm64-v8a, x86_64 | BSD-3-Clause\* | `share/doc/libmd/COPYING` | https://www.hadrons.org/software/libmd/ |
| libmpfr | 4.2.1-1 | arm64-v8a, x86_64 | LGPL-3.0 | `share/doc/libmpfr/copyright` → `share/LICENSES/LGPL-3.0.txt` | https://www.mpfr.org/ |
| libnettle | 4.0+really3.10.2 | arm64-v8a, x86_64 | GPL-2.0, LGPL-3.0 | `share/doc/libnettle/copyright` → `share/LICENSES/GPL-2.0.txt`<br>`share/doc/libnettle/copyright.1` → `share/LICENSES/LGPL-3.0.txt` | https://www.lysator.liu.se/~nisse/nettle/ |
| libnghttp2 | 1.71.0 | arm64-v8a, x86_64 | MIT\* | `share/doc/libnghttp2/copyright` | https://nghttp2.org/ |
| libnghttp3 | 1.19.0 | arm64-v8a, x86_64 | MIT\* | `share/doc/libnghttp3/copyright` | https://nghttp2.org/nghttp3/ |
| libngtcp2 | 1.26.0 | arm64-v8a, x86_64 | MIT\* | `share/doc/libngtcp2/copyright` | https://github.com/ngtcp2/ngtcp2 |
| libnpth | 1.6-3 | arm64-v8a, x86_64 | LGPL-2.0 | `share/doc/libnpth/copyright` → `share/LICENSES/LGPL-2.0.txt` | https://www.gnupg.org/related_software/npth/ |
| libresolv-wrapper | 1.1.8 | arm64-v8a, x86_64 | BSD-3-Clause\* | `share/doc/libresolv-wrapper/copyright` | https://cwrap.org/resolv_wrapper.html |
| libsmartcols | 2.41.2-1 | arm64-v8a, x86_64 | LGPL-2.1† | `share/doc/util-linux/COPYING.LGPL-2.1-or-later` | https://en.wikipedia.org/wiki/Util-linux |
| libsqlite | 3.54.1-1 | arm64-v8a, x86_64 | Public Domain | `share/doc/libsqlite/copyright` → `share/LICENSES/Public Domain.txt` | https://www.sqlite.org |
| libssh2 | 1.11.1-2 | arm64-v8a, x86_64 | BSD-3-Clause\* | `share/doc/libssh2/copyright` | https://www.libssh2.org |
| libtirpc | 1.3.7-1 | arm64-v8a, x86_64 | BSD-2-Clause\* | `share/doc/libtirpc/copyright` | http://git.linux-nfs.org/?p=steved/libtirpc.git |
| libunbound | 1.24.2-1 | arm64-v8a, x86_64 | BSD-3-Clause\* | `share/doc/libunbound/copyright` | https://unbound.net/ |
| libunistring | 1.3-1 | arm64-v8a, x86_64 | LGPL-3.0, GPL-2.0 | `share/doc/libunistring/copyright` → `share/LICENSES/LGPL-3.0.txt`<br>`share/doc/libunistring/copyright.1` → `share/LICENSES/GPL-2.0.txt` | https://www.gnu.org/software/libunistring/ |
| libyaml | 0.2.5-5 | arm64-v8a, x86_64 | MIT\* | `share/doc/libyaml/copyright` | https://pyyaml.org/wiki/LibYAML |
| lsof | 4.99.5-2 | arm64-v8a, x86_64 | lsof† | `share/doc/lsof/COPYING` | https://github.com/lsof-org/lsof |
| nano | 8.7.1 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/nano/copyright` → `share/LICENSES/GPL-3.0.txt` | https://www.nano-editor.org/ |
| ncurses | 6.6.20260307+really6.5.20250830 | arm64-v8a, x86_64 | MIT\* | `share/doc/ncurses/copyright` | https://invisible-island.net/ncurses/ |
| ncurses-ui-libs | 6.6.20260307+really6.5.20250830 | arm64-v8a, x86_64 | MIT† | `share/doc/ncurses/copyright` | https://invisible-island.net/ncurses/ |
| net-tools | 2.10.0-1 | arm64-v8a, x86_64 | GPL-2.0 | `share/doc/net-tools/copyright` → `share/LICENSES/GPL-2.0.txt` | http://net-tools.sourceforge.net/ |
| nodejs | 26.13.1 | arm64-v8a, x86_64 | Apache-2.0\*, Artistic-2.0\*, ISC\*, MIT\*, BSD-3-Clause\*, Zlib\*, Unicode-3.0\*, GPL-3.0-or-later\* | `share/doc/nodejs/copyright` | https://nodejs.org/ |
| npm | 12.2.2 | arm64-v8a, x86_64 | Artistic-License-2.0 | `share/doc/npm/copyright` → `share/LICENSES/Artistic-License-2.0.txt` | https://docs.npmjs.com/cli/ |
| oniguruma | 6.9.10-1 | arm64-v8a, x86_64 | BSD-2-Clause\* | `share/doc/oniguruma/copyright` | https://github.com/kkos/oniguruma |
| openssh | 10.6p2 | arm64-v8a, x86_64 | BSD-3-Clause\* | `share/doc/openssh/copyright` | https://www.openssh.com/ |
| openssh-sftp-server | 10.6p2 | arm64-v8a, x86_64 | BSD-3-Clause† | `share/doc/openssh/copyright` | https://www.openssh.com/ |
| openssl | 1:3.6.5 | arm64-v8a, x86_64 | Apache-2.0 | `share/doc/openssl/copyright` → `share/LICENSES/Apache-2.0.txt` | https://www.openssl.org/ |
| patch | 2.8-1 | arm64-v8a, x86_64 | GPL-2.0 | `share/doc/patch/copyright` → `share/LICENSES/GPL-2.0.txt` | https://savannah.gnu.org/projects/patch/ |
| pcre2 | 10.49 | arm64-v8a, x86_64 | BSD-3-Clause\* | `share/doc/pcre2/COPYING`<br>`share/doc/pcre2/LICENCE.md`<br>`share/doc/pcre2/copyright`<br>`share/doc/pcre2/copyright.1` | https://pcre2project.github.io/pcre2/ |
| perl | 5.44.0-1 | arm64-v8a, x86_64 | Artistic-License-2.0 | `share/doc/perl/copyright` → `share/LICENSES/Artistic-License-2.0.txt` | https://www.perl.org/ |
| procps | 3.3.17-6 | arm64-v8a, x86_64 | LGPL-2.0 | `share/doc/procps/copyright` → `share/LICENSES/LGPL-2.0.txt` | https://gitlab.com/procps-ng/procps |
| psmisc | 23.7-1 | arm64-v8a, x86_64 | GPL-2.0 | `share/doc/psmisc/copyright` → `share/LICENSES/GPL-2.0.txt` | https://gitlab.com/psmisc/psmisc |
| python | 3.14.10 | arm64-v8a, x86_64 | PSF-2.0\*, ISC\* | `share/doc/python/LICENSE` | https://python.org/ |
| python-pip | 26.3 | arm64-v8a, x86_64 | MIT\* | `share/doc/python-pip/copyright` | https://pip.pypa.io/ |
| readline | 8.3.6 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/readline/copyright` → `share/LICENSES/GPL-3.0.txt` | https://tiswww.case.edu/php/chet/readline/rltop.html |
| resolv-conf | 1.3 | arm64-v8a, x86_64 | Public Domain | `share/doc/resolv-conf/LICENSE` → `share/LICENSES/Public Domain.txt` | https://man7.org/linux/man-pages/man5/resolv.conf.5.html |
| ripgrep | 15.2.0 | arm64-v8a, x86_64 | Unlicense†, MIT\* | `share/doc/ripgrep/copyright`<br>`share/doc/ripgrep/copyright.1` | https://github.com/BurntSushi/ripgrep |
| ruby | 4.0.9 | arm64-v8a, x86_64 | Ruby\* | `share/doc/ruby/copyright` | https://www.ruby-lang.org/ |
| sed | 4.9-2 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/sed/copyright` → `share/LICENSES/GPL-3.0.txt` | https://www.gnu.org/software/sed/ |
| tar | 1.35-2 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/tar/copyright` → `share/LICENSES/GPL-3.0.txt` | https://www.gnu.org/software/tar/ |
| termux-am | 0.8.0-2 | arm64-v8a, x86_64 | Apache-2.0 | `share/doc/termux-am/copyright` → `share/LICENSES/Apache-2.0.txt` | https://github.com/termux/TermuxAm |
| termux-am-socket | 1.5.0-1 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/termux-am-socket/copyright` → `share/LICENSES/GPL-3.0.txt` | https://github.com/termux/termux-am-socket |
| termux-auth | 1.5.0-1 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/termux-auth/copyright` → `share/LICENSES/GPL-3.0.txt` | https://github.com/termux/termux-auth |
| termux-core | 0.4.0-1 | arm64-v8a, x86_64 | MIT† | `share/doc/termux-core/copyright` | https://github.com/termux/termux-core-package |
| termux-exec | 1:2.4.0-1 | arm64-v8a, x86_64 | Apache-2.0† | `share/doc/termux-exec/copyright` | https://github.com/termux/termux-exec-package |
| termux-keyring | 3.13 | arm64-v8a, x86_64 | Apache-2.0 | `share/doc/termux-keyring/copyright` → `share/LICENSES/Apache-2.0.txt` | https://github.com/termux |
| termux-licenses | 2.1 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/termux-licenses/copyright` → `share/LICENSES/GPL-3.0.txt` | https://termux.dev |
| termux-tools | 1.46.0+really1.45.0-1 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/termux-tools/copyright` → `share/LICENSES/GPL-3.0.txt` | https://termux.dev/ |
| tree | 2.3.2 | arm64-v8a, x86_64 | GPL-2.0 | `share/doc/tree/copyright` → `share/LICENSES/GPL-2.0.txt` | http://mama.indstate.edu/users/ice/tree/ |
| unzip | 6.0-10 | arm64-v8a, x86_64 | Info-ZIP† | `share/doc/unzip/copyright` | https://sourceforge.net/projects/infozip/ |
| util-linux | 2.41.2-1 | arm64-v8a, x86_64 | BSD-2-Clause\*, BSD-3-Clause\*, GPL-2.0\*, GPL-3.0\*, ISC\*, LGPL-2.1\* | `share/doc/util-linux/COPYING.BSD-3-Clause`<br>`share/doc/util-linux/COPYING.BSD-4-Clause-UC`<br>`share/doc/util-linux/COPYING.GPL-2.0-or-later`<br>`share/doc/util-linux/COPYING.GPL-3.0-or-later`<br>`share/doc/util-linux/COPYING.ISC`<br>`share/doc/util-linux/COPYING.LGPL-2.1-or-later` | https://en.wikipedia.org/wiki/Util-linux |
| which | 2.25 | arm64-v8a, x86_64 | GPL-2.0-or-later | `share/doc/which/copyright` → `share/LICENSES/GPL-2.0-or-later.txt` | https://savannah.gnu.org/projects/which/ |
| xxhash | 0.8.3-1 | arm64-v8a, x86_64 | BSD-2-Clause\*, GPL-2.0 | `share/doc/xxhash/copyright`<br>`share/doc/xxhash/copyright.1` → `share/LICENSES/GPL-2.0.txt` | https://cyan4973.github.io/xxHash/ |
| xz-utils | 5.8.4 | arm64-v8a, x86_64 | 0BSD†, GPL-2.0† | `share/doc/liblzma/COPYING`<br>`share/doc/liblzma/COPYING.GPLv2` | https://tukaani.org/xz/ |
| zlib | 1.4 | arm64-v8a, x86_64 | Zlib\* | `share/doc/zlib/copyright` | https://www.zlib.net/ |
| zstd | 1.5.7-1 | arm64-v8a, x86_64 | GPL-2.0 | `share/doc/zstd/copyright` → `share/LICENSES/GPL-2.0.txt` | https://github.com/facebook/zstd |

<!-- userland:end -->

## 6. The language servers

**What they are.** Since Phase 6 W2 the app carries two language servers, which the runtime's node runs: Pyright, and typescript-language-server with TypeScript ([ADR-0015](docs/adr/0015-language-servers.md)). They are npm packages, pinned with their integrity in `runtime/language-servers/` and shipped as archives beside the userland. Each is installed into the runtime the first time it is needed.

**What they carry.** Each npm package keeps its own licence. Pyright and typescript-language-server also bundle other npm packages into their JavaScript, and ship without those packages' licence texts. `runtime/language_servers.py` reads the bundled packages and their versions from the shipped packages' source maps, which name pnpm's store paths, into `runtime/language-servers/bundled.json`. It then takes each one's licence files from its own tarball, verified against the registry's SHA-512.

**Where the texts are.** The app carries them as `app/assets/licenses/language-servers.txt`, each distinct text once after the packages that carry it, and its licence page lists them. CI checks this table and that file against the pins.

<!-- language-servers:begin -->
<!-- Written by runtime/language_servers.py from runtime/language-servers/. Do not edit by hand: CI checks it. -->

**61 package versions** ship in the language servers: 3 as their own files and 58 bundled inside their JavaScript. Pyright: `pyright` 1.1.414, with 37 bundled inside; the TypeScript server: `typescript` 6.0.3 and `typescript-language-server` 6.1.0, with 21 bundled inside. Licences, counted per package version: MIT 48, ISC 5, Apache-2.0 2, BSD-2-Clause 2, BSD-3-Clause 2, 0BSD 1, BlueOak-1.0.0 1.

| Package | Version | Licence | Server | Ships | Licence text |
|---|---|---|---|---|---|
| pyright | 1.1.414 | MIT | Pyright | its own files | `LICENSE.txt`, `dist/typeshed-fallback/LICENSE` |
| typescript | 6.0.3 | Apache-2.0 | the TypeScript server | its own files | `LICENSE.txt`, `ThirdPartyNoticeText.txt` |
| typescript-language-server | 6.1.0 | Apache-2.0 | the TypeScript server | its own files | `LICENSE` |
| @yarnpkg/fslib | 2.10.4 | BSD-2-Clause | Pyright | bundled in `pyright@1.1.414` | none in its package |
| @yarnpkg/libzip | 2.3.0 | BSD-2-Clause | Pyright | bundled in `pyright@1.1.414` | none in its package |
| ansi-styles | 4.3.0 | MIT | Pyright | bundled in `pyright@1.1.414` | `license` |
| anymatch | 3.1.3 | ISC | Pyright | bundled in `pyright@1.1.414` | `LICENSE` |
| binary-extensions | 2.3.0 | MIT | Pyright | bundled in `pyright@1.1.414` | `license` |
| braces | 3.0.3 | MIT | Pyright | bundled in `pyright@1.1.414` | `LICENSE` |
| buffer-from | 1.1.2 | MIT | Pyright | bundled in `pyright@1.1.414` | `LICENSE` |
| chalk | 4.1.2 | MIT | Pyright | bundled in `pyright@1.1.414` | `license` |
| chokidar | 3.6.0 | MIT | Pyright | bundled in `pyright@1.1.414` | `LICENSE` |
| color-convert | 2.0.1 | MIT | Pyright | bundled in `pyright@1.1.414` | `LICENSE` |
| color-name | 1.1.4 | MIT | Pyright | bundled in `pyright@1.1.414` | `LICENSE` |
| command-line-args | 5.2.1 | MIT | Pyright | bundled in `pyright@1.1.414` | `LICENSE` |
| commander | 15.1.0 | MIT | the TypeScript server | bundled in `typescript-language-server@6.1.0` | `LICENSE` |
| crypto-random-string | 4.0.0 | MIT | the TypeScript server | bundled in `typescript-language-server@6.1.0` | `license` |
| fill-range | 7.1.1 | MIT | Pyright | bundled in `pyright@1.1.414` | `LICENSE` |
| find-up-simple | 1.0.1 | MIT | the TypeScript server | bundled in `typescript-language-server@6.1.0` | `license` |
| fs-extra | 11.4.1 | MIT | the TypeScript server | bundled in `typescript-language-server@6.1.0` | `LICENSE` |
| glob-parent | 5.1.2 | ISC | Pyright | bundled in `pyright@1.1.414` | `LICENSE` |
| graceful-fs | 4.2.11 | ISC | the TypeScript server | bundled in `typescript-language-server@6.1.0` | `LICENSE` |
| has-flag | 4.0.0 | MIT | Pyright | bundled in `pyright@1.1.414` | `license` |
| is-binary-path | 2.1.0 | MIT | Pyright | bundled in `pyright@1.1.414` | `license` |
| is-extglob | 2.1.1 | MIT | Pyright | bundled in `pyright@1.1.414` | `LICENSE` |
| is-glob | 4.0.3 | MIT | Pyright | bundled in `pyright@1.1.414` | `LICENSE` |
| is-number | 7.0.0 | MIT | Pyright | bundled in `pyright@1.1.414` | `LICENSE` |
| isexe | 4.0.0 | BlueOak-1.0.0 | the TypeScript server | bundled in `typescript-language-server@6.1.0` | `LICENSE.md` |
| jsonc-parser | 3.3.1 | MIT | Pyright | bundled in `pyright@1.1.414` | `LICENSE.md` |
| jsonfile | 6.2.1 | MIT | the TypeScript server | bundled in `typescript-language-server@6.1.0` | `LICENSE` |
| lodash.camelcase | 4.3.0 | MIT | Pyright | bundled in `pyright@1.1.414` | `LICENSE` |
| normalize-path | 3.0.0 | MIT | Pyright | bundled in `pyright@1.1.414` | `LICENSE` |
| p-debounce | 6.0.0 | MIT | the TypeScript server | bundled in `typescript-language-server@6.1.0` | `license` |
| package-up | 5.0.0 | MIT | the TypeScript server | bundled in `typescript-language-server@6.1.0` | `license` |
| picomatch | 2.3.2 | MIT | Pyright | bundled in `pyright@1.1.414` | `LICENSE` |
| readdirp | 3.6.0 | MIT | Pyright | bundled in `pyright@1.1.414` | `LICENSE` |
| semver | 7.8.6 | ISC | the TypeScript server | bundled in `typescript-language-server@6.1.0` | `LICENSE` |
| smol-toml | 1.7.0 | BSD-3-Clause | Pyright | bundled in `pyright@1.1.414` | `LICENSE` |
| source-map | 0.6.1 | BSD-3-Clause | Pyright | bundled in `pyright@1.1.414` | `LICENSE` |
| source-map-support | 0.5.21 | MIT | Pyright | bundled in `pyright@1.1.414` | `LICENSE.md` |
| supports-color | 7.2.0 | MIT | Pyright | bundled in `pyright@1.1.414` | `license` |
| temp-dir | 3.0.0 | MIT | the TypeScript server | bundled in `typescript-language-server@6.1.0` | `license` |
| tempy | 3.2.0 | MIT | the TypeScript server | bundled in `typescript-language-server@6.1.0` | `license` |
| tmp | 0.2.7 | MIT | Pyright | bundled in `pyright@1.1.414` | `LICENSE` |
| to-regex-range | 5.0.1 | MIT | Pyright | bundled in `pyright@1.1.414` | `LICENSE` |
| tslib | 1.14.1 | 0BSD | Pyright | bundled in `pyright@1.1.414` | `LICENSE.txt` |
| unique-string | 3.0.0 | MIT | the TypeScript server | bundled in `typescript-language-server@6.1.0` | `license` |
| universalify | 2.0.1 | MIT | the TypeScript server | bundled in `typescript-language-server@6.1.0` | `LICENSE` |
| vscode-jsonrpc | 10.0.0 | MIT | the TypeScript server | bundled in `typescript-language-server@6.1.0` | `License.txt`, `thirdpartynotices.txt` |
| vscode-jsonrpc | 9.0.1 | MIT | Pyright | bundled in `pyright@1.1.414` | `License.txt`, `thirdpartynotices.txt` |
| vscode-languageserver | 10.1.0 | MIT | Pyright | bundled in `pyright@1.1.414` | `License.txt`, `thirdpartynotices.txt` |
| vscode-languageserver | 11.0.0 | MIT | the TypeScript server | bundled in `typescript-language-server@6.1.0` | `License.txt`, `thirdpartynotices.txt` |
| vscode-languageserver-protocol | 3.18.2 | MIT | Pyright | bundled in `pyright@1.1.414` | `License.txt`, `thirdpartynotices.txt` |
| vscode-languageserver-protocol | 3.18.5 | MIT | the TypeScript server | bundled in `typescript-language-server@6.1.0` | `License.txt`, `thirdpartynotices.txt` |
| vscode-languageserver-textdocument | 1.0.12 | MIT | Pyright | bundled in `pyright@1.1.414` | `License.txt`, `thirdpartynotices.txt` |
| vscode-languageserver-textdocument | 1.0.16 | MIT | the TypeScript server | bundled in `typescript-language-server@6.1.0` | `License.txt`, `thirdpartynotices.txt` |
| vscode-languageserver-types | 3.18.0 | MIT | Pyright | bundled in `pyright@1.1.414` | `License.txt`, `thirdpartynotices.txt` |
| vscode-languageserver-types | 3.18.5 | MIT | the TypeScript server | bundled in `typescript-language-server@6.1.0` | `License.txt`, `thirdpartynotices.txt` |
| vscode-uri | 3.1.0 | MIT | Pyright | bundled in `pyright@1.1.414` | `LICENSE.md` |
| vscode-uri | 3.2.0 | MIT | the TypeScript server | bundled in `typescript-language-server@6.1.0` | `LICENSE.md` |
| which | 7.0.0 | ISC | the TypeScript server | bundled in `typescript-language-server@6.1.0` | `LICENSE` |

**Without a licence text in their package** (2): @yarnpkg/fslib@2.10.4, @yarnpkg/libzip@2.3.0. Their package.json names the licence; the text is for the licence review.

<!-- language-servers:end -->

## 7. Done, and still open

- [x] Sections 2 and 3 listed, each written and checked by CI from the resolved dependencies.
- [x] Every package section 5 could not name has a licence: Phase 4 W7 read each one's Termux recipe (the dagger), and a subpackage that carries no text points to its parent's. CI fails if a named text is not in the payload, or if a review is no longer needed.
- [x] Whether the vendored files need a notice inside them: no. t1 and CodeForge have the same owner and the same licence text, and native/PROVENANCE.md and `native/patches/` record every change made to t1's files.
- [x] **The userland's texts in the app's licence page** (Phase 5 W1). runtime/notices.py writes them from the payload's own licence files into `app/assets/licenses/userland.txt`: each distinct text once, under the packages that carry it, with a link in the payload followed to its text. A text the payload lacks fails the run, and CI checks the file against the pins. About → *Open-source licenses* lists them after the Flutter, Dart and editor page packages. The first run found one link the payload can't follow: libdb's `copyright` names `share/LICENSES/AGPL-3.0-only.txt`, a name termux-licenses 2.2 introduced in August 2026, while the payload carries the bootstrap's 2.1, which has the same text as `AGPL-V3.txt`. Section 5 marks it with a double dagger, and the app shows that text. On the device, the link stays broken until a re-pin adds termux-licenses 2.2 to the pinned core set.
- [ ] **A licence review by a person qualified to give one,** of this file and SOURCE_OFFER.md, before the first binary release.
