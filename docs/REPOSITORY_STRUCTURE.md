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
│   │   │                         #   terminal/: the session models, the terminal
│   │   │                         #   protocol v1 mirror, the extra keys (Ph. 5);
│   │   │                         #   protocol/: the validators' shared checks (Ph. 5 W3);
│   │   │                         #   files/: workspace paths, text codec, file stamps;
│   │   │                         #   legal/: the source offer About shows (Ph. 5 W1)
│   │   ├── services/             # interfaces + fake/ + native/ impls;
│   │   │                         #   files/: the dart:io file service + demo project;
│   │   │                         #   platform/: the app's files folder (one channel);
│   │   │                         #   editor/: WebView surface, page verification;
│   │   │                         #   editor/bench/: benchmark pages + their WebView;
│   │   │                         #   terminal/: the terminal page's verification and
│   │   │                         #   its Pigeon client (native/, Ph. 5 W2–W3);
│   │   │                         #   perf/: frame timing recorder;
│   │   │                         #   runtime/: the runtime's state + its Pigeon client (Ph. 4),
│   │   │                         #   the userland's licence texts for About (Ph. 5 W1);
│   │   │                         #   search/: search across files + its Pigeon client (Ph. 4 W6)
│   │   ├── application/          # controllers + providers; editor/: the editor host;
│   │   │                         #   terminal/: the terminal page's host + the
│   │   │                         #   sessions' tabs (Ph. 5 W3);
│   │   │                         #   documents/: open documents and tabs;
│   │   │                         #   bench/: the engine benchmark runner
│   │   ├── features/             # home, workbench, explorer, editor, terminal,
│   │   │   └── <feature>/        #   search, source_control, extensions,
│   │   │       ├── presentation/ #   run_debug, settings (settings/developer/:
│   │   │       │                 #   benchmark + frame timing, non-release only)
│   │   │       ├── application/
│   │   │       └── domain/
│   │   └── routing/
│   ├── android/                  # Kotlin host (MainActivity; W4: the paths channel);
│   │                             #   app/src/main/…/runtime/: RuntimeHost and the sealed
│   │                             #   runtime's install and audit (Phase 4 W3), commands
│   │                             #   and tools (W4); …/search/: the search host (W6);
│   │                             #   app/src/androidTest/: the instrumented runtime tests
│   ├── assets/
│   │   ├── editor/               # built editor page (gitignored; CI builds it from editor/)
│   │   ├── editor_bench/         # benchmark pages (gitignored except README; the phase
│   │   │                         #   gate builds them for its debug APK and the phone APK)
│   │   ├── terminal/             # built terminal page, xterm.js (gitignored; CI builds it
│   │   │                         #   from editor/ with the editor page; Phase 5 W3)
│   │   ├── fonts/                # bundled UI + mono fonts (offline)
│   │   ├── licenses/             # (Ph. 5 W1) CodeForge's LICENSE, copied; userland.txt, the
│   │   │                         #   userland's licence texts (runtime/notices.py; CI checks it)
│   │   └── icons/
│   ├── test/                     # unit + widget tests mirror lib/; support/: scripted
│   │                             #   editor page, benchmark pages, in-memory files
│   ├── integration_test/         # device/emulator workflow tests
│   └── pubspec.yaml              # pinned; lockfile committed
│
├── editor/                       # TypeScript workspace for the editor page (Phase 2)
│   │                             #   and the terminal page (Phase 5 W3)
│   ├── src/
│   │   ├── protocol/             # v1 message catalogue, strict validator, change-set reference
│   │   ├── editor/               # CM6 controller, change batcher, languages, theme, palette
│   │   ├── terminal/             # terminal protocol v1 + validator, xterm.js controller,
│   │   │                         #   keys, touch, bridge, entry point, page template
│   │   ├── bridge.ts, main.ts    # host channel + page entry point
│   │   └── page.html             # template: CSP + inline style + inline script
│   ├── test/                     # vitest: protocol, change sets vs CM6, controller, bridge
│   │   └── fixtures/             # JSON contract fixtures, shared with the Dart tests
│   ├── tool/                     # build.mjs, verify_bundle.mjs, check_licenses.mjs,
│   │                             #   build_terminal.mjs, verify_terminal.mjs and
│   │                             #   terminal_cdp.mjs (the composition suite's driver),
│   │                             #   notices.mjs (THIRD_PARTY_NOTICES §3, Phase 4 W7),
│   │                             #   page_kit.mjs (shared), build_bench.mjs,
│   │                             #   bench_cdp.mjs (DevTools driver), bench_report.mjs
│   ├── bench/                    # benchmark harness, CM6 + Monaco adapters, page template,
│   │                             #   composition cases (Phase 2 W3)
│   ├── package.json              # exact pins; npm ci only
│   └── .nvmrc                    # Node 24 in CI
│
├── native/                       # vendored runtime modules (Phase 4, from t1 @ d9789a2)
│   ├── PROVENANCE.md             # source repo + commit, licence, every file's SHA-256 (W2)
│   ├── patches/                  # CodeForge's changes to t1's code, recorded per file (W7;
│   │                             #   the owner's permission, 2026-11-18)
│   ├── sealed-runtime/           # t1's kernel, whole: plain Java, 22 JVM tests (W2), 23 with
│   │                             #   CodeForge's patch (W7)
│   ├── runtime-core/             # (W3) t1's HarnessConfig, HarnessPaths, exec adapter, renamed;
│   │                             #   harness-exec.c/harness-probe.c unchanged, built by its own
│   │                             #   Android.mk and Gradle tasks, which also build the payload
│   │                             #   into the APK; no Termux terminal modules (ADR-0011)
│   └── pack_buildtools/          # (later) Play Feature Delivery module
│
├── runtime/                      # runtime supply chain (Phase 4 W2): t1's scripts/ + CodeForge's
│   ├── build-sealed-payload.py   # t1: the payload from the bootstrap + the pinned .debs
│   ├── fetch-core-debs.py        # t1: Termux's index, the resolver, downloads
│   ├── check-bundle-size.py      # t1
│   ├── check-page-alignment.py   # t1
│   ├── check-sealed-manifest.sh  # t1
│   ├── pins.json                 # every input pinned: bootstrap per ABI, packages, SHA-256
│   ├── pins.py                   # check · fetch (fails closed) · bootstrap · resolve ([repin]) ·
│   │                             #   info (the payload's JSON for the app, W3)
│   ├── notices.py                # writes THIRD_PARTY_NOTICES §5 and SOURCE_OFFER's copyleft
│   │                             #   table from the payload's licence files, with W7's
│   │                             #   reviews; fails on a package with no licence named;
│   │                             #   since Phase 5 W1 also the texts for the app's licence page
│   ├── sources.py                # (Phase 5 W1) the copyleft packages' corresponding source:
│   │                             #   recipes at the commits that built them, Termux's build
│   │                             #   system, the upstream files verified; fails closed
│   ├── provenance.py             # checks native/PROVENANCE.md against the vendored files;
│   │                             #   copy re-vendors them from a t1 checkout (W3)
│   ├── README.md                 # how the supply chain fits together
│   ├── ci-results/               # the runtime job's evidence (committed back)
│   └── tests/                    # t1's 2 script tests, CodeForge's 5 (pins, notices,
│                                 #   provenance, the launcher, sources) + fixtures, live check
│
├── docs/                         # all project documentation (spec §13)
│   ├── adr/                      # architecture decision records
│   ├── phases/                   # per-phase plans + exit reports, phone checklists;
│   │                             #   evidence/: owner device runs (screenshots, raw results)
│   ├── store/                    # Play drafts (Phase 4 W7): listing, Data safety, privacy
│   │                             #   policy, release checklist
│   └── *.md
│
├── .github/
│   ├── workflows/                # ci.yml (editor + Flutter jobs, and the phase gate);
│   │                             #   release.yml (Phase 5 W1): the release build, which ci.yml
│   │                             #   calls for a [release] subject line; dry runs only so far
│   └── PULL_REQUEST_TEMPLATE.md
│
├── AGENTS.md                     # agent development rules (spec §12 workflow)
├── CONTRIBUTING.md
├── README.md
├── LICENSE                       # Apache License 2.0 (ADR-0011, 2026-11-12)
├── THIRD_PARTY_NOTICES.md        # completed in Phase 4 W7; CI writes and checks its lists
└── SOURCE_OFFER.md               # the copyleft userland's source offer (its mechanism decided
                                  #   in W7); published before the first binary release
