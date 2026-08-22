#!/bin/bash

# 设置 PATH 确保 cron 环境能找到所有命令
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 权限运行此脚本。"
    exit 1
fi

WORK_DIR="/etc/trafficcop-lite"
CONFIG_FILE="$WORK_DIR/traffic_monitor_config.txt"
LOG_FILE="$WORK_DIR/traffic_monitor.log"
SCRIPT_PATH="$WORK_DIR/trafficcop-lite-monitor.sh"
LOCK_FILE="$WORK_DIR/traffic_monitor.lock"
TC_STATE_FILE="$WORK_DIR/tc_limit_state"
PERIOD_STATE_FILE="$WORK_DIR/last_reset_period"
RETENTION_STATE_FILE="$WORK_DIR/vnstat_daily_coverage_start"
USAGE_STATE_FILE="$WORK_DIR/current_traffic_state"
ENFORCEMENT_STATE_FILE="$WORK_DIR/enforcement_state"
SHUTDOWN_STATE_FILE="$WORK_DIR/shutdown_limit_state"
ROOT_CRONTAB_LOCK_FILE="${TRAFFICCOP_ROOT_CRONTAB_LOCK_FILE:-$WORK_DIR/root-crontab.lock}"
TC_HIERARCHY_LOCK_FILE="${TRAFFIC_TOOLS_TC_LOCK_FILE:-/run/lock/traffic-tools-tc.lock}"
TC_STATE_SCHEMA="traffic-tools-unified-htb-v1"
TC_STATE_PROVIDER="trafficcop-lite"
TC_PARENT_RATE="100gbit"
TC_DEFAULT_CLASS_RATE="1kbit"
DOG_CONFIG_FILE="/etc/port-traffic-dog/config.json"
DOG_TC_OWNER_FILE="/etc/port-traffic-dog/tc-root-qdisc.owner"
LOG_MAX_LINES="${LOG_MAX_LINES:-5000}"
SCRIPT_VERSION="1.1.6"
mkdir -p "$WORK_DIR"
chmod 700 "$WORK_DIR" 2>/dev/null || true

trim_log_file() {
    local file="$1"
    local max_lines="$2"
    local tmp_file

    [ -f "$file" ] || return 0
    [[ "$max_lines" =~ ^[1-9][0-9]*$ ]] || max_lines=5000
    local trim_at=$((max_lines + max_lines / 5))
    [ "$(wc -l < "$file" 2>/dev/null || echo 0)" -le "$trim_at" ] && return 0

    tmp_file="${file}.tmp.$$"
    tail -n "$max_lines" "$file" > "$tmp_file" 2>/dev/null && mv -f "$tmp_file" "$file"
    rm -f "$tmp_file" 2>/dev/null || true
}

trim_log_file "$LOG_FILE" "$LOG_MAX_LINES"

find_tc_bin() {
    local candidate
    for candidate in /usr/sbin/tc /sbin/tc /usr/bin/tc /bin/tc; do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    command -v tc 2>/dev/null || true
}

TC_BIN="$(find_tc_bin)"

echo "-----------------------------------------------------"| tee -a "$LOG_FILE"
echo "$(date '+%Y-%m-%d %H:%M:%S') 当前版本：$SCRIPT_VERSION"| tee -a "$LOG_FILE"





migrate_files() {
    mkdir -p "$WORK_DIR"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 使用独立工作目录: $WORK_DIR" | tee -a "$LOG_FILE"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

vnstat_config_value() {
    local target="$1"
    vnstat --showconfig 2>/dev/null | awk -v target="$target" '
        {
            key=$1
            sub(/^[;#]/, "", key)
            if (key == target) {
                print $NF
                exit
            }
        }
    '
}

read_current_crontab() {
    local error_file="$WORK_DIR/.crontab-read-error.$$"
    local current_crontab status

    current_crontab=$(LC_ALL=C crontab -l 2>"$error_file")
    status=$?
    if [ "$status" -eq 0 ]; then
        rm -f "$error_file"
        printf '%s\n' "$current_crontab"
        return 0
    fi
    if grep -Eqi 'no crontab for|no such file or directory' "$error_file" 2>/dev/null; then
        rm -f "$error_file"
        return 0
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') 读取当前 crontab 失败：$(cat "$error_file" 2>/dev/null)" | tee -a "$LOG_FILE" >&2
    rm -f "$error_file"
    return 1
}

acquire_root_crontab_lock() {
    mkdir -p "$(dirname "$ROOT_CRONTAB_LOCK_FILE")" || return 1
    exec 7>"$ROOT_CRONTAB_LOCK_FILE" || return 1
    if ! flock -w 15 7; then
        exec 7>&-
        return 1
    fi
}

release_root_crontab_lock() {
    flock -u 7 2>/dev/null || true
    exec 7>&-
}

read_root_crontab_locked() {
    local current_crontab="" status=0

    acquire_root_crontab_lock || return 1
    current_crontab=$(read_current_crontab) || status=$?
    release_root_crontab_lock
    [ "$status" -eq 0 ] || return "$status"
    printf '%s\n' "$current_crontab"
}

align_timezone_with_vnstat() {
    local use_utc
    use_utc=$(vnstat_config_value "UseUTC")
    if [ "$use_utc" = "1" ]; then
        export TZ=UTC
    else
        unset TZ
    fi
}

ensure_vnstat_interface() {
    local interface="$1"
    if vnstat -i "$interface" --json >/dev/null 2>&1; then
        return 0
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') vnStat 尚未监控接口 $interface，正在添加。" | tee -a "$LOG_FILE"
    if ! vnstat --add -i "$interface" >/dev/null 2>&1; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 无法将接口 $interface 添加到 vnStat 数据库。" | tee -a "$LOG_FILE"
        return 1
    fi
    ensure_service_running "vnStat" vnstat vnstatd
}

commit_vnstat_retention_update() {
    local config_path="$1"
    local config_tmp="$2"
    local marker_tmp="$3"
    local marker_backup="${RETENTION_STATE_FILE}.before-update.$$"
    local had_marker=false
    local rollback_failed=false

    if [ -f "$RETENTION_STATE_FILE" ]; then
        if ! cp -p "$RETENTION_STATE_FILE" "$marker_backup"; then
            rm -f "$config_tmp" "$marker_tmp"
            return 1
        fi
        had_marker=true
    fi

    if ! mv -f "$marker_tmp" "$RETENTION_STATE_FILE"; then
        rm -f "$config_tmp" "$marker_tmp" "$marker_backup"
        return 1
    fi

    if mv -f "$config_tmp" "$config_path"; then
        rm -f "$marker_backup"
        return 0
    fi

    if $had_marker; then
        mv -f "$marker_backup" "$RETENTION_STATE_FILE" || rollback_failed=true
    else
        rm -f "$RETENTION_STATE_FILE" || rollback_failed=true
    fi
    rm -f "$config_tmp" "$marker_tmp"

    if $rollback_failed; then
        if $had_marker; then
            echo "vnStat 配置写入失败，且保留期状态回滚失败；旧标记备份保留在 $marker_backup。"
        else
            echo "vnStat 配置写入失败，且无法删除新建的保留期标记；请检查 $RETENTION_STATE_FILE。"
        fi
    fi
    return 1
}

ensure_vnstat_daily_retention() {
    local required_days current_days config_path answer tmp_file mode owner group marker_tmp
    case "$TRAFFIC_PERIOD" in
        monthly) required_days=40 ;;
        quarterly) required_days=100 ;;
        yearly) required_days=400 ;;
    esac
    current_days=$(vnstat_config_value "DailyDays")
    if [ "$current_days" = "-1" ] || { [[ "$current_days" =~ ^[0-9]+$ ]] && [ "$current_days" -ge "$required_days" ]; }; then
        return 0
    fi

    echo "当前 vnStat DailyDays=${current_days:-未知}，${TRAFFIC_PERIOD} 周期建议至少保留 $required_days 天日数据。"
    read -r -p "是否由脚本调整 vnStat 日数据保留期？[Y/n]: " answer
    case "$answer" in
        n|N)
            echo "未调整 vnStat 日数据保留期，已取消本次配置；原监控配置不会被覆盖。"
            return 1
            ;;
    esac

    for config_path in /etc/vnstat.conf /etc/vnstat/vnstat.conf; do
        [ -f "$config_path" ] && break
    done
    if [ ! -f "$config_path" ]; then
        echo "未找到 vnStat 配置文件，请手动将 DailyDays 调整为至少 $required_days。"
        return 1
    fi
    if [ ! -f "$WORK_DIR/vnstat.conf.before-trafficcop-lite" ]; then
        cp -p "$config_path" "$WORK_DIR/vnstat.conf.before-trafficcop-lite" || return 1
        chmod 600 "$WORK_DIR/vnstat.conf.before-trafficcop-lite" 2>/dev/null || true
    fi
    tmp_file="${config_path}.trafficcop-lite.$$"
    awk -v days="$required_days" '
        BEGIN { updated=0 }
        /^[[:space:]]*[;#]?[[:space:]]*DailyDays[[:space:]]+/ { print "DailyDays " days; updated=1; next }
        { print }
        END { if (!updated) print "DailyDays " days }
    ' "$config_path" > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    mode=$(stat -c '%a' "$config_path" 2>/dev/null || echo 644)
    owner=$(stat -c '%u' "$config_path" 2>/dev/null || echo 0)
    group=$(stat -c '%g' "$config_path" 2>/dev/null || echo 0)
    chmod "$mode" "$tmp_file" 2>/dev/null || chmod 644 "$tmp_file" 2>/dev/null || true
    chown "$owner:$group" "$tmp_file" 2>/dev/null || true

    marker_tmp="${RETENTION_STATE_FILE}.tmp.$$"
    date +%Y-%m-%d > "$marker_tmp" || { rm -f "$tmp_file"; return 1; }
    chmod 600 "$marker_tmp" 2>/dev/null || true
    commit_vnstat_retention_update "$config_path" "$tmp_file" "$marker_tmp" || return 1
    if command_exists systemctl; then
        systemctl restart vnstat.service >/dev/null 2>&1 || systemctl restart vnstatd.service >/dev/null 2>&1 || true
    elif command_exists rc-service; then
        rc-service vnstat restart >/dev/null 2>&1 || rc-service vnstatd restart >/dev/null 2>&1 || true
    elif command_exists service; then
        service vnstat restart >/dev/null 2>&1 || service vnstatd restart >/dev/null 2>&1 || true
    fi
    ensure_service_running "vnStat" vnstat vnstatd
    echo "vnStat DailyDays 已调整为 $required_days；原配置备份在 $WORK_DIR/vnstat.conf.before-trafficcop-lite。"
}

run_privileged() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command_exists sudo; then
        sudo "$@"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 需要 root 权限或 sudo 才能安装依赖。" | tee -a "$LOG_FILE"
        return 1
    fi
}

add_package_once() {
    local package="$1"
    local existing
    for existing in "${packages_to_install[@]}"; do
        if [ "$existing" = "$package" ]; then
            return
        fi
    done
    packages_to_install+=("$package")
}

add_package_for_command() {
    local missing_command="$1"

    case "$PACKAGE_MANAGER:$missing_command" in
        apt:ip) add_package_once "iproute2" ;;
        apt:crontab) add_package_once "cron" ;;
        apt:flock) add_package_once "util-linux" ;;
        apt:tac) add_package_once "coreutils" ;;
        dnf:ip|yum:ip) add_package_once "iproute" ;;
        dnf:crontab|yum:crontab) add_package_once "cronie" ;;
        dnf:flock|yum:flock) add_package_once "util-linux" ;;
        dnf:tac|yum:tac) add_package_once "coreutils" ;;
        apk:ip) add_package_once "iproute2" ;;
        apk:crontab) add_package_once "dcron" ;;
        apk:flock) add_package_once "util-linux-misc" ;;
        apk:tac) add_package_once "coreutils" ;;
        pacman:ip) add_package_once "iproute2" ;;
        pacman:crontab) add_package_once "cronie" ;;
        pacman:flock) add_package_once "util-linux" ;;
        pacman:tac) add_package_once "coreutils" ;;
        *) add_package_once "$missing_command" ;;
    esac
}

detect_package_manager() {
    if command_exists apt-get; then
        echo "apt"
    elif command_exists dnf; then
        echo "dnf"
    elif command_exists yum; then
        echo "yum"
    elif command_exists apk; then
        echo "apk"
    elif command_exists pacman; then
        echo "pacman"
    else
        echo ""
    fi
}

install_packages() {
    case "$PACKAGE_MANAGER" in
        apt)
            echo "$(date '+%Y-%m-%d %H:%M:%S') 正在更新软件包列表..." | tee -a "$LOG_FILE"
            run_privileged apt-get update || return 1
            run_privileged apt-get install -y "$@"
            ;;
        dnf)
            run_privileged dnf install -y "$@"
            ;;
        yum)
            run_privileged yum install -y "$@"
            ;;
        apk)
            run_privileged apk add --no-cache "$@"
            ;;
        pacman)
            run_privileged pacman -S --needed --noconfirm "$@"
            ;;
        *)
            return 1
            ;;
    esac
}

ensure_service_running() {
    local display_name="$1"
    shift
    local service_name

    if command_exists systemctl; then
        for service_name in "$@"; do
            if systemctl list-unit-files "${service_name}.service" --no-legend 2>/dev/null | grep -q "^${service_name}\.service"; then
                if run_privileged systemctl enable --now "${service_name}.service" >/dev/null 2>&1; then
                    return 0
                fi
            fi
        done
    elif command_exists rc-service; then
        for service_name in "$@"; do
            if [ -x "/etc/init.d/$service_name" ]; then
                if command_exists rc-update; then
                    run_privileged rc-update add "$service_name" default >/dev/null 2>&1 || true
                fi
                if run_privileged rc-service "$service_name" start >/dev/null 2>&1 || rc-service "$service_name" status >/dev/null 2>&1; then
                    return 0
                fi
            fi
        done
    elif command_exists service; then
        for service_name in "$@"; do
            if [ -x "/etc/init.d/$service_name" ] && { run_privileged service "$service_name" start >/dev/null 2>&1 || service "$service_name" status >/dev/null 2>&1; }; then
                return 0
            fi
        done
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') 提示：无法自动确认 $display_name 服务状态，请确保对应服务正在运行。" | tee -a "$LOG_FILE"
    return 0
}




