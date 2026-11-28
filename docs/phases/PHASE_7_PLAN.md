# Phase 7 Plan — Git & Source Control

**Status:** **In progress.** Proposed on 2026-11-23, the day Phase 6 was accepted, and started the same day on the owner's "green start next phase" (CI 45236523396 on the plan). **W1 done on 2026-11-23** (phase gate 45250655049: `GitTest` 7 of 7 on API 26 to 36 and on Test Lab's Pixel 8a, after the first gate had found git's paths broken in the runtime and the fix had gone in; see *As built (W1)* and [ADR-0016](../adr/0016-git.md)). **The owner accepted W1 and decided §10's items 2 to 4 on 2026-11-23:** (a) Git in projects, folders through *Import as project*; (b) HTTPS tokens and SSH keys; (a) the Git budgets as proposed. **W2 done on 2026-11-25** (phase gate 45626687240: `GitHostTest` 6 of 6 through the host on API 26 to 36 and on Test Lab's Pixel 8a; see *As built (W2)*). **W3 done on 2026-11-25** (phase gate 45682652174: `GitRemoteTest` a to d — the Keystore's store, clone, push, fetch and pull with the credential helper, a refused token erased, a stopped clone, and an SSH key made with a passphrase only the store holds — on API 26 to 36 and on Test Lab's Pixel 8a; see *As built (W3)*). **W4 done on 2026-11-26** (CI 45814316019 on the code and phase gate 45828081837 as its regression run, after 45817035219 had found a race in Phase 6's `lsp` test: the Source control panel, the explorer's colours and the import's pack files, with 35 new Dart tests, 6 of them goldens; G4's run in the real app waits for the gate's `git` group in W6; see *As built (W4)*). **W5 done on 2026-11-27** (CI 46054276473 on the code and phase gate 46057427130 as its regression run, every emulator group and every runtime leg on API 26 to 36 on the first try: `@codemirror/merge` in the page, the protocol's `diff.open` and `diff.close` with fixtures both sides run, the working tree against the index or the last commit, a commit's file against its parent, and the bundle at 319.6 KiB gzipped of its 1.5 MiB; G5's run in the real app waits for the gate's `git` group in W6; see *As built (W5)*). **W6's code is green on 2026-11-28** (CI 46111411540: the gate's `git` group, the phone's budgets file and the page's revert command, with 478 vitest tests and the Dart suites unchanged at 1,441); its own evidence is the phase gate's run of the new `git` group and a `[testlab]` run of `phone_git_test.dart` on the Pixel 8a, which this commit starts — G6 is judged on those, and the ids are written into *As built (W6)* when they land. **W7 after them** · **Spec reference:** §8 Phase 7 (Git and source control), §7 (security), §9 (performance: measure, never assume) · **Architecture:** [ARCHITECTURE.md](../ARCHITECTURE.md) §4 (the credential store), [RUNTIME_INTEGRATION.md](../RUNTIME_INTEGRATION.md) (Git on folders from shared storage), [SECURITY.md](../SECURITY.md) §1, §2 and §4, [EDITOR_ARCHITECTURE.md](../EDITOR_ARCHITECTURE.md), [ADR-0004](../adr/0004-editor-engine.md) (CodeMirror 6), [ADR-0005](../adr/0005-sealed-runtime.md), [ADR-0012](../adr/0012-backup-opt-in.md) (backup), [ADR-0013](../adr/0013-folders-and-the-runtime.md) (a folder runs in a copy) · **Builds on:** Phase 6 ([report](PHASE_6_REPORT.md)), and the sealed runtime's Git since Phase 4

---

## 0. Carried in from Phase 6 and the owner

**From Phase 6** (PHASE_6_REPORT §9.2, §10):
- **What a process can be today.** The launcher (`libcodeforge-spawn.so`) runs:
  - one-shot commands: stdin closed, output read up to a cap of 1 KiB to 1 MiB, a deadline of 100 ms to 10 min (SECURITY §2.1);
  - the same with stdout streamed line by line, which search uses;
  - terminal sessions on a pseudo-terminal (ADR-0014);
  - since Phase 6, long-lived processes on pipes with stdin open, the language servers (SECURITY §2.3).

  Each leads its own session and process group, is ended with its whole tree, and runs under the limits SECURITY §2.2 measured. A Git operation is a one-shot command, but a clone or a push runs for minutes, reports progress on stderr, may ask for a credential, and must be stoppable. A status of a large repository can write more than 1 MiB.
- **The Git service is a fake.** `GitService` in `services/contracts.dart` has one method, `summary()`, answered by `FakeGitService` with the branch `main`; its comment still says "Phase 6 provides the real impl". The workbench's *Source control* panel is an honest placeholder that says "Arrives in Phase 7" (`panels/placeholder_panels.dart`).
- **The editor protocol v1** takes new types with fixtures both sides run, as Phase 6's nine did (EDITOR_ARCHITECTURE §2). PERFORMANCE allows two WebViews, the editor's and the terminal's, so a diff view belongs in the editor's page.
- **Memory.** On Test Lab's Pixel 8a the app with the editor and its renderer held 511.4 MB of PSS, and 927.7 MB with both language servers (phase gate 45182761593). With a terminal open beside them, Phase 6's exit gate measured 917.0 MB, and 682.2 or 747.3 MB with one server (exit gate 45225412011; PHASE_6_REPORT §7.1). Git's processes are short-lived; their memory is recorded, never budgeted.
- **Size:** the base module is 158.5 MB per device, 79.2 % of Play's 200 MB. Phase 7 adds no runtime package (*Verified*, below).
- **Pending with the owner, non-blocking:**
  - the phone sessions: PHASE_6_PHONE_CHECKLIST, and the Phase 3, 4 and 5 checklists, on Phase 6's exit gate APK (kept until 2026-12-23);
  - the first release: the keys, and the licence review;
  - Play's account, testers, forms and special-use declaration, and its rule on downloaded executable code;
  - what runs the arm64 tests after Test Lab.

**The owner's standing rules:**
- **Test Lab:** a change goes through plain CI first. Only then does a separate commit with `[testlab]` in its subject run it on the phone. The free plan gives 5 physical-device tests a day, and Firebase counts the day from midnight Pacific time (09:00 in Frankfurt in winter).
- **No nightly CI** (2026-11-11): the emulator suite and the runtime gates run in the phase gate, once per work package.
- **CI and the phase gate are one workflow;** a `[phase-gate]` push gives one run.
- **t1's code may be changed,** as recorded patches in `native/patches/`.
- **No public binary before the licence review** (2026-11-18).

**Verified while planning (2026-11-23),** from the repository and the npm registry:
- **The runtime already carries Git's network.** `runtime/pins.json` asks for `git` and `openssh` among its 13 packages, and resolves 50 per ABI:
  - git 2.56.1, which depends on libcurl, libexpat, libiconv, less, openssl, pcre2 and zlib;
  - libcurl and curl 8.23.0, with nghttp2 1.71.0, nghttp3 1.19.0 and ngtcp2 1.26.0;
  - ca-certificates 2026.11.05;
  - openssh and openssh-sftp-server 10.6p2, libssh2 1.11.1 and krb5 1.22.3.

  `RuntimeCommandsTest` checks git's version against its pin on API 26 to 36 and the Pixel 8a at every phase gate. **No test has used Git over a network yet:** no clone, fetch or push, and no HTTPS through libcurl. The launcher's environment names the payload's certificates (`SSL_CERT_FILE`, `SSL_CERT_DIR`; `RuntimeEnvironment.kt`), and W1 proves that git's libcurl uses them.
