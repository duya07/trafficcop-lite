#!/usr/bin/env bash
# Isolated public CLI tests: fake dpkg/APT, paths redirected into this workspace.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [ "$(id -u)" -ne 0 ]; then
    printf 'SKIP dependency regression: root is required for ledger ownership checks.\n'
    exit 0
fi
TEST_ROOT=$(mktemp -d "$ROOT_DIR/tests/.dependency-test.XXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT
BIN="$TEST_ROOT/bin"
mkdir -p "$BIN"
for tool in bash awk cat chmod comm cut date dirname flock grep head id install ln mkdir mktemp mv readlink rm sed sort stat tac tee touch tr true; do
    ln -s "$(command -v "$tool")" "$BIN/$tool"
done
export PATH="$BIN"
export MOCK_BIN="$BIN" MOCK_DB="$TEST_ROOT/packages" MOCK_LOG="$TEST_ROOT/apt.log"
export DEPENDENCY_STATE_DIR="$TEST_ROOT/state"
export MOCK_CA="$TEST_ROOT/ca-bundle" MOCK_CA_ALT="$TEST_ROOT/ca-alt"
SCRIPT="$TEST_ROOT/trafficcop-lite.sh"
WORK="$TEST_ROOT/installed"
DOG="$TEST_ROOT/dog"
sed -e "s|WORK_DIR=\"/etc/trafficcop-lite\"|WORK_DIR=\"$WORK\"|" \
    -e "s|/usr/local/bin/port-traffic-dog.sh|$DOG/script|g" \
    -e "s|/etc/port-traffic-dog|$DOG/config|g" \
    -e "s|/etc/ssl/certs/ca-certificates.crt|$MOCK_CA|g" \
    -e "s|/etc/ssl/cert.pem|$MOCK_CA_ALT|g" \
    "$ROOT_DIR/trafficcop-lite.sh" > "$SCRIPT"

cat > "$BIN/dpkg-query" <<'MOCK'
#!/bin/bash
format='' package=''
for arg in "$@"; do
    case "$arg" in -f=*) format=${arg#-f=} ;; -*) ;; *) package=$arg ;; esac
done
if [ -z "$package" ] && [[ "$format" == *'${Pre-Depends}'* ]]; then
    [ "${MOCK_DPKG_FAIL_DEPS:-0}" != 1 ] || exit 42
    awk -F '\t' '{print $1 "\t" $2 "\t" $6 ", " $5}' "$MOCK_DB"
elif [ -z "$package" ]; then
    awk -F '\t' '{print $1 "\t" $2 "\t" $3 "\t" $4}' "$MOCK_DB"
elif [[ "$format" == *'${Essential}'* ]]; then
    awk -F '\t' -v p="$package" '$1 == p {print $3 "\t" $4; found=1} END {if (!found) exit 1}' "$MOCK_DB"
else
    awk -F '\t' -v p="$package" '$1 == p {print $2; found=1} END {if (!found) exit 1}' "$MOCK_DB"
fi
MOCK
cat > "$BIN/apt-get" <<'MOCK'
#!/bin/bash
set -e
printf '%s\n' "$*" >> "$MOCK_LOG"
action='' simulate=false after=false
packages=()
for arg in "$@"; do
    case "$arg" in
        --simulate) simulate=true ;;
        install|remove|update) action=$arg ;;
        --) after=true ;;
        *) if $after; then packages+=("$arg"); fi ;;
    esac
done
[ "$action" != update ] || exit 0
if $simulate; then
    for package in "${packages[@]}"; do
        if [ "$action" = install ] && [ "${MOCK_SKIP_PLAN:-0}" = 1 ] && [ "$package" = vnstat ]; then continue; fi
        if [ "$action" = install ]; then printf 'Inst %s (1 test)\n' "$package"
        else
            if [ "${MOCK_REMOVAL_UNQUAL:-0}" = 1 ]; then package=${package%:amd64}; fi
            printf 'Remv %s [1]\n' "$package"
        fi
    done
    if [ "$action" = install ] && [ "${MOCK_CONCURRENT:-0}" = 1 ]; then
        printf 'foreign-package\tinstalled\tno\tno\n' >> "$MOCK_DB"
    fi
    if [ "$action" = install ] && [ "${MOCK_TRANSITIVE:-0}" = 1 ]; then
        printf 'Inst libntc-test (1 test)\n'
    fi
    if [ "$action" = remove ] && [ "${MOCK_CASCADE:-0}" = 1 ]; then
        printf 'Remv foreign-package [1]\n'
    fi
    exit 0
