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
32. Dog 已建立并可验证归属的 `ifb0` 会与物理网卡在同一 TC 锁和事务内同步 `1:1`/`1:30` 父速率。撤销、宽限、暂停、周期重置、停止和卸载会同时解除两侧整机上限，保留 Dog 的端口 class/filter 和 ingress redirect；IFB 更新或状态提交/删除失败会恢复修改前两侧速率。
33. NTC 自检和恢复会核对已协作 IFB 的父速率、端口 class/filter 引用及 IPv4/IPv6 redirect。只有父速率漂移时可原地修复；配置、设备类型或归属无法验证时拒绝写入，应先通过共享恢复入口修复 Dog。NTC 单独安装仍只管理出向，不创建 IFB。
34. Dog 配置中的逗号组在首次实际下发前可能没有 `class_id`；NTC 不凭空创建该 class。缺失、`null` 或空字符串的 class 字段不会导致速率/mark 列错位；已存在的 Dog class/filter 必须全部能由可信配置解释，未知对象或归属不明时保持失败关闭。
35. 清除、宽限、暂停、停止和卸载允许 Dog 已经删除的端口 class 缺失；IFB 上现存端口 class 仍须匹配配置速率和父类，并校验 filter 引用、双栈 redirect 及默认类。现存 class 的速率错误不会按缺失跳过，apply 和自检仍要求配置中的已物化 class 完整。如果 IFB 已删除且物理 root 已回到默认状态，只清理 NTC 自己的残留状态。
36. 两个项目可先后独立安装；NTC 单独运行或仅有尚未下发的 Dog 配置时只管理出向 HTB，不探测或创建未知 `ifb0`。首次登记 `IFB_INTERFACE=ifb0` 必须由可验证的 Dog owner/config、设备类型、class/filter 和 IPv4/IPv6 redirect 共同证明；登记后可在有效 NTC 状态和 Dog 配置范围内处理 Dog 已删除最后一个端口及 owner 标记的清理。

### 1.2.0（适配 Port Traffic Dog 2.0）

37. 识别 Dog 2.0 的配置格式（schema 2）：端口限速类改从 Dog 写入的类清单 `/etc/port-traffic-dog/tc-interop.json`（`traffic-tools-dog-classes-v1`）读取，逐项核对文件权限、class 编号（`1:4001` 起）、fw mark 公式与掩码，任何一项不符都失败关闭；Dog 1.5.x 配置仍按原 `.ports` 推导。无法识别的配置（包括有 `.monitors` 却没有 `schema`）一律不碰 TC。Dog 2.0 设置限速前会检查已安装的 NTC 是否认识该清单，旧版 NTC 需先升级到 1.2.0。
38. 手动恢复（`--tc-recover-owned --manual` / 菜单 `9`）删除 `htb 1:` root 前，若其中还有 `1:1`/`1:30` 以外的类或任何过滤器（即仍有 Dog 等其他使用者），拒绝删除，不再因 Dog 配置/清单缺失而误删端口限速。
39. 停止、卸载和禁用机器限速时不再在加锁前 `pkill -f`；持有监控锁即可排除正在运行的 `--run`，Telegram 只按精确命令行结束本项目的 `-cron` 进程。
40. 更新与补装组件改为按仓库根目录 `SHA256SUMS` 逐个校验，缺失或不符即取消且不留临时文件（见“更新脚本”）。
41. 监控每轮写入 `monitor_health`（ok/error/disabled 与最后一条失败原因）。Telegram 在监控报错或超过 10 分钟未运行时提醒（6 小时限频，恢复后发一次“已恢复”）；监控异常导致状态不可用时，日报改发一次“状态不可用”说明，不再静默。
42. 手动 TC 恢复读取配置后先对齐 vnStat 时区，周期判断与监控一致。

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

- `--install`: 安装前检查全部组件所需命令，仅在确认后安装缺失项，再安装/更新组件和快捷命令；使用 `--install --yes` 可明确允许非交互安装依赖。单文件入口会同步刷新整套组件。
- `--update`: 从仓库更新脚本文件，不覆盖配置和日志。
- `--logs`: 查看日志。操作审计会在真实操作完成后记录中文结果；查看日志、自检和状态查询不会为了“有记录”而修改安装目录。
- 操作审计文件为 `/etc/trafficcop-lite/operations.log`，默认 `0700` 目录、`0600` 文件，单文件达到 1 MiB 后轮转并保留 3 份。记录包含自然语言动作、成功/失败/保持不变结果以及 `EVENT`/`RESULT` 字段，不记录配置内容、Token、通知 URL 或用户输入。
- `--stop`: 停止独立版监控和通知任务。
- `--config`: 查看配置。
- `--self-check [INTERFACE]` / `--tc-self-check [INTERFACE]`: 只读检查统一 HTB、状态归属和已协作的 Dog IFB；不创建目录、不修正权限、不写监控日志。
- `--recover-tc --manual`: 显式调用共享恢复入口；它可能删除当前 root qdisc，通常应优先在主菜单 `9` 阅读提示并确认。
- `--uninstall`: 卸载 TrafficCop Lite。