- **Folders and `.git`** (ADR-0013):
  - a run's copy of a folder leaves `.git` out (`FolderCopy.RUN_SKIPPED`), as search does;
  - *Import as project* copies everything, `.git` included (`StorageBroker.importTree`, nothing skipped), within 100,000 files and 4 GiB, **and 64 MB a file**: a pack file larger than that is left out today, which would leave the imported repository broken.
- **What was planned for credentials,** since Phase 0:
  - ARCHITECTURE §4: Git tokens and SSH keys in an Android Keystore-backed encrypted store, in Phase 7, never in plain preferences, never logged;
  - SECURITY §2: credentials supplied per invocation through askpass or a credential helper, never in files on the PATH or in a child's environment by default;
  - SECURITY §4: AES-GCM with a key that never leaves the Keystore, the encrypted blobs in app-private storage; SSH through openssh, key files with mode 600 in the runtime's home, and a passphrase prompt.
- **What was decided against:** JGit as the primary Git (TECH_STACK): the spec prefers the existing binary, and JGit adds JVM weight and behaviour that differs from Git's.
- **In the page:** `@codemirror/merge` 6.12.3 (MIT, published 2026-10-19) draws a document against an older version, in one column or two, with controls that revert a change. Its dependencies (`@codemirror/view`, `state` and `language`, `@lezer/highlight` and `style-mod`) are all in the page already.

## 1. Objectives

