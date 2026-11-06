#!/usr/bin/env bash
# Phase-gate emulator run (G1/G5/G6 evidence).
# Boots a headless API-36 emulator (KVM when the runner exposes it, software
# emulation otherwise), waits for a *stable* Android framework, runs the
# integration tests — the restore pair with a real process kill between A and
# B — then measures cold start on a dedicated release APK.
# Run from app/ on a Linux CI runner with ANDROID_HOME set.
#
# Evidence lands in ci-results/gate/ — a directory owned by this script, so
# phase-gate.yml can commit it back without touching CI's own diagnostics:
#   host.txt         runner CPU/RAM, /dev/kvm, acceleration actually used
#   readiness.txt    boot + framework-readiness timings
#   attempts.txt     every integration-test attempt and its exit code
#   smoke|restore_a|restore_b.txt  final attempt output (+ .attemptN.txt)
#   prefs_after_a.txt / process_after_kill.txt  G5 on-disk + kill proof
#   coldstart*.txt / perf.json     G6 measurement (record-only)
#   editor_bench.json|.txt         Phase 2 W3 engine benchmark (CodeMirror 6
#                                  vs Monaco; information for ADR-0004), from
#                                  editor_bench_<engine>.txt + the DevTools
#                                  driver's editor_bench_cdp.json|.txt
set -uo pipefail

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$SDK" ]; then
  for cand in /usr/local/lib/android/sdk "$HOME/Android/Sdk" /opt/android-sdk; do
    [ -d "$cand" ] && SDK="$cand" && break
  done
fi
if [ -z "$SDK" ]; then
  echo "Android SDK not found (ANDROID_HOME unset and no default path)" >&2
  exit 1
fi
echo "Android SDK: $SDK"
EMU_BIN="$SDK/emulator/emulator"
SDKMANAGER="$(command -v sdkmanager || echo "$SDK/cmdline-tools/latest/bin/sdkmanager")"
AVDMANAGER="$(command -v avdmanager || echo "$SDK/cmdline-tools/avdmanager")"
[ -x "$AVDMANAGER" ] || AVDMANAGER="$SDK/cmdline-tools/latest/bin/avdmanager"
ADB="$(command -v adb || echo "$SDK/platform-tools/adb")"
APP_ID="dev.codeforge.app"
RESULTS="ci-results/gate"
# Fresh evidence only: the directory belongs to this script.
rm -rf "$RESULTS"
mkdir -p "$RESULTS"
# The emulator logs OUTSIDE the workspace: a dying emulator must never write
# into the tree the commit-back step is committing (gate-7 lost its evidence
# that way). A tail is copied into the evidence once the emulator is dead.
EMU_LOG="${RUNNER_TEMP:-/tmp}/codeforge-emulator.log"
: > "$EMU_LOG"

EMU_PID=""
fail=0
ACCEL="tcg"

# Always leave a verdict + logcat tail, including on early exits.
finish() {
  local code=$?
  if [ -n "$EMU_PID" ] && kill -0 "$EMU_PID" >/dev/null 2>&1; then
    # Keep only the tail — full logcat is large and not needed as evidence.
    "$ADB" logcat -d 2>&1 | tail -400 > "$RESULTS/logcat.txt" || true
    kill "$EMU_PID" >/dev/null 2>&1 || true
    # Wait for it to really exit (then force) so nothing outlives the step.
    for _ in $(seq 1 20); do
      kill -0 "$EMU_PID" >/dev/null 2>&1 || break
      sleep 1
    done
    kill -9 "$EMU_PID" >/dev/null 2>&1 || true
  fi
  pkill -9 -f qemu-system >/dev/null 2>&1 || true
  "$ADB" kill-server >/dev/null 2>&1 || true
  tail -200 "$EMU_LOG" > "$RESULTS/emulator.txt" 2>/dev/null || true
  [ "$code" -ne 0 ] && fail=1
  echo "gate_result=$([ "$fail" -eq 0 ] && echo pass || echo fail)" \
    | tee "$RESULTS/gate-result.txt"
}
trap finish EXIT

