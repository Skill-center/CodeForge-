#!/usr/bin/env bash
# Fetches the Gradle distribution that the wrapper pins, retrying, so that
# the APK builds after it find it in place. services.gradle.org sometimes
# stalls past the wrapper's read timeout: CI 42477797826 and phase gates
# 42477797842 and 42478331067 failed on it before any test ran. The
# workflows cache the distribution between runs, so this usually finds it
# already there. Run from app/.
set -uo pipefail

attempts=5
for attempt in $(seq 1 "$attempts"); do
  if (cd android && ./gradlew --version); then
    exit 0
  fi
  echo "::warning::fetching Gradle failed (attempt $attempt of $attempts)"
  if [ "$attempt" -lt "$attempts" ]; then
    sleep $((attempt * 20))
  fi
done
echo "::error::could not fetch Gradle from services.gradle.org"
exit 1
