# Runtime Integration

**Status:** Design accepted (ADR-0001/0005); implementation Phase 4: the kernel and the pins since W2, the host's install and audit since W3 (§2–3) · Basis: [EXISTING_RUNTIME_AUDIT.md](EXISTING_RUNTIME_AUDIT.md)

This document defines *how* the audited t1 sealed runtime becomes CodeForge's execution foundation. The audit's conclusion: **integration, not research** — the model is proven at targetSdk 36 on API 36; our job is to embed it without breaking its invariants.

---

## 1. Integration approach (chosen)

**Native Kotlin host embedding vendored Java modules, exposed to Flutter via Pigeon + EventChannels.**

Alternatives evaluated (spec §2 requires this):

| Approach | Verdict |
|---|---|
| **Kotlin host + vendored modules + Pigeon** ✅ | Modules are JVM code already; typed boundary; testable host; no JNI beyond what t1 ships |
| Direct Dart FFI into runtime | Rejected: PTY/process supervision needs Android lifecycle awareness (Context, foreground service); FFI would duplicate harness-core in Dart |
| JNI-only interface | Rejected: t1 already exposes Java APIs (`HarnessConfig`, `HarnessSession`, `SealedInstaller`); JNI adds a layer with no benefit |
| Rewrite runtime in Dart/Kotlin | Rejected: spec §2 forbids unnecessary rebuild; four device-hardened invariants would be re-learned the expensive way |
| proot distro | Rejected: see TECH_STACK.md §5 |

## 2. Module embedding plan (Phase 4 workstream order)

1. **Vendor `sealed-runtime` whole** (8 classes + JVM tests). Rename package to `dev.codeforge.runtime.sealed` via t1's `export-sealed-runtime.sh` pattern; tests must pass unchanged. This module has zero Android APIs — it runs in `./gradlew :native:sealed-runtime:test` on any JVM. **Done in Phase 4 W2** from t1 `d9789a2`: the 11 files differ from t1 only in their package line, and the 22 tests pass in CI (native/PROVENANCE.md).
2. **Vendor `harness-core` subset**: `HarnessConfig`, `HarnessPaths`, `HarnessEnvironment`, `HarnessSession`, `HarnessCommandRunner`, `HarnessSizeReport`, `Toolchain`, `exec/SealedPayloadInstaller`, `packs/{Pack,PackState,PackResult,PackInstaller,PlayPackInstaller,Packs}`. **Excluded**: `HarnessBootstrap`, `provision/*`, `AptPackInstaller`, `PackageCommands` — the apt shape does not ship. `Packs.isSealedBuild` becomes compile-time true; the apt branch is deleted, not toggled (no dead code paths that could fetch code at runtime). **As built in Phase 4 W3, a smaller subset** (PHASE_4_PLAN *As built (W3)*):
   - **Vendored:** `HarnessConfig`, `HarnessPaths` and `exec/SealedPayloadInstaller`, renamed into `dev.codeforge.runtime.core` and otherwise t1's.
   - **Not vendored:** `HarnessSizeReport` and `packs/*` need edits to drop the apt shape, and a vendored file is never edited (AGENTS §4). The host measures the sizes itself, and packs wait for the build-tools pack.
   - **Moved to W4:** `HarnessEnvironment`, `HarnessCommandRunner` and `Toolchain`. `HarnessEnvironment.prepare` calls `HarnessBootstrap` and writes the apt configuration.
   - `HarnessSession` stays out (ADR-0011).
