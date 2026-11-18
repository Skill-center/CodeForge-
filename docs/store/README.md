# Play preparation (Phase 4 W7)

> **Drafts, 2026-11-18.** Written by the agent from t1's `store/` templates (m-cyber12/t1 at `d9789a2`, ADR-0010), checked against what the app does today. Nothing here is submitted. The owner submits it, and checks each answer against Play Console's form on the day, because Google changes the forms.

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

**The agent:** these drafts; the release workflow (a signed arm64 App Bundle, below); the source archive and the offer in About (SOURCE_OFFER.md); the graphics; and the evidence that the answers are true: CI's *Release manifest* gate (the release build asks for no permissions) and the dependency list (THIRD_PARTY_NOTICES §2: no analytics, crash-reporting or advertising packages).

## The closed test: a proposed start

**Proposed: start the closed test with the first build that has the release workflow and the source archive, as Phase 5's first work package. It runs 14 days, alongside Phase 5's work.**

- **Why not now:** the closed test distributes the app, and with it the userland's GPL binaries. So the source archive and the offer must exist first (SOURCE_OFFER.md, ADR-0010). There is also no release workflow yet: CI builds APKs, and Play needs a signed App Bundle.
- **Why not later:** the production gate needs those 14 days, and they can pass during Phase 5, long before the public release in Phase 10. A later test can then try the terminal.
- **What it needs, and who:**

  | Before the start | Who | State on 2026-11-18 |
  |---|---|---|
  | The developer account, verified | the owner | not started |
  | Play App Signing, and the upload key in CI's secrets | the owner | not started |
  | The release workflow: a signed arm64 App Bundle, with its size within Play's 200 MB base limit | the agent (Phase 5 W1, proposed) | not built: CI builds APKs |
  | The source archive with the release, and the offer in About | the agent (Phase 5 W1, proposed) | the mechanism is decided (SOURCE_OFFER.md) |
  | The privacy policy at a public URL | the owner fills in the name, the date and the address; it can be published from this public repository (GitHub Pages) | drafted |
  | The listing, Data safety, content rating, target audience | the owner, from the drafts | drafted |
  | The graphics: an icon at 512 × 512, a feature graphic, 2 to 8 screenshots | the agent | to produce |
  | 15 to 20 testers | the owner | not started |

- **The date:** the Monday after the last of these is done. If the account is verified by the end of November and Phase 5 W1 lands in early December, the test could start on **Monday 2026-12-07** and meet the 14 days on 2026-12-21.
- **What testers try:** the editor, projects and folders, search, Settings → Linux runtime, and the first install on their phone (its time is on the Runtime page). Feedback goes through Play's private feedback and the repository's issues.
