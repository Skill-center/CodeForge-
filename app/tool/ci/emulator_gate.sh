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
#   restore_fixture.txt / restore_driver.txt / restore_ui.xml
#                                  Phase 3 W3 G5: the gate folder the restore
#                                  pair opens through Android's picker, the
#                                  driver's log and the picker's last screen
#   coldstart*.txt / perf.json     G6 measurement (record-only)
#   editing.txt                    Phase 2 W6 G5: find, replace, go to line
#   keys.txt / keys_injector.txt   Phase 2 W6 G6: toolbar touches and hardware
#                                  shortcuts, injected through adb (below);
#                                  since Phase 3 W3 the injector also records
#                                  which window had focus around each tap,
#                                  and keys_first_tap_<run>.png the screen
#                                  after each run's first tap; keys_events.txt
#                                  every ANR and crash since boot
#   backup.txt / backup_*.txt      Phase 3 W1 G6: Android backup on → restore,
#                                  off → a fresh app (local transport)
#   folders.txt / folders_*.txt    Phase 3 W2 G1: a folder from shared storage
#                                  through Android's picker, every operation
#                                  checked on disk, process death, a missing
#                                  folder and a lost grant (driver log,
#                                  picker screen, fixture, disk after part A)
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
# Android's error dialogs off (Phase 3 W3). In gate 43069846571 System UI
# stopped responding, and its "Application Not Responding" dialog held the
# window focus when the keys group tapped the editor: the tap and every key
# after it went to the dialog, never to the app (keys_injector.txt). With
# the dialogs hidden, Android ends a process that stops responding instead
# of asking, as if Close had been chosen: System UI starts again, and an
# ANR of the app itself ends the app, which its test then sees.
"$ADB" shell settings put global hide_error_dialogs 1 || true
echo "hide_error_dialogs=$("$ADB" shell settings get global hide_error_dialogs < /dev/null 2>/dev/null | tr -d '\r')" \
  | tee -a "$RESULTS/readiness.txt"
echo "::endgroup::"

# Signatures of failures that happen *before any test code runs* — install /
# framework / transport trouble. Only these are retried; an assertion failure
# is never retried, so a retry cannot turn a real failure into a pass.
INFRA_RE="Can't find service|Broken pipe|before system providers are installed|Cannot broadcast before boot completed|DeadSystemException|Failure calling service|device offline|no devices/emulators found|Unable to start the app on the device"
INFRA_SEEN=0

# run_itest <name> <test file> [extra flutter test args...]
# Each attempt has a wall-clock limit. `--timeout` covers the tests once
# they run, but `flutter test` itself can wait forever for an app that never
# connects: gate 42500759166 sat 65 minutes after installing the smoke test,
# until the job's limit stopped it. An attempt past the limit counts as an
# infrastructure failure and is retried. The longest group (keys) takes
# about 3 minutes with its build. A group may set ITEST_LIMIT and
# ITEST_ATTEMPTS for its own call (large files: longer, fewer attempts).
ITEST_LIMIT=10m
ITEST_ATTEMPTS=3
run_itest() {
  local name="$1" file="$2"
  shift 2
  local attempt rc=1 stuck
  for attempt in $(seq 1 "$ITEST_ATTEMPTS"); do
    wait_for_framework "$name#$attempt" 600 || true
    timeout --kill-after=30s "$ITEST_LIMIT" \
      flutter test "$file" -d emulator-5554 --reporter expanded \
      --timeout=300s "$@" 2>&1 | tee "$RESULTS/$name.txt"
    rc=${PIPESTATUS[0]}
    stuck=""
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
      stuck=1
      echo "$name: still running after $ITEST_LIMIT; stopped" \
        | tee -a "$RESULTS/$name.txt"
    fi
    echo "$name attempt=$attempt exit=$rc" | tee -a "$RESULTS/attempts.txt"
    [ "$rc" -eq 0 ] && return 0
    if [ -z "$stuck" ] && ! grep -qE "$INFRA_RE" "$RESULTS/$name.txt"; then
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

echo "::group::Integration — editing (Phase 2 W6, G5: find, replace, go to line)"
run_itest editing integration_test/editing_test.dart || fail=1
echo "::endgroup::"

echo "::group::Integration — keyboards (Phase 2 W6, G6: toolbar touches, hardware shortcuts)"
# keys_test asks for real input in its log, one request at a time
# (KEYGATE <run>.<n> tap <x> <y> | key <KEYCODE> | keys <KEYCODE>... |
# beside 0|1 | done), and waits for its effect. The injector polls the log
# for the newest request and answers each new one: taps and single keys
# through `adb shell input`, chords on the emulator's own keyboard (see
# press_chord), and `beside` through the soft-keyboard setting. Each
# poll is one `logcat -d`, so no long-lived log stream has to stay up. The
# test prints its requests in the root zone: a print inside a test goes to
# the test runner, not to the device log, which is why neither a streaming
# reader (gate 42479571017) nor a poll (gate 42482002996) saw request 1.
# The <run> part tells a retried test's requests from those of the attempt
# before.
# Linux key codes (input-event-codes.h) for the Android key codes the keys
# test uses in chords.
linux_code() {
  local letters=" Q16 W17 E18 R19 T20 Y21 U22 I23 O24 P25 A30 S31 D32 F33"
  letters="$letters G34 H35 J36 K37 L38 Z44 X45 C46 V47 B48 N49 M50 "
  local rest
  case "$1" in
    KEYCODE_CTRL_LEFT) echo 29 ;;
    KEYCODE_SHIFT_LEFT) echo 42 ;;
    KEYCODE_TAB) echo 15 ;;
    KEYCODE_[A-Z])
      rest="${letters#* "${1#KEYCODE_}"}"
      echo "${rest%% *}"
      ;;
    *) return 1 ;;
  esac
}

