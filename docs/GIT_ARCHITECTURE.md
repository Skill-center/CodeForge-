# Git Architecture

**Status:** **Begun in Phase 7 W2, with W3's remotes and credentials** (2026-11-25; [PHASE_7_PLAN.md](phases/PHASE_7_PLAN.md), [ADR-0016](adr/0016-git.md)). It records the Git host, the service, and how a credential reaches git and ssh without being in a file, an argument or the environment. W4 adds the *Source control* panel, W5 diffs in the editor and W6 the Git gate, and each adds its section here. W7 completes the document at the phase's end.

---

## 1. Topology

Git is the sealed runtime's own `git` 2.56.1, run as a child process through the launcher, never JGit and never a library in the app's process (ADR-0016):

```
Workbench: the status strip's branch chip (features/workbench/workbench_screen.dart)
Home → Clone repository (features/home/clone_dialog.dart) · the prompts above every screen
Settings → Source control: the identity, the accounts, the SSH key (features/settings/)
   │
GitController (application/git/git_controller.dart): the open project's repository state
   │   debounced, one status at a time, changes queued
GitService (services/contracts.dart) ── HostGitService (services/git/host_git_service.dart)
   │   meaning: status, stage, commit, log, branches, merge, init, clone, fetch, pull, push
   │   core/git/: the parsers of porcelain v2, log, for-each-ref and diff-tree; URLs; git's errors
GitHost (services/contracts.dart) ── PigeonGitHost (services/git/native/pigeon_git_host.dart)
   │   Pigeon GitApi: run · stop · answerCredential · accounts · sshKey …
   │          ▲ GitEvents: output · progress · exited · credentialRequested/Withdrawn/Rejected
GitHost (Kotlin, git/GitHost.kt) ──► GitRunner (git/GitRunner.kt) ──► GitCommands (git/GitCommands.kt)
   │                                    a project by its folder's name      the fixed set of operations,
   │                                    one change at a time per repository   the fixed settings
   ├── CredentialChannel (git/CredentialChannel.kt): one run's two FIFOs, mode 600
   │        git's credential helper ──┐                   ┌── ssh's SSH_ASKPASS (the runtime's bash)
   │                            CredentialBroker (git/CredentialBroker.kt)
   │                            CredentialStore (git/CredentialStore.kt) ── Android Keystore AES-256-GCM
   │                            SshKeys (git/SshKeys.kt) ── ~/.ssh/codeforge_ed25519, known_hosts
RuntimeHub.stream ──► CommandRunner.stream (runtime/): the launcher's command mode
   │                     stdout cut into records (NUL, newline or whole); stderr's progress
git --no-pager --literal-pathspecs [--no-optional-locks] -c … <operation> <arguments>
```

