#!/bin/bash

# TrafficCop 机器限速管理脚本 v2.9
# 提供完整的启用/禁用/恢复机器限速功能

WORK_DIR="/etc/trafficcop-lite"
CONFIG_FILE="$WORK_DIR/traffic_monitor_config.txt"
BACKUP_CONFIG_FILE="$CONFIG_FILE.disabled.backup"
SCRIPT_PATH="$WORK_DIR/trafficcop-lite-monitor.sh"
TC_STATE_FILE="$WORK_DIR/tc_limit_state"
ENFORCEMENT_STATE_FILE="$WORK_DIR/enforcement_state"
SHUTDOWN_STATE_FILE="$WORK_DIR/shutdown_limit_state"
MONITOR_LOCK_FILE="$WORK_DIR/traffic_monitor.lock"
VNSTAT_CONFIG_PATH_FILE="$WORK_DIR/vnstat_config_path"
ROOT_CRONTAB_LOCK_FILE="${TRAFFICCOP_ROOT_CRONTAB_LOCK_FILE:-$WORK_DIR/root-crontab.lock}"
TC_STATE_SCHEMA="traffic-tools-unified-htb-v1"
TC_STATE_PROVIDER="trafficcop-lite"
CRON_COMMENT="# TrafficCop-Lite Monitor"

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

    echo "读取当前 crontab 失败：$(cat "$error_file" 2>/dev/null)" >&2
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

tc_state_value() {
    local key="$1"
    if [ -f "$TC_STATE_FILE" ]; then
        grep "^${key}=" "$TC_STATE_FILE" 2>/dev/null | tail -n 1 | cut -d'=' -f2-
    fi
}

tc_root_qdisc() {
    local interface="$1"
    local qdisc_state qdisc_line
    [ -n "$TC_BIN" ] && [ -n "$interface" ] || return 2
    qdisc_state=$("$TC_BIN" qdisc show dev "$interface" root 2>/dev/null) || return 2
    qdisc_line=$(awk 'NR == 1 { print; exit }' <<< "$qdisc_state")
    [ -n "$qdisc_line" ] || return 1
    printf '%s\n' "$qdisc_line"
}

tc_class_output() {
    local interface="$1"
    [ -n "$TC_BIN" ] && [ -n "$interface" ] || return 2
    "$TC_BIN" class show dev "$interface" 2>/dev/null || return 2
}

enforcement_state_value() {
    local key="$1"
    if [ -f "$ENFORCEMENT_STATE_FILE" ]; then
        grep "^${key}=" "$ENFORCEMENT_STATE_FILE" 2>/dev/null | tail -n 1 | cut -d'=' -f2-
    fi
}

has_pending_shutdown() {
    if shutdown --help 2>&1 | grep -q -- '--show'; then
        shutdown --show >/dev/null 2>&1
    elif command -v pgrep >/dev/null 2>&1; then
        pgrep -x shutdown >/dev/null 2>&1
    else
        return 1
    fi
}

shutdown_task_token_from_state() {
    local task_token
    task_token=$(grep '^TASK_TOKEN=' "$SHUTDOWN_STATE_FILE" 2>/dev/null |
        tail -n 1 | cut -d'=' -f2-)
    [[ "$task_token" =~ ^trafficcop-lite-[0-9A-Za-z-]{8,80}$ ]] || return 1
    printf '%s\n' "$task_token"
}

pending_shutdown_matches_owned_state() {
    local task_token wall_state
    has_pending_shutdown || return 1
    task_token=$(shutdown_task_token_from_state) || return 1
    if command -v busctl >/dev/null 2>&1; then
        wall_state=$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
            org.freedesktop.login1.Manager WallMessage 2>/dev/null || true)
        if [ -n "$wall_state" ] && grep -Fq "$task_token" <<< "$wall_state"; then
            return 0
        fi
    fi
    if [ -r /run/systemd/shutdown/scheduled ] &&
       grep -Fq "$task_token" /run/systemd/shutdown/scheduled 2>/dev/null; then
        return 0
    fi
    return 1
}

