#!/bin/bash

# TrafficCop 机器限速管理脚本 v2.1
# 提供完整的启用/禁用/恢复机器限速功能

WORK_DIR="/etc/trafficcop-lite"
CONFIG_FILE="$WORK_DIR/traffic_monitor_config.txt"
BACKUP_CONFIG_FILE="$CONFIG_FILE.disabled.backup"
SCRIPT_PATH="$WORK_DIR/trafficcop-lite-monitor.sh"
TC_STATE_FILE="$WORK_DIR/tc_limit_state"
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

tc_state_value() {
    local key="$1"
    if [ -f "$TC_STATE_FILE" ]; then
        grep "^${key}=" "$TC_STATE_FILE" 2>/dev/null | tail -n 1 | cut -d'=' -f2-
    fi
}

tc_root_qdisc() {
    local interface="$1"
    if [ -n "$TC_BIN" ] && [ -n "$interface" ]; then
        "$TC_BIN" qdisc show dev "$interface" root 2>/dev/null | head -n 1
    fi
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
    if [ -f "$CONFIG_FILE" ]; then
        chmod 600 "$CONFIG_FILE" 2>/dev/null || true
        . "$CONFIG_FILE" 2>/dev/null || true
        if [ -n "$MAIN_INTERFACE" ]; then
            echo "$MAIN_INTERFACE"
            return
        fi
    fi
    ip route | grep default | awk '{print $5}' | head -n1
}

# 清除TC限速规则
clear_tc_rules() {
    local interface state_interface qdisc_line state_qdisc_line state_speed

    interface=$(get_main_interface)
    if [ -z "$TC_BIN" ]; then
        echo "未找到系统 tc 命令，跳过TC规则清理"
        [ -f "$TC_STATE_FILE" ] && return 1
        return 0
    fi

    if [ -f "$TC_STATE_FILE" ]; then
        state_interface="$(tc_state_value "INTERFACE")"
        if [ -z "$state_interface" ]; then
            rm -f "$TC_STATE_FILE"
            echo "✓ TC状态文件无效，已清理状态文件"
            return
        fi

        qdisc_line="$(tc_root_qdisc "$state_interface")"
        if echo "$qdisc_line" | grep -q " tbf "; then
            state_qdisc_line="$(tc_state_value "QDISC_LINE")"
            state_speed="$(tc_state_value "LIMIT_SPEED")"
            if [ -n "$state_qdisc_line" ] && [ "$qdisc_line" != "$state_qdisc_line" ]; then
                echo "检测到当前 tbf 与本脚本状态记录不一致，已保留现有规则并清理状态标记。"
                rm -f "$TC_STATE_FILE"
                return
            fi
            if [ -z "$state_qdisc_line" ]; then
                if ! echo "$state_speed" | grep -Eq '^[0-9]+$'; then
                    echo "检测到旧状态记录缺失限速速率，已保留现有规则并清理状态标记。"
                    rm -f "$TC_STATE_FILE"
                    return
                fi
                if ! echo "$qdisc_line" | grep -Eq "rate[[:space:]]+${state_speed}[Kk]bit"; then
                    echo "检测到当前 tbf 速率与旧状态记录不一致，已保留现有规则并清理状态标记。"
                    rm -f "$TC_STATE_FILE"
                    return
                fi
            fi
            echo "清除本脚本在网络接口 $state_interface 上应用的TC限速规则..."
            if "$TC_BIN" qdisc del dev "$state_interface" root 2>/dev/null; then
                echo "✓ 本脚本TC限速规则已清除"
            else
                qdisc_line="$(tc_root_qdisc "$state_interface")"
                if echo "$qdisc_line" | grep -q " tbf "; then
                    echo "✗ TC限速规则清除失败，已保留状态文件以便重试"
                    return 1
                fi
                echo "✓ 接口已不存在 tbf 限速规则"
            fi
        else
            echo "✓ 接口 $state_interface 当前没有 tbf 限速规则"
        fi
        rm -f "$TC_STATE_FILE"
    elif [ -n "$interface" ] && "$TC_BIN" qdisc show dev "$interface" root 2>/dev/null | grep -q " tbf "; then
        echo "检测到网络接口 $interface 存在 tbf 规则，但没有本脚本状态标记。"
        echo "为避免误删系统原有限速，已保留该 TC 规则。"
    else
        echo "✓ 未发现需要清除的TC限速规则"
    fi
}

# 停止监控进程
stop_monitor_process() {
    echo "停止TrafficCop监控进程..."
    
    # 杀死相关进程
    pkill -f "$SCRIPT_PATH" 2>/dev/null || true
    
    echo "✓ 监控进程已停止"
}

