#!/bin/bash

# TrafficCop Lite - 独立版流量监控管理器
# 基于 ypq123456789/TrafficCop 的流量监控、Telegram 通知与机器限速功能整理。

SCRIPT_VERSION="1.0.0"
LAST_UPDATE="2026-06-08"

WORK_DIR="/etc/trafficcop-lite"
MONITOR_SCRIPT="trafficcop-lite-monitor.sh"
TELEGRAM_SCRIPT="trafficcop-lite-telegram.sh"
MACHINE_LIMIT_SCRIPT="trafficcop-lite-machine-limit.sh"
SHORTCUT_PATH="/usr/local/bin/ncl"
LEGACY_SHORTCUT_PATH="/usr/local/bin/tc"
REPO="${REPO:-duya07/trafficcop-lite}"
BRANCH="${BRANCH:-main}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/${REPO}/${BRANCH}}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
WHITE='\033[0;37m'
NC='\033[0m'

SOURCE_PATH="${BASH_SOURCE[0]}"
while [ -L "$SOURCE_PATH" ]; do
    SOURCE_DIR="$(cd -P "$(dirname "$SOURCE_PATH")" && pwd)"
    SOURCE_PATH="$(readlink "$SOURCE_PATH")"
    [[ "$SOURCE_PATH" != /* ]] && SOURCE_PATH="$SOURCE_DIR/$SOURCE_PATH"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE_PATH")" && pwd)"

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

pause() {
    echo ""
    read -p "按回车键继续..."
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}请使用 root 权限运行此脚本。${NC}"
        exit 1
    fi
}

ensure_work_dir() {
    mkdir -p "$WORK_DIR"
}

copy_self_if_needed() {
    local self_path="$SOURCE_PATH"
    if [ "$self_path" != "$WORK_DIR/trafficcop-lite.sh" ] && [ -f "$self_path" ]; then
        cp "$self_path" "$WORK_DIR/trafficcop-lite.sh"
        chmod +x "$WORK_DIR/trafficcop-lite.sh"
    fi
}

download_component() {
    local script_name="$1"
    local dest="$WORK_DIR/$script_name"
    local url="$RAW_BASE/$script_name"

    echo -e "${YELLOW}正在下载 $script_name...${NC}"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$dest"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$dest" "$url"
    else
        echo -e "${RED}缺少 curl/wget，无法自动下载组件。${NC}"
        return 1
    fi
    chmod +x "$dest"
}

download_url_to_file() {
    local url="$1"
    local dest="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$dest"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$dest" "$url"
    else
        echo -e "${RED}缺少 curl/wget，无法下载文件。${NC}"
        return 1
    fi
}

ensure_component() {
    local script_name="$1"
    local src="$SCRIPT_DIR/$script_name"
    local dest="$WORK_DIR/$script_name"

    ensure_work_dir

    if [ -f "$src" ] && [ "$src" != "$dest" ]; then
        cp "$src" "$dest"
        chmod +x "$dest"
        echo -e "${GREEN}✓ 已安装/更新 $script_name${NC}"
        return 0
    fi

    if [ -f "$dest" ]; then
        chmod +x "$dest"
        return 0
    fi

    download_component "$script_name"
}

install_all_components() {
    ensure_component "$MONITOR_SCRIPT" || return 1
    ensure_component "$TELEGRAM_SCRIPT" || return 1
    ensure_component "$MACHINE_LIMIT_SCRIPT" || return 1
    copy_self_if_needed
}

install_shortcut() {
    install_all_components || return 1

    if [ -e "$SHORTCUT_PATH" ] && [ "$(readlink "$SHORTCUT_PATH" 2>/dev/null)" != "$WORK_DIR/trafficcop-lite.sh" ]; then
        echo -e "${YELLOW}! $SHORTCUT_PATH 已存在，未覆盖。${NC}"
        echo -e "${YELLOW}  你仍可使用：sudo bash $WORK_DIR/trafficcop-lite.sh${NC}"
        return 0
    fi

    mkdir -p "$(dirname "$SHORTCUT_PATH")"
    ln -sfn "$WORK_DIR/trafficcop-lite.sh" "$SHORTCUT_PATH"
    chmod +x "$WORK_DIR/trafficcop-lite.sh"
    echo -e "${GREEN}✓ 快捷命令已安装：sudo ncl${NC}"
    if [ "$(readlink "$LEGACY_SHORTCUT_PATH" 2>/dev/null)" = "$WORK_DIR/trafficcop-lite.sh" ]; then
        rm -f "$LEGACY_SHORTCUT_PATH"
        echo -e "${GREEN}✓ 已清理旧快捷命令：$LEGACY_SHORTCUT_PATH${NC}"
    fi
    if [ -n "$TC_BIN" ]; then
        echo -e "${CYAN}系统原 tc 命令路径：$TC_BIN${NC}"
    fi
}

run_component() {
    local script_name="$1"
    ensure_component "$script_name" || {
        pause
        return 1
    }
    bash "$WORK_DIR/$script_name"
}

manage_monitor() {
    echo -e "${CYAN}正在打开流量监控管理...${NC}"
    install_all_components || {
        pause
        return
    }
    bash "$WORK_DIR/$MONITOR_SCRIPT"
    pause
}

manage_telegram() {
    echo -e "${CYAN}正在打开 Telegram 通知管理...${NC}"
    install_all_components || {
        pause
        return
    }
    bash "$WORK_DIR/$TELEGRAM_SCRIPT"
    pause
}

manage_machine_limit() {
    echo -e "${CYAN}正在打开机器限速管理...${NC}"
    install_all_components || {
        pause
        return
    }
    bash "$WORK_DIR/$MACHINE_LIMIT_SCRIPT"
    pause
}

choose_update_base() {
    local direct_base="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
    local proxy_base="https://v6.gh-proxy.org/https://raw.githubusercontent.com/${REPO}/${BRANCH}"
    local source_choice

    echo -e "${CYAN}请选择更新线路${NC}" >&2
    menu_item "1" "直连" >&2
    menu_item "2" "国内优先" >&2
    menu_item "0" "返回" >&2
    echo "" >&2
    read -p "请输入选项: " source_choice

    case "$source_choice" in
        1|"")
            echo "$direct_base"
            ;;
        2)
            echo "$proxy_base"
            ;;
        0)
            return 1
            ;;
        *)
            echo -e "${RED}无效选择${NC}" >&2
            return 1
            ;;
    esac
}

update_scripts() {
    local update_base="${1:-$RAW_BASE}"
    local scripts=("trafficcop-lite.sh" "$MONITOR_SCRIPT" "$TELEGRAM_SCRIPT" "$MACHINE_LIMIT_SCRIPT")
    local temp_files=()
    local script_name tmp_file url backup_dir

    ensure_work_dir
    echo -e "${CYAN}正在更新 TrafficCop-Lite 脚本...${NC}"
    echo -e "${CYAN}更新源:${NC} $update_base"
    echo -e "${YELLOW}仅覆盖脚本文件；配置、日志、crontab 不会被覆盖。${NC}"
    echo ""

    for script_name in "${scripts[@]}"; do
        url="$update_base/$script_name"
        tmp_file="$WORK_DIR/.${script_name}.new.$$"
        echo -e "${YELLOW}下载 $script_name...${NC}"

        if ! download_url_to_file "$url" "$tmp_file"; then
            echo -e "${RED}下载失败：$script_name${NC}"
            rm -f "${temp_files[@]}" "$tmp_file" 2>/dev/null || true
            return 1
        fi

        if [ ! -s "$tmp_file" ]; then
            echo -e "${RED}下载文件为空：$script_name${NC}"
            rm -f "${temp_files[@]}" "$tmp_file" 2>/dev/null || true
            return 1
        fi

        if ! bash -n "$tmp_file" 2>/dev/null; then
            echo -e "${RED}语法检查失败：$script_name，已取消更新。${NC}"
            rm -f "${temp_files[@]}" "$tmp_file" 2>/dev/null || true
            return 1
        fi

        temp_files+=("$tmp_file")
    done

    backup_dir="$WORK_DIR/backups/scripts-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"

    for script_name in "${scripts[@]}"; do
        if [ -f "$WORK_DIR/$script_name" ]; then
            cp -a "$WORK_DIR/$script_name" "$backup_dir/"
        fi
    done

    for script_name in "${scripts[@]}"; do
        tmp_file="$WORK_DIR/.${script_name}.new.$$"
        chmod +x "$tmp_file"
        mv -f "$tmp_file" "$WORK_DIR/$script_name"
        echo -e "${GREEN}✓ 已更新 $script_name${NC}"
    done

    if [ -e "$SHORTCUT_PATH" ] && [ "$(readlink "$SHORTCUT_PATH" 2>/dev/null)" != "$WORK_DIR/trafficcop-lite.sh" ]; then
        echo -e "${YELLOW}! $SHORTCUT_PATH 已存在且不属于本脚本，已保留。${NC}"
    else
        mkdir -p "$(dirname "$SHORTCUT_PATH")"
        ln -sfn "$WORK_DIR/trafficcop-lite.sh" "$SHORTCUT_PATH"
    fi
    if [ "$(readlink "$LEGACY_SHORTCUT_PATH" 2>/dev/null)" = "$WORK_DIR/trafficcop-lite.sh" ]; then
        rm -f "$LEGACY_SHORTCUT_PATH"
    fi

    echo ""
    echo -e "${GREEN}脚本更新完成。旧脚本已备份到：$backup_dir${NC}"
    echo -e "${YELLOW}建议重新执行 sudo ncl 进入新版菜单。${NC}"
}

update_scripts_interactive() {
    local selected_base

    selected_base=$(choose_update_base) || {
        echo "已取消更新。"
        pause
        return
    }

    update_scripts "$selected_base"
    pause
}

show_status_line() {
    local monitor_cron="未设置"
    local telegram_cron="未设置"
    local config_state="未配置"

    if crontab -l 2>/dev/null | grep -F -q "$WORK_DIR/$MONITOR_SCRIPT"; then
        monitor_cron="已设置"
    fi
    if crontab -l 2>/dev/null | grep -F -q "$WORK_DIR/$TELEGRAM_SCRIPT"; then
        telegram_cron="已设置"
    fi
    if [ -f "$WORK_DIR/traffic_monitor_config.txt" ]; then
        config_state="已配置"
    fi

    local config_color="$YELLOW"
    local monitor_color="$YELLOW"
    local telegram_color="$YELLOW"

    [ "$config_state" = "已配置" ] && config_color="$GREEN"
    [ "$monitor_cron" = "已设置" ] && monitor_color="$GREEN"
    [ "$telegram_cron" = "已设置" ] && telegram_color="$GREEN"

    echo -e "${CYAN}工作目录:${NC} $WORK_DIR"
    echo -e "${CYAN}监控配置:${NC} ${config_color}${config_state}${NC}   ${CYAN}监控任务:${NC} ${monitor_color}${monitor_cron}${NC}   ${CYAN}TG任务:${NC} ${telegram_color}${telegram_cron}${NC}"
}

menu_item() {
    local number="$1"
    local label="$2"
    local number_color="${3:-$PURPLE}"
    local label_color="${4:-$WHITE}"
    printf "${number_color}%2s)${NC} ${label_color}%s${NC}\n" "$number" "$label"
}

tail_file() {
    local file="$1"
    local title="$2"
    echo -e "${CYAN}${title}${NC}"
    if [ -f "$file" ]; then
        tail -80 "$file"
    else
        echo -e "${YELLOW}文件不存在：$file${NC}"
    fi
}

view_logs() {
    while true; do
        clear
        echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║              查看日志                  ║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
        echo "1) 流量监控日志"
        echo "2) Telegram 通知日志"
        echo "3) 当前 crontab 相关条目"
        echo "0) 返回主菜单"
        echo ""
        read -p "请输入选项: " choice

        case "$choice" in
            1) tail_file "$WORK_DIR/traffic_monitor.log" "流量监控日志"; pause ;;
            2) tail_file "$WORK_DIR/tg_notifier_cron.log" "Telegram 通知日志"; pause ;;
            3)
                echo -e "${CYAN}TrafficCop-Lite 定时任务:${NC}"
                crontab -l 2>/dev/null | grep -F "$WORK_DIR" || echo "无相关定时任务"
                pause
                ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

print_config_file() {
    local file="$1"
    local title="$2"
    echo -e "${CYAN}${title}${NC}"
    if [ -f "$file" ]; then
        sed -E 's/^(BOT_TOKEN=).*/\1********/; s/^(CHAT_ID=).*/\1********/' "$file"
    else
        echo -e "${YELLOW}配置不存在：$file${NC}"
    fi
}

view_config() {
    while true; do
        clear
        echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║             当前配置                   ║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
        echo "1) 流量监控配置"
        echo "2) Telegram 通知配置"
        echo "3) 独立版安装状态"
        echo "0) 返回主菜单"
        echo ""
        read -p "请输入选项: " choice

        case "$choice" in
            1) print_config_file "$WORK_DIR/traffic_monitor_config.txt" "流量监控配置"; pause ;;
            2) print_config_file "$WORK_DIR/tg_notifier_config.txt" "Telegram 通知配置"; pause ;;
            3) show_status_line; pause ;;
            0) return ;;
            *) echo -e "${RED}无效选择${NC}"; sleep 1 ;;
        esac
    done
}

