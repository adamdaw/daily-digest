#!/usr/bin/env bash
# Exercises only fetch_backups/stamp_status from bin/daily-digest, against
# fake stamp directories and a fake ssh on PATH. Never runs the digest itself.
# Run: bash tests/test-backup-stamps.sh
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Pull just the two functions out of the script; sourcing it would run it.
# shellcheck source=/dev/null
source <(sed -n '/^fetch_backups() {/,/^}/p; /^stamp_status() {/,/^}/p' "$repo/bin/daily-digest")

work="$(mktemp -d)"
trap 'chmod -R u+rwx "$work"; rm -rf "$work"' EXIT

# Fake ssh: logs each call, skips "-o opt" pairs and the host, then runs the
# remote command locally (as sshd would hand it to a shell). FAKE_SSH_FAIL
# makes it behave like an unreachable host.
mkdir -p "$work/bin"
cat > "$work/bin/ssh" <<'SSH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_SSH_LOG"
[[ -n "${FAKE_SSH_FAIL:-}" ]] && { echo "ssh: connect to host: timed out" >&2; exit 255; }
while [[ "$1" == -o ]]; do shift 2; done
shift
exec bash -c "$*"
SSH
chmod +x "$work/bin/ssh"
PATH="$work/bin:$PATH"

pass=0 fail=0
check() {  # check <description> <pattern> <<< output
    local desc="$1" pattern="$2" out
    out=$(cat)
    if grep -qF -- "$pattern" <<<"$out"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL: %s\n  expected line containing: %s\n  got:\n%s\n' "$desc" "$pattern" "$out"
    fi
}

stamp_hours_ago() { date -Is -d "-$2 hours" > "$1"; }

# Each case gets its own fixture tree and env.
setup() {
    local d="$work/$1"
    mkdir -p "$d/bazzite-restic" "$d/library" "$d/acheron-restic" "$d/gitmirror"
    export BACKUP_STATUS_DIR="$d/bazzite-restic"
    export LIBRARY_MIRROR_STATUS_DIR="$d/library"
    export ACHERON_BACKUP_STATUS_DIR="$d/acheron-restic"
    export ACHERON_MIRROR_STAMP="$d/gitmirror/mirror-ok"
    export ACHERON_HOST=acheron-test
    export FAKE_SSH_LOG="$d/ssh.log"
    unset FAKE_SSH_FAIL
    stamp_hours_ago "$d/bazzite-restic/local-ok" 1
    stamp_hours_ago "$d/bazzite-restic/proton-ok" 1
    D="$d"
}

# --- fresh -------------------------------------------------------------------
setup fresh
stamp_hours_ago "$D/library/library-mirror-ok" 1
stamp_hours_ago "$D/acheron-restic/proton-ok" 3
stamp_hours_ago "$D/acheron-restic/local-ok" 3
stamp_hours_ago "$D/gitmirror/mirror-ok" 5
out=$(fetch_backups)
check "fresh library"  "- library-mirror: OK, 1 h ago" <<<"$out"
check "fresh proton"   "- acheron-test proton: OK, 3 h ago" <<<"$out"
check "fresh local"    "- acheron-test local: OK, 3 h ago" <<<"$out"
check "fresh mirror"   "- acheron-test git-mirror: OK, 5 h ago" <<<"$out"
check "no warnings"    "$(printf '%s\n' "$out" | grep -c '⚠️' | sed 's/^0$/no-warnings/')" <<<"no-warnings"
check "one ssh call"   "1" <<<"$(wc -l < "$FAKE_SSH_LOG")"
check "host override + batch mode" "-o BatchMode=yes -o ConnectTimeout=10 acheron-test" < "$FAKE_SSH_LOG"

# --- stale (and just under each threshold) ------------------------------------
setup stale
stamp_hours_ago "$D/library/library-mirror-ok" 27
stamp_hours_ago "$D/acheron-restic/proton-ok" 31
stamp_hours_ago "$D/acheron-restic/local-ok" 29
stamp_hours_ago "$D/gitmirror/mirror-ok" 29
out=$(fetch_backups)
check "stale library"     "- ⚠️ **library-mirror:** last good run 27 h ago" <<<"$out"
check "stale proton"      "- ⚠️ **acheron-test proton:** last good run 31 h ago" <<<"$out"
check "local within 30 h" "- acheron-test local: OK, 29 h ago" <<<"$out"
check "stale mirror"      "- ⚠️ **acheron-test git-mirror:** last good run 29 h ago" <<<"$out"

# --- missing -------------------------------------------------------------------
setup missing
out=$(fetch_backups)
check "missing library" "- ⚠️ **library-mirror:** no successful run recorded" <<<"$out"
check "missing proton"  "- ⚠️ **acheron-test proton:** no successful run recorded" <<<"$out"
check "missing local"   "- ⚠️ **acheron-test local:** no successful run recorded" <<<"$out"
check "missing mirror"  "- ⚠️ **acheron-test git-mirror:** no successful run recorded" <<<"$out"

# --- unreadable ------------------------------------------------------------------
if (( EUID == 0 )); then
    echo "SKIP: unreadable cases (root can read anything)"
else
    # Today's real case: stamp inside a directory we can't enter.
    setup unreadable-dir
    stamp_hours_ago "$D/gitmirror/mirror-ok" 2
    chmod 000 "$D/gitmirror"
    out=$(fetch_backups)
    check "mirror dir not enterable" "- ⚠️ **acheron-test git-mirror:** stamp exists but is not readable (permissions)" <<<"$out"
    # Unreadable stamp file in a readable directory.
    setup unreadable-file
    stamp_hours_ago "$D/acheron-restic/proton-ok" 2
    chmod 000 "$D/acheron-restic/proton-ok"
    out=$(fetch_backups)
    check "proton file not readable" "- ⚠️ **acheron-test proton:** stamp exists but is not readable (permissions)" <<<"$out"
    check "mirror still missing, not unreadable" "- ⚠️ **acheron-test git-mirror:** no successful run recorded" <<<"$out"
fi

# --- host unreachable ------------------------------------------------------------
setup unreachable
stamp_hours_ago "$D/library/library-mirror-ok" 1
export FAKE_SSH_FAIL=1
out=$(fetch_backups); status=$?
check "unreachable warning" "- ⚠️ **acheron-test:** unreachable over ssh; backup and mirror status unknown" <<<"$out"
check "local stamps still reported" "- library-mirror: OK, 1 h ago" <<<"$out"
check "returns 0" "status=0" <<<"status=$status"
check "only one acheron line" "1" <<<"$(grep -c acheron-test <<<"$out")"

echo "passed: $pass, failed: $fail"
(( fail == 0 ))