fi
if [ "$action" = install ]; then
    count=0
    for package in "${packages[@]}"; do
        awk -F '\t' -v p="$package" '$1 != p' "$MOCK_DB" > "$MOCK_DB.tmp"
        mv "$MOCK_DB.tmp" "$MOCK_DB"
        if [ "${MOCK_PARTIAL_UNPACK:-0}" = 1 ]; then
            printf '%s\tunpacked\tno\tno\n' "$package" >> "$MOCK_DB"
            exit 42
        fi
        printf '%s\tinstalled\tno\tno\n' "$package" >> "$MOCK_DB"
        case "$package" in
            ca-certificates) printf 'test certificate\n' > "$MOCK_CA" ;;
            vnstat|jq|bc|curl) ln -s /bin/true "$MOCK_BIN/$package" ;;
            iproute2) ln -s /bin/true "$MOCK_BIN/ip"; ln -s /bin/true "$MOCK_BIN/tc" ;;
        esac
        count=$((count + 1))
        if [ "${MOCK_PARTIAL:-0}" = 1 ] && [ "$count" -eq 1 ]; then exit 42; fi
    done
    if [ "${MOCK_TRANSITIVE:-0}" = 1 ]; then
        if [ "${MOCK_ARCH_TRANSITIVE:-0}" = 1 ]; then printf 'libntc-test:amd64\tinstalled\tno\tno\n' >> "$MOCK_DB"
        else printf 'libntc-test\tinstalled\tno\tno\n' >> "$MOCK_DB"; fi
    fi
elif [ "$action" = remove ]; then
    for package in "${packages[@]}"; do
        if [ "${MOCK_PARTIAL_REMOVE:-0}" = 1 ]; then
            awk -F '\t' -v OFS='\t' -v p="$package" '$1 == p {$2="half-configured"} {print}' "$MOCK_DB" > "$MOCK_DB.tmp"
            mv "$MOCK_DB.tmp" "$MOCK_DB"
            exit 42
        fi
        awk -F '\t' -v p="$package" '$1 != p' "$MOCK_DB" > "$MOCK_DB.tmp"
        mv "$MOCK_DB.tmp" "$MOCK_DB"
        case "$package" in
            vnstat|jq|bc|curl) rm -f "$MOCK_BIN/$package" ;;
            iproute2) rm -f "$MOCK_BIN/ip" "$MOCK_BIN/tc" ;;
        esac
    done
else
    exit 90
fi
MOCK
cat > "$BIN/crontab" <<'MOCK'
#!/bin/bash
[ "${1:-}" = -l ] || exit 90
if [ -n "${MOCK_CRON_LINE:-}" ]; then printf '%s\n' "$MOCK_CRON_LINE"; exit 0; fi
printf 'no crontab for root\n' >&2
exit 1
MOCK
cat > "$BIN/pgrep" <<'MOCK'
#!/bin/bash
if [ "${MOCK_RUNNING:-0}" = 1 ]; then printf '999999\n'; exit 0; fi
exit 1
MOCK
cat > "$BIN/dpkg" <<'MOCK'
#!/bin/bash
[ "${1:-}" = --print-architecture ] || exit 90
printf 'amd64\n'
MOCK
chmod 755 "$BIN/dpkg-query" "$BIN/dpkg" "$BIN/apt-get" "$BIN/crontab" "$BIN/pgrep"
ln -s /bin/true "$BIN/pkill"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cli() { bash "$SCRIPT" --dependencies "$@"; }
reset_fixture() {
    rm -rf "$DEPENDENCY_STATE_DIR" "$WORK" "$DOG"
    printf 'test certificate\n' > "$MOCK_CA"
    rm -f "$MOCK_CA_ALT"
    rm -f "$BIN/vnstat" "$BIN/jq" "$BIN/bc" "$BIN/ip" "$BIN/tc" "$BIN/curl"
    ln -s /bin/true "$BIN/jq"
    ln -s /bin/true "$BIN/curl"
    printf '%s\n' \
        $'jq\tinstalled\tno\tno' $'curl\tinstalled\tno\tno' \
        $'cron\tinstalled\tno\tno' $'procps\tinstalled\tno\tno' $'coreutils\tinstalled\tyes\tno' $'ca-certificates\tinstalled\tno\tno' \
        $'sed\tinstalled\tno\tno' $'mawk\tinstalled\tno\tno' \
        $'util-linux\tinstalled\tno\tno' > "$MOCK_DB"
    : > "$MOCK_LOG"
    unset MOCK_TRANSITIVE MOCK_CASCADE MOCK_PARTIAL MOCK_CRON_LINE MOCK_RUNNING MOCK_SKIP_PLAN MOCK_ARCH_TRANSITIVE MOCK_PARTIAL_UNPACK MOCK_PARTIAL_REMOVE MOCK_REMOVAL_UNQUAL MOCK_CONCURRENT MOCK_DPKG_FAIL_DEPS || true
}
assert_owned() {
    local actual
    actual=$(cli owned)
    [ "$actual" = "$1" ] || fail "ownership mismatch: $actual"
}
assert_no_real_mutation() { [ ! -s "$MOCK_LOG" ] || fail 'unexpected APT invocation'; }

