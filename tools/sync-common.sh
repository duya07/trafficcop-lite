#!/usr/bin/env bash
# 把 src/common/<模块>.sh 写进四个发行脚本里的同名标记区块：
#   # >>> ntc-common:<模块> >>>
#   …（由本脚本生成，勿直接修改）
#   # <<< ntc-common:<模块> <<<
# 用法：tools/sync-common.sh           同步（只改有差异的脚本）
#       tools/sync-common.sh --check   只检查，有差异或标记错误时返回 1（tests/regression.sh 调用）
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
COMMON_DIR="$ROOT/src/common"
SCRIPTS=(trafficcop-lite.sh trafficcop-lite-monitor.sh trafficcop-lite-telegram.sh trafficcop-lite-machine-limit.sh)

mode=write
case "${1:-}" in
    --check) mode=check ;;
    '') ;;
    *) printf '用法: %s [--check]\n' "$0" >&2; exit 2 ;;
esac

# render 脚本路径 已用模块清单文件 -> 标准输出为同步后的内容
render() {
    awk -v common="$COMMON_DIR" -v used="$2" -v script="$1" '
        function fail(msg) { printf "%s:%d: %s\n", script, NR, msg > "/dev/stderr"; failed = 1; exit 1 }
        {
            if (index($0, "# >>> ntc-common:") == 1) {
                if (inside) fail("标记区块未结束就开始了新区块")
                name = substr($0, 18)
                if (length(name) < 5 || substr(name, length(name) - 3) != " >>>") fail("起始标记格式应为 # >>> ntc-common:<模块> >>>")
                name = substr(name, 1, length(name) - 4)
                if (name !~ /^[a-z0-9-]+$/) fail("模块名只能含小写字母、数字和连字符")
                if (name in seen) fail("模块 " name " 在同一脚本里出现了两次")
                seen[name] = 1
                path = common "/" name ".sh"
                print
                print "# 本区块由 tools/sync-common.sh 根据 src/common/" name ".sh 生成，请改源文件后运行该脚本，勿直接修改。"
                count = 0
                while ((status = (getline line < path)) > 0) { print line; count++ }
                if (status < 0 || count == 0) fail("找不到或无法读取模块文件 src/common/" name ".sh")
                close(path)
                print name >> used
                inside = 1
                next
            }
            if (index($0, "# <<< ntc-common:") == 1) {
                if (!inside) fail("结束标记前没有起始标记")
                if ($0 != "# <<< ntc-common:" name " <<<") fail("结束标记与起始模块 " name " 不一致")
                print
                inside = 0
                next
            }
            if (!inside) print
        }
        END {
            if (failed) exit 1
            if (inside) { printf "%s: 模块 %s 缺少结束标记\n", script, name > "/dev/stderr"; exit 1 }
        }
    ' "$1"
}

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
: > "$tmp_dir/used"
status=0
for script in "${SCRIPTS[@]}"; do
    path="$ROOT/$script"
    if ! render "$path" "$tmp_dir/used" > "$tmp_dir/out"; then
        status=1
        continue
    fi
    if cmp -s "$tmp_dir/out" "$path"; then
        continue
    fi
    if [ "$mode" = check ]; then
        printf '需要同步：%s（运行 tools/sync-common.sh）\n' "$script" >&2
        diff -u "$path" "$tmp_dir/out" | head -n 40 >&2 || true
        status=1
    else
        cat "$tmp_dir/out" > "$path"
        printf '已同步：%s\n' "$script"
    fi
done

# 每个模块都必须至少被一个脚本使用，避免源文件改了却没有任何产物跟着变。
for module_path in "$COMMON_DIR"/*.sh; do
    [ -e "$module_path" ] || continue
    module=$(basename "$module_path" .sh)
    if ! grep -Fxq "$module" "$tmp_dir/used"; then
        printf '模块 src/common/%s.sh 没有被任何脚本引用\n' "$module" >&2
        status=1
    fi
done
exit "$status"
