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
<!-- Written by runtime/notices.py from runtime/pins.json and the pinned files. Do not edit by hand: CI checks it. -->

**112 package versions** ship in the payloads: the bootstrap `2026.02.12-r1+apt.android-7` refreshed by the pinned core set (resolved 2026-11-13T09:43:19Z). Per ABI: arm64-v8a 112 packages, 50 of them pinned; x86_64 112 packages, 50 of them pinned.

Licences, counted per package version: GPL-3.0 23, GPL-2.0 22, MIT 16, BSD-2-Clause 13, BSD-3-Clause 13, LGPL-2.1 10, unidentified 8, Apache-2.0 5, LGPL-3.0 5, ISC 3, Public Domain 3, Artistic-License-2.0 2, curl 2, LGPL-2.0 2, Zlib 2, AGPL-3.0-only 1, Artistic-2.0 1, GPL-2.0-or-later 1, GPL-3.0-or-later 1, MPL-2.0 1, NCSA 1, PSF-2.0 1, Ruby 1, Unicode-3.0 1.

A licence with an asterisk was identified from its text's wording; the others are named by Termux's link to `share/LICENSES/<id>.txt`, exactly as Termux names them. The texts ship in the payload at the paths shown (prefix-relative).

**To review (W7):** no licence was identified for `bzip2`, `curl`, `file`, `gpgv`, `libicu`, `liblzma`, `libsmartcols`, `lsof`, `ncurses-ui-libs`, `openssh-sftp-server`, `pcre2`, `ripgrep`, `termux-core`, `termux-exec`, `unzip`, `xz-utils`.

