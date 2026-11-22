# ADR-0015: The language servers: Pyright, and TypeScript 6 with typescript-language-server, under the sealed node

**Status:** Accepted · 2026-11-22 · Phase 6 W1 ([PHASE_6_PLAN.md](../phases/PHASE_6_PLAN.md) W1, which assigns the choice to W1, with numbers) · the languages decided by the owner on 2026-11-22 (§10, item 2: (a), Python and JavaScript/TypeScript); the servers chosen by the agent from W1's measurements · **the memory budget with a server awaits the owner** (§10, item 3; *Consequences*)

## Context
- **ROADMAP's Phase 6:** at least one full language server, "Pyright or the TypeScript server under the sealed node", with completion, diagnostics, go to definition and rename, restart on a crash, and completion within 300 ms at the 95th percentile. The compatibility spike comes first ([LSP_ARCHITECTURE.md](../LSP_ARCHITECTURE.md) §2).
- **The owner chose servers for both Python and JavaScript/TypeScript** (2026-11-22).
- **What can run:** the sealed runtime ships node 26.13.1 and python 3.14.10 (Phase 4), and programs come only from the APK ([SECURITY.md](../SECURITY.md) §2). So a server is JavaScript or Python that the runtime's interpreters run, or a program built into the APK.
- **TypeScript changed since the seed:** npm's `latest` for `typescript` is 7.0.2, a native port with binaries for 20 platforms and none for Android. 6.0.3 is the last JavaScript release, the one with `tsserver` (PHASE_6_PLAN §0).

