# ADR-0003: Riverpod 3.x for state/DI + GoRouter 18.x for navigation

**Status:** Accepted · 2026-11-05

## Context
Spec mandates Riverpod + GoRouter. Versions verified 2026-11-05: riverpod 3.4.3, go_router 18.1.3 (git tags). Riverpod 3 brings mature Notifier/AsyncNotifier, autoDispose, and offline mutation handling; codegen is optional.

## Decision
- **Riverpod 3.x** as the only state/DI system: Notifier/AsyncNotifier controllers, immutable states, provider families for workspace/session scoping, autoDispose for session state.
- **Phase 1: no riverpod_generator/build_runner** — hand-written providers and copyWith immutables keep the critical path codegen-free; revisit when boilerplate measurably hurts.
- **GoRouter 18.x** with a StatefulShellRoute workbench, typed route params, deep links, restoration-friendly URLs.
- No second state library; no GetX/Provider/Bloc mixing.

## Consequences
- Compile-safe dependency graph; widget tests inject fakes via provider overrides.
- Slightly more boilerplate early, zero codegen fragility in CI; Drift adds codegen later, contained to data.
- Navigation state is restorable and testable without a device.
