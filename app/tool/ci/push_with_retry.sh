#!/usr/bin/env bash
# Push HEAD to a branch, surviving concurrent CI commit-backs (phase-gate
# evidence and bootstrap results can land at the same time): on rejection,
# fetch + rebase onto the remote tip and retry. CI results never touch the
# same files as each other, so a rebase conflict means something is wrong.
# Usage (from the repository root): push_with_retry.sh <branch>
set -uo pipefail

branch="${1:?usage: push_with_retry.sh <branch>}"
for attempt in 1 2 3 4 5; do
  if git push origin "HEAD:$branch"; then
    exit 0
  fi
  echo "push attempt $attempt rejected; rebasing onto origin/$branch"
  git fetch origin "$branch" || true
  if ! git rebase "origin/$branch"; then
    git rebase --abort || true
    echo "::error::rebase conflict while pushing CI results to $branch"
    exit 1
  fi
  sleep 5
done
echo "::error::failed to push CI results to $branch after 5 attempts"
exit 1
