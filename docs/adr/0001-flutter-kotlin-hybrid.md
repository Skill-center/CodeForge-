# ADR-0001: Flutter UI + Kotlin/Java Android host embedding the audited runtime

**Status:** Accepted · 2026-11-05

## Context
Spec mandates Flutter as the primary framework with native Android integration where Flutter alone is insufficient. The audit (EXISTING_RUNTIME_AUDIT.md) found the existing Linux environment (m-cyber12/t1) is a mature JVM/NDK codebase: sealed-runtime (plain Java), harness-core (Java), PTY JNI (C), proven at targetSdk 36 on API 36.

## Decision
- Flutter (Dart) owns **all UI and application logic**.
- A thin **Kotlin host** inside `app/android/` owns Android-specific services: runtime lifecycle, process/session supervision, SAF storage, WebView hosting, foreground service.
- The t1 modules are **vendored as Gradle modules** (Java stays Java — no rewrite) and exposed to Dart through **Pigeon** typed APIs + **EventChannel** streams.
- No Dart FFI into the runtime; no JNI beyond what t1 already ships.

## Consequences
- Reuse of device-proven code with its JVM tests intact (spec §2 reuse mandate).
- Typed, versioned platform boundary; business logic stays testable in Dart with fakes.
- Two languages on the native side (Kotlin host + Java modules) — acceptable: same JVM, clear ownership line (host = orchestration, modules = mechanism).
- Flutter engine adds ~10 MB per ABI to the audited 136 MB base — within the 180 MB budget (PERFORMANCE.md).

## Amendment — Phase 2 (2026-11-06)
Two services this decision gave to the Kotlin host run without host code of our own, because neither needed more than a Flutter plugin or Dart's own APIs offer:
- **WebView hosting** goes through the `webview_flutter` plugin (W2). The hardening is set through the plugin's Android API (SECURITY.md §3).
- **Files in the app-private workspace** use `dart:io` (W4; ARCHITECTURE.md §2.5). The Kotlin host only reports the folder, answering `filesDir` on a plain MethodChannel (`dev.codeforge/paths`). Pigeon arrives with the first multi-method surface.

**SAF storage** stays with the Kotlin host (Phase 3), because `content://` documents need Android APIs; it will sit behind the same Dart `FileService` contract. The ownership line is unchanged: Dart owns logic and plain file work, Kotlin owns what needs Android APIs.
