# AGENTS.md — Development Rules for AI Agents on CodeForge

These rules bind every agent session on this repository. They encode spec §12 and the lessons of the Phase 0 audit. Violating them invalidates the work.

## 1. Workflow (every phase, every feature)

Analyze → Plan → Implement → Test → Verify → Document → Report.
- **Analyze:** read the current code + relevant docs before proposing changes.
- **Plan:** state the work, dependencies, and acceptance evidence before coding.
- **Implement:** production-quality, compilable code. No placeholder implementations inside features marked complete; no important functionality left as TODO.
- **Test/Verify:** run the relevant suites; fix failures; never proceed on red.
- **Document:** update the matching doc + ADR in the same change.
- **Report:** completed functionality, files touched, dependencies added, **tests executed with CI run ids**, build results, limitations, remaining tasks.

## 2. Honesty rules (hard constraints)

1. **Never claim a build succeeded or a test passed without a run id** (GitHub Actions is the build authority; the sandbox cannot build Android).
2. Never invent APIs, library capabilities, versions, or runtime behavior — verify against source/registry/CI.
3. Placeholders must be visibly honest (labeled, inert, explained). A button that doesn't work says why.
4. Limitations are documented where users will meet them, not buried.
5. Security claims match reality: child processes share the app UID; we never call that "sandboxed" (docs/SECURITY.md).

## 3. Phase discipline

- Work only the current phase (docs/ROADMAP.md). Do not start phase N+1 while N has unresolved critical issues.
- Phase exit = all acceptance gates green with cited evidence + `docs/phases/PHASE_N_REPORT.md` + owner acceptance.
- Scope creep goes to the roadmap backlog, not into the current PR.

## 4. Runtime reuse rules (the audited asset)

- The foundation is `m-cyber12/t1` @ `0e26d7a` (PR #81's branch, merged on 2026-11-11 as PR #229; main `7b496c3` has the same tree, and main `d9789a2` adds only its Apache-2.0 LICENSE: CodeForge vendors from `d9789a2`, recorded in native/PROVENANCE.md). Read docs/EXISTING_RUNTIME_AUDIT.md and docs/RUNTIME_INTEGRATION.md before touching anything runtime-related.
- **Do not rebuild what exists.** Do not add a second runtime, a proot distro, or linker hacks.
- The four sealed invariants are inviolable: symlinks-into-nativeLibraryDir (never copies); verify-while-writing; version-resolved deps + DT_NEEDED sonames; explicit interpreter env (PYTHONHOME etc.).
- Vendoring (Phase 4+) requires `native/PROVENANCE.md` (repo, commit, per-module license) and the upstream JVM tests passing unchanged. A vendored file is never edited in place: `runtime/provenance.py check` fails CI on any change but the recorded one, so a fix goes to t1 first and is re-vendored. The runtime's inputs are pinned (`runtime/pins.json`); re-pinning is a deliberate `[repin]` commit.
- No executable code may be downloaded at runtime. Ever. (ADR-0005.)
- CodeForge is Apache-2.0 (ADR-0011, Accepted 2026-11-12), and so is t1's code it vendors (t1's LICENSE first). No GPL-derived code is linked into the app: Termux's `terminal-emulator` (with `termux.c`), `terminal-view` and t1's `HarnessSession` are never vendored; Phase 5 writes the PTY clean-room, or reuses `termux.c` only if a legal review verifies its Apache-2.0 jackpal lineage. The terminal is xterm.js (ADR-0006). GPL userland binaries ship only as an aggregate, with their licence texts and a source offer published before any binary release (ADR-0010).

## 5. Architecture boundaries

- Widgets contain no business logic; controllers depend on service interfaces; Pigeon types live only in `services/*/native`; domain is pure Dart.
- One state system (Riverpod), one router (GoRouter). No mixing.
- Every bridge message: versioned envelope, schema-validated, workspace-scoped paths, typed failures.
- New dependency = justification paragraph (Android/ARM64, license, maintenance, offline, size) + exact pin + lockfile.

## 6. Evidence & CI

- PRs run `ci.yml`; heavy gates at phase boundaries/nightly. A green claim without artifacts is a process violation.
- Perf numbers come from the benchmark suite, recorded in phase reports; regressions > 15% are tracked issues.
- Use workflow artifacts for evidence — do not create diagnostics branches.

## 7. Git & collaboration

- Work on the session's `arena/*` branch only; never touch `main` or other branches; PRs from the session branch.
- Commits: imperative, scoped (`phase1: add adaptive workbench shell`); one logical change per commit.
- Never commit secrets, keystores, generated payloads (runtime archives and the like), build outputs, or large binaries. Generated Dart source is the exception. CI's `[bootstrap]` mode writes Drift's code, schema dumps and test helpers and commits them, and every run checks they are current (ADR-0008, BUILD_AND_RELEASE.md). Never edit them by hand: change the source and push with `[bootstrap]`.
- Owner decisions (license, minSdk changes, distribution keys) are asked, never assumed.

## 8. Documentation map (keep synchronized)

PROJECT_OVERVIEW · ARCHITECTURE · TECH_STACK · REPOSITORY_STRUCTURE · EXISTING_RUNTIME_AUDIT · RUNTIME_INTEGRATION · EDITOR_ARCHITECTURE · TERMINAL_ARCHITECTURE · LSP_ARCHITECTURE · EXTENSION_API · SECURITY · UI_DESIGN_SYSTEM · PERFORMANCE · TESTING · BUILD_AND_RELEASE · ROADMAP · CHANGELOG · adr/ · phases/.

When architecture changes: update the doc, write/amend an ADR, provide migration notes for stored data (backward compatibility is mandatory).
