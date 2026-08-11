#!/bin/bash

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 权限运行此脚本。"
    exit 1
fi

# 设置新的工作目录
WORK_DIR="/etc/trafficcop-lite"
mkdir -p "$WORK_DIR"
chmod 700 "$WORK_DIR" 2>/dev/null || true

# 更新文件路径
CONFIG_FILE="$WORK_DIR/tg_notifier_config.txt"
LAST_NOTIFICATION_FILE="$WORK_DIR/last_traffic_notification"
LAST_DAILY_REPORT_FILE="$WORK_DIR/last_daily_report"
PERIOD_STATE_FILE="$WORK_DIR/last_reset_period"
USAGE_STATE_FILE="$WORK_DIR/current_traffic_state"
SCRIPT_PATH="$WORK_DIR/trafficcop-lite-telegram.sh"
CRON_LOG="$WORK_DIR/tg_notifier_cron.log"
TG_LOCK_FILE="$WORK_DIR/tg_notifier.lock"
CRON_LOG_MAX_LINES="${CRON_LOG_MAX_LINES:-2000}"
TG_DEBUG="${TG_DEBUG:-false}"
SCRIPT_VERSION="1.1.1"

# 此函数只由 EXIT trap 调用，ShellCheck 无法沿字符串形式的 trap 识别调用关系。
# shellcheck disable=SC2317,SC2329
trim_log_file() {
    local file="$1"
    local max_lines="$2"
    local tmp_file

    if [ ! -f "$file" ]; then
        return
    fi
    if ! [[ "$max_lines" =~ ^[1-9][0-9]*$ ]]; then
        max_lines=2000
    fi
    local trim_at=$((max_lines + max_lines / 5))
    if [ "$(wc -l < "$file" 2>/dev/null || echo 0)" -le "$trim_at" ]; then
        return
    fi

    tmp_file="${file}.tmp.$$"
    tail -n "$max_lines" "$file" > "$tmp_file" 2>/dev/null && mv -f "$tmp_file" "$file"
    rm -f "$tmp_file" 2>/dev/null || true
}

log_cron() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') : $*" >> "$CRON_LOG"
}

debug_log() {
    if [ "$TG_DEBUG" = "true" ]; then
        log_cron "[调试] $*"
    fi
}

# 文件迁移函数
migrate_files() {
    mkdir -p "$WORK_DIR"
    echo "$(date '+%Y-%m-%d %H:%M:%S') 使用独立工作目录: $WORK_DIR" | tee -a "$CRON_LOG"
}

# 在脚本开始时调用迁移函数
migrate_files

# 切换到工作目录
cd "$WORK_DIR" || exit 1
trap 'trim_log_file "$CRON_LOG" "$CRON_LOG_MAX_LINES"' EXIT

echo "----------------------------------------------"| tee -a "$CRON_LOG"
echo "$(date '+%Y-%m-%d %H:%M:%S') : 当前版本：$SCRIPT_VERSION" | tee -a "$CRON_LOG"

# 检查是否有同名的 crontab 正在执行:
check_running() {
    local wait_seconds="${1:-0}"

    echo "$(date '+%Y-%m-%d %H:%M:%S') : 开始检查是否有其他实例运行" >> "$CRON_LOG"
    exec 8>"$TG_LOCK_FILE"
    chmod 600 "$TG_LOCK_FILE" 2>/dev/null || true
    if { [ "$wait_seconds" -gt 0 ] && ! flock -w "$wait_seconds" 8; } \
        || { [ "$wait_seconds" -eq 0 ] && ! flock -n 8; }; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') : 另一个脚本实例正在运行，退出脚本" >> "$CRON_LOG"
        echo "另一个 Telegram 通知任务正在运行，请稍后重试。"
        exec 8>&-
        return 1
    fi
    trap 'flock -u 8 2>/dev/null || true; trim_log_file "$CRON_LOG" "$CRON_LOG_MAX_LINES"' EXIT
    echo "$(date '+%Y-%m-%d %H:%M:%S') : 没有其他实例运行，继续执行" >> "$CRON_LOG"
}