reset_fixture
if cli check > "$TEST_ROOT/check"; then fail 'missing dependencies reported as complete'; fi
grep -Fq '[缺失] vnstat' "$TEST_ROOT/check" || fail 'missing status absent'
cli owned > /dev/null
if [ -e "$DEPENDENCY_STATE_DIR" ] || [ -e "$WORK" ]; then fail 'check or owned wrote state'; fi
assert_no_real_mutation
bash -c 'source "$1"; declare -F dependency_cli >/dev/null' bash "$SCRIPT"
if [ -e "$DEPENDENCY_STATE_DIR" ] || [ -e "$WORK" ]; then fail 'sourcing wrote state'; fi
if printf 'n\n' | cli install > /dev/null; then fail 'cancelled installation returned success'; fi
assert_no_real_mutation
[ ! -e "$DEPENDENCY_STATE_DIR" ] || fail 'cancelled installation created ledger'
printf 'ok - read-only check, source, owned and cancellation\n'

export MOCK_TRANSITIVE=1
cli install --yes > "$TEST_ROOT/install-output" || fail 'installation failed'
assert_owned $'bc\niproute2\nlibntc-test\nvnstat'
[ "$(stat -c %a "$DEPENDENCY_STATE_DIR")" = 700 ] || fail 'ledger directory mode'
[ "$(stat -c %a "$DEPENDENCY_STATE_DIR/installed-packages")" = 600 ] || fail 'ledger file mode'
! grep -Eq '^install .* jq([[:space:]]|$)' "$MOCK_LOG" || fail 'preexisting jq installed'
[ "$(grep -c ' install -y ' "$MOCK_LOG")" -eq 1 ] || fail 'install count'
cli install --yes > /dev/null || fail 'idempotent install failed'
[ "$(grep -c ' install -y ' "$MOCK_LOG")" -eq 1 ] || fail 'idempotent install called APT'
: > "$DEPENDENCY_STATE_DIR/pending-before"
chmod 600 "$DEPENDENCY_STATE_DIR/pending-before"
if cli check > /dev/null 2>&1; then fail 'check did not report pending transaction'; fi
if cli install --yes > /dev/null 2>&1; then fail 'pending transaction ignored with all commands present'; fi
if cli remove --yes > /dev/null 2>&1; then fail 'pending transaction ignored on removal'; fi
rm "$DEPENDENCY_STATE_DIR/pending-before"
printf 'ok - new and transitive ownership, idempotence and pending fail-closed\n'