```

## Boundary rules

1. **`app/` never contains runtime binaries.** Payload assets are generated into Gradle build dirs by `runtime/` scripts at build time (t1 pattern) — never committed.
2. **`editor/` builds deterministic pages** committed nowhere: CI builds them into `app/assets/editor/` and, since Phase 5 W3, `app/assets/terminal/`, and the Android build consumes them from there. Each `manifest.json` records its page's SHA-256, size and bundled packages.
3. **`native/` is vendored, not forked-and-forgotten.** PROVENANCE.md records upstream commit; changes are either upstreamable patches (documented) or CodeForge-specific adapters in clearly separated files. Re-sync procedure documented there. Since Phase 4 W2, CI enforces it: `runtime/provenance.py check` fails when a vendored file differs from t1 by anything but its recorded change and patches, or when a file under `native/` or `runtime/` is unrecorded. Since W7 a patch may change a vendored file, with the owner's permission (2026-11-18): it lives in `native/patches/`, and its file's row names it.
4. **Generated artifacts stay out of Git** (build/, .dart_tool/, node_modules/, payloads, APKs). `.gitignore` covers them from Phase 1.
5. **Docs move with code.** A PR that changes architecture updates the matching doc + ADR in the same PR (spec rule 12).

## Why one Flutter package (not a Melos monorepo)

Through Phase 6 there is exactly one Dart consumer. Package splits (`codeforge_design_system`, `codeforge_services`) add versioning overhead with no second consumer to justify it. The internal directory boundaries + CI import lint give the same discipline. Split trigger: a second app/package needs the design system or services — then extract with tests intact.
