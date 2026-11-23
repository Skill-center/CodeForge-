# Phase 7 Plan — Git & Source Control

**Status:** **Proposed on 2026-11-23,** the day Phase 6 was accepted. The owner's decisions it needs are in §10 · **Spec reference:** §8 Phase 7 (Git and source control), §7 (security), §9 (performance: measure, never assume) · **Architecture:** [ARCHITECTURE.md](../ARCHITECTURE.md) §4 (the credential store), [RUNTIME_INTEGRATION.md](../RUNTIME_INTEGRATION.md) (Git on folders from shared storage), [SECURITY.md](../SECURITY.md) §1, §2 and §4, [EDITOR_ARCHITECTURE.md](../EDITOR_ARCHITECTURE.md), [ADR-0004](../adr/0004-editor-engine.md) (CodeMirror 6), [ADR-0005](../adr/0005-sealed-runtime.md), [ADR-0012](../adr/0012-backup-opt-in.md) (backup), [ADR-0013](../adr/0013-folders-and-the-runtime.md) (a folder runs in a copy) · **Builds on:** Phase 6 ([report](PHASE_6_REPORT.md)), and the sealed runtime's Git since Phase 4

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
- **SSH, as a probe** for §10, item 3: `ssh-keygen` makes an ed25519 key with a passphrase; the runtime's `sshd` serves a repository on 127.0.0.1 with that key authorised; `git clone` over SSH, the passphrase given through `SSH_ASKPASS`. Recorded.
- **A large repository,** generated: 10,000 files in 500 folders, two commits, and the same at 50,000 files:
  - `status` once cold (the first after the files were written) and 20 times warm: the median, the 95th percentile and the slowest;
  - the size of its output, `add -A` and `commit` of 100 changed files, `log -n 100`, and `diff --stat`;
  - the same `status` with `--no-optional-locks`, which leaves the index alone, so the app's reads never block the terminal's git.
- **The outcome:**
  - ADR-0016 (Git) records the choices with these numbers: the sealed CLI through a host; the helper's transport; HTTPS settings.
  - W1's report brings the owner the numbers for §10's items 2, 3 and 4, with a recommendation for each.

### W2 — The Git host and the real service (2 sessions) → G2

- **The host** (Kotlin, `git/GitHost.kt`):
  - runs `git` through the launcher, in a project's folder named by the project, never by a path from Dart;
  - takes an operation from a fixed set (`status`, `add`, `restore`, `commit`, `log`, `show`, `diff`, `branch`, `switch`, `merge`, `init`, and W3's remotes) with its arguments. It refuses any option that runs a program or moves Git elsewhere (`-c`, `--config-env`, `--exec-path`, `--git-dir`, `--work-tree`, `--upload-pack` and clone's `-u`, `--receive-pack`, `--exec`, `--template`). Paths come after `--`, relative, inside the project;
  - adds the same settings to every command, which a repository's own configuration cannot change for that command: no fsmonitor, no `ext::` transport, no pager, no colour, paths unquoted, CodeForge's credential helper only (W3), `GIT_TERMINAL_PROMPT=0`, no system configuration;
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
- **SSH keys, if decided** (§10, item 3):
  - an ed25519 key made with the runtime's `ssh-keygen`, encrypted by OpenSSH with a random passphrase that only the store holds;
  - the passphrase given per operation through `SSH_ASKPASS`;
  - `known_hosts` in the runtime's home, a new host's fingerprint shown once for the user to accept;
  - the public key shown, to copy into the host's settings.

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
- **Folders from shared storage,** as decided (§10, item 2).
- **Accessibility** (labels, tap targets, text at 1.3×) and goldens, as the other panels have.

### W5 — Diffs in the editor (1–2 sessions) → G5

- **`@codemirror/merge` in the editor page:**
  - one column on a phone, two on a wide screen;
  - a working-tree file against the index or the last commit, editable, with *Revert this change* on each change, which is an edit the editor can undo;
  - a commit's file against its parent, read-only.
- **The protocol's new types,** with fixtures both sides run: a diff opened with the older text and the document, its mode, and closed.
- **Large files:** above the editor's 512 KiB line for plain text, the diff says it is too large to compare here, and offers the file.
- **The bundle** stays within its 1.5 MiB gzipped, with its size recorded.

### W6 — The Git gate on real targets (1–2 sessions) → G6

**The budgets,** as the owner decides after W1 (§10, item 4). The agent will propose, from W1's numbers:
- status of the 10,000-file repository, warm, at the 95th percentile;
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
3. **Credentials in Phase 7,** by W3:
   - **(a) HTTPS with a token** (a personal access token from GitHub, GitLab, Codeberg, Bitbucket or any host), kept in the Keystore.
   - **(b)** (a), plus SSH keys made in the app (§3, W3). About one more session; W1 probes it.
   - **(c)** (a), plus signing in to GitHub through its device flow. It needs an OAuth app that the owner registers, and its client id.
   - **The agent recommends (a) now, and brings (b) at W1's end** with the SSH probe's result.
4. **The Git budgets, after W1's numbers:** status of the 10,000-file repository, the frames during long operations, and what is only recorded. The agent proposes them at W1's end, as Phase 4 W6 proposed search's.
5. **Non-blocking, carried from Phase 6:**
   - the phone sessions: PHASE_6_PHONE_CHECKLIST, and the Phase 3, 4 and 5 checklists, on Phase 6's exit gate APK;
   - the first release: the keys, and the licence review;
   - Play: the account, the testers, the forms, the special-use declaration, and the rule on downloaded code;
   - what runs the arm64 tests after Test Lab.
6. **Left to the agent,** unless the owner wants them: the helper's transport (measured in W1), the host's fixed settings and its refused options, the refresh policy, the merge view's options, the panel's details, and how a write waits for a lock.