- **Dart owns the meaning:** which command answers which question, how its output reads, what a failure means, and when the status is read again.
- **Kotlin owns what may run:** an operation from a fixed set with the options it allows, in a project named by its folder, with settings no repository can change. Dart never names a path outside a project, a program, an option off the list or a variable.
- **The runtime owns the process:** a session and a process group of its own, a time limit, and nothing left running when it ends (SECURITY E4).
- **A secret belongs to neither side:** Dart asks the user and shows what is kept; Kotlin seals it with a Keystore key and hands it to git or ssh through a FIFO of that run's own. A secret is never a Pigeon field going down, an argument, a variable or a file (SECURITY §2.4).

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
| `clone` (W3) | write, network | lines | one URL, checked ([GitUrls](#24-credentials-w3)); `--progress` forced; the runner names the folder, never Dart |
| `fetch` (W3) | write, network | lines | `--progress` forced; `--prune`; one remote |
| `pull` (W3) | write, network | lines | `--progress --no-rebase --no-edit` forced, whatever `pull.rebase` says; `--ff-only`, `--ff`, `--no-ff`; a remote and a branch |
| `push` (W3) | write, network | lines | `--progress` forced; `--set-upstream`; a remote and a branch, to the same name: no refspec, no force, no delete, no tags |

- **Paths** come after `--`, relative, inside the project, never through `..` or into `.git` (in any case), and are taken literally (`--literal-pathspecs`). Revisions never start with `-`, hold no control character, and a `<revision>:<path>` names a path inside the project.
- **Every command** starts `git --no-pager --literal-pathspecs`, a read adds `--no-optional-locks`, and then the same settings, which a repository's own configuration cannot change for that command: `core.fsmonitor=false`, `protocol.ext.allow=never`, `core.pager=cat`, `color.ui=false`, `core.quotePath=false`, `credential.helper=` (W3 adds CodeForge's own after it), `gc.autoDetach=false` and `maintenance.autoDetach=false` (the launcher ends whatever a command leaves running), `user.useConfigOnly=true` (never an identity git guesses), and `log.showSignature=false`, `merge.verifySignatures=false`, `commit.gpgSign=false` (no gpg in the runtime).
- **Its variables:** `GIT_TERMINAL_PROMPT=0`, `GIT_CONFIG_NOSYSTEM=1`, `GIT_EDITOR=:`, `GIT_PAGER=cat`, and in a project `GIT_CEILING_DIRECTORIES` at the projects' folder, so a `.git` the terminal made above it claims no project. A host's variables only add to the runtime's environment, never replace one of its own (`CommandRequest.variables`).
- **A command that reaches a remote** (`clone`, `fetch`, `pull`, `push`) adds seven settings of its own: `protocol.allow=never` with `protocol.https.allow`, `protocol.ssh.allow` and `protocol.http.allow` set to `always`, so only those three transports run and `ext::`, `file://` and the rest are refused wherever a URL comes from; `submodule.recurse=false` and `fetch.recurseSubmodules=false`, so no other repository is fetched behind the user's back; and `transfer.credentialsInUrl=die`, so a URL carrying a secret stops git rather than leaking it into a log. Then CodeForge's credential helper, named last (§2.4).
- **Time limits:** 2 minutes for a read, 10 for a change.

### 2.2 How it runs: `GitRunner`

- **The place:** a project is named by its folder's name and resolved in `<filesDir>/workspaces`, links resolved: the folder must be directly in it (SECURITY E3). The identity runs in the runtime's home.
- **One change at a time per repository:** a second is refused as `busy` at once, and Dart's controller queues its own. Reads run alongside, without the index's optional lock, so they never hold up the terminal's git. At most 8 runs at once.
- **The output:** stdout is cut into records at NUL (git's `-z`), at newlines, or kept whole (a file's text or a diff, up to 4 MiB, else `too_large`). Records go to Dart in batches of 2,000 or 256 KiB. A run stops at its record cap (Dart's; a status asks for twice its files and its headers, since a rename is two records) or at 64 MiB, and ends *truncated*, not failed. stderr keeps 64 KiB; its progress lines go to Dart instead, at most one redrawn line per 100 ms, every closing line.
- **A clone's place (W3):** it runs in the projects' folder and writes `.clone-<runId>`, a hidden staging folder the runner names itself, renamed to the project's name when git exits 0. Stop, a failure or the app's death leave a hidden folder and no half-made project; the next clone of the same name is refused as `exists` only when the name is really taken. The name is locked for the clone's life, so two clones cannot race for it.
- **Stop:** ends the run's whole tree, before or after git started; the exit says `stopped`.
- **The exits:** git's code when it exited by itself, whatever it is; otherwise `timed_out`, `stopped`, `signaled`, `too_large`, `not_ready` or `launch_failed`. A refusal comes at once and nothing follows: `not_ready`, `bad_request`, `refused`, `no_such_project`, `busy` or `launch_failed`.
- **The log** names an operation, its run, how it ended, its records and its time: never an argument, a path or a URL.

### 2.3 Pigeon: `pigeons/git_api.dart`

- `GitApi.run(GitRunMessage{runId, project?, operation, arguments, maxRecords?})` answers `GitStartMessage{failure?, detail?}`: the run started, or why not. A null project is the runtime's home.
- `GitApi.stop(runId)` answers whether such a run was running.
- `GitEvents.output(runId, records)`, `progress(runId, text, closing)` and `exited(GitExitMessage{runId, operation, exitCode?, failure?, detail?, stderr, records, chars, truncated, elapsedMs})`, in order, on the main thread.
- The runs belong to the engine: when it goes, they stop.
- **W3 adds, for credentials:** `GitApi.answerCredential(GitCredentialAnswerMessage{id, accepted, username?, secret?, remember})`, and `accounts()`, `removeAccount()`, `sshKey()`, `createSshKey(comment)`, `deleteSshKey()`; `GitEvents.credentialRequested(GitCredentialPromptMessage{id, runId, kind: `https` or `host_key`, host, username?, fingerprint?, keyType?})`, `credentialWithdrawn(id)` and `credentialRejected(runId, host, username)`. A secret goes **up** once, in the user's answer; nothing going down ever carries one. `GitAccountMessage` has a host and a user name and no secret, and `GitSshKeyMessage` the public key, its fingerprint and its comment.

### 2.4 Credentials (W3)

A credential never reaches git as an argument, a variable or a file. Each remote run opens a **`CredentialChannel`**: a folder of its own under `no_backup/git/run/`, two FIFOs (`request` and `answer`, mode 600, made with `Os.mkfifo`), two small scripts, and a thread that reads a request, has the **`CredentialBroker`** answer it, and writes the answer back. The channel closes with the run, whatever it was waiting for: a blocked open is released by opening the FIFO for reading and writing at once. What a run left behind when the app's process died is swept at the next start.

**The two ways in:**

- **git's credential helper,** named on that operation's own command line, after the fixed settings' empty `credential.helper=` which clears every other: `-c credential.helper=!bash '<folder>/credential.sh' '<folder>'`. git runs it with `get`, `store` or `erase` and its fields on stdin; the script writes them into the request FIFO and prints what comes back.
- **ssh's askpass,** for a key's passphrase and a new host's key. `SSH_ASKPASS` cannot be a script of the app's, since Android forbids executing a file from app storage from API 29, so it is **the runtime's own bash**, with `BASH_ENV` pointing at a relay bash reads before it would open its argument as a script. A question (an argument ending in `: ` or `? ` that is not a file) goes to the channel and the answer is printed; anything else — a real script, a hook — runs as it would. `SSH_ASKPASS_REQUIRE=force`, since there is no display.
- **git's own prompts get nothing:** `GIT_ASKPASS=""` stops git looking further (a repository's `core.askPass`, `SSH_ASKPASS`), and `GIT_TERMINAL_PROMPT=0` leaves it no terminal. The helper is the only way in.

**The broker** answers one run:

| Asked | Answered |
|---|---|
| `get` for a host | the store's secret for exactly that host and user, if any; else the user is asked (Dart's dialog) and their answer used. Never over plain HTTP, unless the host is this device (`127.0.0.0/8`, `localhost`, `[::1]`) |
| `store` after a success | what the user typed, if they chose *Remember*, and only once the host accepted it: nothing else is ever stored |
| `erase` after a refusal | the stored secret is removed, but only if it is still the one that was refused; the run says so, and the user is told which account was dropped |
| ssh: `Enter passphrase for key '<file>'` (and OpenSSH 10's `Enter passphrase for "<file>"`, with or without `(empty for no passphrase)`, and `Enter same passphrase again`) | the passphrase of CodeForge's own key, from the store, to a question naming that key and no other; while a key is being made, the new passphrase made for it |
| ssh: `The authenticity of host … can't be established` | the user is shown the host and the fingerprint and decides; `yes` or `no`, and `no` to a question that cannot be read. OpenSSH 10 writes `… key fingerprint is: SHA256:…`, 9 wrote `is SHA256:….`; both are read |
| anything else | nothing |

A prompt waits 5 minutes; a run that ends withdraws its prompt. Every question ssh asked is kept (120 characters each, never an answer) so a failing run can say what it was asked.

**The store** (`CredentialStore`) is one file in `no_backup/`, which backup leaves out (ADR-0012), with a line per entry: the kind (`https` or `ssh_key`), the host, the user name and the sealed secret, each Base64, and when it was last written. The secret is sealed with **AES-256-GCM** under a key made in the **Android Keystore** (`codeforge-git-credentials`, randomized encryption required, never exportable, so it cannot leave the device), with a fresh nonce each time and the entry's kind, host and user as GCM's associated data: a sealed secret moved to another entry no longer opens. A line that will not open is dropped, not thrown; at most 256 entries are kept.

**SSH keys** (`SshKeys`): one ed25519 key, `~/.ssh/codeforge_ed25519` in the runtime's home — its own name, so the terminal's ssh never offers it unasked — made by the runtime's `ssh-keygen -q -t ed25519 -a 16`, encrypted by OpenSSH with a 32-byte random passphrase that only the store holds (under the host `codeforge-ssh-key`). `ssh-keygen` takes that passphrase through askpass, and the key is read back the same way to prove it opens with it. git runs ssh as `ssh -o IdentitiesOnly=yes -i <that key> -o UserKnownHostsFile=<home>/.ssh/known_hosts -o StrictHostKeyChecking=ask -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o ConnectTimeout=30`: CodeForge's key only, a new host asked about once and remembered, and no password authentication to fall back to. Settings shows the public half to copy into a host; *Remove* deletes both halves and the passphrase.

**The URLs a clone may take** (`GitUrls.kt`, and `core/git/git_urls.dart` with the same rules, both read `test/fixtures/git/urls.tsv`): HTTPS, SSH (`ssh://` or `user@host:path`), and plain HTTP only to this device. A URL carrying a password or a token is refused with that reason — CodeForge asks for the credential instead and keeps it in the Keystore — and a user name that is really a secret (a known token's prefix, or a long random-looking string) is refused as one. A user name alone, as `git@github.com` has, is kept.

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
| clone (W3) | `clone -- <url>`, into the runner's staging folder, with the new project's name |
| fetch, pull, push (W3) | `fetch --prune <remote>`, `pull <remote> <branch>`, `push [--set-upstream] <remote> <branch>` |
| the accounts, the SSH key (W3) | not git: the host's store (`accounts`, `removeAccount`) and `ssh-keygen` (`sshKey`, `createSshKey`, `deleteSshKey`) |

- **The parsers** (`core/git/`): porcelain v2 with the branch headers, ahead and behind, renames, conflicts and paths holding spaces, newlines or any UTF-8; `log`'s and `for-each-ref`'s fields; `diff-tree`'s pairs; and git's progress lines. Each is checked against fixtures of git's real output (`test/fixtures/git/`, 13 files, written with the host's own command lines) and fuzzed: nothing they are given makes them throw, and every file they read has a path.
- **The failures:** every error is a `GitFailure` with a `GitProblem`: the host's codes, and git's words read into what they mean (`core/git/git_errors.dart`): not a repository, a lock held, no identity, a conflict, local changes a switch would overwrite, a merge in progress, nothing to commit, no commits yet, a branch that exists, an invalid name, not fully merged, the current branch, no such branch. **W3's remote problems** come from the same reading: authentication refused, no credential given, no such repository, offline, a push the host rejected (fetch first), TLS refused, a host key that changed, no upstream, and a project name already taken. git speaks English here (`LANG=C.UTF-8`), and each pattern is checked against its real output (`errors.json`, and `remote_errors.json`'s 14 cases).
- **The fake:** `FakeGitService` (`services/fakes.dart`) keeps a repository in memory with the same contract, for the widget tests and `flutter test`.