# 移除定时任务
remove_cron_job() {
    local current_crontab new_crontab

    echo "移除定时任务..."

    current_crontab="$(crontab -l 2>/dev/null || true)"
    new_crontab="$(printf '%s\n' "$current_crontab" | grep -v -F "$SCRIPT_PATH" || true)"
    if ! printf '%s\n' "$new_crontab" | crontab - 2>/dev/null; then
        echo "✗ 定时任务移除失败"
        return 1
    fi

    echo "✓ 定时任务已移除"
}

# 添加定时任务
add_cron_job() {
    local current_crontab new_crontab cron_entry

    echo "添加定时任务..."

    current_crontab="$(crontab -l 2>/dev/null || true)"
    new_crontab="$(printf '%s\n' "$current_crontab" | grep -v -F "$SCRIPT_PATH" || true)"
    cron_entry="* * * * * $SCRIPT_PATH --run $CRON_COMMENT"
    if ! { printf '%s\n' "$new_crontab"; printf '%s\n' "$cron_entry"; } | sed '/^[[:space:]]*$/d' | crontab -; then
        echo "✗ 定时任务添加失败"
        return 1
    fi

    echo "✓ 定时任务已添加"
}

# 完全禁用机器限速
disable_machine_limit() {
    local has_error=false

    echo -e "${YELLOW}==================== 禁用机器限速 ====================${NC}"
    echo ""
    
    # 1. 停止监控进程
    stop_monitor_process
    
    # 2. 清除TC限速规则
    clear_tc_rules || has_error=true
    
    # 3. 移除定时任务
    remove_cron_job || has_error=true
    
    # 4. 备份并标记配置文件
    if [ -f "$CONFIG_FILE" ]; then
        echo "备份当前配置..."
        cp "$CONFIG_FILE" "$BACKUP_CONFIG_FILE"
        chmod 600 "$BACKUP_CONFIG_FILE" 2>/dev/null || true
        grep -v -E '^(DISABLED|DISABLED_TIME)=' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" || true
        mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        echo "DISABLED=true" >> "$CONFIG_FILE"
        echo "DISABLED_TIME=$(date '+%Y-%m-%d %H:%M:%S')" >> "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE" 2>/dev/null || true
        echo "✓ 配置已备份并标记为禁用"
    fi
    
    # 5. 取消可能的关机计划
    if grep -q "LIMIT_MODE=shutdown" "$CONFIG_FILE" 2>/dev/null; then
        read -r -p "检测到关机模式配置，是否取消当前系统计划关机？[y/N]: " cancel_shutdown
        if [[ $cancel_shutdown =~ ^[Yy]$ ]]; then
            shutdown -c 2>/dev/null || true
            echo "✓ 已尝试取消关机计划"
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

# 启用机器限速
enable_machine_limit() {
    local enable_backup="$CONFIG_FILE.enable-backup.$$"
    local had_tc_state=false

    echo -e "${YELLOW}==================== 启用机器限速 ====================${NC}"
    echo ""
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}错误: 未找到配置文件 $CONFIG_FILE${NC}"
        echo "请先运行 trafficcop-lite-monitor.sh 进行初始配置"
        return 1
    fi
    
    cp "$CONFIG_FILE" "$enable_backup" || return 1
    chmod 600 "$enable_backup" 2>/dev/null || true
    [ -f "$TC_STATE_FILE" ] && had_tc_state=true

    # 1. 恢复配置文件（移除DISABLED标记）
    if grep -q "DISABLED=true" "$CONFIG_FILE" 2>/dev/null; then
        echo "恢复配置文件..."
        grep -v -E '^(DISABLED|DISABLED_TIME)=' "$CONFIG_FILE" > "$CONFIG_FILE.tmp"
        mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE" 2>/dev/null || true
        echo "✓ 配置文件已恢复"
    fi

    # 2. 立即执行一次监控，确认配置和运行环境有效
    echo "启动TrafficCop监控测试..."
    if ! cd "$WORK_DIR" || ! bash "$SCRIPT_PATH" --run; then
        $had_tc_state || clear_tc_rules || true
        cp "$enable_backup" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE" 2>/dev/null || true
        rm -f "$enable_backup"
        echo -e "${RED}监控测试失败，已恢复启用前配置且未添加定时任务。${NC}"
        return 1
    fi

    # 3. 测试成功后再添加定时任务
    if ! add_cron_job; then
        $had_tc_state || clear_tc_rules || true
        cp "$enable_backup" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE" 2>/dev/null || true
        rm -f "$enable_backup"
        echo -e "${RED}定时任务添加失败，已恢复启用前配置。${NC}"
        return 1
    fi
    rm -f "$enable_backup"
    
    echo ""
    echo -e "${GREEN}✓ 机器限速已启用${NC}"
    echo -e "${CYAN}监控将通过定时任务每分钟执行一次${NC}"
    echo -e "${CYAN}刚才已执行一次测试，可在日志中查看结果${NC}"
}

