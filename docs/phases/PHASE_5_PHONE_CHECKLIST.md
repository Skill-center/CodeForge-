# Phase 5 phone checks: the terminal on your phone

**Status:** ready for the owner, prepared in Phase 5 W7 (PHASE_5_PLAN W7, *The exit*). About 35 minutes on one phone, ten of them waiting in §6. It can be done in the same sitting as [PHASE_3_PHONE_CHECKLIST.md](PHASE_3_PHONE_CHECKLIST.md) and [PHASE_4_PHONE_CHECKLIST.md](PHASE_4_PHONE_CHECKLIST.md), with the same APK. Results go into [PHASE_5_REPORT.md](PHASE_5_REPORT.md) §8. Non-blocking for Phase 5's acceptance unless the owner decides otherwise.

The terminal has passed on five emulators (Android 8.0 to 16) and on Test Lab's Pixel 8a (PHASE_5_REPORT §4). Your phone adds what those can't:
- **Your keyboard by hand.** The emulator's tests type through Android's input pipeline and replay scripted compositions; nobody has swiped on Gboard into the terminal.
- **Hybrid Composition++.** On Android 14 and later, with a Vulkan GPU, the app composes the editor's and the terminal's pages with it (since W6). The Pixel 8a measured it, but no test has tapped and typed through it with a real keyboard, and the emulator composes another way.
- **Your Android's own handling** of a long session in the background, of an app swiped away, and of a forced stop.

## 0. What you need

- An arm64 Android phone with Android 8.0 or newer and about 700 MB free. **§3 needs Android 14 or later;** on an older phone, skip it and say so.
- Gboard, or your usual keyboard (say which).
- **The APK:** on GitHub, signed in, [the artifact](https://github.com/Skill-center/CodeForge-/actions/runs/44900930980/artifacts/14707861503) downloads directly (otherwise **Actions →** run 44900930980 **→ Artifacts → `codeforge-phone-profile-arm64`**; kept until 2026-12-21). It is a zip holding one APK, the profile build with the arm64 runtime, 165 MB. Unzip it, open the APK on the phone, and allow "install unknown apps" for your browser or file manager when asked; with adb, `adb install codeforge-phone-profile-arm64.apk`. If you are doing the Phase 3 or Phase 4 checklist too, install this APK once for all of them. **Or the newer build** (Phase 6's exit gate, preferred): [the artifact](https://github.com/Skill-center/CodeForge-/actions/runs/45225412011/artifacts/14849775819), run 45225412011, kept until 2026-12-23. It adds the language servers, and [PHASE_6_PHONE_CHECKLIST.md](PHASE_6_PHONE_CHECKLIST.md) uses it too, so one install serves all four checklists.
- Uninstall any earlier CodeForge build first: every CI build is signed with its own throwaway key, so Android refuses to install over another one.

## 1. Install (3 minutes)

1. Install the APK, open CodeForge, and open the demo project from Home.
2. Wait until the status strip's chip says `runtime` (the first install took 17.2 s through the app on the Pixel 8a).
3. Tap the top bar's terminal button (*Toggle terminal*). The panel opens at half height with a terminal. If there is none, tap **+** (*New terminal*).
4. **On Android 13 and later, Android asks to allow notifications: allow them.** §6 needs the notification. If you decline, sessions still run, without it.

## 2. Gboard and the extra keys in the terminal (8 minutes)

1. Tap in the terminal. **Check:** Gboard comes up, and the prompt has the cursor.
2. Type `echo hello world` with Gboard's keys, then Enter. **Check:** the line reads exactly that, and `hello world` comes back.
3. Type the same again, with Gboard's other ways if you use them: swipe `hello` and `world`; tap a suggestion if Gboard offers one; try voice typing if you like. **Check:** the terminal shows exactly what Gboard put in, with nothing doubled, missing or out of order. Gboard's text garbled this way on the emulator in W3 until the page took it over; it has passed there since.
4. **The extra-keys row** above the keyboard:
   - Type `ec`, then the row's **Tab**: bash completes `echo`.
   - The row's **↑**: the last command comes back. **↓** clears it again.
   - Type `ls ` then the row's **~**, then a space, **|** and ` head` (with the row's `|`), Enter. **Check:** a short list comes back.
   - Type `sleep 30`, Enter, then tap the row's **Ctrl** (it stays highlighted) and type `c` on Gboard. **Check:** `^C`, and the prompt is back at once. Ctrl is no longer highlighted.
5. **Copy and paste:** long-press a word in the output. It is selected, and the row shows **Copy**. Tap it, then the row's **Paste**. **Check:** the word is typed at the prompt. Clear the line with Ctrl, then `u`.
6. **Write down:** anything lost, doubled, garbled or slow; any key of the row that did nothing.

