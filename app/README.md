# CodeForge app

Flutter client for CodeForge — a mobile-first code workbench. This directory
is the Flutter package; repository-level docs live in `../docs/`.

## Toolchain (pinned)

| Tool | Version | Source of truth |
|---|---|---|
| Flutter | 3.50.0 | `../.flutter-version` |
| Dart | ships with Flutter | — |
| JDK | Temurin 17 | CI `setup-java` |
| Gradle | 9.5.0 | `android/gradle/wrapper/gradle-wrapper.properties` |
| AGP | 9.3.3 | `android/settings.gradle.kts` |
| Kotlin | 2.4.20 | `android/settings.gradle.kts` |

`android.builtInKotlin=false` is set deliberately: the Flutter Gradle plugin
applies the classic Kotlin Android plugin itself (verified against the
3.47.9 template sources; 3.50.0's template sets the same flags). Do not add `kotlin-android` to the app plugins
block.

## Layout

```
lib/
  core/            pure Dart: failures, logger, breakpoints, command registry
  design_system/   tokens, theme, reusable components (no app logic)
  services/        contracts + fakes + persisted stores (settings, shell)
  application/     Riverpod controllers, router, command wiring
  features/        screens: home, palette, workbench, settings
  app.dart         root widget
  bootstrap.dart   async startup: prefs, stores, error hooks
  main.dart        entrypoint
```

Architecture rules are enforced by `tool/lint_imports.dart` (layering) and
`tool/check_licenses.dart` (dependency licenses). See `../docs/ARCHITECTURE.md`.

## Run locally

```bash
flutter pub get
flutter run                 # attached device / emulator
```

## Quality gates (same as CI)

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
dart run tool/lint_imports.dart
dart run tool/check_licenses.dart
flutter test --coverage
```

Golden baselines live in `test/goldens/`. After an intentional UI change:

```bash
flutter test --update-goldens --tags golden
```

Integration tests (device/emulator required):

```bash
flutter test integration_test/smoke_test.dart -d <device>
```

The restore gate runs `restore_a_test.dart`, force-stops the app, then runs
`restore_b_test.dart` — see `tool/ci/emulator_gate.sh`.

## CI

- `.github/workflows/ci.yml` — quality gates + debug APK on every push/PR.
  A commit message containing `[bootstrap]` lets CI generate the artifacts
  the authoring sandbox cannot (lockfile, `dart fix`/format results, golden
  baselines) and commit them back with `[skip ci]`.
- `.github/workflows/phase-gate.yml` — emulator integration + process-death
  restore + cold-start measurement, triggered by `[phase-gate]`.

## Conventions

- Relative imports inside `lib/` (`prefer_relative_imports`).
- Trailing commas everywhere (`require_trailing_commas`).
- No `print` in `lib/` — use `appLogger` (redacts secret-looking fields).
- Persisted state uses a `{schemaVersion, data}` envelope and tolerant
  decode; corrupt or future-version data falls back to defaults.
