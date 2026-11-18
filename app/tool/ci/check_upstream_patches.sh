#!/usr/bin/env bash
# The upstream patches for t1 (native/upstream/*.patch; native/PROVENANCE.md,
# "Upstream patches"). Each is written against t1's tree for t1's owner to
# apply, so this maps it onto the vendored kernel (t1's paths and package to
# CodeForge's), applies it, runs the kernel's JVM tests with it, and restores
# the vendored files, checked unchanged afterwards.
#   - A patch that no longer applies fails: re-vendoring changed the code it
#     fixes, so it needs writing again.
#   - A patch already in the vendored copy (t1 took it, and CodeForge
#     re-vendored) only warns: retire it, and what worked around it.
# Run from app/ (CI's quality job). Writes ci-results/upstream-patches.txt.
set -uo pipefail

root="$(cd .. && pwd)"
kernel="native/sealed-runtime"
out="ci-results/upstream-patches.txt"
results="build/sealed-runtime/test-results/test"
mkdir -p ci-results
: > "$out"

restore() {
  git -C "$root" checkout -q -- "$kernel"
}
trap restore EXIT

# tests/failures/errors/skipped summed over the JUnit XML, as the CI step
# for the kernel's tests counts them.
count() {
  local tests=0 failures=0 errors=0 skipped=0 head t fl e sk f
  for f in "$results"/TEST-*.xml; do
    [ -f "$f" ] || continue
    head=$(grep -o '<testsuite [^>]*>' "$f" | head -n 1)
    t=$(printf '%s' "$head" | sed -n 's/.* tests="\([0-9]*\)".*/\1/p')
    fl=$(printf '%s' "$head" | sed -n 's/.* failures="\([0-9]*\)".*/\1/p')
    e=$(printf '%s' "$head" | sed -n 's/.* errors="\([0-9]*\)".*/\1/p')
    sk=$(printf '%s' "$head" | sed -n 's/.* skipped="\([0-9]*\)".*/\1/p')
    tests=$((tests + ${t:-0})); failures=$((failures + ${fl:-0}))
    errors=$((errors + ${e:-0})); skipped=$((skipped + ${sk:-0}))
  done
  echo "$tests $failures $errors $skipped"
}

shopt -s nullglob
patches=("$root"/native/upstream/*.patch)
status=0
for patch in "${patches[@]}"; do
  name="$(basename "$patch")"
  mapped="$(mktemp)"
  sed -e 's#\([ab]\)/sealed-runtime/#\1/native/sealed-runtime/#g' \
      -e 's#io/mcyber12/sealed#dev/codeforge/runtime/sealed#g' \
      -e 's#io\.mcyber12\.sealed#dev.codeforge.runtime.sealed#g' \
      "$patch" > "$mapped"
  if git -C "$root" apply --check "$mapped" 2>/dev/null; then
    git -C "$root" apply "$mapped"
    rm -rf "$results"
    gradle_exit=0
    ( cd android && timeout --kill-after=30s 10m \
        ./gradlew :native:sealed-runtime:test --rerun --console=plain ) \
      > "${RUNNER_TEMP:-/tmp}/upstream-$name.log" 2>&1 || gradle_exit=$?
    read -r tests failures errors skipped < <(count)
    line="patch=$name applies=yes tests=$tests failures=$failures errors=$errors skipped=$skipped gradle_exit=$gradle_exit"
    if [ "$gradle_exit" -ne 0 ] || [ "$tests" -eq 0 ] || [ "$failures" -ne 0 ] || [ "$errors" -ne 0 ]; then
      status=1
      tail -n 40 "${RUNNER_TEMP:-/tmp}/upstream-$name.log" >> "$out"
      echo "::error title=Upstream patch fails::$name: the kernel's tests fail with it ($line)"
    fi
    restore
  elif git -C "$root" apply --reverse --check "$mapped" 2>/dev/null; then
    line="patch=$name applies=already"
    echo "::warning title=Upstream patch already vendored::$name is in the vendored kernel: retire it (native/PROVENANCE.md)"
  else
    line="patch=$name applies=no"
    status=1
    echo "::error title=Upstream patch no longer applies::$name does not apply to the vendored kernel"
  fi
  echo "$line" | tee -a "$out"
  rm -f "$mapped"
done

restore
if ! git -C "$root" diff --quiet -- "$kernel"; then
  echo "::error::the vendored kernel was not restored after the upstream patches"
  status=1
fi
echo "upstream_patches=${#patches[@]} status=$status" | tee -a "$out"
exit "$status"
