# ADR-0010: Distribution — GitHub Releases first ("full" APK), Play-compatible sealed AAB ("base + packs")

**Status:** Accepted (owner choice 2026-11-05: both channels, GitHub first) · 2026-11-05

## Context
Play forbids post-install executable downloads and caps base modules at 200 MB/device; direct distribution has no such limits. The sealed model satisfies both with one execution model (ADR-0005). t1 already builds the Play shape (arm64 base + `pack_buildtools` PFD) and proves the size gates.

## Decision
- **GitHub Releases (primary, first):** signed "full" APK — sealed core payload + build-tools folded in; arm64-v8a (+ x86_64 dev/emulator artifact); SHA256SUMS + PINS.json published; pre-release flag until Phase 10.
- **Google Play (second track):** sealed AAB — arm64-only base ≤ 200 MB/device, `pack_buildtools` as on-demand Play Feature Delivery; internal → closed → production, manual promotion; data-safety: nothing collected.
- Design for Play constraints **from day one** (no runtime code downloads anywhere, 16 KB alignment, target 36) so the GitHub build never diverges into an unpublishable shape.
- No F-Droid/apt shape in v1 (dual mechanisms rejected by the port guide); revisit only as a separate product decision.
- Release blocked until ADR-0011 (license) resolved + THIRD_PARTY_NOTICES + GPL source offer published.

## Consequences
- Users get full toolchain freedom via GitHub immediately; Play users get the same core with store-delivered packs.
- One codebase, two packagings — CI builds both from the same pins; divergence is a gate failure.
- Play Console account + upload key are owner tasks (Phase 10 prep at Phase 4).
- **2026-11-11 (owner):** they are prepared at Phase 4, as planned. A personal developer account created after 13 November 2023 must run a closed test with at least 12 testers, opted in for 14 days in a row, before it can apply for production access (organisation accounts are exempt). The closed test therefore starts well before Phase 10.
