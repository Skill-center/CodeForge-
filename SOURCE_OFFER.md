# Source offer

> **Draft (Phase 4 W2).** ADR-0011's interim rule 3 and ADR-0010: this is published before any binary release that contains the userland, and W7 completes it. It is not legal advice: W7's licence review checks it.

## Why there is one

CodeForge's own code is Apache-2.0, and it is public in this repository. The app's runtime payload, however, contains Termux packages under copyleft licences: GPL, LGPL and others (the table below). Whoever distributes their binaries, in an APK on Play or anywhere else, must make the corresponding source available on the terms of each licence. For the GPL, the binaries must either come with the source, or come with a written offer of it that is valid for at least three years (GPL-2.0 §3, GPL-3.0 §6).

## What the corresponding source is

For each package version in the payload:

- **The upstream release.** The source release that Termux's build recipe names (`TERMUX_PKG_SRCURL`, with its SHA-256).
- **Termux's recipe and patches.** The package's directory in https://github.com/termux/termux-packages, at the commit that built that version.
- **The bootstrap.** The same for every package the bootstrap contains, plus Termux's scripts that build the bootstrap.

## How CodeForge will provide it (decided in W7)

**The recommendation: publish the source with every release, and point to it from a written offer.**

- **The source.** The release workflow (ADR-0010) assembles the corresponding source of every copyleft package version from the pins: the upstream archives, and Termux's recipe directories at the matching commits.
- **Where it goes.** It is published next to the APK, as a GitHub release asset, with checksums.
- **The offer.** The app and this file carry a written offer, valid for at least three years after the last distribution of each binary, that points to that archive. Honouring the offer then costs nothing.

**Open points for W7 and the owner:**

- [ ] Choose the mechanism. The recommendation is above.
- [ ] Map each pinned version to the termux-packages commit that built it (the history of the recipe's `TERMUX_PKG_VERSION`).
- [ ] Choose the contact address for source requests.
- [ ] Decide whether the Play listing links to this file.
- [ ] Have this file and THIRD_PARTY_NOTICES.md reviewed.

## The copyleft packages in the payload

<!-- copyleft:begin -->
_Not generated yet: the first `[repin]` CI run resolves the pins and writes this section._
<!-- copyleft:end -->
