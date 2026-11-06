# Phase 2 phone checklist: editor engines (ADR-0004) and frame timing

**Status:** Run 1 done on 2026-11-06 (§7), and the checklist is reusable for later builds. Non-blocking for Phase 2 acceptance (PHASE_2_PLAN.md §5) · **Build:** the `codeforge-phone-profile-arm64` artifact of phase gate [42216855184](https://github.com/Skill-center/CodeForge-/actions/runs/42216855184) (commit 58d91fa, with the selection fix and the typing-check instructions), kept until 2026-12-06. Run 1 used the earlier build from gate 42206498197 · **Time:** about 10 minutes

The emulator gate measures both editor engines under scripted input. A phone adds what an emulator can't: a real ARM CPU and GPU, the real Android System WebView, and your keyboard with its predictions, autocorrect, emoji and (optionally) Chinese input. Nothing here needs a computer except the download.

## 0. What you need

- An arm64 Android phone with Android 8.0 or newer. Update **Android System WebView** (or Chrome) from the Play Store first; the benchmark reports its version.
- Your usual keyboard. A Chinese pinyin input language in Gboard is optional (§3).

## 1. Install

1. On GitHub, signed in: [the artifact](https://github.com/Skill-center/CodeForge-/actions/runs/42216855184/artifacts/13502173377) downloads directly. Otherwise go to **Actions → Phase gate →** run 42216855184 **→ Artifacts → `codeforge-phone-profile-arm64`**. It is a 20 MB zip holding one APK.
2. **Uninstall any earlier CodeForge build first.** Every CI build is signed with a different throwaway key, so Android refuses to install over an older one.
3. Unzip, open the APK on the phone, and allow "install unknown apps" for your browser or file manager when asked.

With adb instead: `adb uninstall dev.codeforge.app`, then `adb install codeforge-phone-profile-arm64.apk`.

This is a profile build: optimised like a release, but with a Developer section in Settings.

## 2. Run the benchmark (about 2 minutes, hands off)

1. Open CodeForge → **Settings →** scroll to the end → **DEVELOPER → Editor benchmark**.
2. The status line should read "Ready: codemirror and monaco."
3. Tap **Run benchmark** and leave the phone alone. Each engine runs 3 times in a fresh page (6 runs), and you can watch each page work.
4. When it reads "Finished 6 of 6 runs.", the screen lists per engine: first frame, typing p50/p95, 1 MiB open, 1 MiB typing p95, scroll frames over 32 ms, and whether features and highlighting passed.

## 3. Typing check (each engine, your keyboard)

Do this for **CodeMirror**, then for **Monaco** (the selector next to the buttons):

1. Tap **Typing check**. An empty editor opens, with the phrase to type underneath.
2. For each phrase in the dropdown: tap into the editor, type the phrase exactly as shown, the way you normally type (suggestions and autocorrect on), then tap **Check**. The screen repeats this instruction above the phrase. Under the buttons it shows **Match**, or **Differs at character N** with what the editor actually contains. **Clear** empties the editor for another try.

   | Phrase | Type |
   |---|---|
   | Code with symbols | `const total = items.map((x) => x * 2);` |
   | Words (swipe or suggestions) | `hello world from codeforge`, by swiping or picking suggestions if you use them |
   | Emoji | `ok 👍🏽 done 😀`, the thumbs-up with a skin tone from the emoji keyboard |
   | Chinese (pinyin keyboard) | `你好，世界`: "nihao" → 你好, the full-width comma "，", "shijie" → 世界. Skip it without a Chinese keyboard |

   Gboard often adds a space after a picked suggestion. Delete it before **Check**, or it shows as a difference. The copied results contain the exact text either way.
3. While you type, note your impressions:
   - Does the cursor jump, or do characters go missing or appear twice? Does a word double after autocorrect?
   - Long-press a word: do the selection handles appear, and can you drag them? Copy the selection and paste it somewhere else in the editor.
   - Fling-scroll the editor (paste the phrase a few times first): is it smooth?
4. Tap **Done**. Each check also records how long your keystrokes took to reach the screen, shown as "input p95 … ms" in the results.

## 4. Copy the benchmark results

Tap the **copy icon** at the top right ("Copy results"), then paste into the chat. The JSON holds every run, every typing check and the WebView's user agent.

## 5. Frame timing (about 1 minute; closes the parked Phase 1 G6 check)

1. **Settings → DEVELOPER → Frame timing → Reset.**
2. Go back and move around the app for about 30 seconds: home, workspace, settings, opening and closing the terminal panel and the command palette, and switching editor tabs.
3. Come back to **Frame timing → Copy**, then paste into the chat.

## 6. What to send back

- The two JSON results: the benchmark from §4 and frame timing from §5.
- The phone model and Android version (Settings → About phone).
- Your impressions from §3, per engine: one sentence each on cursor and characters, selection handles, copy and paste, and scrolling.

## Notes

- A profile build exposes no DevTools connection, so the phone gives in-page timings and your typing checks. Memory and the scripted composition cases come from the emulator gate.
- **Optional:** the parked Phase 1 TalkBack checklist (PHASE_1_REPORT.md §8) runs on this same APK if you have a few more minutes.

## 7. Runs

| Run | Date | Phone | Build | Result |
|---|---|---|---|---|
| 1 | 2026-11-06 | realme C51 (RMX3830: Unisoc T612, 4 GB, Android 13) | gate 42206498197, profile arm64 | Benchmark: CodeMirror 6 met cold load and typing on this low-end phone, and Monaco did not beat it (ADR-0004, now Accepted). Frame timing: 3.4 % of frames over 32 ms, which completes Phase 1 G6. The selection bug found here was fixed. The typing check's instructions were unclear and are now on screen. Evidence: [phase2-phone-2026-11-06](evidence/phase2-phone-2026-11-06/README.md) |