3. **Vendor the preload**: `harness-exec.c`, `harness-probe.c`, `Android.mk` with the 16 KB linker flags. **Decided 2026-11-12 (ADR-0011, Apache-2.0):** `termux.c` and Termux's parser and view are not vendored; the PTY is CodeForge's own, written in Phase 5 (ADR-0006: xterm.js). **Built in W3:** both C files byte for byte. CodeForge's own `Android.mk` builds the preload with t1's 16 KB flags (t1's would also build `libtermux`), and the exec probe is built as an executable named `libharnessprobe.so`. CI checks the 16 KB alignment of every shipped object in the APK.
4. **Vendor `runtime/` scripts** + pins; wire into Gradle exactly as t1 does (generated assets, SHA-256 verification, `extractNativeLibs=true`, `useLegacyPackaging=true`). **The scripts and the pins are in since Phase 4 W2** (runtime/README.md). The pins cover every input: the bootstrap per ABI and 50 packages per ABI. A build takes exactly those and fails closed when one is gone. Resolving keeps the composed payload consistent: the bootstrap's `curl` and `xz-utils` follow the newer libraries they need exactly. **The Gradle wiring is in since W3:** for each payload ABI, `native/runtime-core`'s tasks take the pinned files and run t1's builder. The results go into the APK as generated assets and JNI libraries, with `extractNativeLibs=true` and `useLegacyPackaging=true`. An APK carries one ABI's payload at most (BUILD_AND_RELEASE §3).
5. **Port the gates**: `ExecModelTest` + `SealedShellTest` become CodeForge instrumentation tests in `app/android/app/src/androidTest/`. They run in CI on x86_64 emulators at API 34/36 **and on arm64 hardware** (Firebase Test Lab, ADR-0009 amendment; closes audit gap R2) before MVP 4 is declared.

### The four invariants (non-negotiable, from t1's device failures)

1. Executables are **symlinks into `nativeLibraryDir`, never copies** — copies in app data cannot exec at target 29+.
2. Payload **verified while written** (sha256 + size per file); truncated payload = failed install, never silent.
3. Dependencies resolved **by version, not name**; soname links created from `DT_NEEDED` (no postinsts run).
4. Interpreters get **explicit env** (`PYTHONHOME`, `GEM_HOME`, `NODE_PATH`) — `/proc/self/exe` points into the APK, not the prefix.

## 3. RuntimeHost (Kotlin) responsibilities

```
RuntimeHost
├── install(payload)      → SealedInstaller via SealedPayloadInstaller adapter
│                           streams InstallProgress → Dart EventChannel
├── audit()               → ExecAudit at every startup; non-zero = degraded mode + report
├── environment()         → HarnessEnvironment.create (preload order, prefix vars)
│                           as built (W4): CodeForge's RuntimeEnvironment
├── exec(request)         → one-shot command (HarnessCommandRunner), typed result
│                           as built (W4): CommandRunner through libcodeforge-spawn.so
├── session(spec)         → PTY session (CodeForge's own, Phase 5), registered in SessionRegistry
├── tools()               → Toolchain discovery: path, version, health per tool
│                           as built (W4): CodeForge's Toolchain, versions against the pins
└── packs()               → PlayPackInstaller (Play) / bundled full variant (GitHub)
```

- **Lazy initialization:** runtime install/verify happens on first workspace open, off the UI thread, with progress events; app shell is usable before runtime is ready (editor works on files without runtime).
- **Capability model (spec §6.5):** each language advertises `{editable, analyzable, compilable, executable}` separately. Phase 1: all languages editable-only. Phase 4 flips executable for JS/Python/shell; Phase 6 flips analyzable per LSP; build-tools pack flips compilable for C/C++. **As built in Phase 4 W4:** `app/lib/core/editor/capabilities.dart`. JavaScript (node), Python (python) and shell scripts (bash) are executable once the runtime is ready, and only that flag changes; *Run* comes in Phase 5. A file is a shell script by its extension (`.sh`, `.bash`) or its `#!` line (`sh`, `bash`, `dash`), and the status strip's language chip names it *shell* and says in its tooltip whether the runtime can run it.
- **Sessions:** `SessionRegistry` owns every child process; foreground service while any session lives; process-group termination on close; exit codes + typed failures surfaced; no zombie processes (instrumented test asserts). **As built in Phase 4 W4:** one-shot commands only, each a session of the registry, which ends its whole process tree (SECURITY §2.1); the foreground service comes with Phase 5's terminal sessions.
- **Working directories:** sessions start in the workspace root (SAF-backed or app-private); `HOME`, `TMPDIR`, XDG dirs live in the runtime root, never in the user's project. **As built in Phase 4 W4:** a command runs in the runtime's home, or in a folder inside the runtime's home or its workspace (t1's layout). How a project in `files/workspaces/` or a folder from shared storage reaches the runtime is Phase 5's, with *Run* (ADR-0013). **Since W6** one command runs in a project's folder: search's ripgrep (`app/android/…/search/SearchHost.kt`), streamed line by line through `CommandRunner.stream` (SECURITY §2.1).

