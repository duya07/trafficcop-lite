# trafficcop-lite

独立版机器流量监控、限速与 Telegram 通知管理脚本。

本仓库从 TrafficCop 中拆出“机器总流量限制”相关能力，去掉端口流量限制入口，并增加年度周期起始月份选择。

## 参考来源

- 上游仓库: <https://github.com/ypq123456789/TrafficCop>
- 上游管理脚本: <https://github.com/ypq123456789/TrafficCop/blob/main/trafficcop-manager.sh>
- 上游流量监控脚本: <https://github.com/ypq123456789/TrafficCop/blob/main/trafficcop.sh>
- 上游 Telegram 通知脚本: <https://github.com/ypq123456789/TrafficCop/blob/main/tg_notifier.sh>
- 上游机器限速管理脚本: <https://github.com/ypq123456789/TrafficCop/blob/main/machine_limit_manager.sh>

## 本仓库主要改动

1. 独立工作目录改为 `/etc/trafficcop-lite`。
2. 主菜单保留流量监控、Telegram 通知、机器限速、日志、配置、停止服务、更新、卸载和 TC 冲突恢复管理。
3. 年度统计周期支持选择起始月份，不再只能从每年 1 月开始。
4. 安装后提供快捷命令 `ntc`，可直接执行 `sudo ntc` 打开管理菜单。
5. 脚本内部调用系统限速命令时使用 `/usr/sbin/tc` 等原始路径，避免与 Linux 自带 `tc` 限速命令冲突。
6. 停止服务和卸载时只处理 `/etc/trafficcop-lite` 相关进程、crontab 和文件，不删除上游默认目录 `/root/TrafficCop`。
7. 卸载会先按配置检查 TC 限速和计划关机，再备份配置和日志到 `/etc/trafficcop-lite-backup-时间戳/`。
8. TC 规则只有在当前状态与本脚本记录一致时才会自动更新或删除；清理失败会保留状态并中止卸载。
9. Telegram 配置和状态文件使用 `600` 权限，通知发送失败会保留旧状态并在下次任务重试。
10. 周期重置每个周期只执行一次；即使机器错过周期起始日，也会在恢复运行后补做重置。
11. 监控成功后原子写入实时流量状态，Telegram 只使用未过期且周期一致的状态，不再从旧日志推断。
12. 兼容 vnStat 以分号或井号标记的默认配置输出，不会误判 `DailyDays`、`TrafficlessEntries` 或 `UseUTC`。
13. 关机模式检测到已有计划关机时不会重复提交或覆盖，避免每分钟改写系统关机计划。
14. vnStat 历史晚于流量周期起点时，可由用户明确确认后按现有历史继续统计，主页会持续提示周期早段流量未计入。
15. 保存配置时若当前流量已经达到阈值，可选择立即执行、限时宽限或暂停执行。
16. TC 模式支持开机宽限，默认开机 10 分钟后才允许首次下发限速。
17. 关机模式记录触发时的周期和 boot ID；同一周期内手动开机后会自动暂停再次关机，避免循环。
18. 新周期重置时会先撤销本脚本登记的计划关机；撤销失败则保留状态并停止重置。
19. 修改监控配置后的安全处理若失败，会恢复修改前的配置和执行策略。
20. Telegram 交互菜单不再长期占用任务锁，定时任务与手动发送仍保持互斥。
21. vnStat 保留期配置与覆盖起点标记同步提交，配置替换失败时会恢复旧标记。
22. 取消计划关机前会核对 boot ID；重启后的陈旧标记不会取消本次开机由其他工具创建的关机任务。旧标记无法验证归属时会保留系统任务并停止自动清理。
23. 所有 root crontab 读改写使用 TrafficCop Lite 自身的 `/etc/trafficcop-lite/root-crontab.lock`；它不依赖也不占用 Port Traffic Dog 的 cron 锁。
24. TC 模式直接管理 `traffic-tools-unified-htb-v1`：`1:1` 实施整机上限，`1:30` 承接默认流量，并保留 Dog 的端口子类。TrafficCop Lite 可单独安装；日常应用在可验证的 Dog 层级中原地协调，共享恢复入口在两者并存时按顺序调用两边的恢复接口，安装顺序不限。
25. 主页只读显示 TC 状态；用户明确确认后，可删除冲突 root 并按 Dog/NTC 现有状态重建。第三方 TC 配置不会被识别、迁移或保留。
26. Dog 与 NTC 共用唯一的 `traffic-tools-tc-recovery.service`。服务默认关闭；启用后在网络就绪时执行一次，不使用固定延迟，也不做运行期高频抢占。
27. vnStat 异常速率检查默认关闭（`MaxBW=0`），也可在监控配置中设置 `1-50000 Mbit/s` 的自定义上限；脚本同时校准写盘间隔，仅在配置实际变化时向 `vnstatd` 发送 HUP，失败会恢复旧配置。
28. 流量读取前同时检查 `vnstatd` 和数据库更新时间；TC 的 root/class/filter 查询保留“存在、缺失、查询失败”三种状态，查询失败时不会按“规则不存在”继续修改。
29. 机器限速启用宽限会在同一监控锁内先撤销 NTC 自有整机限速和计划关机，再提交宽限状态；Dog 的端口 class/filter 会保留。
30. 显式配置的周期起始日必须是 `1-31`；非法值会停止本轮计算并在主页提示配置异常，不再由不同组件各自归一化。
31. TC 自检不会写入通用监控日志；机器状态只把明确的自动化执行标记视为最近运行，打开主页或执行自检不会伪造监控活动。

