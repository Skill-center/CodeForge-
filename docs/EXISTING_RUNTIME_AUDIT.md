# Existing Runtime Audit — m-cyber12/t1 ("Coding Harness")

**Audited:** 2026-11-05 · **Source:** https://github.com/m-cyber12/t1 · **Code branch:** `arena/f91bdedf-t1` @ `0e26d7a` (then open as PR #81 → `main`; **merged on 2026-11-11 as PR #229**, main `7b496c3`, the same tree) · **Upstream version:** 0.33.1 (versionCode 40)

> `main` contains only a 5-byte README. All findings below refer to the PR branch. The repository also carries hundreds of `diagnostics/e2e-*`, `diagnostics/sealed-*-sdk{34,36}`, and `diagnostics/exec-model-*` branches — CI evidence snapshots published every 5 minutes during emulator runs. CodeForge will use workflow artifacts instead (see [BUILD_AND_RELEASE.md](BUILD_AND_RELEASE.md)).

---

## 1. What it is

A standalone Android terminal/coding harness that provisions a **Termux-shaped userland inside its own app sandbox** and drives it through a real PTY. It is deliberately narrower than Termux: bootstrap + package layers, not the Termux app. It was built to be **lifted into a larger host app** — the README and `docs/sealed-runtime-port.md` define the exact reusable surface. This is the asset CodeForge integrates.

Two build shapes exist:

| Shape | Execution | targetSdk | Distribution | Status |
|---|---|---|---|---|
| **apt** | userland extracted to app data, executed there; `apt install` at runtime | 28 (deliberate) | F-Droid / direct only | works, but **not publishable** (W^X + Play downloaded-code policy) |
| **sealed** | every executable ships in the APK as `lib*.so`; prefix symlinks into `nativeLibraryDir`; only read-only data extracted | 34 and 36, both proven | **Play-legal** + direct | **shipping shape; CodeForge adopts this one** |

## 2. Module inventory

| Module | Language | Android APIs | Role | CodeForge disposition |
|---|---|---|---|---|
| `sealed-runtime/` | plain Java | **none** | Install/verify/uninstall kernel: `SealedInstaller`, `PayloadExtractor`, `RuntimeManifest`, `SealedLayout`, `ExecAudit`, `ExecutableProbe`, `ExecutableKind`, `SealedUninstaller` (8 classes, ~1,100 lines + JVM tests) | **Take whole** (vendor as Gradle module) |
| `harness-core/` | Java | yes | `HarnessConfig/Paths/Environment/Session/CommandRunner/SizeReport/Toolchain`, `exec/SealedPayloadInstaller` (ABI/asset adapter, ~180 lines), `provision/*` + `packs/*` (apt machinery) | **Take selectively**: config/paths/environment/session/command-runner/size-report + sealed adapter + `packs/PlayPackInstaller`. **Leave behind**: `HarnessBootstrap`, `provision/*`, `packs/AptPackInstaller` (apt shape not shipped) |
| `terminal-emulator/` | Java + C (JNI) | yes | Termux terminal parser, `TerminalSession` PTY owner; JNI: `termux.c` (PTY), `harness-exec.c` (LD_PRELOAD translator), `harness-probe.c` (exec probe) | **Take** (PTY + preload required; parser needed only for native frontend — see ADR-0006) |
| `terminal-view/` | Java | yes | Termux native terminal renderer: touch, IME, selection, scrollback | **Candidate frontend** via Flutter PlatformView (ADR-0006); xterm.js is the fallback |
| `pack_buildtools/` | Gradle dynamic-feature | yes | Play Feature Delivery module; clang/cmake/make/pkg-config as on-demand sealed pack; `dist:fusing include=true` so universal APKs carry it | **Take pattern + module** (Play channel); GitHub "full" variant folds pack payload into base |
| `app/` | Java | yes | Standalone `MainActivity` + instrumentation gates (`ExecModelTest`, `SealedShellTest`, `CodingHarnessE2eTest`) | **Do not take UI**; **port the instrumentation gates** into CodeForge's Android host |
| `scripts/` | Python/shell | — | `build-sealed-payload.py`, `fetch-core-debs.py`, `check-bundle-size.py`, `check-page-alignment.py`, `assert-gate-results.py`, `export-sealed-runtime.sh`, `run-emulator-e2e.sh` (+ unit tests) | **Take whole** — this is the runtime supply chain |
| `.github/workflows/` | YAML | — | JDK builder, emulator setup E2E (a01–a04), exec-model gate (sealed, SDK 34/36 matrix) | **Adopt patterns** (ADR-0009) |
| `store/` | md | — | Listing, data-safety, privacy policy, release checklist | **Reuse as templates** |

