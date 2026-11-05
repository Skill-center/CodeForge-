# Repository Structure

**Status:** Accepted (ADR-0002). Created incrementally — Phase 1 creates only what Phase 1 needs; later directories appear with their phase. No empty scaffold dirs committed ahead of use.

```
CodeForge-/
├── app/                          # Flutter application (Phase 1)
│   ├── lib/                      # structure per ARCHITECTURE.md §2
│   │   ├── main.dart
│   │   ├── bootstrap/
│   │   ├── design_system/        # tokens / theme / components
│   │   ├── core/                 # errors, logging, platform, utils
│   │   ├── services/             # interfaces + fake/ + native/ impls
│   │   ├── features/             # home, workbench, explorer, editor, terminal,
│   │   │   └── <feature>/        #   search, source_control, extensions,
│   │   │       ├── presentation/ #   run_debug, settings
│   │   │       ├── application/
│   │   │       └── domain/
│   │   └── routing/
│   ├── android/                  # Kotlin host (Phase 1: MainActivity + channels stub)
│   ├── assets/
│   │   ├── editor/               # built CM6 bundle (Phase 2, from editor/ workspace)
│   │   ├── terminal/             # xterm bundle only if ADR-0006 fallback chosen
│   │   ├── fonts/                # bundled UI + mono fonts (offline)
│   │   └── icons/
│   ├── test/                     # unit + widget tests mirror lib/
│   ├── integration_test/         # device/emulator workflow tests
│   └── pubspec.yaml              # pinned; lockfile committed
│
├── editor/                       # TypeScript workspace for WebView bundles (Phase 2)
│   ├── src/
│   │   ├── protocol/             # bridge message types (mirrors Dart contract)
│   │   ├── codemirror/           # CM6 setup, mobile extensions, themes
│   │   ├── monaco/               # challenger build for the ADR-0004 gate
│   │   └── terminal/             # xterm.js fallback frontend (conditional)
│   ├── test/                     # vitest: protocol + change-set round-trips
│   ├── package.json              # exact pins; npm ci only
│   └── esbuild.config.mjs
│
├── native/                       # vendored runtime modules (Phase 4, from t1 @ 0e26d7a)
│   ├── PROVENANCE.md             # source repo, commit, per-module license notes
│   ├── sealed-runtime/           # whole module (plain Java, JVM tests)
│   ├── harness-core/             # subset: config/paths/env/session/runner/size +
│   │                             #   exec adapter + PlayPackInstaller (no apt machinery)
│   ├── terminal-emulator/        # PTY JNI + harness-exec preload (+ parser if ADR-0006 native)
│   ├── terminal-view/            # only if ADR-0006 picks native frontend
│   └── pack_buildtools/          # Play Feature Delivery module
│
├── runtime/                      # runtime supply chain (Phase 4, from t1 scripts/)
│   ├── build-sealed-payload.py
│   ├── fetch-core-debs.py
│   ├── check-bundle-size.py
│   ├── check-page-alignment.py
│   ├── pins.json                 # bootstrap + package versions, SHA-256
│   └── tests/
│
├── docs/                         # all project documentation (spec §13)
│   ├── adr/                      # architecture decision records
│   ├── phases/                   # per-phase plans + exit reports
│   └── *.md
│
├── .github/
│   ├── workflows/                # ci.yml, editor.yml, runtime-gates.yml, release.yml
│   └── PULL_REQUEST_TEMPLATE.md
│
├── AGENTS.md                     # agent development rules (spec §12 workflow)
├── CONTRIBUTING.md
├── README.md
├── LICENSE                       # pending ADR-0011 owner decision
└── THIRD_PARTY_NOTICES.md        # before first binary release (userland obligations)
```

## Boundary rules

1. **`app/` never contains runtime binaries.** Payload assets are generated into Gradle build dirs by `runtime/` scripts at build time (t1 pattern) — never committed.
2. **`editor/` builds deterministic bundles** committed nowhere; CI builds them and the Android build consumes them from a known path. Bundle hash recorded in build metadata.
3. **`native/` is vendored, not forked-and-forgotten.** PROVENANCE.md records upstream commit; changes are either upstreamable patches (documented) or CodeForge-specific adapters in clearly separated files. Re-sync procedure documented there.
4. **Generated artifacts stay out of Git** (build/, .dart_tool/, node_modules/, payloads, APKs). `.gitignore` covers them from Phase 1.
5. **Docs move with code.** A PR that changes architecture updates the matching doc + ADR in the same PR (spec rule 12).

## Why one Flutter package (not a Melos monorepo)

Through Phase 6 there is exactly one Dart consumer. Package splits (`codeforge_design_system`, `codeforge_services`) add versioning overhead with no second consumer to justify it. The internal directory boundaries + CI import lint give the same discipline. Split trigger: a second app/package needs the design system or services — then extract with tests intact.
