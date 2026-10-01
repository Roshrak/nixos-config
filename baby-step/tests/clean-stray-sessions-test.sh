#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$test_dir/../.." && pwd)"
if [ -x "$repo_root/dotfiles/.local/bin/clean-stray-sessions" ]; then
    helper="$repo_root/dotfiles/.local/bin/clean-stray-sessions"
else
    helper="$HOME/.local/bin/clean-stray-sessions"
fi
scratch="$(mktemp -d /tmp/clean-stray-sessions-test.XXXXXX)"
cleanup() {
    case "$scratch" in
        /tmp/clean-stray-sessions-test.*) rm -rf -- "$scratch" ;;
        *) printf 'Refusing unexpected test cleanup path: %s\n' "$scratch" >&2; return 1 ;;
    esac
}
trap cleanup EXIT

mkdir -p "$scratch/bin" "$scratch/proc/1001" "$scratch/proc/1002" "$scratch/proc/1003"
printf '%s\n' 1001 1002 1003 > "$scratch/pids"
printf '0\n' > "$scratch/logind-calls"
mkdir -p "$scratch/home/.config/chromium"
printf 'preserve this lock metadata\n' > "$scratch/home/.config/chromium/SingletonLock"

cat > "$scratch/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
cat "$CLEAN_STRAY_TEST_PIDS"
EOF
cat > "$scratch/bin/loginctl" <<'EOF'
#!/usr/bin/env bash
[ "${CLEAN_STRAY_TEST_LOGIND_FAIL:-0}" = 0 ] || exit 1
calls="$(cat "$CLEAN_STRAY_TEST_LOGIND_CALLS")"
calls=$((calls + 1))
printf '%s\n' "$calls" > "$CLEAN_STRAY_TEST_LOGIND_CALLS"
printf '51 aesc seat0 1096 user tty1 yes -\n'
if [ "${CLEAN_STRAY_TEST_OTHER_ACTIVE:-0}" = 1 ] ||
   { [ "${CLEAN_STRAY_TEST_REAPPEAR:-0}" = 1 ] && [ "$calls" -ge 2 ]; }; then
    printf '52 aesc seat0 1097 user tty2 yes -\n'
fi
if [ "${CLEAN_STRAY_TEST_PID_REUSED:-0}" = 1 ] && [ "$calls" -ge 2 ]; then
    uid="$(id -u)"
    {
        printf '1002 (chromium) S'
        for _ in {4..21}; do printf ' 0'; done
        printf ' 59999\n'
    } > "$CLEAN_STRAY_TEST_PROC/1002/stat"
fi
EOF
cat > "$scratch/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
[ "${CLEAN_STRAY_TEST_SYSTEMD_FAIL:-0}" = 0 ] || exit 1
printf 'active\n'
EOF
chmod 755 "$scratch/bin/pgrep" "$scratch/bin/loginctl" "$scratch/bin/systemctl"

make_process() {
    local pid="$1" scope="$2" start="$3" uid
    uid="$(id -u)"
    printf '%s\n' chromium > "$scratch/proc/$pid/comm"
    printf 'Name:\tchromium\nUid:\t%s\t%s\t%s\t%s\n' "$uid" "$uid" "$uid" "$uid" > "$scratch/proc/$pid/status"
    {
        printf '%s (chromium) S' "$pid"
        for _ in {4..21}; do printf ' 0'; done
        printf ' %s\n' "$start"
    } > "$scratch/proc/$pid/stat"
    printf '0::/user.slice/user-%s.slice/%s/app.slice/app-test.scope\n' "$uid" "$scope" > "$scratch/proc/$pid/cgroup"
}

make_process 1001 session-51.scope 5001
make_process 1002 session-52.scope 5002
make_process 1003 user@1000.service 5003

run_helper() {
    printf '0\n' > "$scratch/logind-calls"
    CLEAN_STRAY_TESTING=1 \
    CLEAN_STRAY_PROC_ROOT="$scratch/proc" \
    CLEAN_STRAY_TEST_PIDS="$scratch/pids" \
    CLEAN_STRAY_TEST_LOGIND_CALLS="$scratch/logind-calls" \
    CLEAN_STRAY_TEST_PROC="$scratch/proc" \
    HOME="$scratch/home" \
    PATH="$scratch/bin:/run/current-system/sw/bin" \
        "$helper"
}

output="$(run_helper)"
[[ "$output" == *"would send TERM to chromium pid=1002 ended-session=52"* ]]
[[ "$output" == *"TERM=1 unknown-or-unowned=1"* ]]
[[ "$(<"$scratch/home/.config/chromium/SingletonLock")" == 'preserve this lock metadata' ]]
printf 'Ended-session fixture: PASS\n'

output="$(CLEAN_STRAY_TEST_OTHER_ACTIVE=1 run_helper)"
[[ "$output" != *"would send TERM"* ]]
[[ "$output" == *"TERM=0"* ]]
printf 'Other active login session: PASS\n'

output="$(CLEAN_STRAY_TEST_REAPPEAR=1 run_helper)"
[[ "$output" != *"would send TERM"* ]]
[[ "$output" == *"TERM=0"* ]]
printf 'Session reappearing before TERM: PASS\n'

output="$(CLEAN_STRAY_TEST_PID_REUSED=1 run_helper)"
[[ "$output" != *"would send TERM"* ]]
[[ "$output" == *"TERM=0"* ]]
printf 'Reused PID before TERM: PASS\n'

if CLEAN_STRAY_TESTING=1 CLEAN_STRAY_PROC_ROOT="$scratch/proc" \
    CLEAN_STRAY_TEST_PIDS="$scratch/pids" \
    CLEAN_STRAY_TEST_LOGIND_CALLS="$scratch/logind-calls" \
    CLEAN_STRAY_TEST_PROC="$scratch/proc" CLEAN_STRAY_TEST_LOGIND_FAIL=1 \
    HOME="$scratch/home" \
    PATH="$scratch/bin:/run/current-system/sw/bin" "$helper" 2>&1 | rg -q 'left processes untouched'; then
    printf 'Logind failure: PASS\n'
else
    printf 'Logind failure test failed\n' >&2
    exit 1
fi

if CLEAN_STRAY_TESTING=1 CLEAN_STRAY_PROC_ROOT="$scratch/proc" \
    CLEAN_STRAY_TEST_PIDS="$scratch/pids" \
    CLEAN_STRAY_TEST_LOGIND_CALLS="$scratch/logind-calls" \
    CLEAN_STRAY_TEST_PROC="$scratch/proc" CLEAN_STRAY_TEST_SYSTEMD_FAIL=1 \
    HOME="$scratch/home" \
    PATH="$scratch/bin:/run/current-system/sw/bin" "$helper" 2>&1 | rg -q 'TERM=0'; then
    printf 'System scope query failure: PASS\n'
else
    printf 'System scope query failure test failed\n' >&2
    exit 1
fi