## 下载方式说明

- 直连（海外网络优先）  
  使用 `https://raw.githubusercontent.com/...`
- 国内优先（代理加速）  
  使用 `https://v6.gh-proxy.org/https://raw.githubusercontent.com/...`

国内优先线路由第三方代理提供。脚本将以 root 权限运行，安全性要求较高时请优先使用 GitHub 直连。

---

## 1) 安装

直连:

```bash
wget -O trafficcop-lite.sh https://raw.githubusercontent.com/duya07/trafficcop-lite/main/trafficcop-lite.sh
chmod +x trafficcop-lite.sh
sudo ./trafficcop-lite.sh --install
sudo ntc
```

国内优先（gh-proxy）:

```bash
wget -O trafficcop-lite.sh https://v6.gh-proxy.org/https://raw.githubusercontent.com/duya07/trafficcop-lite/main/trafficcop-lite.sh
chmod +x trafficcop-lite.sh
sudo env RAW_BASE="https://v6.gh-proxy.org/https://raw.githubusercontent.com/duya07/trafficcop-lite/main" ./trafficcop-lite.sh --install
sudo ntc
```

一行安装:

直连:

```bash
wget -O trafficcop-lite.sh https://raw.githubusercontent.com/duya07/trafficcop-lite/main/trafficcop-lite.sh && chmod +x trafficcop-lite.sh && sudo ./trafficcop-lite.sh --install && sudo ntc
```

国内优先（gh-proxy）:

```bash
wget -O trafficcop-lite.sh https://v6.gh-proxy.org/https://raw.githubusercontent.com/duya07/trafficcop-lite/main/trafficcop-lite.sh && chmod +x trafficcop-lite.sh && sudo env RAW_BASE="https://v6.gh-proxy.org/https://raw.githubusercontent.com/duya07/trafficcop-lite/main" ./trafficcop-lite.sh --install && sudo ntc
```

## 2) 使用

打开主菜单:

```bash
sudo ntc
```

常用命令:

```bash
sudo ntc --install
sudo ntc --update
sudo ntc --stop
sudo ntc --logs
sudo ntc --config
sudo ntc --self-check
sudo ntc --recover-tc --manual
sudo ntc --uninstall
```

- `--install`: 安装/更新组件，并创建 `ntc` 快捷命令；使用单独下载的主脚本安装时会同步刷新整套组件。
- `--update`: 从仓库更新脚本文件，不覆盖配置和日志。
- `--stop`: 停止独立版监控和通知任务。
- `--logs`: 查看日志。
- `--config`: 查看配置。
- `--self-check [INTERFACE]`: 只读检查指定网卡（或自动识别网卡）的统一 HTB、状态归属与兼容性。
- `--recover-tc --manual`: 显式调用共享恢复入口；它可能删除当前 root qdisc，通常应优先在主菜单 `9` 阅读提示并确认。
- `--uninstall`: 卸载 TrafficCop Lite。

主菜单入口:

```text
1) 安装/管理流量监控
2) 安装/管理 Telegram 通知
3) 机器限速管理 (启用/禁用)
4) 查看日志
5) 查看当前配置
6) 停止所有服务
7) 更新脚本
8) 卸载 TrafficCop-Lite
9) TC 冲突处理/自动恢复
```

Telegram 管理菜单提供 `8. 开启/关闭自动通知`。关闭后会移除本项目的 Telegram 定时任务并保存关闭状态，但不会删除 Bot 配置，也不影响测试消息和手动发送；再次开启时会恢复唯一的每分钟检查任务。

## 3) 更新脚本

交互菜单中选择 `7) 更新脚本`，可选择直连或国内优先线路。

