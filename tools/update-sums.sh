#!/bin/bash
# 重新生成仓库根目录的 SHA256SUMS（ntc 更新与补装组件时据此校验四个脚本）。
# 任何脚本改动提交前都要运行；tests/regression.sh 会核对 SHA256SUMS 与当前文件一致。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
files=(trafficcop-lite.sh trafficcop-lite-monitor.sh trafficcop-lite-telegram.sh trafficcop-lite-machine-limit.sh)
for f in "${files[@]}"; do bash -n "$f"; done
sha256sum "${files[@]}" > SHA256SUMS
sha256sum -c --quiet SHA256SUMS
cat SHA256SUMS