remove_lite_cron() {
    local current_crontab
    current_crontab="$(crontab -l 2>/dev/null || true)"
    if [ -n "$current_crontab" ]; then
        echo "$current_crontab" | grep -v -F "$WORK_DIR" | crontab - 2>/dev/null || true
    fi
}

stop_lite_processes() {
    pkill -f "$WORK_DIR/$MONITOR_SCRIPT" 2>/dev/null || true
    pkill -f "$WORK_DIR/$TELEGRAM_SCRIPT" 2>/dev/null || true
}

clear_lite_tc_rules_interactive() {
    local config="$WORK_DIR/traffic_monitor_config.txt"
    local interface=""
    local limit_mode=""

    if [ -f "$config" ]; then
        interface="$(grep '^MAIN_INTERFACE=' "$config" | tail -1 | cut -d'=' -f2-)"
        limit_mode="$(grep '^LIMIT_MODE=' "$config" | tail -1 | cut -d'=' -f2-)"
    fi

    if [ "$limit_mode" != "tc" ] || [ -z "$interface" ]; then
        echo "✓ 未检测到独立版 TC 限速配置"
        return
    fi

    if [ -z "$TC_BIN" ]; then
        echo -e "${YELLOW}未找到系统 tc 命令，跳过 TC 规则检查。${NC}"
        return
    fi

    if ! "$TC_BIN" qdisc show dev "$interface" 2>/dev/null | grep -q "tbf"; then
        echo "✓ 接口 $interface 未发现 tbf 限速规则"
        return
    fi

    echo -e "${YELLOW}检测到接口 $interface 上存在 tbf 限速规则。${NC}"
    echo -e "${YELLOW}Linux 无法可靠区分该规则是否由本脚本创建，默认不清除以免影响系统其他限速。${NC}"
    read -p "确认清除该接口 root TC 规则？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        "$TC_BIN" qdisc del dev "$interface" root 2>/dev/null || true
        echo "✓ 已尝试清除 TC 规则"
    else
        echo "已保留 TC 规则"
    fi
}

