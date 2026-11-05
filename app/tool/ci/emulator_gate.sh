#!/usr/bin/env bash
# Phase-gate emulator run (G1/G5/G6 evidence).
# Boots a headless API-36 emulator (manual boot, bounded polls — the approach
# proven by the t1 runtime audit), runs the three integration tests with a
# real process kill between restore A and B, then measures cold start.
# Run from app/ on a Linux CI runner with ANDROID_HOME set.
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
RESULTS="ci-results"
mkdir -p "$RESULTS"
EMU_PID=""

cleanup() { [ -n "$EMU_PID" ] && kill "$EMU_PID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "::group::KVM setup"
# GitHub Linux runners expose KVM only after this udev rule (harmless if the
# device never appears — we fall back to software emulation below).
echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' \
  | sudo tee /etc/udev/rules.d/99-kvm4all.rules >/dev/null 2>&1 || true
sudo udevadm control --reload-rules >/dev/null 2>&1 || true
sudo udevadm trigger --name-match=kvm >/dev/null 2>&1 || true
ACCEL_ARGS=""
if [ -w /dev/kvm ]; then
  echo "KVM available — hardware acceleration"
else
  echo "KVM unavailable — software emulation (TCG); budgets sized for it"
  ACCEL_ARGS="-no-accel"
fi
echo "::endgroup::"

echo "::group::System image"
# Full image, NOT an ATD. ATD ("automated test device") images strip system
# services and the GPU stack: the first gate run showed package/storage
# service crashes ("Can't find service: package", StorageManagerService NPE)
# and a Flutter surface that never sized. google_apis is the full-featured
# image used for UI/integration testing; `default` (AOSP) is the fallback.
SYSTEM_IMAGE="system-images;android-36;google_apis;x86_64"
yes | "$SDKMANAGER" --licenses > "$RESULTS/licenses.txt" 2>&1 || true
if ! "$SDKMANAGER" "emulator" "platform-tools" "$SYSTEM_IMAGE" \
    > "$RESULTS/sysimg.txt" 2>&1; then
  FALLBACK="${SYSTEM_IMAGE/;google_apis;/;default;}"
  echo "google_apis unavailable — falling back to $FALLBACK"
  "$SDKMANAGER" "emulator" "platform-tools" "$FALLBACK" \
    >> "$RESULTS/sysimg.txt" 2>&1 || { tail -30 "$RESULTS/sysimg.txt"; exit 1; }
  SYSTEM_IMAGE="$FALLBACK"
fi
echo "system_image=$SYSTEM_IMAGE" | tee "$RESULTS/system-image.txt"
echo "::endgroup::"

echo "::group::Create AVD + boot"
export ANDROID_AVD_HOME="${ANDROID_AVD_HOME:-$HOME/.android/avd}"
mkdir -p "$ANDROID_AVD_HOME"
echo no | "$AVDMANAGER" create avd -n gate -k "$SYSTEM_IMAGE" -d pixel_6 \
  --force > "$RESULTS/avd.txt" 2>&1 || { tail -30 "$RESULTS/avd.txt"; exit 1; }
"$EMU_BIN" -avd gate -no-window -gpu swiftshader_indirect -no-snapshot \
  -noaudio -no-boot-anim -dns-server 8.8.8.8,1.1.1.1 $ACCEL_ARGS \
  -memory 4096 -cores 4 > "$RESULTS/emulator.txt" 2>&1 &
EMU_PID=$!
booted=""
for i in $(seq 1 180); do
  if ! kill -0 "$EMU_PID" >/dev/null 2>&1; then
    echo "emulator process died during boot"; break
  fi
  if [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
    booted=1; break
  fi
  sleep 10
done
if [ -z "$booted" ]; then
  echo "BOOT FAILED"; tail -60 "$RESULTS/emulator.txt"; exit 1
fi
"$ADB" shell settings put global window_animation_scale 0 || true
"$ADB" shell settings put global transition_animation_scale 0 || true
"$ADB" shell settings put global animator_duration_scale 0 || true
"$ADB" shell svc power stayon true || true
echo "booted after ~$((i * 10))s"
echo "::endgroup::"

fail=0

echo "::group::Cold start measurement (G6, recorded not hard-failed)"
# Measured FIRST, on a fresh emulator: after several integration-test
# installs the package service can flake ("Broken pipe"). This is a
# record-only measurement (docs/PERFORMANCE.md) and never fails the gate.
# TCG numbers are environment-relative; the absolute budget is judged on
# real hardware in later phases.
installed=0
for attempt in 1 2 3; do
  if "$ADB" install -r build/app/outputs/flutter-apk/app-debug.apk \
      > "$RESULTS/install.txt" 2>&1; then
    installed=1; break
  fi
  echo "cold-start install attempt $attempt failed; retrying"
  sleep 5
done
: > "$RESULTS/coldstart.txt"
if [ "$installed" = "1" ]; then
  for run in 1 2 3 4 5; do
    "$ADB" shell am force-stop dev.codeforge.app
    sleep 2
    "$ADB" shell am start -W -n dev.codeforge.app/.MainActivity \
      | tr -d '\r' | tee -a "$RESULTS/coldstart.txt"
  done
  median=$(grep 'TotalTime:' "$RESULTS/coldstart.txt" | awk '{print $2}' \
    | sort -n | awk '{a[NR]=$1} END {if (NR==0) print 0; else print (NR%2) ? a[(NR+1)/2] : int((a[NR/2]+a[NR/2+1])/2)}')
  echo "cold_start_median_ms=${median:-0}" | tee "$RESULTS/coldstart-summary.txt"
else
  echo "cold_start_median_ms=0 install_failed_record_only=true" \
    | tee "$RESULTS/coldstart-summary.txt"
fi
# Leave the app stopped so the smoke test installs cleanly.
"$ADB" shell am force-stop dev.codeforge.app || true
echo "::endgroup::"

echo "::group::Integration — smoke"
flutter test integration_test/smoke_test.dart -d emulator-5554 \
  --reporter expanded --timeout=300s 2>&1 | tee "$RESULTS/smoke.txt" || fail=1
echo "::endgroup::"

echo "::group::Integration — restore A (establish state)"
# --no-uninstall is essential: `flutter test integration_test` uninstalls the
# app by default when the run ends, which wipes the very state the restore
# gate must verify. Keep it installed so force-stop is a pure process death.
flutter test integration_test/restore_a_test.dart -d emulator-5554 \
  --no-uninstall --reporter expanded --timeout=300s 2>&1 | tee "$RESULTS/restore_a.txt" || fail=1
# Evidence: the persisted envelope actually on disk before the process kill.
"$ADB" shell run-as dev.codeforge.app cat shared_prefs/FlutterSharedPreferences.xml \
  > "$RESULTS/prefs_after_a.txt" 2>&1 || true
echo "::endgroup::"

echo "::group::Process kill"
# Real process death — the G5 gate. install -r during the next test run
# preserves app data, exactly like an update over a killed process.
"$ADB" shell am force-stop dev.codeforge.app | tee "$RESULTS/force_stop.txt"
sleep 3
echo "::endgroup::"

echo "::group::Integration — restore B (verify survival)"
flutter test integration_test/restore_b_test.dart -d emulator-5554 \
  --reporter expanded --timeout=300s 2>&1 | tee "$RESULTS/restore_b.txt" || fail=1
echo "::endgroup::"

# Keep only the tail — full logcat is large and not needed as evidence.
"$ADB" logcat -d 2>&1 | tail -400 > "$RESULTS/logcat.txt" || true
echo "gate_result=$([ $fail -eq 0 ] && echo pass || echo fail)" \
  | tee "$RESULTS/gate-result.txt"
exit $fail