# Presses a chord's keys in order and lets them go in reverse on the
# emulator's hardware keyboard device ($kbd_dev), each change followed by a
# sync report as a real keyboard sends it. Android then reports the keys as
# that keyboard's, with its device and meta state. `input keycombination`
# injects from the virtual keyboard device, and the modifier's own press
# carries no meta state; Flutter trusts a virtual device's meta state, so it
# never sees the modifier held (gate 42497788524). The emulator console's
# `event send` was accepted but reached nothing (gate 42507384710). What the
# device said is left in $chord_answer.
chord_answer=""
press_chord() {
  local downs="" ups="" key code
  if [ -z "$kbd_dev" ]; then
    chord_answer="no keyboard device"
    return 1
  fi
  for key in "$@"; do
    code=$(linux_code "$key") || { chord_answer="no code for $key"; return 1; }
    downs="$downs sendevent $kbd_dev 1 $code 1; sendevent $kbd_dev 0 0 0;"
    ups="sendevent $kbd_dev 1 $code 0; sendevent $kbd_dev 0 0 0; $ups"
  done
  chord_answer=$(timeout 10 "$ADB" shell "$downs $ups echo sent" \
    < /dev/null 2>&1) || return 1
  case "$chord_answer" in
    *denied* | *rror* | *"not found"* | *[Uu]sage*) return 1 ;;
    *sent*) return 0 ;;
    *) return 1 ;;
  esac
}

# Which window has focus, where Android sends the keyboard, and which
# window the input dispatcher holds focused: what the keys step lacked when
# its first tap went nowhere (gates 42862715744 and 43007795087, attempt 1
# each, PHASE_3_PLAN As built W1 and W2). One line, the lines joined by ';'.
window_focus() {
  local window input
  window=$(timeout 10 "$ADB" shell dumpsys window < /dev/null 2>/dev/null \
    | tr -d '\r' \
    | grep -E 'mCurrentFocus=|mFocusedApp=|imeInputTarget|imeControlTarget' \
    | sed 's/^[[:space:]]*//' | sort -u | head -n 6 | paste -s -d ';' -)
  input=$(timeout 10 "$ADB" shell dumpsys input < /dev/null 2>/dev/null \
    | tr -d '\r' | grep -E -A1 'FocusedApplications|FocusedWindows' \
    | sed 's/^[[:space:]]*//' | grep -v '^--$' | head -n 4 | paste -s -d ';' -)
  echo "window: ${window:-nothing}; input: ${input:-nothing}"
}

key_injector() {
  local last="" line id kind status run focus
  echo "injector: polling the log for requests ($(date +%T))"
  while :; do
    line=$("$ADB" logcat -d -v raw -s flutter:I < /dev/null 2>/dev/null \
      | grep 'KEYGATE ' | tail -n 1 | tr -d '\r')
    # shellcheck disable=SC2086 # a request is a list of words by design.
    set -- ${line#*KEYGATE }
    id="${1:-}"
    kind="${2:-}"
    if [ -z "$id" ] || [ "$id" = "$last" ]; then
      sleep 0.25
      continue
    fi
    last="$id"
    shift 2 || true
    # adb shell reads stdin; keep it off whatever the loop is reading.
    case "$kind" in
      tap)
        # Focus before and after the tap, and the screen after each run's
        # first tap (the step that timed out). screencap draws nothing
        # into the app and turns on no accessibility service, which
        # uiautomator would (Flutter then builds its semantics tree).
        focus=$(window_focus)
        echo "request $id: focus before the tap: $focus"
        # An error dialog over the app takes the tap (gate 43069846571,
        # before the gate hid them): ask Android to close it, and look again.
        case "$focus" in
          *"Application Not Responding"* | *"Application Error"*)
            "$ADB" shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS \
              < /dev/null > /dev/null 2>&1
            sleep 1
            echo "request $id: an error dialog had the focus; after closing" \
              "system dialogs: $(window_focus)"
            ;;
        esac
        "$ADB" shell input tap "${1:-0}" "${2:-0}" < /dev/null
        status=$?
        sleep 0.5
        echo "request $id: tap $* (exit $status, $(date +%T))"
        echo "request $id: focus after the tap: $(window_focus)"
        run="${id%%.*}"
        if [ ! -f "$RESULTS/keys_first_tap_$run.png" ]; then
          timeout 20 "$ADB" exec-out screencap -p < /dev/null \
            > "$RESULTS/keys_first_tap_$run.png" 2>/dev/null \
            || rm -f "$RESULTS/keys_first_tap_$run.png"
          echo "request $id: screen after the first tap of run $run:" \
            "keys_first_tap_$run.png ($(wc -c < "$RESULTS/keys_first_tap_$run.png" 2>/dev/null || echo 0) bytes)"
        fi
        continue
        ;;
      key) "$ADB" shell input keyevent "${1:-}" < /dev/null ;;
      keys)
        if press_chord "$@"; then
          echo "request $id: keys $* (on $kbd_dev, $(date +%T))"
          continue
        fi
        echo "request $id: the keyboard device failed:" \
          "$(echo "$chord_answer" | tr '\n' ' ')"
        "$ADB" shell input keycombination "$@" < /dev/null
        ;;
      # The soft keyboard beside a hardware one, on (1) or off (0).
      beside)
        "$ADB" shell settings put secure show_ime_with_hard_keyboard \
          "${1:-0}" < /dev/null
        ;;
      done) echo "request $id: done ($(date +%T))"; return 0 ;;
      *) echo "request $id: unknown request '$kind'"; continue ;;
    esac
    status=$?
    echo "request $id: $kind $* (exit $status, $(date +%T))"
  done
}

