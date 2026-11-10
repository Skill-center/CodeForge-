# Security

**Status:** Living document · Principles locked Phase 0; controls land with their phases

CodeForge executes user code, shell commands, and (later) third-party extensions. Security is designed in from the start — and described **honestly**: we state what is isolated and what is not.

---

## 1. Trust boundaries (what is actually isolated)

| Boundary | Real? | Mechanism |
|---|---|---|
| App ↔ rest of OS | ✅ | Android app sandbox (UID, SELinux); no root, no special permissions for core features |
| App ↔ shared storage | ✅ | SAF: user-consented trees only, persistable URI grants, revocable |
| WebView renderer ↔ app | ✅ (partial) | Android WebView renderer process isolation; our bridge is the only doorway, validated |
| User code ↔ app data | ❌ **NOT isolated** | Child processes run as the app UID: they can read app-private files. **We never claim otherwise** (spec §7). Mitigations below reduce blast radius, not eliminate it |
| Extension code ↔ app | ❌ same UID | Permission system is a policy layer + interpreter scoping, not an OS sandbox (Phase 8 doc will repeat this) |

UI copy and docs must say "runs locally in CodeForge's sandbox" — never "securely sandboxed" about user code.

## 2. Runtime execution controls (Phase 4+)

- **Exec model:** only APK-backed executables run (sealed invariant; `ExecAudit` = 0 enforced at startup; non-zero → degraded mode + user-visible report). User *scripts* are interpreted by shipped interpreters — never `execve`'d from data.
- **No downloaded executables, ever** (Play policy + W^X): packages/packs arrive only via Play Feature Delivery or a new APK. npm/pip installing **native** addons is a known tension: Phase 5 documents that node-gyp/pip source builds require the build-tools pack and produce data-dir binaries that **cannot exec** at target 36 — such installs are detected and reported with guidance (pure-JS/wheel alternatives), not silently broken. This limitation is surfaced in Runtime Diagnostics.
- **Resource limits:** `ulimit`-style rlimits on child processes where bionic supports (CPU time, file size, nproc); OOM-score adjustments; session count cap (default 8); output flood coalescing. Measured, not assumed.
- **Process hygiene:** process-group kill on session close; foreground service notification with "kill all"; no background execution without a visible session.
- **Environment:** secrets are not injected into child env by default; Git credentials supplied per-invocation via askpass/credential helper, never `PATH`-visible files.

## 3. WebView & bridge hardening (Phase 2+)

