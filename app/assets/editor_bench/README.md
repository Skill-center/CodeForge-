# Editor benchmark pages (Phase 2 W3)

This directory is listed in `pubspec.yaml` so that the engine benchmark
pages are bundled **when they exist**. They are never committed:

- `codemirror.html`, `monaco.html`: one self-contained page per engine,
- `manifest.json`: size, gzip size and SHA-256 per page (the app refuses a
  page that does not match),
- `NOTICES.txt`: the licences of everything either page bundles.

Build them with `npm ci && npm run build:bench` in `editor/`. CI does that
for the phase gate's debug APK and the phone profile APK only; every other
build ships this README alone, and Settings → Developer → Editor benchmark
says the pages are not part of the build. See
`docs/phases/PHASE_2_PLAN.md` (W3) and `docs/adr/0004-editor-engine.md`.
