# Repository Structure

**Status:** Accepted (ADR-0002). Created incrementally — Phase 1 creates only what Phase 1 needs; later directories appear with their phase. No empty scaffold dirs committed ahead of use.

```
CodeForge-/
├── app/                          # Flutter application (Phase 1)
│   ├── lib/                      # structure per ARCHITECTURE.md §2
│   │   ├── main.dart
│   │   ├── bootstrap/
│   │   ├── design_system/        # tokens / theme / components
│   │   ├── core/                 # errors, logging, platform, utils;
│   │   │                         #   editor/: protocol v1 mirror, change sets, shadows;
│   │   │                         #   files/: workspace paths, text codec, file stamps
│   │   ├── services/             # interfaces + fake/ + native/ impls;
│   │   │                         #   files/: the dart:io file service + demo project;
│   │   │                         #   platform/: the app's files folder (one channel);
│   │   │                         #   editor/: WebView surface, page verification;
│   │   │                         #   editor/bench/: benchmark pages + their WebView;
│   │   │                         #   perf/: frame timing recorder
│   │   ├── application/          # controllers + providers; editor/: the editor host;
│   │   │                         #   documents/: open documents and tabs;
│   │   │                         #   bench/: the engine benchmark runner
│   │   ├── features/             # home, workbench, explorer, editor, terminal,
│   │   │   └── <feature>/        #   search, source_control, extensions,
│   │   │       ├── presentation/ #   run_debug, settings (settings/developer/:
│   │   │       │                 #   benchmark + frame timing, non-release only)
│   │   │       ├── application/
│   │   │       └── domain/
│   │   └── routing/
│   ├── android/                  # Kotlin host (MainActivity; W4: the paths channel)
│   ├── assets/
│   │   ├── editor/               # built editor page (gitignored; CI builds it from editor/)
│   │   ├── editor_bench/         # benchmark pages (gitignored except README; the phase
│   │   │                         #   gate builds them for its debug APK and the phone APK)
│   │   ├── terminal/             # xterm bundle only if ADR-0006 fallback chosen
│   │   ├── fonts/                # bundled UI + mono fonts (offline)
│   │   └── icons/
│   ├── test/                     # unit + widget tests mirror lib/; support/: scripted
│   │                             #   editor page, benchmark pages, in-memory files
│   ├── integration_test/         # device/emulator workflow tests
│   └── pubspec.yaml              # pinned; lockfile committed
│
├── editor/                       # TypeScript workspace for the editor page (Phase 2)
│   ├── src/
│   │   ├── protocol/             # v1 message catalogue, strict validator, change-set reference
│   │   ├── editor/               # CM6 controller, change batcher, languages, theme, palette
│   │   ├── bridge.ts, main.ts    # host channel + page entry point
│   │   └── page.html             # template: CSP + inline style + inline script
│   ├── test/                     # vitest: protocol, change sets vs CM6, controller, bridge
│   │   └── fixtures/             # JSON contract fixtures, shared with the Dart tests
│   ├── tool/                     # build.mjs, verify_bundle.mjs, check_licenses.mjs,
│   │                             #   page_kit.mjs (shared), build_bench.mjs,
│   │                             #   bench_cdp.mjs (DevTools driver), bench_report.mjs
│   ├── bench/                    # benchmark harness, CM6 + Monaco adapters, page template,
│   │                             #   composition cases (Phase 2 W3)
│   ├── package.json              # exact pins; npm ci only
│   └── .nvmrc                    # Node 24 in CI
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
│   ├── phases/                   # per-phase plans + exit reports, phone checklists;
│   │                             #   evidence/: owner device runs (screenshots, raw results)
│   └── *.md
│
├── .github/
│   ├── workflows/                # ci.yml (editor + Flutter jobs), phase-gate.yml; release.yml later
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
2. **`editor/` builds a deterministic page** committed nowhere: CI builds it into `app/assets/editor/` and the Android build consumes it from there. `manifest.json` records its SHA-256, size and bundled packages.
3. **`native/` is vendored, not forked-and-forgotten.** PROVENANCE.md records upstream commit; changes are either upstreamable patches (documented) or CodeForge-specific adapters in clearly separated files. Re-sync procedure documented there.
4. **Generated artifacts stay out of Git** (build/, .dart_tool/, node_modules/, payloads, APKs). `.gitignore` covers them from Phase 1.
5. **Docs move with code.** A PR that changes architecture updates the matching doc + ADR in the same PR (spec rule 12).

## Why one Flutter package (not a Melos monorepo)

Through Phase 6 there is exactly one Dart consumer. Package splits (`codeforge_design_system`, `codeforge_services`) add versioning overhead with no second consumer to justify it. The internal directory boundaries + CI import lint give the same discipline. Split trigger: a second app/package needs the design system or services — then extract with tests intact.