### 依赖管理

主菜单 `10` 显示依赖当前状态，并提供检测、按需安装、查看账本与卸载。也可以直接运行主脚本的独立入口：

```bash
sudo bash trafficcop-lite.sh --dependencies check
sudo bash trafficcop-lite.sh --dependencies install
sudo bash trafficcop-lite.sh --dependencies install --yes
sudo bash trafficcop-lite.sh --dependencies owned
sudo bash trafficcop-lite.sh --dependencies remove
sudo bash trafficcop-lite.sh --dependencies remove --all
```

`check` 和 `owned` 只读；检测到包已安装但命令或 HTTPS 证书文件不可用时会报异常而不是假装安装成功。安装会显示缺失项及 APT 模拟计划，并仅将安装前没有、计划中存在且安装后实际安装的包（含传递依赖）记录到 `/var/lib/trafficcop-lite/dependencies/installed-packages`。部分安装失败也会记录实际新增包。这个目录独立于配置目录，卸载 NTC 不会删除它；`DEPENDENCY_STATE_DIR` 可显式指定另一绝对路径。

先完整卸载 NTC，并确认没有 NTC 脚本、进程或 crontab 任务，才能单独卸载依赖。默认仅卸载账本里的新增包；`--all` 明确扩大到本项目相关的原有包，须谨慎确认。系统基础/Essential/Protected 包、Dog 仍需要的包及这些包的已安装依赖闭包会保留；模拟计划中范围外的级联删除会被拒绝，不执行 `autoremove` 或 `purge`。`--yes` 可跳过依赖安装或卸载确认，但不会跳过安全检查。脚本的 `--uninstall` 本身保留所有系统包；交互卸载完成后可另行进入依赖菜单。卸载后可继续使用下载的 `trafficcop-lite.sh` 执行依赖命令。

完整归属账本和自动依赖卸载仅支持 Debian/Ubuntu 的 APT。dnf、yum、apk、pacman 保留按缺失命令安装及安装后复检，但不建立 APT 账本，也不支持自动依赖卸载。若安装中断后出现 `pending-before` 或 `pending-plan`，后续安装和卸载会停止；请先检查事务快照与系统包状态并人工处理，不要盲目认领或删除记录。

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
10) 依赖检测、安装与卸载
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
- 先下载仓库根目录的 `SHA256SUMS`（优先 `RAW_BASE` 直连；直连失败才用所选镜像线路，并提示镜像只能防传输损坏、不能防镜像本身被篡改），四个脚本逐个比对哈希，缺失或不符即取消。
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
- IFB 协作首次使用 Dog 的网卡/机器归属标记、可信配置、`ifb0` 设备类型及现有 class/filter/双栈 redirect 验证运行态；同步成功后在 `tc_limit_state` 中记录可选的 `IFB_INTERFACE=ifb0`。已登记状态可在 Dog 删除最后一个端口和 owner 标记后保留清理范围。NTC 不创建、接管未知 IFB，也不删除 Dog 的入向对象。其余无法验证的归属或链路会保留原规则和状态并报错，须先修复 Dog。
- NTC 与 Dog 各自使用自己的 root crontab 锁；只有修改同一内核 TC 层级时共用 `/run/lock/traffic-tools-tc.lock`。
- 外部程序重建 root qdisc 后，主页会报告外部/未知 TC 冲突，普通监控 cron 仍会拒绝覆盖。主菜单 `9` 可在明确确认后删除冲突并只重建 Dog/NTC；不会保留任何第三方规则。
- 可选的 `traffic-tools-tc-recovery.service` 只在开机网络就绪后执行一次；它只接受默认/缺失 qdisc 或已识别的 Dog/NTC 统一层级，遇到外部或未知 root qdisc 会拒绝自动接管，须从主菜单 `9` 明确确认。运行期间若 root qdisc 再次被其他程序覆盖，也需要用户再次手动恢复；建议关闭其他 TC 管理服务。
- `enforcement_state` 只记录临时宽限或暂停状态；`shutdown_limit_state` 只记录本脚本计划的流量关机及其 boot ID。
- 若状态记录与当前 qdisc 不一致，脚本会按外部规则处理并停止自动覆盖。
- 停止服务/卸载时，未标记的 TC 规则和计划关机会要求确认后才处理。
- NTC 操作审计默认保留最近 1 MiB × 4 个文件；日志写入失败只提示 `NTC 操作日志写入失败`，不改变已经确定的安装、更新、限速或恢复结果。
- Telegram cron 日志默认保留最近 2000 行；如需详细调试，可临时设置 `TG_DEBUG=true`。
- 流量监控日志默认保留最近 5000 行，可通过 `LOG_MAX_LINES` 调整。
- 需要 vnStat 2.x 或更高版本。脚本兼容 `vnstat --showconfig` 中带分号或井号的默认配置项，会管理 `SaveInterval`、必要时的 `UpdateInterval`、当前接口 `MaxBW`，并按周期需求管理 `DailyDays`；`VNSTAT_MAX_BANDWIDTH=0` 为默认值并表示关闭异常速率检查，非零值必须在 `1-50000` 范围内；vnStat 2.0–2.8 还使用上述兼容设置。守护进程未显式指定 `--config` 时，只有运行中的 `vnstatd`、系统 `vnstatd` 命令和 `vnstat` 客户端能证明来自同一安装前缀，脚本才采用客户端报告的默认配置。每个实际配置路径首次变更前都会单独保留原配置备份，卸载时不会自动恢复全局 vnStat 配置。
- Debian/Ubuntu、RHEL 系、Alpine 和 Arch 系会按已识别的包管理器尝试安装依赖；无法自动启动 cron 或 vnStat 服务时会给出明确提示，请按系统服务管理方式确认其已运行。
- 网络受限时，优先使用带 `v6.gh-proxy.org` 的命令。
- 不要与上游原版 TrafficCop 的 TC 模式同时运行：原版在流量正常时每分钟执行 `tc qdisc del dev <网卡> root`，会清掉 NTC 与 Dog 的整套 HTB（实测 Debian 13 主机上任何 HTB 都保持不到 60 秒）。迁移到 NTC 后请移除原版的 `traffic_monitor.sh --run` 定时任务。
- 与 Dog 2.0 共存需要 NTC 1.2.0+；Dog 1.5.x 与 NTC 1.2.0 仍可共存。