if printf 'n\n' | cli remove > /dev/null; then :; else fail 'removal cancellation failed'; fi
assert_owned $'bc\niproute2\nlibntc-test\nvnstat'
! grep -q ' remove -y ' "$MOCK_LOG" || fail 'cancelled removal ran APT'
export MOCK_CASCADE=1
if cli remove --yes > /dev/null 2>&1; then fail 'cascade removal accepted'; fi
unset MOCK_CASCADE
! grep -q ' remove -y ' "$MOCK_LOG" || fail 'cascade ran removal'
mkdir -p "$WORK"
touch "$WORK/trafficcop-lite-monitor.sh"
if cli remove --yes > /dev/null 2>&1; then fail 'installed monitor did not block removal'; fi
rm -rf "$WORK"
export MOCK_CRON_LINE='* * * * * /elsewhere/trafficcop-lite-telegram.sh -cron'
if cli remove --yes > /dev/null 2>&1; then fail 'active cron did not block removal'; fi
unset MOCK_CRON_LINE
export MOCK_RUNNING=1
if cli remove --yes > /dev/null 2>&1; then fail 'active process did not block removal'; fi
unset MOCK_RUNNING
mkdir -p "$DOG/config"
cli remove --yes > /dev/null || fail 'safe removal with Dog failed'
assert_owned $'bc\niproute2\nlibntc-test'
rm -rf "$DOG"
cli remove --yes > /dev/null || fail 'owned removal failed'
assert_owned ''
grep -q '^jq' "$MOCK_DB" || fail 'preexisting jq was removed'
if printf 'n\n' | cli remove --all > "$TEST_ROOT/all-output"; then :; else fail 'all cancellation failed'; fi
grep -Fq '保留系统基础/受保护包：coreutils' "$TEST_ROOT/all-output" || fail 'essential package not protected'
printf 'ok - cancellation, cascade, active scripts/cron/process, Dog and protected packages\n'

reset_fixture
export MOCK_SKIP_PLAN=1
if cli install --yes > /dev/null 2>&1; then fail 'incomplete APT plan accepted'; fi
! grep -q ' install -y ' "$MOCK_LOG" || fail 'incomplete APT plan was executed'
reset_fixture
export MOCK_CONCURRENT=1
if cli install --yes > /dev/null 2>&1; then fail 'changed package snapshot was accepted'; fi
! grep -q ' install -y ' "$MOCK_LOG" || fail 'changed package snapshot was installed'
[ ! -e "$DEPENDENCY_STATE_DIR/pending-before" ] || fail 'pre-install abort left pending transaction'
reset_fixture
export MOCK_TRANSITIVE=1 MOCK_ARCH_TRANSITIVE=1
cli install --yes > /dev/null || fail 'multiarch plan install failed'
assert_owned $'bc\niproute2\nlibntc-test:amd64\nvnstat'
export MOCK_REMOVAL_UNQUAL=1
cli remove --yes > /dev/null || fail 'native multiarch removal plan failed'
assert_owned ''
printf 'ok - incomplete plans rejected and native multiarch transitives recorded\n'

reset_fixture
export MOCK_TRANSITIVE=1
cli install --yes > /dev/null || fail 'protected dependency fixture install failed'
printf '%s\n' $'systemd\tinstalled\tno\tno\tlibbridge' \
    $'libbridge\tinstalled\tno\tno\t\tmissing-alternative | libntc-test:any (>= 1)' >> "$MOCK_DB"
cli remove --yes > "$TEST_ROOT/retained-output" || fail 'protected dependency closure removal failed'
assert_owned 'libntc-test'
grep -Fq 'libntc-test' "$TEST_ROOT/retained-output" || fail 'protected transitive dependency was not reported'
grep -q '^libntc-test' "$MOCK_DB" || fail 'protected transitive dependency removed'
export MOCK_DPKG_FAIL_DEPS=1
if cli remove --yes > /dev/null 2>&1; then fail 'failed dpkg dependency query accepted'; fi
unset MOCK_DPKG_FAIL_DEPS
printf 'ok - protected system dependency closure and query failure\n'

