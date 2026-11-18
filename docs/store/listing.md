# Play Store listing (draft)

> **Draft, 2026-11-18,** from t1's `store/listing.md`. It describes the app as it is at the end of Phase 4, with one change from Phase 5 W1 (2026-11-18): the release build asks for internet access, for the commands the user runs. **Before each upload, check it against the build:** a listing that claims more than the app does is a policy problem. The terminal arrives in Phase 5. Until then the listing says the runtime's tools ship and are checked, not that you can run your own commands.

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
• Running your own commands in a terminal comes in a later version

PRIVATE BY DESIGN
• No account, no ads, no analytics, no tracking
• One permission, internet access, for the commands you run (npm, pip, git);
  the app itself sends nothing
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
| Phone screenshots | 2 to 8, JPEG or 24-bit PNG; each side 320 to 3,840 px, the long side at most twice the short | **to capture:** (1) the workbench with a file open, (2) Home with projects and folders, (3) the explorer, (4) search results, (5) Settings → Linux runtime with the versions, (6) the editor's find and replace |
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
| Permissions declarations | None apply: the release build's one permission, INTERNET, is a normal permission, which Play's declaration forms do not cover | CI's *Release manifest* gate reads the release build's merged manifest on every push. Its entries: INTERNET (from Phase 5 W1), and androidx.core's own signature permission, which grants nothing outside the app |

## Release notes (the first upload)

```
First test build. Edit real files in projects and folders, search across a
project, and see the bundled Linux tools (Node, Python, Git, bash, Perl, Ruby,
ripgrep) installed and checked on your phone. Works offline. Running your own
commands comes in a later build.
```
