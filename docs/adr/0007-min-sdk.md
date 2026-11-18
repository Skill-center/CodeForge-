# ADR-0007: minSdk 26 (owner choice) with a Phase 4 reconciliation gate against t1's minSdk 29

**Status:** **Accepted at minSdk 26 (2026-11-18, Phase 4 W5):** the reconciliation gate passed on API 26, 27 and 28 (phase gate 44239443885; *Result* below) · decided by the owner on 2026-11-11 (minSdk stays 26, to be verified by this gate; a raise to 29 would have needed the owner's sign-off) · proposed 2026-11-05 ("needs decision")

## Context
Owner selected minSdk 26 (Android 8.0, ~98% reach) before the audit revealed t1 declares **minSdk 29**. The sealed model itself should work below 29 (exec-from-nativeLibraryDir predates W^X; the restriction only bites at target 29+), but t1 never tested 26–28: bionic API availability (e.g. `openpty`, `posix_spawn` usage), Termux bootstrap's `apt-android-7` floor (Android 7+), and WebView vintage are the unknowns.

## Decision
- Phase 1 scaffolds with **minSdk 26** per owner choice (UI-only, no runtime risk).
- Phase 4 adds a **reconciliation gate**: run the exec-model + sealed-shell instrumentation on API 26, 27, 28 emulators.
  - All green → keep 26, record evidence, this ADR → Accepted.
  - Failures with reasonable fixes (≤ 1 week) → fix, keep 26.
  - Structural failures → raise minSdk to 29 **with owner sign-off**, update Play listing copy, this ADR records the raise.
- No silent minSdk changes; the manifest value is a reviewed constant.

## Result (Phase 4 W5, 2026-11-18)

**The gate:** the phase gate's runtime gates (PHASE_4_PLAN *As built (W5)*; jobs of `phase-gate.yml` then, of `ci.yml` since W6). One build of the debug APK, which carries the x86_64 payload and targets API 36, then one x86_64 emulator per API level, each running four instrumented classes:
- t1's `ExecModelTest` and `SealedShellTest`, ported (native/PROVENANCE.md);
- W3's `RuntimeInstallTest` and W4's `RuntimeCommandsTest`.

That is 16 tests a leg. `tool/ci/gate_results.py` requires every class to run, unskipped and green, and every audit to report 0.

**Phase gate 44239443885** (`c4b2577`; evidence in `app/ci-results/runtime-gates/`): every leg passed, 16 of 16.

| | API 26 | API 27 | API 28 | API 34 | API 36 |
|---|---|---|---|---|---|
| Android, kernel | 8.0.0, 3.18 | 8.1.0, 3.18 | 9, 4.4 | 14, 6.1 | 16, 6.6 |
| Image | google_apis | AOSP default (no google_apis x86_64 image) | google_apis | google_apis | google_apis |
| Exec from app data (ExecModelTest) | allowed | allowed | allowed | denied | denied |
| t1's kernel reading a manifest stream | `NoSuchMethodError` | `NoSuchMethodError` | `NoSuchMethodError` | read | read |
| First install, instrumented | 8,114 ms | 7,980 ms | 5,978 ms | 9,082 ms | 6,001 ms |
| Warm start, median of 5 | 13 ms | 15 ms | 12 ms | 37 ms | 25 ms |
| `ExecAudit` outside the APK | 0 | 0 | 0 | 0 | 0 |
| The seven tools at their pins | yes | yes | yes | yes | yes |
| WebView of the image | Chrome 69 | WebView 61 | Chrome 69 | 113 | 133 |

**The three unknowns:**
- **bionic:** nothing failed. CodeForge's native code (the preload, the probe, the launcher) compiles against the NDK's API 26 headers, so a call newer than 26 cannot even link. Termux's packages target API 24. The PTY (`openpty`) comes with Phase 5's terminal; bionic has it from API 23.
- **The bootstrap's `apt-android-7` floor:** the payload installs, verifies and runs on Android 8.0:
  - all seven tools at their pins, npm through the preload, bash and sed;
  - dpkg's database agrees with the shipped packages;
  - no child is left after an end, a time limit or an exit.
- **WebView:** recorded, not tested. The editor page is built for Chrome 87 and later (`editor/tool/build.mjs`: `es2020`, `chrome87`). Google ended Chrome's updates for Android 8 and 9 at Chrome 138 (June 2025), so a phone there that updates its WebView from the store is far above 87. A phone whose WebView was never updated, like these emulator images (61 and 69), could not run the editor page. The runtime does not depend on WebView.
  - **Decided on 2026-11-18, built in W6** (W5's proposal; the owner left the decision to the agent): before loading the editor page, the editor host reads the WebView's version from its user agent (`Chrome/<major>`). Below 87 it does not load the page, which could not start, and says plainly which version the phone has and what to update, instead of a generic failure after 20 seconds. *Try again* checks again, so an updated WebView works without reinstalling. The floor is one constant (`app/lib/core/editor/webview_floor.dart`), and a test fails if it ever differs from the page's build target in `build.mjs`. A WebView that can't report a version is not refused.

**What the gate found was not Android's:** t1's kernel reads its manifest stream with `InputStream.readAllBytes()`. Android has that method only from API 33, and D8 does not backport it. So every runtime install through the kernel's entry point failed on Android 8.0 to 12L (API 26 to 32), half of it above t1's own floor. W5 found it by review before the legs ran, and the legs then measured it: `RuntimeInstallTest` g calls the method itself, with `NoSuchMethodError` on API 26 to 28 and a normal read on 34 and 36.
- It was fixed without editing the vendored file: the runtime host made the entry point's calls itself (`PayloadInstall.kt`). **Superseded in Phase 4 W7:** the owner allowed changes to t1's code (2026-11-18), so the fix is now applied to CodeForge's copy of the kernel as a recorded patch (`native/patches/t1-0001-runtime-manifest-read.patch`; native/PROVENANCE.md, *Patches*), the host installs through `SealedInstaller.install` again, and `PayloadInstall.kt` is gone. `RuntimeInstallTest` g now reads a manifest through the patched kernel on every leg (CI 44297145654 built it; the W7 phase gate runs it on API 26 to 36).
- CI now keeps the whole app at the floor: `tool/ci/check_api_floor.py` checks every method, field and class CodeForge's own and vendored code refers to in the debug APK's dex against the SDK's API database. Its first run (CI 44233761227) found no other violation. One call sits behind a version check, and four vendored methods are never called.

**Decision:** minSdk stays 26. This ADR is Accepted.

## Consequences
- Device reach stays maximal until evidence says otherwise: the Play listing can say Android 8.0 and later.
- Phase 4 schedule carries a bounded verification cost (3 emulator legs). They run in every phase gate from W5 on, with API 34 and 36.
- If raised to 29: ~2–4% of active devices excluded (2026 distribution), documented honestly in listing. *(Not needed: see Result.)*
- A Java or Android API newer than 26 now fails CI's API floor check unless it sits behind a version check, so the floor holds for code that no emulator leg runs.
