# Play Store listing (draft)

> **Draft, 2026-11-18,** from t1's `store/listing.md`; **revised at Phase 5's end** (2026-11-21) for what Phase 5 built: the terminal, *Run*, and sessions that keep running with a notification; **and at Phase 6's end** (2026-11-23) for the language servers: completion, problems, definition, rename and hover for Python, JavaScript and TypeScript, offline. They need no permission and send nothing. The release build asks for internet access (Phase 5 W1) and for the foreground service's permissions (W5). **Before each upload, check it against the build:** a listing that claims more than the app does is a policy problem. A build from before Phase 5 has no terminal, and its listing must not claim one; a build from before Phase 6 has no language servers.

## App identity

| Field | Value |
|---|---|
| App name | CodeForge |
| Package | `dev.codeforge.app` |
| Category | Tools (Play has no developer-tools category; Productivity is the other fit) |
| Contact email | the owner's support address (required; also shown in the privacy policy) |
| Website | https://github.com/Skill-center/CodeForge- |
| Default language | English (United States) |

## Store presence

**Short description** (80 characters at most):

```
A code editor for Android with a real Linux toolchain inside. No account or ads.
```
(80 characters.)

**Full description** (4,000 characters at most):

```
CodeForge is a code editor built for Android phones and tablets. It edits real
files, works offline, and carries a real Linux toolchain inside the app.

EDIT
• CodeMirror 6, with syntax colours for JavaScript, TypeScript, JSX, Python,
  HTML, CSS, JSON and Markdown, many tabs, find and replace, and a symbol bar
  for the characters code needs
• Hardware keyboard shortcuts
• Unsaved text survives the app being closed by Android

UNDERSTANDS YOUR CODE, OFFLINE
• Completion as you type, problems underlined and listed, go to definition,
  rename across files with undo, and what a name is on a long press
• For Python (Pyright) and for JavaScript and TypeScript (the TypeScript
  language server), running inside the app: no account, no cloud

PROJECTS AND FOLDERS
• Projects live in the app's own storage
• Open any folder on your device through Android's own picker: CodeForge needs
  no storage permission, and sees only the folders you choose
• Create, rename, move, copy and delete in the explorer, and find any file by
  name
• Files changed by other apps update as you watch, and your unsaved text is
  never overwritten

SEARCH
• Search a whole project in a fraction of a second, with match case, whole word,
  regular expressions, and files to include or exclude
• Tap a result to open the file at the match

A LINUX TOOLCHAIN, INSIDE THE APP
• Node, Python, Git, bash, Perl, Ruby and ripgrep ship in the app, so nothing is
  downloaded and nothing needs root
• Every file is verified when it installs, and every program is checked at each
  start to come from the app itself
• Settings > Linux runtime shows each tool's version

TERMINAL AND RUN
• A real terminal: bash with tabs, a row of extra keys (Esc, Ctrl, Alt, Tab,
  arrows), copy and paste, and colours; nano, top and less work
• Run the open file (JavaScript, Python, shell, Ruby, Perl) or a project's npm
  script, and tap a file:line in the output to open the editor there
• Sessions keep running while you use other apps, with a notification that
  ends them all; what you start ends with everything it started
• Your code runs as the app, with the app's access: it is not isolated from
  CodeForge's own files

PRIVATE BY DESIGN
• No account, no ads, no analytics, no tracking
• Internet access for the commands you run (npm, pip, git), and a
  notification while your terminal sessions run; the app itself sends nothing
• Android backup is your choice, and off until you turn it on

CodeForge is open source under the Apache License 2.0. The bundled Linux
packages keep their own licences; the app lists them, and their source is
offered with every release.
```

## Graphics

