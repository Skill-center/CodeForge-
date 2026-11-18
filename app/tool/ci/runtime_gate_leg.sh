#!/usr/bin/env bash
# One leg of the runtime gates (Phase 4 W5; G5: API 34 and 36, G7: API 26 to
# 28, ADR-0007): an x86_64 emulator at one API level runs the runtime's
# instrumented tests against the debug APK that carries the x86_64 payload.
#
#   runtime_gate_leg.sh <api> <app apk> <test apk>
#
# Run from app/ on a Linux runner with ANDROID_HOME set; phase-gate.yml's
# runtime-gates jobs build the two APKs once and run one leg per API level.
# The classes, in the order AndroidJUnitRunner runs them (by name):
#   ExecModelTest        t1's, ported: Android's exec rule measured, the
#                        native library directory, a prefix link, a shebang
#                        through the preload, the audit;
#   RuntimeCommandsTest  W4: the tools at their pinned versions, the
#                        environment, no child left;
#   RuntimeInstallTest   W3: the install, the warm start, a flipped byte, the
#                        audit;
#   SealedShellTest      t1's, ported: bash, sed and the core tools from the
#                        APK's payload, the app's own startup path twice, dpkg.
# Evidence (ci-results/runtime-gates/api-<api>/, judged by gate_results.py):
#   leg.json / leg.txt   the verdict, each class's counts, every figure;
#   host.txt, system-image.txt, readiness.txt, webview.txt
#   instrumented.txt     `am instrument -r` output;
#   *-report.txt         the tests' own figures (run-as);
#   logcat.txt           the runtime's device log; logcat-tail.txt the end of
#                        the whole log.
set -uo pipefail

API="${1:?usage: runtime_gate_leg.sh <api> <app apk> <test apk>}"
APP_APK="${2:?app apk}"
TEST_APK="${3:?test apk}"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
EMU_BIN="$SDK/emulator/emulator"
SDKMANAGER="$(command -v sdkmanager || echo "$SDK/cmdline-tools/latest/bin/sdkmanager")"
AVDMANAGER="$(command -v avdmanager || echo "$SDK/cmdline-tools/latest/bin/avdmanager")"
ADB="$(command -v adb || echo "$SDK/platform-tools/adb")"
APP_ID="dev.codeforge.app"
RESULTS="ci-results/runtime-gates/api-$API"
EMU_LOG="${RUNNER_TEMP:-/tmp}/runtime-gate-emulator-$API.log"
CLASSES="dev.codeforge.app.runtime.ExecModelTest,dev.codeforge.app.runtime.RuntimeCommandsTest"
CLASSES="$CLASSES,dev.codeforge.app.runtime.RuntimeInstallTest,dev.codeforge.app.runtime.SealedShellTest"
rm -rf "$RESULTS"
mkdir -p "$RESULTS"
: > "$EMU_LOG"
EMU_PID=""

finish() {
  if [ -n "$EMU_PID" ] && kill -0 "$EMU_PID" >/dev/null 2>&1; then
    "$ADB" logcat -d 2>&1 | tail -n 400 > "$RESULTS/logcat-tail.txt" || true
    kill "$EMU_PID" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      kill -0 "$EMU_PID" >/dev/null 2>&1 || break
      sleep 1
    done
    kill -9 "$EMU_PID" >/dev/null 2>&1 || true
  fi
  pkill -9 -f qemu-system >/dev/null 2>&1 || true
  "$ADB" kill-server >/dev/null 2>&1 || true
  tail -n 120 "$EMU_LOG" > "$RESULTS/emulator.txt" 2>/dev/null || true
}
trap finish EXIT

echo "::group::KVM (API $API)"
# As emulator_gate.sh: the udev rule, settled, and chmod as the fallback.
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
ACCEL_ARGS=""
CORES=2
ACCEL=kvm
if [ ! -w /dev/kvm ]; then
  ACCEL=tcg
  ACCEL_ARGS="-no-accel"
  CORES=4
