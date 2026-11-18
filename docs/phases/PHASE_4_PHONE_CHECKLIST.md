# Phase 4 phone checks: the runtime on your phone

**Status:** ready for the owner, prepared in Phase 4 W7 (PHASE_4_PLAN W7, *The exit*). About 20 minutes on one phone, best done in the same sitting as [PHASE_3_PHONE_CHECKLIST.md](PHASE_3_PHONE_CHECKLIST.md), with the same APK. Results go into [PHASE_4_REPORT.md](PHASE_4_REPORT.md) §8. Non-blocking for Phase 4's acceptance unless the owner decides otherwise.

The runtime has passed on five emulators (Android 8.0 to 16) and on Test Lab's Pixel 8a (PHASE_4_REPORT §4). Your phone adds what those can't: your own device's storage speed and Android build, and a person looking at the screens.

## 0. What you need

- An arm64 Android phone with Android 8.0 or newer, and about 700 MB free. On the emulator, the app (a debug build, 212 MB), its extracted libraries (140 MB) and the installed runtime (275 MB, 13,894 files) took 627 MB together (phase gate 44275357542). The phone's profile build is smaller (about 164 MB).
- **The APK:** the `codeforge-phone-profile-arm64` artifact of Phase 4's last phase gate (PHASE_4_REPORT §6 has the link). It carries the runtime for arm64. If you are doing the Phase 3 checklist too, install this APK once for both.
- Uninstall any earlier CodeForge build first: every CI build is signed with its own throwaway key, so Android refuses to install over another one.

## 1. The first install (5 minutes)

1. Install the APK, open CodeForge, and open the demo project from Home.
2. The status strip at the bottom shows `installing` with a percentage. **Check:** the editor works while it installs (type a few characters).
3. When the strip's chip turns into a green `runtime` (long-press it for *Runtime ready*), open **Settings → Linux runtime**.
4. **Write down:**
   - **Status:** it should say *Ready · every program comes from the app*.
   - **Timing → Install:** the seconds it took to extract and verify every file. The budget is 60 s on a mid-range phone; the Pixel 8a took 13.6 s.
   - **Program check:** it should say *0 programs outside the app*, with how many came from the app and how long the check took.
   - **Storage → Space used:** tap *Measure*, and note the result.

## 2. The warm start (3 minutes)

1. Close CodeForge from the recent apps (swipe it away), then open it and the demo project again.
2. In **Settings → Linux runtime**, **write down Timing → Start**: the milliseconds a start took with nothing extracted. The budget is 100 ms; the Pixel 8a took 73 ms.
3. **Check:** *Program check* still says *0 programs outside the app*.

## 3. The tools (3 minutes)

1. On the same page, under **Tools**, wait for the check to finish.
2. **Check:** the summary says *All 7 tools are their pinned versions*, and each row (node, python, git, bash, perl, ruby, rg) shows its version beside its pin: node 26.13.1, python 3.14.10, git 2.56.1, bash 5.3.9, perl 5.44.0 (package 5.44.0-1), ruby 4.0.9, rg 15.2.0.
3. **Write down** the time the check took (*Each run once in … ms*). On the Pixel 8a, the instrumented test ran the seven in about 1 s.

## 4. Search (5 minutes)

1. **In a project:** open the demo project, then the Search panel. Search for `function`.
   - **Check:** two results arrive, one in `main.js` and one in `utils.js` (unless you changed the demo files); a tap opens the file with the cursor at the match.
   - Search for `Function` with *Match case* on: nothing is found. Turn it off: the two come back.
2. **In a folder from your phone's storage** (the Phase 3 checklist's §3 folder will do): open it from Home, then search for a word you know is in it.
   - **Check:** results arrive as files are read, and *Stop* stops it, keeping what was found.
   - **Write down** roughly how long a search of the whole folder took, and how many files it has. This is CodeForge's own scan; the emulator read 1,000 small files in about 4.6 s, and Test Lab can't open a folder.

## 5. The report (2 minutes)

1. On **Settings → Linux runtime**, tap the copy button at the top (*Copy the runtime report*).
2. Paste it into your message. It holds the status, the times, the audit and the tools, so nothing has to be typed.

## 6. What to send back

- The four figures from §1, the start time from §2, the tools' time from §3, and the folder search from §4.
- The pasted runtime report (§5).
- The phone's model and Android version.
- Anything that looked wrong, unclear or slow, with a screenshot if you can.