| Asset | Size | Status |
|---|---|---|
| App icon | 512 × 512 PNG, 32-bit with alpha | **to produce**, from the launcher icon (`@mipmap/ic_launcher`) |
| Feature graphic | 1024 × 500, JPEG or 24-bit PNG | **to produce:** the workbench with code, legible as a thumbnail; no third-party marks |
| Phone screenshots | 2 to 8, JPEG or 24-bit PNG; each side 320 to 3,840 px, the long side at most twice the short | **to capture:** (1) the workbench with a file open and a completion list, (2) the terminal with a session and the extra-keys row, (3) a run's output in the terminal with the Run panel, (4) Home with projects and folders, (5) the explorer, (6) search results, (7) the *Problems* sheet, or a long press's symbol menu, (8) Settings → Linux runtime with the versions and the language servers |
| Tablet screenshots (7- and 10-inch) | optional | the workbench's wide layout |

The screenshots show the demo project only: no real project names, keys or personal files.

## Store settings

| Setting | Answer | Why |
|---|---|---|
| App or game | App | — |
| Free or paid | Free | — |
| Ads | **No** | No advertising code in the dependencies (`pubspec.yaml`: Flutter, material_ui, Riverpod, go_router, shared_preferences, Drift, crypto, webview_flutter) |
| In-app purchases | No | — |
| App access | All functionality is available without special access | No account or sign-in |
| Content rating | A utility: no user-generated content shared, no violence, no gambling, no ads | The questionnaire's answers follow from that |
| Target audience | 13 and over; not designed for children | A developer tool. It collects no data from anyone either way |
| Data safety | **No data collected, no data shared** ([data-safety.md](data-safety.md)) | — |
| Privacy policy | [privacy-policy.md](privacy-policy.md), at a public URL | Required even when nothing is collected |
| Government, financial, health, news apps | No | — |
| Permissions declarations | **The foreground service (Phase 5 W5):** App content → Foreground service permissions, for `FOREGROUND_SERVICE_SPECIAL_USE`, with the text below (*The foreground service declaration*). INTERNET, FOREGROUND_SERVICE and POST_NOTIFICATIONS are not declared: Play's other forms do not cover them | CI's *Release manifest* gate reads the release build's merged manifest on every push. Its entries: INTERNET (from Phase 5 W1), FOREGROUND_SERVICE, FOREGROUND_SERVICE_SPECIAL_USE and POST_NOTIFICATIONS (from Phase 5 W5), and androidx.core's own signature permission, which grants nothing outside the app; `SessionService` is the only service |

## The foreground service declaration (Phase 5 W5; the owner submits it)

Play Console → App content → Foreground service permissions, at the first upload of a build with the service (PHASE_5_PLAN §10, item 5). A draft: the owner checks it against the form on the day, since Google changes it.

- **The permission:** `android.permission.FOREGROUND_SERVICE_SPECIAL_USE`, for one service, `dev.codeforge.app.terminal.SessionService`. The manifest's subtype (`PROPERTY_SPECIAL_USE_FGS_SUBTYPE`): *Terminal sessions that the user starts in the Linux environment of the app, which run until the user ends them*.
- **The use, for the description field:**

  > CodeForge is a code editor with a Linux command line inside the app. When the user starts a terminal session, or runs their program or an npm script from the editor, a foreground service keeps the app's process running, so that the session goes on while the user is in another app: for example, to look at the page their development server serves in the browser, or while a long `npm install`, build or test run finishes. The service runs only while at least one session the user started is running. Its notification says how many run ("2 terminal sessions running") and has an End all button; it stops as soon as the last session ends. It does no work of its own, starts nothing by itself, and is never started from the background. No other type fits: a terminal session is the user's own program and runs for as long as the user lets it, while `dataSync` is for data transfers and is limited to six hours a day.

- **If Android stopped it:** the user's running programs (a development server, a build, a test run, an interactive shell) would end, and their output would be lost.
- **The video** (the owner records it on a phone): open a project, open the terminal, run a long command (`npm run dev`, or `sleep 600`), press Home, show the notification, come back to the app, and tap *End all* in the notification.

## Release notes (the first upload)

```
First test build. Edit real files in projects and folders, search across a
project, and run your code: a terminal with bash and the bundled Linux tools
(Node, Python, Git, Perl, Ruby, ripgrep), and Run for the open file or an npm
script. Sessions keep running in the background, with a notification to end
them. Completion, problems, go to definition and rename for Python,
JavaScript and TypeScript, from language servers inside the app. Works
offline, except for the commands you run that use the network.
```
