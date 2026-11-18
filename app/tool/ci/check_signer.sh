#!/usr/bin/env bash
# The release build's signatures (Phase 5 W1): an APK or App Bundle must be
# signed by the key the release workflow chose, and by nothing else. The
# certificate's SHA-256 digest is read from the file (apksigner for an APK,
# keytool for a bundle, whose signature is a JAR signature) and compared with
# the key's, which the workflow read from its keystore.
#
#   check_signer.sh <file.apk | file.aab> <expected SHA-256 digest>
#   check_signer.sh --self-test
#
# The digest may be written with or without colons, in either case. Prints
# signer=<digest> and signer_check=pass|fail.
#
# A tool's output is read through here-strings, never `printf | grep -q`:
# under pipefail, grep -q leaving at its first match broke printf's pipe, and
# a verified bundle failed (CI 44394419519). The self-test's first case is
# that one.
set -uo pipefail

self_test() {
  local dir digest other failed=0 case_no=0
  dir=$(mktemp -d)
  mkdir -p "$dir/bin" "$dir/sdk/build-tools/99.0.0"
  digest="AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89"
  other="11:22:33:44:55:66:77:88:99:00:11:22:33:44:55:66:77:88:99:00:11:22:33:44:55:66:77:88:99:00:11:22"
  # The tools print what the case wrote for them.
  printf '#!/bin/sh\ncat "%s/keytool.txt"\n' "$dir" > "$dir/bin/keytool"
  printf '#!/bin/sh\ncat "%s/jarsigner.txt"\n' "$dir" > "$dir/bin/jarsigner"
  printf '#!/bin/sh\ncat "%s/apksigner.txt"\n' "$dir" > "$dir/sdk/build-tools/99.0.0/apksigner"
  chmod +x "$dir/bin/keytool" "$dir/bin/jarsigner" "$dir/sdk/build-tools/99.0.0/apksigner"
  touch "$dir/app.aab" "$dir/app.apk"
  certificate() {   # keytool -printcert's lines for one certificate
    printf 'Signer #%s:\n\nCertificate fingerprints:\n\t SHA1: 00:11\n\t SHA256: %s\n' "$1" "$2"
  }
  expect() {   # description, expected exit status, file, digest
    case_no=$((case_no + 1))
    local status
    PATH="$dir/bin:$PATH" ANDROID_HOME="$dir/sdk" bash "${BASH_SOURCE[0]}" "$3" "$4" \
      > "$dir/out.txt" 2>&1
    status=$?
    if [ "$status" -eq "$2" ]; then
      echo "self-test: $1 -> exit $status, as expected"
    else
      echo "self-test: FAILED: $1 -> exit $status, expected $2"
      sed 's/^/  | /' "$dir/out.txt"
      failed=1
    fi
  }

  # A bundle signed once, by the key, and verified, with a long warning after
  # the verdict: the pipe race of CI 44394419519.
  certificate 1 "$digest" > "$dir/keytool.txt"
  { printf '\njar verified.\n\nWarning:\n'
    yes 'This jar contains entries whose certificate chain is invalid.' | head -n 5000; } \
    > "$dir/jarsigner.txt"
  expect "a verified bundle with long warnings" 0 "$dir/app.aab" "$digest"
  # The same, with the digest written in lower case without colons.
  expect "the expected digest in another form" 0 "$dir/app.aab" \
    "$(printf '%s' "$digest" | tr -d ':' | tr 'A-F' 'a-f')"
  # Another key.
  expect "a bundle signed by another key" 1 "$dir/app.aab" "$other"
  # Two signers.
  { certificate 1 "$digest"; certificate 2 "$other"; } > "$dir/keytool.txt"
  expect "a bundle with two signers" 1 "$dir/app.aab" "$digest"
  # Not verified: jarsigner exits 0 for an unsigned file, so its words count.
  certificate 1 "$digest" > "$dir/keytool.txt"
  printf '\njar is unsigned.\n' > "$dir/jarsigner.txt"
  expect "a bundle jarsigner does not verify" 1 "$dir/app.aab" "$digest"
  # An APK signed once, by the key.
  printf 'Signer #1 certificate DN: CN=x\nSigner #1 certificate SHA-256 digest: %s\n' \
    "$(printf '%s' "$digest" | tr -d ':' | tr 'A-F' 'a-f')" > "$dir/apksigner.txt"
  expect "an APK signed by the key" 0 "$dir/app.apk" "$digest"
  # An APK with a second signer.
  printf 'Signer #2 certificate SHA-256 digest: %s\n' "$other" >> "$dir/apksigner.txt"
  expect "an APK with two signers" 1 "$dir/app.apk" "$digest"
  # Neither kind of file.
  expect "a file that is neither" 2 "$dir/app.zip" "$digest"

  rm -rf "$dir"
  if [ "$failed" -eq 0 ]; then
    echo "self-test: all $case_no cases as expected"
  fi
  return "$failed"
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit $?
fi

file="${1:?usage: check_signer.sh <apk|aab> <sha256>}"
want=$(printf '%s' "${2:?usage: check_signer.sh <apk|aab> <sha256>}" | tr -d ':[:space:]' | tr 'A-F' 'a-f')
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"

case "$file" in
  *.apk)
    # The newest build-tools whose apksigner runs on the job's Java 17 (as
    # same_signer.sh: build-tools 37's needs a newer Java and reads nothing).
    got=""
    signers=0
    for tool in $(ls -d "$SDK"/build-tools/*/apksigner 2>/dev/null | sort -rV); do
      out=$("$tool" verify --print-certs "$file" 2>&1)
      got=$(sed -n '/^Signer #1 certificate SHA-256 digest: /{s///p;q;}' <<< "$out")
      if [ -n "$got" ]; then
        signers=$(grep -c '^Signer #[0-9]* certificate SHA-256 digest:' <<< "$out")
        echo "apksigner=build-tools $(basename "$(dirname "$tool")")"
        break
      fi
    done
    ;;
  *.aab)
    out=$(keytool -printcert -jarfile "$file" 2>&1)
    got=$(sed -n '/^[[:space:]]*SHA256: /{s///p;q;}' <<< "$out")
    signers=$(grep -c '^[[:space:]]*SHA256: ' <<< "$out")
    # Not -strict: Play's upload key is self-signed, which -strict counts as an
    # error. And an unsigned file also exits 0, so the verdict is read.
    verdict=$(jarsigner -verify "$file" 2>&1)
    if ! grep -q '^jar verified\.' <<< "$verdict"; then
      echo "jarsigner: $(head -n 3 <<< "$verdict" | tr '\n' ' ')"
      got=""
    fi
    ;;
  *)
    echo "check_signer.sh: an .apk or an .aab, not $file" >&2
    exit 2 ;;
esac

got=$(printf '%s' "$got" | tr -d ':[:space:]' | tr 'A-F' 'a-f')
echo "signer=${got:-none} signers=${signers:-0} ($(basename "$file"))"
if [ -n "$got" ] && [ "$got" = "$want" ] && [ "${signers:-0}" -eq 1 ]; then
  echo "signer_check=pass"
  exit 0
fi
echo "signer_check=fail (expected $want)"
exit 1