release_running_lock() {
    flock -u 8 2>/dev/null || true
    exec 8>&-
    trap 'trim_log_file "$CRON_LOG" "$CRON_LOG_MAX_LINES"' EXIT
}

run_with_telegram_lock() {
    local status

    check_running 15 || return 1
    "$@"
    status=$?
    release_running_lock
    return "$status"
}

check_runtime_dependencies() {
    local command_name
    local missing_commands=()

    for command_name in curl crontab flock sed awk; do
        command -v "$command_name" >/dev/null 2>&1 || missing_commands+=("$command_name")
    done
    if [ "${#missing_commands[@]}" -gt 0 ]; then
        echo "缺少运行依赖：${missing_commands[*]}"
        echo "请先通过主菜单选项 1 完成流量监控依赖安装。"
        return 1
    fi
    return 0
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

    log_cron "读取当前 crontab 失败：$(cat "$error_file" 2>/dev/null)"
    rm -f "$error_file"
    return 1
}


is_valid_timezone() {
    local timezone="$1"

    case "$timezone" in
        ""|/*|*..*) return 1 ;;
        UTC|GMT) return 0 ;;
    esac
    [ -f "/usr/share/zoneinfo/$timezone" ]
}

# 读取配置
read_config() {
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
        echo "配置文件不存在或为空，需要进行初始化配置。"
        return 1
    fi

    chmod 600 "$CONFIG_FILE" 2>/dev/null || true

    # 旧配置没有开关字段时保持原行为：自动通知默认开启。
    TG_DISABLED=false
    # 读取配置文件
    # shellcheck disable=SC1090
    source "$CONFIG_FILE" || return 1
    REPORT_TIMEZONE="${REPORT_TIMEZONE:-Asia/Shanghai}"
    TG_DISABLED="${TG_DISABLED:-false}"

    # 检查必要的配置项是否都存在
    if [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ] || [ -z "$MACHINE_NAME" ] || [ -z "$DAILY_REPORT_TIME" ]; then
        echo "配置文件不完整，需要重新进行配置。"
        return 1
    fi
    if ! is_valid_timezone "$REPORT_TIMEZONE"; then
        echo "报告时区无效：$REPORT_TIMEZONE"
        return 1
    fi
    case "$TG_DISABLED" in
        true|false) ;;
        *)
            echo "自动通知开关配置无效：$TG_DISABLED"
            return 1
            ;;
    esac

    return 0
}

# 写入配置
write_config_value() {
    local key="$1"
    local value="$2"
    local quoted
    printf -v quoted '%q' "$value"
    printf '%s=%s\n' "$key" "$quoted"
}

write_config() {
    local tmp_file="${CONFIG_FILE}.tmp.$$"
    if ! {
        write_config_value "BOT_TOKEN" "$BOT_TOKEN"
        write_config_value "CHAT_ID" "$CHAT_ID"
        write_config_value "DAILY_REPORT_TIME" "$DAILY_REPORT_TIME"
        write_config_value "REPORT_TIMEZONE" "${REPORT_TIMEZONE:-Asia/Shanghai}"
        write_config_value "MACHINE_NAME" "$MACHINE_NAME"
        write_config_value "TG_DISABLED" "${TG_DISABLED:-false}"
    } > "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi
    chmod 600 "$tmp_file" 2>/dev/null || true
    mv -f "$tmp_file" "$CONFIG_FILE" || { rm -f "$tmp_file"; return 1; }
    echo "配置已保存到 $CONFIG_FILE"
}


# 初始配置
initial_config() {
    echo "======================================"
    echo "   修改 Telegram 通知配置"
    echo "======================================"
    echo ""
    echo "提示：按 Enter 保留当前配置，输入新值则更新配置"
    echo ""

    case "${TG_DISABLED:-false}" in
        true|false) ;;
        *) TG_DISABLED=false ;;
    esac
    
    local new_token new_chat_id new_machine_name new_daily_report_time new_report_timezone

    # Bot Token
    if [ -n "$BOT_TOKEN" ]; then
        # 隐藏部分Token显示
        local token_display="${BOT_TOKEN:0:10}...${BOT_TOKEN: -4}"
        echo "请输入Telegram Bot Token [当前: $token_display]: "
    else
        echo "请输入Telegram Bot Token: "
    fi
    read -r new_token
    # 如果输入为空且有原配置，保留原配置
    if [[ -z "$new_token" ]] && [[ -n "$BOT_TOKEN" ]]; then
        new_token="$BOT_TOKEN"
        echo "  → 保留原配置"
    fi
    # 如果还是空（首次配置），要求必须输入
    while [[ -z "$new_token" ]]; do
        echo "Bot Token 不能为空。请重新输入: "
        read -r new_token
    done

    # Chat ID
    if [ -n "$CHAT_ID" ]; then
        echo "请输入Telegram Chat ID [当前: $CHAT_ID]: "
    else
        echo "请输入Telegram Chat ID: "
    fi
    read -r new_chat_id
    if [[ -z "$new_chat_id" ]] && [[ -n "$CHAT_ID" ]]; then
        new_chat_id="$CHAT_ID"
        echo "  → 保留原配置"
    fi
    while [[ -z "$new_chat_id" ]]; do
        echo "Chat ID 不能为空。请重新输入: "
        read -r new_chat_id
    done

    # 机器名称
    if [ -n "$MACHINE_NAME" ]; then
        echo "请输入机器名称 [当前: $MACHINE_NAME]: "
    else
        echo "请输入机器名称: "
    fi
    read -r new_machine_name
    if [[ -z "$new_machine_name" ]] && [[ -n "$MACHINE_NAME" ]]; then
        new_machine_name="$MACHINE_NAME"
        echo "  → 保留原配置"
    fi
    while [[ -z "$new_machine_name" ]]; do
        echo "机器名称不能为空。请重新输入: "
        read -r new_machine_name
    done

    # 每日报告时间
    if [ -n "$DAILY_REPORT_TIME" ]; then
        echo "请输入每日报告时间 [当前: $DAILY_REPORT_TIME，格式 HH:MM]: "
    else
        echo "请输入每日报告时间 (格式 HH:MM，例如 01:00): "
    fi
    read -r new_daily_report_time
    if [[ -z "$new_daily_report_time" ]] && [[ -n "$DAILY_REPORT_TIME" ]]; then
        new_daily_report_time="$DAILY_REPORT_TIME"
        echo "  → 保留原配置"
    fi
    while [[ ! $new_daily_report_time =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; do
        echo "时间格式不正确。请重新输入 (HH:MM): "
        read -r new_daily_report_time
    done

    REPORT_TIMEZONE="${REPORT_TIMEZONE:-Asia/Shanghai}"
    echo "请输入每日报告时区 [当前: $REPORT_TIMEZONE，例如 Asia/Shanghai 或 UTC]: "
    read -r new_report_timezone
    new_report_timezone="${new_report_timezone:-$REPORT_TIMEZONE}"
    while ! is_valid_timezone "$new_report_timezone"; do
        echo "时区无效，请重新输入: "
        read -r new_report_timezone
    done

    # 更新配置文件（使用引号防止空格等特殊字符问题）
    BOT_TOKEN="$new_token"
    CHAT_ID="$new_chat_id"
    MACHINE_NAME="$new_machine_name"
    DAILY_REPORT_TIME="$new_daily_report_time"
    REPORT_TIMEZONE="$new_report_timezone"
    
    write_config || return 1
    
    echo ""
    echo "======================================"
    echo "配置已更新成功！"
    echo "======================================"
    echo ""
    read_config
}

telegram_send_message() {
    local message="$1"
    local response

    message="${message//%0A/$'\n'}"

    if ! response=$(curl -fsS --connect-timeout 10 --max-time 30 -X POST \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=$CHAT_ID" \
        --data-urlencode "text=$message" 2>/dev/null); then
        return 1
    fi
    echo "$response" | grep -Eq '"ok"[[:space:]]*:[[:space:]]*true'
}

# 发送限速警告
send_throttle_warning() {
    local message="⚠️ [${MACHINE_NAME}]限速警告：流量已达到限制，已启动 TC 模式限速。"
    telegram_send_message "$message"
}

# 发送限速解除通知
send_throttle_lifted() {
    local message="✅ [${MACHINE_NAME}]限速解除：流量已恢复正常，所有限制已清除。"
    telegram_send_message "$message"
}

# 发送新周期开始通知
send_new_cycle_notification() {
    local message="🔄 [${MACHINE_NAME}]新周期开始：新的流量统计周期已开始，之前的限速（如果有）已自动解除。"
    telegram_send_message "$message"
}

# 发送关机警告
send_shutdown_warning() {
    local message="🚨 [${MACHINE_NAME}]关机警告：流量已达到严重限制，系统已进入计划关机状态！"
    telegram_send_message "$message"
}




# 该函数由 run_with_telegram_lock 按菜单选择间接调用。
# shellcheck disable=SC2317,SC2329
test_telegram_notification() {
    local message="🔔 [${MACHINE_NAME}]这是一条测试消息。如果您收到这条消息，说明Telegram通知功能正常工作。"

    if telegram_send_message "$message"; then
        echo "✅ [${MACHINE_NAME}]测试消息已成功发送，请检查您的Telegram。"
    else
        echo "❌ [${MACHINE_NAME}]发送测试消息失败。请检查您的BOT_TOKEN和CHAT_ID设置。"
    fi
}

read_notification_state() {
    LAST_STATUS=""
    LAST_CYCLE_EVENT=""

    [ -f "$LAST_NOTIFICATION_FILE" ] || return 0
    if grep -q '^STATUS=' "$LAST_NOTIFICATION_FILE" 2>/dev/null; then
        LAST_STATUS=$(grep '^STATUS=' "$LAST_NOTIFICATION_FILE" | tail -n 1 | cut -d'=' -f2-)
        LAST_CYCLE_EVENT=$(grep '^CYCLE_EVENT=' "$LAST_NOTIFICATION_FILE" | tail -n 1 | cut -d'=' -f2-)
    else
        LAST_STATUS=$(tail -n 1 "$LAST_NOTIFICATION_FILE" | cut -d' ' -f3-)
    fi
}

write_notification_state() {
    local status="$1"
    local cycle_event="$2"
    local tmp_file="${LAST_NOTIFICATION_FILE}.tmp.$$"

    {
        printf 'STATUS=%s\n' "$status"
        printf 'CYCLE_EVENT=%s\n' "$cycle_event"
        printf 'UPDATED_AT=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$tmp_file" || return 1
    chmod 600 "$tmp_file" 2>/dev/null || true
    mv -f "$tmp_file" "$LAST_NOTIFICATION_FILE"
}

write_daily_report_state() {
    local report_date="$1"
    local tmp_file="${LAST_DAILY_REPORT_FILE}.tmp.$$"

    printf '%s\n' "$report_date" > "$tmp_file" || return 1
    chmod 600 "$tmp_file" 2>/dev/null || true
    mv -f "$tmp_file" "$LAST_DAILY_REPORT_FILE"
}

read_current_traffic_state() {
    local key value now age period_state

    CURRENT_TRAFFIC_STATUS=""
    CURRENT_TRAFFIC_PERIOD_START=""
    CURRENT_TRAFFIC_PERIOD_END=""
    CURRENT_TRAFFIC_USAGE=""
    CURRENT_TRAFFIC_LIMIT=""
    CURRENT_TRAFFIC_THRESHOLD=""
    CURRENT_TRAFFIC_UNIT=""
    CURRENT_TRAFFIC_UPDATED_EPOCH=""

    [ -s "$USAGE_STATE_FILE" ] || return 1
    while IFS='=' read -r key value; do
        value=${value%$'\r'}
        case "$key" in
            STATUS) CURRENT_TRAFFIC_STATUS="$value" ;;
            PERIOD_START) CURRENT_TRAFFIC_PERIOD_START="$value" ;;
            PERIOD_END) CURRENT_TRAFFIC_PERIOD_END="$value" ;;
            USAGE) CURRENT_TRAFFIC_USAGE="$value" ;;
            TRAFFIC_LIMIT) CURRENT_TRAFFIC_LIMIT="$value" ;;
            LIMIT_THRESHOLD) CURRENT_TRAFFIC_THRESHOLD="$value" ;;
            UNIT) CURRENT_TRAFFIC_UNIT="$value" ;;
            UPDATED_EPOCH) CURRENT_TRAFFIC_UPDATED_EPOCH="$value" ;;
        esac
    done < "$USAGE_STATE_FILE"

    case "$CURRENT_TRAFFIC_STATUS" in
        normal|limited|shutdown|grace|paused) ;;
        *) return 1 ;;
    esac
    [[ "$CURRENT_TRAFFIC_PERIOD_START" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    [[ "$CURRENT_TRAFFIC_PERIOD_END" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    [[ "$CURRENT_TRAFFIC_USAGE" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    [[ "$CURRENT_TRAFFIC_LIMIT" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    [[ "$CURRENT_TRAFFIC_THRESHOLD" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    [[ "$CURRENT_TRAFFIC_UPDATED_EPOCH" =~ ^[0-9]+$ ]] || return 1
    case "$CURRENT_TRAFFIC_UNIT" in
        GB|GiB) ;;
        *) return 1 ;;
    esac

    now=$(date +%s) || return 1
    age=$((now - CURRENT_TRAFFIC_UPDATED_EPOCH))
    [ "$age" -ge -60 ] && [ "$age" -le 300 ] || return 1
    period_state=$(cat "$PERIOD_STATE_FILE" 2>/dev/null || true)
    [ -z "$period_state" ] || [ "$period_state" = "$CURRENT_TRAFFIC_PERIOD_START" ]
}

check_and_notify() {
    local current_status="未知"
    local cycle_event=""
    local next_status next_cycle effective_last_status
    local cycle_failed=false
    local had_notification_state=false

    echo "$(date '+%Y-%m-%d %H:%M:%S') : 开始检查流量状态..."| tee -a "$CRON_LOG"

    cycle_event=$(cat "$PERIOD_STATE_FILE" 2>/dev/null || true)

    if read_current_traffic_state; then
        case "$CURRENT_TRAFFIC_STATUS" in
            shutdown) current_status="关机" ;;
            limited) current_status="限速" ;;
            normal) current_status="正常" ;;
            grace) current_status="宽限" ;;
            paused) current_status="暂停" ;;
        esac
    else
        log_cron "实时流量状态不存在、无效或已过期，不根据旧日志发送状态通知"
    fi

    [ -f "$LAST_NOTIFICATION_FILE" ] && had_notification_state=true
    read_notification_state
    next_status="$LAST_STATUS"
    next_cycle="$LAST_CYCLE_EVENT"
    effective_last_status="$LAST_STATUS"

    echo "$(date '+%Y-%m-%d %H:%M:%S') : 当前状态=$current_status，上次状态=${LAST_STATUS:-空}" | tee -a "$CRON_LOG"

    if ! $had_notification_state && [ -n "$cycle_event" ]; then
        next_cycle="$cycle_event"
    elif [ -n "$cycle_event" ] && [ "$cycle_event" != "$LAST_CYCLE_EVENT" ]; then
        if send_new_cycle_notification; then
            next_cycle="$cycle_event"
            next_status="正常"
            effective_last_status="正常"
            log_cron "新周期通知发送成功"
        else
            cycle_failed=true
            log_cron "新周期通知发送失败，将在下次任务重试"
        fi
    fi

    if ! $cycle_failed; then
        case "$current_status" in
            限速)
                if [ "$effective_last_status" != "限速" ]; then
                    if send_throttle_warning; then
                        next_status="限速"
                        log_cron "限速通知发送成功"
                    else
                        log_cron "限速通知发送失败，将在下次任务重试"
                    fi
                fi
                ;;
            关机)
                if [ "$effective_last_status" != "关机" ]; then
                    if send_shutdown_warning; then
                        next_status="关机"
                        log_cron "关机通知发送成功"
                    else
                        log_cron "关机通知发送失败，将在下次任务重试"
                    fi
                fi
                ;;
            正常)
                if [ "$effective_last_status" = "限速" ] || [ "$effective_last_status" = "关机" ]; then
                    if send_throttle_lifted; then
                        next_status="正常"
                        log_cron "限速解除通知发送成功"
                    else
                        log_cron "限速解除通知发送失败，将在下次任务重试"
                    fi
                elif [ -z "$effective_last_status" ]; then
                    next_status="正常"
                else
                    next_status="正常"
                fi
                ;;
            宽限|暂停)
                next_status="$current_status"
                ;;
            *)
                log_cron "无法识别当前状态，不发送通知"
                ;;
        esac
    fi

    if ! $had_notification_state || ! grep -q '^STATUS=' "$LAST_NOTIFICATION_FILE" 2>/dev/null \
        || [ "$next_status" != "$LAST_STATUS" ] || [ "$next_cycle" != "$LAST_CYCLE_EVENT" ]; then
        if ! write_notification_state "$next_status" "$next_cycle"; then
            log_cron "通知状态文件写入失败"
            return 1
        fi
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') : 流量检查完成。"| tee -a "$CRON_LOG"
}




# 设置定时任务
setup_cron() {
    local correct_entry="* * * * * $SCRIPT_PATH -cron >/dev/null 2>&1 # TrafficCop-Lite Telegram"
    local current_crontab new_crontab

    if ! current_crontab="$(read_current_crontab)"; then
        echo "读取当前 crontab 失败，未修改定时任务。"
        return 1
    fi
    new_crontab="$(printf '%s\n' "$current_crontab" | grep -v -F "$SCRIPT_PATH" || true)"

    if ! { printf '%s\n' "$new_crontab"; printf '%s\n' "$correct_entry"; } | sed '/^[[:space:]]*$/d' | crontab -; then
        echo "更新 Telegram crontab 失败。"
        return 1
    fi
    echo "已清理旧条目并设置唯一的 Telegram 每分钟任务。"

    # 显示当前的 crontab 内容
    echo "当前的 crontab 内容："
    crontab -l
}

remove_telegram_cron() {
    local current_crontab new_crontab

    if ! current_crontab="$(read_current_crontab)"; then
        echo "读取当前 crontab 失败，未修改定时任务。"
        return 1
    fi
    new_crontab="$(printf '%s\n' "$current_crontab" | grep -v -F "$SCRIPT_PATH" || true)"
    if ! printf '%s\n' "$new_crontab" | sed '/^[[:space:]]*$/d' | crontab -; then
        echo "移除 Telegram crontab 失败。"
        return 1
    fi
    echo "已移除 TrafficCop-Lite Telegram 自动通知任务。"
}

# 以下两个函数由 run_with_telegram_lock 按菜单选择间接调用。
# shellcheck disable=SC2317,SC2329
enable_telegram_notifications() {
    # 配置仍为关闭时先创建任务；即使 cron 立即触发也会安全跳过。
    if ! setup_cron; then
        echo "自动通知开启失败，当前仍保持关闭状态。"
        return 1
    fi

    TG_DISABLED=false
    if ! write_config; then
        TG_DISABLED=true
        remove_telegram_cron >/dev/null 2>&1 || true
        echo "自动通知开启失败：无法更新配置，已清理新建的定时任务。"
        return 1
    fi
    echo "Telegram 自动通知已开启。"
}

# shellcheck disable=SC2317,SC2329
disable_telegram_notifications() {
    TG_DISABLED=true
    if ! write_config; then
        echo "自动通知关闭失败：无法更新配置。"
        return 1
    fi
    if ! remove_telegram_cron; then
        echo "自动通知已标记为关闭，但定时任务清理失败；残留任务运行时也会跳过推送。"
        return 1
    fi
    echo "Telegram 自动通知已关闭；配置和手动功能仍保留。"
}

# 更新cron任务中的时间（当修改每日报告时间时调用）
update_cron_time() {
    local new_time="$1"
    echo "正在更新cron任务时间为: $new_time"
    
    # 重新读取配置以获取最新时间
    read_config || return 1
    
    # 关闭状态下只保存时间，不重新创建任务。
    if [ "${TG_DISABLED:-false}" != "true" ]; then
        setup_cron || return 1
    fi
    
    echo "cron任务时间已更新"
}

# 每日报告
daily_report() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') : 开始生成每日报告"| tee -a "$CRON_LOG"
    echo "$(date '+%Y-%m-%d %H:%M:%S') : DAILY_REPORT_TIME=$DAILY_REPORT_TIME"| tee -a "$CRON_LOG"
    echo "$(date '+%Y-%m-%d %H:%M:%S') : Telegram 配置已加载，机器名=$MACHINE_NAME"| tee -a "$CRON_LOG"
    if ! read_current_traffic_state; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') : 实时流量状态不存在、无效或已过期，稍后重试每日报告"| tee -a "$CRON_LOG"
        return 1
    fi

    local current_usage="${CURRENT_TRAFFIC_USAGE} ${CURRENT_TRAFFIC_UNIT}"
    local limit="${CURRENT_TRAFFIC_LIMIT} ${CURRENT_TRAFFIC_UNIT}"

    # 构建基础消息
    local message="📊 [${MACHINE_NAME}]每日流量报告%0A%0A🖥️ 机器总流量：%0A当前使用：$current_usage%0A流量限制：$limit"
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') : 准备发送消息"| tee -a "$CRON_LOG"
    
    debug_log "发送到TG的消息长度: ${#message}字符"

    echo "$(date '+%Y-%m-%d %H:%M:%S') : 尝试发送Telegram消息"| tee -a "$CRON_LOG"

    if telegram_send_message "$message"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') : 每日报告发送成功"| tee -a "$CRON_LOG"
        return 0
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') : 每日报告发送失败"| tee -a "$CRON_LOG"
        return 1
    fi
}



# 主任务
main() {
    debug_log "进入主任务，参数数量=$#，参数=$*"
    
    check_runtime_dependencies || return 1
    
if [[ "$*" == *"-cron"* ]]; then
    check_running || return 1
    log_cron "进入cron模式"
    if read_config; then
        debug_log "成功读取配置文件"
        if [ "${TG_DISABLED:-false}" = "true" ]; then
            log_cron "Telegram 自动通知已关闭，跳过本轮任务"
            return 0
        fi
        # 继续执行其他操作
        check_and_notify || log_cron "状态检查未完整成功"
        
    # 检查是否需要发送每日报告
        current_time=$(TZ="$REPORT_TIMEZONE" date +%H:%M)
        current_date=$(TZ="$REPORT_TIMEZONE" date +%Y-%m-%d)
        last_report_date=$(cat "$LAST_DAILY_REPORT_FILE" 2>/dev/null || true)
        debug_log "当前时间: $current_time, 设定的报告时间: $DAILY_REPORT_TIME, 时区: $REPORT_TIMEZONE"
        if [[ "$current_time" > "$DAILY_REPORT_TIME" || "$current_time" == "$DAILY_REPORT_TIME" ]] && [ "$last_report_date" != "$current_date" ]; then
            log_cron "已到报告时间且今日尚未发送，准备发送每日报告"
            if daily_report; then
                if write_daily_report_state "$current_date"; then
                    log_cron "每日报告发送成功"
                else
                    log_cron "每日报告已发送，但状态文件写入失败；请检查目录权限以避免重复发送"
                fi
            else
                log_cron "每日报告发送失败"
            fi
        else
            debug_log "尚未到报告时间或今日已经发送，不发送报告"
        fi
    else
        log_cron "配置文件不存在或不完整，跳过检查"
        exit 1
    fi

    else
        # 菜单模式 (替换原来的交互模式)
        if ! read_config; then
            echo "需要进行初始化配置。"
            initial_config || return 1
        fi
        
        if [ "${TG_DISABLED:-false}" = "true" ]; then
            if ! remove_telegram_cron; then
                return 1
            fi
        elif ! setup_cron; then
            return 1
        fi
        
        # 显示菜单
        while true; do
            clear
            echo "======================================"
            echo "      Telegram 通知脚本管理菜单"
            echo "======================================"
            echo "当前配置摘要："
            echo "机器名称: $MACHINE_NAME"
            echo "每日报告时间: $DAILY_REPORT_TIME"
            echo "报告时区: ${REPORT_TIMEZONE:-Asia/Shanghai}"
            echo "Bot Token: ${BOT_TOKEN:0:10}..." # 只显示前10个字符
            echo "Chat ID: $CHAT_ID"
            if [ "${TG_DISABLED:-false}" = "true" ]; then
                echo "自动通知: 已关闭"
            else
                echo "自动通知: 已开启"
            fi
            echo "======================================"
            echo "1. 检查流量并推送"
            echo "2. 手动发送每日报告"
            echo "3. 发送测试消息"
            echo "4. 重新加载配置"
            echo "5. 修改配置"
            echo "6. 修改每日报告时间"
            echo "7. 查看通知运行日志"
            echo "8. 开启/关闭自动通知"
            echo "0. 退出"
            echo "======================================"
            echo -n "请选择操作 [0-8]: "
            
            if ! read -r choice; then
                echo
                echo "输入已结束，退出脚本。"
                exit 0
            fi
            echo
            
            case $choice in
                0)
                    echo "退出脚本。"
                    exit 0
                    ;;
                1)
                    echo "正在检查流量并推送..."
                    run_with_telegram_lock check_and_notify
                    ;;
                2)
                    echo "正在发送每日报告..."
                    run_with_telegram_lock daily_report
                    ;;
                3)
                    echo "正在发送测试消息..."
                    run_with_telegram_lock test_telegram_notification
                    ;;
                4)
                    echo "正在重新加载配置..."
                    if read_config; then
                        echo "配置已重新加载。"
                    else
                        echo "配置重新加载失败。"
                    fi
                    ;;
                5)
                    echo "进入配置修改模式..."
                    initial_config || echo "配置修改失败。"
                    ;;
                6)
                    local config_tmp="${CONFIG_FILE}.tmp.$$"
                    echo "修改每日报告时间"
                    echo -n "请输入新的每日报告时间 (HH:MM): "
                    read -r new_time
                    if [[ $new_time =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                        if ! cp "$CONFIG_FILE" "$CONFIG_FILE.backup" \
                            || ! awk -v new_time="$new_time" '
                        /^DAILY_REPORT_TIME=/ { print "DAILY_REPORT_TIME=" new_time; next }
                        { print }
                        ' "$CONFIG_FILE.backup" > "$config_tmp" \
                            || ! chmod 600 "$config_tmp" 2>/dev/null \
                            || ! mv -f "$config_tmp" "$CONFIG_FILE"; then
                            rm -f "$config_tmp"
                            echo "每日报告时间更新失败，原配置未被覆盖。"
                            continue
                        fi
                        chmod 600 "$CONFIG_FILE.backup" 2>/dev/null || true
                        
                        echo "每日报告时间已更新为 $new_time"
                        # 更新 cron 任务
                        if ! update_cron_time "$new_time"; then
                            echo "定时任务更新失败，请检查上方错误。"
                            continue
                        fi
                    else
                        echo "无效的时间格式。请使用 HH:MM 格式 (如: 09:30)"
                    fi
                    ;;
                7)
                    echo "查看最近的 Telegram 通知运行日志..."
                    if [ -f "$CRON_LOG" ]; then
                        tail -80 "$CRON_LOG"
                    else
                        echo "通知日志不存在"
                    fi
                    ;;
                8)
                    if [ "${TG_DISABLED:-false}" = "true" ]; then
                        run_with_telegram_lock enable_telegram_notifications
                    else
                        run_with_telegram_lock disable_telegram_notifications
                    fi
                    ;;
                *)
                    echo "无效的选择，请输入 0-8"
                    ;;
            esac
            
            if [ "$choice" != "0" ]; then
                echo
                echo "按 Enter 键继续..."
                read -r
            fi
        done
    fi
}


# 执行主函数
main "$@"
exit_code=$?
echo "----------------------------------------------"| tee -a "$CRON_LOG"
exit "$exit_code"
