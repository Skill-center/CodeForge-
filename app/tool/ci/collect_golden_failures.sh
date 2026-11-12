#!/usr/bin/env bash
# Golden diff images (Phase 3 W6, an owner item of 2026-11-11). When a
# golden test fails, flutter_test's LocalFileComparator writes the golden
# (_masterImage), what the test drew (_testImage) and, when their sizes
# match, the differences (_isolatedDiff, _maskedDiff) into a failures/
# folder beside the test file. This moves every such image into
# <results>/golden-failures/, keeping its test folder (so
# test/goldens/failures/x.png becomes golden-failures/goldens/x.png), lists
# them in <results>/golden-failures.txt, and prints how many there were.
# The workflow commits them back with its diagnostics. Images from an
# earlier run are removed first, so the folder always holds this run's.
# Usage (from app/): collect_golden_failures.sh <test dir> <results dir>
set -euo pipefail

tests="${1:?usage: collect_golden_failures.sh <test dir> <results dir>}"
results="${2:?usage: collect_golden_failures.sh <test dir> <results dir>}"
out="$results/golden-failures"
rm -rf "$out" "$results/golden-failures.txt"
count=0
while IFS= read -r -d '' image; do
  rel="${image#"$tests"/}"
  # goldens/failures/x.png -> goldens/x.png
  dest="$out/${rel/failures\//}"
  mkdir -p "$(dirname "$dest")"
  cp "$image" "$dest"
  count=$((count + 1))
done < <(find "$tests" -type f -path '*/failures/*.png' -print0 | sort -z)
# The originals go, so that no later `git add` picks them up beside the
# test files.
find "$tests" -type d -name failures -prune -exec rm -rf {} +
if [ "$count" -gt 0 ]; then
  (cd "$out" && find . -type f -name '*.png' | sed 's|^\./||' | LC_ALL=C sort) \
    > "$results/golden-failures.txt"
fi
echo "$count"
