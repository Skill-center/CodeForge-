# Runtime Integration

**Status:** Design accepted (ADR-0001/0005); implementation Phase 4 · Basis: [EXISTING_RUNTIME_AUDIT.md](EXISTING_RUNTIME_AUDIT.md)

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

1. **Vendor `sealed-runtime` whole** (8 classes + JVM tests). Rename package to `dev.codeforge.runtime.sealed` via t1's `export-sealed-runtime.sh` pattern; tests must pass unchanged. This module has zero Android APIs — it runs in `./gradlew :native:sealed-runtime:test` on any JVM.
2. **Vendor `harness-core` subset**: `HarnessConfig`, `HarnessPaths`, `HarnessEnvironment`, `HarnessSession`, `HarnessCommandRunner`, `HarnessSizeReport`, `Toolchain`, `exec/SealedPayloadInstaller`, `packs/{Pack,PackState,PackResult,PackInstaller,PlayPackInstaller,Packs}`. **Excluded**: `HarnessBootstrap`, `provision/*`, `AptPackInstaller`, `PackageCommands` — the apt shape does not ship. `Packs.isSealedBuild` becomes compile-time true; the apt branch is deleted, not toggled (no dead code paths that could fetch code at runtime).
3. **Vendor PTY JNI + preload**: `termux.c`, `harness-exec.c`, `harness-probe.c`, `Android.mk` with the 16 KB linker flags. Terminal parser/view inclusion depends on ADR-0006.
4. **Vendor `runtime/` scripts** + pins; wire into Gradle exactly as t1 does (generated assets, SHA-256 verification, `extractNativeLibs=true`, `useLegacyPackaging=true`).
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
├── exec(request)         → one-shot command (HarnessCommandRunner), typed result
├── session(spec)         → PTY session (HarnessSession), registered in SessionRegistry
├── tools()               → Toolchain discovery: path, version, health per tool
└── packs()               → PlayPackInstaller (Play) / bundled full variant (GitHub)
```

- **Lazy initialization:** runtime install/verify happens on first workspace open, off the UI thread, with progress events; app shell is usable before runtime is ready (editor works on files without runtime).
- **Capability model (spec §6.5):** each language advertises `{editable, analyzable, compilable, executable}` separately. Phase 1: all languages editable-only. Phase 4 flips executable for JS/Python/shell; Phase 6 flips analyzable per LSP; build-tools pack flips compilable for C/C++.
- **Sessions:** `SessionRegistry` owns every child process; foreground service while any session lives; process-group termination on close; exit codes + typed failures surfaced; no zombie processes (instrumented test asserts).
- **Working directories:** sessions start in the workspace root (SAF-backed or app-private); `HOME`, `TMPDIR`, XDG dirs live in the runtime root, never in the user's project.

## 4. Storage model

| Location | Contents | Access |
|---|---|---|
| App-private `files/runtime/` | sealed prefix (rootfs mirror), home, tmp, markers | app only; executables symlink to APK |
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

- [ ] `:native:sealed-runtime:test` green (JVM, unchanged upstream tests)
- [ ] `ExecModelTest` + `SealedShellTest` green on API 34 & 36 x86_64 emulators **and arm64 device**
- [ ] ExecAudit = 0 at startup on all gate devices
- [ ] node/python/git/bash/perl/ruby/rg version probes reported correctly through RuntimeService → Flutter UI
- [ ] Second launch skips re-extract (t1 measured 11 ms; CodeForge budget ≤ 100 ms)
- [ ] Process termination leaves zero children (instrumented assertion)
- [ ] Payload corruption test: flipped byte → install fails with typed error, no partial runtime marked ready
- [ ] minSdk gate (ADR-0007): API 26–28 emulator run OR owner-approved raise to 29