**As built in Phase 4 W3** (`app/android/app/src/main/kotlin/dev/codeforge/app/runtime/`; PHASE_4_PLAN *As built (W3)*):
- **`install`, `audit`, the status and the sizes** exist, behind the Pigeon API `pigeons/runtime_api.dart`: `status`, `start`, `reinstall`, `audit` and `size`. Every change of state reaches Dart through `RuntimeEvents.changed`, the install's progress included.
- **One background thread** runs them all (`RuntimeHub.kt`), so an install, a warm start and an audit never overlap.
- **The install** uses t1's installer, which verifies every file while writing it. CodeForge's marker, `codeforge/installed.properties` in the runtime's root, is written only after a verified install. A failure is typed (`corrupt`, `incomplete`, `storage`, `missing_executables`, …) and leaves nothing marked installed.
- **A warm start** extracts nothing. It re-applies t1's layout and points every executable's link at the current `nativeLibraryDir`, which changes when the app is updated. In gate 43808489945 it took 18 ms. It took 48 ms through the app after the gate had installed the app again, which moved the libraries: all 535 links were repointed.
- **The audit** runs at every start, after the install or the warm start. Any binary outside the APK makes the runtime degraded, with a report the user can copy. Scripts are listed apart: they run through the preload.
- **Lazy, as designed:** the install starts when a workspace opens, never at app start.
- **Still to come:** sessions in Phase 5; packs with the build-tools pack. `environment`, `exec` and `tools` came in W4 (below).

**As built in Phase 4 W4** (the same folder; PHASE_4_PLAN *As built (W4)*; SECURITY §2.1):
- **CodeForge's own exec model,** not t1's `HarnessEnvironment`, `HarnessCommandRunner` and `Toolchain` ([native/PROVENANCE.md](../native/PROVENANCE.md) says why).
  - `RuntimeEnvironment` builds every command's environment from nothing: up to six of Android's system locations from the app's process, and the rest the runtime's own, with the interpreters' homes set explicitly (`PYTHONHOME`, `NODE_PATH`, `GEM_HOME`, `RUBYLIB`, `PERL5LIB`) and CodeForge's `harness-exec` as the only preload.
  - `CommandRunner` runs a program from the runtime's `bin` through the launcher `libcodeforge-spawn.so` (`native/runtime-core/src/main/jni/codeforge-spawn.c`), in the runtime's home or a folder inside its home or workspace, with a time limit and capped output.
  - `SessionRegistry` owns each command's process, enforces its deadline, and ends its whole tree; before an install it ends them all.
- **`exec` and `tools` over Pigeon** (`pigeons/runtime_api.dart`), answered on threads of their own, only while the runtime is ready or degraded, never during an install. `exec` answers with the typed result (exit code or signal, stdout and stderr apart with their byte counts, duration, failure kind).
- **The tools:** node, python, git, bash, perl, ruby and rg. Each probe runs the tool once, and the interpreters load some of their libraries too (node finds npm's package; python imports `ssl`, `json` and `sqlite3`; perl loads `strict` and `List::Util`; ruby requires `rubygems` and `securerandom`). The version it reports is compared with its package's pin from the payload's info. Settings → Linux runtime lists them, each with its health (*ok*, *mismatch*, *failed* or *missing*), and checks them again on request. In phase gate 43837693816 all seven were their pinned versions, instrumented (693 ms for the seven) and in the app's Settings (1,161 ms): node 26.13.1, python 3.14.10, git 2.56.1, bash 5.3.9, perl 5.44.0, ruby 4.0.9 and rg 15.2.0.
- **What runs:** in W4 only the app's own commands, the probes and the tests. Nothing the user writes runs before Phase 5, which also brings the limits SECURITY §2.1 lists as not yet built.

**As built in Phase 4 W5** (PHASE_4_PLAN *As built (W5)*):
- **The install goes through the kernel's `SealedInstaller.install`.** From W5 to W7 it went through `PayloadInstall.kt`, a copy of the entry point's steps, because the kernel read its manifest stream with `InputStream.readAllBytes()`, which Android has only from API 33. Since W7 the vendored kernel carries CodeForge's fix, a recorded patch (native/PROVENANCE.md, *Patches*; the owner allowed changes to t1's code on 2026-11-18), and `PayloadInstall.kt` is gone. `RuntimeInstallTest` g checks the kernel's read on every API level of the runtime gates.
- **The runtime gates** run the host on x86_64 emulators at API 26, 27, 28, 34 and 36, in every phase gate, and on a physical arm64 phone in Firebase Test Lab, on a `[testlab]` commit. Both run t1's ported `ExecModelTest` and `SealedShellTest`, W3's and W4's instrumented tests, and §6's criteria (all met).
- **CI's API floor check** (`app/tool/ci/check_api_floor.py`) holds the app's dex to minSdk 26 on every push.

## 4. Storage model