check_and_install_packages() {
    local required_commands=("vnstat" "jq" "bc" "ip" "crontab" "flock" "curl" "tac")
    local command_name
    local missing_commands=()
    local packages_to_install=()
    local PACKAGE_MANAGER

    for command_name in "${required_commands[@]}"; do
        if ! command_exists "$command_name"; then
            missing_commands+=("$command_name")
        fi
    done

    if [ "${#missing_commands[@]}" -eq 0 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 所有必要的软件包已安装" | tee -a "$LOG_FILE"
    else
        PACKAGE_MANAGER="$(detect_package_manager)"
        if [ -z "$PACKAGE_MANAGER" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 缺少命令：${missing_commands[*]}，且未识别到支持的包管理器，请手动安装。" | tee -a "$LOG_FILE"
            return 1
        fi

        for command_name in "${missing_commands[@]}"; do
            add_package_for_command "$command_name"
        done

        echo "$(date '+%Y-%m-%d %H:%M:%S') 缺少命令：${missing_commands[*]}，将使用 $PACKAGE_MANAGER 安装：${packages_to_install[*]}" | tee -a "$LOG_FILE"
        if ! install_packages "${packages_to_install[@]}"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 依赖安装失败，请检查网络连接、包管理器和系统状态。" | tee -a "$LOG_FILE"
            return 1
        fi

        for command_name in "${required_commands[@]}"; do
            if ! command_exists "$command_name"; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') 安装后仍缺少命令：$command_name，请手动检查。" | tee -a "$LOG_FILE"
                return 1
            fi
        done
    fi

    ensure_service_running "cron" cron crond dcron cronie
    ensure_service_running "vnStat" vnstat vnstatd

    # 验证系统 tc 命令是否可用；独立版的 tc 快捷命令不会用于限速。
    if [ -z "$TC_BIN" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 警告：'tc' 命令不可用，可能影响限速功能。" | tee -a "$LOG_FILE"
    fi

    # 获取 vnstat 版本
    local vnstat_version vnstat_major
    vnstat_version=$(vnstat --version 2>&1 | head -n 1)
    echo "$(date '+%Y-%m-%d %H:%M:%S') vnstat 版本: $vnstat_version" | tee -a "$LOG_FILE"
    vnstat_major=$(printf '%s\n' "$vnstat_version" | sed -n 's/^[^0-9]*\([0-9][0-9]*\)\..*/\1/p')
    if ! [[ "$vnstat_major" =~ ^[0-9]+$ ]] || [ "$vnstat_major" -lt 2 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 错误：需要 vnStat 2.x 或更高版本。" | tee -a "$LOG_FILE"
        return 1
    fi

    # 获取主要网络接口
    local main_interface
    main_interface=$(ip route show default 2>/dev/null | awk '{
        for (i = 1; i <= NF; i++) {
            if ($i == "dev" && (i + 1) <= NF) {
                print $(i + 1)
                exit
            }
        }
    }')
    echo "$(date '+%Y-%m-%d %H:%M:%S') 主要网络接口: $main_interface" | tee -a "$LOG_FILE"

    # 获取 vnstat 统计开始时间
    if [ -n "$main_interface" ]; then
        local vnstat_json vnstat_start_time
        vnstat_json=$(vnstat -i "$main_interface" --json d)
        vnstat_start_time=$(echo "$vnstat_json" | jq -r '.interfaces[0].created.date | "\(.year)-\(.month | tostring | if length == 1 then "0" + . else . end)-\(.day | tostring | if length == 1 then "0" + . else . end)"')
        
        if [ -n "$vnstat_start_time" ] && [ "$vnstat_start_time" != "null-null-null" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') vnstat 统计开始日期: $vnstat_start_time，在此之前的流量不会被纳入统计！" | tee -a "$LOG_FILE"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') 无法获取 vnstat 统计开始时间" | tee -a "$LOG_FILE"
            echo "vnstat JSON 输出: $vnstat_json" | tee -a "$LOG_FILE"
        fi
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 无法获取主要网络接口" | tee -a "$LOG_FILE"
    fi
}


# 检查配置和定时任务
check_existing_setup() {
     if [ -s "$CONFIG_FILE" ] && read_config; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置已存在"| tee -a "$LOG_FILE"
        if read_root_crontab_locked 2>/dev/null | grep -Fq "$SCRIPT_PATH --run"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 每分钟一次的定时任务已在执行。"| tee -a "$LOG_FILE"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') 警告：定时任务未找到，可能需要重新设置。"| tee -a "$LOG_FILE"
        fi
        return 0
    else
        return 1
    fi
}

is_decimal() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

compare_decimal() {
    awk -v left="$1" -v right="$2" -v op="$3" 'BEGIN {
        if (op == "gt") exit !(left > right)
        if (op == "ge") exit !(left >= right)
        if (op == "lt") exit !(left < right)
        exit 1
    }'
}

validate_config() {
    local has_error=false

    case "${TRAFFIC_MODE:-}" in
        out|in|total|max) ;;
        *)
            echo "$(date '+%Y-%m-%d %H:%M:%S') 配置错误：TRAFFIC_MODE 无效：${TRAFFIC_MODE:-空}" | tee -a "$LOG_FILE"
            has_error=true
            ;;
    esac

    case "${TRAFFIC_PERIOD:-}" in
        monthly|quarterly|yearly) ;;
        *)
            echo "$(date '+%Y-%m-%d %H:%M:%S') 配置错误：TRAFFIC_PERIOD 无效：${TRAFFIC_PERIOD:-空}" | tee -a "$LOG_FILE"
            has_error=true
            ;;
    esac

    if ! is_decimal "${TRAFFIC_LIMIT:-}" || ! compare_decimal "$TRAFFIC_LIMIT" "0" "gt"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置错误：TRAFFIC_LIMIT 必须大于 0。" | tee -a "$LOG_FILE"
        has_error=true
    fi

    TRAFFIC_TOLERANCE="${TRAFFIC_TOLERANCE:-0}"
    if ! is_decimal "$TRAFFIC_TOLERANCE"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置错误：TRAFFIC_TOLERANCE 必须是非负数字。" | tee -a "$LOG_FILE"
        has_error=true
    elif is_decimal "${TRAFFIC_LIMIT:-}" && compare_decimal "$TRAFFIC_TOLERANCE" "$TRAFFIC_LIMIT" "ge"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置错误：TRAFFIC_TOLERANCE 必须小于 TRAFFIC_LIMIT。" | tee -a "$LOG_FILE"
        has_error=true
    fi

    TRAFFIC_UNIT="${TRAFFIC_UNIT:-binary}"
    case "$TRAFFIC_UNIT" in
        decimal|binary) ;;
        *)
            echo "$(date '+%Y-%m-%d %H:%M:%S') 配置错误：TRAFFIC_UNIT 无效：$TRAFFIC_UNIT" | tee -a "$LOG_FILE"
            has_error=true
            ;;
    esac

    PERIOD_START_DAY="${PERIOD_START_DAY:-1}"
    if ! [[ "$PERIOD_START_DAY" =~ ^[0-9]+$ ]]; then
        PERIOD_START_DAY=1
    fi
    PERIOD_START_DAY=$((10#$PERIOD_START_DAY))
    if [ "$PERIOD_START_DAY" -lt 1 ] || [ "$PERIOD_START_DAY" -gt 31 ]; then
        PERIOD_START_DAY=1
    fi

    PERIOD_START_MONTH="${PERIOD_START_MONTH:-1}"
    if ! [[ "$PERIOD_START_MONTH" =~ ^[0-9]+$ ]]; then
        PERIOD_START_MONTH=1
    fi
    PERIOD_START_MONTH=$((10#$PERIOD_START_MONTH))
    if [ "$PERIOD_START_MONTH" -lt 1 ] || [ "$PERIOD_START_MONTH" -gt 12 ]; then
        PERIOD_START_MONTH=1
    fi

    LIMIT_SPEED="${LIMIT_SPEED:-20}"
    if ! [[ "$LIMIT_SPEED" =~ ^[1-9][0-9]*$ ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置错误：LIMIT_SPEED 必须是大于 0 的整数。" | tee -a "$LOG_FILE"
        has_error=true
    fi
    TC_BOOT_GRACE_MINUTES="${TC_BOOT_GRACE_MINUTES:-10}"
    if ! [[ "$TC_BOOT_GRACE_MINUTES" =~ ^[0-9]+$ ]] || [ "$TC_BOOT_GRACE_MINUTES" -gt 1440 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置错误：TC_BOOT_GRACE_MINUTES 必须是 0-1440 的整数。" | tee -a "$LOG_FILE"
        has_error=true
    fi
    ALLOW_PARTIAL_HISTORY="${ALLOW_PARTIAL_HISTORY:-false}"
    case "$ALLOW_PARTIAL_HISTORY" in
        true|false) ;;
        *)
            echo "$(date '+%Y-%m-%d %H:%M:%S') 配置错误：ALLOW_PARTIAL_HISTORY 必须是 true 或 false。" | tee -a "$LOG_FILE"
            has_error=true
            ;;
    esac

    if [ -z "${MAIN_INTERFACE:-}" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置错误：MAIN_INTERFACE 为空。" | tee -a "$LOG_FILE"
        has_error=true
    elif command_exists ip && ! ip link show "$MAIN_INTERFACE" >/dev/null 2>&1; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置错误：网络接口不存在：$MAIN_INTERFACE" | tee -a "$LOG_FILE"
        has_error=true
    fi

    case "${LIMIT_MODE:-}" in
        tc|shutdown) ;;
        *)
            echo "$(date '+%Y-%m-%d %H:%M:%S') 配置错误：LIMIT_MODE 无效：${LIMIT_MODE:-空}" | tee -a "$LOG_FILE"
            has_error=true
            ;;
    esac

    if [ "${LIMIT_MODE:-}" = "shutdown" ] && ! command_exists shutdown; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置错误：关机模式需要系统 shutdown 命令。" | tee -a "$LOG_FILE"
        has_error=true
    fi

    if $has_error; then
        return 1
    fi
    return 0
}

# 读取配置
read_config() {
    if [ -f "$CONFIG_FILE" ]; then
        chmod 600 "$CONFIG_FILE" 2>/dev/null || true
        unset TRAFFIC_MODE TRAFFIC_PERIOD TRAFFIC_LIMIT TRAFFIC_TOLERANCE TRAFFIC_UNIT
        unset PERIOD_START_DAY PERIOD_START_MONTH LIMIT_SPEED MAIN_INTERFACE LIMIT_MODE
        unset ALLOW_PARTIAL_HISTORY TC_BOOT_GRACE_MINUTES
        unset DISABLED DISABLED_TIME
        while IFS='=' read -r key value; do
            value=${value%$'\r'}
            case "$key" in
                TRAFFIC_MODE|TRAFFIC_PERIOD|TRAFFIC_LIMIT|TRAFFIC_TOLERANCE|TRAFFIC_UNIT|PERIOD_START_DAY|PERIOD_START_MONTH|LIMIT_SPEED|MAIN_INTERFACE|LIMIT_MODE|ALLOW_PARTIAL_HISTORY|TC_BOOT_GRACE_MINUTES|DISABLED|DISABLED_TIME)
                    printf -v "$key" '%s' "$value"
                    ;;
            esac
        done < "$CONFIG_FILE"
        validate_config
    else
        return 1
    fi
}

# 写入配置
write_config() {
    local tmp_file="${CONFIG_FILE}.tmp.$$"
    if ! cat > "$tmp_file" << EOF
TRAFFIC_MODE=$TRAFFIC_MODE
TRAFFIC_PERIOD=$TRAFFIC_PERIOD
TRAFFIC_LIMIT=$TRAFFIC_LIMIT
TRAFFIC_TOLERANCE=$TRAFFIC_TOLERANCE
TRAFFIC_UNIT=${TRAFFIC_UNIT:-binary}
PERIOD_START_DAY=${PERIOD_START_DAY:-1}
PERIOD_START_MONTH=${PERIOD_START_MONTH:-1}
LIMIT_SPEED=${LIMIT_SPEED:-20}
MAIN_INTERFACE=$MAIN_INTERFACE
LIMIT_MODE=$LIMIT_MODE
ALLOW_PARTIAL_HISTORY=${ALLOW_PARTIAL_HISTORY:-false}
TC_BOOT_GRACE_MINUTES=${TC_BOOT_GRACE_MINUTES:-10}
EOF
    then
        rm -f "$tmp_file"
        return 1
    fi
    chmod 600 "$tmp_file" 2>/dev/null || true
    mv -f "$tmp_file" "$CONFIG_FILE" || { rm -f "$tmp_file"; return 1; }
    echo "$(date '+%Y-%m-%d %H:%M:%S') 配置已更新"| tee -a "$LOG_FILE"
}

restore_monitor_config_snapshot() {
    local config_backup="$1"
    local had_config="$2"
    local enforcement_backup="$3"
    local had_enforcement="$4"
    local restore_failed=false

    if [ "$had_config" = "true" ]; then
        if [ ! -f "$config_backup" ] || ! mv -f "$config_backup" "$CONFIG_FILE"; then
            restore_failed=true
        fi
    elif ! rm -f "$CONFIG_FILE"; then
        restore_failed=true
    fi

    if [ "$had_enforcement" = "true" ]; then
        if [ ! -f "$enforcement_backup" ] || ! mv -f "$enforcement_backup" "$ENFORCEMENT_STATE_FILE"; then
            restore_failed=true
        fi
    elif ! rm -f "$ENFORCEMENT_STATE_FILE"; then
        restore_failed=true
    fi

    if $restore_failed; then
        return 1
    fi
    return 0
}


# 显示当前配置
show_current_config() {
    local unit_label
    [ "${TRAFFIC_UNIT:-binary}" = "decimal" ] && unit_label="GB" || unit_label="GiB"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 当前配置:"| tee -a "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 流量统计模式: $TRAFFIC_MODE"| tee -a "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 流量统计周期: $TRAFFIC_PERIOD"| tee -a "$LOG_FILE"
    if [ "$TRAFFIC_PERIOD" = "yearly" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 年度起始月份: ${PERIOD_START_MONTH:-1}"| tee -a "$LOG_FILE"
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') 周期起始日: ${PERIOD_START_DAY:-1}"| tee -a "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 流量限制: $TRAFFIC_LIMIT $unit_label"| tee -a "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 容错范围: $TRAFFIC_TOLERANCE $unit_label"| tee -a "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 限速: ${LIMIT_SPEED:-20} kbit/s"| tee -a "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 主要网络接口: $MAIN_INTERFACE"| tee -a "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 限制模式: $LIMIT_MODE"| tee -a "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 历史不足时继续统计: ${ALLOW_PARTIAL_HISTORY:-false}"| tee -a "$LOG_FILE"
    if [ "$LIMIT_MODE" = "tc" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 开机后限速宽限: ${TC_BOOT_GRACE_MINUTES:-10} 分钟"| tee -a "$LOG_FILE"
    fi
}

# 检测主要网络接口
get_main_interface() {
    local main_interface
    main_interface=$(ip route show default 2>/dev/null | awk '{
        for (i = 1; i <= NF; i++) {
            if ($i == "dev" && (i + 1) <= NF) {
                print $(i + 1)
                exit
            }
        }
    }')
    if [ -z "$main_interface" ]; then
        main_interface=$(ip link | grep 'state UP' | sed -n 's/^[0-9]*: \([^:]*\):.*/\1/p' | head -n1)
    fi
    
    if [ -z "$main_interface" ]; then
        while true; do
            echo "$(date '+%Y-%m-%d %H:%M:%S') 无法自动检测主要网络接口。"| tee -a "$LOG_FILE" >&2
            echo "$(date '+%Y-%m-%d %H:%M:%S') 可用的网络接口有："| tee -a "$LOG_FILE" >&2
            ip -o link show | sed -n 's/^[0-9]*: \([^:]*\):.*/\1/p' >&2
            read -r -p "请从上面的列表中选择一个网络接口: " main_interface
            if [ -z "$main_interface" ]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') 请输入一个有效的接口名称。"| tee -a "$LOG_FILE" >&2
            elif ip link show "$main_interface" > /dev/null 2>&1; then
                break
            else
                echo "$(date '+%Y-%m-%d %H:%M:%S') 无效的接口，请重新选择。"| tee -a "$LOG_FILE" >&2
            fi
        done
    else
        read -r -p "检测到的主要网络接口是: $main_interface, 按Enter使用此接口，或输入新的接口名称: " new_interface
        if [ -n "$new_interface" ]; then
            if ip link show "$new_interface" > /dev/null 2>&1; then
                main_interface=$new_interface
            else
                echo "$(date '+%Y-%m-%d %H:%M:%S') 输入的接口无效，将使用检测到的接口: $main_interface"| tee -a "$LOG_FILE" >&2
            fi
        fi
    fi
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') 主要网络接口: $main_interface"| tee -a "$LOG_FILE" >&2
    echo "$main_interface"
}

date_num_to_iso() {
    local date_num="$1"
    printf '%s-%s-%s\n' "${date_num:0:4}" "${date_num:4:2}" "${date_num:6:2}"
}

get_vnstat_available_start() {
    local vnstat_json created_num earliest_num available_num trafficless_entries

    vnstat_json=$(vnstat -i "$MAIN_INTERFACE" --json 2>/dev/null) || return 1
    created_num=$(printf '%s' "$vnstat_json" | jq -r \
        '.interfaces[0].created.date | (.year * 10000 + .month * 100 + .day)' 2>/dev/null) || return 1
    earliest_num=$(printf '%s' "$vnstat_json" | jq -r \
        '[.interfaces[0].traffic.day[]? | (.date.year * 10000 + .date.month * 100 + .date.day)] | min // 0' 2>/dev/null) || return 1
    [[ "$created_num" =~ ^[0-9]{8}$ ]] || return 1

    trafficless_entries=$(vnstat_config_value "TrafficlessEntries")
    trafficless_entries=${trafficless_entries:-1}
    available_num="$created_num"
    if [ "$trafficless_entries" != "0" ] \
        && [[ "$earliest_num" =~ ^[0-9]{8}$ ]] && [ "$earliest_num" -gt "$available_num" ]; then
        available_num="$earliest_num"
    fi
    date_num_to_iso "$available_num"
}

history_incomplete_for_current_period() {
    local period_start available_start retention_start trafficless_entries
    local period_num available_num retention_num

    period_start=$(get_period_start_date) || return 2
    available_start=$(get_vnstat_available_start) || return 2
    retention_start=$(cat "$RETENTION_STATE_FILE" 2>/dev/null || true)
    trafficless_entries=$(vnstat_config_value "TrafficlessEntries")
    trafficless_entries=${trafficless_entries:-1}
    period_num=${period_start//-/}
    available_num=${available_start//-/}
    retention_num=${retention_start//-/}

    [ "$available_num" -gt "$period_num" ] && return 0
    if [ "$trafficless_entries" = "0" ] && [ -n "$retention_start" ] \
        && { ! [[ "$retention_num" =~ ^[0-9]{8}$ ]] || [ "$retention_num" -gt "$period_num" ]; }; then
        return 0
    fi
    return 1
}

configure_history_policy() {
    local period_start available_start available_num retention_start retention_num trafficless_entries history_choice
    local history_status

    ALLOW_PARTIAL_HISTORY=false
    history_incomplete_for_current_period
    history_status=$?
    case "$history_status" in
        0) ;;
        1) return 0 ;;
        *)
            echo "无法可靠读取 vnStat 历史起点，已取消本次配置；请确认 vnStat 服务和接口数据正常。"
            return 1
            ;;
    esac

    period_start=$(get_period_start_date)
    available_start=$(get_vnstat_available_start 2>/dev/null || echo "未知")
    retention_start=$(cat "$RETENTION_STATE_FILE" 2>/dev/null || true)
    trafficless_entries=$(vnstat_config_value "TrafficlessEntries")
    trafficless_entries=${trafficless_entries:-1}
    available_num=${available_start//-/}
    retention_num=${retention_start//-/}
    if [ "$trafficless_entries" = "0" ] && [[ "$retention_num" =~ ^[0-9]{8}$ ]] \
        && { ! [[ "$available_num" =~ ^[0-9]{8}$ ]] || [ "$retention_num" -gt "$available_num" ]; }; then
        available_start="$retention_start"
    fi
    echo ""
    echo "检测到 vnStat 历史不足以覆盖周期起点 $period_start。"
    echo "当前可用流量历史约从 $available_start 开始；受 vnStat 本地历史记录限制，此前流量无法补回。"
    echo "继续后，脚本会按现有历史统计并正常执行限制，但实际已用流量可能偏低。"
    echo "主菜单会持续显示该提示，直到进入具有完整历史的新周期。"
    echo ""
    echo "1) 我已了解，按现有 vnStat 历史继续"
    echo "0) 取消配置，不保存本次修改"
    read -r -p "请输入选择 [0/1]: " history_choice
    if [ "$history_choice" != "1" ]; then
        echo "已取消配置；原配置未被覆盖。"
        return 1
    fi
    ALLOW_PARTIAL_HISTORY=true
}

enforcement_state_value() {
    local key="$1"
    if [ -f "$ENFORCEMENT_STATE_FILE" ]; then
        grep "^${key}=" "$ENFORCEMENT_STATE_FILE" 2>/dev/null | tail -n 1 | cut -d'=' -f2-
    fi
}

shutdown_state_value() {
    local key="$1"
    if [ -f "$SHUTDOWN_STATE_FILE" ]; then
        grep "^${key}=" "$SHUTDOWN_STATE_FILE" 2>/dev/null | tail -n 1 | cut -d'=' -f2-
    fi
}

write_enforcement_state() {
    local mode="$1"
    local until_epoch="$2"
    local reason="$3"
    local tmp_file="${ENFORCEMENT_STATE_FILE}.tmp.$$"

    {
        printf 'MODE=%s\n' "$mode"
        printf 'UNTIL_EPOCH=%s\n' "$until_epoch"
        printf 'REASON=%s\n' "$reason"
        printf 'UPDATED_AT=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    chmod 600 "$tmp_file" 2>/dev/null || true
    mv -f "$tmp_file" "$ENFORCEMENT_STATE_FILE"
}

clear_owned_shutdown_schedule() {
    local state_boot current_boot

    if [ -f "$SHUTDOWN_STATE_FILE" ]; then
        state_boot=$(grep '^BOOT_ID=' "$SHUTDOWN_STATE_FILE" 2>/dev/null | tail -n 1 | cut -d'=' -f2-)
        current_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
        if [ -n "$state_boot" ] && [ -n "$current_boot" ] && [ "$state_boot" != "$current_boot" ]; then
            rm -f "$SHUTDOWN_STATE_FILE" || return 1
            echo "$(date '+%Y-%m-%d %H:%M:%S') 已清理上次开机遗留的关机状态；未触碰本次开机的计划关机。" | tee -a "$LOG_FILE"
            return 0
        fi
        if { [ -z "$state_boot" ] || [ -z "$current_boot" ]; } && has_pending_shutdown; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 无法确认计划关机是否属于本脚本，已保留系统任务和状态文件。" | tee -a "$LOG_FILE"
            return 1
        fi
        if has_pending_shutdown && ! shutdown -c 2>/dev/null; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 无法取消本脚本记录的计划关机，已保留状态文件。" | tee -a "$LOG_FILE"
            return 1
        fi
        rm -f "$SHUTDOWN_STATE_FILE" || return 1
    fi
}

configure_post_save_enforcement() {
    local current_usage limit_threshold unit_label policy_choice grace_minutes until_epoch

    if ! current_usage=$(get_traffic_usage); then
        echo "无法可靠读取当前流量，已取消本次配置；原监控配置不会被覆盖。"
        return 1
    fi
    clear_owned_shutdown_schedule || return 1
    rm -f "$ENFORCEMENT_STATE_FILE"
    clear_owned_tc_rules "配置已更新" || return 1
    [ "${TRAFFIC_UNIT:-binary}" = "decimal" ] && unit_label="GB" || unit_label="GiB"
    limit_threshold=$(echo "$TRAFFIC_LIMIT - $TRAFFIC_TOLERANCE" | bc 2>/dev/null || echo "0")
    if ! compare_decimal "$current_usage" "$limit_threshold" "ge"; then
        return 0
    fi

    echo ""
    echo "当前可统计流量为 $current_usage $unit_label，已经达到执行阈值 $limit_threshold $unit_label。"
    echo "为避免保存配置后突然限速或关机，请选择本次执行策略："
    echo "1) 宽限一段时间后再执行（推荐）"
    echo "2) 立即执行"
    echo "3) 仅监控，暂停执行限制，稍后在机器限速管理中恢复"
    read -r -p "请输入选择 (1-3，默认为1): " policy_choice
    case "$policy_choice" in
        2)
            rm -f "$ENFORCEMENT_STATE_FILE"
            ;;
        3)
            write_enforcement_state "paused" "0" "manual" || return 1
            echo "限制执行已暂停；流量统计和主页显示仍会继续。"
            ;;
        1|"")
            read -r -p "请输入宽限分钟数 (1-1440，默认为10): " grace_minutes
            grace_minutes=${grace_minutes:-10}
            if ! [[ "$grace_minutes" =~ ^[0-9]+$ ]] || [ "$grace_minutes" -lt 1 ] || [ "$grace_minutes" -gt 1440 ]; then
                echo "输入无效，使用默认值：10 分钟"
                grace_minutes=10
            fi
            until_epoch=$(( $(date +%s) + grace_minutes * 60 ))
            write_enforcement_state "grace" "$until_epoch" "config" || return 1
            echo "已设置 $grace_minutes 分钟宽限；期间只统计流量，不执行限制。"
            ;;
        *)
            echo "输入无效，使用推荐值：宽限 10 分钟"
            until_epoch=$(( $(date +%s) + 600 ))
            write_enforcement_state "grace" "$until_epoch" "config" || return 1
            ;;
    esac
}

# 初始配置函数
echo "$(date '+%Y-%m-%d %H:%M:%S') 开始初始化配置"| tee -a "$LOG_FILE"
initial_config() {
    local config_backup="${CONFIG_FILE}.before-config.$$"
    local enforcement_backup="${ENFORCEMENT_STATE_FILE}.before-config.$$"
    local had_config=false
    local had_enforcement=false

    echo "$(date '+%Y-%m-%d %H:%M:%S') 正在检测主要网络接口..."| tee -a "$LOG_FILE"
    MAIN_INTERFACE=$(get_main_interface)
    ensure_vnstat_interface "$MAIN_INTERFACE" || return 1

    while true; do
        echo "$(date '+%Y-%m-%d %H:%M:%S') 请选择流量统计模式："| tee -a "$LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 1. 只计算出站流量"| tee -a "$LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 2. 只计算进站流量"| tee -a "$LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 3. 出进站流量都计算"| tee -a "$LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 4. 出站和进站流量只取大"| tee -a "$LOG_FILE"
        read -r -p "请输入选择 (1-4): " mode_choice
        case $mode_choice in
            1) TRAFFIC_MODE="out"; break ;;
            2) TRAFFIC_MODE="in"; break ;;
            3) TRAFFIC_MODE="total"; break ;;
            4) TRAFFIC_MODE="max"; break ;;
            *) echo "无效输入，请重新选择。" ;;
        esac
    done

    read -r -p "请选择流量统计周期 (m/q/y，默认为m): " period_choice
    case $period_choice in
        q) TRAFFIC_PERIOD="quarterly" ;;
        y) TRAFFIC_PERIOD="yearly" ;;
        m|"") TRAFFIC_PERIOD="monthly" ;;
        *) echo "无效输入，使用默认值：monthly"; TRAFFIC_PERIOD="monthly" ;;
    esac
    ensure_vnstat_daily_retention || return 1

    echo "请选择流量单位："
    echo "1. GB（十进制，1 GB = 1000^3 字节，推荐用于服务商配额）"
    echo "2. GiB（二进制，1 GiB = 1024^3 字节，兼容旧版）"
    read -r -p "请输入选择 (1-2，默认为1): " unit_choice
    case "$unit_choice" in
        2) TRAFFIC_UNIT="binary" ;;
        1|"") TRAFFIC_UNIT="decimal" ;;
        *) echo "无效输入，使用默认值：GB"; TRAFFIC_UNIT="decimal" ;;
    esac

    PERIOD_START_MONTH=1
    if [ "$TRAFFIC_PERIOD" = "yearly" ]; then
        read -r -p "请输入年度周期起始月份 (1-12，默认为1): " PERIOD_START_MONTH
        if [[ -z "$PERIOD_START_MONTH" ]]; then
            PERIOD_START_MONTH=1
        elif ! [[ "$PERIOD_START_MONTH" =~ ^[1-9]$|^1[0-2]$ ]]; then
            echo "无效输入，使用默认值：1"
            PERIOD_START_MONTH=1
        fi
    fi

    read -r -p "请输入周期起始日 (1-31，默认为1): " PERIOD_START_DAY
    if [[ -z "$PERIOD_START_DAY" ]]; then
        PERIOD_START_DAY=1
    elif ! [[ "$PERIOD_START_DAY" =~ ^[1-9]$|^[12][0-9]$|^3[01]$ ]]; then
        echo "无效输入，使用默认值：1"
        PERIOD_START_DAY=1
    fi

    while true; do
        read -r -p "请输入流量限制 ($([ "$TRAFFIC_UNIT" = "decimal" ] && echo GB || echo GiB)): " TRAFFIC_LIMIT
        if [[ "$TRAFFIC_LIMIT" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (( $(echo "$TRAFFIC_LIMIT > 0" | bc -l 2>/dev/null || echo "0") )); then
            break
        else
            echo "无效输入，请输入一个大于 0 的数字。"
        fi
    done

    while true; do
        read -r -p "请输入容错范围 ($([ "$TRAFFIC_UNIT" = "decimal" ] && echo GB || echo GiB)): " TRAFFIC_TOLERANCE
        if [[ "$TRAFFIC_TOLERANCE" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (( $(echo "$TRAFFIC_TOLERANCE < $TRAFFIC_LIMIT" | bc -l 2>/dev/null || echo "0") )); then
            break
        else
            echo "无效输入，容错范围必须大于等于 0 且小于流量限制。"
        fi
    done

    while true; do
        echo "$(date '+%Y-%m-%d %H:%M:%S') 请选择限制模式："| tee -a "$LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 1. TC 模式（更灵活）"| tee -a "$LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 2. 关机模式（更安全）"| tee -a "$LOG_FILE"
        read -r -p "请输入选择 (1-2): " limit_mode_choice
        case $limit_mode_choice in
            1) 
                LIMIT_MODE="tc"
                read -r -p "请输入限速 (kbit/s，默认为20): " LIMIT_SPEED
                LIMIT_SPEED=${LIMIT_SPEED:-20}
                if ! [[ "$LIMIT_SPEED" =~ ^[1-9][0-9]*$ ]]; then
                    echo "无效输入，使用默认值：20 kbit/s"
                    LIMIT_SPEED=20
                fi
                read -r -p "请输入开机后限速宽限时间（防卡死，单位：分钟；0=立即，默认为10）: " TC_BOOT_GRACE_MINUTES
                TC_BOOT_GRACE_MINUTES=${TC_BOOT_GRACE_MINUTES:-10}
                if ! [[ "$TC_BOOT_GRACE_MINUTES" =~ ^[0-9]+$ ]] || [ "$TC_BOOT_GRACE_MINUTES" -gt 1440 ]; then
                    echo "无效输入，使用默认值：10 分钟"
                    TC_BOOT_GRACE_MINUTES=10
                fi
                break 
                ;;
            2) 
                LIMIT_MODE="shutdown"
                LIMIT_SPEED=""  # 关机模式不需要限速
                TC_BOOT_GRACE_MINUTES=10
                break 
                ;;
            *) echo "无效输入，请重新选择。" ;;
        esac
    done

    configure_history_policy || return 1

    if [ -f "$CONFIG_FILE" ]; then
        cp -p "$CONFIG_FILE" "$config_backup" || return 1
        chmod 600 "$config_backup" 2>/dev/null || true
        had_config=true
    fi
    if [ -f "$ENFORCEMENT_STATE_FILE" ]; then
        if ! cp -p "$ENFORCEMENT_STATE_FILE" "$enforcement_backup"; then
            rm -f "$config_backup"
            return 1
        fi
        chmod 600 "$enforcement_backup" 2>/dev/null || true
        had_enforcement=true
    fi

    if ! write_config; then
        if restore_monitor_config_snapshot "$config_backup" "$had_config" "$enforcement_backup" "$had_enforcement"; then
            echo "配置写入失败，已恢复修改前的监控配置与执行策略。"
        else
            echo "配置写入失败，且无法完整恢复修改前状态；可用备份会保留在 $config_backup 或 $enforcement_backup。"
        fi
        return 1
    fi

    if ! configure_post_save_enforcement; then
        if restore_monitor_config_snapshot "$config_backup" "$had_config" "$enforcement_backup" "$had_enforcement"; then
            echo "后续安全处理失败，已恢复修改前的监控配置与执行策略。"
        else
            echo "后续安全处理失败，且无法完整恢复修改前状态；可用备份会保留在 $config_backup 或 $enforcement_backup。"
        fi
        return 1
    fi

    rm -f "$config_backup" "$enforcement_backup"
}