## 3. Build system (verified from source)

- **AGP 8.13.2**, **Gradle wrapper 9.2.1**, **JDK 17** (Temurin in CI), **NDK 27.2.12479018** pinned.
- `minSdk 29`; `compileSdk 35` default, `-PharnessCompileSdk=36` for store; `targetSdk 28` default (apt), `-PharnessTargetSdk=34|36` for sealed. Bundle tasks **refuse** to build below target 36.
- 16 KB page alignment: explicit `-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384` on both ndk-build modules + `scripts/check-page-alignment.py` gate (NDK 27.2 does not align by itself).
- Bootstrap: official Termux `2026.02.12-r1+apt.android-7`, **SHA-256 pinned per ABI** (aarch64, x86_64), downloaded at build time into Gradle build dir — never committed.
- Sealed payload pipeline (`scripts/build-sealed-payload.py`): bootstrap + core `.deb`s → `assets/userland-<abi>.zip` (data only), `sealed-manifest-<abi>.txt` (sha256⇥size⇥path), `sealed-exec-<abi>.txt` (path⇥libname), `sealed-symlinks-<abi>.txt`, and `jniLibs/<abi>/lib*.so`. Dependencies resolved **by Debian version, not name**; soname links created from `DT_NEEDED` (postinsts never run in a payload).
- Signing: `keystore.properties`/env, fails closed; unsigned artifacts are labeled and never uploadable.
- `extractNativeLibs=true` + `jniLibs.useLegacyPackaging=true` on the sealed variant — the two facts that make executables real files in `nativeLibraryDir`.

## 4. On-device runtime layout

```
<app files>/coding-harness/            HAR
├── rootfs/data/data/com.termux/files/usr/   PREFIX (dpkg-shaped mirror; real dirs, never symlinked)
├── workspace/  home/  <xdg dirs>/
├── libharness-exec.so                 LD_PRELOAD translator, extracted from APK
└── markers, logs, setup-result.txt
```

- Executables in `PREFIX/bin` are **symlinks into `nativeLibraryDir`** — absolute paths and `#!` lines keep working; the kernel executes APK-backed inodes only.
- `harness-exec.c` (LD_PRELOAD) translates official-Termux paths in **exec targets, shebangs, opendir/fopen, and argv** — four mechanisms, each added to fix a specific real-device failure.
- Interpreters can't find their own prefix from `/proc/self/exe` (it points into `nativeLibraryDir`): `PYTHONHOME`, `GEM_HOME`, `NODE_PATH` set explicitly.
- `ExecAudit` reports "executables outside the APK" — the publishability number; sealed build asserts **0**.

## 5. Verified capabilities (t1 CI evidence, run `40078102513`, commit `6222a1b`)

Both matrix legs green: `targetSdk 34 on API 34` and `targetSdk 36 on API 36` (x86_64 `aosp_atd` emulators, TCG/no KVM):

```
sealed payload (x86_64): 13858 data files, 1173 data links,
                         535 executables from the APK (→ 252 JNI libs), 13858 verified
bin/bash   → 5.3.9(1)-release      bin/git    → 2.56.0
bin/python → OpenSSL 3.6.5         bin/node   → v26.12.1
bin/perl   → v5.44.0               bin/ruby   → 4.0.7 [x86_64-linux-android]
bin/rg     → 15.2.0 (+pcre2)       second startup: 11 ms (no re-extract)
dpkg records shipped packages as installed; ExecAudit = 0
```

