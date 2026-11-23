# CodeForge privacy policy

> **Draft, 2026-11-18,** from t1's `store/privacy-policy.md`; **revised in Phase 5 W1** (2026-11-18) for internet access, which the owner decided that day, and **in Phase 5 W5** (2026-11-20) for the terminal sessions' foreground service and notification; **reviewed at Phase 6's end** (2026-11-23) for the language servers, which collect and send nothing. For the owner to complete (the three bracketed items) and publish at a public URL before the closed test. Everything below the line is the policy itself.

---

**CodeForge privacy policy**

*Effective [the date it is published].*

CodeForge is a code editor for Android, published by [the developer's name, as on the Google Play account]. It runs entirely on your device.

**What we collect: nothing.** CodeForge does not collect, transmit, sell or share personal information. It has no accounts, no analytics, no advertising and no crash reporting, and none of its own code sends anything anywhere.

**The internet.** CodeForge asks Android for internet access, so that the Linux tools inside it can reach the network when you run them. For example, `npm install` downloads packages from the npm registry, `pip install` from the Python Package Index, and `git clone`, `git pull` and `git push` talk to the servers you name. What such a command sends (the names of the packages you ask for; your code, when you push it) goes to the server the command names, under that server's own privacy policy. It never goes to us. Nothing is sent unless you run a command that sends it.

**Terminal sessions.** While a terminal session you started runs, CodeForge keeps running in the foreground and shows a notification saying how many run, with a button to end them all, so that your programs go on while you use another app. For this it asks Android to run a foreground service and, on Android 13 and later, asks you to allow its notifications; if you decline, sessions still run. The notification is drawn on your device and sends nothing.

**Your files.** Your projects stay in the app's own storage on your device. When you open a folder, Android's picker gives CodeForge access to that folder only. Removing the folder from CodeForge's Home gives that access back to Android. CodeForge does not read other files.

**What the app keeps on your device:** the files you edit, your open tabs and unsaved text, your settings, and logs of what the app did, with secrets removed. The logs stay on the device and are never backed up; you can read them in Settings → About → Recent logs.

**The Linux tools** (Node, Python, Git and others) are part of the app and run on your device; the app downloads none of them. So are the language servers that offer completion and show problems in your code: they read your project on your device and send nothing anywhere.

**Android backup** is off until you turn it on in Settings → Privacy. When it is on, Android's backup service copies your projects, your session (open tabs and unsaved text) and your settings to your own Google account, so a new phone can restore them. This copy is handled by Android and Google under your Google account. We never receive it. On Android 9 and later, with a screen lock, Android encrypts it with your device's PIN, pattern or password. You can turn backup off at any time, and delete the copy in your Google account's backup settings.

**Deleting your data.** Uninstalling CodeForge removes everything it stored on your device.

**Children.** CodeForge is a tool for developers, and is not directed at children.

**Changes.** If this policy changes, the new version is published at this address with a new effective date. If a future version adds a feature of its own that uses the internet, this policy will say what it sends and where, before that version is released.

**Contact:** [the support address shown on the Google Play listing].