# 返回指定年月的周期锚点。若用户配置了不存在的日期（如 2 月 31 日），使用当月最后一天。
is_leap_year() {
    local year="$1"
    if { [ $((year % 4)) -eq 0 ] && [ $((year % 100)) -ne 0 ]; } || [ $((year % 400)) -eq 0 ]; then
        return 0
    fi
    return 1
}

days_in_month() {
    local year="$1"
    local month=$((10#$2))

    case "$month" in
        1|3|5|7|8|10|12) echo 31 ;;
        4|6|9|11) echo 30 ;;
        2)
            if is_leap_year "$year"; then
                echo 29
            else
                echo 28
            fi
            ;;
    esac
}

get_anchor_date() {
    local year="$1"
    local month=$((10#$2))
    local day=$((10#$3))
    local max_day

    max_day=$(days_in_month "$year" "$month")
    if [ "$day" -gt "$max_day" ]; then
        day="$max_day"
    fi

    printf "%04d-%02d-%02d\n" "$year" "$month" "$day"
}

date_to_num() {
    echo "$1" | tr -d '-'
}

shift_month() {
    local year="$1"
    local month=$((10#$2))
    local offset="$3"
    local total=$((year * 12 + month - 1 + offset))
    local shifted_year=$((total / 12))
    local shifted_month=$((total % 12 + 1))

    printf "%04d %02d\n" "$shifted_year" "$shifted_month"
}

previous_day() {
    local date_value="$1"
    local year=${date_value%%-*}
    local rest=${date_value#*-}
    local month=${rest%%-*}
    local day=${date_value##*-}

    year=$((10#$year))
    month=$((10#$month))
    day=$((10#$day))

    if [ "$day" -gt 1 ]; then
        printf "%04d-%02d-%02d\n" "$year" "$month" "$((day - 1))"
    else
        local prev_year prev_month prev_day
        read -r prev_year prev_month <<< "$(shift_month "$year" "$month" -1)"
        prev_day=$(days_in_month "$prev_year" "$prev_month")
        printf "%04d-%02d-%02d\n" "$prev_year" "$((10#$prev_month))" "$prev_day"
    fi
}

# 获取当前周期的起始日期
get_period_start_date() {
    local current_date current_month current_year
    local anchor_this anchor_num current_num period_year period_month

    current_date=$(date +%Y-%m-%d)
    current_month=$(date +%m)
    current_year=$(date +%Y)

    current_num=$(date_to_num "$current_date")

    case $TRAFFIC_PERIOD in
        monthly)
            anchor_this=$(get_anchor_date "$current_year" "$current_month" "$PERIOD_START_DAY")
            anchor_num=$(date_to_num "$anchor_this")
            if [ "$current_num" -lt "$anchor_num" ]; then
                read -r period_year period_month <<< "$(shift_month "$current_year" "$current_month" -1)"
                get_anchor_date "$period_year" "$period_month" "$PERIOD_START_DAY"
            else
                echo "$anchor_this"
            fi
            ;;
        quarterly)
            local quarter_month=$(( ((10#$current_month - 1) / 3) * 3 + 1 ))
            anchor_this=$(get_anchor_date "$current_year" "$quarter_month" "$PERIOD_START_DAY")
            anchor_num=$(date_to_num "$anchor_this")
            if [ "$current_num" -lt "$anchor_num" ]; then
                read -r period_year period_month <<< "$(shift_month "$current_year" "$quarter_month" -3)"
                get_anchor_date "$period_year" "$period_month" "$PERIOD_START_DAY"
            else
                echo "$anchor_this"
            fi
            ;;
        yearly)
            local start_month_num=$((10#${PERIOD_START_MONTH:-1}))
            anchor_this=$(get_anchor_date "$current_year" "$start_month_num" "$PERIOD_START_DAY")
            anchor_num=$(date_to_num "$anchor_this")
            if [ "$current_num" -lt "$anchor_num" ]; then
                read -r period_year period_month <<< "$(shift_month "$current_year" "$start_month_num" -12)"
                get_anchor_date "$period_year" "$period_month" "$PERIOD_START_DAY"
            else
                echo "$anchor_this"
            fi
            ;;
    esac
}

# 获取周期结束日期
get_period_end_date() {
    local start_date start_year start_month next_year next_month next_anchor offset

    start_date=$(get_period_start_date)
    start_year=${start_date%%-*}
    start_month=${start_date#*-}
    start_month=${start_month%%-*}

    case $TRAFFIC_PERIOD in
        monthly) offset=1 ;;
        quarterly) offset=3 ;;
        yearly) offset=12 ;;
    esac

    read -r next_year next_month <<< "$(shift_month "$start_year" "$start_month" "$offset")"
    next_anchor=$(get_anchor_date "$next_year" "$next_month" "$PERIOD_START_DAY")
    previous_day "$next_anchor"
}

# 获取流量使用情况
get_traffic_usage() {
    local start_date end_date
    local start_num end_num vnstat_json usage_bytes rx_bytes tx_bytes divisor
    local created_num earliest_num daily_days required_days trafficless_entries retention_start retention_num
    local available_num available_start

    start_date=$(get_period_start_date)
    end_date=$(get_period_end_date)
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') 周期开始日期: $start_date, 周期结束日期: $end_date" >&2
    
    # 使用 vnstat JSON API 获取每日流量数据
    if ! vnstat_json=$(vnstat -i "$MAIN_INTERFACE" --json 2>/dev/null); then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 错误: vnstat 执行失败，跳过本轮限速检查" >&2
        return 1
    fi
    
    if [ -z "$vnstat_json" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 错误: 无法获取 vnstat JSON 数据" >&2
        return 1
    fi
    
    # 将日期转换为 YYYYMMDD 整数用于比较（兼容 vnstat 2.x 的 date 对象格式）
    start_num=$(echo "$start_date" | tr -d '-')
    end_num=$(echo "$end_date" | tr -d '-')

    created_num=$(echo "$vnstat_json" | jq -r '.interfaces[0].created.date | (.year * 10000 + .month * 100 + .day)' 2>/dev/null) || return 1
    earliest_num=$(echo "$vnstat_json" | jq -r '[.interfaces[0].traffic.day[]? | (.date.year * 10000 + .date.month * 100 + .date.day)] | min // 0' 2>/dev/null) || return 1
    case "$TRAFFIC_PERIOD" in
        monthly) required_days=40 ;;
        quarterly) required_days=100 ;;
        yearly) required_days=400 ;;
    esac
    daily_days=$(vnstat_config_value "DailyDays")
    if [ "$daily_days" != "-1" ] && { ! [[ "$daily_days" =~ ^[0-9]+$ ]] || [ "$daily_days" -lt "$required_days" ]; }; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 错误: vnStat DailyDays=${daily_days:-未知}，不足以可靠统计当前周期（建议至少 $required_days）" >&2
        return 1
    fi
    trafficless_entries=$(vnstat_config_value "TrafficlessEntries")
    trafficless_entries=${trafficless_entries:-1}
    retention_start=$(cat "$RETENTION_STATE_FILE" 2>/dev/null || true)
    retention_num=${retention_start//-/}
    if [ -z "$retention_start" ] && [ -f "$WORK_DIR/vnstat.conf.before-trafficcop-lite" ] \
        && [[ "$earliest_num" =~ ^[0-9]{8}$ ]] && [ "$earliest_num" -ne 0 ]; then
        # 旧版没有记录调整 DailyDays 的日期，以最早日记录作为保守覆盖起点。
        retention_start="$earliest_num"
        retention_num="$earliest_num"
    fi
    if ! [[ "$created_num" =~ ^[0-9]{8}$ ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 错误: 无法确认 vnStat 数据起始日期" >&2
        return 1
    fi
    if [ "$created_num" -gt "$start_num" ] \
        || { [ "$trafficless_entries" = "0" ] && [ -n "$retention_start" ] && { ! [[ "$retention_num" =~ ^[0-9]{8}$ ]] || [ "$retention_num" -gt "$start_num" ]; }; } \
        || { [ "$trafficless_entries" != "0" ] && { ! [[ "$earliest_num" =~ ^[0-9]+$ ]] || [ "$earliest_num" -eq 0 ] || [ "$earliest_num" -gt "$start_num" ]; }; }; then
        if [ "${ALLOW_PARTIAL_HISTORY:-false}" != "true" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 错误: vnStat 日数据未完整覆盖周期起点 $start_date，拒绝按不完整数据限速" >&2
            return 1
        fi
        available_num="$created_num"
        if [ "$trafficless_entries" != "0" ] \
            && [[ "$earliest_num" =~ ^[0-9]{8}$ ]] && [ "$earliest_num" -gt "$available_num" ]; then
            available_num="$earliest_num"
        fi
        if [ "$trafficless_entries" = "0" ] \
            && [[ "$retention_num" =~ ^[0-9]{8}$ ]] && [ "$retention_num" -gt "$available_num" ]; then
            available_num="$retention_num"
        fi
        available_start=$(date_num_to_iso "$available_num")
        echo "$(date '+%Y-%m-%d %H:%M:%S') 警告: 用户已确认按部分历史继续；仅统计 $available_start 以来的可用流量，周期早段流量未计入" >&2
    fi
    
    # 根据 TRAFFIC_MODE 累加对应的流量
    case $TRAFFIC_MODE in
        out)
            usage_bytes=$(echo "$vnstat_json" | jq --argjson start_num "$start_num" --argjson end_num "$end_num" \
                '[.interfaces[0].traffic.day[]? | (.date.year * 10000 + .date.month * 100 + .date.day) as $date_num | select($date_num >= $start_num and $date_num <= $end_num) | .tx] | add // 0') || return 1
            ;;
        in)
            usage_bytes=$(echo "$vnstat_json" | jq --argjson start_num "$start_num" --argjson end_num "$end_num" \
                '[.interfaces[0].traffic.day[]? | (.date.year * 10000 + .date.month * 100 + .date.day) as $date_num | select($date_num >= $start_num and $date_num <= $end_num) | .rx] | add // 0') || return 1
            ;;
        total)
            usage_bytes=$(echo "$vnstat_json" | jq --argjson start_num "$start_num" --argjson end_num "$end_num" \
                '[.interfaces[0].traffic.day[]? | (.date.year * 10000 + .date.month * 100 + .date.day) as $date_num | select($date_num >= $start_num and $date_num <= $end_num) | (.rx + .tx)] | add // 0') || return 1
            ;;
        max)
            rx_bytes=$(echo "$vnstat_json" | jq --argjson start_num "$start_num" --argjson end_num "$end_num" \
                '[.interfaces[0].traffic.day[]? | (.date.year * 10000 + .date.month * 100 + .date.day) as $date_num | select($date_num >= $start_num and $date_num <= $end_num) | .rx] | add // 0') || return 1
            tx_bytes=$(echo "$vnstat_json" | jq --argjson start_num "$start_num" --argjson end_num "$end_num" \
                '[.interfaces[0].traffic.day[]? | (.date.year * 10000 + .date.month * 100 + .date.day) as $date_num | select($date_num >= $start_num and $date_num <= $end_num) | .tx] | add // 0') || return 1
            usage_bytes=$(awk -v rx="$rx_bytes" -v tx="$tx_bytes" 'BEGIN { if (rx >= tx) print rx; else print tx }')
            ;;
    esac

    if ! [[ "$usage_bytes" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 错误: jq 返回了无效流量数据：${usage_bytes:-空}" >&2
        return 1
    fi

    if [ "$usage_bytes" != "0" ]; then
        [ "${TRAFFIC_UNIT:-binary}" = "decimal" ] && divisor=1000000000 || divisor=1073741824
        awk -v bytes="$usage_bytes" -v divisor="$divisor" 'BEGIN { printf "%.3f\n", bytes / divisor }'
    else
        echo "0.000"
    fi
}

tc_root_qdisc() {
    local qdisc_state
    qdisc_state=$("$TC_BIN" qdisc show dev "$1" root 2>/dev/null) || return 1
    awk 'NR == 1 { print }' <<< "$qdisc_state"
}

is_default_qdisc_line() {
    local qdisc_line="$1"
    local qdisc_type

    qdisc_type=$(printf '%s\n' "$qdisc_line" | awk '{print $2}')
    case "$qdisc_type" in
        ""|noqueue|fq_codel|pfifo_fast|mq|fq) return 0 ;;
        *) return 1 ;;
    esac
}

tc_state_value() {
    local key="$1"
    if [ -f "$TC_STATE_FILE" ]; then
        grep "^${key}=" "$TC_STATE_FILE" 2>/dev/null | tail -n 1 | cut -d'=' -f2-
    fi
}

tc_state_interface() {
    tc_state_value "INTERFACE"
}

acquire_tc_hierarchy_lock() {
    mkdir -p "$(dirname "$TC_HIERARCHY_LOCK_FILE")" || return 1
    exec 6>"$TC_HIERARCHY_LOCK_FILE" || return 1
    if ! flock -w 15 6; then
        exec 6>&-
        return 1
    fi
}

release_tc_hierarchy_lock() {
    flock -u 6 2>/dev/null || true
    exec 6>&-
}

normalize_tc_rate_to_bps() {
    local value="${1,,}"
    local number unit multiplier

    value=${value//[[:space:]]/}
    [[ "$value" =~ ^([0-9]+)(bit|kbit|mbit|gbit|tbit)$ ]] || return 1
    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    case "$unit" in
        bit) multiplier=1 ;;
        kbit) multiplier=1000 ;;
        mbit) multiplier=1000000 ;;
        gbit) multiplier=1000000000 ;;
        tbit) multiplier=1000000000000 ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$((number * multiplier))"
}

tc_class_line() {
    local interface="$1"
    local class_id="$2"
    local class_state
    class_state=$("$TC_BIN" class show dev "$interface" 2>/dev/null) || return 1
    awk -v class_id="$class_id" '$1 == "class" && $3 == class_id { print; exit }' \
        <<< "$class_state"
}

tc_class_value() {
    local interface="$1"
    local class_id="$2"
    local key="$3"
    tc_class_line "$interface" "$class_id" |
        awk -v key="$key" '{ for (i = 1; i < NF; i++) if ($i == key) { print $(i + 1); exit } }'
}

tc_class_rate_matches() {
    local interface="$1"
    local class_id="$2"
    local expected_rate="$3"
    local expected_ceil="${4:-}"
    local actual_rate actual_ceil expected_bps actual_bps

    actual_rate=$(tc_class_value "$interface" "$class_id" rate)
    expected_bps=$(normalize_tc_rate_to_bps "$expected_rate") || return 1
    actual_bps=$(normalize_tc_rate_to_bps "$actual_rate") || return 1
    [ "$actual_bps" = "$expected_bps" ] || return 1
    if [ -n "$expected_ceil" ]; then
        actual_ceil=$(tc_class_value "$interface" "$class_id" ceil)
        expected_bps=$(normalize_tc_rate_to_bps "$expected_ceil") || return 1
        actual_bps=$(normalize_tc_rate_to_bps "$actual_ceil") || return 1
        [ "$actual_bps" = "$expected_bps" ] || return 1
    fi
}

tc_root_is_htb_handle_one() {
    local interface="$1"
    tc_root_qdisc "$interface" | grep -Eq '^qdisc htb 1:([[:space:]]|$)'
}

tc_root_has_default_30() {
    local interface="$1"
    tc_root_qdisc "$interface" | grep -Eq ' default (0x)?30([[:space:]]|$)'
}

tc_root_has_parent_class() {
    local interface="$1"
    tc_class_line "$interface" "1:1" | grep -Eq '^class htb 1:1 root([[:space:]]|$)'
}

dog_owner_marker_matches() {
    local interface="$1"
    local recorded_interface="" recorded_machine_id="" machine_id=""

    [ -r "$DOG_TC_OWNER_FILE" ] || return 1
    IFS='|' read -r recorded_interface recorded_machine_id < "$DOG_TC_OWNER_FILE" || return 1
    [ -r /etc/machine-id ] && machine_id=$(tr -d '\r\n' < /etc/machine-id)
    [ "$recorded_interface" = "$interface" ] && [ "$recorded_machine_id" = "$machine_id" ]
}

tc_state_is_unified_for_interface() {
    local interface="$1"
    [ "$(tc_state_value SCHEMA)" = "$TC_STATE_SCHEMA" ] &&
        [ "$(tc_state_value PROVIDER)" = "$TC_STATE_PROVIDER" ] &&
        [ "$(tc_state_interface)" = "$interface" ]
}

dog_configured_class_ids() {
    local port class_id start_port end_port mark_id minor

    [ -r "$DOG_CONFIG_FILE" ] && command -v jq >/dev/null 2>&1 || return 1
    jq -e '(.ports // {}) | type == "object"' "$DOG_CONFIG_FILE" >/dev/null 2>&1 || return 1
    while IFS=$'\t' read -r port class_id; do
        if [[ "$class_id" =~ ^1:([0-9a-fA-F]+)$ ]]; then
            printf '%s\n' "$class_id"
        elif [[ "$port" =~ ^[0-9]+$ ]]; then
            printf '1:%x\n' "$((0x1000 + port))"
        elif [[ "$port" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start_port="${BASH_REMATCH[1]}"
            end_port="${BASH_REMATCH[2]}"
            mark_id=$(((start_port * 1000 + end_port) % 65536))
            minor=$((0x2000 + mark_id))
            [ "$minor" -le 65535 ] || continue
            printf '1:%x\n' "$minor"
        fi
    done < <(jq -r '
        .ports // {} | to_entries[] |
        select((.value.enabled // true) == true) |
        select((.value.bandwidth_limit.enabled // false) == true) |
        select((.value.bandwidth_limit.rate // "unlimited") != "unlimited") |
        [.key, (.value.bandwidth_limit.class_id // "")] | @tsv
    ' "$DOG_CONFIG_FILE" 2>/dev/null) | sort -u
}

dog_live_objects_match_config() {
    local interface="$1"
    local configured_ids actual_ids filter_ids class_id

    configured_ids=$(dog_configured_class_ids) || return 1
    actual_ids=$("$TC_BIN" class show dev "$interface" 2>/dev/null |
        awk '$1 == "class" && $2 == "htb" && $3 != "1:1" && $3 != "1:30" { print $3 }' |
        sort -u)
    filter_ids=$("$TC_BIN" filter show dev "$interface" parent 1:0 2>/dev/null |
        grep -Eo '(flowid|classid)[[:space:]]+1:[0-9a-fA-F]+' |
        awk '{ print $2 }' | sort -u)

    while IFS= read -r class_id; do
        [ -z "$class_id" ] && continue
        printf '%s\n' "$configured_ids" | grep -Fqx "$class_id" || return 1
    done <<< "$actual_ids"
    while IFS= read -r class_id; do
        [ -z "$class_id" ] && continue
        printf '%s\n' "$configured_ids" | grep -Fqx "$class_id" || return 1
    done <<< "$filter_ids"
    while IFS= read -r class_id; do
        [ -z "$class_id" ] && continue
        printf '%s\n' "$actual_ids" | grep -Fqx "$class_id" || return 1
        printf '%s\n' "$filter_ids" | grep -Fqx "$class_id" || return 1
    done <<< "$configured_ids"
}

tc_root_is_recognized_dog_htb() {
    local interface="$1"
    dog_owner_marker_matches "$interface" &&
        tc_root_is_htb_handle_one "$interface" &&
        tc_root_has_default_30 "$interface" &&
        tc_root_has_parent_class "$interface" &&
        dog_live_objects_match_config "$interface"
}

tc_root_is_unified_compatible() {
    local interface="$1"
    tc_root_is_htb_handle_one "$interface" || return 1
    tc_root_has_default_30 "$interface" || return 1
    tc_root_has_parent_class "$interface" || return 1
    tc_state_is_unified_for_interface "$interface" || tc_root_is_recognized_dog_htb "$interface"
}

dog_config_reserves_default_class() {
    [ -f "$DOG_CONFIG_FILE" ] || return 1
    command -v jq >/dev/null 2>&1 || return 0
    jq -e '
        [.ports // {} | to_entries[] |
            select((.value.bandwidth_limit.class_id // "") == "1:30")] |
        length > 0
    ' "$DOG_CONFIG_FILE" >/dev/null 2>&1
}

tc_default_class_is_safe() {
    local interface="$1"
    local default_line

    dog_config_reserves_default_class && return 1
    default_line=$(tc_class_line "$interface" "1:30")
    [ -z "$default_line" ] && return 0
    printf '%s\n' "$default_line" | grep -Eq '^class htb 1:30 parent 1:1([[:space:]]|$)' &&
        tc_class_rate_matches "$interface" "1:30" "$TC_DEFAULT_CLASS_RATE"
}

tc_has_other_consumers() {
    local interface="$1"
    local class_output filter_output

    class_output=$("$TC_BIN" class show dev "$interface" 2>/dev/null || true)
    if printf '%s\n' "$class_output" |
        awk '$1 == "class" && $3 != "1:1" && $3 != "1:30" { found=1 } END { exit found ? 0 : 1 }'; then
        return 0
    fi
    filter_output=$("$TC_BIN" filter show dev "$interface" parent 1:0 2>/dev/null || true)
    [ -n "$filter_output" ]
}

tc_legacy_tbf_is_owned() {
    local interface="$1"
    local qdisc_line="$2"
    local state_interface state_schema state_provider state_qdisc state_speed actual_rate

    printf '%s\n' "$qdisc_line" | grep -q ' tbf ' || return 1
    state_interface=$(tc_state_interface)
    state_schema=$(tc_state_value SCHEMA)
    state_provider=$(tc_state_value PROVIDER)
    state_qdisc=$(tc_state_value QDISC_LINE)
    state_speed=$(tc_state_value LIMIT_SPEED)
    [ "$state_interface" = "$interface" ] || return 1
    [ -z "$state_schema" ] || return 1
    [ -z "$state_provider" ] || [ "$state_provider" = "$TC_STATE_PROVIDER" ] || return 1
    [[ "$state_speed" =~ ^[1-9][0-9]*$ ]] || return 1
    if [ -n "$state_qdisc" ]; then
        [ "$qdisc_line" = "$state_qdisc" ] || return 1
    fi
    actual_rate=$(printf '%s\n' "$qdisc_line" |
        awk '{ for (i = 1; i < NF; i++) if ($i == "rate") { print $(i + 1); exit } }')
    [ "$(normalize_tc_rate_to_bps "$actual_rate" 2>/dev/null)" = "$((state_speed * 1000))" ]
}

current_boot_id() {
    cat /proc/sys/kernel/random/boot_id 2>/dev/null || true
}

write_tc_state() {
    local interface="$1"
    local speed="$2"
    local qdisc_line="$3"
    local state_file="${4:-$TC_STATE_FILE}"
    local period_start tmp_file

    period_start=$(get_period_start_date)
    tmp_file="${state_file}.tmp.$$"
    {
        printf 'SCHEMA=%s\n' "$TC_STATE_SCHEMA"
        printf 'PROVIDER=%s\n' "$TC_STATE_PROVIDER"
        printf 'INTERFACE=%s\n' "$interface"
        printf 'LIMIT_SPEED=%s\n' "$speed"
        printf 'QDISC_LINE=%s\n' "$qdisc_line"
        printf 'BOOT_ID=%s\n' "$(current_boot_id)"
        printf 'PERIOD_START=%s\n' "$period_start"
        printf 'APPLIED_AT=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    chmod 600 "$tmp_file" 2>/dev/null || true
    mv -f "$tmp_file" "$state_file" || { rm -f "$tmp_file"; return 1; }
}

tc_verify_unified_hierarchy() {
    local interface="$1"
    local parent_rate="$2"

    tc_root_is_htb_handle_one "$interface" || return 1
    tc_root_has_default_30 "$interface" || return 1
    tc_root_has_parent_class "$interface" || return 1
    tc_class_line "$interface" "1:30" |
        grep -Eq '^class htb 1:30 parent 1:1([[:space:]]|$)' || return 1
    tc_class_rate_matches "$interface" "1:1" "$parent_rate" "$parent_rate" || return 1
    tc_class_rate_matches "$interface" "1:30" "$TC_DEFAULT_CLASS_RATE" "$parent_rate"
}

tc_replace_base_classes() {
    local interface="$1"
    local parent_rate="$2"

    normalize_tc_rate_to_bps "$parent_rate" >/dev/null 2>&1 || return 1
    tc_default_class_is_safe "$interface" || return 1
    "$TC_BIN" class replace dev "$interface" parent 1: classid 1:1 htb \
        rate "$parent_rate" ceil "$parent_rate" 2>/dev/null || return 1
    "$TC_BIN" class replace dev "$interface" parent 1:1 classid 1:30 htb \
        rate "$TC_DEFAULT_CLASS_RATE" ceil "$parent_rate" 2>/dev/null
}

tc_state_allows_boot_rebuild() {
    local interface="$1"
    local state_boot_id boot_id state_provider state_speed

    [ "$(tc_state_interface)" = "$interface" ] || return 1
    state_provider=$(tc_state_value PROVIDER)
    [ -z "$state_provider" ] || [ "$state_provider" = "$TC_STATE_PROVIDER" ] || return 1
    state_speed=$(tc_state_value LIMIT_SPEED)
    [[ "$state_speed" =~ ^[1-9][0-9]*$ ]] || return 1
    state_boot_id=$(tc_state_value BOOT_ID)
    boot_id=$(current_boot_id)
    [ -n "$state_boot_id" ] && [ -n "$boot_id" ] && [ "$state_boot_id" != "$boot_id" ]
}

apply_tc_limit() {
    local speed="$1"
    local existing_qdisc state_interface mode=""
    local prepared_state="${TC_STATE_FILE}.prepared.$$"
    local old_parent_rate="" old_parent_ceil=""
    local old_default_line="" old_default_rate="" old_default_ceil=""
    local legacy_speed="" rollback_ok=false

    if [ -z "$TC_BIN" ] || ! [[ "$speed" =~ ^[1-9][0-9]*$ ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 未找到系统 tc 命令，无法执行限速" | tee -a "$LOG_FILE"
        return 1
    fi

    if ! acquire_tc_hierarchy_lock; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 无法取得统一 TC 层级锁，未修改 qdisc。" | tee -a "$LOG_FILE"
        return 1
    fi

    state_interface=$(tc_state_interface)
    if [ -n "$state_interface" ] && [ "$state_interface" != "$MAIN_INTERFACE" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') TC 状态文件属于接口 $state_interface，当前配置接口为 $MAIN_INTERFACE，将先清理旧接口限速。" | tee -a "$LOG_FILE"
        if ! clear_owned_tc_rules_locked "配置接口已变更"; then
            release_tc_hierarchy_lock
            return 1
        fi
        state_interface=""
    fi

    existing_qdisc=$(tc_root_qdisc "$MAIN_INTERFACE")
    if tc_root_is_unified_compatible "$MAIN_INTERFACE"; then
        mode="existing"
        if tc_state_is_unified_for_interface "$MAIN_INTERFACE" &&
           [ "$(tc_state_value LIMIT_SPEED)" = "$speed" ] &&
           tc_verify_unified_hierarchy "$MAIN_INTERFACE" "${speed}kbit"; then
            release_tc_hierarchy_lock
            echo "$(date '+%Y-%m-%d %H:%M:%S') 统一 HTB 整机限速规则保持生效" | tee -a "$LOG_FILE"
            return 0
        fi
        old_parent_rate=$(tc_class_value "$MAIN_INTERFACE" "1:1" rate)
        old_parent_ceil=$(tc_class_value "$MAIN_INTERFACE" "1:1" ceil)
        normalize_tc_rate_to_bps "$old_parent_rate" >/dev/null 2>&1 || mode=""
        normalize_tc_rate_to_bps "$old_parent_ceil" >/dev/null 2>&1 || mode=""
        old_default_line=$(tc_class_line "$MAIN_INTERFACE" "1:30")
        if [ -n "$old_default_line" ]; then
            old_default_rate=$(tc_class_value "$MAIN_INTERFACE" "1:30" rate)
            old_default_ceil=$(tc_class_value "$MAIN_INTERFACE" "1:30" ceil)
            normalize_tc_rate_to_bps "$old_default_rate" >/dev/null 2>&1 || mode=""
            normalize_tc_rate_to_bps "$old_default_ceil" >/dev/null 2>&1 || mode=""
        fi
    elif tc_legacy_tbf_is_owned "$MAIN_INTERFACE" "$existing_qdisc"; then
        mode="legacy-tbf"
        legacy_speed=$(tc_state_value LIMIT_SPEED)
    elif is_default_qdisc_line "$existing_qdisc"; then
        if [ -f "$TC_STATE_FILE" ] && ! tc_state_allows_boot_rebuild "$MAIN_INTERFACE"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') TC 状态存在，但当前 root qdisc 在本次开机中已变化；为避免覆盖外部策略，已停止。" | tee -a "$LOG_FILE"
            release_tc_hierarchy_lock
            return 1
        fi
        mode="new"
    fi

    if [ -z "$mode" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 检测到无法证明归属的 root qdisc：${existing_qdisc:-空}，未作修改。" | tee -a "$LOG_FILE"
        release_tc_hierarchy_lock
        return 1
    fi

    if ! write_tc_state "$MAIN_INTERFACE" "$speed" "" "$prepared_state"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 无法预写统一 HTB 状态，已拒绝修改系统 qdisc。" | tee -a "$LOG_FILE"
        release_tc_hierarchy_lock
        return 1
    fi

    if [ "$mode" != "existing" ] &&
       ! "$TC_BIN" qdisc replace dev "$MAIN_INTERFACE" root handle 1: htb default 30 2>/dev/null; then
        rm -f "$prepared_state"
        release_tc_hierarchy_lock
        echo "$(date '+%Y-%m-%d %H:%M:%S') 无法创建统一 HTB root qdisc。" | tee -a "$LOG_FILE"
        return 1
    fi

    if tc_replace_base_classes "$MAIN_INTERFACE" "${speed}kbit" &&
       tc_verify_unified_hierarchy "$MAIN_INTERFACE" "${speed}kbit" &&
       mv -f "$prepared_state" "$TC_STATE_FILE"; then
        release_tc_hierarchy_lock
        echo "$(date '+%Y-%m-%d %H:%M:%S') 统一 HTB 整机限速已应用，现有端口子类保持不变。" | tee -a "$LOG_FILE"
        return 0
    fi

    case "$mode" in
        existing)
            if "$TC_BIN" class replace dev "$MAIN_INTERFACE" parent 1: classid 1:1 htb \
                    rate "$old_parent_rate" ceil "$old_parent_ceil" 2>/dev/null; then
                if [ -n "$old_default_line" ]; then
                    "$TC_BIN" class replace dev "$MAIN_INTERFACE" parent 1:1 classid 1:30 htb \
                        rate "$old_default_rate" ceil "$old_default_ceil" 2>/dev/null && rollback_ok=true
                else
                    "$TC_BIN" class del dev "$MAIN_INTERFACE" classid 1:30 2>/dev/null || true
                    rollback_ok=true
                fi
            fi
            ;;
        legacy-tbf)
            if "$TC_BIN" qdisc replace dev "$MAIN_INTERFACE" root tbf rate "${legacy_speed}kbit" \
                burst 32kbit latency 400ms 2>/dev/null; then
                rollback_ok=true
            fi
            ;;
        new)
            if "$TC_BIN" qdisc del dev "$MAIN_INTERFACE" root handle 1: 2>/dev/null ||
               ! tc_root_is_htb_handle_one "$MAIN_INTERFACE"; then
                rollback_ok=true
            fi
            ;;
    esac

    if $rollback_ok; then
        rm -f "$prepared_state"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 统一 HTB 应用失败，已恢复修改前的 TC 状态。" | tee -a "$LOG_FILE"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 严重错误：统一 HTB 回滚失败；预写状态保留在 $prepared_state。" | tee -a "$LOG_FILE"
    fi
    release_tc_hierarchy_lock
    return 1
}

clear_owned_tc_rules_locked() {
    local reason="$1"
    local state_interface qdisc_line state_speed state_schema state_provider
    local rollback_ok=false

    if [ ! -f "$TC_STATE_FILE" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：未发现本脚本 TC 状态标记，保留现有 qdisc。" | tee -a "$LOG_FILE"
        return 0
    fi

    state_interface=$(tc_state_interface)
    if [ -z "$state_interface" ]; then
        rm -f "$TC_STATE_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：TC 状态文件无效，已移除状态文件。" | tee -a "$LOG_FILE"
        return 0
    fi

    if [ -z "$TC_BIN" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：未找到系统 tc 命令，无法清理本脚本限速。" | tee -a "$LOG_FILE"
        return 1
    fi

    qdisc_line=$(tc_root_qdisc "$state_interface")
    state_speed=$(tc_state_value LIMIT_SPEED)
    state_schema=$(tc_state_value SCHEMA)
    state_provider=$(tc_state_value PROVIDER)

    if [ -z "$state_schema" ]; then
        if is_default_qdisc_line "$qdisc_line" && tc_state_allows_boot_rebuild "$state_interface"; then
            rm -f "$TC_STATE_FILE"
            echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：旧 TBF 已随重启消失，仅清理旧状态。" | tee -a "$LOG_FILE"
            return 0
        fi
        if ! tc_legacy_tbf_is_owned "$state_interface" "$qdisc_line"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：旧 TBF 与状态记录不一致，保留规则和状态。" | tee -a "$LOG_FILE"
            return 1
        fi
        if ! "$TC_BIN" qdisc del dev "$state_interface" root 2>/dev/null; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：旧 TBF 清理失败，保留状态。" | tee -a "$LOG_FILE"
            return 1
        fi
        if rm -f "$TC_STATE_FILE"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：已清理本脚本旧 TBF。" | tee -a "$LOG_FILE"
            return 0
        fi
        "$TC_BIN" qdisc replace dev "$state_interface" root tbf rate "${state_speed}kbit" \
            burst 32kbit latency 400ms 2>/dev/null || true
        return 1
    fi

    if [ "$state_schema" != "$TC_STATE_SCHEMA" ] || [ "$state_provider" != "$TC_STATE_PROVIDER" ] ||
       ! [[ "$state_speed" =~ ^[1-9][0-9]*$ ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：TC 状态格式或归属无效，未修改 qdisc。" | tee -a "$LOG_FILE"
        return 1
    fi

    if is_default_qdisc_line "$qdisc_line"; then
        rm -f "$TC_STATE_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：统一 HTB 已不存在，仅清理本脚本状态。" | tee -a "$LOG_FILE"
        return 0
    fi
    if ! tc_root_is_unified_compatible "$state_interface" ||
       ! tc_verify_unified_hierarchy "$state_interface" "${state_speed}kbit"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：统一 HTB 与本脚本状态不一致，保留规则和状态。" | tee -a "$LOG_FILE"
        return 1
    fi

    if tc_has_other_consumers "$state_interface"; then
        if ! tc_replace_base_classes "$state_interface" "$TC_PARENT_RATE" ||
           ! tc_verify_unified_hierarchy "$state_interface" "$TC_PARENT_RATE"; then
            tc_replace_base_classes "$state_interface" "${state_speed}kbit" >/dev/null 2>&1 || true
            echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：无法撤销全局父限速，已尝试恢复。" | tee -a "$LOG_FILE"
            return 1
        fi
        if rm -f "$TC_STATE_FILE"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：已撤销整机上限，现有端口子类和过滤器保持不变。" | tee -a "$LOG_FILE"
            return 0
        fi
        tc_replace_base_classes "$state_interface" "${state_speed}kbit" >/dev/null 2>&1 && rollback_ok=true
    else
        if ! "$TC_BIN" qdisc del dev "$state_interface" root handle 1: 2>/dev/null &&
           tc_root_is_htb_handle_one "$state_interface"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：统一 HTB root 清理失败，保留状态。" | tee -a "$LOG_FILE"
            return 1
        fi
        if rm -f "$TC_STATE_FILE"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：已清理仅由 TrafficCop 使用的统一 HTB root。" | tee -a "$LOG_FILE"
            return 0
        fi
        if "$TC_BIN" qdisc replace dev "$state_interface" root handle 1: htb default 30 2>/dev/null &&
           tc_replace_base_classes "$state_interface" "${state_speed}kbit"; then
            rollback_ok=true
        fi
    fi

    if $rollback_ok; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：状态文件删除失败，已恢复原整机限速。" | tee -a "$LOG_FILE"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：状态文件删除失败且 TC 回滚失败，请立即检查。" | tee -a "$LOG_FILE"
    fi
    return 1
}

clear_owned_tc_rules() {
    local reason="$1"
    local result

    if ! acquire_tc_hierarchy_lock; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：无法取得统一 TC 层级锁。" | tee -a "$LOG_FILE"
        return 1
    fi
    clear_owned_tc_rules_locked "$reason"
    result=$?
    release_tc_hierarchy_lock
    return "$result"
}

write_usage_state() {
    local status="$1"
    local current_usage="$2"
    local limit_threshold="$3"
    local unit_label="$4"
    local tmp_file="${USAGE_STATE_FILE}.tmp.$$"

    {
        printf 'STATUS=%s\n' "$status"
        printf 'PERIOD_START=%s\n' "$(get_period_start_date)"
        printf 'PERIOD_END=%s\n' "$(get_period_end_date)"
        printf 'USAGE=%s\n' "$current_usage"
        printf 'TRAFFIC_LIMIT=%s\n' "$TRAFFIC_LIMIT"
        printf 'LIMIT_THRESHOLD=%s\n' "$limit_threshold"
        printf 'UNIT=%s\n' "$unit_label"
        printf 'UPDATED_EPOCH=%s\n' "$(date +%s)"
    } > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    chmod 600 "$tmp_file" 2>/dev/null || true
    mv -f "$tmp_file" "$USAGE_STATE_FILE" || { rm -f "$tmp_file"; return 1; }
}

has_pending_shutdown() {
    if shutdown --help 2>&1 | grep -q -- '--show'; then
        shutdown --show >/dev/null 2>&1
    elif command_exists pgrep; then
        pgrep -x shutdown >/dev/null 2>&1
    else
        return 1
    fi
}

write_shutdown_state() {
    local period_start boot_id
    local tmp_file="${SHUTDOWN_STATE_FILE}.tmp.$$"

    period_start=$(get_period_start_date)
    boot_id=$(current_boot_id)
    [[ "$period_start" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    [ -n "$boot_id" ] || return 1

    {
        printf 'PERIOD_START=%s\n' "$period_start"
        printf 'BOOT_ID=%s\n' "$boot_id"
        printf 'SCHEDULED_EPOCH=%s\n' "$(date +%s)"
    } > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    chmod 600 "$tmp_file" 2>/dev/null || true
    mv -f "$tmp_file" "$SHUTDOWN_STATE_FILE"
}

shutdown_reboot_guard_active() {
    local state_period state_boot current_period boot_id

    [ -f "$SHUTDOWN_STATE_FILE" ] || return 1
    state_period=$(shutdown_state_value "PERIOD_START")
    state_boot=$(shutdown_state_value "BOOT_ID")
    current_period=$(get_period_start_date)
    boot_id=$(current_boot_id)
    if [ -z "$state_period" ] || [ -z "$state_boot" ] || [ -z "$boot_id" ]; then
        return 2
    fi
    if [ "$state_period" != "$current_period" ]; then
        rm -f "$SHUTDOWN_STATE_FILE"
        return 1
    fi
    if [ -n "$state_boot" ] && [ -n "$boot_id" ] && [ "$state_boot" != "$boot_id" ]; then
        if ! write_enforcement_state "paused" "0" "shutdown_reboot"; then
            return 2
        fi
        echo "$(date '+%Y-%m-%d %H:%M:%S') 检测到关机限制后的系统重启；同一周期已自动暂停再次关机，等待用户手动恢复。" | tee -a "$LOG_FILE"
        return 0
    fi
    return 1
}

ENFORCEMENT_GUARD_MODE=""
ENFORCEMENT_GUARD_REASON=""
ENFORCEMENT_GUARD_REMAINING=0

enforcement_guard_active() {
    local mode until_epoch reason now

    ENFORCEMENT_GUARD_MODE=""
    ENFORCEMENT_GUARD_REASON=""
    ENFORCEMENT_GUARD_REMAINING=0
    [ -f "$ENFORCEMENT_STATE_FILE" ] || return 1
    mode=$(enforcement_state_value "MODE")
    until_epoch=$(enforcement_state_value "UNTIL_EPOCH")
    reason=$(enforcement_state_value "REASON")
    case "$mode" in
        paused)
            ENFORCEMENT_GUARD_MODE="paused"
            ENFORCEMENT_GUARD_REASON="$reason"
            return 0
            ;;
        grace)
            if ! [[ "$until_epoch" =~ ^[0-9]+$ ]]; then
                rm -f "$ENFORCEMENT_STATE_FILE"
                return 1
            fi
            now=$(date +%s)
            if [ "$now" -ge "$until_epoch" ]; then
                rm -f "$ENFORCEMENT_STATE_FILE"
                return 1
            fi
            ENFORCEMENT_GUARD_MODE="grace"
            ENFORCEMENT_GUARD_REASON="$reason"
            ENFORCEMENT_GUARD_REMAINING=$(( (until_epoch - now + 59) / 60 ))
            return 0
            ;;
        *)
            rm -f "$ENFORCEMENT_STATE_FILE"
            return 1
            ;;
    esac
}

owned_tc_limit_active() {
    local state_interface qdisc_line state_speed state_provider state_schema

    [ -f "$TC_STATE_FILE" ] || return 1
    state_interface=$(tc_state_interface)
    [ "$state_interface" = "$MAIN_INTERFACE" ] || return 1
    state_provider=$(tc_state_value PROVIDER)
    state_schema=$(tc_state_value SCHEMA)
    state_speed=$(tc_state_value LIMIT_SPEED)
    [[ "$state_speed" =~ ^[1-9][0-9]*$ ]] || return 1
    qdisc_line=$(tc_root_qdisc "$state_interface")
    if [ "$state_schema" = "$TC_STATE_SCHEMA" ] && [ "$state_provider" = "$TC_STATE_PROVIDER" ]; then
        tc_root_is_unified_compatible "$state_interface" &&
            tc_verify_unified_hierarchy "$state_interface" "${state_speed}kbit"
        return $?
    fi
    tc_legacy_tbf_is_owned "$state_interface" "$qdisc_line"
}

TC_BOOT_GRACE_REMAINING=0

tc_boot_grace_active() {
    local grace_minutes uptime_seconds grace_seconds

    TC_BOOT_GRACE_REMAINING=0
    grace_minutes="${TC_BOOT_GRACE_MINUTES:-10}"
    [[ "$grace_minutes" =~ ^[0-9]+$ ]] || grace_minutes=10
    [ "$grace_minutes" -gt 0 ] || return 1
    owned_tc_limit_active && return 1
    uptime_seconds=$(awk '{ printf "%d", $1 }' /proc/uptime 2>/dev/null) || return 1
    [[ "$uptime_seconds" =~ ^[0-9]+$ ]] || return 1
    grace_seconds=$((grace_minutes * 60))
    [ "$uptime_seconds" -lt "$grace_seconds" ] || return 1
    TC_BOOT_GRACE_REMAINING=$(( (grace_seconds - uptime_seconds + 59) / 60 ))
    return 0
}


# 修改 check_and_limit_traffic 函数
check_and_limit_traffic() {
    local current_usage limit_threshold unit_label shutdown_guard_status
    [ "${TRAFFIC_UNIT:-binary}" = "decimal" ] && unit_label="GB" || unit_label="GiB"

    if ! current_usage=$(get_traffic_usage); then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 无法可靠读取当前流量，本轮跳过限速判断并保留现有限速状态。" | tee -a "$LOG_FILE"
        return 1
    fi

    limit_threshold=$(echo "$TRAFFIC_LIMIT - $TRAFFIC_TOLERANCE" | bc 2>/dev/null || echo "0")

    if (( $(echo "$limit_threshold <= 0" | bc -l 2>/dev/null || echo "0") )); then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 检测到配置异常：限制阈值必须大于 0 $unit_label，本轮跳过限速判断" | tee -a "$LOG_FILE"
        return 1
    fi
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') 当前使用流量: $current_usage $unit_label，限制流量: $limit_threshold $unit_label" | tee -a "$LOG_FILE"
    
    if (( $(echo "$current_usage >= $limit_threshold" | bc -l 2>/dev/null || echo "0") )); then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 流量超出限制" | tee -a "$LOG_FILE"
        if [ "$LIMIT_MODE" = "shutdown" ]; then
            if [ -f "$TC_STATE_FILE" ] && ! clear_owned_tc_rules "关机模式不保留 TC 限速"; then
                return 1
            fi
            shutdown_reboot_guard_active
            shutdown_guard_status=$?
            if [ "$shutdown_guard_status" -eq 2 ]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') 无法写入关机重启保护状态，本轮拒绝再次关机。" | tee -a "$LOG_FILE"
                return 1
            fi
        fi
        if enforcement_guard_active; then
            if [ "$ENFORCEMENT_GUARD_MODE" = "grace" ]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') 当前处于执行宽限期，剩余约 $ENFORCEMENT_GUARD_REMAINING 分钟；本轮只统计，不执行限制。" | tee -a "$LOG_FILE"
                write_usage_state "grace" "$current_usage" "$limit_threshold" "$unit_label" || return 1
            else
                echo "$(date '+%Y-%m-%d %H:%M:%S') 限制执行已暂停（原因：${ENFORCEMENT_GUARD_REASON:-manual}）；本轮只统计，不执行限制。" | tee -a "$LOG_FILE"
                write_usage_state "paused" "$current_usage" "$limit_threshold" "$unit_label" || return 1
            fi
            return 0
        fi
        if [ "$LIMIT_MODE" = "tc" ]; then
            if tc_boot_grace_active; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') 系统仍在开机限速宽限期，剩余约 $TC_BOOT_GRACE_REMAINING 分钟；暂不下发 TC 限速。" | tee -a "$LOG_FILE"
                write_usage_state "grace" "$current_usage" "$limit_threshold" "$unit_label" || return 1
                return 0
            fi
            echo "$(date '+%Y-%m-%d %H:%M:%S') 使用 TC 模式限速" | tee -a "$LOG_FILE"
            local safe_limit_speed="${LIMIT_SPEED:-20}"
            if ! [[ "$safe_limit_speed" =~ ^[1-9][0-9]*$ ]]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') 检测到限速值异常：$safe_limit_speed，本轮拒绝执行 TC 限速" | tee -a "$LOG_FILE"
                return 1
            fi
            if ! apply_tc_limit "$safe_limit_speed"; then
                return 1
            fi
            write_usage_state "limited" "$current_usage" "$limit_threshold" "$unit_label" || return 1
        elif [ "$LIMIT_MODE" = "shutdown" ]; then
            if has_pending_shutdown; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') 流量超出限制，系统已有计划关机，未重复提交或覆盖" | tee -a "$LOG_FILE"
            else
                echo "$(date '+%Y-%m-%d %H:%M:%S') 流量超出限制，系统将在 1 分钟后关机" | tee -a "$LOG_FILE"
                if ! write_shutdown_state; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') 无法预写关机保护状态，本轮拒绝提交计划关机" | tee -a "$LOG_FILE"
                    return 1
                fi
                if ! shutdown -h +1 "流量超出限制，系统将在 1 分钟后关机"; then
                    if has_pending_shutdown; then
                        echo "$(date '+%Y-%m-%d %H:%M:%S') 关机命令返回失败但仍检测到计划任务，已保留归属状态供安全清理" | tee -a "$LOG_FILE"
                    elif ! rm -f "$SHUTDOWN_STATE_FILE"; then
                        echo "$(date '+%Y-%m-%d %H:%M:%S') 计划关机失败，且无法清理预写状态；下轮将继续安全核验" | tee -a "$LOG_FILE"
                    fi
                    echo "$(date '+%Y-%m-%d %H:%M:%S') 计划关机失败" | tee -a "$LOG_FILE"
                    return 1
                fi
            fi
            write_usage_state "shutdown" "$current_usage" "$limit_threshold" "$unit_label" || return 1
        fi
    else
        if ! clear_owned_tc_rules "流量正常"; then
            return 1
        fi
        echo "$(date '+%Y-%m-%d %H:%M:%S') 流量正常，已完成限速状态检查" | tee -a "$LOG_FILE"
        write_usage_state "normal" "$current_usage" "$limit_threshold" "$unit_label" || return 1
    fi
}


# 检查是否需要重置限制
check_reset_limit() {
    local period_start last_reset_period tmp_file enforcement_reason

    period_start=$(get_period_start_date)
    last_reset_period=$(cat "$PERIOD_STATE_FILE" 2>/dev/null || true)

    if [ "$last_reset_period" = "$period_start" ]; then
        return 0
    fi

    if ! clear_owned_shutdown_schedule; then
        return 1
    fi
    if [ -n "$last_reset_period" ]; then
        if ! clear_owned_tc_rules "新的流量周期开始"; then
            return 1
        fi
    fi
    rm -f "$USAGE_STATE_FILE"
    enforcement_reason=$(enforcement_state_value "REASON")
    if [ "$enforcement_reason" = "shutdown_reboot" ]; then
        rm -f "$ENFORCEMENT_STATE_FILE"
    fi

    tmp_file="${PERIOD_STATE_FILE}.tmp.$$"
    printf '%s\n' "$period_start" > "$tmp_file" || return 1
    chmod 600 "$tmp_file" 2>/dev/null || true
    mv -f "$tmp_file" "$PERIOD_STATE_FILE" || { rm -f "$tmp_file"; return 1; }
    if [ -n "$last_reset_period" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 检测到新的流量周期，已重置限制"| tee -a "$LOG_FILE"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 已初始化当前流量周期状态"| tee -a "$LOG_FILE"
    fi
    return 0
}

resolve_tc_self_check_interface() {
    local requested_interface="${1:-}"
    local configured_interface="" state_interface="" detected_interface=""

    if [ -n "$requested_interface" ]; then
        printf '%s\n' "$requested_interface"
        return 0
    fi
    configured_interface=$(grep '^MAIN_INTERFACE=' "$CONFIG_FILE" 2>/dev/null | tail -n 1 | cut -d'=' -f2-)
    state_interface=$(tc_state_interface)
    if [ -n "$configured_interface" ] && [ -n "$state_interface" ] &&
       [ "$configured_interface" != "$state_interface" ]; then
        return 1
    fi
    if [ -n "$configured_interface" ]; then
        printf '%s\n' "$configured_interface"
        return 0
    fi
    if [ -n "$state_interface" ]; then
        printf '%s\n' "$state_interface"
        return 0
    fi
    detected_interface=$(ip route show default 2>/dev/null |
        awk '{ for (i = 1; i <= NF; i++) if ($i == "dev" && (i + 1) <= NF) { print $(i + 1); exit } }')
    [ -n "$detected_interface" ] || return 1
    printf '%s\n' "$detected_interface"
}

# 这是显式接管入口；普通 cron 的 apply_tc_limit 仍会对外部 root fail-closed。
# --auto 只恢复已有 NTC 状态，--manual 还允许在 TC 模式下清除首次发现的冲突。
recover_owned_tc_hierarchy() {
    local mode="${1:---manual}"
    case "$mode" in
        --auto|--manual) ;;
        *)
            echo "不支持的 TC 恢复模式: $mode" >&2
            return 2
            ;;
    esac

    [ -n "$TC_BIN" ] || {
        echo "未找到系统 tc 命令，无法恢复。" >&2
        return 1
    }
    [[ "${MAIN_INTERFACE:-}" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || {
        echo "TrafficCop 配置中的网卡无效，拒绝修改 TC。" >&2
        return 1
    }

    local state_expected=false
    local state_interface=""
    local state_schema=""
    local state_provider=""
    local state_speed=""
    if [ -e "$TC_STATE_FILE" ]; then
        state_interface=$(tc_state_interface)
        state_schema=$(tc_state_value SCHEMA)
        state_provider=$(tc_state_value PROVIDER)
        state_speed=$(tc_state_value LIMIT_SPEED)
        if [ "$state_interface" != "$MAIN_INTERFACE" ] ||
           [ "$state_schema" != "$TC_STATE_SCHEMA" ] ||
           [ "$state_provider" != "$TC_STATE_PROVIDER" ] ||
           ! [[ "$state_speed" =~ ^[1-9][0-9]*$ ]]; then
            echo "TrafficCop TC 状态文件无法安全解释，拒绝删除 qdisc。" >&2
            return 1
        fi
        state_expected=true
    fi

    if [ "${DISABLED:-false}" = "true" ] && [ "$state_expected" = "false" ]; then
        echo "TrafficCop 当前已禁用，没有需要恢复的 TC 规则。"
        return 0
    fi
    if [ "${LIMIT_MODE:-}" != "tc" ] && [ "$state_expected" = "false" ]; then
        echo "TrafficCop 当前不是 TC 限速模式，没有需要恢复的 TC 规则。"
        return 0
    fi
    if [ "$mode" = "--auto" ] && [ "$state_expected" = "false" ]; then
        echo "当前没有需要自动恢复的 TrafficCop TC 状态。"
        return 0
    fi

    if ! acquire_tc_hierarchy_lock; then
        echo "无法取得统一 TC 层级锁，未修改 qdisc。" >&2
        return 1
    fi

    local qdisc_line
    qdisc_line=$(tc_root_qdisc "$MAIN_INTERFACE")
    if [ "$state_expected" = "true" ] &&
       tc_root_is_unified_compatible "$MAIN_INTERFACE" &&
       tc_verify_unified_hierarchy "$MAIN_INTERFACE" "${state_speed}kbit"; then
        release_tc_hierarchy_lock
        echo "Dog/NTC TC 规则完整，无需重建。"
        return 0
    fi

    # Dog 已恢复统一层级但 NTC 状态尚未建立时，不删树，交给现有全局限速逻辑原地协调。
    if [ "$state_expected" = "false" ] && tc_root_is_unified_compatible "$MAIN_INTERFACE"; then
        release_tc_hierarchy_lock
        check_and_limit_traffic
        return $?
    fi

    # 其余情况下只要仍配置了 Dog 端口类，就必须由共享入口先恢复整棵树。
    local dog_classes=""
    dog_classes=$(dog_configured_class_ids 2>/dev/null || true)
    if [ -n "$dog_classes" ]; then
        release_tc_hierarchy_lock
        echo "检测到 Dog 端口限速配置，请使用共享 traffic-tools-tc-recovery 服务恢复。" >&2
        return 1
    fi

    local prepared_state="${TC_STATE_FILE}.recovery.$$"
    if [ "$state_expected" = "true" ] &&
       ! write_tc_state "$MAIN_INTERFACE" "$state_speed" "" "$prepared_state"; then
        release_tc_hierarchy_lock
        echo "无法预写 TrafficCop TC 恢复状态，未删除当前 qdisc。" >&2
        return 1
    fi

    if ! is_default_qdisc_line "$qdisc_line" &&
       ! "$TC_BIN" qdisc del dev "$MAIN_INTERFACE" root 2>/dev/null; then
        rm -f "$prepared_state"
        release_tc_hierarchy_lock
        echo "无法删除当前冲突 root qdisc，TrafficCop 规则未重建。" >&2
        return 1
    fi
    rm -f "$DOG_TC_OWNER_FILE"

    if [ "$state_expected" = "true" ]; then
        if "$TC_BIN" qdisc replace dev "$MAIN_INTERFACE" root handle 1: htb default 30 2>/dev/null &&
           tc_replace_base_classes "$MAIN_INTERFACE" "${state_speed}kbit" &&
           tc_verify_unified_hierarchy "$MAIN_INTERFACE" "${state_speed}kbit" &&
           mv -f "$prepared_state" "$TC_STATE_FILE"; then
            release_tc_hierarchy_lock
            echo "TrafficCop 统一 HTB 已按现有状态重建。"
            return 0
        fi
        rm -f "$prepared_state"
        release_tc_hierarchy_lock
        echo "冲突 qdisc 已清除，但 TrafficCop 统一 HTB 未能完整重建。" >&2
        return 1
    fi

    release_tc_hierarchy_lock
    # 首次冲突没有旧状态时，删除完成后重新计算流量；只有确实超额才创建 NTC 层级。
    check_and_limit_traffic
}

tc_self_check() {
    local interface qdisc_line state_speed state_schema result=1

    if [ -z "$TC_BIN" ]; then
        echo "TC_SELF_CHECK=ERROR REASON=tc-not-found"
        return 1
    fi
    if ! interface=$(resolve_tc_self_check_interface "${1:-}") ||
       ! [[ "$interface" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
        echo "TC_SELF_CHECK=ERROR REASON=interface-unresolved"
        return 1
    fi
    if ! acquire_tc_hierarchy_lock; then
        echo "TC_SELF_CHECK=ERROR INTERFACE=$interface REASON=lock-timeout"
        return 1
    fi

    qdisc_line=$(tc_root_qdisc "$interface")
    if is_default_qdisc_line "$qdisc_line"; then
        if [ -f "$TC_STATE_FILE" ]; then
            echo "TC_SELF_CHECK=DRIFT INTERFACE=$interface REASON=state-without-unified-htb"
        else
            echo "TC_SELF_CHECK=OK INTERFACE=$interface MODEL=absent"
            result=0
        fi
    elif printf '%s\n' "$qdisc_line" | grep -q ' tbf '; then
        if tc_legacy_tbf_is_owned "$interface" "$qdisc_line"; then
            echo "TC_SELF_CHECK=OK INTERFACE=$interface MODEL=legacy-trafficcop-tbf ACTION=migrate-on-next-apply"
            result=0
        else
            echo "TC_SELF_CHECK=CONFLICT INTERFACE=$interface REASON=foreign-tbf"
        fi
    elif tc_root_is_unified_compatible "$interface"; then
        if ! tc_default_class_is_safe "$interface"; then
            echo "TC_SELF_CHECK=CONFLICT INTERFACE=$interface REASON=reserved-class-1:30"
        elif tc_state_is_unified_for_interface "$interface"; then
            state_speed=$(tc_state_value LIMIT_SPEED)
            if [[ "$state_speed" =~ ^[1-9][0-9]*$ ]] &&
               tc_verify_unified_hierarchy "$interface" "${state_speed}kbit"; then
                echo "TC_SELF_CHECK=OK INTERFACE=$interface MODEL=$TC_STATE_SCHEMA OWNER=trafficcop-lite"
                result=0
            else
                echo "TC_SELF_CHECK=DRIFT INTERFACE=$interface REASON=trafficcop-parent-mismatch"
            fi
        elif [ -f "$TC_STATE_FILE" ] && [ "$(tc_state_interface)" = "$interface" ]; then
            state_schema=$(tc_state_value SCHEMA)
            if [ -z "$state_schema" ]; then
                echo "TC_SELF_CHECK=DRIFT INTERFACE=$interface REASON=legacy-trafficcop-state-with-unified-htb ACTION=reapply-trafficcop-limit"
            else
                echo "TC_SELF_CHECK=DRIFT INTERFACE=$interface REASON=trafficcop-state-not-unified"
            fi
        elif tc_class_line "$interface" "1:30" >/dev/null &&
             [ -n "$(tc_class_line "$interface" "1:30")" ]; then
            echo "TC_SELF_CHECK=OK INTERFACE=$interface MODEL=$TC_STATE_SCHEMA OWNER=port-traffic-dog"
            result=0
        else
            echo "TC_SELF_CHECK=OK INTERFACE=$interface MODEL=legacy-dog-htb ACTION=add-default-class-on-next-apply"
            result=0
        fi
    else
        echo "TC_SELF_CHECK=CONFLICT INTERFACE=$interface REASON=foreign-root-qdisc"
    fi

    release_tc_hierarchy_lock
    return "$result"
}

setup_crontab() {
    local current_crontab new_crontab cron_entry

    if ! acquire_root_crontab_lock; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 无法取得 TrafficCop-Lite crontab 锁" | tee -a "$LOG_FILE"
        return 1
    fi
    if ! current_crontab="$(read_current_crontab)"; then
        release_root_crontab_lock
        return 1
    fi
    new_crontab="$(printf '%s\n' "$current_crontab" | grep -v -F "$SCRIPT_PATH" || true)"
    cron_entry="* * * * * $SCRIPT_PATH --run >/dev/null 2>&1 # TrafficCop-Lite Monitor"

    if ! { printf '%s\n' "$new_crontab"; printf '%s\n' "$cron_entry"; } | sed '/^[[:space:]]*$/d' | crontab -; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') Crontab 设置失败" | tee -a "$LOG_FILE"
        release_root_crontab_lock
        return 1
    fi

    release_root_crontab_lock
    echo "$(date '+%Y-%m-%d %H:%M:%S') Crontab 已设置，每分钟运行一次"| tee -a "$LOG_FILE"
}


# 主函数
main() {
    case "${1:-}" in
        --self-check|--tc-self-check)
            tc_self_check "${2:-}"
            return $?
            ;;
        --tc-clear-owned)
            clear_owned_tc_rules "${2:-手动清理}"
            return $?
            ;;
    esac

    # 在脚本开始时调用迁移函数
    migrate_files

    # 切换到工作目录
    cd "$WORK_DIR" || exit 1

    # 创建锁文件（如果不存在）
    touch "${LOCK_FILE}"
    chmod 600 "$LOCK_FILE" 2>/dev/null || true

    # cron 模式拿不到锁直接退出；显式/开机恢复允许短暂等待正在结束的 cron，
    # 避免两者恰好在开机同一分钟启动时让 recovery unit 偶发失败。
    exec 9>"${LOCK_FILE}"
    if [ "${1:-}" = "--tc-recover-owned" ]; then
        if ! flock -w 15 9; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 另一个脚本实例长时间占用监控锁，TC 恢复未执行。" | tee -a "$LOG_FILE"
            exit 1
        fi
    elif ! flock -n 9; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 另一个脚本实例正在运行，退出。" | tee -a "$LOG_FILE"
        exit 1
    fi
    trap 'trim_log_file "$LOG_FILE" "$LOG_MAX_LINES"; flock -u 9 2>/dev/null || true' EXIT
    command_exists vnstat && align_timezone_with_vnstat

    if [ "${1:-}" = "--tc-recover-owned" ]; then
        if ! read_config; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 配置文件读取失败，未修改 TC。" | tee -a "$LOG_FILE"
            return 1
        fi
        recover_owned_tc_hierarchy "${2:---manual}"
        return $?
    fi

    # 检查是否以 --run 模式运行
    if [ "$1" = "--run" ] || [ "$1" = "--cron" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 正在以自动化模式运行" | tee -a "$LOG_FILE"
        if read_config; then
            if [ "${DISABLED:-false}" = "true" ]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') 监控已标记为禁用，跳过自动检查" | tee -a "$LOG_FILE"
                return
            fi
            check_reset_limit || return 1
            check_and_limit_traffic
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') 配置文件读取失败，请检查配置" | tee -a "$LOG_FILE"
            return 1
        fi
        return
    fi

 # 非 --run 模式下的操作
  # 首先检查并安装必要的软件包
    if ! check_and_install_packages; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 依赖检查未通过，已停止后续配置和限速检查。" | tee -a "$LOG_FILE"
        return 1
    fi
    if check_existing_setup; then
        read_config || return 1
        show_current_config

        echo "$(date '+%Y-%m-%d %H:%M:%S') 是否需要修改配置？(y/n): 5秒内按任意键修改配置，否则保持现有配置" | tee -a "$LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 开始等待用户输入..." | tee -a "$LOG_FILE"
        
        if read -r -t 5 -n 1; then
            echo ""
            echo "$(date '+%Y-%m-%d %H:%M:%S') 开始修改配置..." | tee -a "$LOG_FILE"
            initial_config || return 1
            echo "$(date '+%Y-%m-%d %H:%M:%S') 配置已更新，脚本将每分钟自动运行一次" | tee -a "$LOG_FILE"
        else
            echo ""
            echo "$(date '+%Y-%m-%d %H:%M:%S') 等待超时，保持现有配置。" | tee -a "$LOG_FILE"
        fi
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 开始初始化配置..." | tee -a "$LOG_FILE"
        initial_config || return 1
        echo "$(date '+%Y-%m-%d %H:%M:%S') 初始配置完成，脚本将每分钟自动运行一次" | tee -a "$LOG_FILE"
    fi
    setup_crontab || return 1

    # 显示当前流量使用情况和限制状态
    if read_config; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 当前流量使用情况：" | tee -a "$LOG_FILE"
        local current_usage unit_label
        #echo "Debug: Current usage from get_traffic_usage: $current_usage" | tee -a "$LOG_FILE"
        if current_usage=$(get_traffic_usage); then
            local start_date
            start_date=$(get_period_start_date)
            echo "$(date '+%Y-%m-%d %H:%M:%S') 当前统计周期: $TRAFFIC_PERIOD (从 $start_date 开始)" | tee -a "$LOG_FILE"
            echo "$(date '+%Y-%m-%d %H:%M:%S') 统计模式: $TRAFFIC_MODE" | tee -a "$LOG_FILE"
            [ "${TRAFFIC_UNIT:-binary}" = "decimal" ] && unit_label="GB" || unit_label="GiB"
            echo "$(date '+%Y-%m-%d %H:%M:%S') 当前使用流量: $current_usage $unit_label" | tee -a "$LOG_FILE"
            echo "$(date '+%Y-%m-%d %H:%M:%S') 检查并限制流量：" | tee -a "$LOG_FILE"
            check_and_limit_traffic
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') 无法可靠获取流量数据，请检查 vnstat 配置；本轮不会清除现有限速。" | tee -a "$LOG_FILE"
            return 1
        fi
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置文件读取失败，请检查配置" | tee -a "$LOG_FILE"
        return 1
    fi
}



# 执行主函数
main "$@"
exit_code=$?
echo "-----------------------------------------------------"| tee -a "$LOG_FILE"
exit "$exit_code"
