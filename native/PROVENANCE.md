# Provenance of the vendored runtime

CodeForge vendors t1's sealed runtime: its kernel (`native/sealed-runtime/`) and its payload scripts (`runtime/`). This file is the record AGENTS.md requires: where every vendored file came from, the one change made to it, its licence, and how to re-vendor. CI runs `python3 runtime/provenance.py check` on every push, and the check fails if a file differs from this record.

## Source

- **Repository:** https://github.com/m-cyber12/t1
- **Commit:** `d9789a26e441f5e1a1f2489eb88d7138d76c59ac` (`main`, 2026-11-13, "Add Apache License 2.0 to the project"). Its tree is the audited commit `0e26d7a` (docs/EXISTING_RUNTIME_AUDIT.md, merged to `main` by PR #229 as `7b496c3`) plus the LICENSE file.
- **Licence:** Apache-2.0. t1's `LICENSE` (SHA-256 `c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4`) is the Apache License 2.0 text; it differs from CodeForge's `LICENSE` only by a trailing blank line. t1 has no NOTICE file, and the vendored files carry no licence headers or attribution notices that would have to be kept.
- **Copyright:** t1's owner (m-cyber12), who also owns CodeForge.
- **Vendored:** 2026-11-13, Phase 4 W2.

## What was vendored, and what was not

**Vendored (18 files):**
- the sealed-runtime kernel, 8 classes and 3 JUnit test classes (t1's `sealed-runtime/`), into `native/sealed-runtime/`, with the package renamed;
- the payload scripts and their tests (t1's `scripts/`), into `runtime/`, byte for byte.

**Not vendored, by decision:**
- **Termux-derived code** (`terminal-emulator`, `terminal-view`, `termux.c` and t1's `HarnessSession`). It is never vendored: CodeForge is Apache-2.0 (ADR-0011) and its terminal is xterm.js (ADR-0006). Phase 5 writes the PTY clean-room, or reuses `termux.c` only after a legal review confirms its Apache-2.0 jackpal lineage.
- **The apt machinery** (`HarnessBootstrap`, `provision/*`, `AptPackInstaller`, `PackageCommands`). The apt shape does not ship (RUNTIME_INTEGRATION §5).
- **Play Feature Delivery** (`feature-delivery`, `pack_buildtools`). It falls under the Play Core SDK's terms, and nothing needs it before the build-tools pack (PHASE_4_PLAN §2).
- **`scripts/export-sealed-runtime.sh`.** It made the copy (below); the tree does not need it.

**Still to come:**
- W3 adds the Android adapter (t1's `SealedPayloadInstaller`), the preload (`harness-exec.c`, `harness-probe.c` and `Android.mk`) and the runtime-core subset (`HarnessCommandRunner`, `HarnessEnvironment`, `Toolchain` and the rest).
- W5 adds t1's `ExecModelTest` and `SealedShellTest`.
- Each joins this record when it is vendored.

## The one change: the package

The Java package `io.mcyber12.sealed` became `dev.codeforge.runtime.sealed`. t1's own script made the change:

```bash
scripts/export-sealed-runtime.sh <CodeForge>/native/sealed-runtime/src/main/java --package dev.codeforge.runtime.sealed
```

- **What the script changes:** it rewrites the `package` line (`sed "s/^package io\.mcyber12\.sealed;/package dev.codeforge.runtime.sealed;/"`) and nothing else, in the classes and in the tests. Nothing else in the files names the package.
- **The tests:** t1's tests are changed only in that line (gate G2). `provenance.py check` proves it for every file: undoing the rename gives t1's SHA-256 exactly.
- **The licence notice:** this statement of the change is the notice Apache-2.0 §4(b) asks for. Whether the renamed files should also carry a notice inside them is on W7's licence review list.

**The module's build script.** `native/sealed-runtime/build.gradle.kts` is t1's `sealed-runtime/build.gradle` translated to the Kotlin DSL, with the same settings (Java 17, JUnit 4.13.2), and it states `useJUnit()`.

## Vendored files

<!-- vendored:begin -->
| CodeForge file | t1 file | Change | t1 SHA-256 | CodeForge SHA-256 |
|---|---|---|---|---|
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
| `native/sealed-runtime/build.gradle.kts` | the module's build script: t1's, in the Kotlin DSL |
| `runtime/README.md` | how the supply chain fits together, and its commands |
| `runtime/pins.json` | the pins: the bootstrap, the core set, and every resolved package with its SHA-256 |
| `runtime/pins.py` | `check`, `fetch` (fails closed), `bootstrap`, `resolve` (re-pin) |
| `runtime/notices.py` | drafts THIRD_PARTY_NOTICES.md and SOURCE_OFFER.md from the pinned packages' licence files |
| `runtime/provenance.py` | checks this record; `record` rewrites its hashes |
| `runtime/tests/fixtures.py` | synthetic Termux repositories for CodeForge's tests |
| `runtime/tests/test-pins.py` | pins.py's tests, the fail-closed cases among them |
| `runtime/tests/test-notices.py` | notices.py's tests |
| `runtime/tests/test-provenance.py` | provenance.py's tests |
| `runtime/tests/live-fail-closed.py` | CI's check that a missing pinned package fails closed against the real repository |
<!-- own:end -->

## Re-vendoring

1. **Choose the commit.** Pick the t1 commit and check that its LICENSE is still Apache-2.0. Read what changed in the vendored paths: `git diff <old>..<new> -- sealed-runtime scripts`.
2. **Copy the files.** In a t1 checkout at that commit, run `scripts/export-sealed-runtime.sh <CodeForge>/native/sealed-runtime/src/main/java --package dev.codeforge.runtime.sealed`, then copy the listed scripts into `runtime/`.
3. **Update the record.** Change the Commit line above. Add a row with `-` hashes for each new file, and remove the rows of files t1 dropped.
4. **Record the hashes.** Run `python3 runtime/provenance.py record --t1 <t1 checkout>`. It refuses a checkout at another commit, and any file that is not t1's with the recorded change.
5. **Test.** Run `python3 runtime/provenance.py check`, the script tests and `./gradlew :native:sealed-runtime:test` (from `app/android`). CI runs all three.
6. **Commit** it as one change ("vendor t1 <sha>"), and say what t1 changed.

**Vendored files are never edited here.** A fix goes to t1 first, as an upstreamable patch, and is then re-vendored. A need that is CodeForge's own goes into a separate CodeForge file (REPOSITORY_STRUCTURE's boundary rule 3).

## The pins

`runtime/pins.json` pins every input of the payload: the bootstrap for each ABI, by t1's SHA-256, and the resolved core set, each package by version, file and SHA-256. `runtime/README.md` and docs/BUILD_AND_RELEASE.md §3 describe how CI fetches the pins, caches them and fails closed, and how a deliberate `[repin]` commit re-pins.