命令行更新:

直连:

```bash
sudo ntc --update
```

国内优先（gh-proxy）:

```bash
sudo env RAW_BASE="https://v6.gh-proxy.org/https://raw.githubusercontent.com/duya07/trafficcop-lite/main" /usr/local/bin/ntc --update
```

更新行为:

- 只覆盖 `/etc/trafficcop-lite` 下的脚本文件。
- 不覆盖 `traffic_monitor_config.txt`、`tg_notifier_config.txt`、日志和 crontab。
- 兼容旧配置；旧配置没有 `PERIOD_START_MONTH` 时仍按 1 月起算。
- 旧配置没有 `TRAFFIC_UNIT` 时继续按 GiB 计算，不会因更新改变原配额含义。
- 旧配置没有 `ALLOW_PARTIAL_HISTORY` 时保持严格模式，不会擅自按残缺历史执行限制。
- 旧配置没有 `TC_BOOT_GRACE_MINUTES` 时默认使用 10 分钟开机限速宽限。
- 旧配置没有 `VNSTAT_MAX_BANDWIDTH` 时默认使用 `0`，即关闭 vnStat 异常速率检查。
- 旧 Telegram 配置没有 `TG_DISABLED` 时保持原行为，自动通知默认开启。
- 下载到临时文件并通过 `bash -n` 语法检查后才替换。
- 校验每个候选脚本的版本，拒绝代理缓存或错误更新源造成的组件降级。
- 四个脚本全部下载并校验成功后才开始替换；替换后会再次校验整套脚本。
- 旧脚本会备份到 `/etc/trafficcop-lite/backups/scripts-时间戳-进程号/`。
- 文件内容没有变化时直接提示已是最新版本，不重复创建备份。
- 更新完成会显示“旧版本 → 新版本”，便于确认实际安装结果。
- 交互更新完成后会自动重新载入新版菜单；命令行更新完成后重新执行 `sudo ntc`。
- 新版安装器会比较组件版本，阻止较旧的外部脚本覆盖已经安装的更高版本。

`1.0.2` 的旧交互进程有一个显示限制：脚本文件更新成功后，当前进程仍会暂时显示 `1.0.2`，退出并重新执行 `sudo ntc` 才会载入新版本。该版本会在更新前创建脚本备份，因此可通过 `/etc/trafficcop-lite/backups/` 判断是否已完成替换；从后续版本开始，交互更新会自动载入新版菜单。

## 4) 年度起始月份

配置流量监控时，选择统计周期 `y` 后会额外提示:

```text
请输入年度周期起始月份 (1-12，默认为1):
```

例如输入 `6`，年度统计周期会按每年 6 月的指定起始日开始计算。

配置时还可选择流量单位：`GB` 使用十进制（1000³ 字节，适合服务商配额），`GiB` 使用二进制（1024³ 字节，兼容旧版）。容错范围必须大于等于 `0` 且小于流量限制，异常旧配置会停止本轮判断，不会按 `0` 阈值触发限速或关机。季度和年度统计依赖 vnStat 的每日历史；脚本可调整 `DailyDays`，并按实际配置文件的规范路径分别保留原配置备份（首个通常为 `/etc/trafficcop-lite/vnstat.conf.before-trafficcop-lite`，切换路径后使用编号备份及对应 `.source-path` 标记）。`DailyDays=-1` 会按无限保留处理，`TrafficlessEntries=0` 产生的无流量日期缺口不会被误判为历史丢失。

TrafficCop Lite 会保留 vnStat 配置中的其他自定义项，并幂等设置 `SaveInterval 1`。当 `UpdateInterval` 大于 60 秒时才将其收紧到 60 秒，以满足 vnStat 的保存间隔约束。配置监控时可以设置 `VNSTAT_MAX_BANDWIDTH`：默认 `0` 表示关闭 vnStat 异常速率检查，也可以输入 `1-50000` 作为 Mbit/s 上限。vnStat 2.9 及以上使用当前网卡的 `MaxBW<接口名>`；2.0–2.8 兼容模式还会设置 `BandwidthDetection 0` 和全局 `MaxBandwidth`。关闭检查可避免高速云网卡被过低上限丢弃采样，但也会失去 vnStat 对异常接口计数跳变的保护；如需该保护，请按机器合理峰值设置非零上限。