cancel_shutdown_interactive() {
    local config="$WORK_DIR/traffic_monitor_config.txt"
    if grep -q '^LIMIT_MODE=shutdown' "$config" 2>/dev/null; then
        echo -e "${YELLOW}检测到独立版曾配置关机模式。${NC}"
        read -p "是否取消当前系统计划关机？[y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            shutdown -c 2>/dev/null || true
            echo "✓ 已尝试取消计划关机"
        fi
    fi
}

stop_all_services() {
    echo -e "${CYAN}正在停止 TrafficCop-Lite 服务...${NC}"
    stop_lite_processes
    echo "✓ 已停止独立版监控/通知进程"

    remove_lite_cron
    echo "✓ 已移除独立版 crontab 条目"

    clear_lite_tc_rules_interactive
    cancel_shutdown_interactive

    echo -e "${GREEN}独立版服务停止流程完成。${NC}"
    pause
}

uninstall_lite() {
    clear
    echo -e "${RED}${BOLD}卸载 TrafficCop-Lite${NC}"
    echo ""
    echo "只会处理独立版目录：$WORK_DIR"
    echo "不会删除 /root/TrafficCop，也不会卸载 vnstat/jq/bc/cron/iproute2 等系统软件包。"
    echo ""
    read -p "确认卸载？请输入 UNINSTALL 继续: " confirm
    if [ "$confirm" != "UNINSTALL" ]; then
        echo "已取消卸载。"
        pause
        return
    fi

    stop_lite_processes
    remove_lite_cron
    clear_lite_tc_rules_interactive
    cancel_shutdown_interactive

    if [ -d "$WORK_DIR" ]; then
        read -p "是否先备份配置和日志？[Y/n]: " keep_backup
        if [[ ! "$keep_backup" =~ ^[Nn]$ ]]; then
            local backup_dir="/etc/trafficcop-lite-backup-$(date +%Y%m%d-%H%M%S)"
            cp -a "$WORK_DIR" "$backup_dir"
            echo "✓ 已备份到 $backup_dir"
        fi
        rm -rf "$WORK_DIR"
        echo "✓ 已删除 $WORK_DIR"
    else
        echo "独立版工作目录不存在，无需删除。"
    fi

    if [ "$(readlink "$SHORTCUT_PATH" 2>/dev/null)" = "$WORK_DIR/trafficcop-lite.sh" ]; then
        rm -f "$SHORTCUT_PATH"
        echo "✓ 已删除快捷命令 $SHORTCUT_PATH"
    fi
    if [ "$(readlink "$LEGACY_SHORTCUT_PATH" 2>/dev/null)" = "$WORK_DIR/trafficcop-lite.sh" ]; then
        rm -f "$LEGACY_SHORTCUT_PATH"
        echo "✓ 已删除旧快捷命令 $LEGACY_SHORTCUT_PATH"
    fi

    echo -e "${GREEN}卸载完成。${NC}"
    pause
}