write_enforcement_state_file() {
    local mode="$1"
    local until_epoch="$2"
    local reason="$3"
    local target_file="$4"
    local tmp_file="${target_file}.tmp.$$"

    {
        printf 'MODE=%s\n' "$mode"
        printf 'UNTIL_EPOCH=%s\n' "$until_epoch"
        printf 'REASON=%s\n' "$reason"
        printf 'UPDATED_AT=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    chmod 600 "$tmp_file" 2>/dev/null || true
    mv -f "$tmp_file" "$target_file"
}

write_enforcement_state() {
    write_enforcement_state_file "$1" "$2" "$3" "$ENFORCEMENT_STATE_FILE"
}

cancel_owned_shutdown() {
    local state_boot current_boot

    if [ -f "$SHUTDOWN_STATE_FILE" ]; then
        state_boot=$(grep '^BOOT_ID=' "$SHUTDOWN_STATE_FILE" 2>/dev/null | tail -n 1 | cut -d'=' -f2-)
        current_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
        if [ -n "$state_boot" ] && [ -n "$current_boot" ] && [ "$state_boot" != "$current_boot" ]; then
            rm -f "$SHUTDOWN_STATE_FILE" || return 1
            echo "✓ 已清理上次开机遗留的关机状态，未触碰本次开机的计划关机"
            return 0
        fi
        if { [ -z "$state_boot" ] || [ -z "$current_boot" ]; } && has_pending_shutdown; then
            echo "✗ 无法确认计划关机是否属于本脚本，已保留系统任务和状态文件"
            return 1
        fi
        if has_pending_shutdown; then
            if ! pending_shutdown_matches_owned_state; then
                echo "✗ 当前计划关机无法与本脚本任务标识匹配，已保留系统任务和状态文件"
                return 1
            fi
            if ! shutdown -c 2>/dev/null || has_pending_shutdown; then
                echo "✗ 无法取消本脚本记录的计划关机，已保留状态文件"
                return 1
            fi
        fi
        rm -f "$SHUTDOWN_STATE_FILE" || return 1
        echo "✓ 已取消本脚本记录的计划关机"
    fi
}

begin_enable_grace() {
    local grace_minutes="${1:-10}"
    local until_epoch result=0
    local enforcement_candidate="${ENFORCEMENT_STATE_FILE}.enable-candidate.$$"

    ENABLE_TC_CLEAR_ATTEMPTED=false
    if ! [[ "$grace_minutes" =~ ^[0-9]+$ ]] || [ "$grace_minutes" -lt 1 ] || [ "$grace_minutes" -gt 1440 ]; then
        grace_minutes=10
    fi
    until_epoch=$(( $(date +%s) + grace_minutes * 60 ))
    rm -f "$enforcement_candidate"
    if ! write_enforcement_state_file "grace" "$until_epoch" "enable" "$enforcement_candidate"; then
        rm -f "$enforcement_candidate"
        return 1
    fi

    if ! acquire_monitor_cleanup_lock; then
        rm -f "$enforcement_candidate"
        return 1
    fi
    # 在同一监控锁内先撤销旧整机限速，再取消自有计划关机，最后提交宽限状态。
    # 因此成功返回时，“宽限期间只统计”与实际 TC/关机运行态一致。
    ENABLE_TC_CLEAR_ATTEMPTED=true
    clear_tc_rules || result=$?
    if [ "$result" -eq 0 ]; then
        cancel_owned_shutdown || result=$?
    fi
    if [ "$result" -eq 0 ] && ! mv -f "$enforcement_candidate" "$ENFORCEMENT_STATE_FILE"; then
        result=1
    fi
    release_monitor_cleanup_lock
    rm -f "$enforcement_candidate"
    return "$result"
}

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 检查网络接口
get_main_interface() {
    local main_interface
    if [ -f "$CONFIG_FILE" ]; then
        chmod 600 "$CONFIG_FILE" 2>/dev/null || true
        main_interface=$(grep '^MAIN_INTERFACE=' "$CONFIG_FILE" 2>/dev/null | tail -n 1 | cut -d'=' -f2-)
        if [ -n "$main_interface" ]; then
            echo "$main_interface"
            return
        fi
    fi
    ip route | grep default | awk '{print $5}' | head -n1
}

# 清除TC限速规则
clear_tc_rules() {
    if [ ! -f "$TC_STATE_FILE" ]; then
        echo "✓ 未发现本脚本拥有的 TC 限速状态"
        return 0
    fi
    if [ ! -f "$SCRIPT_PATH" ]; then
        echo "找不到 TrafficCop 监控脚本，无法安全清理统一 HTB。"
        return 1
    fi
    bash "$SCRIPT_PATH" --tc-clear-owned "机器限速管理"
}

# 停止监控进程
stop_monitor_process() {
    echo "停止TrafficCop监控进程..."
    
    # 杀死相关进程
    pkill -f "$SCRIPT_PATH" 2>/dev/null || true
    
    echo "✓ 监控进程已停止"
}

acquire_monitor_cleanup_lock() {
    touch "$MONITOR_LOCK_FILE" || return 1
    chmod 600 "$MONITOR_LOCK_FILE" 2>/dev/null || true
    exec 9>"$MONITOR_LOCK_FILE"
    if ! flock -w 15 9; then
        exec 9>&-
        return 1
    fi
}

release_monitor_cleanup_lock() {
    flock -u 9 2>/dev/null || true
    exec 9>&-
}

clear_tc_rules_with_lock() {
    local clear_status

    if ! acquire_monitor_cleanup_lock; then
        echo "✗ 无法取得监控锁，未清理 TC 规则"
        return 1
    fi
    clear_tc_rules
    clear_status=$?
    release_monitor_cleanup_lock
    return "$clear_status"
}

# 移除定时任务
remove_cron_job() {
    local current_crontab crontab_tmp

    echo "移除定时任务..."

    if ! acquire_root_crontab_lock; then
        echo "✗ 无法取得 TrafficCop-Lite crontab 锁，未作修改"
        return 1
    fi
    if ! current_crontab="$(read_current_crontab)"; then
        echo "✗ 读取当前定时任务失败，未作修改"
        release_root_crontab_lock
        return 1
    fi
    if ! crontab_tmp="$(mktemp)"; then
        echo "✗ 无法创建 crontab 临时文件，未作修改"
        release_root_crontab_lock
        return 1
    fi
    chmod 600 "$crontab_tmp" 2>/dev/null || true
    if ! awk -v script="$SCRIPT_PATH" 'index($0, script) == 0 { print }' \
        <<< "$current_crontab" > "$crontab_tmp"; then
        rm -f "$crontab_tmp"
        echo "✗ 生成 crontab 候选内容失败，未作修改"
        release_root_crontab_lock
        return 1
    fi
    if ! crontab "$crontab_tmp" 2>/dev/null; then
        rm -f "$crontab_tmp"
        echo "✗ 定时任务移除失败"
        release_root_crontab_lock
        return 1
    fi
    rm -f "$crontab_tmp"

    release_root_crontab_lock
    echo "✓ 定时任务已移除"
}

# 添加定时任务
add_cron_job() {
    local current_crontab cron_entry crontab_tmp

    echo "添加定时任务..."

    if ! acquire_root_crontab_lock; then
        echo "✗ 无法取得 TrafficCop-Lite crontab 锁，未作修改"
        return 1
    fi
    if ! current_crontab="$(read_current_crontab)"; then
        echo "✗ 读取当前定时任务失败，未作修改"
        release_root_crontab_lock
        return 1
    fi
    cron_entry="* * * * * $SCRIPT_PATH --run >/dev/null 2>&1 $CRON_COMMENT"
    if ! crontab_tmp="$(mktemp)"; then
        echo "✗ 无法创建 crontab 临时文件，未作修改"
        release_root_crontab_lock
        return 1
    fi
    chmod 600 "$crontab_tmp" 2>/dev/null || true
    if ! awk -v script="$SCRIPT_PATH" '
        index($0, script) == 0 && $0 !~ /^[[:space:]]*$/ { print }
    ' <<< "$current_crontab" > "$crontab_tmp" \
        || ! printf '%s\n' "$cron_entry" >> "$crontab_tmp"; then
        rm -f "$crontab_tmp"
        echo "✗ 生成 crontab 候选内容失败，未作修改"
        release_root_crontab_lock
        return 1
    fi
    if ! crontab "$crontab_tmp"; then
        rm -f "$crontab_tmp"
        echo "✗ 定时任务添加失败"
        release_root_crontab_lock
        return 1
    fi
    rm -f "$crontab_tmp"

    release_root_crontab_lock
    echo "✓ 定时任务已添加"
}

# 完全禁用机器限速
disable_machine_limit() {
    local has_error=false config_tmp had_owned_shutdown=false

    echo -e "${YELLOW}==================== 禁用机器限速 ====================${NC}"
    echo ""
    
    # 1. 先阻止新任务，再等待正在运行的监控退出。
    remove_cron_job || has_error=true
    stop_monitor_process
    if ! $has_error; then
        if acquire_monitor_cleanup_lock; then
            stop_monitor_process
            clear_tc_rules || has_error=true
            release_monitor_cleanup_lock
        else
            echo "✗ 无法取得监控锁，未清理 TC 规则"
            has_error=true
        fi
    fi
    
    # 2. 备份并标记配置文件
    if [ -f "$CONFIG_FILE" ]; then
        if grep -q '^DISABLED=true$' "$CONFIG_FILE" 2>/dev/null; then
            echo "✓ 配置已经处于禁用状态，保留原备份"
        else
            echo "备份当前配置..."
            config_tmp="${CONFIG_FILE}.tmp.$$"
            if cp "$CONFIG_FILE" "$BACKUP_CONFIG_FILE" \
                && grep -v -E '^(DISABLED|DISABLED_TIME)=' "$CONFIG_FILE" > "$config_tmp" \
                && { printf 'DISABLED=true\n'; printf 'DISABLED_TIME=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"; } >> "$config_tmp"; then
                chmod 600 "$BACKUP_CONFIG_FILE" "$config_tmp" 2>/dev/null || true
                if mv -f "$config_tmp" "$CONFIG_FILE"; then
                    echo "✓ 配置已备份并标记为禁用"
                else
                    rm -f "$config_tmp"
                    echo "✗ 配置禁用标记写入失败"
                    has_error=true
                fi
            else
                rm -f "$config_tmp"
                echo "✗ 配置备份或禁用标记写入失败"
                has_error=true
            fi
        fi
    fi
    
    # 3. 取消可能的关机计划并清理执行控制状态
    [ -f "$SHUTDOWN_STATE_FILE" ] && had_owned_shutdown=true
    if ! cancel_owned_shutdown; then
        has_error=true
    fi
    rm -f "$ENFORCEMENT_STATE_FILE"
    if ! $had_owned_shutdown && grep -q "LIMIT_MODE=shutdown" "$CONFIG_FILE" 2>/dev/null; then
        read -r -p "检测到关机模式配置，是否取消当前系统计划关机？[y/N]: " cancel_shutdown
        if [[ $cancel_shutdown =~ ^[Yy]$ ]]; then
            if ! shutdown -c 2>/dev/null; then
                echo "✗ 取消关机计划失败，请先手动确认系统关机任务"
                has_error=true
            elif has_pending_shutdown; then
                echo "✗ 取消命令执行后仍检测到关机计划，请先手动处理"
                has_error=true
            else
                echo "✓ 已取消关机计划"
            fi
        fi
    fi
    
    echo ""
    if $has_error; then
        echo -e "${RED}机器监控已禁用，但部分清理操作失败；状态文件已保留，请查看上方错误。${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ 机器限速已完全禁用${NC}"
    echo -e "${CYAN}说明: 原配置已备份，可随时恢复${NC}"
}

rollback_enable_machine_limit() {
    local config_backup="$1"
    local enforcement_backup="$2"
    local had_enforcement="$3"
    local activation_from_disabled="$4"
    local config_tmp="${CONFIG_FILE}.enable-rollback.$$"
    local enforcement_tmp="${ENFORCEMENT_STATE_FILE}.enable-rollback.$$"
    local rollback_failed=false

    if ! cp -p "$config_backup" "$config_tmp" 2>/dev/null ||
       ! chmod 600 "$config_tmp" 2>/dev/null ||
       ! mv -f "$config_tmp" "$CONFIG_FILE"; then
        rm -f "$config_tmp"
        rollback_failed=true
    fi

    if [ "${ENABLE_TC_CLEAR_ATTEMPTED:-false}" = "true" ] &&
       [ "$activation_from_disabled" = "true" ]; then
        rm -f "$ENFORCEMENT_STATE_FILE" || rollback_failed=true
    elif [ "$had_enforcement" = "true" ]; then
        if ! cp -p "$enforcement_backup" "$enforcement_tmp" 2>/dev/null ||
           ! chmod 600 "$enforcement_tmp" 2>/dev/null ||
           ! mv -f "$enforcement_tmp" "$ENFORCEMENT_STATE_FILE"; then
            rm -f "$enforcement_tmp"
            rollback_failed=true
        fi
    elif ! rm -f "$ENFORCEMENT_STATE_FILE"; then
        rollback_failed=true
    fi

    # 启用失败采用 fail-open：恢复配置/执行控制，但不重新施加刚撤销的旧限速。
    # 这样即使原限速状态异常，也不会在失败回滚时再次锁住网络。
    if [ "${ENABLE_TC_CLEAR_ATTEMPTED:-false}" = "true" ]; then
        clear_tc_rules_with_lock >/dev/null 2>&1 || rollback_failed=true
    fi

    if $rollback_failed; then
        return 1
    fi
    rm -f "$config_backup" "$enforcement_backup"
}

# 启用机器限速
enable_machine_limit() {
    local enable_backup="$CONFIG_FILE.enable-backup.$$"
    local enforcement_backup="$ENFORCEMENT_STATE_FILE.enable-backup.$$"
    local config_tmp="${CONFIG_FILE}.tmp.$$"
    local had_enforcement=false
    local activation_from_disabled=false

    if [ "${1:-}" = "--from-disabled-restore" ]; then
        activation_from_disabled=true
    fi

    echo -e "${YELLOW}==================== 启用机器限速 ====================${NC}"
    echo ""
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}错误: 未找到配置文件 $CONFIG_FILE${NC}"
        echo "请先运行 trafficcop-lite-monitor.sh 进行初始配置"
        return 1
    fi
    
    cp "$CONFIG_FILE" "$enable_backup" || return 1
    chmod 600 "$enable_backup" 2>/dev/null || true
    if grep -q '^DISABLED=true$' "$CONFIG_FILE" 2>/dev/null; then
        activation_from_disabled=true
    fi
    if [ -f "$ENFORCEMENT_STATE_FILE" ]; then
        if ! cp -p "$ENFORCEMENT_STATE_FILE" "$enforcement_backup"; then
            rm -f "$enable_backup"
            return 1
        fi
        chmod 600 "$enforcement_backup" 2>/dev/null || true
        had_enforcement=true
    fi

    # 1. 先保留当前禁用标记建立安全窗口。监控脚本据此可识别并清理
    # “父类已由 Dog 恢复、但 NTC 状态文件仍残留”的禁用态收尾场景。
    if ! begin_enable_grace 10; then
        if rollback_enable_machine_limit "$enable_backup" "$enforcement_backup" \
            "$had_enforcement" "$activation_from_disabled"; then
            if [ "${ENABLE_TC_CLEAR_ATTEMPTED:-false}" = "true" ]; then
                echo -e "${RED}无法建立无旧限速的启用宽限；配置/执行控制已恢复，旧 TC 限速保持撤销。${NC}"
            else
                echo -e "${RED}无法建立启用宽限；原配置、执行控制和 TC 均保持不变。${NC}"
            fi
        else
            echo -e "${RED}无法建立启用宽限，且回滚不完整；备份已保留，请立即检查。${NC}"
        fi
        return 1
    fi
    echo "✓ 已设置 10 分钟启用宽限，期间只统计流量"

    # 2. 旧 TC/关机状态已撤销后，再恢复配置文件（移除 DISABLED 标记）。
    if grep -q '^DISABLED=true$' "$CONFIG_FILE" 2>/dev/null; then
        echo "恢复配置文件..."
        if ! grep -v -E '^(DISABLED|DISABLED_TIME)=' "$CONFIG_FILE" > "$config_tmp" \
            || ! chmod 600 "$config_tmp" 2>/dev/null \
            || ! mv -f "$config_tmp" "$CONFIG_FILE"; then
            rm -f "$config_tmp"
            if rollback_enable_machine_limit "$enable_backup" "$enforcement_backup" \
                "$had_enforcement" "$activation_from_disabled"; then
                echo -e "${RED}配置文件恢复失败；原配置/执行控制已恢复，旧 TC 限速保持撤销。${NC}"
            else
                echo -e "${RED}配置文件恢复失败且回滚不完整；备份已保留，请立即检查。${NC}"
            fi
            return 1
        fi
        chmod 600 "$CONFIG_FILE" 2>/dev/null || true
        echo "✓ 配置文件已恢复"
    fi

    echo "启动TrafficCop监控测试..."
    if ! cd "$WORK_DIR" || ! bash "$SCRIPT_PATH" --run; then
        if rollback_enable_machine_limit "$enable_backup" "$enforcement_backup" \
            "$had_enforcement" "$activation_from_disabled"; then
            echo -e "${RED}监控测试失败；配置/执行控制已恢复，旧 TC 限速出于安全未恢复，且未添加定时任务。${NC}"
        else
            echo -e "${RED}监控测试失败且回滚不完整；备份已保留，请立即检查。${NC}"
        fi
        return 1
    fi

    # 3. 测试成功后再添加定时任务
    if ! add_cron_job; then
        if rollback_enable_machine_limit "$enable_backup" "$enforcement_backup" \
            "$had_enforcement" "$activation_from_disabled"; then
            echo -e "${RED}定时任务添加失败；配置/执行控制已恢复，旧 TC 限速出于安全未恢复。${NC}"
        else
            echo -e "${RED}定时任务添加失败且回滚不完整；备份已保留，请立即检查。${NC}"
        fi
        return 1
    fi
    rm -f "$enable_backup" "$enforcement_backup"
    
    echo ""
    echo -e "${GREEN}✓ 机器限速已启用${NC}"
    echo -e "${CYAN}监控将通过定时任务每分钟执行一次${NC}"
    echo -e "${CYAN}刚才已执行一次测试，可在日志中查看结果${NC}"
}

# 恢复之前的配置
restore_machine_limit() {
    local restore_tmp="${CONFIG_FILE}.tmp.$$"
    local rollback_file="${CONFIG_FILE}.restore-backup.$$"
    local had_config=false
    local operation_from_disabled=false
    echo -e "${YELLOW}==================== 恢复机器限速 ====================${NC}"
    echo ""
    
    if [ ! -f "$BACKUP_CONFIG_FILE" ]; then
        echo -e "${RED}错误: 未找到备份配置文件${NC}"
        echo "无法恢复，请手动重新配置"
        return 1
    fi

    if [ -f "$CONFIG_FILE" ]; then
        grep -q '^DISABLED=true$' "$CONFIG_FILE" 2>/dev/null && operation_from_disabled=true
        if ! cp "$CONFIG_FILE" "$rollback_file" || ! chmod 600 "$rollback_file" 2>/dev/null; then
            rm -f "$rollback_file"
            echo -e "${RED}无法备份当前配置，未执行恢复。${NC}"
            return 1
        fi
        had_config=true
    fi
    
    # 恢复配置文件
    echo "恢复备份配置..."
    if ! cp "$BACKUP_CONFIG_FILE" "$restore_tmp" || ! chmod 600 "$restore_tmp" 2>/dev/null || ! mv -f "$restore_tmp" "$CONFIG_FILE"; then
        rm -f "$restore_tmp"
        rm -f "$rollback_file"
        echo -e "${RED}配置恢复失败，未启动监控。${NC}"
        return 1
    fi
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    echo "✓ 配置已恢复"
    
    # 启用监控
    if { $operation_from_disabled && enable_machine_limit --from-disabled-restore; } ||
       { ! $operation_from_disabled && enable_machine_limit; }; then
        rm -f "$rollback_file"
        return 0
    fi

    if $had_config; then
        if mv -f "$rollback_file" "$CONFIG_FILE"; then
            chmod 600 "$CONFIG_FILE" 2>/dev/null || true
            echo -e "${YELLOW}启用失败，已恢复操作前配置。${NC}"
        else
            echo -e "${RED}启用失败且操作前配置回滚失败，备份保留在 $rollback_file。${NC}"
        fi
    elif rm -f "$CONFIG_FILE"; then
        echo -e "${YELLOW}启用失败，已移除本次恢复的配置。${NC}"
    else
        echo -e "${RED}启用失败且无法移除本次恢复的配置，请手动检查 $CONFIG_FILE。${NC}"
    fi
    return 1
}

manage_enforcement_control() {
    local control_choice grace_minutes until_epoch config_tmp

    echo -e "${CYAN}==================== 限制执行控制 ====================${NC}"
    echo "流量统计和 cron 可保持运行；这里仅控制达到阈值后是否真正限速或关机。"
    echo ""
    echo "1) 恢复执行（TC 仍遵守配置的开机宽限）"
    echo "2) 宽限一段时间"
    echo "3) 暂停执行（仅监控）"
    echo "4) 修改 TC 开机宽限"
    echo "0) 返回"
    read -r -p "请选择 [0-4]: " control_choice
    case "$control_choice" in
        1)
            cancel_owned_shutdown || return 1
            rm -f "$ENFORCEMENT_STATE_FILE"
            echo "✓ 已恢复限制执行；下次监控达到阈值时将按配置处理"
            ;;
        2|3)
            if ! acquire_monitor_cleanup_lock; then
                echo "✗ 无法取得监控锁，未修改执行状态"
                return 1
            fi
            if ! clear_tc_rules; then
                release_monitor_cleanup_lock
                echo "✗ 无法安全清理当前 TC 规则，未修改执行状态"
                return 1
            fi
            if ! cancel_owned_shutdown; then
                release_monitor_cleanup_lock
                return 1
            fi
            if [ "$control_choice" = "2" ]; then
                read -r -p "请输入宽限分钟数 (1-1440，默认为10): " grace_minutes
                grace_minutes=${grace_minutes:-10}
                if ! [[ "$grace_minutes" =~ ^[0-9]+$ ]] || [ "$grace_minutes" -lt 1 ] || [ "$grace_minutes" -gt 1440 ]; then
                    echo "输入无效，使用默认值：10 分钟"
                    grace_minutes=10
                fi
                until_epoch=$(( $(date +%s) + grace_minutes * 60 ))
                write_enforcement_state "grace" "$until_epoch" "manual" || {
                    release_monitor_cleanup_lock
                    return 1
                }
                echo "✓ 已设置 $grace_minutes 分钟宽限"
            else
                write_enforcement_state "paused" "0" "manual" || {
                    release_monitor_cleanup_lock
                    return 1
                }
                echo "✓ 已暂停限制执行；流量统计仍会继续"
            fi
            release_monitor_cleanup_lock
            ;;
        4)
            if ! grep -q '^LIMIT_MODE=tc$' "$CONFIG_FILE" 2>/dev/null; then
                echo "当前不是 TC 限速模式，无需设置开机限速宽限。"
                return 1
            fi
            read -r -p "请输入开机后宽限分钟数 (0=立即，0-1440，默认为10): " grace_minutes
            grace_minutes=${grace_minutes:-10}
            if ! [[ "$grace_minutes" =~ ^[0-9]+$ ]] || [ "$grace_minutes" -gt 1440 ]; then
                echo "输入无效，未修改。"
                return 1
            fi
            config_tmp="${CONFIG_FILE}.tmp.$$"
            if ! awk -v value="$grace_minutes" '
                BEGIN { updated=0 }
                /^TC_BOOT_GRACE_MINUTES=/ { print "TC_BOOT_GRACE_MINUTES=" value; updated=1; next }
                { print }
                END { if (!updated) print "TC_BOOT_GRACE_MINUTES=" value }
            ' "$CONFIG_FILE" > "$config_tmp" \
                || ! chmod 600 "$config_tmp" 2>/dev/null \
                || ! mv -f "$config_tmp" "$CONFIG_FILE"; then
                rm -f "$config_tmp"
                echo "TC 开机宽限更新失败。"
                return 1
            fi
            echo "✓ TC 开机宽限已更新为 $grace_minutes 分钟"
            ;;
        0) return 0 ;;
        *) echo "无效选择"; return 1 ;;
    esac
}

