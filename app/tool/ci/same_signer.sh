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

digest_with() {
  "$1" verify --print-certs "$2" 2>&1 | sed -n 's/^Signer #1 certificate SHA-256 digest: //p' | head -n 1
}

# The newest build-tools whose apksigner runs here: a newer one can need a
# newer Java than the job's 17 (the first version of this check took
# build-tools 37.0.0 and read nothing from either APK).
apksigner=""
app_digest=""
for tool in $(ls -d "$SDK"/build-tools/*/apksigner 2>/dev/null | sort -rV); do
  app_digest=$(digest_with "$tool" "$app")
  if [ -n "$app_digest" ]; then
    apksigner="$tool"
    break
  fi
  echo "apksigner of build-tools $(basename "$(dirname "$tool")") read no certificate:" \
    "$("$tool" verify --print-certs "$app" 2>&1 | head -n 2 | tr '\n' ' ')"
done
if [ -z "$apksigner" ]; then
  echo "::error::no apksigner in $SDK/build-tools could read the app's certificate"
  exit 2
fi
test_digest=$(digest_with "$apksigner" "$test_apk")
echo "apksigner=build-tools $(basename "$(dirname "$apksigner")")"
echo "signer_app=$app_digest ($(basename "$app"))"
echo "signer_test=${test_digest:-none} ($(basename "$test_apk"))"
if [ "$app_digest" != "$test_digest" ]; then
  echo "::error::the app and its test APK are not signed by the same key"
  exit 1
fi
echo "same_signer=yes"
