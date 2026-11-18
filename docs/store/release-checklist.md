# Release checklist (draft)

> **Draft, 2026-11-18,** from t1's `store/release-checklist.md`. For every upload to Play, the closed test's first included. **(CI)** marks what CI enforces; the rest are steps in Play Console. The release workflow it refers to is built since Phase 5 W1 (`.github/workflows/release.yml`), and runs dry until the owner's keys exist ([README.md](README.md)).

## Before the first upload, once

1. **(owner)** The developer account is verified, and Play App Signing is on. The upload key is outside the repository, backed up, and in CI's secrets.
2. **(agent, then the owner)** SOURCE_OFFER.md's items before the first distribution are done: the archive and the offer since Phase 5 W1, then the licence review. No build with the userland is distributed before them (ADR-0010, ADR-0011).
3. **(agent, then the owner)** THIRD_PARTY_NOTICES.md is current (CI fails when it is not), and its open item is done: the licence review by a qualified person. The userland's licence texts are in the app's licence page since Phase 5 W1.
4. **(owner)** The privacy policy is at its public URL, and the forms are filled from [listing.md](listing.md) and [data-safety.md](data-safety.md): the listing, Data safety, content rating, target audience, ads, and app access.

## Every upload

1. **(CI)** The run for the commit is green: the quality gates (with the *Release manifest* gate: INTERNET and androidx.core's signature permission, nothing else), the runtime's supply chain, and the editor page.
2. **(CI)** The last phase gate for the change passed, with every runtime leg (Android 8.0 to 16).
3. **(CI)** The release workflow built the arm64 App Bundle from the same pins, signed it with the upload key, and checked its base module against Play's 200 MB limit (`runtime/check-bundle-size.py`) and its native libraries' 16 KB alignment.
4. **(CI)** The release on GitHub carries the source archive and its checksums, next to the bundle's.
5. **(owner)** Upload to the internal testing track first. Install from Play on a real phone and check: the first start installs the runtime (its time is on Settings → Runtime), Settings → Linux runtime lists every tool at its pinned version, a project opens and saves, search finds text, and Android asks for no permission.
6. **(owner)** Promote to the closed track. Testers must stay opted in for 14 days in a row; the count of opted-in testers is on the track's page.
7. **(owner)** The release notes say what changed, and claim nothing the build does not do.
8. **(agent)** If the build adds a permission, a network feature or a dependency, data-safety.md and the privacy policy are reviewed before the upload.

## After the closed test

- Applying for production access asks how the test went: what testers found and what changed. Play's testing feedback and the repository's issues are the record.
- The production release is Phase 10's ([ROADMAP.md](../ROADMAP.md)).