## Options
- **Python:**
  - Pyright 1.1.414 (MIT, JavaScript; 19.5 MB in 5,423 files, 5.9 MB compressed);
  - basedpyright 1.40.2 (MIT, Pyright's community fork; 7.8 MB compressed);
  - jedi-language-server 0.47.0 (pure Python, small, but one dependency is LGPL-2.1-or-later);
  - python-lsp-server 1.15.0, which needs ujson, a C extension with no Android wheel, so it can't be installed without a compiler.
- **JavaScript and TypeScript:**
  - typescript-language-server 6.1.0 with TypeScript 6.0.3 (Apache-2.0, JavaScript; 5.1 MB compressed);
  - TypeScript 7's native server: its Linux arm64 binary shipped as one of the APK's programs, unproven on Android.
- **Where the client lives:** in Dart, as LSP_ARCHITECTURE §1 planned, or in the editor's page, with `@codemirror/lsp-client` 6.3.1.

## Measured
`LanguageServerTest` (W1) runs each candidate under the sealed runtime's node, from the test APK's assets, with each tarball checked against the npm registry's SHA-512. The launcher starts the server as it starts a command, in its own session and process group under the session limits, but keeps stdin open. The test speaks LSP's base protocol to it.

The smoke suite, on two files:
- `initialize`, and the error in the diagnostics;
- completion offering a known member: once cold, 50 times repeated, and 50 times after an edit, as typing does;
- definition and rename across the two files;
- the error fixed and its diagnostic gone;
- `shutdown` and `exit`, with no process of the server's group left.

Then the same, apart from definition, rename and the fix, on a generated project of 200 files that its main file imports in full. **Every test passed on every target:** the five runtime legs (API 26, 27, 28, 34 and 36) and Test Lab's Pixel 8a with Android 14, all in phase gate 44977463887.

**On the Pixel 8a** (arm64, a profile build, Test Lab in the same run):

| | Pyright, 2 files | Pyright, 200 files | TypeScript, 2 files | TypeScript, 200 files |
|---|---|---|---|---|
| Start to `initialize`'s answer | 777 ms | 867 ms | 660 ms | 635 ms |
| First diagnostics after `didOpen` | 1,211 ms | 1,509 ms | 2,464 ms | 2,770 ms |
| Completion after an edit: p50 / p95 / max | 28 / 43 / 50 ms | 33 / 56 / 64 ms | 29 / 93 / 180 ms | 32 / 60 / 123 ms |
| Completion repeated: p50 / p95 | 7.9 / 12.0 ms | 7.1 / 10.3 ms | 20.1 / 38.8 ms | 7.5 / 27.2 ms |
| Memory (PSS of the group): idle / after the completions | 142.2 / 167.1 MB | 148.7 / 210.1 MB | 211.6 / 246.7 MB | 219.0 / 255.2 MB |
| Processes in the group | 2 (the launcher, node) | 2 | 3 (the launcher, the server, `tsserver`) | 3 |

**On the emulators** (API 26 to 36, x86_64), the range across the five:

| | Pyright, 2 files | Pyright, 200 files | TypeScript, 2 files | TypeScript, 200 files |
|---|---|---|---|---|
| First diagnostics | 0.67–1.06 s | 0.83–1.10 s | 1.35–1.98 s | 1.45–4.58 s |
| Completion after an edit, p95 | 19–72 ms | 33–78 ms | 16–31 ms | 28–46 ms |
| Memory after the completions | 162–179 MB | 200–218 MB | 238–242 MB | 256–264 MB |

**Also found:**
- **Pyright resolved `import pip` on every target.** It asks the Python on the PATH for its search paths, so node started the runtime's python.
- **Each server exited with 0** about 0.1 s after `exit`, and nothing of its group was left.
- **The largest message was 37,991 bytes:** the TypeScript project's 199 diagnostics, 198 of them hints that an import is unused. The editor's bridge takes 32 Mi characters.
- **Unpacking Pyright's 5,423 files** took 0.9 to 1.5 s on the emulators and 2.7 s on the phone.
- **The launcher's command mode hands a server its stdin unchanged,** so W1 needed no new launcher mode.

MB here is KiB / 1024, as Phase 5's memory figures were.

## Decision
- **Python: Pyright 1.1.414.** **JavaScript and TypeScript: typescript-language-server 6.1.0 with TypeScript 6.0.3.** It runs one `tsserver` (`useSyntaxServer: never`) and fetches no typings from the network (`disableAutomaticTypingAcquisition`).
- **Why these:**
  - Both are JavaScript under the runtime's node, with no native code and permissive licences.
  - Both passed the smoke suite on every target.
  - Completion after an edit stayed within a third of the 300 ms budget on the phone.
- **Not chosen:**
  - basedpyright stays Pyright's fallback, unmeasured.
  - TypeScript 7's native server waits in ROADMAP's queue.
  - jedi-language-server and python-lsp-server are not used.
- **The client lives in Dart,** for the reasons PHASE_6_PLAN W4 gives:
  - a server's session outlives the editor's page;
  - the shadow documents and their versions are Dart's already;
  - diagnostics feed Flutter's UI;
  - the state machine can be tested with a fake transport.

  `@codemirror/lsp-client` is not used.
- **The host:** W1 started each server through the launcher's command mode with stdin kept open, and that held on every target. W3 builds `LspHost` on it unless one of its tests shows otherwise.

## Consequences
- **Memory: a server costs 167 to 255 MB of PSS on the phone,** past what PERFORMANCE §2 planned. With the editor and an open terminal (497.3 MB in Phase 5's exit gate, CI 44900930980), the app reaches about 665 to 753 MB, against PERFORMANCE's 600 MB for the editor, a terminal and one language server.
  - Keeping 600 MB would mean a server under about 103 MB beside them, while the servers take 142 to 219 MB idle.
  - So the budget goes to the owner (PHASE_6_PLAN §10, item 3).
  - Whatever the decision, W3 stops a server that has had no open document for 10 minutes, and runs at most two at once.
- **Size:** about 11.0 MB per device, which W2 measures in the bundle.
- **TypeScript 6.0.3 is the last JavaScript TypeScript.** It checks JavaScript and TypeScript today. Moving to TypeScript 7 means shipping its native binary among the APK's programs.
- **The first install** would grow by Pyright's 5,423 files. W2 installs each language's server only when that language is first needed.
