#!/usr/bin/env bash
# Exercises only fetch_math/fetch_daily_reading from bin/daily-digest against
# an empty fixture vault. Never runs the digest itself.
# Run: bash tests/test-missing-folders.sh
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source <(sed -n '/^fetch_math() {/,/^}/p; /^fetch_daily_reading() {/,/^}/p' "$repo/bin/daily-digest")

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export VAULT="$work/vault" DATE=2026-11-16
mkdir -p "$VAULT"

pass=0 fail=0
check() {  # check <description> <expected> <actual>
    if [[ "$3" == "$2" ]]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL: %s\n  expected: %s\n  got:      %s\n' "$1" "$2" "$3"
    fi
}

# Like production, each section runs in $(...) under set -u; an unset
# variable there kills the subshell and loses the section's output.
status=0
out=$(fetch_math 2>&1) || status=$?
check "math: message"   "_no daily-math folder at $VAULT/30-Areas/Daily Math_" "$out"
check "math: exit status" 0 "$status"

status=0
out=$(fetch_daily_reading 2>&1) || status=$?
check "reading: message"   "_no daily-reading folder at $VAULT/30-Areas/Daily Reading_" "$out"
check "reading: exit status" 0 "$status"

echo "passed: $pass, failed: $fail"
(( fail == 0 ))
