enforcement_state_value() {
    local key="$1"
    if [ -f "$ENFORCEMENT_STATE_FILE" ]; then
        grep "^${key}=" "$ENFORCEMENT_STATE_FILE" 2>/dev/null | tail -n 1 | cut -d'=' -f2-
    fi
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
