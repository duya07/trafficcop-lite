# trafficcop-lite

整机流量监控、达量限速/关机与 Telegram 通知脚本（从 [TrafficCop](https://github.com/ypq123456789/TrafficCop) 拆分定制）。以 root 运行，基于 vnStat 计量、HTB 限速。

> 安全提示：`v6.gh-proxy.org` 等镜像由第三方提供；脚本以 root 运行，安全性要求高时请优先使用 GitHub 直连。

## 功能

- **整机流量计量**：基于 vnStat 每日历史统计周期用量，支持 月 / 季 / 年 周期与自定义起始日、起始月；单位支持 `GB`(10³) 与 `GiB`(2³⁰)。
- **达量执行**：超过阈值后可 限速（统一 HTB 整机上限）或 关机；支持宽限期、暂停、禁用与开机限速宽限（默认 10 分钟）。
- **开机保护**：关机模式记录周期与 boot ID，同一周期手动开机后自动暂停再次关机，避免循环。
- **Telegram 通知**：阈值、周期与每日报告；凭据文件 600，失败保留旧状态重试。
- **统一 HTB**：`1:1` 父类承担整机上限、`1:30` 承接默认流量，并保留 Dog 的端口子类/过滤器；可与 port-traffic-dog 共存，安装顺序不限。
- **TC 冲突处理**：主页只读检测；用户确认后删除冲突 root 并只重建 Dog/NTC 层级，不保留第三方 TC。

## 安装

直连：

```bash
wget -O trafficcop-lite.sh https://raw.githubusercontent.com/duya07/trafficcop-lite/main/trafficcop-lite.sh
chmod +x trafficcop-lite.sh && sudo ./trafficcop-lite.sh --install && sudo ntc
```

国内优先（gh-proxy）：

```bash
wget -O trafficcop-lite.sh https://v6.gh-proxy.org/https://raw.githubusercontent.com/duya07/trafficcop-lite/main/trafficcop-lite.sh
chmod +x trafficcop-lite.sh && sudo env RAW_BASE="https://v6.gh-proxy.org/https://raw.githubusercontent.com/duya07/trafficcop-lite/main" ./trafficcop-lite.sh --install && sudo ntc
```

## 常用命令

```bash
sudo ntc --install / --update
sudo ntc --self-check          # 只读检查统一 HTB、状态归属与兼容性
sudo ntc --recover-tc --manual # 确认后重建统一 HTB
sudo ntc --logs / --config / --stop / --uninstall
```

主菜单：`1` 流量监控 · `2` Telegram · `3` 机器限速 · `4` 日志 · `5` 配置 · `6` 停止服务 · `7` 更新 · `8` 卸载 · `9` TC 冲突处理/自动恢复。

## 配置要点

- **周期**：月/季/年，可设起始日（1–31，遇短月按月末）与年度起始月。
- **计费口径**：只出站 `ΣTX`、只进站 `ΣRX`、进出合计 `ΣRX+ΣTX`、进出取大 `max(ΣRX, ΣTX)`；显示、阈值与通知使用同一口径。
- **vnStat 异常速率检查**：`VNSTAT_MAX_BANDWIDTH` 默认 `0`（关闭），可设 `1–50000` Mbit/s；过低上限会让 vnStat 丢弃高速采样。
- **失败关闭**：vnStat 未运行、数据库过旧、JSON/日期/字段异常或历史不足（未允许部分历史）时，本轮不下发新限制、也不清除已有规则。
- 保存配置时若已超额，会要求选择：宽限（默认 10 分钟）/ 立即执行 / 暂停。

## 安装后的文件

```text
/etc/trafficcop-lite/trafficcop-lite.sh             主入口
/etc/trafficcop-lite/trafficcop-lite-monitor.sh     监控与限速
/etc/trafficcop-lite/trafficcop-lite-telegram.sh    Telegram
/etc/trafficcop-lite/trafficcop-lite-machine-limit.sh 机器限速管理
/etc/trafficcop-lite/traffic_monitor_config.txt     监控配置
/etc/trafficcop-lite/tc_limit_state                 整机上限状态（与 Dog 共享）
/etc/trafficcop-lite/{enforcement,shutdown_limit,current_traffic}_state
/etc/trafficcop-lite/backups/scripts-时间戳/        更新备份
/usr/local/bin/ntc -> /etc/trafficcop-lite/trafficcop-lite.sh
```

## 卸载

`sudo ntc --uninstall`：仅处理 `/etc/trafficcop-lite` 与本项目创建的任务/文件，卸载前按配置检查 TC 限速与计划关机，清理失败会中止删除；默认备份配置与日志到 `/etc/trafficcop-lite-backup-时间戳/`，不删除上游 `/root/TrafficCop`，也不自动恢复全局 vnStat 配置。

## 注意事项

- 需 vnStat 2.x；Debian/Ubuntu、RHEL 系、Alpine、Arch 系会按包管理器尝试安装依赖（含 `iproute2`/`tc`、`procps`），无法自动启动 cron/vnStat 时会明确提示。
- 与 Dog 共用 `/run/lock/traffic-tools-tc.lock`，root crontab 锁各自独立；外部程序重建 root qdisc 后主页会报冲突，自动路径拒绝覆盖，需菜单 `9` 确认。
- 需要控制台或备用管理入口后再对 SSH 端口执行限速/关机，避免自锁。

## 参考

- 上游：<https://github.com/ypq123456789/TrafficCop>