reset_fixture
rm "$MOCK_CA"
printf 'alternate certificate\n' > "$MOCK_CA_ALT"
cli check > "$TEST_ROOT/ca-alt-check" || true
grep -Fq '[可用] ca-certificates' "$TEST_ROOT/ca-alt-check" || fail 'alternate CA path not recognised'
rm "$MOCK_CA_ALT"
if cli check > "$TEST_ROOT/ca-check"; then fail 'missing certificate bundle reported available'; fi
grep -Fq '[异常] ca-certificates' "$TEST_ROOT/ca-check" || fail 'broken CA bundle not reported'
if cli install --yes > /dev/null 2>&1; then fail 'installed but missing CA bundle accepted'; fi
assert_no_real_mutation
awk -F '\t' '$1 != "ca-certificates"' "$MOCK_DB" > "$MOCK_DB.tmp"
mv "$MOCK_DB.tmp" "$MOCK_DB"
cli install --yes > /dev/null || fail 'missing certificate bundle install failed'
grep -Fxq 'ca-certificates' "$DEPENDENCY_STATE_DIR/installed-packages" || fail 'new CA package not recorded'
printf 'ok - CA bundle capability, broken installed package and missing install\n'

reset_fixture
printf 'vnstat\tinstalled\tno\tno\n' >> "$MOCK_DB"
if cli check > "$TEST_ROOT/broken"; then fail 'installed but broken reported healthy'; fi
grep -Fq '[异常] vnstat' "$TEST_ROOT/broken" || fail 'broken package not reported'
if cli install --yes > /dev/null 2>&1; then fail 'installed but broken accepted'; fi
if bash "$SCRIPT" --install --yes > /dev/null 2>&1; then fail 'main install skipped broken dependencies'; fi
assert_no_real_mutation
reset_fixture
printf 'vnstat\thalf-configured\tno\tno\n' >> "$MOCK_DB"
if cli install --yes > "$TEST_ROOT/half" 2>&1; then fail 'half-configured package accepted'; fi
grep -Fq 'half-configured' "$TEST_ROOT/half" || fail 'partial dpkg state not reported'
assert_no_real_mutation
reset_fixture
printf 'vnstat\tconfig-files\tno\tno\n' >> "$MOCK_DB"
cli install --yes > /dev/null || fail 'previous configuration install failed'
assert_owned $'bc\niproute2'
printf 'ok - incomplete package rejected and preexisting package state not claimed\n'
reset_fixture
export MOCK_PARTIAL=1
if cli install --yes > /dev/null 2>&1; then fail 'partial install accepted'; fi
assert_owned 'vnstat'
[ ! -e "$DEPENDENCY_STATE_DIR/pending-before" ] || fail 'completed partial snapshot not cleared'
printf 'ok - installed-but-broken and partial failure ownership\n'

reset_fixture
export MOCK_PARTIAL_UNPACK=1
if cli install --yes > /dev/null 2>&1; then fail 'unpacked partial install accepted'; fi
[ -f "$DEPENDENCY_STATE_DIR/pending-before" ] || fail 'unpacked install lost before snapshot'
[ -f "$DEPENDENCY_STATE_DIR/pending-plan" ] || fail 'unpacked install lost plan snapshot'
assert_owned ''
if cli install --yes > /dev/null 2>&1; then fail 'unpacked pending transaction ignored'; fi
reset_fixture
export MOCK_TRANSITIVE=1
cli install --yes > /dev/null || fail 'partial removal fixture install failed'
export MOCK_PARTIAL_REMOVE=1
if cli remove --yes > /dev/null 2>&1; then fail 'partial removal accepted'; fi
assert_owned $'bc\niproute2\nlibntc-test\nvnstat'
unset MOCK_PARTIAL_REMOVE
if cli remove --yes > /dev/null 2>&1; then fail 'incomplete removal package ignored'; fi
printf 'ok - unfinished install retains pending evidence and failed removal retains ownership\n'

reset_fixture
export MOCK_TRANSITIVE=1
MONITOR="$TEST_ROOT/monitor.sh"
sed -e "s|^export PATH=.*|export PATH=\"$BIN\"|" \
    -e "s|WORK_DIR=\"/etc/trafficcop-lite\"|WORK_DIR=\"$WORK\"|" \
    -e "s|/etc/ssl/certs/ca-certificates.crt|$MOCK_CA|g" \
    -e "s|/etc/ssl/cert.pem|$MOCK_CA_ALT|g" \
    "$ROOT_DIR/trafficcop-lite-monitor.sh" > "$MONITOR"
bash -c 'source "$1"; PACKAGE_MANAGER=apt; LOG_FILE="$2"; install_packages vnstat bc iproute2' \
    bash "$MONITOR" "$TEST_ROOT/monitor.log" > /dev/null || fail 'standalone monitor ledger install failed'