- **One self-contained page** (decided in Phase 2; it replaces the original `WebViewAssetLoader` plan). `webview_flutter_android` 4.14.1 exposes no request interception, so `WebViewAssetLoader` is unreachable through the plugin. The editor page is therefore a single document with its script, style and font inline, loaded with `loadHtmlString` under the base URL `https://appassets.androidplatform.net/`, and it makes no network or file requests. The build records the page's SHA-256 in `manifest.json`; the host verifies the asset against it before loading.
- CSP: `default-src 'none'; script-src 'sha256-<build hash>'; style-src 'unsafe-inline'; font-src data:; base-uri 'none'; form-action 'none'`. The hash pins the one inline script, so a modified script does not run, and every other fetch (`connect-src`, `img-src`, frames) falls back to `'none'`. `editor/tool/verify_bundle.mjs` checks the pin against the built page in CI. At the Phase 2 exit (CI 42678576228) the page is 768.4 KiB (291,951 B gzipped), its SHA-256 is `84431233cb8721838888d4a7230c9c5f074c30b7f69e9604bb7c0aa6f67caa8a`, and the CSP pins `sha256-csqXDdzzvB25mLR2mBYrAmqOOjLWRYZ7xGw6yMzoWRc=`. Both hashes change whenever the page does; `app/ci-results/editor/{build,verify}.txt` records them on every bootstrap run.
- WebView settings (`app/lib/services/editor/webview_editor_surface.dart`): `setAllowFileAccess(false)`, `setAllowContentAccess(false)`, geolocation off, media playback only after a user gesture, page zoom off, text zoom pinned at 100 % (the host sends a font size that already includes the user's text scale), JavaScript dialogs refused, remote debugging only in debug builds (`enableDebugging(kDebugMode)`). JavaScript runs only in this one page. The page uses no web storage: editor state lives in Dart. Mixed content and cookies never come into play, because the page makes no requests.
- **The page is verified before it runs:** the host hashes `editor.html` and compares it with the SHA-256 in `manifest.json` (`app/lib/services/editor/editor_page.dart`); a mismatch, a malformed manifest or a different protocol version fails closed. The pane then shows the reason and a retry, and never loads the page.
- **Benchmark pages (Phase 2 W3, non-release builds only):** Settings → Developer → Editor benchmark loads the CodeMirror and Monaco benchmark pages from `assets/editor_bench/`. They are verified against their `manifest.json` hashes the same way (`app/lib/services/editor/bench/bench_pages.dart`) and run in a WebView with the same settings (`bench_surface.dart`). Their `CodeForgeBench` channel only reports measurements to the screen and reaches no file, document or protocol, so it has no rate limit. The developer screens are compiled out of release builds (`kReleaseMode`). The phase gate builds the pages after its release APK, so release builds carry none.
- **One bridge object, one method** (the `CodeForgeBridge` JavaScript channel, `postMessage(String)`); JSON envelope schema-validated on both sides (type allowlist per direction, version check, unknown fields rejected, size cap 32 Mi characters because whole-document messages must fit the largest supported file, 10 MiB (larger files are refused before they are read, W7), host-side token-bucket rate limit: bursts of 240, 120 messages/s, excess dropped and logged); the protocol carries no file paths at all (documents are opaque ids; file access stays in Dart, where W4 confines it to workspace roots); every failure typed + logged; no reflection, no generic "eval" or "exec" message types (the editor protocol's `cmd.exec` runs only a named command from a fixed allowlist, such as undo or indent).
- **Every navigation request is refused** (`onNavigationRequest` → prevent, and logged), the asset origin included: the page never navigates, and only the app's own `loadHtmlString` loads it. No download listener is installed, so nothing can be downloaded.
- **Renderer crashes:** `webview_flutter_android` 4.14.1 exposes no `onRenderProcessGone`, so if the WebView renderer dies, Android ends the app process (the platform default for an unhandled renderer crash). Unsaved text survives that through the edit journal (W5), which brings it back on the next start: phase gate 42386742421 crashed the renderer of a running app holding unsaved text, and the next start restored all of it, still unsaved, with the cursor. A page reload short of a crash is recovered in-app: the host reopens every document from its shadow copy.

## 4. Data protection

| Data | Control |
|---|---|
| Git tokens / SSH keys (Ph. 7) | Android Keystore-backed encryption (AES-GCM, key never leaves Keystore); encrypted blobs in app-private storage; never logged, never in child env by default; SSH via openssh with key files chmod 600 in runtime home, passphrase prompt UI |
| Settings/workspace DB | app-private, and the app itself syncs nothing. **Android Auto Backup is on, by Android's default** (found in Phase 2 W8): the manifest sets neither `android:allowBackup` nor `android:dataExtractionRules`. So when the user has device backup turned on, Android copies the app's files (the workspace, `codeforge.sqlite` with any unsaved text, the settings), up to 25 MB, to the user's own Google Drive about daily, end-to-end encrypted on Android 9+ when the phone has a screen lock, and restores them when the app is installed again ([Android: Auto Backup](https://developer.android.com/identity/data/autobackup)). **Owner decision (2026-11-10): backup becomes the user's choice, off by default.** Phase 3 W1 builds the switch ([PHASE_3_PLAN.md](phases/PHASE_3_PLAN.md)); until then, Android's default applies. Backup/export as an explicit user action: Phase 10 |
| Logs | bounded ring buffer; redaction at logger (tokens, key paths, env values matching secret patterns); export requires user action |
| Temp files | app-private tmp; cleaned on session end + startup sweep. A save's temp file (`.<name>.cf-tmp`, W4) sits beside its target and is deleted when the save fails; one left by a crash is hidden from listings and replaced by the next save of that file |
| Workspace files (Phase 2) | one app-private folder, `<filesDir>/workspaces/demo` (W4). Every path is checked as text (relative, no `.` or `..`, no control or reserved characters), then on disk: the deepest existing ancestor, symbolic links resolved, must lie inside the canonical root, so neither `..` nor a link can reach outside it. Writes are atomic (temp file, flush, rename): an interrupted save leaves the old file. Files that are not UTF-8 text are refused, so they are never rewritten. **Known limit:** a save replaces the file, so the old file's permission bits are not kept (a new app file's are). Nothing depends on them in the app-private folder; Phase 3 (SAF folders) and Phase 4 (running user code, where an executable script must stay executable) must preserve the mode |
| Network | core features fully offline; network used only for: git remotes (user-initiated), pack delivery (Play), extension install (Phase 8, user-initiated), docs links. No telemetry, no analytics |

## 5. Extension security model (Phase 8 preview)

Manifest-declared permissions (`workspace.read`, `workspace.write`, `terminal.spawn`, `network`, `theme`, `snippets`); install-time grant dialog; extensions run in a scoped JS interpreter (QuickJS evaluated in Phase 8) with **only** bridged APIs, no raw filesystem/process access; themes/snippets are declarative (no code). Failure isolation: extension crash ≠ IDE crash. Full spec: EXTENSION_API.md (written in Phase 8).

## 6. Supply chain

- Bootstrap + `.deb` pins with SHA-256 (t1 pattern); payload manifest verified while writing; build scripts unit-tested.
- Dependencies: lockfiles committed; license screening at intake; CI `npm ci`/locked pub; no install scripts from unreviewed packages (`npm ci --ignore-scripts` where feasible).
- Release signing: keystore outside repo (env/`keystore.properties` git-ignored), fails closed; Play App Signing for the Play track; GitHub artifacts signed with the same upload key, hashes published in release notes.
- CI secrets: least-privilege `GITHUB_TOKEN` (contents:read default; write only where a job publishes); no secrets in PR runs from forks.

## 7. Vulnerability handling

Security issues: private report via GitHub security advisories (enabled Phase 1). Severity triage ≤ 72 h; patch releases out-of-band; CHANGELOG notes without exploit detail until users can update.