echo "::group::KVM setup"
# GitHub's Linux runners expose KVM after this udev rule. `udevadm trigger`
# is asynchronous, so settle (and chmod as a fallback) before probing: gate
# runs 1-6 lost that race, silently fell back to software emulation (TCG)
# and paid for it with 4.5-15.6 min boots and system_server watchdog
# restarts.
echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' \
  | sudo tee /etc/udev/rules.d/99-kvm4all.rules >/dev/null 2>&1 || true
sudo udevadm control --reload-rules >/dev/null 2>&1 || true
sudo udevadm trigger --name-match=kvm >/dev/null 2>&1 || true
sudo udevadm settle --timeout=30 >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do
  [ -w /dev/kvm ] && break
  sleep 2
done
if [ -e /dev/kvm ] && [ ! -w /dev/kvm ]; then
  sudo chmod 666 /dev/kvm >/dev/null 2>&1 || true
fi
{
  echo "nproc=$(nproc)"
  echo "mem_total_mb=$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo)"
  echo "cpu_virt_flags=$(grep -cE '(vmx|svm)' /proc/cpuinfo)"
  echo "dev_kvm=$(ls -l /dev/kvm 2>&1)"
} > "$RESULTS/host.txt"
if [ -w /dev/kvm ]; then
  ACCEL="kvm"
  ACCEL_ARGS=""
  CORES=2
else
  ACCEL="tcg"
  ACCEL_ARGS="-no-accel"
  CORES=4
fi
echo "accel=$ACCEL" >> "$RESULTS/host.txt"
cat "$RESULTS/host.txt"
echo "::endgroup::"

echo "::group::System image"
# Full image, NOT an ATD. ATD ("automated test device") images strip system
# services and the GPU stack: the first gate run showed package/storage
# service crashes and a Flutter surface that never sized. google_apis is the
# full-featured image used for UI/integration testing; `default` (AOSP) is
# the fallback.
SYSTEM_IMAGE="system-images;android-36;google_apis;x86_64"
yes | "$SDKMANAGER" --licenses > "$RESULTS/sdk-licenses.txt" 2>&1 || true
if ! "$SDKMANAGER" "emulator" "platform-tools" "$SYSTEM_IMAGE" \
    > "$RESULTS/sysimg.txt" 2>&1; then
  FALLBACK="${SYSTEM_IMAGE/;google_apis;/;default;}"
  echo "google_apis unavailable — falling back to $FALLBACK"
  "$SDKMANAGER" "emulator" "platform-tools" "$FALLBACK" \
    >> "$RESULTS/sysimg.txt" 2>&1 || { tail -30 "$RESULTS/sysimg.txt"; exit 1; }
  SYSTEM_IMAGE="$FALLBACK"
fi
echo "system_image=$SYSTEM_IMAGE" | tee "$RESULTS/system-image.txt"
{ echo "--- emulator -accel-check"; "$EMU_BIN" -accel-check 2>&1; } \
  >> "$RESULTS/host.txt" || true
echo "::endgroup::"

# sys.boot_completed stays "1" across a system_server restart (a watchdog
# kill re-runs framework init underneath it — gate run 6 died exactly so:
# "Can't find service: package", "system providers not installed"). Ready
# therefore means: package + settings services answer AND the activity
# manager accepts broadcasts, on three consecutive probes.
framework_ready() {
  "$ADB" shell pm path android 2>/dev/null | grep -q '^package:' || return 1
  "$ADB" shell settings get global device_provisioned 2>/dev/null \
    | tr -d '\r' | grep -qE '^[0-9]+$' || return 1
  "$ADB" shell am broadcast -a dev.codeforge.gate.PING 2>&1 \
    | grep -q 'Broadcast completed' || return 1
}

