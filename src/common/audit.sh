# Only fixed event/result values are accepted; extra arguments are never recorded.
ntc_operation_log() {
    local event="${1:-}" result="${2:-}"
    case "$event" in
        install|update|update-rollback|monitor-config|config-rollback|tc-apply|tc-clear|tc-recover|stop|machine-enable|machine-disable|machine-restore|machine-rollback|enforcement-pause|enforcement-resume|enforcement-grace|boot-grace|telegram-config|telegram-enable|telegram-disable) ;;
        *) printf '%s\n' 'NTC audit event rejected' >&2; return 0 ;;
    esac
    case "$result" in
        success|failure|unchanged) ;;
        *) printf '%s\n' 'NTC audit result rejected' >&2; return 0 ;;
    esac
    local description result_text
    case "$event" in
        install) description="安装 NTC" ;;
        update) description="更新脚本" ;;
        update-rollback) description="恢复更新前的脚本" ;;
        monitor-config) description="保存流量监控配置" ;;
        config-rollback) description="恢复原配置" ;;
        tc-apply) description="应用整机限速" ;;
        tc-clear) description="撤销整机限速" ;;
        tc-recover) description="恢复 Dog/NTC 限速" ;;
        stop) description="停止监控和通知" ;;
        machine-enable) description="启用整机流量限制" ;;
        machine-disable) description="停用整机流量限制" ;;
        machine-restore) description="恢复整机流量配置" ;;
        machine-rollback) description="回退整机流量配置" ;;
        enforcement-pause) description="暂停流量限制" ;;
        enforcement-resume) description="恢复流量限制" ;;
        enforcement-grace) description="设置临时宽限期" ;;
        boot-grace) description="设置开机宽限期" ;;
        telegram-config) description="保存 Telegram 通知配置" ;;
        telegram-enable) description="启用 Telegram 通知" ;;
        telegram-disable) description="停用 Telegram 通知" ;;
    esac
    case "$result" in success) result_text="成功" ;; failure) result_text="失败" ;; unchanged) result_text="保持不变" ;; esac
    if ! (
        umask 077
        [ -n "${WORK_DIR:-}" ] && [ ! -L "$WORK_DIR" ] || exit 1
        mkdir -p "$WORK_DIR" && chmod 700 "$WORK_DIR" || exit 1
        audit_file="$WORK_DIR/operations.log"
        for audit_path in "$audit_file" "$audit_file.1" "$audit_file.2" "$audit_file.3" "$audit_file.lock"; do
            [ ! -L "$audit_path" ] || exit 1
            if [ -e "$audit_path" ]; then
                [ -f "$audit_path" ] && [ "$(stat -c %h "$audit_path")" = 1 ] || exit 1
                chmod 600 "$audit_path" || exit 1
            fi
        done
        exec 8>"$audit_file.lock" || exit 1
        chmod 600 "$audit_file.lock" && flock -w 2 8 || exit 1
        if [ -f "$audit_file" ] && [ "$(stat -c %s "$audit_file")" -ge 1048576 ]; then
            rm -f "$audit_file.3" || exit 1
            [ ! -f "$audit_file.2" ] || mv -f "$audit_file.2" "$audit_file.3" || exit 1
            [ ! -f "$audit_file.1" ] || mv -f "$audit_file.1" "$audit_file.2" || exit 1
            mv -f "$audit_file" "$audit_file.1" || exit 1
        fi
        : >> "$audit_file" && chmod 600 "$audit_file" || exit 1
        printf '%s %s：%s EVENT=%s RESULT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$description" "$result_text" "$event" "$result" >> "$audit_file" || exit 1
    ) 2>/dev/null; then
        printf 'NTC 操作日志写入失败，业务结果保持原值 (NTC audit log unavailable EVENT=%s RESULT=%s)\n' "$event" "$result" >&2
    fi
    # Logging failures must never change the business result or the caller's shell options.
    return 0
}