assert_owned $'bc\niproute2\nlibntc-test\nvnstat'
rm "$MOCK_CA"
awk -F '\t' '$1 != "ca-certificates"' "$MOCK_DB" > "$MOCK_DB.tmp"
mv "$MOCK_DB.tmp" "$MOCK_DB"
unset MOCK_TRANSITIVE
bash -c 'source "$1"; LOG_FILE="$2"; ensure_service_running() { return 0; }; ensure_vnstat_daemon_running() { return 0; }; vnstat() { printf "vnStat 2.10\n"; }; check_and_install_packages' \
    bash "$MONITOR" "$TEST_ROOT/monitor.log" > /dev/null || fail 'standalone monitor missed certificate installation'
[ -s "$MOCK_CA" ] || fail 'standalone monitor did not restore certificate bundle'
grep -Fxq 'ca-certificates' "$DEPENDENCY_STATE_DIR/installed-packages" || fail 'standalone monitor did not record CA package'

TELEGRAM="$TEST_ROOT/telegram.sh"
MACHINE="$TEST_ROOT/machine.sh"
for component in telegram machine; do
    case "$component" in telegram) src="$ROOT_DIR/trafficcop-lite-telegram.sh"; dest="$TELEGRAM" ;;
        machine) src="$ROOT_DIR/trafficcop-lite-machine-limit.sh"; dest="$MACHINE" ;; esac
    sed -e "s|WORK_DIR=\"/etc/trafficcop-lite\"|WORK_DIR=\"$WORK\"|" \
        -e "s|/etc/ssl/certs/ca-certificates.crt|$MOCK_CA|g" \
        -e "s|/etc/ssl/cert.pem|$MOCK_CA_ALT|g" "$src" > "$dest"
done
rm "$MOCK_CA"
if bash -c 'source "$1"; check_runtime_dependencies cron' bash "$TELEGRAM" > /dev/null; then fail 'standalone Telegram ignored missing CA'; fi
if bash -c 'source "$1"; machine_require_dependencies' bash "$MACHINE" > /dev/null; then fail 'standalone machine manager ignored missing CA'; fi
printf 'ok - standalone components detect missing certificate bundle\n'
printf 'ok - standalone monitor records APT transactions in the same ledger\n'

reset_fixture
cat > "$BIN/dnf" <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> "$MOCK_LOG"
for package in "$@"; do
    case "$package" in
        vnstat|jq|bc|curl) ln -s /bin/true "$MOCK_BIN/$package" ;;
        ca-certificates) printf 'test certificate\n' > "$MOCK_CA" ;;
        iproute|iproute2) ln -s /bin/true "$MOCK_BIN/ip"; ln -s /bin/true "$MOCK_BIN/tc" ;;
    esac
done
MOCK
chmod 755 "$BIN/dnf"
mv "$BIN/apt-get" "$BIN/apt-disabled"
for manager in dnf yum apk pacman; do
    reset_fixture
    [ "$manager" = dnf ] || mv "$BIN/dnf" "$BIN/$manager"
    if cli check > /dev/null; then fail "$manager missing dependencies reported complete"; fi
    cli install --yes > /dev/null || fail "$manager adapter failed"
    case "$manager" in
        dnf|yum) expected='install -y vnstat bc iproute' ;;
        apk) expected='add --no-cache vnstat bc iproute2' ;;
        pacman) expected='-S --needed --noconfirm vnstat bc iproute2' ;;
    esac
    grep -Fq -- "$expected" "$MOCK_LOG" || fail "$manager package mapping wrong"
    rm "$MOCK_CA"
    if cli check > "$TEST_ROOT/non-apt-ca"; then fail "$manager missing certificate reported available"; fi
    grep -Fq '[缺失] ca-certificates' "$TEST_ROOT/non-apt-ca" || fail "$manager CA capability missing from report"
    cli install --yes > /dev/null || fail "$manager missing certificate install failed"
    grep -q 'ca-certificates' "$MOCK_LOG" || fail "$manager CA package not selected"
    if cli owned > /dev/null 2>&1; then fail "$manager ledger was claimed"; fi
    if cli remove --yes > /dev/null 2>&1; then fail "$manager auto-removal was accepted"; fi
    [ ! -e "$DEPENDENCY_STATE_DIR" ] || fail "$manager adapter created APT ledger"
    [ "$manager" = dnf ] || mv "$BIN/$manager" "$BIN/dnf"