wait_for_framework() {
  local label="$1" limit="${2:-600}" stable=0 waited=0
  while [ "$waited" -lt "$limit" ]; do
    if framework_ready; then
      stable=$((stable + 1))
      if [ "$stable" -ge 3 ]; then
        echo "[$label] framework ready (waited ${waited}s)" \
          | tee -a "$RESULTS/readiness.txt"
        return 0
      fi
    else
      stable=0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  echo "[$label] framework NOT ready after ${limit}s" \
    | tee -a "$RESULTS/readiness.txt"
  return 1
}

echo "::group::Create AVD + boot"
export ANDROID_AVD_HOME="${ANDROID_AVD_HOME:-$HOME/.android/avd}"
mkdir -p "$ANDROID_AVD_HOME"
echo no | "$AVDMANAGER" create avd -n gate -k "$SYSTEM_IMAGE" -d pixel_6 \
  --force > "$RESULTS/avd.txt" 2>&1 || { tail -30 "$RESULTS/avd.txt"; exit 1; }
"$ADB" start-server >/dev/null 2>&1 || true
# shellcheck disable=SC2086 # ACCEL_ARGS is intentionally word-split.
"$EMU_BIN" -avd gate -no-window -gpu swiftshader_indirect -no-snapshot \
  -noaudio -no-boot-anim -dns-server 8.8.8.8,1.1.1.1 $ACCEL_ARGS \
  -memory 4096 -cores "$CORES" > "$EMU_LOG" 2>&1 &
