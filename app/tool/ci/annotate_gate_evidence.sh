#!/usr/bin/env bash
# Mirror the key emulator-gate evidence into check-run annotations: a second
# channel, readable through the GitHub checks API, for when committing the
# evidence back fails (log and artifact hosts are unreachable from the
# authoring sandbox). GitHub keeps at most 10 notices per step — all 10 used.
# Run from app/.
set -uo pipefail

dir="ci-results/gate"

note() {
  local title="$1" file="$2" lines="$3" msg
  [ -s "$file" ] || return 0
  msg="$(tail -n "$lines" "$file" | cut -c1-240 | tail -c 3800)"
  msg="${msg//'%'/'%25'}"
  msg="${msg//$'\r'/'%0D'}"
  msg="${msg//$'\n'/'%0A'}"
  echo "::notice title=gate ${title}::${msg}"
}

note result "$dir/gate-result.txt" 5
note host "$dir/host.txt" 30
note readiness "$dir/readiness.txt" 30
# attempts.txt ends with the backup group's verdict (Phase 3 W1).
note attempts "$dir/attempts.txt" 30
# restore_a gave its place to the large-file numbers (W7): restore_b,
# attempts and the result still say how the restore pair went.
for test in smoke restore_b; do
  note "$test" "$dir/$test.txt" 40
done
note coldstart "$dir/coldstart-summary.txt" 20
note bench "$dir/editor_bench.txt" 40
note "large files" "$dir/large_files.txt" 45
note emulator "$dir/emulator.txt" 25
