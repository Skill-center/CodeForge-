# Source offer

> **Completed in Phase 4 W7** (2026-11-18): the mechanism is decided, and the list below is written and checked by CI from the pins. ADR-0011's interim rule 3 and ADR-0010: published before any binary that contains the userland is distributed. It is not legal advice; the open points are under *Before the first distribution*.

## Why there is one

CodeForge's own code is Apache-2.0, and it is public in this repository. The app's runtime payload, however, contains Termux packages under copyleft licences: GPL, LGPL and others (the table below). Whoever distributes their binaries, in an APK on Play or anywhere else, must make the corresponding source available on the terms of each licence. For the GPL, the binaries must either come with the source, or come with a written offer of it that is valid for at least three years (GPL-2.0 §3, GPL-3.0 §6).

## What the corresponding source is

For each package version in the payload:

- **The upstream release.** The source release that Termux's build recipe names (`TERMUX_PKG_SRCURL`, with its SHA-256).
- **Termux's recipe and patches.** The package's directory in https://github.com/termux/termux-packages, at the commit that built that version.
- **The bootstrap.** The same for every package the bootstrap contains, plus Termux's scripts that build the bootstrap.

## How CodeForge provides it (decided in Phase 4 W7)

**The source is published with every binary, and a written offer points to it.**

- **The source.** For each binary that contains the userland, the release workflow (ADR-0010) assembles the corresponding source of every copyleft package version in it, from the pins: the upstream archives with their SHA-256, and Termux's recipe directories (build script and patches) at the termux-packages commits that built those versions.
- **Where it goes.** Next to the binary, as a GitHub release asset of this repository, with checksums. A binary that reaches users only through Play (the closed test included) gets the same release, so the archive exists for every distributed build.
- **The offer.** This file and the app (About) carry a written offer, valid for at least three years after the last distribution of each binary, to provide that source on request. The archive honours it at no cost.
- **Requests** go to this repository's issue tracker, https://github.com/Skill-center/CodeForge-/issues, until the owner names an address of its own.