show_main_menu() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${BOLD}        TrafficCop Lite 独立管理工具        ${NC}${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"
    echo -e "${PURPLE}版本: ${SCRIPT_VERSION}    更新: ${LAST_UPDATE}${NC}"
    echo ""
    show_status_line
    echo -e "${CYAN}快捷命令:${NC} sudo ncl"
    echo ""
    menu_item "1" "安装/管理流量监控"
    menu_item "2" "安装/管理 Telegram 通知"
    menu_item "3" "机器限速管理 (启用/禁用)"
    menu_item "4" "查看日志"
    menu_item "5" "查看当前配置"
    menu_item "6" "停止所有服务"
    menu_item "7" "更新脚本"
    menu_item "8" "卸载 TrafficCop-Lite" "$RED" "$RED"
    menu_item "0" "退出"
    echo ""
}

main() {
    check_root
    ensure_work_dir

    case "${1:-}" in
        --install)
            install_shortcut
            echo -e "${GREEN}安装完成。以后可执行：sudo ncl${NC}"
            exit 0
            ;;
        --uninstall)
            uninstall_lite
            exit 0
            ;;
        --stop)
            stop_all_services
            exit 0
            ;;
        --logs)
            view_logs
            exit 0
            ;;
        --config)
            view_config
            exit 0
            ;;
        --update)
            update_scripts "$RAW_BASE"
            exit $?
            ;;
        --help|-h)
            echo "TrafficCop Lite"
            echo "用法: sudo ncl [--install|--update|--uninstall|--stop|--logs|--config]"
            echo "无参数运行进入交互菜单。"
            exit 0
            ;;
    esac

    install_shortcut

    while true; do
        show_main_menu
        read -p "请输入选项: " choice
        case "$choice" in
            1) manage_monitor ;;
            2) manage_telegram ;;
            3) manage_machine_limit ;;
            4) view_logs ;;
            5) view_config ;;
            6) stop_all_services ;;
            7) update_scripts_interactive ;;
            8) uninstall_lite ;;
            0) echo -e "${GREEN}已退出 TrafficCop-Lite。${NC}"; exit 0 ;;
            *) echo -e "${RED}无效选择，请重新输入。${NC}"; sleep 1 ;;
        esac
    done
}

main "$@"