| Location | Contents | Access |
|---|---|---|
| App-private `files/coding-harness/` (t1's layout, as built in Phase 4 W3; `files/runtime/` in the design) | sealed prefix (`rootfs/data/data/com.termux/files/usr`, with its `tmp`), `home`, the XDG folders; CodeForge's marker `codeforge/installed.properties` | app only; executables symlink to APK |
| App-private `files/workspaces/` | projects, one folder each (`files/workspaces/<name>`; as built in Phase 3) | app only; no permission prompt |
| SAF user-picked trees | folders from shared storage (as built in Phase 3) | persistable URI grants, no storage permission; `StorageBroker.kt` checks every path segment by segment and walks it from the granted root through the provider's own listings (SECURITY §4.1) |
| `nativeLibraryDir` | APK-shipped executables (read-only) | exec allowed, writes impossible |

Git operations on SAF trees: Phase 7 spike decides between (a) running git on a mirrored app-private checkout with sync, or (b) direct SAF file I/O via a FUSE-free path translation. Default expectation: projects created in-app live app-private (full POSIX semantics); SAF trees are import/export + edit, with runtime execution offered via workspace copy. This is documented honestly in the explorer UX.

**As built in Phase 3:** both workspace rows exist: projects on `dart:io` with atomic saves, and folders through the storage broker, whose saves are written in place (ARCHITECTURE §2.8). Nothing runs yet. Running code, and how a folder from shared storage reaches the runtime (a copy into a project, or import and export), are decided with the runtime in Phase 4 (PHASE_3_PLAN §8).

## 5. Distribution shapes (ADR-0010)

| Channel | Artifact | Runtime delivery |
|---|---|---|
| **GitHub Releases** (first) | "full" APK: base payload + build-tools folded in; arm64-v8a (+x86_64 for emulators) | everything in APK; updates via new APK only |
| **Google Play** | sealed AAB: base ≤ 200 MB/device (arm64 only) + `pack_buildtools` as on-demand PFD | Play delivers packs; **no runtime code download ever** |

Both shapes run the identical sealed execution model; `check-bundle-size.py` + exec audit gate both. The apt shape is **not shipped** (audit §1: unpublishable, and dual mechanisms violate the port guide's "do not have both").

## 6. Phase 4 acceptance (measurable)

- [x] `:native:sealed-runtime:test` green (JVM, unchanged upstream tests): 22 tests, Phase 4 W2 (CI 43401882656); 23 since W7, with the test of CodeForge's recorded patch
- [x] `ExecModelTest` + `SealedShellTest` green on API 34 & 36 x86_64 emulators **and arm64 device**: t1's two tests, ported (native/PROVENANCE.md), green on API 34 and 36 x86_64 in the runtime gates (phase gate 44239443885), and on a physical arm64 phone, a Google Pixel 8a with Android 14, in Firebase Test Lab (CI 44240926191), Phase 4 W5. The legs also run them on API 26 to 28
- [x] ExecAudit = 0 at startup on all gate devices · 0 on the x86_64 emulator at the first start and the warm start, Phase 4 W3 (gate 43808489945); W5: 0 at every first start and warm start, through the installer and through the app's startup path, on API 26, 27, 28, 34 and 36 (phase gate 44239443885) and on the arm64 phone (CI 44240926191)
- [x] node/python/git/bash/perl/ruby/rg version probes reported correctly through RuntimeService → Flutter UI: all seven at their pinned versions on the x86_64 emulator, Phase 4 W4 (gate 43837693816, `RUNTIME_UI tools ok=7 of=7`); W5: all seven at their pins on API 26 to 36 and on the arm64 phone (instrumented, 1,014 ms for the seven there)
- [x] Second launch skips re-extract (t1 measured 11 ms; CodeForge budget ≤ 100 ms): 18 ms median on the x86_64 emulator, Phase 4 W3 (gate 43808489945); W5: 73 ms median on the arm64 phone (samples 64 to 79 ms), and 12 to 37 ms on the emulator legs
- [x] Process termination leaves zero children (instrumented assertion): `RuntimeCommandsTest` e and f on the x86_64 emulator, Phase 4 W4 (gate 43837693816): nothing left after an end, a time limit or an exit; W5: the same on API 26 to 36 and on the arm64 phone
- [x] Payload corruption test: flipped byte → install fails with typed error, no partial runtime marked ready: `corrupt`, for a flipped byte and for a file that differs from its manifest, Phase 4 W3 (`RuntimeInstallTest` e and f, gate 43808489945)
- [x] minSdk gate (ADR-0007): API 26–28 emulator run OR owner-approved raise to 29: the API 26, 27 and 28 legs passed (phase gate 44239443885), so ADR-0007 is Accepted at 26, Phase 4 W5. They found one failure class, in t1's kernel rather than in Android: `InputStream.readAllBytes()` is API 33, so the kernel's install entry point cannot run below it. It was measured on the legs (`NoSuchMethodError` on 26 to 28), avoided by the host (`PayloadInstall.kt`) until W7's patch to the vendored kernel fixed it, and is kept out by CI's API floor check