fi
{
  echo "nproc=$(nproc)"
  echo "mem_total_mb=$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo)"
  echo "accel=$ACCEL"
} | tee "$RESULTS/host.txt"
echo "::endgroup::"

echo "::group::System image (API $API)"
# A full image, as the main gate uses: google_apis, then AOSP's default.
# API 27 has no google_apis image for x86_64.
SYSTEM_IMAGE=""
yes | "$SDKMANAGER" --licenses > /dev/null 2>&1 || true
for tag in google_apis default; do
  candidate="system-images;android-$API;$tag;x86_64"
  if "$SDKMANAGER" "emulator" "platform-tools" "$candidate" >> "$RESULTS/sysimg.txt" 2>&1 \
      && [ -d "$SDK/system-images/android-$API/$tag/x86_64" ]; then
    SYSTEM_IMAGE="$candidate"
    break
  fi
done
if [ -z "$SYSTEM_IMAGE" ]; then
  tail -n 30 "$RESULTS/sysimg.txt"
  echo "no x86_64 system image for API $API" | tee "$RESULTS/leg.txt"
  exit 1
fi
echo "system_image=$SYSTEM_IMAGE" | tee "$RESULTS/system-image.txt"
echo "::endgroup::"

framework_ready() {
  "$ADB" shell pm path android 2>/dev/null | grep -q '^package:' || return 1
  "$ADB" shell settings get global device_provisioned 2>/dev/null \
    | tr -d '\r' | grep -qE '^[0-9]+$' || return 1
  "$ADB" shell am broadcast -a dev.codeforge.gate.PING 2>&1 \
    | grep -q 'Broadcast completed' || return 1
}

echo "::group::Boot (API $API)"
export ANDROID_AVD_HOME="${ANDROID_AVD_HOME:-$HOME/.android/avd}"
mkdir -p "$ANDROID_AVD_HOME"
AVD="runtime$API"
echo no | "$AVDMANAGER" create avd -n "$AVD" -k "$SYSTEM_IMAGE" -d pixel_6 --force \
  > "$RESULTS/avd.txt" 2>&1 || { tail -n 30 "$RESULTS/avd.txt"; exit 1; }
# The payload APK, its extracted executables, and up to six installs of the
# runtime at once (about 300 MB each): the tests' roots and the app's own.
printf 'disk.dataPartition.size=8G\n' >> "$ANDROID_AVD_HOME/$AVD.avd/config.ini"
"$ADB" start-server >/dev/null 2>&1 || true
# shellcheck disable=SC2086 # ACCEL_ARGS is intentionally word-split.
"$EMU_BIN" -avd "$AVD" -no-window -gpu swiftshader_indirect -no-snapshot -noaudio \
  -no-boot-anim $ACCEL_ARGS -memory 4096 -cores "$CORES" > "$EMU_LOG" 2>&1 &
