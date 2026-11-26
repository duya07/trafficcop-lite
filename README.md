# trafficcop-lite（NTC）

整机流量监控：用 vnStat 按月、季或年统计本机流量，超额后整机限速或关机，可选 Telegram 日报与用量预警。命令名 `ntc`。

可与 [Port Traffic Dog](https://github.com/duya07/port-traffic-dog)（端口流量监控与限速）同时安装：两者共用同一套 TC 层级，互不覆盖。

```text
 TrafficCop Lite v2.0.0 · my-vps
 ────────────────────────────────────────────────────────────────────────────
  ● 监控中  eth0 · 出+入 · 每月 1 日重置，还剩 10 天
  本期已用  123.4 GB / 500 GB  ██░░░░░░░░  24%
  超额处理  达到 499 GB 后整机限速 50 kbit/s
  本期预计  约 185.1 GB（按本期日均 6.17 GB）
  Telegram  已启用，每日 08:00 日报；预警 80%、90%
 ────────────────────────────────────────────────────────────────────────────
   流量监控             系统维护
    1. 状态详情          6. 查看日志
    2. 修改监控配置      7. 更新 NTC
    3. 限制执行          8. 依赖管理
    4. Telegram 通知     9. TC 冲突处理 / 自动恢复
    5. 立即检查一次     10. 卸载 NTC
 ────────────────────────────────────────────────────────────────────────────
    0. 退出
 请选择 [0-10]:
```

终端较窄时菜单自动改为单列；设置 `NO_COLOR=1` 或 `TERM=dumb` 时不输出颜色。

## 参考来源

本仓库从 TrafficCop 中拆出“机器总流量限制”相关能力，去掉端口流量限制入口，并增加年度周期起始月份选择。

- 上游仓库: <https://github.com/ypq123456789/TrafficCop>
- 上游管理脚本: <https://github.com/ypq123456789/TrafficCop/blob/main/trafficcop-manager.sh>
- 上游流量监控脚本: <https://github.com/ypq123456789/TrafficCop/blob/main/trafficcop.sh>
- 上游 Telegram 通知脚本: <https://github.com/ypq123456789/TrafficCop/blob/main/tg_notifier.sh>
- 上游机器限速管理脚本: <https://github.com/ypq123456789/TrafficCop/blob/main/machine_limit_manager.sh>

## 2.0 有什么变化

- **新界面**：主菜单改为仪表盘加两组选项，一眼看到状态、本期用量、执行阈值和本期预计；所有子菜单统一样式，最底下都是“0. 返回”；输入结束（Ctrl-D）一律视为取消。
- **配置向导重做**：共 7 项，回车保留当前值；先问完、再预览本期用量，显示摘要后确认才保存；保存失败会整体回滚并说明是哪一步失败，成功提示只在全部完成后出现。
- **命令行**：`ntc status [--json]`、`ntc check`、`ntc config set …`、`ntc pause|resume|grace|enable|disable`、`ntc telegram test|report` 等子命令，旧参数仍可用；未知命令报错并以退出码 2 结束，不再悄悄打开菜单。
- **本期预测**：按本期日均推算期末用量；预计会超过阈值时给出预计到达的日期。仪表盘、状态详情和 Telegram 日报共用同一套计算。
- **Telegram**：新增用量预警（默认 80%、90%，每期每档只推一次，可修改或关闭）；日报加入百分比、阈值、本期起止、剩余天数和预测；设置完成后可发测试消息；发送失败会说明原因（Token 无效、会话不对、被限流、网络不通等）。
- **日志只记事件**：监控日志只记录状态变化（限速与解除、宽限、新周期、错误与恢复等），正常运行时每小时一行心跳，5000 行可以覆盖几个月。
- **限制执行**：原“机器限速管理”与“限制执行控制”两层菜单合并为一层；宽限先问分钟数，再解除限速。
- **启动更快**：主菜单只读状态文件，不再每次跑 TC 自检、等锁、做依赖检查和 daemon-reload，也不再每次写“安装成功”的审计记录。
- **修复**：卸载和 `--stop` 先解除限速、取消关机，最后才删定时任务（中途失败时监控照常运行），系统里没有计划关机时不再询问是否取消，也不再误报“已取消”；停用流量监控同样改为全有或全无，中途失败会把定时任务加回去，不再留下没人解除的限速；systemd 250 以下（如 Debian 11）也能认出 logind 安排的计划关机，关机模式不再每分钟重新安排一次关机，暂停和停用也不再误删 NTC 的关机记录；更新时共享恢复文件写不进去只警告；Telegram 定时任务的写入结果如实报告；开机自动恢复不再在开机宽限期内恢复整机上限。

## 从 1.x 升级

```bash
sudo ntc --update
```

或在菜单里选“更新”。1.2.x 自带的更新器能识别 2.0 的四个脚本（限制执行组件的版本号仍按 `v2.13` 比较），不会当成降级。

- 配置文件、状态文件和定时任务的格式都不变，**不需要重新配置**。
- 已配置 Telegram 的机器，升级后会在本期用量达到 80%、90% 时各推送一次预警。不需要的话，在“Telegram 通知 → 阈值预警档位”里填 `off`。
- `traffic_monitor.log` 不再每分钟写入，原有内容保留。“限制执行”和状态页改看 `monitor_health` 判断监控是否在运行。
- 与 Port Traffic Dog 2.1 共存不需要任何改动。

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

`--install` 先检查全部组件所需命令，仅在确认后安装缺失项，再安装组件和快捷命令；`--install --yes` 明确允许非交互安装依赖。装好后在菜单里选 `2` 开始配置（约 1 分钟）。

## 2) 使用

### 主菜单

```bash
sudo ntc
```

| 选项 | 作用 |
|---|---|
| 1 状态详情 | 与 `ntc status` 相同：用量、阈值、预测、执行状态、定时任务、Telegram、TC、与 Dog 共存情况 |
| 2 修改监控配置 | 尚未配置时直接进入向导；已配置时可“修改配置”或设置“vnStat 异常速率上限（高级）” |
| 3 限制执行 | 宽限、暂停、恢复、立即解除当前限速、开机宽限、停用/启用流量监控、从停用前的备份恢复、详细状态 |
| 4 Telegram 通知 | 机器人、日报时间、预警档位、测试消息、立即发送日报、停用/启用 |
| 5 立即检查一次 | 与每分钟的定时检查相同，结果打印成一行 |
| 6 查看日志 | 事件日志、Telegram 通知日志、操作记录、NTC 定时任务 |
| 7 更新 NTC | 直连或国内镜像；更新后自动载入新版菜单 |
| 8 依赖管理 | 检测、按需安装、查看账本与卸载（见下文） |
| 9 TC 冲突处理 / 自动恢复 | 检测并按需重建 Dog/NTC 规则，开关共享的开机自动恢复 |
| 10 卸载 NTC | 需输入 `UNINSTALL` 确认 |

### 命令行

```text
用法: sudo ntc [命令]

  （无命令）                 打开菜单
  status [--json]            状态：用量、阈值、预测、执行状态、TC、定时任务、Telegram
  check                      立即检查一次（与每分钟的定时检查相同）
  config                     配置向导
  config show                显示当前配置
  config set 选项… [--yes]   不进菜单修改配置（sudo ntc config set --help 查看选项）
  pause | resume             暂停 / 恢复限制（流量照常统计）
  grace <分钟>               宽限一段时间，期间只统计、不限速
  enable | disable           启用 / 停用流量监控
  logs [events|telegram|operations]   查看日志
  telegram test|report       发送测试消息 / 立即发送一次日报
  update [--mirror]          更新 NTC（--mirror 走国内镜像）
  uninstall                  卸载 NTC
  self-check [网卡]          只读检查 TC 状态
  version                    显示各组件版本
  help                       显示本帮助

旧参数仍可用：--install [--yes]、--update、--uninstall、--stop、--logs [类型]、--config、
--self-check [网卡]、--recover-tc [--auto|--manual]、
--dependencies check|install [--yes]|remove [--all] [--yes]|owned
```

- 参数不对（未知命令、缺值、越界、多余参数）时打印用法到标准错误，退出码 `2`；未配置时 `check`、`config show` 等以退出码 `1` 说明原因。
- 非交互命令不读标准输入、不等待确认，适合脚本和定时任务。
- `status`、`self-check`、`logs`、`version` 只读：不创建目录、不修正权限、不写日志。
- `--stop`：停止监控和通知（先解除 NTC 的限速、取消 NTC 安排的计划关机，最后删定时任务），配置和状态文件保留；无法确认归属的计划关机不会取消，只会提示。
- `--recover-tc --manual`：显式调用共享恢复入口，它可能删除当前 root qdisc，通常应先在菜单 `9` 阅读提示并确认。

### 状态与 JSON

```bash
sudo ntc status
sudo ntc status --json
```

`--json` 输出带类型的字段（数字是数字、布尔是布尔），便于脚本读取。全部字段：`version`、`generated_epoch`、`configured`、`config_error`、`disabled`、`status{level,label,detail,state}`、`interface`、`mode`、`period{type,start_day,start_month,start,end,days_left}`、`unit`、`usage`、`usage_source`、`limit`、`tolerance`、`threshold`、`percent`、`forecast{days_elapsed,avg_per_day,projected,reached,reach_epoch}`、`action{type,speed_kbit,boot_grace_minutes}`、`enforcement{mode,until_epoch,reason}`、`health{state,text}`、`cron{readable,monitor,telegram}`、`telegram{state,daily_report_time,warn_percents}`、`tc{root_qdisc,ntc_limit_active,dog_classes}`、`tc_auto_recovery`、`vnstat{daemon,max_bandwidth_mbit}`、`dog_installed`、`partial_history`。

状态页的用量取 10 分钟内同一周期的状态文件；没有时只读调用一次 vnStat，不会触发限速。

### 依赖管理

主菜单 `8` 显示依赖当前状态，并提供检测、按需安装、查看账本与卸载。也可以直接运行主脚本的独立入口：

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

## 3) 配置流量监控

### 配置向导

菜单 `2` 或 `sudo ntc config`，共 7 项：

| 项 | 内容 |
|---|---|
| 1/7 网卡 | 默认是当前配置或自动检测到的默认路由网卡；输错会列出可用网卡 |
| 2/7 统计方向 | 出站 / 入站 / 出+入 / 出入取较大 |
| 3/7 重置周期 | 每月 / 每季度（1/4/7/10 月）/ 每年；再问每期从几号开始（没有这一天的月份按月末算），每年还要问起始月份 |
| 4/7 流量单位 | GB（十进制）/ GiB（二进制） |
| 5/7 每期流量限额 | 按所选单位 |
| 6/7 提前量 | 用量达到“限额 − 提前量”就执行 |
| 7/7 达到阈值后 | 整机限速（再问限速 kbit/s 和开机宽限分钟数）/ 关机 |

问完后显示摘要，确认才保存：

```text
 确认配置
 ────────────────────────────────────────────────────────────────────────────
  网卡      eth0
  统计方向  出+入
  重置周期  每月 1 日重置
  每期限额  500 GB
  提前量    1 GB（用量达到 499 GB 时执行）
  超额处理  整机限速 50 kbit/s
  开机宽限  开机后 10 分钟内不限速
  异常速率  vnStat 不检查（0）
  本期已用  123.4 GB，未达到阈值
 保存？ [Y/n]:
```

- 每项方括号里是当前值（首次配置时是推荐值），直接回车保留；任何一步按 Ctrl-D 都会取消，原配置不变。
- 问完后先预览本期已用流量，显示摘要，确认“保存？”后才写入；写入配置、执行策略、vnStat 设置是同一个事务，任一步失败都会整体恢复，并说明是哪一步失败。
- 保存时如果本期用量已经达到新的执行阈值，会先问这次怎么处理：先宽限一段时间（推荐，默认 10 分钟）、立即限速/关机，或只统计、暂停执行（之后在“限制执行”里恢复）。
- 保存配置会先解除 NTC 当前的整机限速（与 1.x 相同）；如果仍然超额，下一分钟的检查会按新配置重新处理。
- `GB` 为十进制（1000³ 字节，多数服务商这样计费），`GiB` 为二进制（1024³ 字节）。旧配置没有 `TRAFFIC_UNIT` 时继续按 `GiB` 计算。
- 提前量（旧版叫“容错范围”）必须大于等于 `0` 且小于限额；执行阈值 = 限额 − 提前量。
- 流量监控已停用时不能修改配置，请先在“限制执行”里启用（防止改配置时悄悄重新启用）。

### 非交互配置

```text
用法：ntc config set 参数… [--yes]
  --interface 网卡                    --mode out|in|total|max（出站/入站/出+入/取较大）
  --period monthly|quarterly|yearly   --start-day 1-31    --start-month 1-12（仅每年）
  --unit GB|GiB                       --limit 数值        --tolerance 数值（提前量）
  --action tc|shutdown                --speed kbit/s（1-10000000）
  --boot-grace 分钟（0-1440）          --vnstat-max-bw Mbit/s（0-50000，0 = 不检查）
  --when-over grace:分钟|now|monitor  保存时用量已达到阈值的处理（默认 grace:10）
  --allow-partial-history             vnStat 历史不足以覆盖周期起点时仍然保存
  --yes                               不再确认（vnStat 日数据保留期不足时自动调整）
未给出的项保持当前值；首次配置至少需要 --limit。参数也可写成 --limit=500。
示例：ntc config set --limit 500 --tolerance 1 --speed 50 --yes
```

`config set` 与向导使用同一套校验、摘要和事务。参数错误时退出码 `2`，不改配置、不开始 vnStat 事务；没有 `--yes` 时读到输入结束视为不保存。只改 `--vnstat-max-bw` 时不重新评估限速，正在进行的宽限、暂停或限速保持不变。

### vnStat 设置与历史

季度和年度统计依赖 vnStat 的每日历史；脚本可调整 `DailyDays`，并按实际配置文件的规范路径分别保留原配置备份（首个通常为 `/etc/trafficcop-lite/vnstat.conf.before-trafficcop-lite`，切换路径后使用编号备份及对应 `.source-path` 标记）。`DailyDays=-1` 会按无限保留处理，`TrafficlessEntries=0` 产生的无流量日期缺口不会被误判为历史丢失。

TrafficCop Lite 会保留 vnStat 配置中的其他自定义项，并幂等设置 `SaveInterval 1`。当 `UpdateInterval` 大于 60 秒时才将其收紧到 60 秒，以满足 vnStat 的保存间隔约束。“修改监控配置 → vnStat 异常速率上限（高级）”可设置 `VNSTAT_MAX_BANDWIDTH`：默认 `0` 表示关闭 vnStat 异常速率检查，也可以输入 `1-50000` 作为 Mbit/s 上限。vnStat 2.9 及以上使用当前网卡的 `MaxBW<接口名>`；2.0–2.8 兼容模式还会设置 `BandwidthDetection 0` 和全局 `MaxBandwidth`。关闭检查可避免高速云网卡被过低上限丢弃采样，但也会失去 vnStat 对异常接口计数跳变的保护；如需该保护，请按机器合理峰值设置非零上限。

`SaveInterval 1` 会让数据库通常每分钟落盘一次，相比常见的 5 分钟默认值会增加少量磁盘写入，但缩短崩溃或断电时未保存流量的窗口。统计仍不是秒级实时值；正常可有约 1–3 分钟延迟。若 `vnstatd` 未运行、数据库因磁盘满等原因长期未更新，或 JSON API 版本、接口名、日期、每日 `rx/tx` 字段无效，本轮判断会失败关闭：不下发新限制，也不清除已有规则。vnStat 已经因“实际速率高于 MaxBandwidth”而忽略的历史采样无法从数据库补回，只能从修复生效后重新准确累计。

机器重装后，vnStat 无法恢复重装前的流量。若配置的周期起点早于现有历史，向导会显示可用历史起点，并要求确认“按现有 vnStat 历史继续”或取消。选择继续后，脚本会正常统计现有历史并执行规则，但实际已用流量可能偏低；仪表盘和状态页会提示“本期 vnStat 历史不完整”。未确认或旧配置没有 `ALLOW_PARTIAL_HISTORY=true` 时仍采用严格模式，历史不完整就跳过限制判断。

## 4) 限制执行

菜单 `3`：

```text
 限制执行 · 按配置执行
 ────────────────────────────────────────────────────────────────────────────
  总体状态  ● 监控中
  执行方式  整机限速 50 kbit/s
  开机宽限  10 分钟

   临时调整                设置
    1. 宽限一段时间         5. 开机宽限
    2. 暂停限制             6. 停用流量监控
    3. 恢复限制             7. 启用流量监控
    4. 立即解除当前限速     8. 从停用前的备份恢复配置
                            9. 详细状态
 ────────────────────────────────────────────────────────────────────────────
    0. 返回
```

对应的命令行：`sudo ntc pause`、`sudo ntc resume`、`sudo ntc grace 30`、`sudo ntc enable`、`sudo ntc disable`（组件本身另有 `--boot-grace 分钟`、`--clear-tc`、`--status`）。

- **宽限**：先问分钟数（1–1440，默认 10），再解除当前限速；期间只统计、不限速，到时自动恢复执行。
- **暂停**：一直只统计、不执行，直到选择“恢复限制”。不会停止 vnStat 统计和监控定时任务。
- **立即解除当前限速**：只解除这一次；如果仍然超额，下一分钟的检查会再次限速。想持续不限速请用宽限或暂停。
- **停用流量监控**：先删除每分钟的检查任务，删不掉就什么都不改；再解除 NTC 的限速、处理 NTC 安排的关机、另存一份停用前的配置备份并写上 `DISABLED=true`。中途任何一步失败，都会把检查任务加回去、不标记停用，监控照常运行。系统里有计划关机、NTC 却没有它的记录时（例如旧版本安排的），菜单会先问是否一并取消（默认不取消），命令行 `ntc disable` 不取消、只如实提示。停用后状态页显示“已停用”。
- **启用流量监控**：先给 10 分钟启用宽限（期间只统计、不限速），去掉配置里的停用标记，立即检查一次，通过后才加回每分钟的定时任务；任何一步失败都会恢复原来的配置和执行状态，并说明整机限速撤销到了哪一步。已经启用时再选（例如定时任务缺失时补上），未到期的暂停或宽限保持不变，只撤销残留的限速、补上定时任务。
- 停用或尚未配置时，宽限、暂停、恢复和开机宽限都会直接拒绝并说明原因，不改任何状态：停用时监控不统计也不限速，这些操作不会生效。
- **开机宽限**（TC 模式，`0-1440` 分钟，默认 `10`）：系统刚启动时，即使已经超额，也等宽限结束再限速；设为 `0` 才在开机后第一次检查（通常一分钟内）就限速。
- 启用了开机自动恢复时，如果仍在开机宽限期内，自动恢复只重建 Dog 的端口限速，不恢复 NTC 的整机上限；宽限结束后每分钟的检查会重新限速。

关机模式会保存触发周期和 boot ID。因流量超额关机后，如果在同一流量周期内手动开机，脚本会自动切换为“关机后重启保护，已暂停”，不会每分钟再次关机；可在“限制执行”里手动恢复，进入下一个流量周期时这项保护也会自动解除。

判断系统里有没有计划关机时，先看 systemd-logind 写的 `/run/systemd/shutdown/scheduled`，再看 `shutdown --show`（systemd 250 起才有）或 `shutdown` 进程，所以在 Debian 11 这类较旧的 systemd 上也能认出计划关机。

## 5) Telegram 通知

菜单 `4`：设置机器人与机器名、每日报告时间与时区、阈值预警档位、发送测试消息、立即发送一次日报、停用/启用通知。设置完成后会询问是否发一条测试消息。

```text
📊 [my-vps]每日流量报告

🖥️ 机器总流量：
当前使用：123.4 GB（24%）
流量限制：500 GB
执行阈值：499 GB（达到后整机限速 50 kbit/s）
执行状态：正常
本期：2026-11-01 至 2026-11-30，还剩 10 天
预计期末：约 185.1 GB（按本期日均 6.17 GB）
```

```text
⚠️ [my-vps]流量预警：本期用量已达到 80%

已用：400 / 500 GB（80%）
执行阈值：499 GB（达到后整机限速 50 kbit/s）
本期：2026-11-01 至 2026-11-30，还剩 10 天
预计期末：约 600 GB（按本期日均 20 GB）
按目前速度，预计 2026-11-25 前后达到执行阈值
```

- **用量预警**：默认 80%、90%，可改为其他 1–99 的档位，填 `off` 关闭。每期每档只推一次；同时越过多档时只推最高的一档；进入新周期重新计。
- **状态通知**：限速、关机、解除限速各推一次；新周期开始只推一次。每条都先记录、再发送，发送失败会撤回记录、下一分钟重试，不会重复推送。
- **监控异常提醒**：监控报错或超过 10 分钟没有运行时提醒（6 小时限频），恢复后发一次“已恢复”。
- `sudo ntc telegram test` 发送测试消息；`sudo ntc telegram report` 立即发送一次日报，不影响当天的定时日报。未配置时以退出码 `1` 说明原因。
- 发送失败会说明原因：Bot Token 无效、Chat ID 不对或机器人还没加入会话、被屏蔽、被 Telegram 限流、DNS 或网络不通、TLS 证书问题等。
- 停用通知会移除 Telegram 定时任务，但保留 Bot 配置；测试消息和手动日报仍可使用。

## 6) 日志

```bash
sudo ntc logs              # 全部
sudo ntc logs events       # 监控事件
sudo ntc logs telegram     # Telegram 通知
sudo ntc logs operations   # 操作记录
```

- **事件日志** `traffic_monitor.log`：只记录状态变化：配置变更、执行状态变化（正常、宽限、已限速、关机计划、暂停）、限速下发与解除、新周期、错误与恢复。同一错误最多 10 分钟记一次；一切正常时每小时一行心跳（“运行正常：本期已用 … / 阈值 …”）。默认保留最近 5000 行，可通过 `LOG_MAX_LINES` 调整。
- **操作记录** `operations.log`：只在真实变化时记录安装、更新、配置、启停、卸载等操作的中文结果及 `EVENT`/`RESULT` 字段，不记录配置内容、Token 或用户输入；达到 1 MiB 后轮转并保留 3 份。
- **Telegram 日志** `tg_notifier_cron.log`：只记录发送结果和异常，默认保留最近 2000 行；需要详细调试时可临时设置 `TG_DEBUG=true`。
- 查看日志、状态和自检不会为了“有记录”而修改安装目录。

## 7) 更新脚本

交互菜单中选择 `7` 更新，可选择直连或国内优先线路。

命令行更新:

```bash
sudo ntc update             # 直连
sudo ntc update --mirror    # 国内镜像
```

更新行为:

- 只覆盖 `/etc/trafficcop-lite` 下的脚本文件，不覆盖配置、日志和 crontab；兼容旧配置（旧配置缺少的字段按原含义处理，例如没有 `TRAFFIC_UNIT` 时继续按 `GiB` 计算，没有 `TC_BOOT_GRACE_MINUTES` 时开机宽限按 10 分钟）。
- 先下载仓库根目录的 `SHA256SUMS`（优先 `RAW_BASE` 直连；直连失败才用所选镜像线路，并提示镜像只能防传输损坏、不能防镜像本身被篡改），四个脚本逐个比对哈希，缺失或不符即取消。
- 下载到临时文件并通过 `bash -n` 语法检查后才替换；校验每个候选脚本的版本，拒绝代理缓存或错误更新源造成的组件降级。
- 四个脚本全部下载并校验成功后才开始替换；替换后会再次校验整套脚本。旧脚本备份到 `/etc/trafficcop-lite/backups/scripts-时间戳-进程号/`。
- 文件内容没有变化时直接提示已是最新版本，不重复创建备份。更新完成会显示“旧版本 → 新版本”。
- 共享的 TC 自动恢复文件写不进去时只警告，不把已经校验通过的更新判为失败。
- 交互更新完成后会自动载入新版菜单；命令行更新完成后重新执行 `sudo ntc`。

`1.0.2` 的旧交互进程有一个显示限制：脚本文件更新成功后，当前进程仍会暂时显示 `1.0.2`，退出并重新执行 `sudo ntc` 才会载入新版本。

## 8) 流量计费口径

vnStat 已分别记录每个接口实际接收的 `RX` 和发送的 `TX` 字节数，本脚本不会额外复制规则或重复乘权：

- 只计算出站：`ΣTX`
- 只计算进站：`ΣRX`
- 进站与出站都计算：`ΣRX + ΣTX`
- 出入取较大：`max(ΣRX, ΣTX)`，按整个统计周期的两个方向总量取大，不是逐日取大后再累加。

页面显示、阈值判断和 Telegram 状态都使用同一个计算结果。`GB` 与 `GiB` 只影响字节换算，不改变 RX/TX 的计费公式。

## 9) 卸载

```bash
sudo ntc uninstall
```

也可以直接运行主脚本：`sudo bash /etc/trafficcop-lite/trafficcop-lite.sh --uninstall`。

卸载会先问完所有问题（输入 `UNINSTALL` 确认、是否备份；系统里有 NTC 没有记录的计划关机时，还会问是否一并取消，默认保留），再按以下顺序执行：

1. 备份配置和日志到 `/etc/trafficcop-lite-backup-时间戳/`（默认）。
2. 解除 NTC 的限速、取消 NTC 安排的关机。
3. 删除 NTC 的定时任务。
4. 删除 `/etc/trafficcop-lite`、快捷命令 `ntc`（仅当它指向本脚本时，同时清理旧版 `ncl`、`tc` 快捷命令），以及不再被使用的共享 TC 恢复文件。

删除定时任务之前任何一步失败都会中止，监控照常运行，不会留下没人解除的限速。卸载不删除系统依赖包、不删除上游默认目录 `/root/TrafficCop`，也不自动恢复 vnStat 全局配置（选择备份时，原始 vnStat 配置副本会随工作目录一起保存）。

## 10) 目录说明

```text
/etc/trafficcop-lite/
├── trafficcop-lite.sh                主脚本（菜单、安装、更新、状态）
├── trafficcop-lite-monitor.sh        流量监控（配置向导、每分钟检查、TC 限速）
├── trafficcop-lite-telegram.sh       Telegram 通知
├── trafficcop-lite-machine-limit.sh  限制执行（启停、宽限、暂停、开机宽限）
├── traffic_monitor_config.txt        监控配置
├── tg_notifier_config.txt            Telegram 配置（600 权限）
├── traffic_monitor.log               事件日志
├── tg_notifier_cron.log              Telegram 日志
├── operations.log                    操作记录
├── current_traffic_state             最近一次检查的用量与状态
├── monitor_health                    最近一次检查是否成功
├── monitor_log_signature             事件日志去重用的状态签名
├── enforcement_state                 临时宽限或暂停
├── tc_limit_state                    NTC 管理的整机上限
├── shutdown_limit_state              NTC 安排的关机及其 boot ID
├── last_reset_period                 已执行重置的周期
├── last_traffic_notification         Telegram 通知状态（含已发的预警档位）
├── last_daily_report                 当天日报是否已发
├── last_monitor_alert                监控异常提醒状态
├── vnstat_daily_coverage_start       vnStat 日数据的覆盖起点
├── vnstat_config_path                vnStat 配置文件路径
├── traffic_monitor.lock、tg_notifier.lock、root-crontab.lock
├── backups/                          更新前的脚本备份
└── vnstat.conf.before-trafficcop-lite[.N][.source-path]
```

快捷命令 `/usr/local/bin/ntc -> /etc/trafficcop-lite/trafficcop-lite.sh`。

注意：Linux 的系统限速命令叫 `tc`，通常位于 `/usr/sbin/tc`。本项目快捷命令使用 `ntc`，脚本内部也会优先使用系统原始路径调用 `tc`，避免命令名冲突。手动执行系统 `tc` 时建议使用完整路径，例如 `sudo /usr/sbin/tc qdisc show`。

## 注意事项

- 脚本会安装依赖、写入 crontab，并可能配置 TC 限速或关机模式，请先在测试机确认。
- TC 模式直接管理统一 HTB（`traffic-tools-unified-htb-v1`）：`1:1` 实施整机上限，`1:30` 承接默认流量，并保留 Dog 的端口子类。NTC 可单独安装；与 Dog 并存时在可验证的层级中原地协调，安装顺序不限。`1:1`、`1:30` 以外的类或过滤器一律视为 Dog 的端口限速，NTC 不会删除。
- IFB 协作首次使用 Dog 的网卡/机器归属标记、可信配置、`ifb0` 设备类型及现有 class/filter/双栈 redirect 验证运行态；同步成功后在 `tc_limit_state` 中记录可选的 `IFB_INTERFACE=ifb0`。NTC 不创建、不接管未知 IFB，也不删除 Dog 的入向对象；无法验证的归属或链路会保留原规则和状态并报错，须先修复 Dog。
- NTC 与 Dog 各自使用自己的 root crontab 锁；只有修改同一内核 TC 层级时共用 `/run/lock/traffic-tools-tc.lock`。
- 外部程序重建 root qdisc 后，仪表盘会报告 TC 冲突，每分钟的检查也会拒绝覆盖。菜单 `9` 可在明确确认（输入 `REBUILD`）后删除冲突并只重建 Dog/NTC，不会保留任何第三方规则。
- 可选的 `traffic-tools-tc-recovery.service`（与 Dog 共用，默认关闭）只在开机网络就绪后执行一次；它只接受默认/缺失 qdisc 或已识别的 Dog/NTC 统一层级，遇到外部或未知 root qdisc 会拒绝自动接管。运行期间若 root qdisc 再次被其他程序覆盖，需要再次手动恢复；建议关闭其他 TC 管理服务。
- 若状态记录与当前 qdisc 不一致，脚本会按外部规则处理并停止自动覆盖。停止服务、卸载时，未标记的 TC 规则和计划关机会要求确认后才处理。
- 需要 vnStat 2.x 或更高版本。守护进程未显式指定 `--config` 时，只有运行中的 `vnstatd`、系统 `vnstatd` 命令和 `vnstat` 客户端能证明来自同一安装前缀，脚本才采用客户端报告的默认配置。
- Debian/Ubuntu、RHEL 系、Alpine 和 Arch 系会按已识别的包管理器尝试安装依赖；无法自动启动 cron 或 vnStat 服务时会给出明确提示。
- 网络受限时，优先使用带 `v6.gh-proxy.org` 的命令。
- 不要与上游原版 TrafficCop 的 TC 模式同时运行：原版在流量正常时每分钟执行 `tc qdisc del dev <网卡> root`，会清掉 NTC 与 Dog 的整套 HTB。迁移到 NTC 后请移除原版的 `traffic_monitor.sh --run` 定时任务。
- 与 Dog 2.x 共存需要 NTC 1.2.0 及以上；Dog 1.5.x 与 NTC 1.2.0 及以上也可共存。

## 开发验证

仓库内置回归测试，GitHub Actions 会执行语法检查、ShellCheck 和回归测试：

```bash
for script in trafficcop-lite*.sh tests/*.sh tools/*.sh; do bash -n "$script" || exit; done
bash tools/sync-common.sh --check
shellcheck trafficcop-lite.sh trafficcop-lite-monitor.sh trafficcop-lite-telegram.sh trafficcop-lite-machine-limit.sh tests/regression.sh
sudo bash tests/regression.sh          # 非 root 时需要 root 的少数用例记为 skip
bash tests/dependencies-regression.sh
```

- 四个脚本共用的代码（界面、输入、状态与预测、审计、crontab 锁、依赖管理等）的源文件在 `src/common/*.sh`，由 `tools/sync-common.sh` 写进各脚本里 `# >>> ntc-common:<模块> >>>` … `# <<< ntc-common:<模块> <<<` 标记的区块。改共享代码请改源文件后运行 `bash tools/sync-common.sh`；`--check` 由回归测试调用，区块与源文件不一致时测试失败。发布的仍是四个独立脚本，安装与更新方式不变。
- 修改任何产品脚本后必须运行 `tools/update-sums.sh` 重新生成 `SHA256SUMS` 并与脚本一起提交；`tests/regression.sh` 会核对两者一致，否则已发布的 `ntc update` 会拒绝新脚本。
- `tests/regression.sh` 在私有 `mktemp` 目录里用 mock 运行，不执行真实 TC 修改；它同时加载 `tests/ifb-regression.sh`、`tests/logging-regression.sh` 和 `tests/filter-json-regression.sh` 的用例。2.0 新增的用例按组件放在末尾的独立区段，包括菜单版式（120/80/60/40 列、无颜色）、配置向导与 `config set`、`status --json`、事件日志、Telegram 发送与预警、限制执行的命令行、停用与启用的事务和计划关机检测、1.2.1 更新器兼容和与 Dog 的共享约定。
- `tests/dependencies-regression.sh` 在私有临时目录中使用假 APT/dpkg 验证依赖 CLI，不修改主机软件包；账本权限测试需要 root。

真实内核集成测试需要 Dog 2.x 主脚本，只应在可丢弃的测试机上运行（在网络命名空间里创建 ifb/htb/fw 仍会让内核加载全局模块）：

```bash
sudo DOG_SCRIPT=/path/to/port-traffic-dog.sh bash tests/integration-netns.sh
```

## 历史版本改动（1.x）

以下是 1.x 各版本的改动记录，菜单编号与提示文字以当时的版本为准。

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
31. TC 自检不会写入通用监控日志；打开主页或执行自检不会伪造监控活动。
32. Dog 已建立并可验证归属的 `ifb0` 会与物理网卡在同一 TC 锁和事务内同步 `1:1`/`1:30` 父速率。撤销、宽限、暂停、周期重置、停止和卸载会同时解除两侧整机上限，保留 Dog 的端口 class/filter 和 ingress redirect；IFB 更新或状态提交/删除失败会恢复修改前两侧速率。
33. NTC 自检和恢复会核对已协作 IFB 的父速率、端口 class/filter 引用及 IPv4/IPv6 redirect。只有父速率漂移时可原地修复；配置、设备类型或归属无法验证时拒绝写入，应先通过共享恢复入口修复 Dog。NTC 单独安装仍只管理出向，不创建 IFB。
34. Dog 配置中的逗号组在首次实际下发前可能没有 `class_id`；NTC 不凭空创建该 class。缺失、`null` 或空字符串的 class 字段不会导致速率/mark 列错位；已存在的 Dog class/filter 必须全部能由可信配置解释，未知对象或归属不明时保持失败关闭。
35. 清除、宽限、暂停、停止和卸载允许 Dog 已经删除的端口 class 缺失；IFB 上现存端口 class 仍须匹配配置速率和父类，并校验 filter 引用、双栈 redirect 及默认类。现存 class 的速率错误不会按缺失跳过，apply 和自检仍要求配置中的已物化 class 完整。如果 IFB 已删除且物理 root 已回到默认状态，只清理 NTC 自己的残留状态。
36. 两个项目可先后独立安装；NTC 单独运行或仅有尚未下发的 Dog 配置时只管理出向 HTB，不探测或创建未知 `ifb0`。首次登记 `IFB_INTERFACE=ifb0` 必须由可验证的 Dog owner/config、设备类型、class/filter 和 IPv4/IPv6 redirect 共同证明；登记后可在有效 NTC 状态和 Dog 配置范围内处理 Dog 已删除最后一个端口及 owner 标记的清理。

### 1.2.0（适配 Port Traffic Dog 2.0）

37. 识别 Dog 2.0 的配置格式（schema 2）：端口限速类改从 Dog 写入的类清单 `/etc/port-traffic-dog/tc-interop.json`（`traffic-tools-dog-classes-v1`）读取，逐项核对文件权限、class 编号（`1:4001` 起）、fw mark 公式与掩码，任何一项不符都失败关闭；Dog 1.5.x 配置仍按原 `.ports` 推导。无法识别的配置（包括有 `.monitors` 却没有 `schema`）一律不碰 TC。Dog 2.0 设置限速前会检查已安装的 NTC 是否认识该清单，旧版 NTC 需先升级到 1.2.0。
38. 手动恢复（`--tc-recover-owned --manual`）删除 `htb 1:` root 前，若其中还有 `1:1`/`1:30` 以外的类或任何过滤器（即仍有 Dog 等其他使用者），拒绝删除，不再因 Dog 配置/清单缺失而误删端口限速。
39. 停止、卸载和禁用机器限速时不再在加锁前 `pkill -f`；持有监控锁即可排除正在运行的 `--run`，Telegram 只按精确命令行结束本项目的 `-cron` 进程。
40. 更新与补装组件改为按仓库根目录 `SHA256SUMS` 逐个校验，缺失或不符即取消且不留临时文件。
41. 监控每轮写入 `monitor_health`（ok/error/disabled 与最后一条失败原因）。Telegram 在监控报错或超过 10 分钟未运行时提醒（6 小时限频，恢复后发一次“已恢复”）；监控异常导致状态不可用时，日报改发一次“状态不可用”说明，不再静默。
42. 手动 TC 恢复读取配置后先对齐 vnStat 时区，周期判断与监控一致。

### 1.2.1（修复版）

43. 修复首次配置几乎必然失败：保存配置后的执行策略检查在“当前用量低于阈值”或“选择立即执行”时误返回失败，整份配置被回滚并提示“后续安全处理失败”（1.1.10 起的缺陷）。
44. 分钟数输入允许前导零（如 `08`）：开机宽限、宽限分钟数在向导、机器限速管理和读取配置时都按十进制处理。
45. 在机器限速管理中禁用后，再打开“安装/管理流量监控”只展示配置，不再重新加上定时任务、也不再执行一轮限速或关机；限速检查本身也会跳过已禁用的配置。
46. “是否修改配置”改为 `[y/N]`，只有输入 `y` 才进入向导，30 秒无输入保持现有配置。
47. 配置向导和 Telegram 配置中途输入结束（Ctrl-D 或标准输入已关闭）时取消本次配置并恢复 vnStat 状态，不再死循环、不再反复写日志，也不再用默认值继续保存。
