# Phase 2 selection matrix (W6): selection, copy and paste, undo and redo on a phone

**Status:** ready for run 1. Non-blocking for Phase 2 acceptance: the phone confirmations stay on the parked list (PHASE_2_PLAN.md §5) · **Build:** the `codeforge-phone-profile-arm64` artifact of phase gate [42517731718](https://github.com/Skill-center/CodeForge-/actions/runs/42517731718) (commit e45ea41), kept until 2026-12-08 · **Time:** about 10 minutes

The editor's quality bar (EDITOR_ARCHITECTURE.md §1) asks for selection handles, copy and paste, and undo and redo to "pass a manual matrix". The handles are drawn by Android System WebView, not by the app, so no emulator test can see them. This is that matrix. It also puts W6's symbol toolbar under your own fingers and keyboard. The emulator gate already covers the toolbar, Tab and the hardware shortcuts with injected input (PHASE_2_PLAN.md, As built W6).

## 0. Install

As in [PHASE_2_PHONE_CHECKLIST.md](PHASE_2_PHONE_CHECKLIST.md) §1, with this run's artifact: [download](https://github.com/Skill-center/CodeForge-/actions/runs/42517731718/artifacts/13633007577), or **Actions → Phase gate →** run 42517731718 **→ Artifacts → `codeforge-phone-profile-arm64`**. Uninstall the earlier CodeForge build first, because every CI build is signed with a different throwaway key.

## 1. Set up (1 minute)

1. Open this page in your phone's browser and copy the four lines below.
2. In CodeForge, open the workspace, create a file `matrix.js` and paste them in. That paste is row C3.

```js
function add(a, b) {
  return a + b;
}
const total = add(1, 2); // ok 👍🏽 done
```

## 2. The matrix

Write ✅ or ❌ in the last column, and a few words when something looks off. A screenshot helps for any ❌, and for S4 and S5 either way.

### Selection

| # | Do | Expect | Result |
|---|---|---|---|
| S1 | Long-press `total` | The word is selected, with a handle at each end and Android's menu (Cut, Copy, Paste, Select all) | |
| S2 | Drag the end handle down onto line 3 | The selection grows across the line break, and the handle follows your finger | |
| S3 | Drag the start handle up onto line 1 | The same, backwards | |
| S4 | Select from the middle of line 1 to the very start of line 2, before its two spaces | Note where the end handle is drawn: at the start of line 2, or at the end of line 1, as phone run 1 saw (`selection-handle-at-line-break.png`). Either way, dragging it must still move the end of the selection | |
| S5 | Select from the very end of line 1 into line 2 | Note where the start handle is drawn | |
| S6 | Menu → Select all | Everything is highlighted, with the handles at the start and the end | |
| S7 | Select just the 👍🏽 and copy it, then paste it at the end of line 4 | The emoji comes back whole, skin tone included, not as a plain 👍 and a square | |
| S8 | With a selection showing, tap somewhere else in the text | The selection goes and the cursor moves there | |

### Copy, cut and paste

| # | Do | Expect | Result |
|---|---|---|---|
| C1 | Copy line 2 with Android's menu, and paste it at the start of line 4 | The same text, its two leading spaces included | |
| C2 | Cut a word, then paste it back | The word goes with Cut and comes back with Paste | |
| C3 | The paste from your browser in §1 | The same four lines, with the indentation and the emoji | |
| C4 | Copy some lines in CodeForge and paste them into another app (notes, chat) | The same text | |

### Undo and redo

| # | Do | Expect | Result |
|---|---|---|---|
| U1 | After C1, tap the toolbar's Undo | The paste goes in one step | |
| U2 | Tap Redo | The paste comes back | |
| U3 | Type a few words, then tap Undo a few times | Each tap undoes a sensible chunk: neither one character at a time nor everything at once | |
| U4 | Select lines 1 to 3, tap the toolbar's Tab key, then Shift+Tab | All three lines indent, then outdent; Undo takes back each step in one tap | |

### Toolbar and keyboard

| # | Do | Expect | Result |
|---|---|---|---|
| K1 | While typing, tap the `()`, `{}` and `;` keys | Each types at the cursor; a pair puts the cursor between its brackets; the keyboard stays up and the cursor stays in the editor | |
| K2 | Long-press `()` | Only `(` is typed | |
| K3 | The arrow keys, then the hide key at the right end | The arrows move the cursor; the hide key puts the keyboard down, and tapping the editor brings it back | |
| K4 | Optional, with a Bluetooth or USB keyboard: Ctrl+S, Ctrl+F then Escape, Ctrl+Shift+P then Escape, Ctrl+Tab, Ctrl+W, Ctrl+Z, Tab | Each does what it says; the toolbar steps aside while the soft keyboard is down | |

## 3. What to send back

- The four tables with your ✅/❌ and notes. Copying the rows into the chat is fine.
- Screenshots for S4, S5 and any ❌.
- The phone model and Android version, and the **Android System WebView** version (Settings → Apps → Android System WebView).

## 4. Runs

| Run | Date | Phone | Build | Result |
|---|---|---|---|---|
