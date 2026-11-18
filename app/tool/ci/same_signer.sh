#!/usr/bin/env bash
# The app and its test APK must be signed by one key, or Android refuses to
# start the instrumentation ("package dev.codeforge.app.test does not have a
# signature matching the target dev.codeforge.app"). Phase 4 W5's first
# runtime gates (44235180242) lost all five legs to that: the app came from
# `flutter build apk` and the test APK from a second Gradle run, signed by
# another debug key. The builds now make both in one Gradle run; this check
# runs before an emulator or a Test Lab phone is spent on them, and prints
# both certificates' SHA-256 digests.
#
#   same_signer.sh <app apk> <test apk>
set -uo pipefail

app="${1:?usage: same_signer.sh <app apk> <test apk>}"
test_apk="${2:?usage: same_signer.sh <app apk> <test apk>}"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
apksigner=$(ls -d "$SDK"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -n 1)
if [ -z "$apksigner" ] || [ ! -x "$apksigner" ]; then
  echo "::error::no apksigner in $SDK/build-tools"
  exit 2
fi

digest() {
  "$apksigner" verify --print-certs "$1" 2>/dev/null \
    | sed -n 's/^Signer #1 certificate SHA-256 digest: //p' | head -n 1
}

app_digest=$(digest "$app")
test_digest=$(digest "$test_apk")
echo "signer_app=${app_digest:-none} ($(basename "$app"))"
echo "signer_test=${test_digest:-none} ($(basename "$test_apk"))"
if [ -z "$app_digest" ] || [ "$app_digest" != "$test_digest" ]; then
  echo "::error::the app and its test APK are not signed by the same key"
  exit 1
fi
echo "same_signer=yes"
