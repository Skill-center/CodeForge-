# Play preparation (Phase 4 W7)

> **Drafts, 2026-11-18,** updated at Phase 5's end (2026-11-21) for the terminal and *Run*, and at Phase 6's end (2026-11-23) for the language servers, which add no permission and send nothing. Written by the agent from t1's `store/` templates (m-cyber12/t1 at `d9789a2`, ADR-0010), checked against what the app does today. Nothing here is submitted. The owner submits it, and checks each answer against Play Console's form on the day, because Google changes the forms.

| File | What it is |
|---|---|
| [listing.md](listing.md) | The store listing: the name, the descriptions, the graphics to produce, the store settings |
| [data-safety.md](data-safety.md) | The Data safety form's answers (nothing collected, nothing shared), each with the reason it is true |
| [privacy-policy.md](privacy-policy.md) | The privacy policy, to publish at a public URL |
| [release-checklist.md](release-checklist.md) | The steps for every upload, CI's and the owner's |

## Who does what

**The owner** (ADR-0010; only the account holder can):

1. **The developer account.** A personal account created after 13 November 2023 must run a closed test, with at least 12 testers opted in for 14 days in a row, before it can apply for production access ([Play Console Help: app testing requirements](https://support.google.com/googleplay/android-developer/answer/14151465)). An organisation account is exempt, but needs a D-U-N-S number. Google verifies the account holder's identity first, which can take several days.
2. **Play App Signing and an upload key.** Play keeps the app signing key. The owner creates the upload key, keeps it outside the repository, and backs it up. For CI to sign uploads, it goes into the repository's secrets: the keystore as base64, its password, the alias and the key password. Never in a commit.
3. **The forms**, from these drafts: the listing, Data safety, content rating, target audience, ads, and app access.
4. **The testers:** at least 12, better 15 to 20, because the 14 days count only while at least 12 stay opted in. A Google Group makes the list easy to manage.
5. **A contact address** for the listing, the privacy policy and SOURCE_OFFER.md.

**The agent:** these drafts; the release workflow (a signed arm64 App Bundle, below); the source archive and the offer in About (SOURCE_OFFER.md); the graphics; and the evidence that the answers are true: CI's *Release manifest* gate (the release build asks for INTERNET, from Phase 5 W1, and from Phase 5 W5 the terminal sessions' foreground service's FOREGROUND_SERVICE, FOREGROUND_SERVICE_SPECIAL_USE and POST_NOTIFICATIONS, besides androidx.core's own signature permission; nothing else); the text for Play Console's foreground-service declaration ([listing.md](listing.md), *The foreground service declaration*) and the dependency list (THIRD_PARTY_NOTICES §2: no analytics, crash-reporting or advertising packages).

## The closed test: a proposed start

**Proposed: start the closed test with the first build that has the release workflow and the source archive, as Phase 5's first work package. It runs 14 days, alongside Phase 5's work.**

- **Why not now:** the closed test distributes the app, and with it the userland's GPL binaries. So the source archive and the offer must exist first (SOURCE_OFFER.md, ADR-0010). **Since Phase 5 W1** both do, and the release workflow builds the signed App Bundle Play needs; it runs dry until the owner's keys exist (CI 44399784786).
- **Why not later:** the production gate needs those 14 days, and they can pass during Phase 5, long before the public release in Phase 10. A later test can then try the terminal.
- **What it needs, and who:**

  | Before the start | Who | State on 2026-11-18 |
  |---|---|---|
  | The developer account, verified | the owner | not started |
  | Play App Signing, and the upload key in CI's secrets | the owner | not started |
  | The release workflow: a signed arm64 App Bundle, with its size within Play's 200 MB base limit | the agent (Phase 5 W1) | **built:** 146.2 MB per device (dry run CI 44399784786), signed with throwaway keys until the owner's exist |
  | The source archive with the release, and the offer in About | the agent (Phase 5 W1) | **built:** the archive in every release run (261.7 MB in CI 44399784786), the offer in About |
  | The privacy policy at a public URL | the owner fills in the name, the date and the address; it can be published from this public repository (GitHub Pages) | drafted |
  | The listing, Data safety, content rating, target audience | the owner, from the drafts | drafted |
  | The graphics: an icon at 512 × 512, a feature graphic, 2 to 8 screenshots | the agent | to produce |
  | 15 to 20 testers | the owner | not started |
  | A licence review of THIRD_PARTY_NOTICES.md and SOURCE_OFFER.md by a person qualified to give one: no binary is distributed before it (the owner, 2026-11-18) | the owner | being arranged by the owner |

- **The date:** the Monday after the last of these is done. Phase 5 W1 landed on 2026-11-18, so the agent's rows wait only for the graphics, which the agent produces once the owner's rows are under way. If the account, the keys and the licence review are done by early December, the test could start on **Monday 2026-12-07** and meet the 14 days on 2026-12-21.
- **At Phase 5's end** (2026-11-21) the owner's rows are as on 2026-11-18, as far as the agent knows. Since then the build has the terminal and *Run* too, so the closed test can try them from its first build.
- **What testers try:** the editor, projects and folders, search, Settings → Linux runtime, the first install on their phone (its time is on the Runtime page), and since Phase 5 the terminal (Gboard in it, the extra keys, nano), *Run* on the demo's `main.js` and `app.py`, and a long session in the background with its notification; since Phase 6, completion, problems, go to definition and rename in the demo's Python and JavaScript, with their own keyboard. Feedback goes through Play's private feedback and the repository's issues.
