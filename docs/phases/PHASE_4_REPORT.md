# Phase 4 Report — Runtime Integration

**Status:** **Accepted by the owner on 2026-11-18** (the owner's "next" on 2026-11-18, after the report asked to accept the phase or ask for changes); the phone session (§8) and Play's owner actions (§10) are still open, and non-blocking · **Date:** 2026-11-18 · **Branch:** `arena/f57c33ee-codeforge`
**Plan:** [PHASE_4_PLAN.md](PHASE_4_PLAN.md) · **Spec:** §8 Phase 4, §2, §6.4–6.5, §7 · **Rule:** every claim below cites a CI run, a phase gate or an evidence commit. Where something was not measured or not met, this report says so.

---

## 1. Summary

Phase 4 puts t1's audited sealed Linux userland inside CodeForge, and proves it on real targets:
- **The runtime ships in the APK and installs itself.** The first time a workspace opens, the app extracts and verifies the userland: 13,894 files, about 275 MB. Its programs run only from the APK's native-library folder. It took 13.4 s on a physical Google Pixel 8a in the exit gate (13.6 s in W5), and a warm start then took 64 ms (73 ms in W5). At every start, the app checks that every program comes from the APK: 0 from anywhere else, on every device it ran on.
- **Seven tools, at their pinned versions:** node 26.13.1, python 3.14.10, git 2.56.1, bash 5.3.9, perl 5.44.0, ruby 4.0.9 and ripgrep 15.2.0. Settings → *Linux runtime* shows each one's version beside its pin, the install and start times, the program check and the space used.
- **Commands run under CodeForge's own exec model:** a time limit, an output cap, and an end that takes the whole process tree with it, with nothing left running (SECURITY §2.1). The terminal that uses them is Phase 5's.
- **Search across files works.** Projects are searched by the runtime's ripgrep, about 120 ms for 10,000 files on the Pixel 8a. Folders from shared storage are searched by CodeForge's own scan. A result opens at its line.
- **Real targets:** emulators with Android 8.0, 8.1, 9, 14 and 16 in every phase gate, and a physical arm64 phone in Firebase Test Lab. So minSdk 26 is confirmed (ADR-0007 Accepted).
- **The supply chain is pinned and checked:** every input of the userland by SHA-256, failing closed when one is missing. Every vendored file of t1 is recorded and checked against t1 on every push, and CodeForge's one fix to t1's kernel is a recorded patch.
- **Ready for distribution, short of four items:** the third-party notices are complete and kept current by CI, and the source offer's mechanism is decided. The Play drafts are written, and the release build asks for no permissions, which CI checks. The source archive, the offer in the app, the licence texts in the app, and a licence review come before any binary goes out (§9.2).

**All nine gates are met** (§4). Not met, and why:
- **Phone figures:** apart from Test Lab's Pixel 8a, none. The owner's phone session waits: [PHASE_4_PHONE_CHECKLIST.md](PHASE_4_PHONE_CHECKLIST.md), in the same sitting as Phase 3's (§8).
- **No binary release yet** (ADR-0010). The four items above need the release workflow, proposed for Phase 5's first work package.
- **Play needs the owner:** the developer account, Play App Signing, the testers and a contact address ([docs/store/](../store/README.md)).

## 2. Evidence index

| Work package | Done | CI runs | Phase gates | Test Lab |
|---|---|---|---|---|
| W1 Toolchain | 2026-11-13 | 43373527631, 43375227087, 43379964388, 43384226740 | 43375227077 ✗, 43379964330 ✗, **43384226759** ✓ (§9.3) | — |
| W2 Kernel and pins | 2026-11-13 | 43401882656, 43403453442 | — | — |
| W3 Install and audit | 2026-11-16 | 43807290310, 43808489952, 43815154032 | **43808489945** | — |
| W4 Commands and tools | 2026-11-16 | 43830252596, 43833197358, 43835601536 | **43837693816** | — |
| W5 The runtime gates | 2026-11-18 | 44233761227, 44239443972, 44244875981 | 44235180242 ✗, 44236831476 ✗, 44237799081 ✗, **44239443885** ✓ (§9.3) | **CI 44240926191** (Pixel 8a, 17 of 17) |
| W5's decisions, one workflow | 2026-11-18 | 44251612994 (its gate ran too) | 44251612994 | — |
| W6 Search | 2026-11-18 | 44262330746 ✗ (analysis), 44270655389 ✗ (format), 44273190097 | **44264577788**, **44275357542** | **CI 44275357542** (Pixel 8a, 18 of 18) |
| W7 Notices, Play, docs | 2026-11-18 | 44292608356, 44297145654, 44300179086, 44329473907 (the docs) | **44332891340** ✓, the exit gate (`954601c`, an empty commit after 44329473907 passed; evidence `45e2799`, `86bd216`, `7632a07`) | **CI 44332891340** (Pixel 8a, 18 of 18; 3 of the day's 5) |

Since W6, CI and the phase gate are one workflow: a `[phase-gate]` push gives one run whose verdict covers both (the owner's request, 2026-11-18). The gates' evidence is committed back to `app/ci-results/gate/`, the Test Lab results to `app/ci-results/testlab/`, and the runtime job's to `runtime/ci-results/`.

## 3. What was built

- **The toolchain (W1):** Flutter 3.50.0 (Dart 3.14.0), AGP 9.3.3, Kotlin 2.4.20, Gradle 9.5.0, the app on `package:material_ui`, the actions on Node 24.
- **`native/` (W2, W3, W7):** t1's sealed-runtime kernel (`native/sealed-runtime/`, 8 classes and their tests), and `native/runtime-core/`: three t1 classes, the preload `libharness-exec.so`, the exec probe, and the payload's Gradle tasks. [native/PROVENANCE.md](../../native/PROVENANCE.md) records 23 vendored files with t1's SHA-256 and CodeForge's, and since W7 one patch (`native/patches/t1-0001-runtime-manifest-read.patch`).
- **`runtime/` (W2):** `pins.json`, with the bootstrap per ABI and 50 resolved packages per ABI, each by SHA-256. `pins.py` checks, fetches (failing closed), resolves (`[repin]`) and describes them. `provenance.py` checks the vendoring, and `notices.py` writes the userland's notices. t1's five scripts and two script tests come with them, byte for byte.
- **The runtime host (W3, W4, W7, Kotlin):**
  - `RuntimeHost` and `RuntimeHub` own the runtime behind a Pigeon API.
  - `SealedRuntime` installs through t1's `SealedInstaller.install` (since W7), audits, relinks after an app move, measures and reinstalls.
  - `RuntimeCommands`, `CommandRunner`, `SessionRegistry` and `RuntimeEnvironment` run commands under CodeForge's own exec model, with the launcher `libcodeforge-spawn.so` (W4). `Toolchain` runs the seven version probes.
- **Search (W6):** `SearchHost` with `RipgrepSearch` for projects, and CodeForge's own scan for folders (`TextScan`, `GlobFilter`, `LineMatcher`) with the editor's rules for text. In Dart: the search service, its controller and the Search panel.
- **The app (Dart):** the runtime's controller and state; Settings' *Linux runtime* page (state, payload, timing, tools, languages, storage, the program check, *Reinstall*, a copyable report); the status strip's runtime chip; a plain message on a WebView older than 87 (W6, ADR-0007).
- **CI (`ci.yml`):**
  - The runtime job: pins, provenance, the script tests, the fetch, and the notices.
  - *Runtime in the APKs* and page alignment; the API floor, which checks every call against minSdk 26 (W5); and *Release manifest* (W7).
  - With `[phase-gate]`: the runtime group, the runtime gates on five emulators (API 26, 27, 28, 34, 36) and the search group.
  - With `[testlab]`: the instrumented tests on a physical arm64 phone in Firebase Test Lab (W5).
- **Documents:** [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md) and [SOURCE_OFFER.md](../../SOURCE_OFFER.md) (W2 drafted, W7 completed), the Play drafts in [docs/store/](../store/README.md) (W7), and ADR-0013 (W6).

## 4. Gate by gate

| Gate | Result | Evidence |
|---|---|---|
| **G1 Toolchain** | **Met.** Flutter 3.50.0, AGP 9.3.3 (a deviation from 9.3.1, §9.1), KGP 2.4.20, Gradle 9.5.0. Analysis and format clean, all tests passing, no golden changed by the migration, every gate group passing. Cold start 879 ms with Impeller (W1) | CI 43373527631; gate 43384226759 |
| **G2 Kernel** | **Met.** t1's 22 kernel tests pass, changed only in their package line (23 since W7, with the patch's test). The script tests pass, PROVENANCE is complete and checked on every push, and a missing pinned package fails the build, naming it | CI 43401882656, 43403453442; every CI run since |
| **G3 Install** | **Met.** The first install runs off the UI thread with progress, and the editor works during it. Pixel 8a: 13.6 s in W5, 13.4 s in the exit gate (budget 60 s on a mid-range phone). Warm start: 73 and 64 ms on the Pixel 8a, 11 to 37 ms on the emulators (budget 100 ms). A flipped byte gives the typed failure `corrupt`, and the runtime is never marked ready. 0 programs from outside the APK at every start. Sizes in §7.1 | gates 43808489945, 44239443885, 44332891340; Test Lab CI 44240926191, 44332891340 |
| **G4 Versions** | **Met.** All seven tools reach Settings at their pins (`RUNTIME_UI tools ok=7 of=7`). Ending a command, a time limit or an exit leaves no process behind, on the emulators and the Pixel 8a | gate 43837693816; CI 44240926191 |
| **G5 Emulators** | **Met.** `ExecModelTest` and `SealedShellTest` pass on API 34 and 36 x86_64 | gate 44239443885 and every gate since |
| **G6 arm64** | **Met.** The same tests pass on a physical Google Pixel 8a (Android 14) in Test Lab. FULL against NORMAL was measured there: 0.58 against 0.49 ms per change. ADR-0008 updated, and the store syncs with `FULL` since W6 | CI 44240926191, 44275357542 |
| **G7 minSdk** | **Met.** The API 26, 27 and 28 legs pass; ADR-0007 is Accepted at 26. They found an API 33 call in t1's kernel, fixed in CodeForge's copy (§9.1), and the exit gate installs through the fix on all three | gate 44239443885 and every gate since; 44332891340 |
| **G8 Search** | **Met.** ripgrep in projects and the scan in folders find the gate's fixtures; results open at the line; a stop works. Figures in §7.2; the budget was accepted by the owner | gates 44264577788, 44275357542; Test Lab CI 44275357542 |
| **G9 Licence and docs** | **Met.** CodeForge's and t1's LICENSE files are both Apache-2.0 (ADR-0011 Accepted). ADR-0006 Accepted: xterm.js. The notices are complete and the source offer's mechanism decided. The docs are synced, and this report is written | CI 44297145654, 44300179086; PHASE_4_PLAN *As built (W7)* |

**The exit gate, 44332891340, passed every group on its first attempt** (`gate_result=pass`): the Phase 3 groups, the runtime group (`runtime_instrumented=pass OK (13 tests)`, `runtime_pair=pass`, `RUNTIME_UI tools ok=7 of=7`, `exec` printing 42), search, and the cold start. All five runtime legs passed, 16 of 16 tests each, and the Pixel 8a 18 of 18. **The kernel's fix holds on every target:** `RuntimeInstallTest` g read its manifest through the patched kernel (`kernel_manifest_stream=read 1`) on API 26, 27, 28, 34 and 36 and on the Pixel 8a, where W5 measured `NoSuchMethodError` on 26 to 28. The emulator logged one ANR since boot, in Google Play services (`com.google.android.gms.persistent`, a domain-verification broadcast), not in CodeForge.

## 5. Tests

| Suite | Count at Phase 4's end | Where |
|---|---|---|
| Flutter unit, widget, golden, accessibility | `+885: All tests passed!` | CI 44297145654 (`app/ci-results/`) |
| Kotlin (JVM) | 138, none skipped (W6 had 142; the 4 of `PayloadInstallTest` left with it in W7) | CI 44297145654 |
| The sealed kernel (JVM) | 23 (t1's 22, plus the recorded patch's test) | CI 44297145654 |
| `runtime/tests/` | 6 files, 77 cases (`script_test_files=6 cases=77 failed_files=0`): pins 21, notices 15, provenance 15, the launcher 16, and t1's two (bundle size 9, the sealed payload); a live fail-closed check | the runtime job, every push (`runtime/ci-results/script-tests.txt`) |
| CI tool self-tests | `check_manifest.py` 12, `check_runtime_apk.py` 8, `gate_results.py` 10, `testlab_diagnose` 11, the phone picker 12, among others | every push |
| Instrumented (`androidTest/`) | 18: `RuntimeInstallTest` 7 (a to g), `RuntimeCommandsTest` 6, `SealedShellTest` 2, `SyncModesTest` 2, `ExecModelTest` 1 | the exit gate 44332891340: 16 of 16 on each runtime leg (all but `SyncModesTest`), 18 of 18 on the Pixel 8a |
| Integration (`integration_test/`) | the Phase 3 groups, plus `runtime_a`/`runtime_b`, `search` and `phone_search` | every phase gate |

TESTING.md §1.4 describes each Phase 4 suite.

## 6. Build artifacts

- **Every CI run:** `codeforge-debug-apk` (every ABI, no runtime, about 84 MB), kept 90 days. The release x86_64 APK with its runtime is built and checked, but not uploaded.
- **Every phase gate:** `codeforge-phone-profile-arm64`, the phone build: profile mode, arm64, with the runtime (164,337,922 B). **For the owner's phone checks:** [the exit gate's artifact](https://github.com/Skill-center/CodeForge-/actions/runs/44332891340/artifacts/14444540025) (run 44332891340, commit `954601c`, kept until 2026-12-18). It is a zip holding one APK.
- **No release:** nothing is published until the source archive, the offer and the licence texts are in place (ADR-0010; §9.2).

## 7. Performance

### 7.1 The runtime

| Measure | Emulator (x86_64) | Pixel 8a (arm64, Test Lab) | Budget |
|---|---|---|---|
| First install | 6.4 s for 13,894 files in the exit gate (3.8 s in W6's last); 11.4 s through the app's UI. The legs: 6.5 to 13.6 s (W5: 6.0 to 9.1 s) | 13.4 s; 17.2 s through the app's startup path (W5: 13.6 and 17.6 s) | ≤ 60 s, mid-range phone |
| Warm start | 29 ms, median of 5, in the exit gate (18 ms in W6's); 11 to 31 ms on the legs | 64 ms, median of 5, samples 62 to 67 ms (W5: 73 ms) | ≤ 100 ms |
| Program check | 535 programs from the APK, 0 outside, 7,611 paths in 531 ms; 539 ms at a warm start | 534 from the APK, 0 outside, 1,683 ms | 0 outside |
| The seven tools' probes | 524 ms instrumented; 1,026 ms through the app's UI | 883 ms for the seven | — |

The figures without a run id are the exit gate's, 44332891340, its Test Lab run included.

**Sizes:**
- **The release APK (x86_64):** 149.5 MB (149,476,001 B). The userland's zip is 98.0 MB; 259 native libraries are 48.7 MB compressed, 121.6 MB once Android extracts them; 251 executables (CI 44300179086).
- **Per device on Play (arm64):** a 147.4 MB base module, 73.7 % of Play's 200 MB limit; the universal APK is 164.3 MB (the exit gate; the same in both W6 gates).
- **Installed:** 627 MB in all on the emulator, for a debug build: the APK 212 MB, the extracted libraries 140 MB, the runtime's files 275 MB. On the Pixel 8a, 637 MB with a debug build of 208 MB (CI 44332891340). The profile build the owner installs is 164 MB, so expect about 590 MB.
- **16 KB pages:** all 257 shipped userland objects and the 3 built here are aligned (CI 44300179086).

### 7.2 Search (W6)

| Measure | Gate (emulator) | Pixel 8a | Budget (accepted) |
|---|---|---|---|
| ripgrep, 10,000 files: first result / all, median of 3 | W6 58 / 146 ms; the exit gate 47 / 183 ms | 61 / 118 ms | ≤ 0.5 s / ≤ 2 s |
| Folder scan, 1,007 files, median of 3 | W6 4,610 ms; the exit gate 5,117 ms | — (Test Lab can't open a folder) | ≤ 6 s for 1,000 |
| A stop | W6 85 ms; the exit gate 51 ms, no ripgrep left | 67 ms | ≤ 250 ms |

**The folder scan's first run is slower:** 9.7 s, 10.4 s and 9.8 s in the three gates that ran it (44264577788, 44275357542, 44332891340), against about 5 s for the runs after it. Most likely the first pass meets Android's storage provider cold, though that cause is not measured. The median of three is what W6 reported. On the emulator that first run is over the 6 s budget, which is set for a phone. The owner's checklist times a folder on a phone (§8).

### 7.3 Cold start (release build, emulator, median of 10; budget 1,500 ms)

Phase 3's exit gate: 1,302 ms (Skia 992). Phase 4: W1 879 ms; W3 847 ms (Skia 815), the first with the runtime in the APK; W4 1,250 ms; W5 1,267 ms; W6 1,153 ms (Skia 997). The W4 and W5 runs were slower throughout on the emulator's host (PHASE_4_PLAN *As built (W4)*). The runtime doesn't start until a workspace opens, so it adds nothing to the cold start. **The exit gate: 1,121 ms** (Skia 1,090; the shipped APK once more, 1,145).

## 8. The phone checks

- **[PHASE_4_PHONE_CHECKLIST.md](PHASE_4_PHONE_CHECKLIST.md)** (W7): the runtime on the owner's phone. The first install, the warm start, the program check, the space used, the tools, search in a project and in a folder, and the runtime's copied report, in about 20 minutes.
- **[PHASE_3_PHONE_CHECKLIST.md](PHASE_3_PHONE_CHECKLIST.md)** (pending since 2026-11-12): now points at the same build. Its FULL against NORMAL item was done in Test Lab, so it is skipped.
- Both are non-blocking for acceptance unless the owner decides otherwise. Results go here and into PHASE_3_REPORT §8.

| Run | Date | Phone | Build | Result |
|---|---|---|---|---|
| — | — | — | — | not run yet |

## 9. Deviations and known limitations

### 9.1 Deviations from the plan (documented as built)

- **AGP 9.3.3, not 9.3.1** (W1): 9.3.0 and 9.3.1 bundle a lint that crashes on JDK 17 in every release build.
- **Less of t1 vendored** (W3, W4): three of the twelve harness-core classes the plan listed. The others carry t1's apt shape, and vendored files are not edited, so the host is CodeForge's own code. That includes its own exec model with a launcher (W4), in place of t1's `HarnessCommandRunner`.
- **t1's kernel had an API 33 call** (W5): `InputStream.readAllBytes()`, which made every install through its entry point fail below Android 13. W5 worked around it in the host (`PayloadInstall`). After the owner allowed changes to t1's code, W7 fixed it in CodeForge's copy as a recorded patch, and the host went back to the kernel's entry point. CI's API-floor check keeps the whole app at minSdk 26.
- **CI and the phase gate are one workflow** (the owner, 2026-11-18).
- **The notices' Dart list is a superset** (W7): CI writes the app's whole dependency closure, which includes two test libraries. `flutter_riverpod` 3.4.3 and `riverpod` 3.4.3 declare them as regular dependencies.
- **The closed test** is proposed for Phase 5's first work package, not started in Phase 4: it needs a build with the source archive, and the owner's account.

### 9.2 Known limitations, carried forward

- **No binary release.** Before the first distribution, the closed test included: the source archive built by a release workflow, the written offer in the app's About, the userland's licence texts in the app's licence page, and a licence review by a qualified person (SOURCE_OFFER.md).
- **No terminal and no *Run*** (Phase 5, xterm.js). Before them, the exec model gains a session cap, resource limits, the OOM score, a foreground service and output coalescing (SECURITY §2.1).
- **Folders don't reach the runtime yet:** ADR-0013's copy, with *Import as project*, comes in Phase 5. Searching a folder is bound by Android's storage provider, about 4.6 s per 1,000 files on the emulator.
- **No build-tools pack** (no C or C++ compiling), so npm and pip packages with native addons can't build. **No 32-bit ARM build.**
- **Firebase Test Lab shuts down on 2027-09-30.** What runs the arm64 tests after it is in ROADMAP's decision queue.
- **Physical-phone figures** come from one Pixel 8a. The owner's phone adds a second (§8).
- **A folder's first search** took about 10 s for 1,007 files on the emulator, against about 5 s after it (§7.2).

### 9.3 Gate history

- **W1, gate 43375227077:** every group passed, but the AOT builds failed: a Dart 3.14.0 compiler crash ([dart-lang/sdk#64917](https://github.com/dart-lang/sdk/issues/64917); the code was reshaped), and AGP 9.3.1's lint. **Gate 43379964330:** the watch group's last snack bar was still animating when its test ended; the test now waits.
- **W5, gate 44235180242:** all five legs were lost before a test ran: the app and its test APK came from two Gradle runs, signed with different debug keys. One Gradle run now builds both, and `same_signer.sh` checks their certificates before an emulator or a phone is spent. **Gate 44236831476:** that check's first version read nothing with build-tools 37's apksigner on Java 17. **Gate 44237799081:** all five legs passed, but four legs' committed evidence was the first run's. Each leg now uploads its own folder alone, and the evidence job takes each from its own artifact (PHASE_4_PLAN *As built (W5)*).
- **W6, CI 44262330746 and 44270655389:** analysis infos and formatting in new code, each fixed in the next commit.

## 10. Next-phase readiness (Phase 5 — Terminal & execution), and the owner's decisions

**Ready for Phase 5:**
- the exec model, the launcher and the session registry, with each command's whole process tree ended;
- the runtime's environment, proven on API 26 to 36 and arm64;
- ADR-0006's terminal frontend, xterm.js;
- ADR-0013's way for a folder to reach the runtime.

**Proposed for Phase 5's first work package:** the release workflow with the signed App Bundle and the source archive, the offer in About, and the licence texts in the app. Then the closed test can start (for example on 2026-12-07, with 14 days ending 2026-12-21).

**For the owner:**
1. **Accept Phase 4,** or ask for changes.
2. **The phone session:** PHASE_3_PHONE_CHECKLIST (about 75 minutes) and PHASE_4_PHONE_CHECKLIST (about 20), on the same APK (§6).
3. **Play** ([docs/store/README.md](../store/README.md)): the developer account; Play App Signing, with the upload key in CI's secrets; the privacy policy's three placeholders (the name, the date, the contact address); 15 to 20 testers.
4. **Later:** the licence review by a qualified person before the first distribution; and before 2027-09-30, what runs the arm64 tests after Test Lab.