show_monitor_task_status() {
    local log_file="$WORK_DIR/traffic_monitor.log"
    local last_run last_run_timestamp current_timestamp time_diff

    last_run=$(grep ' 正在以自动化模式运行$' "$log_file" 2>/dev/null | tail -n 1 | awk '{print $1, $2}')
    if [ -z "$last_run" ] ||
       ! last_run_timestamp=$(date -d "$last_run" +%s 2>/dev/null); then
        echo -e "监控任务: ${YELLOW}尚无执行记录${NC}"
        return
    fi

    current_timestamp=$(date +%s)
    time_diff=$((current_timestamp - last_run_timestamp))
    if [ "$time_diff" -lt 600 ]; then
        echo -e "监控任务: ${GREEN}最近已执行${NC} (最后执行: $last_run)"
    else
        echo -e "监控任务: ${YELLOW}空闲中${NC} (最后执行: $last_run)"
    fi
}

# 查看当前状态
show_status() {
    local disabled_time
    local enforcement_mode enforcement_until enforcement_reason remaining boot_grace
    local config_disabled=false

    echo -e "${CYAN}==================== 当前状态 ====================${NC}"
    echo ""
    
    # 检查配置文件
    if [ -f "$CONFIG_FILE" ]; then
        if grep -q '^DISABLED=true$' "$CONFIG_FILE" 2>/dev/null; then
            config_disabled=true
            disabled_time=$(grep '^DISABLED_TIME=' "$CONFIG_FILE" | tail -n 1 | cut -d'=' -f2-)
            echo -e "配置状态: ${RED}已禁用${NC} (禁用时间: $disabled_time)"
        else
            echo -e "配置状态: ${GREEN}已启用${NC}"
        fi
    else
        echo -e "配置状态: ${YELLOW}未配置${NC}"
    fi

    enforcement_mode=$(enforcement_state_value "MODE")
    enforcement_until=$(enforcement_state_value "UNTIL_EPOCH")
    enforcement_reason=$(enforcement_state_value "REASON")
    if $config_disabled; then
        echo -e "限制执行: ${RED}已禁用${NC}"
    elif [ "$enforcement_mode" = "paused" ]; then
        if [ "$enforcement_reason" = "shutdown_reboot" ]; then
            echo -e "限制执行: ${RED}关机后重启保护，已暂停${NC}"
        else
            echo -e "限制执行: ${YELLOW}已暂停，仅监控${NC}"
        fi
    elif [ "$enforcement_mode" = "grace" ] && [[ "$enforcement_until" =~ ^[0-9]+$ ]] \
        && [ "$enforcement_until" -gt "$(date +%s)" ]; then
        remaining=$(( (enforcement_until - $(date +%s) + 59) / 60 ))
        echo -e "限制执行: ${YELLOW}宽限中，约剩余 $remaining 分钟${NC}"
    else
        echo -e "限制执行: ${GREEN}正常${NC}"
    fi
    boot_grace=$(grep '^TC_BOOT_GRACE_MINUTES=' "$CONFIG_FILE" 2>/dev/null | tail -1 | cut -d'=' -f2-)
    if [ -n "$boot_grace" ]; then
        echo "TC 开机宽限: $boot_grace 分钟"
    fi
    
    # 这里只报告最近一次 cron/--run 任务，不把普通日志写入误称为实时进程。
    show_monitor_task_status
    
    # 检查定时任务
    if read_root_crontab_locked 2>/dev/null | grep -F -q "$SCRIPT_PATH"; then
        echo -e "定时任务: ${GREEN}已设置${NC}"
    else
        echo -e "定时任务: ${RED}未设置${NC}"
    fi
    
    # 检查TC规则
    local interface state_interface qdisc_line state_qdisc_line state_speed state_schema state_provider class_output query_status
    interface=$(get_main_interface)
    state_interface="$(tc_state_value "INTERFACE")"
    if [ -z "$TC_BIN" ]; then
        echo -e "TC限速: ${YELLOW}无法检测（未找到 tc）${NC}"
    elif [ -n "$state_interface" ]; then
        qdisc_line="$(tc_root_qdisc "$state_interface")"
        query_status=$?
        if [ "$query_status" -eq 2 ]; then
            echo -e "TC限速: ${YELLOW}无法检测（tc 查询失败）${NC}"
        else
            [ "$query_status" -eq 0 ] || qdisc_line=""
            state_schema="$(tc_state_value SCHEMA)"
            state_provider="$(tc_state_value PROVIDER)"
            state_speed="$(tc_state_value LIMIT_SPEED)"
            if [ "$state_schema" = "$TC_STATE_SCHEMA" ] && [ "$state_provider" = "$TC_STATE_PROVIDER" ]; then
                class_output="$(tc_class_output "$state_interface")"
                query_status=$?
                if [ "$query_status" -eq 2 ]; then
                    echo -e "TC限速: ${YELLOW}无法检测（tc 查询失败）${NC}"
                elif echo "$qdisc_line" | grep -Eq '^qdisc htb 1:([[:space:]]|$)' &&
                     printf '%s\n' "$class_output" | grep -Eq '^class htb 1:1([[:space:]]|$)' &&
                     printf '%s\n' "$class_output" | grep -Eq '^class htb 1:30([[:space:]]|$)'; then
                    echo -e "TC限速: ${YELLOW}统一 HTB 已激活（整机 ${state_speed} kbit/s）${NC}"
                else
                    echo -e "TC限速: ${YELLOW}统一 HTB 状态与当前层级不一致，请运行 ntc --tc-self-check${NC}"
                fi
            elif echo "$qdisc_line" | grep -q " tbf "; then
                state_qdisc_line="$(tc_state_value "QDISC_LINE")"
                if { [ -n "$state_qdisc_line" ] && [ "$qdisc_line" = "$state_qdisc_line" ]; } \
                    || { [ -z "$state_qdisc_line" ] && [[ "$state_speed" =~ ^[0-9]+$ ]] && echo "$qdisc_line" | grep -Eq "rate[[:space:]]+${state_speed}[Kk]bit"; }; then
                    echo -e "TC限速: ${YELLOW}已激活（本脚本）${NC}"
                else
                    echo -e "TC限速: ${YELLOW}状态记录与当前 tbf 不一致（按外部规则保留）${NC}"
                fi
            else
                echo -e "TC限速: ${YELLOW}状态标记存在，但当前未检测到 tbf${NC}"
            fi
        fi
    elif [ -f "$TC_STATE_FILE" ]; then
        echo -e "TC限速: ${YELLOW}状态标记无效（未记录接口）${NC}"
    elif [ -n "$interface" ]; then
        qdisc_line="$(tc_root_qdisc "$interface")"
        query_status=$?
        if [ "$query_status" -eq 2 ]; then
            echo -e "TC限速: ${YELLOW}无法检测（tc 查询失败）${NC}"
        elif echo "$qdisc_line" | grep -q " tbf "; then
            echo -e "TC限速: ${YELLOW}检测到外部 tbf（非本脚本）${NC}"
        elif echo "$qdisc_line" | grep -Eq '^qdisc htb 1:([[:space:]]|$)'; then
            echo -e "TC限速: ${GREEN}检测到统一 HTB，TrafficCop 当前未施加整机上限${NC}"
        else
            echo -e "TC限速: ${GREEN}未激活${NC}"
        fi
    else
        echo -e "TC限速: ${GREEN}未激活${NC}"
    fi
    
    # 检查备份
    if [ -f "$BACKUP_CONFIG_FILE" ]; then
        echo -e "配置备份: ${GREEN}存在${NC}"
    else
        echo -e "配置备份: ${YELLOW}不存在${NC}"
    fi
}