`SaveInterval 1` 会让数据库通常每分钟落盘一次，相比常见的 5 分钟默认值会增加少量磁盘写入，但缩短崩溃或断电时未保存流量的窗口。统计仍不是秒级实时值；正常可有约 1–3 分钟延迟。若 `vnstatd` 未运行、数据库因磁盘满等原因长期未更新，或 JSON API 版本、接口名、日期、每日 `rx/tx` 字段无效，本轮判断会失败关闭：不下发新限制，也不清除已有规则。vnStat 已经因“实际速率高于 MaxBandwidth”而忽略的历史采样无法从数据库补回，只能从修复生效后重新准确累计。

机器重装后，vnStat 无法恢复重装前的流量。若配置的周期起点早于现有历史，脚本会明确显示可用历史起点，并要求选择：

```text
1) 我已了解，按现有 vnStat 历史继续
0) 取消配置，不保存本次修改
```

选择继续后，脚本会正常统计现有历史并执行规则，但实际已用流量可能偏低；主页会显示“周期早段流量未计入”。未确认或旧配置没有 `ALLOW_PARTIAL_HISTORY=true` 时仍采用严格模式，历史不完整就跳过限制判断。

## 5) 限制执行与安全宽限

保存配置时，如果现有可统计流量已经达到执行阈值，脚本不会突然限速或关机，而是要求选择：

```text
1) 宽限一段时间后再执行（推荐，默认 10 分钟）
2) 立即执行
3) 仅监控，暂停执行限制
```

暂停不会停止 vnStat 统计或监控 cron。可进入 `3) 机器限速管理 (启用/禁用)`，再选择 `6) 限制执行控制 (立即/宽限/暂停)` 恢复执行、重新宽限或继续暂停。

TC 模式还包含独立的“开机限速宽限”，配置时可设为 `0-1440` 分钟，默认 `10` 分钟。系统刚启动且本脚本的 TC 规则尚未生效时，即使流量已经超额，也会等宽限结束再限速；设为 `0` 才会在下一次监控任务（通常一分钟内）立即处理。更新前的版本没有此保护，超额后通常会在开机后的第一次 cron 检查直接限速。

关机模式会保存触发周期和 boot ID。因流量超额关机后，如果用户在同一流量周期内手动开机，脚本会自动切换为“关机后重启保护，已暂停”，不会每分钟再次关机。用户可在机器限速管理的限制执行控制中手动恢复；若未恢复，进入下一个流量周期时会自动解除这项重启保护。

## 6) 流量计费口径

vnStat 已分别记录每个接口实际接收的 `RX` 和发送的 `TX` 字节数，本脚本不会额外复制规则或重复乘权：

- 只计算出站：`ΣTX`
- 只计算进站：`ΣRX`
- 进站与出站都计算：`ΣRX + ΣTX`
- 进出取大：`max(ΣRX, ΣTX)`，按整个统计周期的两个方向总量取大，不是逐日取大后再累加。

页面显示、阈值判断和 Telegram 状态都使用同一个计算结果。`GB` 与 `GiB` 只影响字节换算，不改变 RX/TX 的计费公式；旧配置没有 `TRAFFIC_UNIT` 时继续按 `GiB` 处理。

## 7) 卸载

推荐使用:

```bash
sudo ntc --uninstall
```

也可以直接运行主脚本:

```bash
sudo bash /etc/trafficcop-lite/trafficcop-lite.sh --uninstall
```

卸载行为:

- 删除 `/etc/trafficcop-lite`。
- 删除 `/usr/local/bin/ntc` 快捷命令（仅当它指向本脚本时）。
- 清理旧版 `/usr/local/bin/ncl` 和 `/usr/local/bin/tc` 快捷命令（仅当它们指向本脚本时）。
- 清理独立版 crontab 条目。
- 删除目录前会按当前配置检查 TC 限速规则和计划关机，并要求确认后处理。
- TC、计划关机或 crontab 清理失败时会中止删除目录，避免留下失去状态记录的限速或定时任务。
- 默认备份配置和日志到 `/etc/trafficcop-lite-backup-时间戳/`。
- 不卸载系统依赖包。
- 不删除上游默认目录 `/root/TrafficCop`。
- 不自动恢复 vnStat 全局配置，避免覆盖安装后用户自行调整的内容；选择备份时，原始 vnStat 配置副本会随工作目录一起保存。

## 8) 目录说明

安装后的默认目录:

```text
/etc/trafficcop-lite/
├── trafficcop-lite.sh
├── trafficcop-lite-monitor.sh
├── trafficcop-lite-telegram.sh
├── trafficcop-lite-machine-limit.sh
├── traffic_monitor_config.txt
├── tg_notifier_config.txt
├── traffic_monitor.log
├── tg_notifier_cron.log
├── traffic_monitor.lock
├── tg_notifier.lock
├── tc_limit_state
├── enforcement_state
├── shutdown_limit_state
├── last_reset_period
├── current_traffic_state
├── vnstat_daily_coverage_start
├── vnstat_config_path
├── last_traffic_notification
├── last_daily_report
├── vnstat.conf.before-trafficcop-lite[.N]
└── vnstat.conf.before-trafficcop-lite[.N].source-path
```