`ExecModelTest` additionally proves the rule itself: nativeLibraryDir exec ✅, same bytes in app data ❌, prefix symlink into APK ✅, official-prefix shebang via preload ✅, direct data-dir script exec ❌.

**Gap:** these gates ran on x86_64. The arm64-v8a payload is built and is the upload ABI, and the *apt* shape was device-tested on arm64 — but **sealed-on-arm64-hardware is not yet evidenced**. CodeForge Phase 4 must run the same gates on arm64 (R2).

## 6. Size truth (measured, not estimated)

| Metric | Value | Source |
|---|---|---|
| Sealed base AAB, per device (arm64-v8a only) | **136.0 MB** (Play cap 200 MB) | t1 ARCHITECTURE.md §10.4, API 36 leg |
| Earlier sealed base measurement | ~165 MB/ABI (before bootstrap-zip removal) | t1 docs/play-store-plan.md §4 |
| Installed core userland (arm64 device, Android accounting) | **360–380 MB** (incl. Perl+Ruby) | t1 docs/size-management.md |
| Emulator core install | 405.1 MiB dpkg apparent / **341.7 MiB unique** | same |
| Build-tools pack | +~620 MB installed; removal returns **byte-identical** pre-install size | E2E a04 |
| Spec's "~50 MB app" | **Not reproducible** at current scope | — |

Assets are delivered whole by Play (not ABI-split): the upload bundle therefore carries **arm64-v8a only**; local APKs keep both ABIs for the emulator gate. `check-bundle-size.py` enforces the per-device cap with unit-tested arithmetic.

## 7. License audit ⚠

| Component | Finding | Implication |
|---|---|---|
| t1 repo | **No LICENSE file**, no headers on original code | Owner (m-cyber12) holds rights; must add an explicit license before CodeForge vendors it |
| `terminal-emulator`, `terminal-view` | Derived from `termux/termux-app` @ `8629e632`; upstream root license **GPLv3-only**, with an exception noting jackpal Android-Terminal-Emulator code is **Apache-2.0**; copied files carry no headers (one support file has an Apache header) | **Conservative reading: GPLv3 applies to the Termux-modified modules.** If CodeForge ships them, the combined app should be GPLv3. A permissive CodeForge is possible by *not* shipping these modules (xterm.js frontend + own/Apache-2.0 PTY) — see ADR-0006/0011 |
| `harness-core`, `sealed-runtime`, JNI preload, scripts, CI | Original t1 code (owner-written) | Owner can license freely; keep attribution |
| Userland binaries (bash, git, coreutils…) | Termux packages: mixed OSS (GPL/LGPL/MIT/PSF/Ruby/Artistic…) | Shipping them in the APK is aggregation, compatible with any app license, **but** GPL components require license texts + source offer (Termux publishes build sources). Add `THIRD_PARTY_NOTICES` + source-offer doc before any binary release |
| Bootstrap zips | Official Termux release, SHA-256 pinned | Same obligations as packages |

**Action:** license decision is an owner gate (ADR-0011). It blocks *release*, not Phase 1–3 development.

## 8. Reuse plan summary

**Take:** `sealed-runtime` (whole) · `harness-core` minus apt machinery · PTY JNI + `harness-exec` preload · payload/build/check scripts · CI gate patterns · `pack_buildtools` PFD pattern · store templates · ~~(candidate) terminal modules per ADR-0006~~ (not taken: the licence is Apache-2.0, 2026-11-12).
**Leave:** `HarnessBootstrap`, `provision/*`, `AptPackInstaller`, standalone `MainActivity`, apt build shape, diagnostics-branch publishing.
**Port:** `ExecModelTest`, `SealedShellTest` into CodeForge's host; the four sealed invariants (symlinks-not-copies; verify-while-writing; version-resolved deps + DT_NEEDED sonames; explicit interpreter env) are non-negotiable and already JVM-tested.

Integration mechanics: [RUNTIME_INTEGRATION.md](RUNTIME_INTEGRATION.md). Vendor provenance will be recorded in `native/PROVENANCE.md` when modules are copied (Phase 4).
