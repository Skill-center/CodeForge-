# ADR-0005: Sealed execution model only — targetSdk/compileSdk 36, no runtime code downloads

**Status:** Accepted · 2026-11-05

## Context
Android 10+ blocks `execve()` from app-writable storage for apps targeting API 29+ (W^X). Play's Device & Network Abuse policy forbids downloading executable code post-install. The audited t1 project proves the way through: the **sealed** model — executables ship in the APK as JNI libraries (`extractNativeLibs=true`, `useLegacyPackaging=true`), the Termux-shaped prefix symlinks into `nativeLibraryDir`, only read-only data is extracted (hash-verified while written), an `LD_PRELOAD` translator fixes relocated paths/shebangs, and optional toolchains arrive as Play Feature Delivery modules. Proven at targetSdk 34-on-34 and 36-on-36 (CI run 40078102513): bash/git/python/node 26/perl/ruby/rg all execute, ExecAudit = 0.

## Decision
- CodeForge ships **only the sealed shape**. The apt shape (targetSdk 28, runtime `apt install`) is not shipped; its machinery (`HarnessBootstrap`, `provision/*`, `AptPackInstaller`) is not vendored.
- `compileSdk = targetSdk = 36`; bundle builds refuse lower targets (t1 guard carried over).
- The four sealed invariants are non-negotiable (RUNTIME_INTEGRATION.md §2): symlinks-not-copies; verify-while-writing; version-resolved deps + DT_NEEDED sonames; explicit interpreter env.
- `ExecAudit` runs at every startup; non-zero → degraded mode + visible report, never silent.
- Optional tools: Play Feature Delivery (Play) or folded into the "full" APK (GitHub). **No executable ever arrives over the network at runtime.**

## Consequences
- Store-legal and direct-distribution with one execution model; no `system_linker_exec` hacks.
- Native addons compiled on-device (node-gyp, pip source builds) cannot exec from data — detected and reported with guidance (SECURITY.md §2); pure-JS/wheel paths preferred in UX.
- Base size ~136 MB + Flutter/editor ≈ within 180 MB budget; the spec's 50 MB assumption is formally retired (audit §6).
- Runtime updates ship with app updates (or Play packs) — a feature for integrity, a constraint for freshness; documented.
