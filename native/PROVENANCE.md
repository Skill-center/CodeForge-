# Provenance of the vendored runtime

CodeForge vendors t1's sealed runtime: its kernel (`native/sealed-runtime/`), its payload scripts (`runtime/`), and its Android adapter and preload (`native/runtime-core/`). This file is the record AGENTS.md requires: where every vendored file came from, the one change made to it, its licence, and how to re-vendor. CI runs `python3 runtime/provenance.py check` on every push, and the check fails if a file differs from this record.

## Source

- **Repository:** https://github.com/m-cyber12/t1
- **Commit:** `d9789a26e441f5e1a1f2489eb88d7138d76c59ac` (`main`, 2026-11-13, "Add Apache License 2.0 to the project"). Its tree is the audited commit `0e26d7a` (docs/EXISTING_RUNTIME_AUDIT.md, merged to `main` by PR #229 as `7b496c3`) plus the LICENSE file.
- **Licence:** Apache-2.0. t1's `LICENSE` (SHA-256 `c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4`) is the Apache License 2.0 text; it differs from CodeForge's `LICENSE` only by a trailing blank line. t1 has no NOTICE file, and the vendored files carry no licence headers or attribution notices that would have to be kept.
- **Copyright:** t1's owner (m-cyber12), who also owns CodeForge.
- **Vendored:** 2026-11-13, Phase 4 W2 (the kernel and the scripts); 2026-11-16, Phase 4 W3 (the runtime core).

## What was vendored, and what was not

**Vendored (23 files):**
- the sealed-runtime kernel, 8 classes and 3 JUnit test classes (t1's `sealed-runtime/`), into `native/sealed-runtime/`, with the package renamed (W2);
- the payload scripts and their tests (t1's `scripts/`), into `runtime/`, byte for byte (W2);
- the runtime core's Android adapter, `HarnessConfig`, `HarnessPaths` and `exec/SealedPayloadInstaller` (t1's `harness-core/`), into `native/runtime-core/`, with the packages renamed (W3);
- the preload's two C files, `harness-exec.c` (the `LD_PRELOAD` path translator) and `harness-probe.c` (the exec probe), into `native/runtime-core/src/main/jni/`, byte for byte (W3). They sit in t1's `terminal-emulator/src/main/jni/`, but they are t1's own: its owner wrote them in t1 (commits `4f5b846` and `e80508b`), after the Termux copy of `4c3ed31` that brought `termux.c`.

**Not vendored, by decision:**
- **Termux-derived code** (`terminal-emulator`, `terminal-view`, `termux.c` and t1's `HarnessSession`). It is never vendored: CodeForge is Apache-2.0 (ADR-0011) and its terminal is xterm.js (ADR-0006). Phase 5 writes the PTY clean-room, or reuses `termux.c` only after a legal review confirms its Apache-2.0 jackpal lineage.
- **The apt machinery** (`HarnessBootstrap`, `provision/*`, `AptPackInstaller`, `PackageCommands`). The apt shape does not ship (RUNTIME_INTEGRATION §5).
- **Play Feature Delivery** (`feature-delivery`, `pack_buildtools`). It falls under the Play Core SDK's terms, and nothing needs it before the build-tools pack (PHASE_4_PLAN §2).
- **`scripts/export-sealed-runtime.sh`.** It made the copy (below); the tree does not need it.
- **What would have to be edited to compile** (W3). A vendored file is never edited here (below), so a t1 file that needs a change to work without what is left behind is not vendored; CodeForge writes its own code instead, or t1 changes first:
  - `HarnessSizeReport` attributes sizes to the apt install tiers (`provision.PackageTier`). The runtime host counts the installed size itself (`SealedRuntime.kt`, unique inodes, as t1's report does).
  - `packs/*` (`Pack`, `PackState`, `PackResult`, `PackInstaller`, `Packs`): `Pack` names an apt tier, the others need `Pack`, and `Packs` chooses between the apt installer and Play's. Nothing installs a pack before the build-tools pack, which brings the port with `PlayPackInstaller`, without an apt branch to delete.
  - t1's `Android.mk` builds `libtermux` from `termux.c`. CodeForge's own `Android.mk` builds `harness-exec.c` alone, with t1's flags.
  - **`HarnessEnvironment`, `HarnessCommandRunner` and `Toolchain` (W4).** CodeForge writes its own exec model instead: `RuntimeEnvironment`, `SessionRegistry`, `CommandRunner` and `Toolchain` in `app/android/app/src/main/kotlin/dev/codeforge/app/runtime/`, and the launcher `native/runtime-core/src/main/jni/codeforge-spawn.c` (docs/SECURITY.md §2):
    - `HarnessEnvironment.prepare` calls `HarnessBootstrap` and writes apt's configuration. Its `create` starts from every variable of the app's process, and it preloads Termux's `termux-exec` beside `harness-exec`; `termux-exec` can run an ELF file from the app's storage through the system linker, which the sealed model rules out. `RuntimeEnvironment` keeps t1's layout and the variables `harness-exec.c` reads, and builds everything else from nothing.
    - `HarnessCommandRunner` merges stderr into stdout through one shared log file, prepares apt at every call and ends only its direct child. CodeForge's runner reads the two streams apart, each capped, and starts every command through the launcher, which leads a process group of its own and ends it whole. The launcher's own `execv` goes through the preload, so `harness-exec` translates a script's official `#!` line, where t1's runner did that in Java.
    - `Toolchain.inspect` looks only whether each program is there. CodeForge's probes run each tool once and compare its version with its package's pin.

    None of this changes a t1 file, so nothing waits on t1 (AGENTS §4).
- **The adapter's install path.** `SealedPayloadInstaller.install` takes no progress listener. The runtime host calls t1's kernel itself, as `SealedPayloadInstaller`'s own comment says a host should, and uses the adapter's asset names and ABI choice.
- **The kernel's entry point, `SealedInstaller.install` (W5).** It reads the manifest stream through `RuntimeManifest.read(InputStream)`, which calls `InputStream.readAllBytes()`. Android has that method only from API 33, and D8 does not backport it, so on Android 8.0 to 12L (API 26 to 32) every install through it ended in `NoSuchMethodError`. t1 never saw it: its minSdk is 29, and it ran only on API 34 and 36. A vendored file is never edited, so the runtime host makes the entry point's calls itself (`PayloadInstall.kt`, beside `SealedRuntime.kt`): `RuntimeManifest.parse` on the bytes it has read, then `PayloadExtractor`, the data links (each side checked by `RuntimeManifest.normalize`, created as the kernel creates them) and `SealedLayout`, in the kernel's order. `PayloadInstallTest` (JVM) installs the same payloads through both and compares the prefixes, counts and problems. CI's API floor check (`app/tool/ci/check_api_floor.py`) fails the build if the app calls `SealedInstaller.install`, `RuntimeManifest.read(InputStream)` or the adapter's `install` again. The fix belongs in t1 (`RuntimeManifest.read` can read the stream in a loop); a re-vendor after it can retire `PayloadInstall`.
  - **Decided on 2026-11-18** (one of W5's open decisions, which the owner left to the agent): `PayloadInstall` stays CodeForge's install path, and nothing waits for t1. The fix is ready for t1's owner as an upstreamable patch with a test, `native/upstream/t1-0001-runtime-manifest-read.patch` (*Upstream patches* below). Whether and when t1 takes it is t1's choice. After a re-vendor that includes it, CI warns that the patch is already in, and `PayloadInstall` can retire.

**Ported, not vendored (W5): t1's on-device gates.** t1's `app/src/androidTest/java/io/mcyber12/codingharness/ExecModelTest.java` and `SealedShellTest.java` (at the commit above) need classes that were not vendored (`androidx.test.ext:junit`, `HarnessCommandRunner`, `HarnessBootstrap`, `packs/*`), so CodeForge ports them. They are CodeForge's own files, in `app/android/app/src/androidTest/` (`java/dev/codeforge/app/runtime/ExecModelTest.java`, `kotlin/dev/codeforge/app/runtime/SealedShellTest.kt`), and each class comment lists what changed and why:
- **`ExecModelTest`** keeps t1's text: its steps, order, assertions and messages. It changes the package, the runner (a plain JUnit4 class), the prefix (a root of the gate's own, cleared first) and the report. One change is about Android, not CodeForge: a denial of exec from app data is expected only where Android denies it, on API 29 and later for an app that targets 29 or later. On API 26 to 28, which t1 never ran, nothing denies it.
- **`SealedShellTest`** keeps t1's assertions and messages on CodeForge's host: the runtime host's install instead of `SealedPayloadInstaller.install`, CodeForge's runner instead of `HarnessCommandRunner`, and the app's startup path (`RuntimeHubs`, which `RuntimeHost` calls) instead of `HarnessBootstrap.ensureSealedPayload`. t1's third test, `packsComeFromTheStoreAndNeverFromApt`, waits for a pack: CodeForge has none before the build-tools pack.
- The probe they run, `harness-probe.c`, is vendored byte for byte (above).

## The one change: the package

Every vendored Java file differs from t1 in its package and nowhere else. The kernel's files have the change `package`; the runtime core's, the change `rename`.

**The kernel (`package`).** The Java package `io.mcyber12.sealed` became `dev.codeforge.runtime.sealed`. t1's own script made the change:

```bash
scripts/export-sealed-runtime.sh <CodeForge>/native/sealed-runtime/src/main/java --package dev.codeforge.runtime.sealed
```

- **What the script changes:** it rewrites the `package` line (`sed "s/^package io\.mcyber12\.sealed;/package dev.codeforge.runtime.sealed;/"`) and nothing else, in the classes and in the tests. Nothing else in the files names the package.
- **The tests:** t1's tests are changed only in that line (gate G2). `provenance.py check` proves it for every file: undoing the rename gives t1's SHA-256 exactly.
**The runtime core (`rename`).** t1's two packages are renamed on the `package` and `import` lines, and nowhere else: `io.mcyber12.codingharness.core` becomes `dev.codeforge.runtime.core`, and `io.mcyber12.sealed` becomes `dev.codeforge.runtime.sealed`. t1 has no export script for `harness-core`, so `provenance.py copy` makes the copy. It refuses a file that names a t1 package anywhere else (a comment, a fully qualified name), since the rename would not reach it, and `check` requires that no `io.mcyber12` is left.

- **The licence notice:** this statement of the change is the notice Apache-2.0 §4(b) asks for. Whether the renamed files should also carry a notice inside them is on W7's licence review list.
- **The runtime core's tests:** t1's `harness-core` tests (`HarnessEnvironmentTest`, `PackCommandsTest`) test the apt shape and `HarnessEnvironment`, which were not vendored, so none of them applies to the three classes. The runtime host's JVM tests and its instrumented tests cover them (`app/android/app/src/test/` and `src/androidTest/`, `runtime` packages), and W5 brings t1's on-device gates.

**The module's build script.** `native/sealed-runtime/build.gradle.kts` is t1's `sealed-runtime/build.gradle` translated to the Kotlin DSL, with the same settings (Java 17, JUnit 4.13.2), and it states `useJUnit()`.

## Vendored files

<!-- vendored:begin -->
| CodeForge file | t1 file | Change | t1 SHA-256 | CodeForge SHA-256 |
|---|---|---|---|---|
| `native/runtime-core/src/main/java/dev/codeforge/runtime/core/HarnessConfig.java` | `harness-core/src/main/java/io/mcyber12/codingharness/core/HarnessConfig.java` | rename | `9811730f51f0269025a54dc20d002c7165af35e763a147154f921b0d92cbd8f6` | `c4377a47a0888b3711b10fe739bd27bb872c2ff29e819be4762231ab9323e10b` |
| `native/runtime-core/src/main/java/dev/codeforge/runtime/core/HarnessPaths.java` | `harness-core/src/main/java/io/mcyber12/codingharness/core/HarnessPaths.java` | rename | `0e5a7f37aec11dfb59e142e10d3e80826bd2dee0265c5863bd242b7f30bf232f` | `25247998fcfa2fa86b76672085dfb8bb62c964a22a2954e5d8ecd5dd4444feaf` |
| `native/runtime-core/src/main/java/dev/codeforge/runtime/core/exec/SealedPayloadInstaller.java` | `harness-core/src/main/java/io/mcyber12/codingharness/core/exec/SealedPayloadInstaller.java` | rename | `76c9569740dc1e53be078c731301d0948a8286f56eb20e5cb864d88921297802` | `5ee0a984061f98225c5d24f600d70bf9bbd7f42b79be18511c907a45bb53280e` |
| `native/runtime-core/src/main/jni/harness-exec.c` | `terminal-emulator/src/main/jni/harness-exec.c` | none | `bcee745627dd11514e36420b75b738d034df97059a4e6b47b12e2bce02ea5ee8` | `bcee745627dd11514e36420b75b738d034df97059a4e6b47b12e2bce02ea5ee8` |
| `native/runtime-core/src/main/jni/harness-probe.c` | `terminal-emulator/src/main/jni/harness-probe.c` | none | `8b880c1c145a64fa582c74f4d74f3b9af5ea587ad32fbe7371fc3dd85ab5bcd4` | `8b880c1c145a64fa582c74f4d74f3b9af5ea587ad32fbe7371fc3dd85ab5bcd4` |
| `native/sealed-runtime/src/main/java/dev/codeforge/runtime/sealed/ExecAudit.java` | `sealed-runtime/src/main/java/io/mcyber12/sealed/ExecAudit.java` | package | `89e71ccc768c4653b40868d741796b76bd0481a5be4ff46b5a91ee886d03483a` | `eba69c580ce62e0743bf388886b9b4dbac11675d257b507bd4b0a068f0a5cac4` |
| `native/sealed-runtime/src/main/java/dev/codeforge/runtime/sealed/ExecutableKind.java` | `sealed-runtime/src/main/java/io/mcyber12/sealed/ExecutableKind.java` | package | `8f36d332d3e454b990478b0e4b51ebf53d9022304b6a81a39974af8dc7093a3f` | `4a3e45d99d1e87c169e0a47dd2a92290c3a50eeb6c6a652f5f7dfa0f8a5b2e9e` |
| `native/sealed-runtime/src/main/java/dev/codeforge/runtime/sealed/ExecutableProbe.java` | `sealed-runtime/src/main/java/io/mcyber12/sealed/ExecutableProbe.java` | package | `a070e1779401dcc0533596bd729b2922afef6fd52dee019d49563a53a9290018` | `b1923519bbb9ca4220d7faa84be34b1cc848c0e22fc88a1454017eea74d49abb` |
| `native/sealed-runtime/src/main/java/dev/codeforge/runtime/sealed/PayloadExtractor.java` | `sealed-runtime/src/main/java/io/mcyber12/sealed/PayloadExtractor.java` | package | `5d80f5491bb18df692774616accd2276af9071062553efc3ed462b774a2f32d1` | `4b1c248819188c52b6a3d29df27ca8f723035f5ef88fb7fa5cca88245a8f1744` |
| `native/sealed-runtime/src/main/java/dev/codeforge/runtime/sealed/RuntimeManifest.java` | `sealed-runtime/src/main/java/io/mcyber12/sealed/RuntimeManifest.java` | package | `40dc296624c6c830a33222b9ec7d57660f04a50611e3642b8b64a82864790c46` | `e6127e359e90b590c3a325ac65a757e3e53fcf58ebd31052ab7cc5d62c450328` |
| `native/sealed-runtime/src/main/java/dev/codeforge/runtime/sealed/SealedInstaller.java` | `sealed-runtime/src/main/java/io/mcyber12/sealed/SealedInstaller.java` | package | `b62e793e3602f877427c94dc0e293fb83918ee05884548fb77601dad59c67aef` | `2d75eb14d24841bec95df74e3cb9a8152be9855174cddd6860b3e8c60b35a857` |
| `native/sealed-runtime/src/main/java/dev/codeforge/runtime/sealed/SealedLayout.java` | `sealed-runtime/src/main/java/io/mcyber12/sealed/SealedLayout.java` | package | `ba29228e0ccadb4ee751b54e8ac8e3c03186a7b7e2b627401b9f017fff115f94` | `c3c2630e2e9613366aee4d14888f67524449236b3fca8d47f3088b730b53474b` |
| `native/sealed-runtime/src/main/java/dev/codeforge/runtime/sealed/SealedUninstaller.java` | `sealed-runtime/src/main/java/io/mcyber12/sealed/SealedUninstaller.java` | package | `995952ad4fb955a3799ac5393460c5f1ab22fb3142409b780d031bc89c957806` | `865ca7b4e0a12fc8bfe3892bf6f5903813f7201562c1f8674c5fb0017fc6f811` |
| `native/sealed-runtime/src/test/java/dev/codeforge/runtime/sealed/ExecSealingTest.java` | `sealed-runtime/src/test/java/io/mcyber12/sealed/ExecSealingTest.java` | package | `18cd347d9d333864adf1c782a9d4c61fbf166cba01d3109bad59350cf3a76cb1` | `478518487e8e8cd982e0159f81931fb3e95eebe46a87eb0c68752c4c32762298` |
| `native/sealed-runtime/src/test/java/dev/codeforge/runtime/sealed/PackPayloadTest.java` | `sealed-runtime/src/test/java/io/mcyber12/sealed/PackPayloadTest.java` | package | `97f302c98bc7d98f96973d7e7d110e6fa89cdccf82801fbf8bc45e2428627bcf` | `b73a0c35c2e55be7cc6f50b6319de52461277e07e7de41425c2094643e19cc7a` |
| `native/sealed-runtime/src/test/java/dev/codeforge/runtime/sealed/SealedInstallerTest.java` | `sealed-runtime/src/test/java/io/mcyber12/sealed/SealedInstallerTest.java` | package | `5d15fb67bdf0c6aff9570d35421dcd95e2ac231b1a3a0d30a102fcb5137dca74` | `addaa8c8aacb6508ba496c7603f6f81267bdc15c7425c66dcada242d36bec410` |
| `runtime/build-sealed-payload.py` | `scripts/build-sealed-payload.py` | none | `6f8296fd9b0c722094ce5115aac043bfffdb6a48058480b9f08e90ce650d30c7` | `6f8296fd9b0c722094ce5115aac043bfffdb6a48058480b9f08e90ce650d30c7` |
| `runtime/fetch-core-debs.py` | `scripts/fetch-core-debs.py` | none | `26daaf7ec1ab897872afc5c6e5be403b188960d4d35a5b02b924038ad3bcdf66` | `26daaf7ec1ab897872afc5c6e5be403b188960d4d35a5b02b924038ad3bcdf66` |
| `runtime/check-bundle-size.py` | `scripts/check-bundle-size.py` | none | `f42ec5a5ec77ad3c797786e767ecf3e30ca812f7dd21b8d1a8735e476909c695` | `f42ec5a5ec77ad3c797786e767ecf3e30ca812f7dd21b8d1a8735e476909c695` |
| `runtime/check-page-alignment.py` | `scripts/check-page-alignment.py` | none | `ab6ce906bcc3d7013b2695a2534a3b528590c91fe6a1d87321ee0b8cc94ecc65` | `ab6ce906bcc3d7013b2695a2534a3b528590c91fe6a1d87321ee0b8cc94ecc65` |
| `runtime/check-sealed-manifest.sh` | `scripts/check-sealed-manifest.sh` | none | `d8c90b7a87e638ac0894ad0f224c426d041feef3c0faa5a0791c340a60dcb6fd` | `d8c90b7a87e638ac0894ad0f224c426d041feef3c0faa5a0791c340a60dcb6fd` |
| `runtime/tests/test-sealed-payload.py` | `scripts/tests/test-sealed-payload.py` | none | `0c0e84ac83f4cadd1433de2e510c6fd69d73f980886defeb9a6cc4c4cf518955` | `0c0e84ac83f4cadd1433de2e510c6fd69d73f980886defeb9a6cc4c4cf518955` |
| `runtime/tests/test-check-bundle-size.py` | `scripts/tests/test-check-bundle-size.py` | none | `b98498abe7f01c69dc3036a052d3da6912a3b4ad2d1d42354fcd13d7b260e321` | `b98498abe7f01c69dc3036a052d3da6912a3b4ad2d1d42354fcd13d7b260e321` |
<!-- vendored:end -->

## CodeForge's own files under native/ and runtime/

<!-- own:begin -->
| CodeForge file | What it is |
|---|---|
| `native/PROVENANCE.md` | this record |
| `native/runtime-core/build.gradle.kts` | the runtime core's build script (W3): the ABIs, ndk-build for the preload, the compile task for the exec probe and (W4) the launcher, and the payload task that builds one ABI's sealed payload from the pins |
| `native/runtime-core/src/main/AndroidManifest.xml` | the runtime core's manifest, empty: the app decides how native libraries are packaged |
| `native/runtime-core/src/main/jni/Android.mk` | ndk-build for `harness-exec.c` with t1's 16 KB flags; t1's own also builds `termux.c`, this one never does (ADR-0011) |
| `native/upstream/t1-0001-runtime-manifest-read.patch` | an upstreamable fix for t1, waiting for t1's owner (*Upstream patches*) |
| `native/runtime-core/src/main/jni/codeforge-spawn.c` | the launcher every runtime command starts through (W4), built as `libcodeforge-spawn.so`: a session and process group of its own, a child subreaper, default signals, no core files; it ends the whole group and every descendant when the command exits or when it is stopped, and writes what happened to a status file (docs/SECURITY.md §2) |
| `native/sealed-runtime/build.gradle.kts` | the module's build script: t1's, in the Kotlin DSL |
| `runtime/README.md` | how the supply chain fits together, and its commands |
| `runtime/pins.json` | the pins: the bootstrap, the core set, and every resolved package with its SHA-256 |
| `runtime/pins.py` | `check`, `fetch` (fails closed), `bootstrap`, `resolve` (re-pin), `info` (what a payload holds, for the app) |
| `runtime/notices.py` | drafts THIRD_PARTY_NOTICES.md and SOURCE_OFFER.md from the pinned packages' licence files |
| `runtime/provenance.py` | checks this record; `copy` writes the vendored files from t1 with their change; `record` rewrites the hashes |
| `runtime/tests/fixtures.py` | synthetic Termux repositories for CodeForge's tests |
| `runtime/tests/test-pins.py` | pins.py's tests, the fail-closed cases among them |
| `runtime/tests/test-notices.py` | notices.py's tests |
| `runtime/tests/test-provenance.py` | provenance.py's tests |
| `runtime/tests/test-spawn.py` | the launcher's tests (W4), on the host's C compiler: output and exit status, its own session and group, clean signals, a child left behind, a tree stopped whole, processes that left the group, exec failures, and nothing left behind |
| `runtime/tests/live-fail-closed.py` | CI's check that a missing pinned package fails closed against the real repository |
<!-- own:end -->

## Re-vendoring

1. **Choose the commit.** Pick the t1 commit and check that its LICENSE is still Apache-2.0. Read what changed in the vendored paths: `git diff <old>..<new> -- sealed-runtime scripts`.
2. **Copy the files.** Run `python3 runtime/provenance.py copy --t1 <t1 checkout>`: it writes every listed file from t1 with its recorded change and t1's file mode, and refuses a checkout at another commit. (The kernel's copy is the same bytes t1's `scripts/export-sealed-runtime.sh <CodeForge>/native/sealed-runtime/src/main/java --package dev.codeforge.runtime.sealed` writes.)
3. **Update the record.** Change the Commit line above. Add a row with `-` hashes for each new file, and remove the rows of files t1 dropped.
4. **Record the hashes.** Run `python3 runtime/provenance.py record --t1 <t1 checkout>`. It refuses a checkout at another commit, and any file that is not t1's with the recorded change.
5. **Test.** Run `python3 runtime/provenance.py check`, the script tests, `./gradlew :native:sealed-runtime:test` and `./gradlew :app:testDebugUnitTest` (from `app/android`), and the emulator gate's runtime group. CI runs them all.
6. **Commit** it as one change ("vendor t1 <sha>"), and say what t1 changed.

**Vendored files are never edited here.** A fix goes to t1 first, as an upstreamable patch, and is then re-vendored. A need that is CodeForge's own goes into a separate CodeForge file (REPOSITORY_STRUCTURE's boundary rule 3).

## Upstream patches

Fixes for t1 that CodeForge has written wait in `native/upstream/`, one `git format-patch` file each, against the commit above and t1's own paths and package. t1's owner applies one with `git am <file>` in a t1 checkout.

- **CI tests each patch on every push** (`app/tool/ci/check_upstream_patches.sh`, the quality job's *Upstream patches for t1*). It maps the patch onto the vendored kernel (t1's paths and package to CodeForge's), applies it, and runs the kernel's JUnit tests with it. Then it restores the vendored files and checks them unchanged, so nothing CodeForge builds or ships includes the patch. Its results go to `app/ci-results/upstream-patches.txt`.
- **A patch that no longer applies** fails the run: a re-vendor changed the code it fixes, so it needs writing again.
- **A patch that is already in** the vendored copy only warns. t1 took it and CodeForge re-vendored, so the patch can go, with whatever worked around it.

| Patch | Fixes | Works around it meanwhile |
|---|---|---|
| `t1-0001-runtime-manifest-read.patch` | `RuntimeManifest.read(InputStream)` called `InputStream.readAllBytes()`, which Android has only from API 33 (W5). It now reads the stream in a loop. The new test reads a stream that returns three bytes per call | `PayloadInstall.kt` |

## The pins

`runtime/pins.json` pins every input of the payload: the bootstrap for each ABI, by t1's SHA-256, and the resolved core set, each package by version, file and SHA-256. `runtime/README.md` and docs/BUILD_AND_RELEASE.md §3 describe how CI fetches the pins, caches them and fails closed, and how a deliberate `[repin]` commit re-pins.