1. **Git that a professional uses every day, on the phone** (ROADMAP): init, status, stage, commit, diff and branches on the sealed Git; clone, pull and push with credentials kept in the Keystore.
2. **Proven before anything is built on it.** Git's local and network operations pass a suite on every target, API 26 to 36 and an arm64 phone, before the app relies on them.
3. **Never a frozen app** (ROADMAP: "big-repo no-freeze"). Git runs in its own processes; nothing waits on it on the UI thread; a large repository's status streams; every long operation shows progress and can be stopped. Measured in W1, budgeted with the owner (§10, item 4), judged on the phone in W6.
4. **Credentials that never leak.** A token or key is never in a log, an argument, an environment variable, a file the runtime can read in plain text, or the app's backup. It is given to Git per operation, for the host that asked.
5. **Folders from shared storage decided** (ROADMAP's gate): what Git does with them, chosen by the owner with W1's numbers (§10, item 2).

## 2. MVP 7 definition (ROADMAP)

ROADMAP's row:
- init, status, stage, commit, diff and branch on the sealed Git;
- clone, pull and push with credentials in the Keystore;
- a large repository without a freeze;
- the strategy for folders from shared storage decided.

**In scope:**
- the spike on every target;
- the Git host and the real `GitService`;
- remotes and credentials;
- the *Source control* panel: changes, staging, commit, branches, history, remotes, conflicts after a pull;
- diffs in the editor;
- the Git gate on real targets.

**Out of scope:**
- staging part of a file (a hunk or a line); interactive rebase; stash, tags, submodules, blame and a history graph in the UI (the terminal's git does them all);
- Git LFS and commit signing (neither git-lfs nor gnupg is in the runtime);
- a host's own features: pull requests, issues, reviews;
- extensions (Phase 8) and debugging (Phase 9).

## 3. Technical implementation (work packages)

### W1 — The Git spike on every target (1 session) 🔑 first → G1

Every later package builds on its answers: HTTPS through libcurl, a credential helper under the launcher, and a large repository's times.

- **`GitTest`,** an instrumented test on every runtime leg (API 26, 27, 28, 34 and 36) and on Test Lab's Pixel 8a, through the launcher's command mode, as Run runs a program. No new code path in the app.
- **Local work,** on a repository the test makes:
  1. `init`, `add` and `commit`, with the identity given on the command line;
  2. `status --porcelain=v2 -z --branch` before and after each step, compared byte for byte with what is expected;
  3. `diff`, `log`, `branch`, `switch` and a fast-forward `merge`;
  4. a merge with a conflict: the conflicted file listed as unmerged, then resolved and committed.
- **A remote with a password, on the device itself.** A small server in the runtime's Python drives `git http-backend` over HTTP on 127.0.0.1, with Basic authentication:
  - clone, fetch and push through it;
  - the credential handed to Git by a **credential helper** (Git's own protocol: `get`, `store`, `erase`), which the test answers. Nothing in an argument, the environment or a file. A wrong password is refused, and Git asks no terminal;
  - W1 picks the helper's transport with these measurements: a script in the runtime's bash talking over two FIFOs the host creates for that operation, or a small native helper next to the launcher.
- **HTTPS to a real host:** `git ls-remote` of a public repository on github.com proves TLS, the payload's certificates and DNS from the runtime. Recorded, not judged, since a network can fail. If libcurl looks for its certificates under Termux's own prefix, CodeForge passes `http.sslCAInfo` on every command.
- **SSH, as a probe** for §10, item 3, recorded:
  - `ssh-keygen` makes an ed25519 key with a passphrase, and reads it back with that passphrase;
  - GitHub's handshake: refused at the key, as an unknown key must be, with GitHub's published host key;
  - the runtime's `sshd` serves a repository on 127.0.0.1, and `git clone` fetches it over SSH with a key it authorises. That key has no passphrase: handing one over through `SSH_ASKPASS` needs the environment of the command, which W3's host gives.
- **A large repository,** generated:
  - 10,000 files in 500 folders, as a new project is made: written, its untracked status, `add -A` and `commit`;
  - 50,000 files in 2,500 folders, as a clone leaves one: a single pack (`fast-import`), then checked out;
  - for each, `status` once after the commit or checkout and 20 times more (the median, the 95th percentile and the slowest), the same with `--no-optional-locks`, which leaves the index alone, so the app's reads never block the terminal's git, then 100 files changed: their status, `add`, `commit`, `log -n 100` and `diff --stat`.
- **The outcome:**
  - ADR-0016 (Git) records the choices with these numbers: the sealed CLI through a host; the helper's transport; HTTPS settings.
  - W1's report brings the owner the numbers for §10's items 2, 3 and 4, with a recommendation for each.

**As built (W1):**
- **G1 met** (CI 45242102178 on the test, and 45248146169 on the fix below; phase gate 45250655049, whole: `GitTest` 7 of 7 on every runtime leg, API 26, 27, 28, 34 and 36, and on Test Lab's Pixel 8a with Android 14, 49 of 49 tests there in the same run; every emulator group at its first attempt, the cold start at 1,365 ms, no ANR or crash of CodeForge's (3 of the system's at boot); evidence `02a0eab8`, `e5c38722` and `c1c0cb4d`). ADR-0016 records the choices with the numbers.
- **Found and fixed: git could do nothing beyond its builtins in the runtime.** The first gate, 45244989137, failed on all five legs:
  - `git init` and `git clone` stopped at "cannot stat template '/data/data/com.termux/files/usr/share/git-core/templates/description'";
  - HTTPS failed within 13 to 65 ms with "remote helper 'https' aborted session", with or without `http.sslCAInfo`.

  Git's compiled-in paths are Termux's official prefix. The preload translates what git executes, opens and lists there, but not what it stats, and git finds its templates and helper programs by `stat`. `RuntimeEnvironment` now names both in the prefix for every command and terminal (`GIT_EXEC_PATH`, `GIT_TEMPLATE_DIR`; fc9df410), so **the terminal's `git init`, `git clone` and HTTPS remotes work too**: they had failed since Phase 4, unnoticed. That gate was cancelled before its Test Lab job submitted, so it spent no Test Lab run.
- **Measured** (gate 45250655049; ADR-0016's table has every figure):
  - **Local work:** `status --porcelain=v2 -z` byte for byte after each step, the diff, the log, branches and a fast-forward merge; a conflict listed with its three stages, resolved with two parents. `status` of the small repository took 45 ms at p50 on the phone, 8 to 17 ms on the emulators: the cost of starting git.
  - **A remote with a password, on the device:** clone, push and pull through `git http-backend` took 421, 405 and 338 ms on the phone, the password reaching git only through the credential helper. A wrong one was refused and erased, no answer failed in 190 ms without a prompt, and the password was in no file of the runtime's home.
  - **HTTPS to github.com** works with the payload's certificates as they are: a shallow clone in 408 ms on the phone.
  - **SSH as a client:** a key with a passphrase made and read back, and GitHub's handshake refused at the unknown key, with GitHub's published Ed25519 host key, on every target.
  - **10,000 files** as a new project, on the phone: untracked status 56 ms (160,000 bytes), `add -A` 1,166 ms, `commit` 160 ms; then `status` 85 ms at p50 and 134 ms at p95.
  - **50,000 files** as a clone leaves them: checked out in 3,586 ms; `status` 183 ms at p50 and 262 ms at p95, and 187 and 579 ms without the index's optional lock.
- **Differs from the plan:**
  - **The helper's transport:** only the bash script over two FIFOs was built, and it worked on every target, so no native helper is needed.
  - **No clone over SSH:** the runtime's `sshd`, a test fixture, refused the app's user as invalid before authentication. GitHub's handshake proves the client; W3 or the owner's phone proves an authenticated clone, if SSH is decided.
  - **HTTPS** needed no `http.sslCAInfo`.
- **Tests:** `GitTest` (7) on the legs and Test Lab; `RuntimeEnvironmentTest` 1 more; `RuntimeCommandsTest` b checks git's two folders on every target (`commands_git_exec_path`, `commands_git_template_dir`).

### W2 — The Git host and the real service (2 sessions) → G2

- **The host** (Kotlin, `git/GitHost.kt`):
  - runs `git` through the launcher, in a project's folder named by the project, never by a path from Dart;
  - takes an operation from a fixed set (`status`, `add`, `restore`, `commit`, `log`, `show`, `diff`, `branch`, `switch`, `merge`, `init`, and W3's remotes) with its arguments. It refuses any option that runs a program or moves Git elsewhere (`-c`, `--config-env`, `--exec-path`, `--git-dir`, `--work-tree`, `--upload-pack` and clone's `-u`, `--receive-pack`, `--exec`, `--template`). Paths come after `--`, relative, inside the project;
  - adds the same settings to every command, which a repository's own configuration cannot change for that command: no fsmonitor, no `ext::` transport, no pager, no colour, paths unquoted, CodeForge's credential helper only (W3), housekeeping in the foreground (`gc.autoDetach=false`), since the launcher ends whatever a command leaves running, `GIT_TERMINAL_PROMPT=0`, no system configuration;
  - streams stdout, NUL-separated, up to 64 MiB, and parses stderr's progress lines;
  - runs one command that writes at a time per repository, reads alongside; a read uses `--no-optional-locks`;
  - logs an operation's kind, its time and its exit, never its arguments, a path or a URL.
- **The Pigeon API** (`pigeons/git_api.dart`): `GitApi` (run, stop) and `GitEvents` (output, progress, exited).
- **The service** (Dart): `GitService` grows into the real one, with an honest fake for tests:
  - status, stage and unstage, discard, commit (with amend), log, a commit's files, a file's text at a revision, branches (list, create, switch, delete), merge, init;
  - `core/git/`: the parsers of porcelain v2, of `log` and `for-each-ref` with NUL-separated formats, and of progress, each with fixtures from W1's real output, and fuzzed;
  - typed failures: not a repository, a lock held by another git, changes that a switch would overwrite, nothing to commit, no identity, a conflict.
- **The controller** (`application/git/git_controller.dart`): the open project's repository state, refreshed after each operation, after saves, on the watcher's changes and on resume. Debounced, one status at a time, the newest wins.
- **The identity:** Settings → Source control, a name and an email, written to the runtime home's `.gitconfig`, so the terminal's git commits as the same person.
- **The status strip's branch chip,** from the real summary.

**As built (W2):**
- **G2 met** (CI 45283948595 on the code, and 45623732053 on a test's fix below; phase gate 45626687240: `GitHostTest` 6 of 6 through the host and W1's `GitTest` 7 of 7 on every runtime leg, API 26, 27, 28, 34 and 36, and on Test Lab's Pixel 8a with Android 14, 55 of 55 tests there in the same run; every emulator group passed, the cold start at 1,300 ms; evidence `4d6a9618`, `d615d880` and `0b49e4dc`). [GIT_ARCHITECTURE.md](../GIT_ARCHITECTURE.md), begun here, describes the host and the service as built.
- **The host** (Kotlin, `git/`):
  - `GitCommands` lists 19 operations and the options each takes; anything else that starts with `-` is refused, so every option the plan names is refused by not being listed. Paths come after `--`, relative, inside the project and never in `.git`; revisions never read as options. A refusal names an option only when it looks like one, never a value Dart sent.
  - Every command: `--no-pager --literal-pathspecs`, `--no-optional-locks` for a read, and twelve fixed settings: the plan's, plus `user.useConfigOnly=true` (never an identity git guesses), `maintenance.autoDetach=false`, and no signature checks or signing, which would run gpg. The variables: `GIT_TERMINAL_PROMPT=0`, `GIT_CONFIG_NOSYSTEM=1`, `GIT_EDITOR=:`, `GIT_PAGER=cat`, and `GIT_CEILING_DIRECTORIES` at the projects' folder.
  - `GitRunner`: a project named by its folder and resolved in `<filesDir>/workspaces`, links resolved (E3); stdout cut into records at NUL, at newlines or whole (up to 4 MiB), in batches of 2,000 records or 256 KiB; a run's record cap and the host's 64 MiB, ending it *truncated*; one change at a time per repository, a second refused as `busy`, reads alongside; at most 8 runs; Stop ends the whole tree; progress from stderr, at most one redrawn line per 100 ms. Logs name an operation, its run, its exit and its time, never an argument, a path or a URL.
  - `CommandRunner` (Phase 4) gained a command's own variables from a Kotlin host, which may only add to the runtime's environment; NUL and whole-output separators; and stderr's progress, kept apart from its text.
- **The Pigeon API** (`pigeons/git_api.dart`): `GitApi` (run, stop) and `GitEvents` (output, progress, exited), as planned.
- **The service** (Dart, `services/git/`, `core/git/`): `HostGitService` over `PigeonGitHost`, each call one of the host's commands; the parsers of porcelain v2, `log`, `for-each-ref`, `diff-tree` and progress, checked against 13 fixtures of git's real output and fuzzed; `GitFailure` with a `GitProblem` read from the host's codes and git's words; an honest fake that says Git is unavailable.
- **The controller** (`application/git/git_controller.dart`): the open project's state (`unavailable`, `folder`, `waiting`, `loading`, `notARepository`, `repository`, `failed`), its status read again after each operation, after a save, on the watcher's batches, on a change in `.git` and on resume; 300 ms of gathering, one status at a time, the newest winning; changes queued.
- **The identity:** Settings → Source control, in the runtime home's `~/.gitconfig`. **The branch chip:** the branch, `*` with changes, the warning colour on conflicts, its words for TalkBack.
- **Found by the first gate** (45620932879, on API 36 alone): `GitHostTest` e expected a capped status to end with no exit code, but on a fast target git wrote all 300 records into the pipe and exited 0 before the runner's end reached it. The run is truncated to its first 100 records either way, which Dart's `GitOutcome.ok` already allowed; the test now accepts both and records which. In the second gate git finished first on API 34 and the phone, and on API 36 in one of its two attempts (`cap=git_done_first`). The first gate was cancelled before Test Lab ran. **The second gate's first attempt** failed twice outside Git, and its failed jobs passed when run again: on API 36, Phase 5's `SessionServiceTest` b found the notification's title one update behind (`GitHostTest` passed there); in the emulator gate the `keys` group, the first after boot, timed out waiting for the editor to take the keyboard while three of Google Play services' processes were not responding.
- **Measured through the host** (gate 45626687240):

  | `GitHostTest` | Emulators, API 26 to 36 | Pixel 8a |
  |---|---|---|
  | 10,000 new files: their status (140,000 characters, 5 batches) | 21–300 ms | 116 ms |
  | `add -A`, `commit` of them | 304–865, 426–973 ms | 1,032, 1,326 ms |
  | The clean status of 10,000 files, p50 / p95 of 20 | 17–42 / 18–46 ms | 87 / 114 ms |
  | A merge with a conflict | 13–43 ms | 81 ms |

  Through the host the phone's p95 of 114 ms is W1's 134 ms through the launcher alone: the host adds no cost to measure. W6 judges the app's own 500 ms budget, with the parse and the panel.
- **Differs from the plan:**
  - **`GitHostTest`, not `GitTest` through the host.** W1's `GitTest` stays as it was, through the launcher, and a class of its own runs each operation of the fixed set through the host's runner with the runtime's git, on every target.
  - **More operations than the plan listed:** `rm --cached` (unstaging before the first commit, when `restore --staged` has no HEAD), `clean` (discarding a new file, the paths named), `cat-file` (a file's text at a revision), `diff-tree`, `for-each-ref`, `rev-parse`, `check-ref-format` and `config` (the identity's two keys only). `show` and `diff` give their whole output, up to 4 MiB.
  - **Settings beyond the plan's:** `user.useConfigOnly=true`, and `GIT_CEILING_DIRECTORIES`, so a `.git` the terminal makes above the projects' folder claims no project.
- **Tests:** JVM `GitCommandsTest` (11), `GitRunnerTest` (11, real processes with the machine's git) and 4 more in `CommandRunnerTest`; instrumented `GitHostTest` (6) on the legs and Test Lab; Dart `git_parsers_test` (19), `git_service_test` (21), `git_controller_test` (14), `git_chip_test` (5) and `source_control_settings_test` (3): 1,353 Dart tests in CI 45281823330, against 1,291 before.

### W3 — Remotes and credentials (2 sessions) → G3

- **The credential store** (Kotlin, `git/CredentialStore.kt`):
  - an AES-256-GCM key made in the Android Keystore, never exportable;
  - each credential encrypted with it, a fresh nonce each time, into app-private storage that backup leaves out (ADR-0012's rules);
  - an entry is a host, optionally a path, a user name and a secret; Settings → Source control → *Accounts* lists hosts and user names, never a secret, with *Remove*.
- **The credential helper:** Git's own protocol, on that command's line only. The host answers `get` from the store for exactly the host that asked. With nothing stored, it asks Dart, which shows a dialog: the host, a user name, a token, and *Remember*. A `store` after success keeps what the user typed when they chose *Remember*; an `erase` after a refusal removes the stored entry and says so.
- **Clone:** Home → *Clone repository*: a URL (HTTPS, or SSH if decided), and the new project's name. It clones into a hidden staging folder renamed into place on success, with progress and *Stop*. A URL with a password or a token in it is refused, with the reason; a user name alone, as SSH's `git@host` has, is kept.
- **Fetch, pull and push,** from the panel and the palette:
  - progress, and *Stop*, which ends the operation's whole tree;
  - pull merges by default; a conflict is W4's;
  - the first push of a branch sets its upstream;
  - typed failures: authentication, not found, offline, a rejected push (fetch first), a host's TLS refused.
- **SSH keys, decided on 2026-11-23** (§10, item 3, (b)):
  - an ed25519 key made with the runtime's `ssh-keygen`, encrypted by OpenSSH with a random passphrase that only the store holds;
  - the passphrase given per operation through `SSH_ASKPASS`;
  - `known_hosts` in the runtime's home, a new host's fingerprint shown once for the user to accept;
  - the public key shown, to copy into the host's settings.

**As built (W3):**
- **G3 met** (CI 45679760414 on the code; phase gate 45682652174: `GitRemoteTest` a to d on every runtime leg, API 26, 27, 28, 34 and 36, and on Test Lab's Pixel 8a, with W1's `GitTest` and W2's `GitHostTest` beside them). [GIT_ARCHITECTURE.md](../GIT_ARCHITECTURE.md) §2.4 describes the credentials as built, and [SECURITY.md](../SECURITY.md) §2.4 holds their threats and proofs.
- **The store** (`git/CredentialStore.kt`): one file in `no_backup/`, a line per entry — kind (`https` or `ssh_key`), host, user name, sealed secret, each Base64, and when it was written — sealed with AES-256-GCM under a Keystore key (`codeforge-git-credentials`, randomized encryption required, never exportable), a fresh nonce each time, bound to the entry's kind, host and user as GCM's associated data, so a sealed secret moved to another entry no longer opens. A line that will not open is dropped; at most 256 entries.
- **The helper and askpass** (`git/CredentialChannel.kt`, `git/CredentialBroker.kt`): each remote run gets a folder of its own with two FIFOs (mode 600) and a thread that answers. git's helper is named on that operation's own line after the settings' empty `credential.helper=`; ssh's `SSH_ASKPASS` is the runtime's **bash** with a relay as `BASH_ENV`, since Android forbids executing a file from app storage from API 29, and the relay answers only a question (an argument ending in `: ` or `? ` that is not a file), leaving a real script to run. `GIT_ASKPASS=""` and `GIT_TERMINAL_PROMPT=0` leave git no other way to ask. The broker answers `get` from the store for exactly that host (never over plain HTTP, unless the host is this device), `store` only what the user typed with *Remember* and only once the host accepted it, and `erase` only a stored secret still equal to the refused one. A prompt waits 5 minutes; a run that ends withdraws it.
- **Clone** runs in the projects' folder into a hidden `.clone-<runId>`, renamed to the project's name on exit 0, so Stop, a failure or the app's death leave no half-made project; the name is locked for the clone's life, and a taken one is refused as `exists`. **Fetch, pull and push** carry `--progress`; pull merges whatever `pull.rebase` says; push takes a branch to the same name, with `--set-upstream` the first time. Every remote command adds `protocol.allow=never` with https, ssh and http allowed, no submodule recursion, and `transfer.credentialsInUrl=die`.
- **SSH keys** (`git/SshKeys.kt`): one ed25519 key, `~/.ssh/codeforge_ed25519`, made by the runtime's `ssh-keygen -q -t ed25519 -a 16` with a 32-byte random passphrase only the store holds, given through askpass and never on a command line; read back the same way to prove it opens. git runs ssh with `IdentitiesOnly=yes`, that key, the runtime's `known_hosts`, `StrictHostKeyChecking=ask`, no password or keyboard-interactive authentication and a 30 s connect timeout.
- **The URLs** (`git/GitUrls.kt`, `core/git/git_urls.dart`, the same rules both sides, over `test/fixtures/git/urls.tsv`): HTTPS, SSH (`ssh://` or `user@host:path`), plain HTTP to this device only; a password or token in the URL refused with that reason, and a user name that is really a token refused as one; `git@host` kept.
- **In the app:** Home → *Clone repository*; the prompts above every screen (a token with *Remember*, or a new host's fingerprint); Settings → Source control's *Accounts* (a host and a user name, never a secret, each with *Remove*) and *SSH key* (made here, its public half to copy, with *Remove*); fetch, pull and push from the palette with progress and *Stop*. New problems read from git's words: authentication refused, no credential, no such repository, offline, a rejected push, TLS, a host key that changed, no upstream, a name already taken.
- **Found by CI, three runs running:** `GitRemoteRunnerTest`'s SSH key test timed out on the runner while passing on the machine here. **OpenSSH 10 renamed the question:** `ssh-keygen` now asks `Enter passphrase for "<file>" (empty for no passphrase): ` where 9 asked `Enter passphrase (empty for no passphrase): `, and the broker, matching 9's wording, answered only the confirmation; `ssh-keygen` asks that pair for ever until the two match, so the run ended at its 60 s limit. The runtime carries openssh 10.6p2, the machine here 9.2, which is why it passed here. The broker now reads every wording both versions use, takes the key a question names and answers only for CodeForge's own; the same change reads OpenSSH 10's `key fingerprint is: SHA256:…`, with its colon, which would otherwise have left a new host's question unanswered. **Two diagnostic steps went in to find it** and stay: `app/tool/ci/junit_failures.py` prints each failing JVM test's message, its first frames and its output tail into `ci-results/kotlin-tests.txt` and the run's warning, and `SshKeys` records what `ssh-keygen` was asked (a question, never an answer) in the refusal it throws.
- **Measured on every target** (gate 45682652174, `GitRemoteTest`), against `git http-backend` with Basic authentication on 127.0.0.1:

  | Measure | Emulators, API 26 to 36 | Pixel 8a |
  |---|---|---|
  | A secret sealed into the store, then found and opened | 15–208 / 1–7 ms | 112 / 8 ms |
  | A clone that asks the user, then one that takes the token from the store | 105–165, 99–158 ms | 282, 238 ms |
  | Push, fetch, pull | 99–182, 75–147, 62–130 ms | 415, 475, 303 ms |
  | A refused token: refused and the entry erased | 42–85 ms | 247 ms |
  | A clone stopped while the user is being asked | 43–84 ms | 161 ms |
  | An ed25519 key made with a passphrase through askpass | 121–202 ms | 432 ms |
  | The token found in any file of the home, the project or the store | 0 | 0 |

  GitHub over SSH is recorded, never judged: on every target its host key was asked about with the **published** ED25519 fingerprint, CodeForge's key offered, and the unknown key refused. Test Lab's Pixel 8a ran 59 of 59 tests, against 55 in W2.
- **The gate's own flake:** its first attempt failed in Phase 6's `lsp` group — after three kills the status chip offered *Restart* but the test read the chip before the frame that gives it its tap. Nothing of W3 was in it; `gh run rerun --failed` passed it (`lsp_itest attempt=1 exit=0`, `gate_result=pass`), and the chip's race is worth a look when the LSP tests are next touched.
- **Differs from the plan:** the plan said "the passphrase given per operation through `SSH_ASKPASS`"; as built, `SSH_ASKPASS` is the runtime's bash with a relay, because Android 29+ will not execute a script from app storage. The plan's "a path" in a store entry is not built: an entry is a kind, a host and a user name, which is what git's helper matches on.
- **Tests:** JVM `CredentialStoreTest` (7), `CredentialBrokerTest` (11), `GitUrlsTest` (4) and `GitRemoteRunnerTest` (7, with the machine's real git, python and `ssh-keygen` behind the compiled launcher and real FIFOs), with `GitCommandsTest` and `GitRunnerTest` grown; instrumented `GitRemoteTest` (4) on the legs and Test Lab; Dart `git_urls_test`, `git_remote_test` (the widget tests of the clone dialog, the prompts and the accounts), and additions to `git_parsers_test`, `git_service_test` and `git_controller_test`: **1,376 Dart tests** in CI 45679760414, against 1,353 in W2, and **284 Kotlin JVM tests**.

### W4 — The Source control panel (2 sessions) → G4

- **The panel** replaces the placeholder:
  - the branch, its upstream, and how far ahead and behind;
  - *Changes*: staged, unstaged, untracked and conflicted files, each with its state and colour. A tap opens its diff (W5); a long press opens the file;
  - stage and unstage, a file or all; discard a file's changes, after a confirmation that names it;
  - the commit box: the message, *Commit*, and *Amend the last commit*. It says why when it can't commit: nothing staged, or no identity;
  - branches: list, create from the current commit, switch (refused with the reason when changes would be lost), delete (a merged branch, or after a confirmation);
  - history: the last 100 commits of the branch, with author, date and message; a tap shows a commit's files and their diffs;
  - remotes: *Fetch*, *Pull* and *Push*, with progress;
  - after a pull with conflicts: the files listed, each opened with its markers, *Mark resolved*, and *Abort the merge*.
- **The status strip:** the branch chip opens the panel, and shows when the tree has changes.
- **The explorer:** files coloured by their state, a folder by its files'.
- **Folders from shared storage, decided on 2026-11-23** (§10, item 2, (a)): a folder that holds a repository says in the panel that Git works in projects, and offers *Import as project*, which copies `.git` with the rest, pack files over 64 MB included (§9).
- **Accessibility** (labels, tap targets, text at 1.3×) and goldens, as the other panels have.

**As built (W4):**
- **The app's half of G4 is met** (CI 45814316019 on the code; phase gate 45828081837 as the regression run for the chrome W4 touched: every emulator group, the five runtime legs on API 26 to 36, the runtime build and the supply chain). G4's own run in the real app is the emulator gate's `git` group, which W6 builds; what W4 can prove, it proves against the scripted service — 15 widget tests, 9 controller tests, 4 state tests and 6 goldens. [GIT_ARCHITECTURE.md](../GIT_ARCHITECTURE.md) §3.3 describes the panel as built, [UI_DESIGN_SYSTEM.md](../UI_DESIGN_SYSTEM.md) §5 how it looks.
- **The panel** (`features/workbench/panels/git_panel.dart`) is one widget, in the sidebar on a tablet and in the activity sheet on a phone. The header: the branch (a detached HEAD by its short commit), `origin/x · 2 ahead, 1 behind`, or *No commits yet* / *No upstream: Push sets one*, with *Fetch*, *Pull* and *Push* behind the progress sheet and *Stop* that Home's clone uses. Then three sections, each with its count beside the title: *Changes*, which the status already holds; *Branches* and *History*, read when they are first opened and again when the branch's commit changes. A change is a 48 dp row — the file, its folder, the letter of its state in that state's colour, and only the buttons that fit it: *Mark resolved*, *Unstage*, *Discard* or *Delete*, *Stage*. The commit box is the message, *Amend the last commit* and *Commit*; a `commitProblem` says in one sentence why it cannot run (nothing read yet, a merge in the way, nothing staged, no identity, no message) instead of letting git refuse.
- **A merge that stopped** puts its conflicts in the first group, with *Abort the merge* beside it; a file is opened with its markers and marked resolved when it is fixed, which is `stage` under a word that says what it means here.
- **Branches and history:** the local branches, the current one ticked and without a delete; a new branch is checked for a name git will take (`check-ref-format`) before anything runs; a switch that would lose changes says git's reason; a branch that is not merged is deleted only after a second question that says what is lost. The history is the branch's last 100 commits, each `shortHash · author · date`, and a tap opens a sheet of the files that commit changed.
- **The explorer and the chrome:** `gitFileStatesProvider` (`application/git/git_file_states.dart`) turns the status into one map — the worst state per path, a folder the worst under it, a rename at both ends — and `CfTreeRow` grew `stateColor`, `stateLetter` and `stateWord` for it (the word is what TalkBack says in the letter's place). The status strip's branch chip opens the panel, and the bar's chips now stretch to its height, so a chip that can be tapped is the whole cell (G7, UI_DESIGN_SYSTEM §8).
- **Where Git cannot work:** a project that is not a repository offers *Make it a repository* (`init`, `main` as the first branch); a folder from shared storage says Git works in projects and offers *Import as project*. **§10 (a) as built:** `CopyLimits.IMPORT` now allows 4 GiB per file, not 64 MiB, so a repository whose `.git` holds a big pack arrives whole; the import's other limits (100,000 files, 4 GiB in all) are unchanged, and a run's copy keeps the 64 MiB cap.
- **Differs from the plan:** a tap on a change opens the file, as the long press does, until W5 puts the diff there; the same for a file in a commit's sheet, where the plan says “their diffs”. The plan's "remotes: Fetch, Pull and Push with progress" are the panel's header rather than a section of their own.
- **Found by CI, the only checker for this code** (the authoring sandbox has no Flutter SDK, and GitHub Actions is the build authority — [AGENTS.md](../../AGENTS.md) §2): a pattern match used as the operand of a `?:` in a `return`, which is a parse error that stops the whole quality job before any gate runs (45751281740); `GitEntryKind.added` in a golden's fixture, where git's kinds are tracked, untracked, ignored and conflicted (45753083788); and the G7 sweep catching the branch chip at 110.6×15.0 once it could be tapped (45810921329), which the chips' new height answers.
- **The gate's own flake, and its fix:** the first run, 45817035219, failed in Phase 6's `lsp` group alone — at its folder step the test read what the editor page had underlined in the same frame as the app's own count of the diagnostics, and the page is told after the app knows (expected 1, found 0). Nothing of W4 was in it: the legs, the quality gates and every other emulator group passed. The step now waits for the underline as the project step above it already did, which is the same kind of race W3's gate met in that group.
- **Tests:** `test/widget/git_panel_test.dart` (15), `test/application/git_panel_controller_test.dart` (9), `test/application/git_file_states_test.dart` (4), `test/goldens/git_golden_test.dart` (6 baselines, `test/goldens/git/`), the panel's G3 and G7 cases in `test/widget/accessibility_test.dart`, and `FolderCopyTest`'s import of a big pack: **1,411 Dart tests** in CI 45814316019, against 1,376 in W3, and **285 Kotlin JVM tests**.

### W5 — Diffs in the editor (1–2 sessions) → G5

- **`@codemirror/merge` in the editor page:**
  - one column on a phone, two on a wide screen;
  - a working-tree file against the index or the last commit, editable, with *Revert this change* on each change, which is an edit the editor can undo;
  - a commit's file against its parent, read-only.
- **The protocol's new types,** with fixtures both sides run: a diff opened with the older text and the document, its mode, and closed.
- **Large files:** above the editor's 512 KiB line for plain text, the diff says it is too large to compare here, and offers the file.
- **The bundle** stays within its 1.5 MiB gzipped, with its size recorded.

#### As built (W5)

- **The page** (`editor/src/editor/diff.ts`, `@codemirror/merge` 6.13.0, MIT): `unifiedMergeView` in the document's own `diffSlot` compartment for one column, `MergeView` in a `cf-split-diff` sibling div for two, with the main view hidden while it is up. A diff is a way of showing a document, not a copy of it: the id, the undo history, the journal and the tab are the document's own, so *Revert this change* is an edit Ctrl+Z takes back and Save writes. Revert buttons are offered only for a document the user can edit — `rejectChunk` dispatches straight at the view, which the read-only facet does not stop, so a button on a commit's text would work and be a lie. The merge view's hardcoded greens and reds are overridden selector by selector with the palette's new `diffAdded` and `diffRemoved` (the design system's `success` and `danger` at 18 % alpha), and its revert and collapsed-lines controls are 48 dp.
- **The protocol:** host → editor `diff.open {docId, original, mode}`, answered with `{mode, chunks}`, and `diff.close {docId}`; `DIFF_MODES` / `diffModes` = `inline`, `split`; `MAX_DIFF_CHARS` / `maxDiffChars` = 512 KiB, the same line §10 of EDITOR_ARCHITECTURE draws for plain text, which the Dart contract test asserts equal to `plainTextAboveChars`. Eight new fixtures (four valid, four invalid) run on both sides; `split` for a document that can be edited is `bad_payload` in the page, and refused in the host before it is sent.
- **In the app:** `EditorHost.openDiff/closeDiff` keep the diff in the shadow, so a page that restarts is shown it again; `DocumentController.showDiff` compares an open document, and `openRevision` opens a commit's file read-only in a tab of its own keyed `path@hash`, which is never saved, watched or written into the session, and reads `main.js at a1b2c3d`. A two-column diff stands in for the editor, so another document coming into it ends that comparison, in the page and in both layers of state. `application/git/git_diff_controller.dart` chooses the older text: the staged version for unstaged changes, the last commit once they are staged, nothing for a new file, the old name for a rename, and the commit before it for a file in a commit. The panel's tap compares, its long press opens the file alone.
- **Too large** is decided in the app, not the page: either text past `maxDiffChars` and nothing is asked of the page — the file is open, and the banner says it is too large to compare here (`diff_notice` in `editor_pane.dart`, which also says *Showing 2 changes against the staged version.* and offers *Stop comparing*).
- **The bundle:** `editor.html` 876.2 KiB, **319.6 KiB gzipped** of the 1.5 MiB budget (327,307 B of 1,572,864 B), **+10,315 B** gzipped for the merge view, 2.1 % of the budget; 28 packages. `tool/verify_bundle.mjs` now also drives the built page through a diff: it opens one, checks that exactly one *Revert this change* is offered, clicks it, and checks the older text came back as one `doc.changed`.
- **Differs from the plan:** nothing in scope. G5's run in the real app — a diff shown, a change reverted, the file committed — belongs to the emulator gate's `git` group, which W6 builds; W5's evidence is vitest, the Dart tests and the verifier on the built page.
- **Tests:** `editor/test/diff.test.ts` (20) and the protocol fixtures, **476 vitest tests** in 27 files against 448 in W4; `test/application/git_diff_test.dart` (16), `test/widget/git_diff_test.dart` (5) and the contract test's W5 case with its 8 fixtures, for **1,441 Dart tests** against 1,411 in W4, with `ScriptedGitService.fileAt` and the fake page taught `diff.open`, `diff.close` and `readOnly`.
- **Found on the way:** CI's gates keep going when they fail, so a red run showed green steps and its log host is not always reachable; the two *Enforce* steps now name the gates that failed in a check annotation, the test digest carries each failure's exception, and the format gate carries the patch `dart format` would write (ci.yml). The new package also left `THIRD_PARTY_NOTICES.md` stale, which `tool/notices.mjs --check` caught in the editor job.

### W6 — The Git gate on real targets (1–2 sessions) → G6

**The budgets, decided by the owner on 2026-11-23** (§10, item 4, (a), from W1's numbers):
- the status of the 10,000-file repository shown in the app within 500 ms at the 95th percentile on the Pixel 8a (git alone took 134 ms in W1);
- the app's frames while a status, a clone and a commit of the large repository run: at most 5 % over 32 ms and none frozen, the terminal flood's rule;
- a clone's time and the processes' memory, recorded.

**Where they are measured:**
- **The emulator gate's new `git` group,** in the real app:
  - a project made a repository, a commit, a branch created and switched to;
  - a diff shown, a change reverted, and the file committed;
  - a clone from the local server, with the token typed into the dialog and remembered; a push; a pull with a conflict, resolved and committed;
  - the token found nowhere: not in the app's logs, the runtime's home, the project, or the processes' arguments and environments;
  - the large repository's status without a frozen frame;
  - the figures recorded.
- **The runtime legs** run `GitTest`.
- **Test Lab's Pixel 8a** runs `phone_git_test.dart`, judged on the budgets, in a `[testlab]` run after CI is green.
- **For the owner's phone** (W7's checklist): a real repository cloned from GitHub with a token, a commit pushed and seen on the website, Gboard in the commit box, and the diff on a phone's screen.

#### As built (W6)

- **The page's revert command** (`editor/src/editor/diff.ts`): a test cannot tap a button inside the WebView, so the edit the diff's own *Revert this change* button makes is now a command — `revertChunk` takes the chunk the cursor is in, else the first one after it, else the first of all, and calls `@codemirror/merge`'s `rejectChunk` at its position in the document (`chunk.fromB`, the side the document is on). It is named in `EDITOR_COMMANDS`, in the controller's `COMMANDS` and in Dart's `editorCommands`, so `cmd.exec {command: 'revertChunk'}` reaches the host as an ordinary `doc.changed` and Ctrl+Z takes it back. Two cases in `editor/test/diff.test.ts` and three checks in `tool/verify_bundle.mjs` (the built page: the command runs, the older text comes back as one change, and a read-only document refuses it).
- **What both targets share** (`app/integration_test/git_measure.dart`): the local server (W1's `git http-backend` behind Basic authentication on 127.0.0.1, in the runtime's own python, kept verbatim from `GitRemoteTest`), which can serve a seed or a repository that already exists; the 10,000-file repository in folders of 100, as `GitTest` generates it; `measureStatuses`, the panel's own refresh timed 20 times; `measureFrames`, Flutter's frames while something runs, with a progress bar laid over the app so every frame is drawn (`terminal_measure.dart`'s `withFramesDrawn`, made public for it); the token sweep, which reads every file under the projects, the no-backup folder and the runtime's home, and every process's arguments and environment through `/proc`; and `GitDriver`, the Git panel driven as a finger drives it. Nothing in it settles the app: a status spinner or a progress bar is almost always drawing, and `pumpAndSettle` would never return.
- **The gate's `git` group** (`app/integration_test/git_test.dart`, one test of five parts): a project made a repository from the panel's empty state, its first commit through the commit box, a branch created and switched to in the dialog; a file's changes opened as a diff by a tap in the panel (two changes against the staged version, the banner saying so), one of them reverted in the page, the file saved and committed, and `git show HEAD:notes.md` holding exactly what the revert left; a clone from the device's own server with the token typed into the credential dialog once and *Remember on this device* left on, a push the bare repository really has afterwards (`log -1` and `show main:README.md` read on the other side), and a pull that conflicts, is resolved file by file in the panel and is committed as a merge with two parents; the token found in no file and no process while a fetch runs and after it; and the 10,000-file repository staged, committed and refreshed with the frames measured. Its `GIT_GATE` lines are the evidence, recorded and never judged there.
- **The phone's budgets** (`app/integration_test/phone_git_test.dart`, run by Test Lab in the same entrypoint as the store, search, the terminal and the languages): the status of 10,000 files untracked, clean and with a hundred changed; the frames while they are committed and while the whole repository is cloned over HTTP from the device's own server; and the clone's time with the app's and its renderers' memory before and after. The figures leave as `RUNTIME_GATE git_phone_*` lines and a `CODEFORGE_GIT_JSON` document; `gate_results.py` holds them to the budgets (`git_phone_status_clean_under_budget=1`, the three frame windows' `*_under_budget=1`, and `git_phone_frozen_frames=0`), and the entrypoint's expectation went from five Dart tests to six.
- **The gate script** (`app/tool/ci/emulator_gate.sh`): the `git` group runs both files — its own first, then the phone's, whose exit and lines are recorded and never judged, as the `lsp` group already does — writes `ci-results/gate/git.txt` with `git_group=pass`, and leaves the device with no app. The phase gate's limit went from 100 to 130 minutes for it.
- **Differs from the plan:** the runtime legs already ran `GitTest` since W1, so that half of W6 was done before it began; and the phone's file measures the budgets alone — the whole of Git's screen is the emulator group's work, which has a computer attached to drive it.
- **Tests:** `editor/test/diff.test.ts` (2 more: 22) for **478 vitest tests** in 27 files against 476 in W5; the Dart unit and widget suites are unchanged at **1,441**; the new work is three integration files, which only a device runs.

### W7 — Docs and the phase exit (1 session) → G7

- **The docs:**
  - GIT_ARCHITECTURE (new, begun in W2, as built in W7), and AGENTS' documentation map;
  - ADR-0016 (Git);
  - SECURITY §2.4, the Git boundary, and §4's credential row as built;
  - ARCHITECTURE (`GitService`, the credential store), EDITOR_ARCHITECTURE (the diff's types), RUNTIME_INTEGRATION (Git on the runtime, folders);
  - PERFORMANCE (the Git budgets), TESTING, BUILD_AND_RELEASE, REPOSITORY_STRUCTURE and TECH_STACK;
  - docs/store (the listing, and the data safety form: credentials stay on the device), ROADMAP, README and the CHANGELOG.
- **The exit:** PHASE_7_REPORT, PHASE_7_PHONE_CHECKLIST and the exit gate.

## 4. Deliverables

- `GitTest` and its numbers, and ADR-0016.
- `GitHost` with its Pigeon API; the real `GitService` and its parsers; the controller; the identity.
- The credential store and helper, clone, fetch, pull and push; SSH keys if decided.
- The *Source control* panel, the branch chip, the explorer's colours.
- The diff view in the editor, with the protocol's new types.
- The `git` gate group, `GitTest` on the legs, and `phone_git_test.dart` in Test Lab.
- GIT_ARCHITECTURE, SECURITY §2.4, PHASE_7_REPORT and PHASE_7_PHONE_CHECKLIST.

## 5. Acceptance criteria (measurable gates)

| Gate | Criterion | Evidence |
|---|---|---|
| **G1 Spike** | Local work, a remote with a password through the credential helper, and the large repository's figures pass on API 26 to 36 and the arm64 phone. HTTPS to a real host and SSH recorded. ADR-0016 records the choices with the numbers | the runtime legs, Test Lab, ADR-0016 |
| **G2 Host and service** | The host refuses what it must (its JVM tests), and runs each operation of the fixed set with the fixed settings. The parsers pass their fixtures and fuzzing. The service and controller pass against the fake, and `GitTest` passes through the host on every target | CI, the runtime legs, Test Lab |
| **G3 Remotes and credentials** | Clone, fetch, pull and push against the local server on every target, the credential from the store; a wrong one refused and erased; a URL carrying a secret refused; *Stop* leaves no process. No secret in a log, an argument, an environment or a plain file. SSH as decided | CI, the runtime legs, the phase gate |
| **G4 Panel** | In the real app: a repository made, changes staged and committed, a branch created and switched, history shown, a pull's conflict resolved, folders as decided | the phase gate's `git` group, widget tests, goldens |
| **G5 Diffs** | A file's diff against the index and the last commit, and a commit's, in the editor page; a change reverted and undone; the protocol's types tested both sides; the bundle within budget | the phase gate's `git` group, vitest, Dart tests |
| **G6 Git budgets** | On the arm64 phone: the budgets as decided (§10, item 4). On the emulator: the same figures recorded | Test Lab, the phase gate |
| **G7 Docs** | The docs synced, GIT_ARCHITECTURE as built, ADR-0016 and SECURITY §2.4 written, PHASE_7_REPORT and the phone checklist written | the documents |

Each work package ends as Phase 6's did: CI green, the phase gate, a `[testlab]` run in its own commit when the phone is involved, the docs updated, a report in chat, then the owner's "next".

## 6. Tests

| New suite | Where |
|---|---|
| JVM: the host's argument checks and fixed settings, the credential helper's protocol, the store with a stand-in cipher | CI's quality job |
| Instrumented: W1's `GitTest`, then through the host; the store with the real Keystore | the runtime legs, Test Lab |
| Dart: the parsers (fixtures from real output, and fuzzing), the service and controller against the fake, the credential dialog, the panel, the clone dialog; goldens | CI |
| vitest: the diff's types, the merge view's setup | CI's editor job |
| Integration: `git_test.dart` | the phase gate |
| `phone_git_test.dart` | Test Lab |

## 7. Documentation

GIT_ARCHITECTURE (new), ADR-0016 (new), SECURITY §2.4 and §4, ARCHITECTURE, EDITOR_ARCHITECTURE, RUNTIME_INTEGRATION, PERFORMANCE, TESTING, BUILD_AND_RELEASE, REPOSITORY_STRUCTURE, TECH_STACK (`@codemirror/merge`'s pin), THIRD_PARTY_NOTICES (written by CI), AGENTS' documentation map, docs/store (the listing, the data safety form), ROADMAP, README, CHANGELOG, PHASE_7_REPORT, PHASE_7_PHONE_CHECKLIST.

## 8. Known limitations (planned) and out of scope

- **What the panel does in Phase 7:** §2's list. Hunks, stash, tags, submodules, blame, rebase and a history graph are for the terminal's git, or later.
- **History** shows the last 100 commits of the branch.
- **Folders from shared storage** get what §10, item 2 decides; ADR-0013's run copy keeps leaving `.git` out.
- **Credentials guard against leaks, not against the user's own code.** Everything the runtime runs shares the app's user (SECURITY §1). While a Git operation runs, a program the user started could reach the helper as Git does; it answers only for that operation's host, and only while it runs.
- **A repository's own configuration** can still name programs Git runs, such as hooks and filters. Hooks the user wrote run as their code, as *Run* does. A cloned repository brings no hooks and no configuration of its own.
- **HTTPS with a private certificate authority,** or through a proxy, is not supported in Phase 7.
- **A repository imported from shared storage** may arrive without executable bits or symbolic links, which Android's shared storage need not keep. W4 checks what Git then shows, and turns `core.fileMode` off for an import if those files show as changed.

## 9. Risks & mitigations

| Risk | Mitigation |
|---|---|
| A large repository freezes the app | Git in its own processes; streamed output parsed off the UI thread; one status at a time, debounced; reads without the index lock; measured in W1, judged on the phone in W6 |
| HTTPS fails in the runtime: libcurl looks for certificates under Termux's own prefix | Proven in W1 against a real host; `http.sslCAInfo` passed if needed |
| A credential leaks into a log, an argument, an environment or a file | The helper protocol only; logs name operations, never URLs or arguments; URLs with secrets refused; the gate searches logs, the runtime's home and the processes for the token |
| A repository's configuration runs a program: fsmonitor, an SSH command, a credential helper, a pager | Fixed settings on every command override them; the `ext::` transport is off; an imported repository's configuration is the user's, as its hooks are |
| The panel's git and the terminal's git take the same lock | Reads take no lock; a write that finds the lock says another git is running, and offers to retry |
| *Import as project* leaves out a pack file over 64 MB | The import takes `.git`'s files whatever their size, within its 4 GiB, or refuses and says why; tested in W4 |
| A clone or push over a slow phone network | Progress; *Stop* ends the tree; a clone lands in a staging folder, renamed into place only on success; Git's low-speed limit ends a stalled transfer |
| The diff view grows the editor page past its budget | `@codemirror/merge` alone: its dependencies are in the page already; the size recorded in W5 |
| Test Lab's 5 daily tests (counted by the Pacific day), and its end on 2027-09-30 | One phone run per gate, as before; ROADMAP's queue holds the successor |

## 10. Owner actions and decisions, in order

1. **Phase 6 accepted on 2026-11-23** (the owner's "continue", then "green start next phase", said before its exit gate; the exit gate passed).
2. **Git in folders from shared storage** (ROADMAP's gate), by W4:
   - **(a) Git in projects.** A folder that holds a repository says, in the panel, that Git works in projects, and offers *Import as project*, which copies `.git` with the rest (§9's fix for pack files). One copy, made once, on request.
   - **(b)** As (a), plus a folder's status, diffs and history, read-only, from a copy of its `.git` made on request.
   - **(c)** Git on the folder itself, through a two-way copy of its files and `.git`, kept in step. Writing thousands of small files back through Android's storage framework is slow, and a copy stopped halfway could damage the user's repository.
   - **The agent recommends (a).** The run copy and *Import as project* already exist, and the user's repository is never written by anything but the user.
   - **Decided on 2026-11-23: (a),** Git in projects.
3. **Credentials in Phase 7,** by W3:
   - **(a) HTTPS with a token** (a personal access token from GitHub, GitLab, Codeberg, Bitbucket or any host), kept in the Keystore.
   - **(b)** (a), plus SSH keys made in the app (§3, W3). About one more session; W1 probes it.
   - **(c)** (a), plus signing in to GitHub through its device flow. It needs an OAuth app that the owner registers, and its client id.
   - **The agent recommends (a) now, and brings (b) at W1's end** with the SSH probe's result. W1 found the SSH client working on every target, so the agent recommended (b).
   - **Decided on 2026-11-23: (b),** HTTPS tokens and SSH keys made in the app.
4. **The Git budgets, after W1's numbers:** status of the 10,000-file repository, the frames during long operations, and what is only recorded. The agent proposes them at W1's end, as Phase 4 W6 proposed search's.
   - **Decided on 2026-11-23: (a),** as proposed: the status of the 10,000-file repository in the app within 500 ms at p95 on the Pixel 8a; at most 5 % of frames over 32 ms and none frozen while a status, a clone and a commit run; a clone's time and memory recorded (W6).
5. **Non-blocking, carried from Phase 6:**
   - the phone sessions: PHASE_6_PHONE_CHECKLIST, and the Phase 3, 4 and 5 checklists, on Phase 6's exit gate APK;
   - the first release: the keys, and the licence review;
   - Play: the account, the testers, the forms, the special-use declaration, and the rule on downloaded code;
   - what runs the arm64 tests after Test Lab.
6. **Left to the agent,** unless the owner wants them: the helper's transport (measured in W1), the host's fixed settings and its refused options, the refresh policy, the merge view's options, the panel's details, and how a write waits for a lock.
