# CodeForge editor page

The editor surface that the Flutter app hosts in a WebView: CodeMirror 6 behind
a small, versioned message protocol. Dart owns documents, files, journaling and
saving; this page owns rendering, input, selection and in-editor undo. Design
and budgets: [EDITOR_ARCHITECTURE.md](../docs/EDITOR_ARCHITECTURE.md),
[ADR-0004](../docs/adr/0004-editor-engine.md),
[PHASE_2_PLAN.md](../docs/phases/PHASE_2_PLAN.md).

| Command | What it does |
|---|---|
| `npm ci` | installs exactly the lockfile (Node 24 in CI, see `.nvmrc`; Node ≥ 22 locally) |
| `npm run typecheck` | `tsc --noEmit`, strict |
| `npm test` | vitest: protocol fixtures, change sets checked against CM6, batcher, languages, controller, bridge |
| `npm run licenses` | runtime dependencies against the licence allowlist |
| `npm run build` | writes `app/assets/editor/{editor.html,manifest.json,NOTICES.txt}` |
| `npm run verify` | checks the built page and boots it against a fake host |
| `npm run ci` | all of the above, in CI order (the `editor` job in `.github/workflows/ci.yml`) |

## Layout

| Path | Contents |
|---|---|
| `src/protocol/types.ts` | protocol v1 message catalogue and limits |
| `src/protocol/validate.ts` | strict envelope and payload validation (unknown fields are rejected) |
| `src/protocol/changes.ts` | change-set application: the reference the Dart shadow buffer mirrors |
| `src/editor/` | `controller.ts` (documents, commands, search), `batcher.ts` (150 ms change batching), `languages.ts`, `theme.ts` |
| `src/bridge.ts`, `src/main.ts` | host channel and page entry point |
| `src/page.html` | page template: CSP, inline style, inline script |
| `test/fixtures/` | JSON contract fixtures, shared with the Dart tests |
| `tool/` | `build.mjs`, `verify_bundle.mjs`, `check_licenses.mjs` |

## The page

`build.mjs` produces one self-contained document: the minified script, the
style and the JetBrains Mono font are all inline, and the page makes no network
or file requests. Its Content-Security-Policy denies everything by default and
allows exactly one script, pinned by SHA-256, so a modified script does not run.
The host loads the document with `loadHtmlString` under
`https://appassets.androidplatform.net/` (see
[SECURITY.md §3](../docs/SECURITY.md#3-webview--bridge-hardening-phase-2) for why
it is not served through `WebViewAssetLoader`). The output is not committed: CI
rebuilds it, and `manifest.json` records its size, gzipped size, SHA-256 and the
bundled packages. The build is deterministic, so the same inputs give the same
bytes, and it fails if the gzipped page exceeds the ADR-0004 budget of 1.5 MiB.
`NOTICES.txt` carries the licence texts of the bundled packages, which the
minifier strips from the script.

## Protocol v1

Every message is a JSON envelope `{"v": 1, "id": "…", "type": "…", "payload": {…}}`.
The host sends through `window.codeforge.receive(json)`; the page answers through
the `CodeForgeBridge` channel. Every host message gets exactly one `response`
(`{"re": id, "ok": true, "result": …}` or `{"re": id, "ok": false, "error": {"code", "message"}}`).

| Direction | Types |
|---|---|
| host → editor | `editor.configure`, `doc.open`, `doc.activate`, `doc.close`, `doc.replace`, `doc.flush`, `doc.snapshot`, `cmd.insert`, `cmd.exec`, `cmd.gotoLine`, `search.set` |
| editor → host | `editor.ready`, `doc.changed`, `doc.viewState`, `editor.history`, `editor.focus`, `ime.composition`, `app.shortcut`, `editor.log`, `response` |

- **Incremental edits.** Edits travel as CM6 change sets (a number keeps that
  many characters, `[n]` deletes `n`, `[n, ...lines]` replaces `n` with the
  given lines), batched for 150 ms and flushed early on document switch, close,
  snapshot, app shortcut and `doc.flush`. Each `doc.changed` carries
  `baseVersion`, `version`, `lengthBefore` and `lengthAfter`, so the host can
  detect a gap or a mismatch instead of silently diverging.
- **Text model.** Text is LF-only; positions are UTF-16 code units, as in
  JavaScript and Dart strings. Line endings are converted at file I/O by the
  host.
- **Limits.** A message may hold at most 32 Mi characters: only whole-document
  messages (`doc.open`, `doc.replace`, snapshots) come near it, and the largest
  supported file is 10 MB.

The fixtures in `test/fixtures/` are the contract. `protocol/valid` and
`protocol/invalid` hold messages with their expected verdicts; `changes/` holds
change sets with the text before and after, each verified against CM6's own
`ChangeSet.apply`. The Dart validator and shadow buffer run the same files.