# Chords are written to the emulator's keyboard device (press_chord), and
# the shell user may read input devices but not write them (Permission
# denied in gate 42509926650). google_apis images are userdebug builds that
# let adbd run as root; it restarts, so wait until it answers as root.
build_type=$("$ADB" shell getprop ro.build.type 2>/dev/null | tr -d '\r')
root_answer=$(timeout 30 "$ADB" root 2>&1 | tr -d '\r' | tr '\n' ' ')
adb_uid=""
case "$root_answer" in
  *cannot* | *rror*) ;;
  *)
    for _ in $(seq 1 30); do
      timeout 10 "$ADB" wait-for-device >/dev/null 2>&1 || true
      adb_uid=$(timeout 10 "$ADB" shell id -u < /dev/null 2>/dev/null \
        | tr -d '\r')
      [ "$adb_uid" = 0 ] && break
      sleep 1
    done
    ;;
esac
[ -n "$adb_uid" ] \
  || adb_uid=$(timeout 10 "$ADB" shell id -u < /dev/null 2>/dev/null \
    | tr -d '\r')

# AVDs report a hardware keyboard (keysexposed-qwerty in the configuration
# logged below), and Android then keeps the soft keyboard down. Ask for it
# beside the hardware keyboard, for this test only, so that the toolbar is
# touched with the soft keyboard up; the setting goes back afterwards.
ime_setting=$("$ADB" shell settings get secure show_ime_with_hard_keyboard \
  2>/dev/null | tr -d '\r')
"$ADB" shell settings put secure show_ime_with_hard_keyboard 1 >/dev/null 2>&1
config=$("$ADB" shell am get-config 2>/dev/null | tr -d '\r' | grep -m1 '^config:')
ime_now=$("$ADB" shell settings get secure show_ime_with_hard_keyboard \
  2>/dev/null | tr -d '\r')
# Which soft keyboard: input methods differ in the hardware keys they take.
ime=$("$ADB" shell settings get secure default_input_method 2>/dev/null \
  | tr -d '\r')
# The emulator's hardware keyboard: the first input device, in getevent's
# order, with both Ctrl and Tab. All such devices are logged.
devices=$(timeout 20 "$ADB" shell getevent -pl < /dev/null 2>/dev/null \
  | tr -d '\r')
