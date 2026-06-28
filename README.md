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
2. 主菜单仅保留流量监控、Telegram 通知、机器限速、日志、配置、停止服务和卸载。
3. 年度统计周期支持选择起始月份，不再只能从每年 1 月开始。
4. 安装后提供快捷命令 `ntc`，可直接执行 `sudo ntc` 打开管理菜单。
5. 脚本内部调用系统限速命令时使用 `/usr/sbin/tc` 等原始路径，避免与 Linux 自带 `tc` 限速命令冲突。
6. 停止服务和卸载时只处理 `/etc/trafficcop-lite` 相关进程、crontab 和文件，不删除上游默认目录 `/root/TrafficCop`。
7. 卸载会先按配置检查 TC 限速和计划关机，再备份配置和日志到 `/etc/trafficcop-lite-backup-时间戳/`。

## 下载方式说明

- 直连（海外网络优先）  
  使用 `https://raw.githubusercontent.com/...`
- 国内优先（代理加速）  
  使用 `https://v6.gh-proxy.org/https://raw.githubusercontent.com/...`

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
sudo ntc --uninstall
```

- `--install`: 安装/更新组件，并创建 `ntc` 快捷命令。
- `--update`: 从仓库更新脚本文件，不覆盖配置和日志。
- `--stop`: 停止独立版监控和通知任务。
- `--logs`: 查看日志。
- `--config`: 查看配置。
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
```

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
- 下载到临时文件并通过 `bash -n` 语法检查后才替换。
- 旧脚本会备份到 `/etc/trafficcop-lite/backups/scripts-时间戳/`。
- 更新完成后建议重新执行 `sudo ntc` 进入新版菜单。

## 4) 年度起始月份

配置流量监控时，选择统计周期 `y` 后会额外提示:

```text
请输入年度周期起始月份 (1-12，默认为1):
```

例如输入 `6`，年度统计周期会按每年 6 月的指定起始日开始计算。

## 5) 卸载

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
- 默认备份配置和日志到 `/etc/trafficcop-lite-backup-时间戳/`。
- 不卸载系统依赖包。
- 不删除上游默认目录 `/root/TrafficCop`。

## 6) 目录说明

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
└── tc_limit_state
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
- TC 模式会用 `/etc/trafficcop-lite/tc_limit_state` 标记本脚本应用过的限速；自动恢复只清理带有该标记的规则，未标记的系统原有 `tbf` 规则会被保留或要求确认。
- 停止服务/卸载时，未标记的 TC 规则和计划关机会要求确认后才处理。
- Telegram cron 日志默认保留最近 2000 行；如需详细调试，可临时设置 `TG_DEBUG=true`。
- 网络受限时，优先使用带 `v6.gh-proxy.org` 的命令。