# 详细状态检查
machine_vnstat_cmd() {
    local config_path=""
    config_path=$(cat "$VNSTAT_CONFIG_PATH_FILE" 2>/dev/null || true)
    if [ -n "$config_path" ] && [ "${config_path#/}" != "$config_path" ] && [ -f "$config_path" ]; then
        vnstat --config "$config_path" "$@"
    else
        vnstat "$@"
    fi
}

machine_vnstat_config_value() {
    local target="$1"
    machine_vnstat_cmd --showconfig 2>/dev/null | awk -v target="$target" '
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

machine_vnstat_daemon_is_running() {
    local comm_file
    for comm_file in /proc/[0-9]*/comm; do
        [ -r "$comm_file" ] || continue
        [ "$(cat "$comm_file" 2>/dev/null)" = "vnstatd" ] && return 0
    done
    return 1
}

machine_normalize_vnstat_json_for_interface() {
    local vnstat_json="$1"
    local expected_interface="$2"

    [[ "$expected_interface" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || return 1
    printf '%s' "$vnstat_json" | jq -ce --arg expected "$expected_interface" '
        def uint: type == "number" and . >= 0 and floor == .;
        def leap_year($year):
            ($year % 400 == 0) or (($year % 4 == 0) and ($year % 100 != 0));
        def month_days($year; $month):
            if $month == 2 then (if leap_year($year) then 29 else 28 end)
            elif $month == 4 or $month == 6 or $month == 9 or $month == 11 then 30
            else 31 end;
        def valid_date:
            type == "object" and
            (.year | uint) and .year >= 1970 and .year <= 9999 and
            (.month | uint) and .month >= 1 and .month <= 12 and
            (.day | uint) and .day >= 1 and .day <= month_days(.year; .month);
        select(.jsonversion == "2" or .jsonversion == 2) |
        select((.interfaces | type) == "array") |
        [.interfaces[] | select(.name == $expected)] as $matches |
        select(($matches | length) == 1) |
        $matches[0] as $interface |
        select(($interface | type) == "object") |
        select($interface.created.date | valid_date) |
        select(($interface.updated | type) == "object") |
        select(($interface.traffic | type) == "object") |
        select(($interface.traffic.day | type) == "array") |
        select(all($interface.traffic.day[];
            (.date | valid_date) and (.rx | uint) and (.tx | uint))) |
        {jsonversion: "2", interfaces: [$interface]}
    ' 2>/dev/null
}

machine_vnstat_data_is_fresh() {
    local vnstat_json="$1"
    local updated_epoch updated_text now age save_interval update_interval max_age

    command -v jq >/dev/null 2>&1 || return 1
    machine_vnstat_daemon_is_running || return 1
    updated_epoch=$(printf '%s' "$vnstat_json" |
        jq -r '.interfaces[0].updated.timestamp // empty' 2>/dev/null) || return 1
    if ! [[ "$updated_epoch" =~ ^[0-9]+$ ]]; then
        updated_text=$(printf '%s' "$vnstat_json" | jq -r '
            .interfaces[0].updated as $u |
            if ($u.date.year == null or $u.date.month == null or $u.date.day == null or
                $u.time.hour == null or $u.time.minute == null) then empty
            else "\($u.date.year)-\($u.date.month)-\($u.date.day) \($u.time.hour):\($u.time.minute):\($u.time.second // 0)" end
        ' 2>/dev/null) || return 1
        [ -n "$updated_text" ] || return 1
        if [ "$(machine_vnstat_config_value "UseUTC")" = "1" ]; then
            updated_epoch=$(TZ=UTC date -d "$updated_text" +%s 2>/dev/null) || return 1
        else
            updated_epoch=$(date -d "$updated_text" +%s 2>/dev/null) || return 1
        fi
    fi
    now=$(date +%s) || return 1
    save_interval=$(machine_vnstat_config_value "SaveInterval")
    update_interval=$(machine_vnstat_config_value "UpdateInterval")
    [[ "$save_interval" =~ ^[1-9][0-9]*$ && "$update_interval" =~ ^[1-9][0-9]*$ ]] || return 1
    max_age=$((save_interval * 60 + update_interval + 90))
    age=$((now - updated_epoch))
    [ "$age" -ge -300 ] && [ "$age" -le "$max_age" ]
}

show_detailed_status() {
    echo -e "${CYAN}==================== 详细状态 ====================${NC}"
    echo ""
    
    # 基本状态
    show_status
    echo ""
    
    # 检查配置文件内容
    echo -e "${CYAN}配置文件内容:${NC}"
    if [ -f "$CONFIG_FILE" ]; then
        cat "$CONFIG_FILE"
    else
        echo -e "${RED}配置文件不存在${NC}"
    fi
    echo ""
    
    # 检查定时任务详情
    echo -e "${CYAN}定时任务详情:${NC}"
    read_root_crontab_locked 2>/dev/null | grep -v "^#" | grep -F "$WORK_DIR" || echo "无相关定时任务"
    echo ""
    
    # 检查最近的日志
    echo -e "${CYAN}最近的监控日志 (最后10行):${NC}"
    if [ -f "$WORK_DIR/traffic_monitor.log" ]; then
        tail -10 "$WORK_DIR/traffic_monitor.log"
    else
        echo "日志文件不存在"
    fi
    echo ""
    
    # 检查当前流量使用
    echo -e "${CYAN}当前流量统计:${NC}"
    if command -v vnstat >/dev/null 2>&1; then
        local interface vnstat_json
        interface=$(get_main_interface)
        if [ -n "$interface" ]; then
            vnstat_json=$(machine_vnstat_cmd -i "$interface" --json 2>/dev/null || true)
            if [ -n "$vnstat_json" ] &&
               vnstat_json=$(machine_normalize_vnstat_json_for_interface "$vnstat_json" "$interface") &&
               machine_vnstat_data_is_fresh "$vnstat_json"; then
                machine_vnstat_cmd -i "$interface" --oneline 2>/dev/null | head -1 || echo "无法获取流量统计"
            else
                echo "vnStat 守护进程未运行或数据库数据已过期"
            fi
        else
            echo "无法检测网络接口"
        fi
    else
        echo "vnstat 未安装"
    fi
}

# 主菜单
show_menu() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        TrafficCop 机器限速管理         ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo ""
    show_status
    echo ""
    echo "选择操作:"
    echo "1) 禁用机器限速 (完全停止监控)"
    echo "2) 启用机器限速 (恢复监控)"
    echo "3) 恢复之前配置 (从备份恢复)"
    echo "4) 查看详细状态"
    echo "5) 清除TC限速规则 (仅清除当前限速)"
    echo "6) 限制执行控制 (立即/宽限/暂停)"
    echo "0) 退出"
    echo ""
}

# 主程序
main() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}请使用 root 权限运行此脚本。${NC}"
        exit 1
    fi

    # 创建工作目录
    mkdir -p "$WORK_DIR"
    chmod 700 "$WORK_DIR" 2>/dev/null || true
    
    if [ "$1" = "--disable" ]; then
        disable_machine_limit
        exit $?
    elif [ "$1" = "--enable" ]; then
        enable_machine_limit
        exit $?
    elif [ "$1" = "--status" ]; then
        show_status
        exit 0
    fi
    
    while true; do
        show_menu
        if ! read -r -p "请选择 [0-6]: " choice; then
            echo ""
            echo "输入已结束，退出"
            exit 0
        fi
        
        case $choice in
            1)
                echo ""
                read -r -p "确认禁用机器限速？这将停止所有监控 [y/N]: " confirm
                if [[ $confirm =~ ^[Yy]$ ]]; then
                    disable_machine_limit
                    read -r -p "按回车键继续..."
                fi
                ;;
            2)
                echo ""
                enable_machine_limit
                read -r -p "按回车键继续..."
                ;;
            3)
                echo ""
                restore_machine_limit
                read -r -p "按回车键继续..."
                ;;
            4)
                echo ""
                show_detailed_status
                read -r -p "按回车键继续..."
                ;;
            5)
                echo ""
                clear_tc_rules_with_lock
                read -r -p "按回车键继续..."
                ;;
            6)
                echo ""
                manage_enforcement_control
                read -r -p "按回车键继续..."
                ;;
            0)
                echo "退出"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择${NC}"
                sleep 1
                ;;
        esac
    done
}

main "$@"