done
mv "$BIN/apt-disabled" "$BIN/apt-get"
rm "$BIN/dnf"
printf 'ok - non-APT installation adapters and explicit ledger limitation\n'

reset_fixture
mkdir -m 700 "$DEPENDENCY_STATE_DIR"
# The literal shell expression is intentionally untrusted ledger data.
# shellcheck disable=SC2016
printf '%s\n' '$(touch unexpected)' > "$DEPENDENCY_STATE_DIR/installed-packages"
chmod 600 "$DEPENDENCY_STATE_DIR/installed-packages"
if cli owned > /dev/null 2>&1; then fail 'invalid ledger accepted'; fi
[ ! -e "$TEST_ROOT/unexpected" ] || fail 'ledger executed'
printf 'vnstat\n' > "$DEPENDENCY_STATE_DIR/installed-packages"
ln "$DEPENDENCY_STATE_DIR/installed-packages" "$TEST_ROOT/hardlink"
if cli owned > /dev/null 2>&1; then fail 'hard-linked ledger accepted'; fi
rm "$TEST_ROOT/hardlink"
chmod 644 "$DEPENDENCY_STATE_DIR/installed-packages"
if cli owned > /dev/null 2>&1; then fail 'world-readable ledger accepted'; fi
rm -rf "$DEPENDENCY_STATE_DIR"
NO_COLOR=1 COLUMNS=30 TERM=dumb bash "$SCRIPT" < /dev/null > "$TEST_ROOT/menu" 2>&1 || fail 'main EOF did not exit'
! grep -q "$(printf '\033')" "$TEST_ROOT/menu" || fail 'NO_COLOR emitted ANSI'
! grep -Fq '╔' "$TEST_ROOT/menu" || fail 'main banner exceeds narrow width'
grep -Fq '10) 依赖检测、安装与卸载' "$TEST_ROOT/menu" || fail 'dependency menu absent'
COLUMNS=30 TERM=dumb NO_COLOR='' bash -c 'source "$1"; view_config' bash "$SCRIPT" < /dev/null > "$TEST_ROOT/config-menu" || fail 'config EOF failed'
! grep -Fq '╔' "$TEST_ROOT/config-menu" || fail 'config banner exceeds narrow width'
COLUMNS=30 TERM=dumb NO_COLOR='' bash -c 'source "$1"; view_logs' bash "$SCRIPT" < /dev/null > "$TEST_ROOT/log-menu" || fail 'logs EOF failed'
! grep -Fq '╔' "$TEST_ROOT/log-menu" || fail 'logs banner exceeds narrow width'
COLUMNS=30 TERM=dumb NO_COLOR='' bash -c 'source "$1"; show_status() { :; }; show_menu' bash "$MACHINE" > "$TEST_ROOT/machine-menu" || fail 'machine menu failed'
! grep -Fq '╔' "$TEST_ROOT/machine-menu" || fail 'machine banner exceeds narrow width'
COLUMNS=30 TERM=dumb NO_COLOR='' bash -c '
    source "$1"
    debug_log() { :; }; check_runtime_dependencies() { :; }; setup_cron() { :; }
    read_config() { MACHINE_NAME=test; DAILY_REPORT_TIME=00:00; BOT_TOKEN=test; CHAT_ID=test; }
    main
' bash "$TELEGRAM" < /dev/null > "$TEST_ROOT/telegram-menu" || fail 'Telegram EOF failed'
! grep -Fq '======================================' "$TEST_ROOT/telegram-menu" || fail 'Telegram banner exceeds narrow width'
grep -Fq '0. 退出' "$TEST_ROOT/telegram-menu" || fail 'Telegram menu numbering changed'
! grep -q "$(printf '\033')" "$TEST_ROOT/machine-menu" || fail 'machine NO_COLOR emitted ANSI'
printf 'ok - untrusted ledger, narrow NO_COLOR menu and EOF\n'
printf 'All dependency regression tests passed.\n'
