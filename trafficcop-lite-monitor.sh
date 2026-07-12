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
LOG_MAX_LINES="${LOG_MAX_LINES:-5000}"
SCRIPT_VERSION="1.0.3"
mkdir -p "$WORK_DIR"
chmod 700 "$WORK_DIR" 2>/dev/null || true

trim_log_file() {
    local file="$1"
    local max_lines="$2"
    local tmp_file

    [ -f "$file" ] || return 0
    [[ "$max_lines" =~ ^[1-9][0-9]*$ ]] || max_lines=5000
    [ "$(wc -l < "$file" 2>/dev/null || echo 0)" -le "$max_lines" ] && return 0

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

# 设置时区为上海（东八区）
export TZ='Asia/Shanghai'

echo "-----------------------------------------------------"| tee -a "$LOG_FILE"
echo "$(date '+%Y-%m-%d %H:%M:%S') 当前版本：$SCRIPT_VERSION"| tee -a "$LOG_FILE"





migrate_files() {
    mkdir -p "$WORK_DIR"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 使用独立工作目录: $WORK_DIR" | tee -a "$LOG_FILE"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
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
                command_exists rc-update && run_privileged rc-update add "$service_name" default >/dev/null 2>&1 || true
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

    ensure_service_running "cron" cron crond
    ensure_service_running "vnStat" vnstat vnstatd

    # 验证系统 tc 命令是否可用；独立版的 tc 快捷命令不会用于限速。
    if [ -z "$TC_BIN" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 警告：'tc' 命令不可用，可能影响限速功能。" | tee -a "$LOG_FILE"
    fi

    # 获取 vnstat 版本
    local vnstat_version=$(vnstat --version 2>&1 | head -n 1)
    echo "$(date '+%Y-%m-%d %H:%M:%S') vnstat 版本: $vnstat_version" | tee -a "$LOG_FILE"

    # 获取主要网络接口
    local main_interface=$(ip route | grep default | sed -e 's/^.*dev \([^ ]*\).*$/\1/' | head -n 1)
    echo "$(date '+%Y-%m-%d %H:%M:%S') 主要网络接口: $main_interface" | tee -a "$LOG_FILE"

    # 获取 vnstat 统计开始时间
    if [ -n "$main_interface" ]; then
        local vnstat_json=$(vnstat -i "$main_interface" --json d)
        local vnstat_start_time=$(echo "$vnstat_json" | jq -r '.interfaces[0].created.date | "\(.year)-\(.month | tostring | if length == 1 then "0" + . else . end)-\(.day | tostring | if length == 1 then "0" + . else . end)"')
        
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
        if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH --run"; then
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
    fi

    if ! [[ "${PERIOD_START_DAY:-1}" =~ ^[0-9]+$ ]]; then
        PERIOD_START_DAY=1
    fi
    PERIOD_START_DAY=$((10#$PERIOD_START_DAY))
    if [ "$PERIOD_START_DAY" -lt 1 ] || [ "$PERIOD_START_DAY" -gt 31 ]; then
        PERIOD_START_DAY=1
    fi

    if ! [[ "${PERIOD_START_MONTH:-1}" =~ ^[0-9]+$ ]]; then
        PERIOD_START_MONTH=1
    fi
    PERIOD_START_MONTH=$((10#$PERIOD_START_MONTH))
    if [ "$PERIOD_START_MONTH" -lt 1 ] || [ "$PERIOD_START_MONTH" -gt 12 ]; then
        PERIOD_START_MONTH=1
    fi

    if ! [[ "${LIMIT_SPEED:-20}" =~ ^[1-9][0-9]*$ ]]; then
        LIMIT_SPEED=20
    fi

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

    if $has_error; then
        return 1
    fi
    return 0
}

# 读取配置
read_config() {
    if [ -f "$CONFIG_FILE" ]; then
        chmod 600 "$CONFIG_FILE" 2>/dev/null || true
        # shellcheck disable=SC1090
        source "$CONFIG_FILE" || return 1
        validate_config
    else
        return 1
    fi
}

# 写入配置
write_config() {
    cat > "$CONFIG_FILE" << EOF
TRAFFIC_MODE=$TRAFFIC_MODE
TRAFFIC_PERIOD=$TRAFFIC_PERIOD
TRAFFIC_LIMIT=$TRAFFIC_LIMIT
TRAFFIC_TOLERANCE=$TRAFFIC_TOLERANCE
PERIOD_START_DAY=${PERIOD_START_DAY:-1}
PERIOD_START_MONTH=${PERIOD_START_MONTH:-1}
LIMIT_SPEED=${LIMIT_SPEED:-20}
MAIN_INTERFACE=$MAIN_INTERFACE
LIMIT_MODE=$LIMIT_MODE
EOF
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    echo "$(date '+%Y-%m-%d %H:%M:%S') 配置已更新"| tee -a "$LOG_FILE"
}


# 显示当前配置
show_current_config() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') 当前配置:"| tee -a "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 流量统计模式: $TRAFFIC_MODE"| tee -a "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 流量统计周期: $TRAFFIC_PERIOD"| tee -a "$LOG_FILE"
    if [ "$TRAFFIC_PERIOD" = "yearly" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 年度起始月份: ${PERIOD_START_MONTH:-1}"| tee -a "$LOG_FILE"
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') 周期起始日: ${PERIOD_START_DAY:-1}"| tee -a "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 流量限制: $TRAFFIC_LIMIT GB"| tee -a "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 容错范围: $TRAFFIC_TOLERANCE GB"| tee -a "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 限速: ${LIMIT_SPEED:-20} kbit/s"| tee -a "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 主要网络接口: $MAIN_INTERFACE"| tee -a "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 限制模式: $LIMIT_MODE"| tee -a "$LOG_FILE"
}

# 检测主要网络接口
get_main_interface() {
    local main_interface=$(ip route | grep default | sed -n 's/^default via [0-9.]* dev \([^ ]*\).*/\1/p' | head -n1)
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

# 初始配置函数
echo "$(date '+%Y-%m-%d %H:%M:%S') 开始初始化配置"| tee -a "$LOG_FILE"
initial_config() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') 正在检测主要网络接口..."| tee -a "$LOG_FILE"
    MAIN_INTERFACE=$(get_main_interface)

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
        read -r -p "请输入流量限制 (GB): " TRAFFIC_LIMIT
        if [[ "$TRAFFIC_LIMIT" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (( $(echo "$TRAFFIC_LIMIT > 0" | bc -l 2>/dev/null || echo "0") )); then
            break
        else
            echo "无效输入，请输入一个大于 0 的数字。"
        fi
    done

    while true; do
        read -r -p "请输入容错范围 (GB): " TRAFFIC_TOLERANCE
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
                break 
                ;;
            2) 
                LIMIT_MODE="shutdown"
                LIMIT_SPEED=""  # 关机模式不需要限速
                break 
                ;;
            *) echo "无效输入，请重新选择。" ;;
        esac
    done

    write_config
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
    local current_date=$(date +%Y-%m-%d)
    local current_month=$(date +%m)
    local current_year=$(date +%Y)
    local anchor_this anchor_num current_num period_year period_month

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
    local start_num end_num vnstat_json usage_bytes rx_bytes tx_bytes usage_gib

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
        # 将字节转换为 GiB，使用 printf 确保格式正确
        usage_gib=$(echo "scale=3; $usage_bytes/1024/1024/1024" | bc 2>/dev/null) || return 1
        # 确保小数点前至少有一个0
        printf "%.3f\n" "$usage_gib" 2>/dev/null || echo "0.000"
    else
        echo "0.000"
    fi
}

tc_root_qdisc() {
    "$TC_BIN" qdisc show dev "$1" root 2>/dev/null | head -n 1
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

current_boot_id() {
    cat /proc/sys/kernel/random/boot_id 2>/dev/null || true
}

write_tc_state() {
    local interface="$1"
    local speed="$2"
    local qdisc_line="$3"
    local period_start

    period_start=$(get_period_start_date)
    {
        printf 'INTERFACE=%s\n' "$interface"
        printf 'LIMIT_SPEED=%s\n' "$speed"
        printf 'QDISC_LINE=%s\n' "$qdisc_line"
        printf 'BOOT_ID=%s\n' "$(current_boot_id)"
        printf 'PERIOD_START=%s\n' "$period_start"
        printf 'APPLIED_AT=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$TC_STATE_FILE"
    chmod 600 "$TC_STATE_FILE" 2>/dev/null || true
}

apply_tc_limit() {
    local speed="$1"
    local existing_qdisc state_interface state_qdisc_line state_speed state_boot_id boot_id

    if [ -z "$TC_BIN" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 未找到系统 tc 命令，无法执行限速" | tee -a "$LOG_FILE"
        return 1
    fi

    existing_qdisc=$(tc_root_qdisc "$MAIN_INTERFACE")
    state_interface=$(tc_state_interface)

    if [ -n "$state_interface" ] && [ "$state_interface" != "$MAIN_INTERFACE" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') TC 状态文件属于接口 $state_interface，当前配置接口为 $MAIN_INTERFACE，将先清理旧接口限速。" | tee -a "$LOG_FILE"
        if ! clear_owned_tc_rules "配置接口已变更"; then
            return 1
        fi
        existing_qdisc=$(tc_root_qdisc "$MAIN_INTERFACE")
        state_interface=""
    fi

    if [ -n "$state_interface" ]; then
        if echo "$existing_qdisc" | grep -q " tbf "; then
            state_qdisc_line=$(tc_state_value "QDISC_LINE")
            state_speed=$(tc_state_value "LIMIT_SPEED")
            if [ -n "$state_qdisc_line" ] && [ "$existing_qdisc" != "$state_qdisc_line" ]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') 当前 tbf 与本脚本状态记录不一致，保留现有规则和状态标记并停止自动覆盖。" | tee -a "$LOG_FILE"
                return 1
            fi
            if [ -z "$state_qdisc_line" ] && { ! [[ "$state_speed" =~ ^[0-9]+$ ]] || ! echo "$existing_qdisc" | grep -Eq "rate[[:space:]]+${state_speed}[Kk]bit"; }; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') 当前 tbf 与旧状态记录不一致，保留现有规则和状态标记并停止自动覆盖。" | tee -a "$LOG_FILE"
                return 1
            fi
        else
            state_boot_id=$(tc_state_value "BOOT_ID")
            boot_id=$(current_boot_id)
            if ! is_default_qdisc_line "$existing_qdisc" \
                || { [ -n "$state_boot_id" ] && [ -n "$boot_id" ] && [ "$state_boot_id" = "$boot_id" ]; }; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') 本脚本应用限速后 qdisc 已被外部修改：$existing_qdisc，保留现有网络策略和状态标记并停止自动覆盖。" | tee -a "$LOG_FILE"
                return 1
            fi
            echo "$(date '+%Y-%m-%d %H:%M:%S') 检测到系统已重启且本脚本旧 tbf 不再存在，将按当前周期重新应用限速。" | tee -a "$LOG_FILE"
        fi
    else
        if echo "$existing_qdisc" | grep -q " tbf "; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 检测到接口 $MAIN_INTERFACE 已存在 tbf 规则且无本脚本状态标记，跳过限速以避免覆盖系统原有限速。" | tee -a "$LOG_FILE"
            return 1
        fi
        if ! is_default_qdisc_line "$existing_qdisc"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 检测到接口 $MAIN_INTERFACE 已存在非默认 qdisc：$existing_qdisc，跳过限速以避免覆盖系统网络策略。" | tee -a "$LOG_FILE"
            return 1
        fi
    fi

    if "$TC_BIN" qdisc replace dev "$MAIN_INTERFACE" root tbf rate "${speed}kbit" burst 32kbit latency 400ms; then
        write_tc_state "$MAIN_INTERFACE" "$speed" "$(tc_root_qdisc "$MAIN_INTERFACE")"
        echo "$(date '+%Y-%m-%d %H:%M:%S') TC 限速规则已应用/更新" | tee -a "$LOG_FILE"
        return 0
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') TC 限速规则应用失败，请检查接口或 tc 状态" | tee -a "$LOG_FILE"
    return 1
}

clear_owned_tc_rules() {
    local reason="$1"
    local state_interface qdisc_line state_qdisc_line state_speed

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
    if echo "$qdisc_line" | grep -q " tbf "; then
        state_qdisc_line=$(tc_state_value "QDISC_LINE")
        state_speed=$(tc_state_value "LIMIT_SPEED")
        if [ -n "$state_qdisc_line" ] && [ "$qdisc_line" != "$state_qdisc_line" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：当前 tbf 与本脚本状态记录不一致，保留现有规则并移除状态标记。" | tee -a "$LOG_FILE"
            rm -f "$TC_STATE_FILE"
            return 0
        fi
        if [ -z "$state_qdisc_line" ]; then
            if ! echo "$state_speed" | grep -Eq '^[0-9]+$'; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：旧状态记录缺失限速速率，保留现有规则并移除状态标记。" | tee -a "$LOG_FILE"
                rm -f "$TC_STATE_FILE"
                return 0
            fi
            if ! echo "$qdisc_line" | grep -Eq "rate[[:space:]]+${state_speed}[Kk]bit"; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：当前 tbf 速率与旧状态记录不一致，保留现有规则并移除状态标记。" | tee -a "$LOG_FILE"
                rm -f "$TC_STATE_FILE"
                return 0
            fi
        fi
        if "$TC_BIN" qdisc del dev "$state_interface" root 2>/dev/null; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：已清理本脚本在接口 $state_interface 上应用的 TC 限速。" | tee -a "$LOG_FILE"
        else
            qdisc_line=$(tc_root_qdisc "$state_interface")
            if echo "$qdisc_line" | grep -q " tbf "; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：TC 限速清理失败，保留状态文件以便下次重试。" | tee -a "$LOG_FILE"
                return 1
            fi
            echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：接口已不存在 tbf 规则。" | tee -a "$LOG_FILE"
        fi
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') $reason：接口 $state_interface 当前没有 tbf 规则，仅移除本脚本状态文件。" | tee -a "$LOG_FILE"
    fi
    rm -f "$TC_STATE_FILE"
}


# 修改 check_and_limit_traffic 函数
check_and_limit_traffic() {
    local current_usage limit_threshold

    if ! current_usage=$(get_traffic_usage); then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 无法可靠读取当前流量，本轮跳过限速判断并保留现有限速状态。" | tee -a "$LOG_FILE"
        return 1
    fi

    limit_threshold=$(echo "$TRAFFIC_LIMIT - $TRAFFIC_TOLERANCE" | bc 2>/dev/null || echo "0")

    if (( $(echo "$limit_threshold < 0" | bc -l 2>/dev/null || echo "0") )); then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 检测到配置异常：容错范围大于流量限制，已将限制阈值按 0 GB 处理" | tee -a "$LOG_FILE"
        limit_threshold=0
    fi
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') 当前使用流量: $current_usage GB，限制流量: $limit_threshold GB" | tee -a "$LOG_FILE"
    
    if (( $(echo "$current_usage > $limit_threshold" | bc -l 2>/dev/null || echo "0") )); then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 流量超出限制" | tee -a "$LOG_FILE"
        if [ "$LIMIT_MODE" = "tc" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 使用 TC 模式限速" | tee -a "$LOG_FILE"
            local safe_limit_speed="${LIMIT_SPEED:-20}"
            if ! [[ "$safe_limit_speed" =~ ^[1-9][0-9]*$ ]]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') 检测到限速值异常：$safe_limit_speed，已使用默认值 20 kbit/s" | tee -a "$LOG_FILE"
                safe_limit_speed=20
            fi
            apply_tc_limit "$safe_limit_speed"
        elif [ "$LIMIT_MODE" = "shutdown" ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') 流量超出限制，系统将在 1 分钟后关机" | tee -a "$LOG_FILE"
            shutdown -h +1 "流量超出限制，系统将在 1 分钟后关机"
        fi
    else
        if ! clear_owned_tc_rules "流量正常"; then
            return 1
        fi
        echo "$(date '+%Y-%m-%d %H:%M:%S') 流量正常，已完成限速状态检查" | tee -a "$LOG_FILE"
    fi
}


# 检查是否需要重置限制
check_reset_limit() {
    local current_date period_start last_reset_period tmp_file

    current_date=$(date +%Y-%m-%d)
    period_start=$(get_period_start_date)

    if [[ "$current_date" == "$period_start" ]]; then
        last_reset_period=$(cat "$PERIOD_STATE_FILE" 2>/dev/null || true)
        if [ "$last_reset_period" = "$period_start" ]; then
            return 0
        fi

        if ! clear_owned_tc_rules "新的流量周期开始"; then
            return 1
        fi

        tmp_file="${PERIOD_STATE_FILE}.tmp.$$"
        printf '%s\n' "$period_start" > "$tmp_file" || return 1
        chmod 600 "$tmp_file" 2>/dev/null || true
        mv -f "$tmp_file" "$PERIOD_STATE_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 新的流量周期开始，重置限制"| tee -a "$LOG_FILE"
    fi
    return 0
}

setup_crontab() {
    local current_crontab new_crontab cron_entry

    current_crontab="$(crontab -l 2>/dev/null || true)"
    new_crontab="$(printf '%s\n' "$current_crontab" | grep -v -F "$SCRIPT_PATH" || true)"
    cron_entry="* * * * * $SCRIPT_PATH --run # TrafficCop-Lite Monitor"

    if ! { printf '%s\n' "$new_crontab"; printf '%s\n' "$cron_entry"; } | sed '/^[[:space:]]*$/d' | crontab -; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') Crontab 设置失败" | tee -a "$LOG_FILE"
        return 1
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') Crontab 已设置，每分钟运行一次"| tee -a "$LOG_FILE"
}


# 主函数
main() {
    # 在脚本开始时调用迁移函数
    migrate_files

    # 切换到工作目录
    cd "$WORK_DIR" || exit 1

    # 创建锁文件（如果不存在）
    touch "${LOCK_FILE}"
    chmod 600 "$LOCK_FILE" 2>/dev/null || true

    # 尝试获取文件锁。cron 模式拿不到锁直接退出，避免打断正在进行的交互配置。
    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 另一个脚本实例正在运行，退出。" | tee -a "$LOG_FILE"
        exit 1
    fi
    trap 'trim_log_file "$LOG_FILE" "$LOG_MAX_LINES"; flock -u 9 2>/dev/null || true' EXIT

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
        read_config
        show_current_config

        echo "$(date '+%Y-%m-%d %H:%M:%S') 是否需要修改配置？(y/n): 5秒内按任意键修改配置，否则保持现有配置" | tee -a "$LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 开始等待用户输入..." | tee -a "$LOG_FILE"
        
        start_time=$(date +%s.%N)
     if read -r -t 5 -n 1 modify_config; then
    end_time=$(date +%s.%N)
    duration=$(echo "$end_time - $start_time" | bc 2>/dev/null || echo "0")
    echo ""  # 换行
    echo "$(date '+%Y-%m-%d %H:%M:%S') 收到用户输入: '${modify_config}' (ASCII: $(printf '%d' "'$modify_config" 2>/dev/null || echo "N/A"))" | tee -a "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 等待时间: $duration 秒" | tee -a "$LOG_FILE"
    if (( $(echo "$duration < 0.1" | bc -l 2>/dev/null || echo "0") )); then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 警告：输入时间过短，可能是自动输入" | tee -a "$LOG_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') 忽略此输入，保持现有配置。" | tee -a "$LOG_FILE"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 开始修改配置..." | tee -a "$LOG_FILE"
        initial_config
        setup_crontab || return 1
        echo "$(date '+%Y-%m-%d %H:%M:%S') 配置已更新，脚本将每分钟自动运行一次" | tee -a "$LOG_FILE"
    fi
else
    end_time=$(date +%s.%N)
    duration=$(echo "$end_time - $start_time" | bc 2>/dev/null || echo "0")
    echo ""  # 换行
    echo "$(date '+%Y-%m-%d %H:%M:%S') 等待超时，无用户输入" | tee -a "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 等待时间: $duration 秒" | tee -a "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 保持现有配置。" | tee -a "$LOG_FILE"
fi
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') 开始初始化配置..." | tee -a "$LOG_FILE"
        initial_config
        setup_crontab || return 1
        echo "$(date '+%Y-%m-%d %H:%M:%S') 初始配置完成，脚本将每分钟自动运行一次" | tee -a "$LOG_FILE"
    fi

    # 显示当前流量使用情况和限制状态
    if read_config; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') 当前流量使用情况：" | tee -a "$LOG_FILE"
        local current_usage
        #echo "Debug: Current usage from get_traffic_usage: $current_usage" | tee -a "$LOG_FILE"
        if current_usage=$(get_traffic_usage); then
            local start_date=$(get_period_start_date)
            echo "$(date '+%Y-%m-%d %H:%M:%S') 当前统计周期: $TRAFFIC_PERIOD (从 $start_date 开始)" | tee -a "$LOG_FILE"
            echo "$(date '+%Y-%m-%d %H:%M:%S') 统计模式: $TRAFFIC_MODE" | tee -a "$LOG_FILE"
            echo "$(date '+%Y-%m-%d %H:%M:%S') 当前使用流量: $current_usage GB" | tee -a "$LOG_FILE"
            echo "$(date '+%Y-%m-%d %H:%M:%S') 检查并限制流量：" | tee -a "$LOG_FILE"
            check_and_limit_traffic
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') 无法可靠获取流量数据，请检查 vnstat 配置；本轮不会清除现有限速。" | tee -a "$LOG_FILE"
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
