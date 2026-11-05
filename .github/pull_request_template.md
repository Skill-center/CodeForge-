## What & why

<!-- One paragraph: the change and the phase/ADR it belongs to. -->

## Phase / gate impact

- Phase: <!-- e.g. Phase 1 W3 -->
- Gates touched: <!-- G1…G8 or none -->

## Evidence (required — no unverified claims)

- CI run: <!-- link + run id -->
- Phase-gate run (if applicable): <!-- link + run id -->
- Tests: <!-- what ran, where; "not run" is an acceptable honest answer -->

## Checklist

- [ ] `flutter analyze` clean on CI
- [ ] Architecture import lint passes (`tool/lint_imports.dart`)
- [ ] License gate passes (`tool/check_licenses.dart`)
- [ ] Docs updated (README / CHANGELOG / affected `docs/*.md`)
- [ ] No new dependency without a TECH_STACK.md justification
- [ ] No secrets, keystores, or generated binaries committed