## 开发验证

仓库内置失败路径回归测试，并在 GitHub Actions 中执行语法检查、ShellCheck 和回归测试：

```bash
for script in trafficcop-lite*.sh tests/*.sh; do bash -n "$script" || exit; done
shellcheck trafficcop-lite.sh trafficcop-lite-monitor.sh trafficcop-lite-telegram.sh trafficcop-lite-machine-limit.sh tests/regression.sh
sudo bash tests/regression.sh          # 非 root 时调用主脚本 CLI 的 2 条用例记为 skip
bash tests/dependencies-regression.sh
```

修改任何产品脚本后必须运行 `tools/update-sums.sh` 重新生成 `SHA256SUMS` 并与脚本一起提交；`tests/regression.sh` 会核对两者一致，否则已发布的 `ntc --update` 会拒绝新脚本。

真实内核集成测试需要 Dog 2.x 主脚本，只应在可丢弃的测试机上运行（在网络命名空间里创建 ifb/htb/fw 仍会让内核加载全局模块）：

```bash
sudo DOG_SCRIPT=/path/to/port-traffic-dog.sh bash tests/integration-netns.sh
```

`tests/regression.sh` 保留原有回归，并加载 `tests/ifb-regression.sh` 的独立 mock 用例，覆盖 IFB 部分更新失败、两侧回滚、状态提交/删除失败、现存子类速率错误拒绝清理、已删子类仅允许清理、NTC 先安装、未物化组和空字段解析、未知 IFB 零写入和主 CLI 只读权限检查。测试将临时文件放在私有 `mktemp` 目录，支持通过 `TMPDIR` 指定位置；mock 回归不执行真实 TC 修改。`tests/integration-netns.sh` 是单独的真实内核集成入口，不由 mock 回归自动执行。
`tests/dependencies-regression.sh` 在工作区私有临时目录中使用假 APT/dpkg 验证依赖 CLI 和独立监控安装，不修改主机软件包；账本权限测试需要 root，非 root 会显示 SKIP。此测试为单独入口，不改变现有 CI workflow。

单端口分类校验按 IPv4/IPv6 协议分别查询，再验证 TCP/UDP 源/目标端口规则，兼容旧 iproute2 在混合 `fw`/u32/flower 时产生非法全量 JSON 的情况。`tests/filter-json-regression.sh` 保留旧版实际错误格式，并检查缺失规则或查询失败仍被拒绝。