EMU_PID=$!
started=$(date +%s)
booted=""
for _ in $(seq 1 90); do
  kill -0 "$EMU_PID" >/dev/null 2>&1 || { echo "the emulator died while booting"; break; }
  if [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
    booted=1
    break
  fi
  sleep 10
done
if [ -z "$booted" ]; then
  echo "BOOT FAILED" | tee -a "$RESULTS/readiness.txt"
  tail -n 40 "$EMU_LOG"
  exit 1
fi
echo "boot_completed_after_s=$(($(date +%s) - started))" | tee -a "$RESULTS/readiness.txt"
stable=0
for _ in $(seq 1 120); do
  if framework_ready; then
    stable=$((stable + 1))
    [ "$stable" -ge 3 ] && break
  else
    stable=0
  fi
  sleep 5
done
if [ "$stable" -lt 3 ]; then
  echo "FRAMEWORK NEVER STABILISED" | tee -a "$RESULTS/readiness.txt"
  exit 1
fi
echo "framework_ready_after_s=$(($(date +%s) - started))" | tee -a "$RESULTS/readiness.txt"
"$ADB" shell settings put global hide_error_dialogs 1 >/dev/null 2>&1 || true
"$ADB" shell svc power stayon true >/dev/null 2>&1 || true
{
  echo "release=$("$ADB" shell getprop ro.build.version.release < /dev/null | tr -d '\r')"
  echo "sdk=$("$ADB" shell getprop ro.build.version.sdk < /dev/null | tr -d '\r')"
  echo "abi=$("$ADB" shell getprop ro.product.cpu.abi < /dev/null | tr -d '\r')"
  echo "kernel=$("$ADB" shell uname -r < /dev/null | tr -d '\r')"
} | tee -a "$RESULTS/readiness.txt"
# ADR-0007's third unknown: the image's WebView. Recorded, never judged here
# (a phone updates its WebView from the store; an emulator image does not).
"$ADB" shell dumpsys webviewupdate < /dev/null 2>&1 \
  | grep -iE 'current webview package|valid package' | head -n 4 | tr -d '\r' \
  > "$RESULTS/webview.txt" || true
cat "$RESULTS/webview.txt"
echo "::endgroup::"

echo "::group::Instrumented tests (API $API)"
{
  "$ADB" install -r -t "$APP_APK" && "$ADB" install -r -t "$TEST_APK"
} > "$RESULTS/install.txt" 2>&1 < /dev/null || { cat "$RESULTS/install.txt"; exit 1; }
"$ADB" shell df -h /data < /dev/null >> "$RESULTS/install.txt" 2>&1
"$ADB" logcat -c < /dev/null
timeout --kill-after=30s 30m "$ADB" shell am instrument -w -r -e class "$CLASSES" \
  "$APP_ID.test/androidx.test.runner.AndroidJUnitRunner" < /dev/null \
  > "$RESULTS/instrumented.txt" 2>&1
echo "am_instrument_exit=$?" >> "$RESULTS/readiness.txt"
for report in report commands-report exec-model-report sealed-shell-report; do
  "$ADB" shell run-as "$APP_ID" cat "files/runtime-gate/$report.txt" < /dev/null \
    > "$RESULTS/$report.txt" 2>&1 || true
done
"$ADB" logcat -d -s CodeForgeRuntimeGate:I CodeForgeRuntime:I ExecModel:I \
  AndroidRuntime:E TestRunner:I < /dev/null > "$RESULTS/logcat.txt" 2>&1 || true
tail -n 15 "$RESULTS/instrumented.txt"
echo "::endgroup::"

webview=$(sed -n 's/.*(\(.*\)).*/\1/p' "$RESULTS/webview.txt" | head -n 1)
python3 tool/ci/gate_results.py \
  --am "$RESULTS/instrumented.txt" \
  --figures "$RESULTS/report.txt" --figures "$RESULTS/commands-report.txt" \
  --figures "$RESULTS/exec-model-report.txt" --figures "$RESULTS/sealed-shell-report.txt" \
  --expect dev.codeforge.app.runtime.ExecModelTest:1 \
  --expect dev.codeforge.app.runtime.SealedShellTest:2 \
  --expect dev.codeforge.app.runtime.RuntimeInstallTest:6 \
  --expect dev.codeforge.app.runtime.RuntimeCommandsTest:6 \
  --require exec_model_audit_outside_apk=0 \
  --require audit_outside_apk=0 \
  --require warm_audit_outside_apk=0 \
  --require sealed_shell_audit_outside_apk=0 \
  --require sealed_shell_first_start_audit_outside_apk=0 \
  --require sealed_shell_second_start_audit_outside_apk=0 \
  --meta "leg=api-$API" --meta "api=$API" --meta "system_image=$SYSTEM_IMAGE" \
  --meta "accel=$ACCEL" --meta "webview=${webview:-unknown}" \
  --meta "apk_bytes=$(stat -c %s "$APP_APK")" \
  --out-json "$RESULTS/leg.json" --out-txt "$RESULTS/leg.txt"
