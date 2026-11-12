# Phase 3 exit session: every parked phone check

**Status:** ready for the owner's session. Prepared in Phase 3 W7, as the owner decided on 2026-11-11: one session at Phase 3's exit, with every check parked since Phase 1 ([ROADMAP.md](../ROADMAP.md), *Parked owner checks*). Results go into [PHASE_3_REPORT.md](PHASE_3_REPORT.md) §8. Non-blocking for acceptance unless the owner decides otherwise (PHASE_3_PLAN.md §5) · **Build:** the `codeforge-phone-profile-arm64` artifact of phase gate [43284276984](https://github.com/Skill-center/CodeForge-/actions/runs/43284276984) (commit a78cbee, Phase 3's final app), kept until 2026-12-12 · **Time:** about 75 minutes, in any number of sittings; do §9 last.

The emulator gate runs every group on each `[phase-gate]` commit. A phone adds what an emulator can't: a real ARM CPU and GPU (Impeller draws with it), your Android's own folder picker, your keyboard, TalkBack, and a real Google account.

## 0. What you need

- An arm64 Android phone, Android 8.0 or newer. Update **Android System WebView** (or Chrome) from the Play Store first.
- Your usual keyboard (Gboard if you have it). A Chinese pinyin input language is optional (§5).
- For §9: device backup on (Android Settings → Google → Backup) with your Google account.
- **Optional, for §8:** a computer with adb (Android's platform-tools) and the phone's USB debugging on. Without one, skip §8; everything else needs only the phone.

## 1. Install

1. On GitHub, signed in: [the artifact](https://github.com/Skill-center/CodeForge-/actions/runs/43284276984/artifacts/13975424637) downloads directly. Otherwise go to **Actions → Phase gate →** run 43284276984 **→ Artifacts → `codeforge-phone-profile-arm64`**. It is a zip holding one APK.
2. **Uninstall any earlier CodeForge build first.** Every CI build is signed with its own throwaway key, so Android refuses to install over another one.
3. Unzip, open the APK on the phone, and allow "install unknown apps" for your browser or file manager when asked. With adb: `adb uninstall dev.codeforge.app`, then `adb install codeforge-phone-profile-arm64.apk`.
4. **Keep the APK file:** §9 installs this same file again.

This is a profile build: optimised like a release, with a Developer section in Settings. The debug build of the same commit is the `codeforge-debug-apk` artifact of CI [43284276980](https://github.com/Skill-center/CodeForge-/actions/runs/43284276980) (all ABIs, kept until 2027-02-10); no check below needs it.

## 2. Impeller on your phone (5 minutes; Phase 3 W6)

Since Phase 3 W6 the app draws with Impeller, Flutter's default renderer, instead of Skia. On the CI emulator it passed every group, but that emulator draws in software.

1. Move around for a minute: Home, the demo project, the explorer, a few files, the command palette, Settings and its sections, a dialog (Home → ⋯ on a project → Rename…), and back.
   - Does anything draw wrongly: black or flickering areas, missing text or icons, a frozen screen, or the editor's text misplaced while you scroll?
2. **Frame timing:** Settings → DEVELOPER → **Frame timing → Reset**. Move around for about 30 seconds as in step 1, switching editor tabs too. Come back to **Frame timing → Copy** and keep the text for the report. On Skia, Phase 1 measured 3.4 % of frames over 32 ms on a realme C51.

## 3. Folders on your phone (10 minutes; Phase 3 W2, W3, W5)

Your phone's folder picker may differ from the emulator's.

1. Make a folder for the test with a file manager, for example `Documents/cf-test`, with one text file in it (`hello.txt`, a line of text).
2. CodeForge → Home → **Open folder**. Android's picker opens: go to `cf-test`, tap **Use this folder**, then **Allow**.
   - The workbench opens on the folder, and the explorer lists `hello.txt`.
3. Open `hello.txt`, type a line, **Save** (Ctrl+S, or the palette's *Save*). Check the file in your file manager: it holds your line.
4. **Outside changes:** with `hello.txt` open and saved in CodeForge, change it in another app (a text editor, or rename and rename back is not enough: change its text) and come back.
   - Within about 2 seconds of returning, CodeForge shows the new text and says the file was reloaded.
   - Now type a line in CodeForge without saving, change the file again in the other app, and come back: CodeForge keeps your text and shows a banner with *Keep mine* and *Use the file*.
5. **Restart:** swipe CodeForge away from the recent apps, then open it again. The folder comes back with its tab, and with your unsaved line if you left one.
6. **A folder that moved:** go Home. In your file manager rename `cf-test` to `cf-test2`. Back in CodeForge, the folder's row in the recents should say *folder missing* or *access lost* (it may need a moment, or a trip into Settings and back).
   - Tap ⋯ on the row → **Reconnect…**. The picker should open at or near the old place. Pick `cf-test2`, then confirm the replacement. The folder opens with its files.
7. Home → ⋯ on the folder → **Remove from recents**. The row goes away, and the files stay in your file manager.
8. **Send back:** whether each step behaved as described, your phone's model and Android version, and anything the picker did differently (extra screens, a different *Allow* question).

## 4. Large files with the policy (10 minutes; Phase 2 W7, ADR-0004)

1. **Settings → DEVELOPER → Create large test files.** Wait for the row to read "Wrote 7 files (… MB) to large-files/". The files are the gate's, byte for byte.
2. Open the demo project, then in the explorer open **large-files**:
   - `large_512kb.js` opens highlighted.
   - `large_1mb.js` opens as plain text, with a banner offering *Highlight anyway*. Tap into the middle, type a line, and fling-scroll: is it smooth? Then try *Highlight anyway*.
   - `large_10mb.txt` opens as plain text. Type a character and **Save**: does the app pause visibly while it saves? (This is ADR-0008's save pause.)
3. **Settings → DEVELOPER → Editor benchmark → Run benchmark**, and leave the phone alone for about 2 minutes. The results include a line "as plain text" for the 1 MiB file. Tap the **copy icon** (top right) and keep the text.
4. **Send back:** the benchmark JSON, one sentence per file on typing and scrolling, and whether saving 10 MiB paused.

## 5. Your keyboard in the editor (10 minutes; Phase 2 G1, the Gboard matrix)

In **Settings → DEVELOPER → Editor benchmark**, for **CodeMirror** (the engine CodeForge uses), and for **Monaco** if you have time:

1. Tap **Typing check**. An empty editor opens, with the phrase to type underneath.
2. For each phrase in the dropdown, tap into the editor, type it the way you normally type (suggestions and autocorrect on), then tap **Check**. The screen shows **Match**, or **Differs at character N** with what the editor holds. **Clear** empties it for another try.

   | Phrase | Type |
   |---|---|
   | Code with symbols | `const total = items.map((x) => x * 2);` |
   | Words (swipe or suggestions) | `hello world from codeforge`, by swiping or picking suggestions if you use them |
   | Emoji | `ok 👍🏽 done 😀`, the thumbs-up with a skin tone |
   | Chinese (pinyin keyboard) | `你好，世界`. Skip it without a Chinese keyboard |
   | Voice (optional) | dictate `hello world` with the keyboard's microphone |

   Gboard often adds a space after a picked suggestion; delete it before **Check**.
3. Tap **Done**, then the **copy icon**, and keep the results.

## 6. Selection, copy and paste, undo and redo (10 minutes; Phase 2 W6)

Run [PHASE_2_SELECTION_MATRIX.md](PHASE_2_SELECTION_MATRIX.md) from its §1 on this build (skip its §0: the app is installed). It has its own table of results.

## 7. TalkBack (15 minutes; Phase 1, Phase 2 and Phase 3 chrome)

Turn TalkBack on (Android Settings → Accessibility). Swipe right to move to the next item, double-tap to activate.

1. **Home:** the welcome sheet (if shown) is read in order. *Open folder*, *New project* and each recent are announced as buttons. Each recent reads its name, kind, place and any status (*missing*, *folder missing*, *access lost*), and its ⋯ button is named.
2. **Home's dialogs** (New project, and on a project's ⋯: Rename…, Delete…): the title, the field and the buttons are read in order.
3. **Workbench, phone portrait:** each activity-bar item announces its name and selected state, and the top bar's buttons are named.
4. **Tabs:** each tab reads its file name, and the active one is announced as selected. Type into a file without saving: its tab reads "*name*, unsaved changes". Each close button reads "Close" and the file name.
5. **Explorer sheet:** rows announce name and expanded or collapsed state; double-tap toggles. Long-press a row: the menu's items are read (New File … Delete).
6. **Command palette and Go to File:** the input is labelled, results are announced, and activating one runs it.
7. **Find bar:** the fields are labelled; match case, whole word and regular expression announce their state; the buttons are named.
8. **Symbol toolbar:** each key announces what it types or does.
9. **Large-file banner** (`large_1mb.js` from §4): read in full, *Highlight anyway* announced as a button.
10. **Outside-change banner** (§3 step 4): read in full, with *Keep mine* and *Use the file* as buttons.
11. **Dialogs:** the close prompt (Save / Don't Save / Cancel), Save As and Go to line read their title, field and buttons in order.
12. **Settings:** the theme selector announces its selection, the font-size slider its value, and each switch its state. **Privacy:** *Back up with Android* reads as one item with its state and text.
13. **Back:** from the workbench or Settings, back returns Home; from Home, back leaves the app.
14. **Text size 130 % and 200 %** (Android display settings): no clipped or overlapping labels on Home, the workbench and Settings.
15. **Landscape:** the navigation rail's items announce name and selected state.
16. **Soft keyboard** (TalkBack can be off): open the palette so the keyboard appears; the workbench behind it stays intact.

**Send back:** the item numbers that failed, with what TalkBack said.

## 8. With a computer and adb (10 minutes; optional)

Connect the phone with USB debugging on, and check `adb devices` lists it.

**Renderer.** Start CodeForge, then run `adb logcat -d | grep -i "rendering backend"` (PowerShell: `adb logcat -d | Select-String "rendering backend"`). It should say `Impeller` and the backend (`Vulkan` or `OpenGLES`).

**Cold start** (G7's budget: 1500 ms on a mid-range phone, median of 10). Start the app once and close it, then:

```sh
for i in 1 2 3 4 5 6 7 8 9 10; do
  adb shell am force-stop dev.codeforge.app
  adb shell am start -W -n dev.codeforge.app/.MainActivity | grep TotalTime
done
```

PowerShell: `1..10 | % { adb shell am force-stop dev.codeforge.app; adb shell am start -W -n dev.codeforge.app/.MainActivity | Select-String TotalTime }`. Keep the ten `TotalTime` lines. This is a profile build; a release build starts no slower, so a profile median within the budget means the release one is too. On the CI emulator, Impeller's medians were 1302 to 1688 ms and Skia's 961 to 1067 ms (PHASE_3_REPORT §7.2).

**Memory** (ADR-0004's budget: 250 MB, app and WebView together). Open `large_1mb.js` from §4 and wait 10 seconds, then:

```sh
adb shell dumpsys meminfo dev.codeforge.app | grep "TOTAL PSS"
adb shell ps -A -o PID,NAME | grep sandboxed_process
```

Then, for each process id the second command printed: `adb shell dumpsys meminfo <id> | grep "TOTAL PSS"`. The sum is the figure the gate reports (230.3 MB in the final gate, a release build on the emulator). Keep all the lines.

**FULL against NORMAL** (ADR-0008) times the database on the phone's flash. It runs the repository's large-file integration test, which needs Flutter 3.47.9 and the repository on the computer (`flutter test integration_test/large_files_test.dart -d <device>`, from `app/`). Skip it unless you have them; PHASE_3_REPORT §8 proposes moving it to Phase 4's Firebase Test Lab runs.

## 9. Backup with your Google account (15 minutes; Phase 3 W1, ADR-0012; do it last)

This check uninstalls the app twice, so it erases what the steps above created. **Reinstall the same APK file each time:** Android restores data only into an app signed with the same key.

1. CodeForge → **Settings → PRIVACY.** *Back up with Android* should be off, and the row should read "Off".
2. Turn it on. Open the demo project, type a line into `main.js` without saving, and create a file with a few words in it, saved.
3. Android Settings → Google → Backup → **Back up now**, and wait until it finishes. The Privacy row should now read "On · last backup run …", with "end-to-end encrypted" if the phone has a screen lock.
4. Uninstall CodeForge, install the same APK again and open it. The demo project should come back with the saved file and with `main.js` still unsaved, holding your line. The Privacy row should read "On".
5. Turn the switch off, then **Back up now** again. Uninstall, install the same APK and open it. The app should be fresh (the welcome screen), and the Privacy row should read "Off · the last backup held only this setting".
6. **Send back:** the Privacy row's text after steps 1, 3, 4 and 5, and whether steps 4 and 5 came back as described.

## 10. What to send back

- The phone's model and Android version (Settings → About phone), and the WebView version (the benchmark's results include it).
- §2: anything drawn wrongly, and the frame-timing text.
- §3: each step's result, and how your picker differed.
- §4 and §5: the two JSON results, and your sentences on typing and scrolling.
- §6: the selection matrix's table.
- §7: the TalkBack items that failed.
- §8 (if run): the renderer line, the ten `TotalTime` lines and the memory lines.
- §9: the Privacy row's four texts, and steps 4 and 5's results.

## 11. Runs

| Run | Date | Phone | Build | Result |
|---|---|---|---|---|
| — | — | — | — | not run yet |
