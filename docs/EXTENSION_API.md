# Extension API

**Status:** Phase 0 design seed · Implementation Phase 8 · Full API spec + interpreter decision finalized at Phase 8 start

---

## 1. Model

Extensions are **declarative-first, code-second**:

- **Tier 0 (no code):** themes, file-icon sets, snippets, language definitions (grammar + comment/bracket rules), keymap presets. Pure JSON manifests + assets. Cannot misbehave beyond looking wrong.
- **Tier 1 (scoped code):** commands, workspace tools, editor decorations, custom views. JavaScript executed in a **scoped interpreter** (QuickJS candidate; evaluated in Phase 8) with only the bridged API surface — no `dart:io`, no raw FS, no process spawn, no network unless granted.

**Not a goal for v1:** VS Code Marketplace binary compatibility (spec §6.8). A compatibility *layer* (manifest subset mapping) grows later.

## 2. Manifest (v1 sketch)

```json
{
  "id": "forge.python-snippets",
  "version": "1.0.0",
  "api": "1",
  "displayName": "Python Snippets",
  "engines": { "codeforge": ">=0.8" },
  "contributes": {
    "themes": [], "snippets": [{"language": "python", "path": "snippets.json"}],
    "commands": [{"id": "py.runFile", "title": "Run Python File"}],
    "languages": [], "fileIcons": [], "views": []
  },
  "permissions": ["workspace.read", "terminal.spawn"],
  "activationEvents": ["onLanguage:python", "onCommand:py.runFile"]
}
```

Validation: JSON schema at install; unknown fields rejected; `api` version negotiated; permissions listed in an install-time grant dialog; grants stored per-extension, revocable in Settings.

## 3. Runtime & isolation (honest)

Interpreter runs **in-process** (same UID — not an OS sandbox; SECURITY.md §1 says so). Isolation = API surface + permission checks + resource quotas (memory cap, instruction budget, timeout per call) + crash containment (interpreter failure disables the extension, never the IDE). Tier 1 API: `workspace.{readFile,list,onChange}`, `editor.{decorate,insert,selection}`, `terminal.{spawn,write}` (gated), `ui.{notify,quickPick,statusBar}`, `commands.{register,execute}`, `storage.{get,set}` (extension-scoped KV).

## 4. Lifecycle

Install (local `.cfext` zip or curated index download — user-initiated) → validate → grant → activate lazily on events → deactivate on disable/uninstall (state kept) → uninstall removes files + grants. Updates are explicit; no silent code updates. Extension failures surface in an Extensions panel with logs and a disable button.

## 5. Distribution & trust

v1: sideload + a curated index hosted in this repo (PR-reviewed, hashes pinned). No arbitrary remote code execution at install. Signing/provenance requirements decided in Phase 8 with the license decision (ADR-0011) in view.
