# Git Architecture

**Status:** **Begun in Phase 7 W2** (2026-11-25; [PHASE_7_PLAN.md](phases/PHASE_7_PLAN.md), [ADR-0016](adr/0016-git.md)). It records the Git host and the service as built. W3 adds remotes and credentials, W4 the *Source control* panel, W5 diffs in the editor and W6 the Git gate, and each adds its section here. W7 completes the document at the phase's end.

---

## 1. Topology

Git is the sealed runtime's own `git` 2.56.1, run as a child process through the launcher, never JGit and never a library in the app's process (ADR-0016):

```
Workbench: the status strip's branch chip (features/workbench/workbench_screen.dart)
Settings → Source control: the identity (features/settings/source_control_settings_screen.dart)
   │
GitController (application/git/git_controller.dart): the open project's repository state
   │   debounced, one status at a time, changes queued
GitService (services/contracts.dart) ── HostGitService (services/git/host_git_service.dart)
   │   meaning: status, stage, commit, log, branches, merge, init, the identity
   │   core/git/: the parsers of porcelain v2, log, for-each-ref and diff-tree; git's errors
GitHost (services/contracts.dart) ── PigeonGitHost (services/git/native/pigeon_git_host.dart)
   │   Pigeon GitApi: run · stop        ▲ GitEvents: output · progress · exited
GitHost (Kotlin, git/GitHost.kt) ──► GitRunner (git/GitRunner.kt) ──► GitCommands (git/GitCommands.kt)
   │                                    a project by its folder's name      the fixed set of operations,
   │                                    one change at a time per repository   the fixed settings
RuntimeHub.stream ──► CommandRunner.stream (runtime/): the launcher's command mode
   │                     stdout cut into records (NUL, newline or whole); stderr's progress
git --no-pager --literal-pathspecs [--no-optional-locks] -c … <operation> <arguments>
```

- **Dart owns the meaning:** which command answers which question, how its output reads, what a failure means, and when the status is read again.
- **Kotlin owns what may run:** an operation from a fixed set with the options it allows, in a project named by its folder, with settings no repository can change. Dart never names a path outside a project, a program, an option off the list or a variable.
- **The runtime owns the process:** a session and a process group of its own, a time limit, and nothing left running when it ends (SECURITY E4).

## 2. The host (Kotlin)

### 2.1 What runs: `GitCommands`

Each operation lists the options it takes; anything else that starts with `-` is refused, so whatever would run a program or move git elsewhere is refused because it is not listed (`-c`, `--config-env`, `--exec-path`, `--git-dir`, `--work-tree`, `--upload-pack`, `--receive-pack`, `--exec`, `--template`, `--output`, `--ext-diff`). A refusal names an option only when it looks like one, never a value Dart sent.

| Operation | Access | Output | Notes |
|---|---|---|---|
| `status` | read | records | `--porcelain=v2 -z` forced; branch, untracked and rename options |
| `add` | write | lines | `-A`, `-u`; paths |
| `rm` | write | lines | `--cached` required, paths required: unstaging before the first commit |
| `restore` | write | lines | `--staged`, `--worktree`, `--source=`; paths required |
| `clean` | write | lines | paths required: only the files named, never the tree |
| `commit` | write | lines | `-m`, `--amend`, `--no-edit`, `--allow-empty` |
| `log` | read | records | `-z --no-color` forced; `-n`, `--skip=`, `--format=` (no `%G`, which runs gpg); paths |
| `diff-tree` | read | records | `-z` forced; `-r`, `--root`, `--name-status`, `-M` |
| `diff`, `show` | read | whole | `--no-color --no-ext-diff --no-textconv` forced |
| `cat-file` | read | whole | a blob at a revision or in the index; no filter runs |
| `for-each-ref` | read | lines | `--format=` (no signature fields), `--sort=`, patterns under `refs/` |
| `rev-parse` | read | lines | nothing that answers with a path |
| `branch`, `switch`, `merge`, `init` | write | lines | `switch --create`, never `-c`; `merge --abort`, `--ff-only`; `init --initial-branch=` |
| `check-ref-format` | read | lines | in a project or the runtime's home |
| `config` | read or write | lines | `--global` and `user.name` or `user.email` only, read, set or unset, in the runtime's home |

