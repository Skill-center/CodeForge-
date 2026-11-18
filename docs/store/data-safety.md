# Data safety answers (draft)

> **Draft, 2026-11-18,** from t1's `store/data-safety.md`. Play Console → App content → Data safety. The owner checks each answer against the form on the day: Google changes it. **Re-check these answers whenever the app gains a permission, a network feature or a dependency.** CI's *Release manifest* gate fails the build if the release build asks for a permission.

## The answers

| Question | Answer |
|---|---|
| Does your app collect or share any of the required user data types? | **No** |
| Is all of the user data collected by your app encrypted in transit? | Not asked: nothing is collected |
| Do you provide a way for users to request that their data is deleted? | Not asked: nothing is collected. The app's data is on the phone, and uninstalling removes it |
| Privacy policy | [privacy-policy.md](privacy-policy.md), at a public URL |

## Why "nothing collected" is true

Play's definition: *collect* means transmitting data from the app off the user's device; data processed only on the device is not collected ([Play Console Help: Data safety](https://support.google.com/googleplay/android-developer/answer/10787469), read 2026-11-18).

| What the app holds | Collected? | Why |
|---|---|---|
| Your files: projects, and folders you open | No | Projects stay in the app's storage. A folder opens through Android's picker, which grants the app that folder alone; removing it from Home gives the grant back. Nothing leaves the phone |
| The session: open tabs, unsaved text, settings | No | In the app's database and preferences, on the phone |
| The app's logs | No | On the phone, in a directory Android never backs up, with secrets redacted (Settings → About → Recent logs) |
| The runtime: Node, Python, Git and the rest | No | They ship inside the app and run on the phone. Nothing is downloaded |
| Device identifiers, location, contacts, accounts | No | The app reads none of them, and asks for no permission that would allow it |
| Crash reports, analytics, advertising | No | None in the app. Its dependencies are Flutter, material_ui, Riverpod, go_router, shared_preferences, Drift, crypto and webview_flutter, with no analytics, crash-reporting or advertising code (THIRD_PARTY_NOTICES §2) |

**The network:** the release build asks for no permissions at all, so it has no internet access: it cannot send anything anywhere. CI's *Release manifest* gate checks the merged manifest on every push; its only entry is androidx.core's own signature permission, which grants nothing outside the app. The editor page runs in Android's WebView from a page inside the app and makes no network requests (SECURITY.md).

**Android backup** (ADR-0012) is off until the user turns it on in Settings → Privacy. Then Android's backup service copies the projects, the session database and the settings to the user's own Google account. The app never receives that copy, and neither does anyone working on CodeForge. On Android 9 and later, with a screen lock set, Android encrypts it end to end with the phone's PIN, pattern or password ([Android Developers: Auto Backup](https://developer.android.com/identity/data/autobackup)). Play's form exempts data that is end-to-end encrypted, and the developer receives nothing at all. *For the owner to confirm against the form:* on Android 8, Android's backup is not end-to-end encrypted; it still goes only to the user's own account, by the user's choice.

**Sharing:** nothing is shared. Text reaches another app on the phone only when the user picks that app in Android's text-selection menu, a user-initiated action that Play's form does not count as sharing.

## When an answer would change

- **Internet access** (git remotes, packages: SECURITY.md lists them for later phases): transfers the user starts, to servers the user chooses, are not the developer collecting data. The answers still need a fresh review, and the privacy policy a new paragraph.
- **Crash reporting or analytics:** none is planned. Adding either changes the answers to "collected" for the data it sends.
- **Extensions** (Phase 8): an extension's network permission needs its own review.