# 恢复之前的配置
restore_machine_limit() {
    echo -e "${YELLOW}==================== 恢复机器限速 ====================${NC}"
    echo ""
    
    if [ ! -f "$BACKUP_CONFIG_FILE" ]; then
        echo -e "${RED}错误: 未找到备份配置文件${NC}"
        echo "无法恢复，请手动重新配置"
        return 1
    fi
    
    # 恢复配置文件
    echo "恢复备份配置..."
    cp "$BACKUP_CONFIG_FILE" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    echo "✓ 配置已恢复"
    
    # 启用监控
    enable_machine_limit
}

# 查看当前状态
show_status() {
    echo -e "${CYAN}==================== 当前状态 ====================${NC}"
    echo ""
    
    # 检查配置文件
    if [ -f "$CONFIG_FILE" ]; then
        if grep -q "DISABLED=true" "$CONFIG_FILE" 2>/dev/null; then
            local disabled_time=$(grep "DISABLED_TIME=" "$CONFIG_FILE" | cut -d'=' -f2)
            echo -e "配置状态: ${RED}已禁用${NC} (禁用时间: $disabled_time)"
        else
            echo -e "配置状态: ${GREEN}已启用${NC}"
        fi
    else
        echo -e "配置状态: ${YELLOW}未配置${NC}"
    fi
    
    # 检查进程状态（检查最近的执行记录而不是实时进程）
    local last_run=$(grep "当前版本" "$WORK_DIR/traffic_monitor.log" 2>/dev/null | tail -1 | awk '{print $1, $2}')
    if [ -n "$last_run" ]; then
        local last_run_timestamp=$(stat -c %Y "$WORK_DIR/traffic_monitor.log" 2>/dev/null || echo "0")
        local current_timestamp=$(date +%s)
        local time_diff=$((current_timestamp - last_run_timestamp))
        
        if [ $time_diff -lt 600 ]; then  # 10分钟内有执行记录
            echo -e "监控进程: ${GREEN}运行中${NC} (最后执行: $last_run)"
        else
            echo -e "监控进程: ${YELLOW}空闲中${NC} (最后执行: $last_run)"
        fi
    else
        echo -e "监控进程: ${RED}未运行${NC}"
    fi
    
    # 检查定时任务
    if crontab -l 2>/dev/null | grep -F -q "$SCRIPT_PATH"; then
        echo -e "定时任务: ${GREEN}已设置${NC}"
    else
        echo -e "定时任务: ${RED}未设置${NC}"
    fi
    
    # 检查TC规则
    local interface state_interface qdisc_line state_qdisc_line state_speed
    interface=$(get_main_interface)
    state_interface="$(tc_state_value "INTERFACE")"
    if [ -z "$TC_BIN" ]; then
        echo -e "TC限速: ${YELLOW}无法检测（未找到 tc）${NC}"
    elif [ -n "$state_interface" ]; then
        qdisc_line="$(tc_root_qdisc "$state_interface")"
        if echo "$qdisc_line" | grep -q " tbf "; then
            state_qdisc_line="$(tc_state_value "QDISC_LINE")"
            state_speed="$(tc_state_value "LIMIT_SPEED")"
            if { [ -n "$state_qdisc_line" ] && [ "$qdisc_line" = "$state_qdisc_line" ]; } \
                || { [ -z "$state_qdisc_line" ] && [[ "$state_speed" =~ ^[0-9]+$ ]] && echo "$qdisc_line" | grep -Eq "rate[[:space:]]+${state_speed}[Kk]bit"; }; then
                echo -e "TC限速: ${YELLOW}已激活（本脚本）${NC}"
            else
                echo -e "TC限速: ${YELLOW}状态记录与当前 tbf 不一致（按外部规则保留）${NC}"
            fi
        else
            echo -e "TC限速: ${YELLOW}状态标记存在，但当前未检测到 tbf${NC}"
        fi
    elif [ -f "$TC_STATE_FILE" ]; then
        echo -e "TC限速: ${YELLOW}状态标记无效（未记录接口）${NC}"
    elif [ -n "$interface" ]; then
        qdisc_line="$(tc_root_qdisc "$interface")"
        if echo "$qdisc_line" | grep -q " tbf "; then
            echo -e "TC限速: ${YELLOW}检测到外部 tbf（非本脚本）${NC}"
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
    crontab -l 2>/dev/null | grep -v "^#" | grep -F "$WORK_DIR" || echo "无相关定时任务"
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
        local interface
        interface=$(get_main_interface)
        if [ -n "$interface" ]; then
            vnstat -i "$interface" --oneline 2>/dev/null | head -1 || echo "无法获取流量统计"
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
        read -r -p "请选择 [0-5]: " choice
        
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
                clear_tc_rules
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
