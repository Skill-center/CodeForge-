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