## 3. Taps and typing through Hybrid Composition++ (Android 14 or later; 5 minutes)

The app doesn't show which composition it uses. On Android 14 and later with a Vulkan GPU, most recent phones, it is Hybrid Composition++, as on the Pixel 8a.

1. **The editor:** open `main.js`.
   - Tap in the middle of a word. **Check:** the cursor lands where you tapped.
   - Type a line with Gboard, by keys and by a swipe. **Check:** it appears as typed, where the cursor was.
   - Long-press a word. **Check:** it is selected, with both handles and Android's menu, in the right place.
   - Scroll with a finger. **Check:** the text follows your finger, with nothing drawn wrongly: no black or flickering areas, no text out of place, no frozen screen.
   - Undo your line (Ctrl+Z on a hardware keyboard, or the palette's *Undo*).
2. **Back and forth:** tap the terminal and type `ls`, tap the editor and type a letter, tap the terminal again. **Check:** each time the keyboard's text goes where you tapped last, and the keyboard stays up.
3. **Maximized:** the terminal's menu (⋮) → **Maximize**. Type and scroll there, then **Restore size**. **Check:** the same as above.
4. **Write down:** your Android version; any tap that landed elsewhere, text that went to the other pane, a keyboard that didn't come up, or anything drawn wrongly.

## 4. nano across a turn (3 minutes)

1. In the terminal: `nano notes.txt`, then type two or three lines.
2. **Turn the phone to landscape.** **Check:** nano draws again at the new size, with its title on top, its help lines at the bottom and your text intact.
3. **Turn it back.** **Check:** the same, in portrait.
4. Save and leave: the row's **Ctrl** then `x`, then `y` and Enter. `cat notes.txt` shows your lines.

## 5. A run (4 minutes)

1. Open `main.js`, then the bottom bar's **Run**, and tap **Run main.js**.
   - **Check:** a terminal tab named for the run shows three lines, `Hello from JavaScript!`, `Hello from Python!` and `Hello from Dart!`, and the run's chip says **Exit 0**.
2. Open `app.py` and run it the same way. **Check:** `Forge at 1250°C`, and **Exit 0**.
3. **A link:** in `main.js`, add a last line `throw new Error('boom');`, then run it. Unsaved changes are saved first.
   - **Check:** the output ends with a stack trace naming `main.js` with a line number.
   - Tap that `main.js:…` in the output. **Check:** the editor opens `main.js` at that line.
   - Remove the line and save.
4. **Run project…** → `start` (`npm run start`). **Check:** the same three lines, and **Exit 0**.
5. **Write down:** anything that didn't match; how long the first run took to show its output.

## 6. A long session in the background (10 minutes, mostly waiting)

1. Open a new terminal and start a heartbeat: `while true; do date +%T; sleep 1; done`.
2. Press Home, and use other apps or lock the phone for **about 10 minutes**.
3. Pull down the notifications. **Check:** CodeForge's notification says how many sessions run (each open terminal tab with its shell counts), with **End all**.
4. Come back to CodeForge. **Check:** the heartbeat's tab is drawn again and still printing. Scroll up a little: the times go on with no gap over a second or two.
5. **Swipe CodeForge away** in the recent apps, with the heartbeat running.
   - **Write down:** whether the notification is still there.
   - Open CodeForge and the demo project again: is the heartbeat's tab still printing, or does it say how it ended? Nothing has measured this yet.
6. In the notification, tap **End all** (if it has gone, use the terminal's menu → **End all**). **Check:** every tab says it ended, and the notification goes.

## 7. The tombstones after process death (3 minutes)

1. Open a new terminal and type `exit 7`. **Check:** the tab stays, saying it exited with code 7.
2. Open another terminal and type `sleep 600`.
3. **Force the app to stop:** Android Settings → Apps → CodeForge → **Force stop**, and confirm. Android then ends the app's processes, the sessions' included.
4. Open CodeForge, the demo project and the terminal.
   - **Check:** the first tab says **exited with code 7**, and the second **ended by the system**.
   - **Check:** the notification is gone, and **+** opens a new terminal that works.

## 8. What to send back

- §2: anything lost or garbled, and the keys that worked.
- §3: your Android version, and anything that went wrong with taps, typing or drawing (or "skipped: Android 13 or older").
- §4 to §7: each **Check** that did not hold. In §5, how long the first run took. In §6, what swiping the app away did.
- The phone's model and Android version, and your keyboard.
- Anything that looked wrong, unclear or slow, with a screenshot if you can.
