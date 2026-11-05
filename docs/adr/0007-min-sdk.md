# ADR-0007: minSdk 26 (owner choice) with a Phase 4 reconciliation gate against t1's minSdk 29

**Status:** Needs decision (gate in Phase 4) · 2026-11-05

## Context
Owner selected minSdk 26 (Android 8.0, ~98% reach) before the audit revealed t1 declares **minSdk 29**. The sealed model itself should work below 29 (exec-from-nativeLibraryDir predates W^X; the restriction only bites at target 29+), but t1 never tested 26–28: bionic API availability (e.g. `openpty`, `posix_spawn` usage), Termux bootstrap's `apt-android-7` floor (Android 7+), and WebView vintage are the unknowns.

## Decision
- Phase 1 scaffolds with **minSdk 26** per owner choice (UI-only, no runtime risk).
- Phase 4 adds a **reconciliation gate**: run the exec-model + sealed-shell instrumentation on API 26, 27, 28 emulators.
  - All green → keep 26, record evidence, this ADR → Accepted.
  - Failures with reasonable fixes (≤ 1 week) → fix, keep 26.
  - Structural failures → raise minSdk to 29 **with owner sign-off**, update Play listing copy, this ADR records the raise.
- No silent minSdk changes; the manifest value is a reviewed constant.

## Consequences
- Device reach stays maximal until evidence says otherwise.
- Phase 4 schedule carries a bounded verification cost (3 emulator legs).
- If raised to 29: ~2–4% of active devices excluded (2026 distribution), documented honestly in listing.
