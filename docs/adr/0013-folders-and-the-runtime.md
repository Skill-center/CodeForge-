# ADR-0013: How a folder from shared storage reaches the runtime

**Status:** Accepted · 2026-11-18 · Phase 4 W6 ([PHASE_4_PLAN.md](../phases/PHASE_4_PLAN.md) W6, which assigns this decision to W6), with the copy measured on the gate's folder · decided by the agent, as the plan asks; the owner can change it before Phase 5 builds it with *Run*

## Context
- **A folder workspace has no path a program can open.** It is a tree the user picked in Android's folder picker, reached through the Storage Access Framework (SECURITY §4.1): `content://` documents behind a documents provider, which only the storage broker reads and writes. The app asks for no storage permission (SECURITY S7).
- **The runtime's programs need real paths.** A script imports its neighbours, reads its data and writes its output, and node, python and the shell find all of it through the file system. ripgrep cannot search such a folder either: W6's folder search is CodeForge's own scan, in Kotlin, through the broker.
- **A project can run where it is.** Projects live in `<filesDir>/workspaces/<name>`, real paths in the app's storage. Since W6 the runtime's ripgrep runs in them (SECURITY §2.1, E3).
- **What Android offers, and why none of it serves:**
  - all-files access (`MANAGE_EXTERNAL_STORAGE`): Play allows it for file managers, backup and antivirus apps and the like, not an editor, and it would undo S7;
  - one file descriptor per document (`openFileDescriptor`, then `/proc/self/fd/N`): one file at a time, with no folder around it, so nothing a program can open by name;
  - FUSE: not available to apps.
- **So a folder's files must become files in the app's storage** before anything runs on them. The question is when the copy is made, and which way changes flow. RUNTIME_INTEGRATION §4 expected "import/export + edit, with runtime execution offered via workspace copy" and left the choice to Phase 4 (PHASE_3_PLAN §8).

## Options
- **(a) Run in a copy.** Before a run, the folder is copied one way into the app's storage, into a hidden copy of its own. The program runs there, and what it writes stays there until the user exports it. The folder stays the workspace and the source of truth, and the editor keeps editing it in place.
- **(b) Import and export.** The user imports the folder as a project, a full copy, and works in the project from then on. An explicit export writes the project back to the folder, or to another.
- **(c) Two-way sync**, a copy whose changes flow back by themselves. Rejected: a document cannot be replaced atomically (SECURITY S6), so a run that fails halfway, or another app editing the same file, would leave the folder half-written. Nobody asked for the folder to change behind their back.

## Measured (the gate's folder, phase gates 44264577788 and 44275357542)
The gate's search group copied the gate folder into the app's storage after scanning it (`app/ci-results/gate/search.txt`), on the emulator:

| What | Phase gate 44264577788 | Phase gate 44275357542 |
|---|---|---|
| The folder | 1,008 files in 7 folders, 4,065 bytes (`many/`'s 1,000 small files, the fixture, a binary file) | the same |
| **The copy** through today's broker, from Dart, one file at a time (`StorageBroker.list` and `read`, `dart:io` writes) | **6,177 ms, about 6.1 ms a file** | **9,917 ms, about 9.8 ms a file** (a slower emulator: see below) |
| For comparison: the scan reading the same files in Kotlin | 5,115 ms, one at a time (median of 3) | 4,610 ms, four at a time (median of 3) |
| For comparison: ripgrep searching a project of 10,000 files in the app's storage | 96 ms in the host (median of 3) | 131 ms in the host (median of 3) |

The copy's code did not change between the two gates, so its two figures show how much the emulator's speed varies from run to run. On a Pixel 8a (Test Lab, CI 44275357542) ripgrep searched the same 10,000-file project in 89 ms in the host; Test Lab cannot answer the folder picker, so the copy has no phone figure yet.

The cost is the provider's, not the bytes: each file is an open that the documents provider answers, and the files here are a few bytes each. A copy is bound by the number of files, not their size.

## Decision
- **(a) Run in a copy** is how a folder reaches the runtime. It keeps the folder the user chose as the workspace, and it changes nothing about editing.
  - **Incremental:** only files whose size or modified time changed since the last copy are copied again, and files gone from the folder are removed from the copy. The first run pays for the whole folder; later runs pay for a listing and the changes.
  - **In Kotlin, several files at a time:** the figure above, a Pigeon round trip per file from Dart, is an upper bound. Phase 5 copies inside the host, reading ahead as W6's scan does (four files at a time through the provider; *As built (W6)* in PHASE_4_PLAN).
  - **One way:** a run's output stays in the copy. The Run panel lists the files a run created or changed, and exports what the user picks (Phase 5's design).
  - **Limits:** the copy leaves out `.git`, as search does. Phase 5 sets its size and count caps from measurements on the devices, and the copy says what it left out.
- **(b) Import as a project** is offered beside it, for folders that need more than a copy gives: git (Phase 7), dependencies installed into the tree (`node_modules`), or very large trees, whose first copy would be long. Export writes back explicitly.
- **Phase 5 builds both, with *Run*.** Until then nothing runs in a folder, and W6's search scans it without a copy.

## Consequences
- The editor keeps working on the folder itself, as today. Running is what makes a copy.
- A large folder's first run is slow. At the gates' 6 to 10 ms a file, a folder of 10,000 small files would take one to two minutes through today's broker, and much less in the host with reads ahead. Later runs cost the listings (the gate's 1,000-entry folder lists in 396 ms, the median of three in the same gate's measure group; 477 to 583 ms in PHASE_3_REPORT §7) plus the changes.
- A program's writes never reach the folder by themselves. That is honest and explicit, but the user must export, and the Run panel must make that plain.
- git in a folder stays Phase 7's spike (RUNTIME_INTEGRATION §4); with (b), an imported project has git's real files.