### 3.2 The controller

`GitController` (`application/git/git_controller.dart`) holds the open workspace's repository state: `unavailable` (no host), `folder` (a folder from shared storage: Git works in projects only), `waiting` (the runtime is not ready), `loading`, `notARepository`, `repository` or `failed` (with the last status kept).

- **When the status is read:** after each operation, after a save (the open documents' stamps, never typing), on the file watcher's batches, on a change in the project's `.git` (whoever ran git, the terminal included), and on resume. Changes gather for 300 ms.
- **One status at a time:** a change while one runs reads it again once it ends; the newest result wins. In the background nothing runs.
- **Changes are queued,** one after another, each followed by a status.

### 3.3 In the app

- **The branch chip** in the status strip shows the branch, `*` when anything changed, and the warning colour on conflicts; its tooltip says the upstream, ahead and behind, and the counts. A detached HEAD shows the commit's short id.
- **Settings → Source control** (`/settings/source-control`) sets the name and email commits are made with, in the runtime home's `.gitconfig`, which the terminal's git shares. An empty field removes its key. **Since W3** it also lists the **accounts** — a host and a user name, never a secret, each with *Remove* — and CodeForge's **SSH key**: made here with a comment, its public half shown to copy into a host's settings, with *Remove*.
- **Home → Clone repository** (W3) takes a URL and the new project's name (offered from the URL), says why a URL cannot be cloned before anything runs, and shows the clone as it goes with *Stop*. The new project opens when it finishes.
- **Fetch, pull and push** (W3) run from the palette with the same progress sheet and *Stop*; the first push of a branch sets its upstream.
- **The prompts** (`features/git/credential_prompts.dart`) sit above every screen, so a question reaches the user wherever they are: a token for a host with *Remember*, or a new SSH host's fingerprint to accept. Each is answered once, a question its run no longer waits for closes by itself, and a stored token a host refused is removed and said.
- **The *Source control* panel** (W4, `features/workbench/panels/git_panel.dart`) is the activity bar's Git item: the same widget in the sidebar on a tablet and in the activity sheet on a phone. Its header has the branch, its upstream and how far ahead and behind, with *Fetch*, *Pull* and *Push*, each with the progress sheet and *Stop* the clone uses. Under it, *Changes* (always open, from the status), *Branches* and *History*, each with its count; the last two are read when they are first opened and again when the branch's commit changes. A change is a 48 dp row: the file, its folder, the letter of its state in that state's colour, and the buttons that fit it — resolve, unstage, discard or delete, stage. The commit box carries the message, *Amend the last commit* (which fills in the last message) and *Commit*, with one sentence under it when it cannot run. A merge that stopped lists its conflicts first, with *Abort the merge* beside the group. Everything that changes the repository goes through the Git controller, which queues it and refreshes the status; the panel's own reads live in `application/git/git_panel_controller.dart` (the branches, the last 100 commits, a commit's files, the identity), and keep the last good answer when a read fails.
- **The explorer's colours** (W4, `application/git/git_file_states.dart`): one map from path to the worst state Git gives it, so a file wears that state's colour with its letter after the name (`M`, `U`, `!`), a folder the worst state under it without a letter, and a renamed file shows at both ends. The colours are `features/git/git_state_look.dart`: conflicted and deleted `danger`, modified `warning`, renamed `info`, added and new `success`.
- **A folder from shared storage** (W4, decision (a)): the panel says Git works in projects and offers *Import as project*, which copies the folder's `.git` with everything else — including a pack file over the 64 MiB a run's copy allows per file, since the import's limits are 100,000 files and 4 GiB (`storage/FolderCopy.kt`, `CopyLimits.IMPORT`).

## 4. Security

- Git's commands run under the runtime's rules (SECURITY §2.1, E1 to E6), plus the host's own: the fixed set of operations, the fixed settings, paths inside the project, no repository found above the projects' folder, and logs without arguments, paths or URLs (§2.1 above).
- **Credentials** (W3, §2.4) reach git only through its credential helper and ssh only through askpass, both on that run's own FIFOs, with the helper named on the operation's own command line after `credential.helper=` clears every other (ADR-0016). A secret is never in a log, an argument, the environment, a plain file or a backup; it is sealed with a Keystore key that cannot leave the device. SECURITY §2.4 holds the threats and their proofs.
- **The network** is only HTTPS, SSH, and plain HTTP to this device; no submodule is fetched behind the user's back; a URL with a secret in it stops git (`transfer.credentialsInUrl=die`) and is refused before that anyway.

## 5. Measured

Through the host's runner with the runtime's own git (`GitHostTest`, phase gate 45626687240), on the runtime legs and Test Lab's phone:

| Measure | Emulators, API 26 to 36 | Pixel 8a |
|---|---|---|
| 10,000 new files: their status (140,000 characters, 5 batches of 2,000) | 21–300 ms | 116 ms |
| `add -A`, `commit` of them | 304–865, 426–973 ms | 1,032, 1,326 ms |
| The clean status of 10,000 files, p50 / p95 of 20 | 17–42 / 18–46 ms | 87 / 114 ms |
| A merge with a conflict | 13–43 ms | 81 ms |

W1's figures, through the launcher alone, are in ADR-0016: the phone's p95 of the same status was 134 ms there, so the host adds no cost a measurement sees. The app's budget (500 ms at p95 on the phone, with the parse and the panel) is W6's to judge.

**Remotes and credentials** (`GitRemoteTest`, phase gate 45682652174), against `git http-backend` with Basic authentication on 127.0.0.1, and the store on the real Keystore:

| Measure | Emulators, API 26 to 36 | Pixel 8a |
|---|---|---|
| A secret sealed into the store, then found and opened | 15–208 / 1–7 ms | 112 / 8 ms |
| A clone that asks the user, then one that takes the token from the store | 105–165, 99–158 ms | 282, 238 ms |
| Push, fetch, pull | 99–182, 75–147, 62–130 ms | 415, 475, 303 ms |
| A refused token: the run refused and the entry erased | 42–85 ms | 247 ms |
| A clone stopped while the user is being asked | 43–84 ms | 161 ms |
| An ed25519 key made with a passphrase through askpass | 121–202 ms | 432 ms |
| The token found in any file of the home, the project or the store | 0 | 0 |

GitHub over SSH is recorded, never judged (a network can fail): on every target its host key was asked about with the **published** ED25519 fingerprint, CodeForge's key was offered, and GitHub refused the unknown key, in 104–938 ms on the emulators and 1,185 ms on the phone.

## 6. Not built yet

- **W5:** diffs in the editor with `@codemirror/merge`; until then a tap on a change opens the file, as the long press does.
- **W6:** the Git gate on the emulator and the phone, with the budgets.
- **Out of scope for Phase 7:** hunk or line staging, interactive rebase, stash, tags, submodules, blame, a history graph, LFS, signing, a host's pull requests and issues, HTTPS through a proxy or with a private CA (PHASE_7_PLAN §8).