快捷命令:

```text
/usr/local/bin/ntc -> /etc/trafficcop-lite/trafficcop-lite.sh
```

注意：Linux 的系统限速命令叫 `tc`，通常位于 `/usr/sbin/tc`。本项目快捷命令使用 `ntc`，脚本内部也会优先使用系统原始路径调用 `tc`，避免命令名冲突。如果你需要手动执行系统 `tc`，建议使用完整路径，例如:

```bash
sudo /usr/sbin/tc qdisc show
```

## 注意事项

- 脚本会安装依赖、写入 crontab，并可能配置 TC 限速或关机模式，请先在测试机确认。
- TC 模式会用 `/etc/trafficcop-lite/tc_limit_state` 记录自身管理的整机上限。NTC 直接创建或更新统一 HTB；Dog 存在时保留其端口类和过滤器，不存在时也可独立工作。
- NTC 与 Dog 各自使用自己的 root crontab 锁；只有修改同一内核 TC 层级时共用 `/run/lock/traffic-tools-tc.lock`。
- 外部程序重建 root qdisc 后，主页会报告外部/未知 TC 冲突，普通监控 cron 仍会拒绝覆盖。主菜单 `9` 可在明确确认后删除冲突并只重建 Dog/NTC；不会保留任何第三方规则。
- 可选的 `traffic-tools-tc-recovery.service` 只在开机网络就绪后执行一次；它只接受默认/缺失 qdisc 或已识别的 Dog/NTC 统一层级，遇到外部或未知 root qdisc 会拒绝自动接管，须从主菜单 `9` 明确确认。运行期间若 root qdisc 再次被其他程序覆盖，也需要用户再次手动恢复；建议关闭其他 TC 管理服务。
- `enforcement_state` 只记录临时宽限或暂停状态；`shutdown_limit_state` 只记录本脚本计划的流量关机及其 boot ID。
- 若状态记录与当前 qdisc 不一致，脚本会按外部规则处理并停止自动覆盖。
- 停止服务/卸载时，未标记的 TC 规则和计划关机会要求确认后才处理。
- Telegram cron 日志默认保留最近 2000 行；如需详细调试，可临时设置 `TG_DEBUG=true`。
- 流量监控日志默认保留最近 5000 行，可通过 `LOG_MAX_LINES` 调整。
- Telegram 报告时区可独立配置；旧配置默认使用 `Asia/Shanghai`。时区名称必须对应系统 `/usr/share/zoneinfo` 中的有效文件，因此精简系统需要安装 `tzdata`。到达设定时间后当天只发送一次，任务短暂中断时会在恢复后补发。
- 需要 vnStat 2.x 或更高版本。脚本兼容 `vnstat --showconfig` 中带分号或井号的默认配置项，会管理 `SaveInterval`、必要时的 `UpdateInterval`、当前接口 `MaxBW`，并按周期需求管理 `DailyDays`；`VNSTAT_MAX_BANDWIDTH=0` 为默认值并表示关闭异常速率检查，非零值必须在 `1-50000` 范围内；vnStat 2.0–2.8 还使用上述兼容设置。守护进程未显式指定 `--config` 时，只有运行中的 `vnstatd`、系统 `vnstatd` 命令和 `vnstat` 客户端能证明来自同一安装前缀，脚本才采用客户端报告的默认配置。每个实际配置路径首次变更前都会单独保留原配置备份，卸载时不会自动恢复全局 vnStat 配置。
- Debian/Ubuntu、RHEL 系、Alpine 和 Arch 系会按已识别的包管理器尝试安装依赖；无法自动启动 cron 或 vnStat 服务时会给出明确提示，请按系统服务管理方式确认其已运行。
- 网络受限时，优先使用带 `v6.gh-proxy.org` 的命令。

## 开发验证

仓库内置失败路径回归测试，并在 GitHub Actions 中执行语法检查、ShellCheck 和回归测试：

```bash
bash -n trafficcop-lite.sh trafficcop-lite-monitor.sh trafficcop-lite-telegram.sh trafficcop-lite-machine-limit.sh tests/regression.sh
shellcheck trafficcop-lite.sh trafficcop-lite-monitor.sh trafficcop-lite-telegram.sh trafficcop-lite-machine-limit.sh tests/regression.sh
bash tests/regression.sh
```