- **Paths** come after `--`, relative, inside the project, never through `..` or into `.git` (in any case), and are taken literally (`--literal-pathspecs`). Revisions never start with `-`, hold no control character, and a `<revision>:<path>` names a path inside the project.
- **Every command** starts `git --no-pager --literal-pathspecs`, a read adds `--no-optional-locks`, and then the same settings, which a repository's own configuration cannot change for that command: `core.fsmonitor=false`, `protocol.ext.allow=never`, `core.pager=cat`, `color.ui=false`, `core.quotePath=false`, `credential.helper=` (W3 adds CodeForge's own after it), `gc.autoDetach=false` and `maintenance.autoDetach=false` (the launcher ends whatever a command leaves running), `user.useConfigOnly=true` (never an identity git guesses), and `log.showSignature=false`, `merge.verifySignatures=false`, `commit.gpgSign=false` (no gpg in the runtime).
- **Its variables:** `GIT_TERMINAL_PROMPT=0`, `GIT_CONFIG_NOSYSTEM=1`, `GIT_EDITOR=:`, `GIT_PAGER=cat`, and in a project `GIT_CEILING_DIRECTORIES` at the projects' folder, so a `.git` the terminal made above it claims no project. A host's variables only add to the runtime's environment, never replace one of its own (`CommandRequest.variables`).
- **Time limits:** 2 minutes for a read, 10 for a change.

### 2.2 How it runs: `GitRunner`

- **The place:** a project is named by its folder's name and resolved in `<filesDir>/workspaces`, links resolved: the folder must be directly in it (SECURITY E3). The identity runs in the runtime's home.
- **One change at a time per repository:** a second is refused as `busy` at once, and Dart's controller queues its own. Reads run alongside, without the index's optional lock, so they never hold up the terminal's git. At most 8 runs at once.
- **The output:** stdout is cut into records at NUL (git's `-z`), at newlines, or kept whole (a file's text or a diff, up to 4 MiB, else `too_large`). Records go to Dart in batches of 2,000 or 256 KiB. A run stops at its record cap (Dart's; a status asks for twice its files and its headers, since a rename is two records) or at 64 MiB, and ends *truncated*, not failed. stderr keeps 64 KiB; its progress lines go to Dart instead, at most one redrawn line per 100 ms, every closing line.
- **Stop:** ends the run's whole tree, before or after git started; the exit says `stopped`.
- **The exits:** git's code when it exited by itself, whatever it is; otherwise `timed_out`, `stopped`, `signaled`, `too_large`, `not_ready` or `launch_failed`. A refusal comes at once and nothing follows: `not_ready`, `bad_request`, `refused`, `no_such_project`, `busy` or `launch_failed`.
- **The log** names an operation, its run, how it ended, its records and its time: never an argument, a path or a URL.

### 2.3 Pigeon: `pigeons/git_api.dart`

- `GitApi.run(GitRunMessage{runId, project?, operation, arguments, maxRecords?})` answers `GitStartMessage{failure?, detail?}`: the run started, or why not. A null project is the runtime's home.
- `GitApi.stop(runId)` answers whether such a run was running.
- `GitEvents.output(runId, records)`, `progress(runId, text, closing)` and `exited(GitExitMessage{runId, operation, exitCode?, failure?, detail?, stderr, records, chars, truncated, elapsedMs})`, in order, on the main thread.
- The runs belong to the engine: when it goes, they stop.

## 3. The service (Dart)

### 3.1 The client and the commands

- **`PigeonGitHost`** gives each run an id (epoch milliseconds × 1000, then counting), takes the run's events that arrive before its answer, and gives up on an answer after 15 s.
- **`HostGitService`** gives the commands their meaning:

| Call | Command |
|---|---|
| status | `status --branch --untracked-files=all`, at most `maxFiles` (100,000 unless asked) |
| stage, stage all | `add -A -- <paths>`, `add -A` |
| unstage | `restore --staged -q -- <paths>`; before the first commit `rm --cached -r -q --ignore-unmatch -- <paths>` |
| discard, delete untracked | `restore --worktree -q -- <paths>`, `clean -f -q -- <paths>` |
| commit | `commit -q [--amend] -m <message>`, or `--amend --no-edit` |
| log | `log -n <max> [--skip=<n>] --format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s [-- <path>]` |
| a commit's files | `diff-tree -r --root --name-status -M --no-commit-id [<parent>] <commit>` |
| a file's text | `cat-file blob <revision>:<path>`, or `:<path>` for the index |
| branches | `for-each-ref` with the ref, its commit, upstream and track, HEAD, date and subject separated by NUL, `refs/heads/` and `refs/remotes/` |
| create, switch, delete a branch | `switch -q --create`, `switch -q`, `branch -d` or `-D -q` |
| merge, abort | `merge --no-edit`, `merge --abort` |
| init | `init -q --initial-branch=main` |
| the identity | `config --global --get`, set or `--unset`, `user.name` and `user.email` |
| a branch name's check | `check-ref-format --branch` |

- **The parsers** (`core/git/`): porcelain v2 with the branch headers, ahead and behind, renames, conflicts and paths holding spaces, newlines or any UTF-8; `log`'s and `for-each-ref`'s fields; `diff-tree`'s pairs; and git's progress lines. Each is checked against fixtures of git's real output (`test/fixtures/git/`, 13 files, written with the host's own command lines) and fuzzed: nothing they are given makes them throw, and every file they read has a path.
- **The failures:** every error is a `GitFailure` with a `GitProblem`: the host's codes, and git's words read into what they mean (`core/git/git_errors.dart`): not a repository, a lock held, no identity, a conflict, local changes a switch would overwrite, a merge in progress, nothing to commit, no commits yet, a branch that exists, an invalid name, not fully merged, the current branch, no such branch. git speaks English here (`LANG=C.UTF-8`), and each pattern is checked against its real output (`errors.json`).
- **The fake:** `FakeGitService` (`services/fakes.dart`) keeps a repository in memory with the same contract, for the widget tests and `flutter test`.