kbd_list=$(echo "$devices" | awk '
  function emit() { if (dev != "" && ctrl && tab) print dev "\t" name }
  /^add device/ { emit(); dev = $4; name = ""; ctrl = 0; tab = 0 }
  /^[ \t]*name:/ { name = $0; sub(/^[ \t]*name:[ \t]*/, "", name) }
  /KEY_LEFTCTRL/ { ctrl = 1 }
  /KEY_TAB([^A-Z_]|$)/ { tab = 1 }
  END { emit() }')
kbd_dev=$(echo "$kbd_list" | head -n 1 | cut -f 1)
{
  echo "${config:-config: (am get-config gave nothing)}"
  echo "show_ime_with_hard_keyboard: ${ime_setting:-unset} -> ${ime_now:-unset}"
  echo "input method: ${ime:-unknown}"
  echo "adb shell user id: ${adb_uid:-?} (build ${build_type:-?}; adb" \
    "root said: ${root_answer:-nothing})"
  echo "keyboards with Ctrl and Tab:" \
    "$(echo "$kbd_list" | tr '\t' ' ' | paste -s -d ';' -)"
  echo "keyboard device: ${kbd_dev:-none found}"
} > "$RESULTS/keys_injector.txt"
# What the input devices report during the test: chords written to the
# keyboard device show up here, with times.
"$ADB" shell getevent -lt < /dev/null > "$RESULTS/keys_getevent.txt" 2>&1 &
getevent_reader=$!
key_injector >> "$RESULTS/keys_injector.txt" 2>&1 &
injector=$!
run_itest keys integration_test/keys_test.dart || fail=1
pkill -P "$injector" >/dev/null 2>&1 || true
kill "$injector" "$getevent_reader" >/dev/null 2>&1 || true
wait "$injector" "$getevent_reader" 2>/dev/null || true
# Every process that stopped responding or crashed since boot, from
# Android's event log, whatever the dialogs did: the keys flake's evidence.
"$ADB" logcat -d -b events < /dev/null 2>/dev/null | tr -d '\r' \
  | grep -E 'am_(anr|crash)' > "$RESULTS/keys_events.txt" || true
echo "keys_events: $(grep -c 'am_anr' "$RESULTS/keys_events.txt") ANRs," \
  "$(grep -c 'am_crash' "$RESULTS/keys_events.txt") crashes since boot" \
  | tee -a "$RESULTS/attempts.txt"
if [ -z "$ime_setting" ] || [ "$ime_setting" = "null" ]; then
  "$ADB" shell settings delete secure show_ime_with_hard_keyboard \
    >/dev/null 2>&1
else
  "$ADB" shell settings put secure show_ime_with_hard_keyboard \
    "$ime_setting" >/dev/null 2>&1
fi
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

echo "::group::Large files (Phase 2 W7, G7: open, scroll, typing, memory at 1/5/10 MiB)"
# The test opens 1, 5 and 10 MiB files in the real app (as .js and as .txt)
# and asks the DevTools driver for each measurement in the device log; the
# driver answers through files in the app's folder (run-as). It ends with
# large_1mb.js open: the release build then goes over the same data with
# `install -r` (same package and signing key), restores that session, and
# its memory is sampled: ADR-0004's release-like number (Flutter refuses
# profile mode on emulators, and a clean install opens no editor). Budget
# misses are information for the large-file policy; the test fails only
# when a step cannot run.
"$ADB" logcat -c >/dev/null 2>&1 || true
node ../editor/tool/large_cdp.mjs --adb "$ADB" --package "$APP_ID" \
  --out "$RESULTS/large_files_cdp.json" --timeout 2400 \
  > "$RESULTS/large_files_cdp.txt" 2>&1 &
large_driver=$!
large_ok=1
ITEST_LIMIT=18m ITEST_ATTEMPTS=2 run_itest large_files_itest \
  integration_test/large_files_test.dart --no-uninstall || large_ok=0
# The driver leaves by itself once the test says it is done.
for _ in $(seq 1 10); do
  kill -0 "$large_driver" 2>/dev/null || break
  sleep 1
done
kill "$large_driver" 2>/dev/null || true
wait "$large_driver" 2>/dev/null || true
if [ "$large_ok" = "1" ] && [ -f build/gate/app-release-x64.apk ]; then
  {
    "$ADB" shell am force-stop "$APP_ID"
    if "$ADB" install -r build/gate/app-release-x64.apk; then
      "$ADB" shell am start -W -n "$APP_ID/.MainActivity"
      # The session restores, the page loads and opens the 1 MiB file.
      sleep 25
      "$ADB" shell dumpsys activity activities | grep -m3 -E "mResumedActivity|topResumedActivity"
      node ../editor/tool/large_cdp.mjs --adb "$ADB" --package "$APP_ID" \
        --memory-only --out "$RESULTS/large_files_release.json"
    fi
  } > "$RESULTS/large_files_release.txt" 2>&1 \
    || echo "release-build memory sample failed (record-only)"
fi
node ../editor/tool/large_report.mjs \
  --itest "$RESULTS/large_files_itest.txt" \
  --cdp "$RESULTS/large_files_cdp.json" \
  --release "$RESULTS/large_files_release.json" \
  --env accel="$ACCEL" --env system_image="$SYSTEM_IMAGE" \
  --out-json "$RESULTS/large_files.json" \
  --out-txt "$RESULTS/large_files.txt" \
  || echo "large-file report failed (record-only)"
[ "$large_ok" = "1" ] || fail=1
echo "::endgroup::"

# Folders from shared storage, for the restore pair (Phase 3 W3: the last
# workspace is a folder) and the folders group (Phase 3 W2, G1): the gate
# folder /sdcard/Documents/cf-gate and a folder beside it come from the
# fixture (integration_test/folder_fixture.dart, written by
# tool/ci/write_folder_fixture.dart, then `adb push`). The test asks for one
# thing at a time in the device log (FOLDERGATE <run>.<n> pick <folder> |
# disk <path> | list <path> | rmtree | mkdir | done); folder_driver answers
# through the app's files folder (run-as: files/foldergate/<run>.<n>), where
# the test reads it (integration_test/folder_gate.dart). The driver runs
# only around the two groups that need it: its polling must not load adb
# while the keys group injects keys.
FOLDER_ROOT=/sdcard/Documents
GATE_FOLDER=cf-gate
GATE_OUTSIDE=cf-gate-outside
# A path the driver may act on: names of letters, digits and ._- only.
folder_safe_path() {
  case "$1" in
    "" | /* | */ | *//* | *[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  case "/$1/" in
    */../* | */./*) return 1 ;;
  esac
  return 0
}
# folder_answer <id> <answer>: the answer, cut to characters a shell word
# can hold, into the app's files folder.
folder_answer() {
  local answer
  answer=$(printf '%s' "$2" | tr -c 'A-Za-z0-9._,:/-' '?')
  "$ADB" shell "run-as $APP_ID sh -c 'mkdir -p files/foldergate && echo $answer > files/foldergate/$1'" \
    < /dev/null
}
# What is at <path> in the gate folder: the file's SHA-256, dir or absent.
folder_disk() {
  local p="$FOLDER_ROOT/$GATE_FOLDER/$1" kind
  kind=$("$ADB" shell "if [ -d $p ]; then echo dir; elif [ -f $p ]; then echo file; else echo absent; fi" \
    < /dev/null | tr -d '\r')
  if [ "$kind" = file ]; then
    "$ADB" shell sha256sum "$p" < /dev/null | tr -d '\r' | cut -d' ' -f1
  else
    echo "$kind"
  fi
}
# The names in <path> (. is the gate folder), dotfiles too, sorted by byte.
folder_list() {
  local p="$FOLDER_ROOT/$GATE_FOLDER"
  [ "$1" = . ] || p="$p/$1"
  "$ADB" shell ls -1a "$p" < /dev/null 2>&1 | tr -d '\r' | grep -vx '\.\|\.\.' \
    | LC_ALL=C sort | paste -sd, -
}
# The screen now (a dump that failed leaves no file, never an old screen),
# in FOLDER_UI: the folders group's file unless the caller names another.
FOLDER_UI="$RESULTS/folders_ui.xml"
folder_screen() {
  "$ADB" shell "rm -f /sdcard/codeforge-ui.xml; uiautomator dump /sdcard/codeforge-ui.xml" \
    < /dev/null > /dev/null 2>&1
  "$ADB" shell cat /sdcard/codeforge-ui.xml < /dev/null > "$FOLDER_UI" 2>/dev/null
}
# Android's folder picker, opened inside the gate folder: "Use this
# folder", once the folder's own entries show, then "Allow" in the dialog
# that asks. A picker that opened elsewhere is walked into Documents, then
# into the gate folder. The last screen stays in FOLDER_UI.
folder_pick() {
  local xy="" step _
  for _ in $(seq 1 40); do
    folder_screen
    if python3 tool/ci/ui_node.py "$FOLDER_UI" 'hello\.txt|notes|src' any > /dev/null \
        && xy=$(python3 tool/ci/ui_node.py "$FOLDER_UI" 'use this folder'); then
      break
    fi
    xy=""
    step=$(python3 tool/ci/ui_node.py "$FOLDER_UI" "$GATE_FOLDER") \
      || step=$(python3 tool/ci/ui_node.py "$FOLDER_UI" 'Documents') \
      || step=""
    # shellcheck disable=SC2086 # "x y", two words by design.
    [ -n "$step" ] && "$ADB" shell input tap $step < /dev/null
    sleep 1.5
  done
  if [ -z "$xy" ]; then
    echo "failed:no-use-this-folder"
    return 1
  fi
  # shellcheck disable=SC2086
  "$ADB" shell input tap $xy < /dev/null
  for _ in $(seq 1 30); do
    sleep 1
    folder_screen
    if xy=$(python3 tool/ci/ui_node.py "$FOLDER_UI" 'allow'); then
      # shellcheck disable=SC2086
      "$ADB" shell input tap $xy < /dev/null
      echo picked
      return 0
    fi
  done
  echo "failed:no-allow"
  return 1
}
folder_driver() {
  local last="" line id kind arg answer
  echo "driver: polling the log for requests ($(date +%T))"
  while :; do
    line=$("$ADB" logcat -d -v raw -s flutter:I < /dev/null 2>/dev/null \
      | grep 'FOLDERGATE [0-9.]* [a-z]' | tail -n 1 | tr -d '\r')
    # shellcheck disable=SC2086 # a request is a list of words by design.
    set -- ${line#*FOLDERGATE }
    id="${1:-}"
    kind="${2:-}"
    arg="${3:-}"
    if [ -z "$id" ] || [ "$id" = "$last" ]; then
      sleep 0.25
      continue
    fi
    last="$id"
    case "$kind" in
      pick) answer=$(folder_pick) ;;
      disk)
        if folder_safe_path "$arg"; then answer=$(folder_disk "$arg"); else answer=bad-path; fi
        ;;
      list)
        if [ "$arg" = . ] || folder_safe_path "$arg"; then
          answer=$(folder_list "$arg")
        else
          answer=bad-path
        fi
        ;;
      rmtree) "$ADB" shell rm -rf "$FOLDER_ROOT/$GATE_FOLDER" < /dev/null; answer=done ;;
      mkdir) "$ADB" shell mkdir -p "$FOLDER_ROOT/$GATE_FOLDER" < /dev/null; answer=done ;;
      done) echo "request $id: done ($(date +%T))"; continue ;;
      *) answer=unknown-request ;;
    esac
    folder_answer "$id" "$answer"
    echo "request $id: $kind $arg -> $answer ($(date +%T))"
  done
}
# folder_fixture_push <evidence file>: the gate folder and the folder
# beside it, exactly as the fixture has them.
folder_fixture_push() {
  "$ADB" shell rm -rf "$FOLDER_ROOT/$GATE_FOLDER" "$FOLDER_ROOT/$GATE_OUTSIDE" < /dev/null
  rm -rf build/gate/folder-fixture
  {
    dart run tool/ci/write_folder_fixture.dart build/gate/folder-fixture \
      && "$ADB" shell mkdir -p "$FOLDER_ROOT" < /dev/null \
      && "$ADB" push build/gate/folder-fixture/. "$FOLDER_ROOT/" < /dev/null
  } > "$RESULTS/$1" 2>&1 || return 1
  "$ADB" shell ls -laR "$FOLDER_ROOT/$GATE_FOLDER" "$FOLDER_ROOT/$GATE_OUTSIDE" \
    < /dev/null >> "$RESULTS/$1" 2>&1
}

echo "::group::Integration — restore pair (G5: establish → process death → verify)"
# --no-uninstall on part A is essential: `flutter test integration_test`
# uninstalls the app by default when the run ends, which would wipe the very
# state the gate must verify. Part B reinstalls with `install -r`, which
# keeps app data — exactly like an update landing on a killed process.
# Since Phase 3 W3 part A leaves two workspaces with unsaved text: the demo
# project, then the gate folder, opened through Android's real picker
# (folder_driver answers it), which stays the open one. Part B finds the
# folder again after the kill, then switches to the project and back.
restore_pair() {
  # Clean slate: every attempt is a complete, self-contained proof.
  "$ADB" uninstall "$APP_ID" >/dev/null 2>&1 || true
  folder_fixture_push restore_fixture.txt || return 1
  "$ADB" logcat -c < /dev/null
  run_itest restore_a integration_test/restore_a_test.dart --no-uninstall \
    || return 1
  # Evidence: the persisted envelope actually on disk before the kill.
  "$ADB" shell run-as "$APP_ID" cat shared_prefs/FlutterSharedPreferences.xml \
    > "$RESULTS/prefs_after_a.txt" 2>&1 || true
  # ... and the app database (tabs since Phase 2 W5).
  "$ADB" shell run-as "$APP_ID" ls -l files/ \
    > "$RESULTS/files_after_a.txt" 2>&1 || true
  # ... and the log file (Phase 3 W1): part A's last record, an error
  # logged just before this kill, must already be on disk.
  "$ADB" shell run-as "$APP_ID" ls -l no_backup/logs \
    > "$RESULTS/logs_after_a.txt" 2>&1 || true
  "$ADB" shell run-as "$APP_ID" tail -n 3 no_backup/logs/codeforge.log \
    >> "$RESULTS/logs_after_a.txt" 2>&1 || true
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
  # Part B switches workspaces, so it runs once per pair: a retry would
  # meet the workspace a failed attempt switched to. (Part A starts from a
  # clean slate each time, so its retries stand.)
  ITEST_ATTEMPTS=1 run_itest restore_b integration_test/restore_b_test.dart \
    || return 1
  # Unsaved text never reached the folder: as the fixture wrote it.
  echo "--- the gate folder after both parts:" >> "$RESULTS/restore_fixture.txt"
  "$ADB" shell sha256sum "$FOLDER_ROOT/$GATE_FOLDER/src/app.js" < /dev/null \
    >> "$RESULTS/restore_fixture.txt" 2>&1
}
FOLDER_UI="$RESULTS/restore_ui.xml" folder_driver \
  > "$RESULTS/restore_driver.txt" 2>&1 &
restore_driver_pid=$!
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
kill "$restore_driver_pid" 2>/dev/null || true
wait "$restore_driver_pid" 2>/dev/null || true
echo "restore_picker_picked=$(grep -c ' pick .*-> picked' "$RESULTS/restore_driver.txt")" \
  | tee -a "$RESULTS/attempts.txt"
# The folders group's driver must not find this group's requests in the
# log and answer them again; and the gate folders go until it pushes them.
"$ADB" logcat -c < /dev/null
"$ADB" shell rm -rf "$FOLDER_ROOT/$GATE_FOLDER" "$FOLDER_ROOT/$GATE_OUTSIDE" < /dev/null
[ "$restore_ok" = "1" ] || fail=1
echo "::endgroup::"

echo "::group::Integration — edit pair (G4: unsaved typing → renderer crash + process death → verify)"
# Part A types into main.js through the real page and never saves; it ends
# once the hot-exit journal and the saved tabs hold the text and the cursor.
# The plain app (same package and signing key, so `install -r` keeps the
# data) is then launched to restore that session, and its WebView renderer
# is killed: webview_flutter_android 4.14.1 has no onRenderProcessGone, so
# Android takes the app down with it — a renderer crash is a process death.
# That step is best effort and recorded in edit_renderer_crash.txt. A
# force-stop makes sure, and part B checks the exact text, the unsaved
# state and the cursor.
renderer_pids() {
  "$ADB" shell ps -A -o PID,NAME 2>/dev/null | tr -d '\r' \
    | awk '/sandboxed_process/ {print $1}'
}
crash_renderer() {
  local out="$RESULTS/edit_renderer_crash.txt" pids="" pid
  : > "$out"
  if [ ! -f build/gate/app-plain-debug.apk ]; then
    echo "no plain debug APK: renderer crash skipped" | tee -a "$out"
    return 0
  fi
  "$ADB" install -r build/gate/app-plain-debug.apk 2>&1 | tail -1 \
    | tee -a "$out"
  # Renderers run in isolated processes: killing one needs root (the
  # google_apis image allows it).
  "$ADB" root >/dev/null 2>&1 || true
  "$ADB" wait-for-device
  "$ADB" shell am start -n "$APP_ID/.MainActivity" 2>&1 | tr -d '\r' \
    | tee -a "$out"
  for _ in $(seq 1 60); do
    pids=$(renderer_pids)
    [ -n "$pids" ] && break
    sleep 1
  done
  if [ -z "$pids" ]; then
    echo "no WebView renderer within 60 s: renderer crash skipped" \
      | tee -a "$out"
    return 0
  fi
  # Let the restored session settle before the crash.
  sleep 5
  pids=$(renderer_pids)
  echo "app pid before: $("$ADB" shell pidof "$APP_ID" 2>/dev/null | tr -d '\r')" \
    | tee -a "$out"
  echo "renderer pids: $(echo $pids)" | tee -a "$out"
  for pid in $pids; do
    "$ADB" shell kill -9 "$pid" 2>&1 | tee -a "$out"
  done
  sleep 5
  pid=$("$ADB" shell pidof "$APP_ID" 2>/dev/null | tr -d '\r')
  echo "app pid after the renderer kill: ${pid:-none, the app died with its renderer}" \
    | tee -a "$out"
}
edit_pair() {
  # Clean slate: every attempt is a complete, self-contained proof.
  "$ADB" uninstall "$APP_ID" >/dev/null 2>&1 || true
  run_itest edit_a integration_test/edit_a_test.dart --no-uninstall \
    || return 1
  # Evidence: the app database (journal and tabs) on disk before the kill.
  "$ADB" shell run-as "$APP_ID" ls -l files/ \
    > "$RESULTS/edit_files_after_a.txt" 2>&1 || true
  crash_renderer || true
  "$ADB" shell am force-stop "$APP_ID"
  sleep 3
  local pid
  pid=$("$ADB" shell pidof "$APP_ID" 2>/dev/null | tr -d '\r')
  if [ -n "$pid" ]; then
    echo "process still alive after force-stop (pid $pid)" \
      | tee "$RESULTS/edit_process_after_kill.txt"
    return 1
  fi
  echo "no $APP_ID process after the renderer kill and am force-stop — process death confirmed" \
    | tee "$RESULTS/edit_process_after_kill.txt"
  run_itest edit_b integration_test/edit_b_test.dart || return 1
}
edit_ok=0
for pair in 1 2; do
  INFRA_SEEN=0
  if edit_pair; then
    edit_ok=1
    break
  fi
  [ "$INFRA_SEEN" = "1" ] || break
  echo "edit pair attempt $pair hit infrastructure failures — re-running the whole pair" \
    | tee -a "$RESULTS/attempts.txt"
done
[ "$edit_ok" = "1" ] || fail=1
echo "::endgroup::"

echo "::group::Integration — backup (Phase 3 W1, G6: switch on → backup → reinstall restores; switch off → a fresh app)"
# Android's backup with its local transport standing in for Google Drive
# (developer.android.com/identity/data/testingbackup). First the default:
# a backup of the app as installed, switch never touched, must hold nothing
# (the transport declines the empty backup, so Android keeps none). Then
# part A turns the switch on, saves a file and leaves an unsaved edit; CI
# backs the app up and reinstalls it, and Android restores it at install
# time; part B checks the project, the edit, the settings and the switch
# are back and the logs are not, then turns the switch off; after a second
# backup and reinstall part C checks the app is fresh and only the switch
# came back.
# `bmgr backupnow` skips a stopped app (a force-stop, as `flutter test`
# leaves it, marks it stopped), so the plain app is launched first; it
# runs in the background while Android backs it up, like a real backup.
# Record-only when the image has no local transport.
BACKUP_TRANSPORT=""
BACKUP_PREVIOUS=""
BACKUP_WAS_ENABLED=""
backup_setup() {
  local out="$RESULTS/backup_setup.txt"
  : > "$out"
  BACKUP_WAS_ENABLED=$("$ADB" shell bmgr enabled 2>&1 | tr -d '\r')
  echo "before: $BACKUP_WAS_ENABLED" | tee -a "$out"
  # The service itself can be off for the user (deactivated), apart from
  # the enabled flag.
  if "$ADB" shell bmgr activated 2>&1 | tr -d '\r' | tee -a "$out" \
      | grep -q deactivated; then
    "$ADB" shell bmgr activate true 2>&1 | tr -d '\r' | tee -a "$out"
  fi
  "$ADB" shell bmgr enable true 2>&1 | tr -d '\r' | tee -a "$out"
  "$ADB" shell bmgr list transports 2>&1 | tr -d '\r' \
    > "$RESULTS/backup_transports.txt"
  cat "$RESULTS/backup_transports.txt" >> "$out"
  BACKUP_PREVIOUS=$(awk '$1 == "*" {print $2}' "$RESULTS/backup_transports.txt" | head -1)
  BACKUP_TRANSPORT=$(grep -oE '[^ *]*LocalTransport' "$RESULTS/backup_transports.txt" | head -1)
  if [ -z "$BACKUP_TRANSPORT" ]; then
    echo "no local backup transport on this image" | tee -a "$out"
    return 2
  fi
  "$ADB" shell bmgr transport "$BACKUP_TRANSPORT" 2>&1 | tr -d '\r' | tee -a "$out"
  # Restore at install, and a finished setup (backups wait for it).
  "$ADB" shell settings put secure backup_auto_restore 1
  local setup
  setup=$("$ADB" shell settings get secure user_setup_complete 2>/dev/null | tr -d '\r')
  echo "user_setup_complete=$setup" | tee -a "$out"
  if [ "$setup" != "1" ]; then
    "$ADB" shell settings put secure user_setup_complete 1
  fi
  "$ADB" shell bmgr enabled 2>&1 | tr -d '\r' | tee -a "$out"
  echo "transport=$BACKUP_TRANSPORT previous=${BACKUP_PREVIOUS:-none}" | tee -a "$out"
}
# backup_wipe <evidence file>: nothing of the app left in the local
# transport, and no app. `bmgr wipe` ignores a package that is not
# installed, so the app is installed first if need be.
backup_wipe() {
  local out="$1"
  if ! "$ADB" shell pm path "$APP_ID" 2>/dev/null | grep -q '^package:'; then
    "$ADB" install build/gate/app-plain-debug.apk 2>&1 | tail -1 | tee -a "$out"
  fi
  "$ADB" shell bmgr wipe "$BACKUP_TRANSPORT" "$APP_ID" 2>&1 | tr -d '\r' \
    | tee -a "$out"
  "$ADB" uninstall "$APP_ID" 2>&1 | tr -d '\r' | tee -a "$out"
}
# backup_now <label> <expected result>: launch the plain app (clears the
# stopped state), send it to the background, back it up, keep what the
# agent recorded, and check bmgr's result for the app.
backup_now() {
  local label="$1" expected="$2" out="$RESULTS/backup_now_$1.txt" pid=""
  : > "$out"
  if [ ! -f build/gate/app-plain-debug.apk ]; then
    echo "no plain debug APK: cannot launch the app for a backup" | tee -a "$out"
    return 1
  fi
  "$ADB" install -r build/gate/app-plain-debug.apk 2>&1 | tail -1 | tee -a "$out"
  "$ADB" shell am start -n "$APP_ID/.MainActivity" 2>&1 | tr -d '\r' | tee -a "$out"
  for _ in $(seq 1 30); do
    pid=$("$ADB" shell pidof "$APP_ID" 2>/dev/null | tr -d '\r')
    [ -n "$pid" ] && break
    sleep 1
  done
  echo "app pid: ${pid:-none}" | tee -a "$out"
  # Let the restored session settle, then leave the app in the background.
  sleep 10
  "$ADB" shell input keyevent KEYCODE_HOME
  sleep 3
  "$ADB" shell bmgr backupnow "$APP_ID" 2>&1 | tr -d '\r' | tee -a "$out"
  "$ADB" shell run-as "$APP_ID" cat shared_prefs/codeforge.backup.xml \
    > "$RESULTS/backup_switch_$label.txt" 2>&1 || true
  grep -q "Package $APP_ID with result: $expected" "$out"
}
backup_group() {
  # Clean slate: a re-run must not restore the previous attempt's backup.
  backup_wipe "$RESULTS/backup_setup.txt"
  # The default, switch never touched: the agent writes nothing, which the
  # transport declines, so there is nothing to restore.
  backup_now default "Transport rejected" || return 1
  "$ADB" uninstall "$APP_ID" 2>&1 | tr -d '\r' | tee "$RESULTS/backup_uninstall_default.txt"
  run_itest backup_a integration_test/backup_a_test.dart --no-uninstall \
    || return 1
  backup_now on Success || return 1
  "$ADB" uninstall "$APP_ID" 2>&1 | tr -d '\r' | tee "$RESULTS/backup_uninstall_on.txt"
  run_itest backup_b integration_test/backup_b_test.dart --no-uninstall \
    || return 1
  # Evidence: what the restore put back (no_backup/ holds this run's log only).
  "$ADB" shell run-as "$APP_ID" ls -lR files shared_prefs no_backup \
    > "$RESULTS/backup_after_restore.txt" 2>&1 || true
  backup_now off Success || return 1
  "$ADB" uninstall "$APP_ID" 2>&1 | tr -d '\r' | tee "$RESULTS/backup_uninstall_off.txt"
  # Kept installed: the transport is wiped below, which needs the app.
  run_itest backup_c integration_test/backup_c_test.dart --no-uninstall \
    || return 1
}
backup_ok=0
backup_setup
backup_rc=$?
if [ "$backup_rc" -eq 2 ]; then
  echo "backup group skipped: no local transport (record-only)" \
    | tee "$RESULTS/backup.txt"
  backup_ok=1
else
  for pair in 1 2; do
    INFRA_SEEN=0
    if backup_group; then
      backup_ok=1
      break
    fi
    [ "$INFRA_SEEN" = "1" ] || break
    echo "backup group attempt $pair hit infrastructure failures — re-running the whole group" \
      | tee -a "$RESULTS/attempts.txt"
  done
  {
    echo "backup_group=$([ "$backup_ok" = "1" ] && echo pass || echo fail)"
    echo "transport=$BACKUP_TRANSPORT"
    grep -h "with result" "$RESULTS"/backup_now_*.txt 2>/dev/null
  } | tee "$RESULTS/backup.txt"
  # The annotations have no slot left: attempts.txt carries the verdict.
  cat "$RESULTS/backup.txt" >> "$RESULTS/attempts.txt"
  # Leave the device as it was: nothing of the app in the local transport
  # and no app (the cold-start install below must restore nothing), the
  # previous transport, and backups off again if they were.
  backup_wipe "$RESULTS/backup.txt"
  if [ -n "$BACKUP_PREVIOUS" ]; then
    "$ADB" shell bmgr transport "$BACKUP_PREVIOUS" 2>&1 | tr -d '\r' \
      | tee -a "$RESULTS/backup.txt"
  fi
  case "$BACKUP_WAS_ENABLED" in
    *disabled*)
      "$ADB" shell bmgr enable false 2>&1 | tr -d '\r' | tee -a "$RESULTS/backup.txt"
      ;;
  esac
fi
[ "$backup_ok" = "1" ] || fail=1
echo "::endgroup::"

echo "::group::Integration — folders (Phase 3 W2, G1: Android's folder picker, every operation checked on disk, process death, a missing folder, a lost grant)"
# /sdcard/Documents/cf-gate and a folder beside it come from the fixture
# (integration_test/folder_fixture.dart, written by
# tool/ci/write_folder_fixture.dart, then `adb push`). Part A taps Open
# Folder; this script drives Android's folder picker (DocumentsUI) with
# `uiautomator dump` and `input tap`, then answers the test's checks. As
# with the keys group, the test asks for one thing at a time in the device
# log (FOLDERGATE <run>.<n> pick <folder> | disk <path> | list <path> |
# rmtree | mkdir | done) and waits; the answer goes into the app's files
# folder through run-as (files/foldergate/<run>.<n>), where the test reads
# it (integration_test/folder_gate.dart). Between the parts the app is
# force-stopped: part B must find the folder open again, so its grant
# survived the process death. Each part runs once per attempt (a retry
# would meet the folder as the failed attempt left it); the whole pair
# runs again, from a fresh fixture, after an infrastructure failure.
folders_pair() {
  # Clean slate: no app (so no grant), and the folders as the fixture has
  # them.
  "$ADB" uninstall "$APP_ID" >/dev/null 2>&1 || true
  folder_fixture_push folders_fixture.txt || return 1
  "$ADB" logcat -c < /dev/null
  ITEST_ATTEMPTS=1 run_itest folders_a integration_test/folders_a_test.dart \
    --no-uninstall || return 1
  "$ADB" shell am force-stop "$APP_ID" < /dev/null
  sleep 3
  local pid
  pid=$("$ADB" shell pidof "$APP_ID" < /dev/null 2>/dev/null | tr -d '\r')
  if [ -n "$pid" ]; then
    echo "process still alive after force-stop (pid $pid)" \
      | tee "$RESULTS/folders_process_after_kill.txt"
    return 1
  fi
  echo "no $APP_ID process after am force-stop — process death confirmed" \
    | tee "$RESULTS/folders_process_after_kill.txt"
  # What part A left on disk, before part B looks.
  "$ADB" shell ls -laR "$FOLDER_ROOT/$GATE_FOLDER" < /dev/null \
    > "$RESULTS/folders_after_a.txt" 2>&1
  ITEST_ATTEMPTS=1 run_itest folders_b integration_test/folders_b_test.dart \
    --no-uninstall || return 1
  # The folder beside the gate folder: as the fixture wrote it.
  echo "--- the folder beside it after both parts:" >> "$RESULTS/folders_after_a.txt"
  "$ADB" shell sha256sum "$FOLDER_ROOT/$GATE_OUTSIDE/secret.txt" < /dev/null \
    >> "$RESULTS/folders_after_a.txt" 2>&1
}
folder_driver > "$RESULTS/folders_driver.txt" 2>&1 &
folders_driver_pid=$!
folders_ok=0
for pair in 1 2; do
  INFRA_SEEN=0
  if folders_pair; then
    folders_ok=1
    break
  fi
  [ "$INFRA_SEEN" = "1" ] || break
  echo "folders pair attempt $pair hit infrastructure failures — re-running the whole pair" \
    | tee -a "$RESULTS/attempts.txt"
done
kill "$folders_driver_pid" 2>/dev/null || true
wait "$folders_driver_pid" 2>/dev/null || true
{
  echo "folders_group=$([ "$folders_ok" = "1" ] && echo pass || echo fail)"
  echo "folders_picker_picked=$(grep -c ' pick .*-> picked' "$RESULTS/folders_driver.txt")"
  echo "folders_disk_checks=$(grep -c ': disk ' "$RESULTS/folders_driver.txt")" \
    "folders_listings=$(grep -c ': list ' "$RESULTS/folders_driver.txt")"
} | tee "$RESULTS/folders.txt"
# The annotations have no slot left: attempts.txt carries the verdict.
cat "$RESULTS/folders.txt" >> "$RESULTS/attempts.txt"
# Leave the device as it was: no gate folders, and no app.
"$ADB" shell rm -rf "$FOLDER_ROOT/$GATE_FOLDER" "$FOLDER_ROOT/$GATE_OUTSIDE" < /dev/null
"$ADB" uninstall "$APP_ID" >/dev/null 2>&1 || true
[ "$folders_ok" = "1" ] || fail=1
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
