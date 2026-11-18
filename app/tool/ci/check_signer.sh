#!/usr/bin/env bash
# The release build's signatures (Phase 5 W1): an APK or App Bundle must be
# signed by the key the release workflow chose, and by nothing else. The
# certificate's SHA-256 digest is read from the file (apksigner for an APK,
# keytool for a bundle, whose signature is a JAR signature) and compared with
# the key's, which the workflow read from its keystore.
#
#   check_signer.sh <file.apk | file.aab> <expected SHA-256 digest>
#
# The digest may be written with or without colons, in either case. Prints
# signer=<digest> and signer_check=pass|fail.
set -uo pipefail

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
      got=$(printf '%s\n' "$out" | sed -n 's/^Signer #1 certificate SHA-256 digest: //p' | head -n 1)
      if [ -n "$got" ]; then
        signers=$(printf '%s\n' "$out" | grep -c '^Signer #[0-9]* certificate SHA-256 digest:')
        echo "apksigner=build-tools $(basename "$(dirname "$tool")")"
        break
      fi
    done
    ;;
  *.aab)
    out=$(keytool -printcert -jarfile "$file" 2>&1)
    got=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*SHA256: //p' | head -n 1)
    signers=$(printf '%s\n' "$out" | grep -c '^[[:space:]]*SHA256: ')
    # Not -strict: Play's upload key is self-signed, which -strict counts as an
    # error. And an unsigned file also exits 0, so the verdict is read.
    verdict=$(jarsigner -verify "$file" 2>&1)
    if ! printf '%s\n' "$verdict" | grep -q '^jar verified\.'; then
      echo "jarsigner: $(printf '%s\n' "$verdict" | head -n 3 | tr '\n' ' ')"
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
