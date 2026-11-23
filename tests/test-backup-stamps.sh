#!/usr/bin/env bash
# Exercises only fetch_backups/stamp_status from bin/daily-digest, against
# fake stamp directories and a fake ssh on PATH. Never runs the digest itself.
# Run: bash tests/test-backup-stamps.sh
# Same shell options as bin/daily-digest; like production, the functions run
# inside $(...), where bash does not inherit errexit.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Pull just the two functions out of the script; sourcing it would run it.
# shellcheck source=/dev/null
source <(sed -n '/^fetch_backups() {/,/^}/p; /^stamp_status() {/,/^}/p; /^smart_escape() {/,/^}/p' "$repo/bin/daily-digest")

work="$(mktemp -d)"
trap 'chmod -R u+rwx "$work"; rm -rf "$work"' EXIT
# A section that aborts (non-zero) fails the whole run, as it should.
trap 'echo "FAIL: aborted at line $LINENO (fetch_backups exited non-zero?)" >&2' ERR

# Fake ssh: logs each call, skips "-o opt" pairs and the host, then runs the
# remote command locally (as sshd would hand it to a shell). FAKE_SSH_FAIL
# makes it behave like an unreachable host; FAKE_SSH_OUTPUT (when set, even
# empty) replaces the remote output, for malformed and partial replies.
mkdir -p "$work/bin"
cat > "$work/bin/ssh" <<'SSH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_SSH_LOG"
[[ -n "${FAKE_SSH_FAIL:-}" ]] && { echo "ssh: connect to host: timed out" >&2; exit 255; }
[[ -n "${FAKE_SSH_OUTPUT+set}" ]] && { cat >/dev/null; printf '%s' "$FAKE_SSH_OUTPUT"; exit 0; }
while [[ "$1" == -o ]]; do shift 2; done
shift
exec bash -c "$*"
SSH
cat > "$work/bin/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_SMART_STATE:-active}"
[[ "${FAKE_SMART_STATE:-active}" == active ]]
SYSTEMCTL
chmod +x "$work/bin/ssh" "$work/bin/systemctl"
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

