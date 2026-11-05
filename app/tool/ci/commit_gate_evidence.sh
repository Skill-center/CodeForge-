#!/usr/bin/env bash
# Commit the emulator gate's evidence (app/ci-results/gate/) back to the
# branch. Concurrent pushes (bootstrap CI commit-backs, the author) are
# expected, so instead of rebasing the runner's checkout — which fails when
# anything in the tree is dirty — every attempt snapshots the evidence,
# resets to the remote tip, restores ONLY the gate directory and commits
# that. CI's own diagnostics in app/ci-results/ are never touched.
# Usage (from the repository root): commit_gate_evidence.sh <branch>
set -uo pipefail

branch="${1:?usage: commit_gate_evidence.sh <branch>}"
dir="app/ci-results/gate"
if [ ! -d "$dir" ]; then
  echo "::warning::no gate evidence directory ($dir); nothing to commit"
  exit 0
fi

snapshot="$(mktemp -d)"
cp -a "$dir/." "$snapshot/"
git config user.name "codeforge-ci"
git config user.email "ci@codeforge.invalid"

for attempt in 1 2 3 4 5; do
  if git fetch -q origin "$branch" && git reset -q --hard "origin/$branch"; then
    rm -rf "$dir"
    mkdir -p "$dir"
    cp -a "$snapshot/." "$dir/"
    git add -A "$dir"
    if git diff --cached --quiet; then
      echo "gate evidence already up to date on $branch"
      exit 0
    fi
    if git commit -q -m "chore(ci): phase-gate evidence [skip ci]" &&
      git push -q origin "HEAD:$branch"; then
      echo "gate evidence pushed on attempt $attempt: $(git rev-parse --short HEAD)"
      exit 0
    fi
  fi
  echo "evidence push attempt $attempt failed; retrying"
  sleep $((attempt * 5))
done
echo "::error::failed to push gate evidence to $branch after 5 attempts"
exit 1