EMU_PID=$!
boot_start=$(date +%s)
booted=""
for _ in $(seq 1 180); do
  if ! kill -0 "$EMU_PID" >/dev/null 2>&1; then
    echo "emulator process died during boot"; break
  fi
  if [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
    booted=1; break
  fi
  sleep 10
done
if [ -z "$booted" ]; then
  echo "BOOT FAILED"; tail -60 "$EMU_LOG"; exit 1
fi
echo "boot_completed_after_s=$(($(date +%s) - boot_start)) accel=$ACCEL" \
  | tee -a "$RESULTS/readiness.txt"
if ! wait_for_framework boot 900; then
  echo "FRAMEWORK NEVER STABILISED"; exit 1
fi
"$ADB" shell settings put global window_animation_scale 0 || true
"$ADB" shell settings put global transition_animation_scale 0 || true
"$ADB" shell settings put global animator_duration_scale 0 || true
"$ADB" shell svc power stayon true || true
echo "::endgroup::"

# Signatures of failures that happen *before any test code runs* — install /
# framework / transport trouble. Only these are retried; an assertion failure
# is never retried, so a retry cannot turn a real failure into a pass.
INFRA_RE="Can't find service|Broken pipe|before system providers are installed|Cannot broadcast before boot completed|DeadSystemException|Failure calling service|device offline|no devices/emulators found|Unable to start the app on the device"
INFRA_SEEN=0

# run_itest <name> <test file> [extra flutter test args...]
run_itest() {
  local name="$1" file="$2"
  shift 2
  local attempt rc=1
  for attempt in 1 2 3; do
    wait_for_framework "$name#$attempt" 600 || true
    flutter test "$file" -d emulator-5554 --reporter expanded --timeout=300s \
      "$@" 2>&1 | tee "$RESULTS/$name.txt"
    rc=${PIPESTATUS[0]}
    echo "$name attempt=$attempt exit=$rc" | tee -a "$RESULTS/attempts.txt"
    [ "$rc" -eq 0 ] && return 0
    if ! grep -qE "$INFRA_RE" "$RESULTS/$name.txt"; then
      return "$rc"
    fi
    INFRA_SEEN=1
    cp "$RESULTS/$name.txt" "$RESULTS/$name.attempt$attempt.txt"
    echo "$name: infrastructure failure on attempt $attempt — retrying"
    sleep 15
  done
  return "$rc"
}

echo "::group::Integration — smoke"
run_itest smoke integration_test/smoke_test.dart || fail=1
echo "::endgroup::"

echo "::group::Integration — editor bridge (Phase 2 W2: the real page in the WebView)"
run_itest editor integration_test/editor_bridge_test.dart || fail=1
echo "::endgroup::"

echo "::group::Editor benchmark (Phase 2 W3: CodeMirror 6 vs Monaco, informational)"
# One app process per engine, so each engine's memory is its own. The
# DevTools driver runs alongside: at the end of each test run the page hands
# itself over (title codeforge-bench:<engine>:driver) for real key events,
# the IME composition suite and a dumpsys memory sample. Budget misses are
# information for ADR-0004 and never fail the gate; the test fails only when
# the benchmark itself cannot run (page missing, no results, broken scope).
node ../editor/tool/bench_cdp.mjs --adb "$ADB" --package "$APP_ID" \
  --out "$RESULTS/editor_bench_cdp.json" --engines codemirror,monaco \
  --timeout 2400 > "$RESULTS/editor_bench_cdp.txt" 2>&1 &
bench_driver=$!
bench_ok=1
for engine in codemirror monaco; do
  run_itest "editor_bench_$engine" integration_test/editor_bench_test.dart \
    --dart-define=BENCH_ENGINE="$engine" --dart-define=BENCH_DRIVER=true \
    || bench_ok=0
done
kill "$bench_driver" 2>/dev/null || true
wait "$bench_driver" 2>/dev/null || true
node ../editor/tool/bench_report.mjs \
  --itest codemirror="$RESULTS/editor_bench_codemirror.txt" \
  --itest monaco="$RESULTS/editor_bench_monaco.txt" \
  --cdp "$RESULTS/editor_bench_cdp.json" \
  --manifest assets/editor_bench/manifest.json \
  --env accel="$ACCEL" --env system_image="$SYSTEM_IMAGE" \
  --out-json "$RESULTS/editor_bench.json" \
  --out-txt "$RESULTS/editor_bench.txt" \
  || echo "editor benchmark report failed (record-only)"
[ "$bench_ok" = "1" ] || fail=1
echo "::endgroup::"

echo "::group::Integration — restore pair (G5: establish → process death → verify)"
# --no-uninstall on part A is essential: `flutter test integration_test`
# uninstalls the app by default when the run ends, which would wipe the very
# state the gate must verify. Part B reinstalls with `install -r`, which
# keeps app data — exactly like an update landing on a killed process.
restore_pair() {
  # Clean slate: every attempt is a complete, self-contained proof.
  "$ADB" uninstall "$APP_ID" >/dev/null 2>&1 || true
  run_itest restore_a integration_test/restore_a_test.dart --no-uninstall \
    || return 1
  # Evidence: the persisted envelope actually on disk before the kill.
  "$ADB" shell run-as "$APP_ID" cat shared_prefs/FlutterSharedPreferences.xml \
    > "$RESULTS/prefs_after_a.txt" 2>&1 || true
  "$ADB" shell am force-stop "$APP_ID" | tee "$RESULTS/force_stop.txt"
  sleep 3
  local pid
  pid=$("$ADB" shell pidof "$APP_ID" 2>/dev/null | tr -d '\r')
  if [ -n "$pid" ]; then
    echo "process still alive after force-stop (pid $pid)" \
      | tee "$RESULTS/process_after_kill.txt"
    return 1
  fi
  echo "no $APP_ID process after am force-stop — process death confirmed" \
    | tee "$RESULTS/process_after_kill.txt"
  run_itest restore_b integration_test/restore_b_test.dart || return 1
}
restore_ok=0
for pair in 1 2; do
  INFRA_SEEN=0
  if restore_pair; then
    restore_ok=1
    break
  fi
  [ "$INFRA_SEEN" = "1" ] || break
  echo "restore pair attempt $pair hit infrastructure failures — re-running the whole pair" \
    | tee -a "$RESULTS/attempts.txt"
done
[ "$restore_ok" = "1" ] || fail=1
echo "::endgroup::"

echo "::group::Cold start (G6 — recorded against the 1.5 s budget, never fails the gate)"
# Measured on a dedicated release APK built before the integration tests:
# `flutter test integration_test` overwrites app-debug.apk with the test
# entrypoint, so earlier runs were timing a test harness, not the app.
COLD_APK=""
COLD_KIND="none"
if [ -f build/gate/app-release-x64.apk ]; then
  COLD_APK="build/gate/app-release-x64.apk"; COLD_KIND="release-x64"
elif [ -f build/gate/app-plain-debug.apk ]; then
  COLD_APK="build/gate/app-plain-debug.apk"; COLD_KIND="debug"
fi
: > "$RESULTS/coldstart.txt"
installed=0
if [ -n "$COLD_APK" ]; then
  wait_for_framework coldstart 300 || true
  "$ADB" uninstall "$APP_ID" >/dev/null 2>&1 || true
  for attempt in 1 2 3; do
    if "$ADB" install "$COLD_APK" > "$RESULTS/install.txt" 2>&1; then
      installed=1; break
    fi
    echo "cold-start install attempt $attempt failed; retrying"
    wait_for_framework "coldstart-install#$attempt" 300 || true
  done
fi
samples=""
if [ "$installed" = "1" ]; then
  for run in $(seq 1 10); do
    "$ADB" shell am force-stop "$APP_ID" || true
    sleep 2
    out=$("$ADB" shell am start -W -n "$APP_ID/.MainActivity" 2>&1 | tr -d '\r')
    printf '%s\n' "--- run $run" "$out" >> "$RESULTS/coldstart.txt"
    t=$(printf '%s\n' "$out" | awk '/TotalTime:/ {print $2}')
    [ -n "$t" ] && samples="$samples $t"
  done
fi
# shellcheck disable=SC2086 # word-split the sample list on purpose.
n=$(echo $samples | wc -w)
median=0
if [ "$n" -gt 0 ]; then
  # shellcheck disable=SC2086
  median=$(printf '%s\n' $samples | sort -n \
    | awk '{a[NR]=$1} END {print (NR % 2) ? a[(NR + 1) / 2] : int((a[NR / 2] + a[NR / 2 + 1]) / 2)}')
fi
within=false
if [ "$n" -gt 0 ] && [ "$median" -le 1500 ]; then within=true; fi
cold_bytes=0
[ -n "$COLD_APK" ] && cold_bytes=$(stat -c %s "$COLD_APK")
debug_bytes=$(stat -c %s build/gate/app-plain-debug.apk 2>/dev/null || echo 0)
{
  echo "cold_start_median_ms=$median"
  echo "cold_start_samples=$n"
  echo "apk=$COLD_KIND accel=$ACCEL"
  echo "budget_ms=1500 within_budget=$within"
  [ "$installed" = "1" ] || echo "install_failed_record_only=true"
} | tee "$RESULTS/coldstart-summary.txt"
# shellcheck disable=SC2086
samples_json=$(echo $samples | tr ' ' ',')
cat > "$RESULTS/perf.json" <<EOF
{
  "gate": "G6",
  "system_image": "$SYSTEM_IMAGE",
  "gpu": "swiftshader_indirect",
  "accel": "$ACCEL",
  "cold_start": {
    "apk": "$COLD_KIND",
    "method": "am start -W (TotalTime) after am force-stop, 10 runs",
    "samples_ms": [$samples_json],
    "median_ms": $median,
    "budget_ms": 1500,
    "within_budget": $within
  },
  "apk_bytes": {
    "debug": $debug_bytes,
    "cold_start_apk": $cold_bytes
  },
  "nav_frame_profile": "not measured on CI in Phase 1 (requires a profile-mode build; see docs/phases/PHASE_1_REPORT.md)"
}
EOF
cat "$RESULTS/perf.json"
echo "::endgroup::"

exit "$fail"