check_count() {  # check_count <description> <expected> <actual>
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" =~ ^[0-9]+$ ]] && (( actual == expected )); then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL: %s\n  expected count: %s\n  got: %s\n' "$desc" "$expected" "$actual"
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
    export ACHERON_SMART_ALERT_DIR="$d/smart"
    export ACHERON_HOST=acheron-test
    export FAKE_SSH_LOG="$d/ssh.log"
    unset FAKE_SSH_FAIL FAKE_SSH_OUTPUT FAKE_SMART_STATE
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
check_count "no warnings" 0 "$(grep -c '⚠️' <<<"$out")"
check_count "one ssh call" 1 "$(wc -l < "$FAKE_SSH_LOG")"
check "host override + batch mode" "-o BatchMode=yes -o ConnectTimeout=10 acheron-test" < "$FAKE_SSH_LOG"

# --- bazzite restic stamps (local, proton) --------------------------------------
setup bazzite-fresh
out=$(fetch_backups)
check "bazzite local fresh"  "- local: OK, 1 h ago" <<<"$out"
check "bazzite proton fresh" "- proton: OK, 1 h ago" <<<"$out"

setup bazzite-stale
stamp_hours_ago "$D/bazzite-restic/local-ok" 27
stamp_hours_ago "$D/bazzite-restic/proton-ok" 26
out=$(fetch_backups)
check "bazzite local stale"       "- ⚠️ **local:** last good backup 27 h ago (" <<<"$out"
check "bazzite proton within 26 h" "- proton: OK, 26 h ago" <<<"$out"

setup bazzite-missing
rm "$D/bazzite-restic/local-ok"
: > "$D/bazzite-restic/proton-ok"
out=$(fetch_backups)
check "bazzite local missing" "- ⚠️ **local:** no successful backup recorded" <<<"$out"
check "bazzite proton empty"  "- ⚠️ **proton:** no successful backup recorded" <<<"$out"

setup bazzite-unparseable
echo "not a date" > "$D/bazzite-restic/local-ok"
stamp_hours_ago "$D/library/library-mirror-ok" 1
out=$(fetch_backups)
check "bazzite local unparseable" "- ⚠️ **local:** stamp unparseable (not a date)" <<<"$out"
check "proton after bad local"    "- proton: OK, 1 h ago" <<<"$out"
check "library after bad local"   "- library-mirror: OK, 1 h ago" <<<"$out"

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
    # Library mirror: unreadable file, then a directory we can't enter.
    setup library-unreadable-file
    stamp_hours_ago "$D/library/library-mirror-ok" 1
    chmod 000 "$D/library/library-mirror-ok"
    stamp_hours_ago "$D/acheron-restic/proton-ok" 2
    out=$(fetch_backups)
    check "library file not readable" "- ⚠️ **library-mirror:** stamp exists but is not readable (permissions)" <<<"$out"
    check "acheron still reported after unreadable library" "- acheron-test proton: OK, 2 h ago" <<<"$out"
    # bazzite local stamp exists but can't be read: reported as missing (it
    # does not yet say "not readable", unlike the checks below).
    setup bazzite-unreadable-file
    chmod 000 "$D/bazzite-restic/local-ok"
    out=$(fetch_backups 2>/dev/null)
    check "bazzite local not readable" "- ⚠️ **local:** no successful backup recorded" <<<"$out"
    check "proton after unreadable local" "- proton: OK, 1 h ago" <<<"$out"
    setup library-unreadable-dir
    stamp_hours_ago "$D/library/library-mirror-ok" 1
    chmod 000 "$D/library"
    out=$(fetch_backups)
    check "library dir not enterable" "- ⚠️ **library-mirror:** stamp exists but is not readable (permissions)" <<<"$out"
fi

# --- malformed timestamps ------------------------------------------------------
setup malformed-local
echo "not a date" > "$D/library/library-mirror-ok"
stamp_hours_ago "$D/acheron-restic/proton-ok" 2
stamp_hours_ago "$D/acheron-restic/local-ok" 2
stamp_hours_ago "$D/gitmirror/mirror-ok" 2
out=$(fetch_backups)
check "library unparseable" "- ⚠️ **library-mirror:** stamp unparseable (not a date)" <<<"$out"
check "later stamps still shown (proton)" "- acheron-test proton: OK, 2 h ago" <<<"$out"
check "later stamps still shown (mirror)" "- acheron-test git-mirror: OK, 2 h ago" <<<"$out"

setup malformed-ssh
stamp_hours_ago "$D/library/library-mirror-ok" 1
FAKE_SSH_OUTPUT="ok garbage
ok $(date -Is -d '-2 hours')
ok $(date -Is -d '-3 hours')
"
export FAKE_SSH_OUTPUT
out=$(fetch_backups)
check "proton unparseable via ssh" "- ⚠️ **acheron-test proton:** stamp unparseable (garbage)" <<<"$out"
check "local after bad proton" "- acheron-test local: OK, 2 h ago" <<<"$out"
check "mirror after bad proton" "- acheron-test git-mirror: OK, 3 h ago" <<<"$out"

# --- empty and partial ssh output ------------------------------------------------
setup empty-ssh
export FAKE_SSH_OUTPUT=""
out=$(fetch_backups)
check "empty: proton" "- ⚠️ **acheron-test proton:** no successful run recorded" <<<"$out"
check "empty: local"  "- ⚠️ **acheron-test local:** no successful run recorded" <<<"$out"
check "empty: mirror" "- ⚠️ **acheron-test git-mirror:** no successful run recorded" <<<"$out"

setup partial-ssh
FAKE_SSH_OUTPUT="ok $(date -Is -d '-2 hours')"
export FAKE_SSH_OUTPUT
out=$(fetch_backups)
check "partial: proton read" "- acheron-test proton: OK, 2 h ago" <<<"$out"
check "partial: local"  "- ⚠️ **acheron-test local:** no successful run recorded" <<<"$out"
check "partial: mirror" "- ⚠️ **acheron-test git-mirror:** no successful run recorded" <<<"$out"

# --- host unreachable ------------------------------------------------------------
setup unreachable
stamp_hours_ago "$D/library/library-mirror-ok" 1
export FAKE_SSH_FAIL=1
status=0
out=$(fetch_backups) || status=$?
check "unreachable warning" "- ⚠️ **acheron-test:** unreachable over ssh; backup, mirror and SMART status unknown" <<<"$out"
check "local stamps still reported" "- library-mirror: OK, 1 h ago" <<<"$out"
check "returns 0" "status=0" <<<"status=$status"
check_count "only one acheron line" 1 "$(grep -c acheron-test <<<"$out")"

# --- SMART alerts -------------------------------------------------------------
setup smart
out=$(fetch_backups)
check "missing SMART directory" "- acheron-test SMART: OK" <<<"$out"
mkdir "$ACHERON_SMART_ALERT_DIR"
out=$(fetch_backups)
check "empty SMART directory" "- acheron-test SMART: OK" <<<"$out"
printf '%s\n' 'time=2026-01-01' 'device=/dev/sda' 'type=health' 'message=Disk failing' > "$ACHERON_SMART_ALERT_DIR/sda.alert"
out=$(fetch_backups)
check "one alert" '- ⚠️ **acheron-test SMART:** /dev/sda health since 2026\-01\-01: Disk failing' <<<"$out"
printf '%s\n' 'time=now' 'device=/dev/nvme0' 'type=error' 'message=Second' > "$ACHERON_SMART_ALERT_DIR/nvme0.alert"
out=$(fetch_backups)
check_count "two alerts" 2 "$(grep -c 'acheron-test SMART:' <<<"$out")"
printf '%s\n' 'bad=data' > "$ACHERON_SMART_ALERT_DIR/broken.alert"
out=$(fetch_backups)
check "malformed alert" 'malformed alert file broken\.alert' <<<"$out"
printf '%s\n' 'time=now' 'device=/dev/sda' 'type=health' 'message=<tag> *bold* [link](url) & `code`' > "$ACHERON_SMART_ALERT_DIR/sda.alert"
out=$(fetch_backups)
check "escaped alert" '&lt;tag&gt; \*bold\* \[link\]\(url\) &amp; \`code\`' <<<"$out"
export FAKE_SMART_STATE=inactive
out=$(fetch_backups)
check "inactive SMART" 'monitoring is not running (state: inactive)' <<<"$out"
check_count "SMART still uses one ssh call per invocation" 7 "$(wc -l < "$FAKE_SSH_LOG")"

echo "passed: $pass, failed: $fail"
(( fail == 0 ))