**Before the first distribution** (the closed test's start, or a GitHub release, whichever is first):

- [ ] The release workflow assembles and publishes the source archive. It needs each pinned version mapped to the termux-packages commit that built it. The recipe declares `TERMUX_PKG_VERSION` and `TERMUX_PKG_REVISION`, so the newest commit whose recipe gives the pinned version is the one; termux-packages' history on GitHub has it.
- [ ] The app's About shows the offer, with the link to this file.
- [ ] A person qualified to give one reviews this file and THIRD_PARTY_NOTICES.md (THIRD_PARTY_NOTICES §6).

No binary that contains the userland is distributed until these are done.

## The offer in the app

About → Source code shows this text (Phase 5 W1, `app/lib/core/legal/source_offer.dart`), with the app's version for `{version}`. A test, `app/test/core/source_offer_test.dart`, keeps the two the same: a change to one is a change to the other, and the licence review covers both.

> CodeForge is open source, under the Apache License 2.0. Its source code is at https://github.com/Skill-center/CodeForge-.
>
> The Linux userland inside the app is built from Termux packages. Many of them are under the GNU GPL, the GNU LGPL or another copyleft license. Open-source licenses lists every package with its license text.
>
> The complete corresponding source code of those copyleft packages is published with every release of CodeForge, next to the app, at https://github.com/Skill-center/CodeForge-/releases: the upstream sources, Termux's build recipes and patches at the commits that built each package, and Termux's build scripts, each file listed with its SHA-256 checksum. For this version it is codeforge-{version}-sources.tar.
>
> Written offer: for at least three years after we last distribute this version of CodeForge, we will give anyone who asks a complete machine-readable copy of that source code, at no charge. To ask, open an issue at https://github.com/Skill-center/CodeForge-/issues.

About → CodeForge's license shows the repository's LICENSE. About → Open-source licenses lists the userland's packages with their licence texts, after the Flutter and Dart packages and the editor page's: runtime/notices.py writes the texts into `app/assets/licenses/userland.txt` from the pinned packages' own licence files, and CI checks the file against the pins.

## The copyleft packages in the payload

<!-- copyleft:begin -->
<!-- Written by runtime/notices.py from runtime/pins.json and the pinned files. Do not edit by hand: CI checks it. -->

**55 package versions** are under a copyleft licence (GPL, LGPL, AGPL, GFDL, MPL and the like), identified as in THIRD_PARTY_NOTICES.md. Bootstrap `2026.02.12-r1+apt.android-7`, pins resolved 2026-11-13T09:43:19Z.

| Package | Version | ABIs | Licence | Homepage |
|---|---|---|---|---|
| apt | 2.8.1-2 | arm64-v8a, x86_64 | GPL-2.0 | https://packages.debian.org/apt |
| attr | 2.5.2-1 | arm64-v8a, x86_64 | GPL-2.0\*, LGPL-2.1\*, GPL-2.0 | http://savannah.nongnu.org/projects/attr/ |
| bash | 5.3.9 | arm64-v8a, x86_64 | GPL-3.0 | https://www.gnu.org/software/bash/ |
| ca-certificates | 1:2026.11.05-1 | arm64-v8a, x86_64 | MPL-2.0 | https://curl.se/docs/caextract.html |
| coreutils | 9.9 | arm64-v8a, x86_64 | GPL-3.0 | https://www.gnu.org/software/coreutils/ |
| debianutils | 5.23.2-1 | arm64-v8a, x86_64 | GPL-2.0 | https://packages.debian.org/debianutils |
| dialog | 1.3-20240307-1 | arm64-v8a, x86_64 | LGPL-2.1 | https://invisible-island.net/dialog/ |
| diffutils | 3.12-2 | arm64-v8a, x86_64 | GPL-3.0 | https://www.gnu.org/software/diffutils/ |
| dpkg | 1.22.6-5 | arm64-v8a, x86_64 | GPL-2.0 | https://packages.debian.org/dpkg |
| ed | 1.22.5 | arm64-v8a, x86_64 | GPL-2.0 | https://www.gnu.org/software/ed/ |
| findutils | 4.10.0-1 | arm64-v8a, x86_64 | GPL-3.0 | https://www.gnu.org/software/findutils/ |
| gawk | 5.3.1-2 | arm64-v8a, x86_64 | GPL-3.0 | https://www.gnu.org/software/gawk/ |
| gdbm | 1.26-1 | arm64-v8a, x86_64 | GPL-3.0 | https://www.gnu.org.ua/software/gdbm/ |
| git | 2.56.1 | arm64-v8a, x86_64 | GPL-2.0 | https://git-scm.com/ |
| gpgv | 2.5.17 | arm64-v8a, x86_64 | GPL-3.0† | https://www.gnupg.org/ |
| grep | 3.12-3 | arm64-v8a, x86_64 | GPL-3.0 | https://www.gnu.org/software/grep/ |
| gzip | 1.14-1 | arm64-v8a, x86_64 | GPL-3.0 | https://www.gnu.org/software/gzip/ |
| inetutils | 2.6-1 | arm64-v8a, x86_64 | GPL-3.0 | https://www.gnu.org/software/inetutils/ |
| less | 710 | arm64-v8a, x86_64 | GPL-3.0\*, BSD-2-Clause\* | https://www.greenwoodsoftware.com/less/ |
| libacl | 2.3.2 | arm64-v8a, x86_64 | LGPL-2.1, GPL-2.0 | http://savannah.nongnu.org/projects/acl |
| libassuan | 3.0.2-1 | arm64-v8a, x86_64 | GPL-2.0 | https://www.gnupg.org/related_software/libassuan/ |
| libcap-ng | 2:0.9 | arm64-v8a, x86_64 | LGPL-2.1 | https://people.redhat.com/sgrubb/libcap-ng/ |
| libdb | 18.1.40-6 | arm64-v8a, x86_64 | AGPL-3.0-only | https://www.oracle.com/database/berkeley-db |
| libgcrypt | 1.11.2-1 | arm64-v8a, x86_64 | GPL-2.0\*, LGPL-2.1\* | https://www.gnu.org/software/libgcrypt/ |
| libgmp | 6.3.0-2 | arm64-v8a, x86_64 | LGPL-3.0 | https://gmplib.org/ |
| libgnutls | 3.8.11 | arm64-v8a, x86_64 | LGPL-2.1, GPL-3.0 | https://www.gnutls.org/ |
| libgpg-error | 1.58 | arm64-v8a, x86_64 | LGPL-2.1 | https://www.gnupg.org/related_software/libgpg-error/ |
| libiconv | 1.19.1 | arm64-v8a, x86_64 | LGPL-2.1, GPL-3.0 | https://www.gnu.org/software/libiconv/ |
| libidn2 | 2.3.8-1 | arm64-v8a, x86_64 | LGPL-3.0, GPL-2.0, GPL-3.0 | https://www.gnu.org/software/libidn/#libidn2 |
| liblz4 | 1.10.0-1 | arm64-v8a, x86_64 | GPL-2.0 | https://lz4.github.io/lz4/ |
| liblzma | 5.8.4 | arm64-v8a, x86_64 | 0BSD†, GPL-2.0\*, GPL-3.0\*, LGPL-2.1\* | https://tukaani.org/xz/ |
| libmpfr | 4.2.1-1 | arm64-v8a, x86_64 | LGPL-3.0 | https://www.mpfr.org/ |
| libnettle | 4.0+really3.10.2 | arm64-v8a, x86_64 | GPL-2.0, LGPL-3.0 | https://www.lysator.liu.se/~nisse/nettle/ |
| libnpth | 1.6-3 | arm64-v8a, x86_64 | LGPL-2.0 | https://www.gnupg.org/related_software/npth/ |
| libsmartcols | 2.41.2-1 | arm64-v8a, x86_64 | LGPL-2.1† | https://en.wikipedia.org/wiki/Util-linux |
| libunistring | 1.3-1 | arm64-v8a, x86_64 | LGPL-3.0, GPL-2.0 | https://www.gnu.org/software/libunistring/ |
| nano | 8.7.1 | arm64-v8a, x86_64 | GPL-3.0 | https://www.nano-editor.org/ |
| net-tools | 2.10.0-1 | arm64-v8a, x86_64 | GPL-2.0 | http://net-tools.sourceforge.net/ |
| nodejs | 26.13.1 | arm64-v8a, x86_64 | Apache-2.0\*, Artistic-2.0\*, ISC\*, MIT\*, BSD-3-Clause\*, Zlib\*, Unicode-3.0\*, GPL-3.0-or-later\* | https://nodejs.org/ |
| patch | 2.8-1 | arm64-v8a, x86_64 | GPL-2.0 | https://savannah.gnu.org/projects/patch/ |
| procps | 3.3.17-6 | arm64-v8a, x86_64 | LGPL-2.0 | https://gitlab.com/procps-ng/procps |
| psmisc | 23.7-1 | arm64-v8a, x86_64 | GPL-2.0 | https://gitlab.com/psmisc/psmisc |
| readline | 8.3.6 | arm64-v8a, x86_64 | GPL-3.0 | https://tiswww.case.edu/php/chet/readline/rltop.html |
| sed | 4.9-2 | arm64-v8a, x86_64 | GPL-3.0 | https://www.gnu.org/software/sed/ |
| tar | 1.35-2 | arm64-v8a, x86_64 | GPL-3.0 | https://www.gnu.org/software/tar/ |
| termux-am-socket | 1.5.0-1 | arm64-v8a, x86_64 | GPL-3.0 | https://github.com/termux/termux-am-socket |
| termux-auth | 1.5.0-1 | arm64-v8a, x86_64 | GPL-3.0 | https://github.com/termux/termux-auth |
| termux-licenses | 2.1 | arm64-v8a, x86_64 | GPL-3.0 | https://termux.dev |
| termux-tools | 1.46.0+really1.45.0-1 | arm64-v8a, x86_64 | GPL-3.0 | https://termux.dev/ |
| tree | 2.3.2 | arm64-v8a, x86_64 | GPL-2.0 | http://mama.indstate.edu/users/ice/tree/ |
| util-linux | 2.41.2-1 | arm64-v8a, x86_64 | BSD-2-Clause\*, BSD-3-Clause\*, GPL-2.0\*, GPL-3.0\*, ISC\*, LGPL-2.1\* | https://en.wikipedia.org/wiki/Util-linux |
| which | 2.25 | arm64-v8a, x86_64 | GPL-2.0-or-later | https://savannah.gnu.org/projects/which/ |
| xxhash | 0.8.3-1 | arm64-v8a, x86_64 | BSD-2-Clause\*, GPL-2.0 | https://cyan4973.github.io/xxHash/ |
| xz-utils | 5.8.4 | arm64-v8a, x86_64 | 0BSD†, GPL-2.0† | https://tukaani.org/xz/ |
| zstd | 1.5.7-1 | arm64-v8a, x86_64 | GPL-2.0 | https://github.com/facebook/zstd |

<!-- copyleft:end -->
