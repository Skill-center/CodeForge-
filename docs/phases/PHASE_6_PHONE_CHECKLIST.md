# Phase 6 phone checks: the language servers on your phone

**Status:** ready for the owner, prepared in Phase 6 W7 (PHASE_6_PLAN W7, *The exit*). About 20 minutes on one phone. It can be done in the same sitting as [PHASE_3_PHONE_CHECKLIST.md](PHASE_3_PHONE_CHECKLIST.md), [PHASE_4_PHONE_CHECKLIST.md](PHASE_4_PHONE_CHECKLIST.md) and [PHASE_5_PHONE_CHECKLIST.md](PHASE_5_PHONE_CHECKLIST.md), with this checklist's APK, which has everything theirs has. Results go into [PHASE_6_REPORT.md](PHASE_6_REPORT.md) §8. Non-blocking for Phase 6's acceptance unless the owner decides otherwise.

The language servers have passed on five emulators (Android 8.0 to 16) and on Test Lab's Pixel 8a (PHASE_6_REPORT §4). Your phone adds what those can't:
- **Your keyboard against the completion list.** The phone's budget test never focused the editor, so no input method took part (PHASE_6_PLAN, *As built (W6)*). With Gboard, the editor's list of names appears over the text while Gboard shows its own suggestions above its keys. Does either hide the other, or take your typing?
- **Your finger.** A long press opens the symbol menu: what the server knows about a name, *Go to definition* and *Rename…*. The emulator's test pressed through adb.
- **Your phone's speed** for a server's first start and its first look at a file.

## 0. What you need

- An arm64 Android phone with Android 8.0 or newer and about 800 MB free.
- Gboard, or your usual keyboard (say which).
- **The APK:** the exit gate's `codeforge-phone-profile-arm64` artifact, the profile build with the arm64 runtime and both language servers. PHASE_6_REPORT §6 gives its link, its run and the date until which GitHub keeps it, once the exit gate has run. It is a zip holding one APK. Unzip it, open the APK on the phone, and allow "install unknown apps" for your browser or file manager when asked. With adb: `adb install codeforge-phone-profile-arm64.apk`.
- Uninstall any earlier CodeForge build first: every CI build is signed with its own throwaway key, so Android refuses to install over another one.

## 1. Install, and the first server (4 minutes)

1. Install the APK, open CodeForge, and open the demo project from Home.
2. Wait until the status strip's runtime chip shows a green `runtime` (the first install took 17.2 s through the app's startup path on the Pixel 8a, at Phase 4's exit).
3. Open `app.py`. Beside the language chip, a second chip names the server: **Pyright: starting**, then **Pyright: ready** (or **Pyright: analysing** while it reads the project). The first time, Pyright installs itself into the runtime first (3.65 s on the Pixel 8a).
   - **Write down:** about how long from opening `app.py` to **Pyright: ready**.
4. Open `main.js`. **Check:** the chip says **TypeScript: starting**, then **TypeScript: ready**.

## 2. Completion with Gboard (6 minutes)

1. In `app.py`, tap at the end of the last line (`print(…)`), press Enter, and type `forge.` with Gboard's keys. The new line keeps the indentation.
   - **Check:** the editor's list opens just after the `.`, offering `heat` and `temperature`, each with its icon. A red underline under the unfinished line is expected while you type.
   - **Check:** Gboard's keys and its suggestion strip stay where they are, and the list is not hidden behind them. If it opens above the line or is cut off, say where.
2. Type `he`. **Check:** the list narrows to `heat`. Tap `heat` in the list. **Check:** the line reads `forge.heat`, once, and the keyboard stays up.
3. Delete back to `forge.` and type `te`. Now **tap Gboard's own suggestion** in its strip, if it offers one (for example `temperature`, or another word). **Write down:** what the line reads after it: nothing doubled, nothing lost?
4. Delete back to `forge.` and type `he` again, then **press Gboard's Enter** while the list is open. **Write down:** whether Enter took `heat` from the list, or started a new line.
5. **Swipe a word** after `forge.`: swipe `heat`. **Write down:** what the line reads, and whether the list did anything odd.
6. Undo your changes (the palette's *Undo*, or close the tab and choose *Don't Save*).
7. **Write down:** anything that fought, flickered or was slow. The list took 139.0 ms at the 95th percentile on the Pixel 8a, on a project of 200 files, without a keyboard.

## 3. The long press: hover and definition (4 minutes)

1. In `app.py`, long-press `heat` in `forge.heat(50)`.
   - **Check:** the word is selected, and CodeForge's symbol menu opens with what Pyright knows about it (`heat`, with `delta: int` and `-> None`), then *Go to definition* and *Rename…*. Android's own copy menu may show as well; say if the two get in each other's way.
   - Tap **Go to definition**. **Check:** the cursor goes to `def heat` in the class.
2. In `main.js`, long-press `greet` in `console.log(greet(lang))`, then **Go to definition**. **Check:** `utils.js` opens at `export function greet`.
3. In `main.js`, long-press `log` in `console.log`, then **Go to definition**. **Check:** a sheet opens on TypeScript's own declarations (`lib.dom.d.ts`, where `console` is declared), at `log`, read-only: it can be read and scrolled, but not edited or saved. Close it.
4. **Write down:** anything in the menu that was cut off, hard to tap, or slow to come.

## 4. A rename across files (3 minutes)

1. Open `main.js` and `utils.js` in two tabs. In `utils.js`, long-press `greet`, then **Rename…**.
2. The dialog starts from `greet`. Type `welcome` and confirm.
   - **Check:** a message says "Renamed greet to welcome in 2 files" and names `main.js` and `utils.js`.
   - **Check:** `utils.js` says `export function welcome`, and `main.js` says `welcome` both in its import and in its call. If TypeScript kept the old name anywhere (for example `welcome as greet`), write down what each line says. The phone's runtime suite renamed a TypeScript method across two files, but this is the first rename of an imported function through the app; the app's own gate renamed across Python files.
3. Undo once in each tab (the palette's *Undo*). **Check:** each file says `greet` again, and nothing else changed. Save neither, or save both.
4. **Write down:** anything that didn't match.

## 5. Problems (3 minutes)

1. In `app.py`, add a last line `forge.cool(1)` inside the `if` block (indented like the lines above it).
   - **Check:** within a second or two, `cool` is underlined in red, and the status strip's problems chip shows **1** with an error icon.
   - Tap the underline. **Check:** Pyright's message names `cool` and `Forge`.
2. Tap the problems chip. **Check:** the *Problems* sheet lists the error under `app.py` with its line number. Tap it. **Check:** the sheet closes, and the cursor is on that line.
3. Delete the line. **Check:** the underline goes and the chip shows **0**, with no need to save.
4. **Write down:** how long the underline took to show and to go, roughly.

## 6. What to send back

- §1: how long Pyright took to be ready the first time.
- §2: the most important part: what Gboard's suggestions, its Enter and a swipe did with the list open, and anything that fought or was hidden.
- §3 to §5: each **Check** that did not hold.
- The phone's model and Android version, and your keyboard.
- Optionally, Settings → Linux runtime: each language server's memory, as the app shows it.
- Anything that looked wrong, unclear or slow, with a screenshot if you can.