### 3.2 The controller

`GitController` (`application/git/git_controller.dart`) holds the open workspace's repository state: `unavailable` (no host), `folder` (a folder from shared storage: Git works in projects only), `waiting` (the runtime is not ready), `loading`, `notARepository`, `repository` or `failed` (with the last status kept).

- **When the status is read:** after each operation, after a save (the open documents' stamps, never typing), on the file watcher's batches, on a change in the project's `.git` (whoever ran git, the terminal included), and on resume. Changes gather for 300 ms.
- **One status at a time:** a change while one runs reads it again once it ends; the newest result wins. In the background nothing runs.
- **Changes are queued,** one after another, each followed by a status.

### 3.3 In the app

- **The branch chip** in the status strip shows the branch, `*` when anything changed, and the warning colour on conflicts; its tooltip says the upstream, ahead and behind, and the counts. A detached HEAD shows the commit's short id.
- **Settings → Source control** (`/settings/source-control`) sets the name and email commits are made with, in the runtime home's `.gitconfig`, which the terminal's git shares. An empty field removes its key.
- The *Source control* panel is W4's; until then it keeps its placeholder.

## 4. Security

- Git's commands run under the runtime's rules (SECURITY §2.1, E1 to E6), plus the host's own: the fixed set of operations, the fixed settings, paths inside the project, no repository found above the projects' folder, and logs without arguments, paths or URLs (§2.1 above).
- **Credentials** (W3) reach git only through its credential helper, named on the operation's own command line after `credential.helper=` clears every other (ADR-0016). Never in a log, an argument, the environment, a plain file or a backup.
- **Not built** for now: no remote operation runs (`clone`, `fetch`, `pull`, `push` are refused until W3).

## 5. Measured

Through the host's runner with the runtime's own git (`GitHostTest`, phase gate 45626687240), on the runtime legs and Test Lab's phone:

| Measure | Emulators, API 26 to 36 | Pixel 8a |
|---|---|---|
| 10,000 new files: their status (140,000 characters, 5 batches of 2,000) | 21–300 ms | 116 ms |
| `add -A`, `commit` of them | 304–865, 426–973 ms | 1,032, 1,326 ms |
| The clean status of 10,000 files, p50 / p95 of 20 | 17–42 / 18–46 ms | 87 / 114 ms |
| A merge with a conflict | 13–43 ms | 81 ms |

W1's figures, through the launcher alone, are in ADR-0016: the phone's p95 of the same status was 134 ms there, so the host adds no cost a measurement sees. The app's budget (500 ms at p95 on the phone, with the parse and the panel) is W6's to judge.

## 6. Not built yet

- **W3:** remotes (clone, fetch, pull, push) and credentials: the Keystore's store, the helper, SSH keys.
- **W4:** the *Source control* panel, the explorer's colours, *Import as project* for a folder's repository.
- **W5:** diffs in the editor with `@codemirror/merge`.
- **W6:** the Git gate on the emulator and the phone, with the budgets.
- **Out of scope for Phase 7:** hunk or line staging, interactive rebase, stash, tags, submodules, blame, a history graph, LFS, signing, a host's pull requests and issues, HTTPS through a proxy or with a private CA (PHASE_7_PLAN §8).
