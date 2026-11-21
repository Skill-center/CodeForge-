# ADR-0010: Distribution — GitHub Releases first ("full" APK), Play-compatible sealed AAB ("base + packs")

**Status:** Accepted (owner choice 2026-11-05: both channels, GitHub first) · 2026-11-05 · Play prepared in Phase 4 W7 (2026-11-18): the drafts, the source offer's mechanism and a proposed closed-test start (below) · the release workflow built in Phase 5 W1, dry until the owner's keys exist (*At Phase 5's end*, below)

## Context
Play forbids post-install executable downloads and caps base modules at 200 MB/device; direct distribution has no such limits. The sealed model satisfies both with one execution model (ADR-0005). t1 already builds the Play shape (arm64 base + `pack_buildtools` PFD) and proves the size gates.

## Decision
- **GitHub Releases (primary, first):** signed "full" APK — sealed core payload + build-tools folded in; arm64-v8a (+ x86_64 dev/emulator artifact); SHA256SUMS + PINS.json published; pre-release flag until Phase 10.
- **Google Play (second track):** sealed AAB — arm64-only base ≤ 200 MB/device, `pack_buildtools` as on-demand Play Feature Delivery; internal → closed → production, manual promotion; data-safety: nothing collected.
- Design for Play constraints **from day one** (no runtime code downloads anywhere, 16 KB alignment, target 36) so the GitHub build never diverges into an unpublishable shape.
- No F-Droid/apt shape in v1 (dual mechanisms rejected by the port guide); revisit only as a separate product decision.
- Release blocked until ADR-0011 (license) resolved + THIRD_PARTY_NOTICES + GPL source offer published. (ADR-0011 resolved on 2026-11-12: Apache-2.0.)

## Consequences
- Users get full toolchain freedom via GitHub immediately; Play users get the same core with store-delivered packs.
- One codebase, two packagings — CI builds both from the same pins; divergence is a gate failure.
- Play Console account + upload key are owner tasks (Phase 10 prep at Phase 4).
- **2026-11-11 (owner):** they are prepared at Phase 4, as planned. A personal developer account created after 13 November 2023 must run a closed test with at least 12 testers, opted in for 14 days in a row, before it can apply for production access (organisation accounts are exempt). The closed test therefore starts well before Phase 10.

## Phase 4 W7 (2026-11-18): Play prepared, the release still blocked

**Done by the agent:**
- **The drafts,** in [docs/store/](../store/README.md), from t1's `store/` templates: the listing, the Data safety answers (nothing collected, nothing shared, each answer with the reason it is true), the privacy policy, and a release checklist. Nothing is submitted.
- **"Nothing collected" is enforced:** CI's *Release manifest* gate fails the build if the release build asks for any permission (`app/tool/ci/check_manifest.py`). Its only entry is androidx.core's own signature permission, which grants nothing outside the app. The debug and profile builds add INTERNET, for Flutter's tooling only. **Amended in Phase 5 W1 (2026-11-18):** by the owner's decision, the release build asks for INTERNET too, so the userland's tools reach the network when the user runs them; the gate allows it and nothing else new. The Data safety answers still say nothing is collected: the app's own code sends nothing, and a command the user runs is a user-initiated transfer (docs/store/data-safety.md).
- **The notices are complete** and kept current by CI: THIRD_PARTY_NOTICES.md names every package of the userland, the app and the editor page, with its version and licence.
- **The source offer's mechanism is decided** (SOURCE_OFFER.md): every binary that contains the userland is published with a source archive, as a GitHub release asset with checksums, and with a written offer valid for at least three years.

**Still blocking any distribution, the closed test included:** the source archive and the offer in About, built with the release workflow; the userland's licence texts in the app's licence page; and a licence review by a qualified person (SOURCE_OFFER.md, *Before the first distribution*). **Phase 5 W1 (2026-11-18):** the first two are built, and the release workflow's dry run passed whole (CI 44399784786: the signed arm64 App Bundle at 146.2 MB per device, the APK, and the source archive). The licence review remains, with the owner's keys and the decision on the first release.

**The closed test, proposed:** it starts with the first build that has the release workflow and the source archive, proposed as Phase 5's first work package, and runs its 14 days alongside Phase 5. With the account verified by the end of November, that could be Monday 2026-12-07, with the 14 days met on 2026-12-21. Aim for 15 to 20 testers, so the count never falls below 12 ([docs/store/README.md](../store/README.md)). **For the owner:** the developer account, Play App Signing with the upload key in CI's secrets, the forms, the testers, and a contact address.

## At Phase 5's end (2026-11-21)

- **The release workflow** (`.github/workflows/release.yml`, W1) builds both channels' files from one commit: the arm64 App Bundle for Play, signed with the upload key, and the arm64 APK for GitHub Releases, signed with the release key, with the source archive, `SHA256SUMS` and the notices beside them (BUILD_AND_RELEASE §2.5, §5). Until the owner's keys exist, every run is a dry run with throwaway keys, and nothing is published.
- **The release build asks for four permissions besides androidx.core's own:** INTERNET (W1), and FOREGROUND_SERVICE, FOREGROUND_SERVICE_SPECIAL_USE and POST_NOTIFICATIONS for the terminal sessions' foreground service (W5). CI's *Release manifest* gate allows exactly these and `SessionService`. The Data safety answers still say nothing is collected, and Play's special-use declaration is drafted for the owner (docs/store/listing.md).
- **Still nothing is distributed.** The licence review, the owner's keys and the decision on the first release remain (PHASE_5_REPORT §10). The closed test can start from a build with the terminal and *Run*.
