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
