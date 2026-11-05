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

- Assets only via `WebViewAssetLoader` (`https://appassets.androidplatform.net/`); bundle SHA-256 recorded at build, verified at load.
- CSP: `default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'none'`.
- `setAllowFileAccess(false)`, `setAllowContentAccess(false)`, `setDomStorageEnabled(true)` (editor state only), no mixed content, no third-party cookies, JavaScript enabled only for our bundles.
- **One bridge object, one method** (`postMessage(String)`); JSON envelope schema-validated (type allowlist, version check, size cap 1 MB, rate limit); every path argument canonicalized and confined to workspace roots; every failure typed + logged; no reflection, no generic "eval" or "exec" message types.
- Navigation blocked except the asset origin; `shouldOverrideUrlLoading` denies everything else; downloads disabled.

## 4. Data protection

| Data | Control |
|---|---|
| Git tokens / SSH keys (Ph. 7) | Android Keystore-backed encryption (AES-GCM, key never leaves Keystore); encrypted blobs in app-private storage; never logged, never in child env by default; SSH via openssh with key files chmod 600 in runtime home, passphrase prompt UI |
| Settings/workspace DB | app-private; no cloud sync by default; backup/export is explicit user action (Phase 10) |
| Logs | bounded ring buffer; redaction at logger (tokens, key paths, env values matching secret patterns); export requires user action |
| Temp files | app-private tmp; cleaned on session end + startup sweep |
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