| Package | Version | ABIs | Licence | Licence text in the payload | Homepage |
|---|---|---|---|---|---|
| apt | 2.8.1-2 | arm64-v8a, x86_64 | GPL-2.0 | `share/doc/apt/copyright` → `share/LICENSES/GPL-2.0.txt` | https://packages.debian.org/apt |
| attr | 2.5.2-1 | arm64-v8a, x86_64 | GPL-2.0\*, LGPL-2.1\*, GPL-2.0 | `share/doc/attr/COPYING`<br>`share/doc/attr/COPYING.LGPL`<br>`share/doc/attr/copyright` → `share/LICENSES/GPL-2.0.txt` | http://savannah.nongnu.org/projects/attr/ |
| bash | 5.3.9 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/bash/copyright` → `share/LICENSES/GPL-3.0.txt` | https://www.gnu.org/software/bash/ |
| bzip2 | 1.0.8-8 | arm64-v8a, x86_64 | none found | — | http://www.bzip.org/ |
| c-ares | 1.34.9 | arm64-v8a, x86_64 | MIT\* | `share/doc/c-ares/copyright` | https://c-ares.org/ |
| ca-certificates | 1:2026.11.05-1 | arm64-v8a, x86_64 | MPL-2.0 | `share/doc/ca-certificates/copyright` → `share/LICENSES/MPL-2.0.txt` | https://curl.se/docs/caextract.html |
| command-not-found | 3.2-16 | arm64-v8a, x86_64 | Apache-2.0 | `share/doc/command-not-found/copyright` → `share/LICENSES/Apache-2.0.txt` | https://github.com/termux/command-not-found |
| coreutils | 9.9 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/coreutils/copyright` → `share/LICENSES/GPL-3.0.txt` | https://www.gnu.org/software/coreutils/ |
| curl | 8.23.0 | arm64-v8a, x86_64 | none found | — | https://curl.se/ |
| dash | 0.5.12-2 | arm64-v8a, x86_64 | BSD-3-Clause\* | `share/doc/dash/copyright` | http://gondor.apana.org.au/~herbert/dash/ |
| debianutils | 5.23.2-1 | arm64-v8a, x86_64 | GPL-2.0 | `share/doc/debianutils/copyright` → `share/LICENSES/GPL-2.0.txt` | https://packages.debian.org/debianutils |
| dialog | 1.3-20240307-1 | arm64-v8a, x86_64 | LGPL-2.1 | `share/doc/dialog/copyright` → `share/LICENSES/LGPL-2.1.txt` | https://invisible-island.net/dialog/ |
| diffutils | 3.12-2 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/diffutils/copyright` → `share/LICENSES/GPL-3.0.txt` | https://www.gnu.org/software/diffutils/ |
| dos2unix | 7.5.2-1 | arm64-v8a, x86_64 | BSD-2-Clause\* | `share/doc/dos2unix/COPYING.txt` | https://waterlan.home.xs4all.nl/dos2unix.html |
| dpkg | 1.22.6-5 | arm64-v8a, x86_64 | GPL-2.0 | `share/doc/dpkg/copyright` → `share/LICENSES/GPL-2.0.txt` | https://packages.debian.org/dpkg |
| ed | 1.22.5 | arm64-v8a, x86_64 | GPL-2.0 | `share/doc/ed/copyright` → `share/LICENSES/GPL-2.0.txt` | https://www.gnu.org/software/ed/ |
| file | 5.48-3 | arm64-v8a, x86_64 | none found | — | https://darwinsys.com/file/ |
| findutils | 4.10.0-1 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/findutils/copyright` → `share/LICENSES/GPL-3.0.txt` | https://www.gnu.org/software/findutils/ |
| gawk | 5.3.1-2 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/gawk/copyright` → `share/LICENSES/GPL-3.0.txt` | https://www.gnu.org/software/gawk/ |
| gdbm | 1.26-1 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/gdbm/copyright` → `share/LICENSES/GPL-3.0.txt` | https://www.gnu.org.ua/software/gdbm/ |
| git | 2.56.1 | arm64-v8a, x86_64 | GPL-2.0 | `share/doc/git/copyright` → `share/LICENSES/GPL-2.0.txt` | https://git-scm.com/ |
| gpgv | 2.5.17 | arm64-v8a, x86_64 | none found | — | https://www.gnupg.org/ |
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
| libbz2 | 1.0.8-8 | arm64-v8a, x86_64 | BSD-2-Clause\* | `share/doc/libbz2/copyright` | http://www.bzip.org/ |
| libc++ | 30 | arm64-v8a, x86_64 | NCSA | `share/doc/libc++/copyright` → `share/LICENSES/NCSA.txt` | https://libcxx.llvm.org/ |
| libcap-ng | 2:0.9 | arm64-v8a, x86_64 | LGPL-2.1 | `share/doc/libcap-ng/copyright` → `share/LICENSES/LGPL-2.1.txt` | https://people.redhat.com/sgrubb/libcap-ng/ |
| libcrypt | 0.2-6 | arm64-v8a, x86_64 | BSD-2-Clause\* | `share/doc/libcrypt/copyright` | http://michael.dipperstein.com/crypt/ |
| libcurl | 8.23.0 | arm64-v8a, x86_64 | curl\* | `share/doc/libcurl/copyright` | https://curl.se/ |
| libdb | 18.1.40-6 | arm64-v8a, x86_64 | AGPL-3.0-only | `share/doc/libdb/copyright` → `share/LICENSES/AGPL-3.0-only.txt` | https://www.oracle.com/database/berkeley-db |
| libedit | 20260512-3.1-0 | arm64-v8a, x86_64 | BSD-3-Clause\* | `share/doc/libedit/copyright` | https://thrysoee.dk/editline/ |
| libevent | 2.1.12-3 | arm64-v8a, x86_64 | MIT\*, BSD-2-Clause\* | `share/doc/libevent/copyright` | https://libevent.org/ |
| libexpat | 2.10.0 | arm64-v8a, x86_64 | MIT\* | `share/doc/libexpat/copyright` | https://libexpat.github.io/ |
| libffi | 3.8.0 | arm64-v8a, x86_64 | MIT\* | `share/doc/libffi/copyright` | https://sourceware.org/libffi/ |
| libgcrypt | 1.11.2-1 | arm64-v8a, x86_64 | GPL-2.0\*, LGPL-2.1\* | `share/doc/libgcrypt/COPYING`<br>`share/doc/libgcrypt/COPYING.LIB` | https://www.gnu.org/software/libgcrypt/ |
| libgmp | 6.3.0-2 | arm64-v8a, x86_64 | LGPL-3.0 | `share/doc/libgmp/copyright` → `share/LICENSES/LGPL-3.0.txt` | https://gmplib.org/ |
| libgnutls | 3.8.11 | arm64-v8a, x86_64 | LGPL-2.1, GPL-3.0 | `share/doc/libgnutls/copyright` → `share/LICENSES/LGPL-2.1.txt`<br>`share/doc/libgnutls/copyright.1` → `share/LICENSES/GPL-3.0.txt` | https://www.gnutls.org/ |
| libgpg-error | 1.58 | arm64-v8a, x86_64 | LGPL-2.1 | `share/doc/libgpg-error/copyright` → `share/LICENSES/LGPL-2.1.txt` | https://www.gnupg.org/related_software/libgpg-error/ |
| libiconv | 1.19.1 | arm64-v8a, x86_64 | LGPL-2.1, GPL-3.0 | `share/doc/libiconv/copyright` → `share/LICENSES/LGPL-2.1.txt`<br>`share/doc/libiconv/copyright.1` → `share/LICENSES/GPL-3.0.txt` | https://www.gnu.org/software/libiconv/ |
| libicu | 79.1 | arm64-v8a, x86_64 | unidentified\* | `share/doc/libicu/LICENSE` | http://site.icu-project.org/home |
| libidn2 | 2.3.8-1 | arm64-v8a, x86_64 | LGPL-3.0, GPL-2.0, GPL-3.0 | `share/doc/libidn2/copyright` → `share/LICENSES/LGPL-3.0.txt`<br>`share/doc/libidn2/copyright.1` → `share/LICENSES/GPL-2.0.txt`<br>`share/doc/libidn2/copyright.2` → `share/LICENSES/GPL-3.0.txt` | https://www.gnu.org/software/libidn/#libidn2 |
| liblz4 | 1.10.0-1 | arm64-v8a, x86_64 | GPL-2.0 | `share/doc/liblz4/copyright` → `share/LICENSES/GPL-2.0.txt` | https://lz4.github.io/lz4/ |
| liblzma | 5.8.4 | arm64-v8a, x86_64 | unidentified\*, GPL-2.0\*, GPL-3.0\*, LGPL-2.1\* | `share/doc/liblzma/COPYING`<br>`share/doc/liblzma/COPYING.GPLv2`<br>`share/doc/liblzma/COPYING.GPLv3`<br>`share/doc/liblzma/COPYING.LGPLv2.1` | https://tukaani.org/xz/ |
| libmagic | 5.48-3 | arm64-v8a, x86_64 | BSD-2-Clause\* | `share/doc/libmagic/copyright` | https://darwinsys.com/file/ |
| libmd | 1.1.0-1 | arm64-v8a, x86_64 | BSD-3-Clause\* | `share/doc/libmd/COPYING` | https://www.hadrons.org/software/libmd/ |
| libmpfr | 4.2.1-1 | arm64-v8a, x86_64 | LGPL-3.0 | `share/doc/libmpfr/copyright` → `share/LICENSES/LGPL-3.0.txt` | https://www.mpfr.org/ |
| libnettle | 4.0+really3.10.2 | arm64-v8a, x86_64 | GPL-2.0, LGPL-3.0 | `share/doc/libnettle/copyright` → `share/LICENSES/GPL-2.0.txt`<br>`share/doc/libnettle/copyright.1` → `share/LICENSES/LGPL-3.0.txt` | https://www.lysator.liu.se/~nisse/nettle/ |
| libnghttp2 | 1.71.0 | arm64-v8a, x86_64 | MIT\* | `share/doc/libnghttp2/copyright` | https://nghttp2.org/ |
| libnghttp3 | 1.19.0 | arm64-v8a, x86_64 | MIT\* | `share/doc/libnghttp3/copyright` | https://nghttp2.org/nghttp3/ |
| libngtcp2 | 1.26.0 | arm64-v8a, x86_64 | MIT\* | `share/doc/libngtcp2/copyright` | https://github.com/ngtcp2/ngtcp2 |
| libnpth | 1.6-3 | arm64-v8a, x86_64 | LGPL-2.0 | `share/doc/libnpth/copyright` → `share/LICENSES/LGPL-2.0.txt` | https://www.gnupg.org/related_software/npth/ |
| libresolv-wrapper | 1.1.8 | arm64-v8a, x86_64 | BSD-3-Clause\* | `share/doc/libresolv-wrapper/copyright` | https://cwrap.org/resolv_wrapper.html |
| libsmartcols | 2.41.2-1 | arm64-v8a, x86_64 | none found | — | https://en.wikipedia.org/wiki/Util-linux |
| libsqlite | 3.54.1-1 | arm64-v8a, x86_64 | Public Domain | `share/doc/libsqlite/copyright` → `share/LICENSES/Public Domain.txt` | https://www.sqlite.org |
| libssh2 | 1.11.1-2 | arm64-v8a, x86_64 | BSD-3-Clause\* | `share/doc/libssh2/copyright` | https://www.libssh2.org |
| libtirpc | 1.3.7-1 | arm64-v8a, x86_64 | BSD-2-Clause\* | `share/doc/libtirpc/copyright` | http://git.linux-nfs.org/?p=steved/libtirpc.git |
| libunbound | 1.24.2-1 | arm64-v8a, x86_64 | BSD-3-Clause\* | `share/doc/libunbound/copyright` | https://unbound.net/ |
| libunistring | 1.3-1 | arm64-v8a, x86_64 | LGPL-3.0, GPL-2.0 | `share/doc/libunistring/copyright` → `share/LICENSES/LGPL-3.0.txt`<br>`share/doc/libunistring/copyright.1` → `share/LICENSES/GPL-2.0.txt` | https://www.gnu.org/software/libunistring/ |
| libyaml | 0.2.5-5 | arm64-v8a, x86_64 | MIT\* | `share/doc/libyaml/copyright` | https://pyyaml.org/wiki/LibYAML |
| lsof | 4.99.5-2 | arm64-v8a, x86_64 | unidentified\* | `share/doc/lsof/COPYING` | https://github.com/lsof-org/lsof |
| nano | 8.7.1 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/nano/copyright` → `share/LICENSES/GPL-3.0.txt` | https://www.nano-editor.org/ |
| ncurses | 6.6.20260307+really6.5.20250830 | arm64-v8a, x86_64 | MIT\* | `share/doc/ncurses/copyright` | https://invisible-island.net/ncurses/ |
| ncurses-ui-libs | 6.6.20260307+really6.5.20250830 | arm64-v8a, x86_64 | none found | — | https://invisible-island.net/ncurses/ |
| net-tools | 2.10.0-1 | arm64-v8a, x86_64 | GPL-2.0 | `share/doc/net-tools/copyright` → `share/LICENSES/GPL-2.0.txt` | http://net-tools.sourceforge.net/ |
| nodejs | 26.13.1 | arm64-v8a, x86_64 | Apache-2.0\*, Artistic-2.0\*, ISC\*, MIT\*, BSD-3-Clause\*, Zlib\*, Unicode-3.0\*, GPL-3.0-or-later\* | `share/doc/nodejs/copyright` | https://nodejs.org/ |
| npm | 12.2.2 | arm64-v8a, x86_64 | Artistic-License-2.0 | `share/doc/npm/copyright` → `share/LICENSES/Artistic-License-2.0.txt` | https://docs.npmjs.com/cli/ |
| oniguruma | 6.9.10-1 | arm64-v8a, x86_64 | BSD-2-Clause\* | `share/doc/oniguruma/copyright` | https://github.com/kkos/oniguruma |
| openssh | 10.6p2 | arm64-v8a, x86_64 | BSD-3-Clause\* | `share/doc/openssh/copyright` | https://www.openssh.com/ |
| openssh-sftp-server | 10.6p2 | arm64-v8a, x86_64 | none found | — | https://www.openssh.com/ |
| openssl | 1:3.6.5 | arm64-v8a, x86_64 | Apache-2.0 | `share/doc/openssl/copyright` → `share/LICENSES/Apache-2.0.txt` | https://www.openssl.org/ |
| patch | 2.8-1 | arm64-v8a, x86_64 | GPL-2.0 | `share/doc/patch/copyright` → `share/LICENSES/GPL-2.0.txt` | https://savannah.gnu.org/projects/patch/ |
| pcre2 | 10.49 | arm64-v8a, x86_64 | unidentified\*, BSD-3-Clause\* | `share/doc/pcre2/COPYING`<br>`share/doc/pcre2/LICENCE.md`<br>`share/doc/pcre2/copyright`<br>`share/doc/pcre2/copyright.1` | https://pcre2project.github.io/pcre2/ |
| perl | 5.44.0-1 | arm64-v8a, x86_64 | Artistic-License-2.0 | `share/doc/perl/copyright` → `share/LICENSES/Artistic-License-2.0.txt` | https://www.perl.org/ |
| procps | 3.3.17-6 | arm64-v8a, x86_64 | LGPL-2.0 | `share/doc/procps/copyright` → `share/LICENSES/LGPL-2.0.txt` | https://gitlab.com/procps-ng/procps |
| psmisc | 23.7-1 | arm64-v8a, x86_64 | GPL-2.0 | `share/doc/psmisc/copyright` → `share/LICENSES/GPL-2.0.txt` | https://gitlab.com/psmisc/psmisc |
| python | 3.14.10 | arm64-v8a, x86_64 | PSF-2.0\*, ISC\* | `share/doc/python/LICENSE` | https://python.org/ |
| python-pip | 26.3 | arm64-v8a, x86_64 | MIT\* | `share/doc/python-pip/copyright` | https://pip.pypa.io/ |
| readline | 8.3.6 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/readline/copyright` → `share/LICENSES/GPL-3.0.txt` | https://tiswww.case.edu/php/chet/readline/rltop.html |
| resolv-conf | 1.3 | arm64-v8a, x86_64 | Public Domain | `share/doc/resolv-conf/LICENSE` → `share/LICENSES/Public Domain.txt` | https://man7.org/linux/man-pages/man5/resolv.conf.5.html |
| ripgrep | 15.2.0 | arm64-v8a, x86_64 | unidentified\*, MIT\* | `share/doc/ripgrep/copyright`<br>`share/doc/ripgrep/copyright.1` | https://github.com/BurntSushi/ripgrep |
| ruby | 4.0.9 | arm64-v8a, x86_64 | Ruby\* | `share/doc/ruby/copyright` | https://www.ruby-lang.org/ |
| sed | 4.9-2 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/sed/copyright` → `share/LICENSES/GPL-3.0.txt` | https://www.gnu.org/software/sed/ |
| tar | 1.35-2 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/tar/copyright` → `share/LICENSES/GPL-3.0.txt` | https://www.gnu.org/software/tar/ |
| termux-am | 0.8.0-2 | arm64-v8a, x86_64 | Apache-2.0 | `share/doc/termux-am/copyright` → `share/LICENSES/Apache-2.0.txt` | https://github.com/termux/TermuxAm |
| termux-am-socket | 1.5.0-1 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/termux-am-socket/copyright` → `share/LICENSES/GPL-3.0.txt` | https://github.com/termux/termux-am-socket |
| termux-auth | 1.5.0-1 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/termux-auth/copyright` → `share/LICENSES/GPL-3.0.txt` | https://github.com/termux/termux-auth |
| termux-core | 0.4.0-1 | arm64-v8a, x86_64 | unidentified\* | `share/doc/termux-core/copyright` | https://github.com/termux/termux-core-package |
| termux-exec | 1:2.4.0-1 | arm64-v8a, x86_64 | unidentified\* | `share/doc/termux-exec/copyright` | https://github.com/termux/termux-exec-package |
| termux-keyring | 3.13 | arm64-v8a, x86_64 | Apache-2.0 | `share/doc/termux-keyring/copyright` → `share/LICENSES/Apache-2.0.txt` | https://github.com/termux |
| termux-licenses | 2.1 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/termux-licenses/copyright` → `share/LICENSES/GPL-3.0.txt` | https://termux.dev |
| termux-tools | 1.46.0+really1.45.0-1 | arm64-v8a, x86_64 | GPL-3.0 | `share/doc/termux-tools/copyright` → `share/LICENSES/GPL-3.0.txt` | https://termux.dev/ |
| tree | 2.3.2 | arm64-v8a, x86_64 | GPL-2.0 | `share/doc/tree/copyright` → `share/LICENSES/GPL-2.0.txt` | http://mama.indstate.edu/users/ice/tree/ |
| unzip | 6.0-10 | arm64-v8a, x86_64 | unidentified\* | `share/doc/unzip/copyright` | https://sourceforge.net/projects/infozip/ |
| util-linux | 2.41.2-1 | arm64-v8a, x86_64 | BSD-2-Clause\*, BSD-3-Clause\*, GPL-2.0\*, GPL-3.0\*, ISC\*, LGPL-2.1\* | `share/doc/util-linux/COPYING.BSD-3-Clause`<br>`share/doc/util-linux/COPYING.BSD-4-Clause-UC`<br>`share/doc/util-linux/COPYING.GPL-2.0-or-later`<br>`share/doc/util-linux/COPYING.GPL-3.0-or-later`<br>`share/doc/util-linux/COPYING.ISC`<br>`share/doc/util-linux/COPYING.LGPL-2.1-or-later` | https://en.wikipedia.org/wiki/Util-linux |
| which | 2.25 | arm64-v8a, x86_64 | GPL-2.0-or-later | `share/doc/which/copyright` → `share/LICENSES/GPL-2.0-or-later.txt` | https://savannah.gnu.org/projects/which/ |
| xxhash | 0.8.3-1 | arm64-v8a, x86_64 | BSD-2-Clause\*, GPL-2.0 | `share/doc/xxhash/copyright`<br>`share/doc/xxhash/copyright.1` → `share/LICENSES/GPL-2.0.txt` | https://cyan4973.github.io/xxHash/ |
| xz-utils | 5.8.4 | arm64-v8a, x86_64 | none found | — | https://tukaani.org/xz/ |
| zlib | 1.4 | arm64-v8a, x86_64 | Zlib\* | `share/doc/zlib/copyright` | https://www.zlib.net/ |
| zstd | 1.5.7-1 | arm64-v8a, x86_64 | GPL-2.0 | `share/doc/zstd/copyright` → `share/LICENSES/GPL-2.0.txt` | https://github.com/facebook/zstd |

<!-- userland:end -->

## 5. Before the first binary release (W7)

- [ ] Sections 2 and 3 listed, from `pubspec.lock` and the editor's manifest.
- [ ] Every "To review" entry in section 4 resolved, and each licence with an asterisk checked against its text.
- [ ] The app shows these notices: Flutter's licence page, plus the userland's texts.
- [ ] PROVENANCE.md's question answered: whether the vendored files need a notice inside them.
