# 固件级修复 · v2（从 0 刷机版）

> 设备：京东云 AX1800 Pro「亚瑟」`jdcloud,re-ss-01` / qualcommax-ipq60xx / aarch64 / 512MB
> 源码：`laipeng668/immortalwrt@openwrt-25.12`，内核 `KERNEL_PATCHVER:=6.12`（与实机 6.12.112 一致）
> 更新：2026-11-09

## 这一版解决什么

目标是**不勾选「保留配置」、从 0 重新刷机**后，固件自身就把此前只在 overlay 里的修复带齐；并且**不预设上行方式**，WAN 直连与 5G 无线中继都能用。

| 项 | 做法 | 位置 |
| --- | --- | --- |
| WiFi 连上但一直「正在获取 IP」 | 编译期把 `MODPARAMS.ath11k:=nss_offload=1` 改成 `=0`，写进 `/rom` | `scripts/wb-fixes.sh` |
| 5G 单射频 AP+STA 冲突 | 首启默认双频都是 AP，不生成任何 STA 中继 | `files/etc/uci-defaults/99-wb-fixes` |
| DHCP 排障看不到日志 | 首启补 `logdhcp=1` | 同上 |
| 无 IPv6 上行时 odhcpd 反复告警 | 不再固件层一刀切禁用；只在启用中继时由本地脚本关闭 RA | 同上 + `enable-uplink.sh` |
| 刷机后代理从零装 | `luci-app-openclash=y`（luci feed 自带 0.48.002）+ 编译期注入 Mihomo 内核 | `configs/General.config`、`wb-fixes.sh` |
| ZeroTier → EasyTier | `zerotier=n`；补入官方包源并显式启用 `easytier` 主程序 | `wb-fixes.sh`、`General.config` |
| 升级时丢配置 | 保留 `/etc/openclash/`、`/root/wb-*` 备份与回退脚本 | `files/etc/sysupgrade.conf` |
| 默认管理地址 `192.168.68.1` | 编译期 sed 改 `config_generate` + 首启 UCI 幂等钉死，双重保险 | `Roc-script.sh:157`、`files/etc/uci-defaults/99-wb-fixes` |

### 关键源码依据

- `package/kernel/mac80211/ath.mk:364`：`MODPARAMS.ath11k:=nss_offload=1 frame_mode=2` 是固件默认值（`/rom/etc/modules.d/ath11k` 已证实），不是刷机操作失误。NSS 接管无线帧后 DHCP 广播不上送 CPU，有线正常、WiFi 拿不到 IP。
- 当初 sed `mac80211.sh` 报「文件不存在」：ImmortalWrt 25.12 已迁移为 `package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc`（ucode 版），与故障无关。本方案不 sed 它，SSID 由 uci-defaults 设置。
- `Build-OpenWrt.yml:174` 的 `CUSTOMIZATION_HASH` 包含 `scripts/Roc-script.sh` 与 `configs/General.config`，改这两处会让 ccache/staging 缓存失效、真正重编译。
- `Build-OpenWrt.yml:257` 用 `cat JDCloud.config General.config > .config`，General 在后覆盖；`Roc-script.sh` 的 `package_enabled` 按同序扫描，所以本段里设 `=n` 也会阻止对应的第三方 clone。
- `JDCloud-ImmortalWrt.yml:24` 的 `kernel_file: kernel-6.18` **只用于 Release 说明里 grep 版本号**，不切换编译内核；已改为 `kernel-6.12` 修正文字。

### 为什么不需要 clone vernesong/OpenClash

`immortalwrt/luci@openwrt-25.12` 的 `applications/luci-app-openclash` 已自带 0.48.002（与实机手动安装版本一致），依赖 `luci-compat` / `dnsmasq-full` / `ruby-yaml` / `kmod-nft-tproxy` / `kmod-inet-diag` 等由 `make defconfig` 自动带入。该仓库历史里塞过内核二进制、体积约 45GB，直接 clone 会拖垮 Actions。唯一缺的是内核二进制，由 `wb-fixes.sh` 从 `MetaCubeX/mihomo` 官方 Release 下载 `mihomo-linux-arm64-*.gz` 注入 rootfs。

关于体积：官方 release 的 gz 约 19.8MB，解压后约 55MB；实机现有的是 UPX 压缩版 12.8MB。本机为 **57.1GB eMMC**，`/overlay` 1GB 仅用 12%，squashfs 还会再压缩一次，55MB 不构成空间问题；且未压缩 ELF 由 mmap 按需分页，在 415MB 内存下比 UPX 版运行时整体解压更省，因此不引入 upx 这个额外编译依赖。

### EasyTier 为什么必须补源

`JDCloud.config:16` 早就写了 `CONFIG_PACKAGE_luci-app-easytier=y`，但 upstream 源码树、`immortalwrt/packages`、`immortalwrt/luci` 里都没有这个包，`make defconfig` 会静默丢弃 —— 这正是旧固件「配置写了却没装」的原因。`EasyTier/luci-app-easytier@main` 的 `easytier/Makefile` 用 `wget` 拉预编译 aarch64 zip，不做 Rust 交叉编译，云编译可行。`wb-fixes.sh` 把 `easytier/`、`luci-app-easytier/`、`version.mk` 拆成两个顶层 `package/` 目录并修正 `-include` 路径。

## 插件取舍

`configs/General.config` 末尾追加的 `wb-plugins-v2.config` 一锤定音：

- **启用**：OpenClash、EasyTier（含主程序）、watchcat、UPnP、nlbwmon、Samba4/diskman/hd-idle/p910nd 及磁盘工具、acme/ddns-go、ttyd/WOL/tmux/htop/btop/dmesg/nano/sftp/autocore、Aurora 主题、基础包（kmod-tun / zram-swap / kmod-lib-lz4 / zoneinfo-asia / default-settings）。
- **排除**：ZeroTier、PassWall 全系及 21 个子选项、HomeProxy、Lucky、SmartDNS、SQM / sqm-scripts-nss / AppFilter、banIP、arpbind、wifischedule、autoreboot、wechatpush、3cat、uhttpd、cpufreq、coremark、vlmcsd、**frpc / frps**、wireguard 协议、Cloudflare DDNS、sgdisk/cfdisk、usb-printer（另一套）、Argon 及两个主题配置页、usb 打印另一套。
- **frpc 移除依据（2026-11-17）**：frp 是「公网中转服务器 + 客户端主动外连」的穿透方案，和本机 EasyTier 子网代理（NAS 常开、公网只留 64333 接入口）功能重叠；装 frpc 等于多开一条外部入口，还要额外维护 frps、token、端口映射，安全面变大而无实际收益。`luci-app-frpc` 无第三方 clone 依赖（`Roc-script.sh` 只对 miniupnpd 做 sparse-clone），设 `=n` 干净移除。
- **留 watchcat 删 autoreboot**：定时重启是「没病也吃药」，且可用一行 cron 代替；上行不固定时按需自愈更对症。注意把 watchcat 配成 ping 网关 / 间隔 5 分钟 / 连续失败 3 次 / 动作选「重启网络」，避免与每日 04:00 订阅自动更新的约 20 秒断网叠加误触发。
- 带 kmod 或会触发 `Roc-script.sh` 第三方 clone 的项，即使「编进去不启用」也会带来 NSS 冲突或编译失败面，因此直接排除；只有官方 feed 的纯界面/小工具才适合「编进去备用」。

### 默认管理地址：192.168.68.1

- 编译期 `scripts/Roc-script.sh:157` 把 `package/base-files/files/bin/config_generate` 里的 `192.168.1.1`（上游 `laipeng668/immortalwrt@openwrt-25.12` 默认值）sed 成 `192.168.68.1`；首启脚本 `99-wb-fixes` 再在 UCI 层幂等写一次 `network.lan.ipaddr`，防止上游默认值变化或其它 `default-settings` 脚本覆盖。
- 仓库 README 第 11 行原写 `192.168.2.1`，是上游旧文案，已同步更正为 `192.168.68.1`。
- 刷完用网线连 LAN 口，浏览器进 `http://192.168.68.1`，用户 `root`、首次登录设密码。DHCP 的 `start/limit` 是相对值，会自动跟随同网段，无需手工改。
- **唯一要注意的冲突**：WAN 直连时若上级光猫也是 `192.168.68.0/24`，WAN 与 LAN 同段会导致路由异常。`extras/enable-wan.sh` 会检测并告警，届时把 LAN 改到 `192.168.69.1` 之类即可。5G 中继上级是 `192.168.31.0/24`，不冲突。

## 刷机后必做三件事（硬约束）

公开仓库 + 从 0 刷机，**凭据绝不能写进固件**，否则任何人下载 Release 解包即可取得。所以这三样只能手填：

1. **选上行**（二选一，本机脚本，不上传本仓库）
   - WAN 直连：插网线即可，或运行 `enable-wan.sh` 清理残留中继/wwan。
   - 5G 中继：运行 `enable-uplink.sh`（含 `CMCC-EDU` 密码，**只在本机保存**），它也会关闭 LAN IPv6 RA。
2. **填代理订阅**：LuCI → OpenClash → 配置订阅，填你的订阅 URL；内核与面板已内置，不需要下载内核。首次联网后建议点一次「更新 Geo 数据库」（`Country.mmdb` / `GeoSite.dat` 未内置）。
3. **设 WiFi 密码**：固件默认 2.4G `JDAX1800` / 5G `JDAX1800-5G` 且为开放网络，刷完立刻设 `psk2` 密码。

随后运行 `verify-after-flash.sh` 做只读体检。

## 手动清理离线客户端（2026-11-17 追加）

LuCI「状态 → 网络 → 客户端」把 `/tmp/dhcp.leases` 的**全部行**都列出来，
包括到期时间已过的（页面显示 `expired`），所以手机/电脑早就离线却仍留在列表里。
dnsmasq 不会主动删这些行，SIGHUP 也不会重读 lease 文件——需要一个显式清理命令。

固件内置 `/usr/bin/wb-clean-clients`（由 `files/usr/bin/wb-clean-clients` 编进 squashfs，
`wb-fixes.sh` 的 `[WB 2/6]` 负责注入并 `chmod 0755`）：

```sh
wb-clean-clients       # 清理：删除已过期的租约行，只打印删除/保留条数
wb-clean-clients -n    # 预览：只看会删几条，不改文件
wb-clean-clients -f    # 连 IPv6 过期项一起处理（默认不动 IPv6）
wb-clean-clients -h    # 帮助
```

- 判定规则：第一列是纯数字且 `0 < 到期时间 <= 当前时间` 才删；`0`（永不过期）与未来时间一律保留。
- **隐私**：脚本不采集、不输出、不落盘任何主机名 / MAC / IP，只打印计数；临时文件用完即删。
- 不影响静态 DHCP 分配（UCI `dhcp.@host`）、在线设备与 DNS 服务；不向 dnsmasq 发信号。
- 可在 LuCI 网页终端（ttyd）或 SSH 里执行；清理后刷新客户端页面即可见离线项消失。
- 只在**手动执行时**生效，不设定时任务（避免自动误删临时离线的设备）。
- 注意：改 `files/` 与 `wb-fixes.sh` 不进入 `CUSTOMIZATION_HASH`，但 rootfs 每构建都重新
  `cp -a files/` 并打包，所以脚本**一定**会进固件，无需手清 ccache。

回退：删掉 `files/usr/bin/wb-clean-clients` 即可，不影响其余功能。

## DHCP 静态绑定实时管理（2026-11-17 追加）

固件内置 `/usr/bin/wb-dhcp`（`files/usr/bin/wb-dhcp`，`[WB 2/6]` 负责注入并 `chmod 0755`）。

```sh
wb-dhcp list                          # 列出当前静态绑定（只显示你自己配置的条目）
wb-dhcp bind <MAC> <名字> [IP]        # 绑定/改名；IP 省略则只改名、IP 仍动态
wb-dhcp unbind <MAC>                  # 解绑，并清理该 MAC 的租约记录
wb-dhcp -n bind ...                   # 预览：改配置但不重载 dnsmasq
wb-dhcp -h
```

- **实时生效**：改完自动 `uci commit dhcp` 并 restart dnsmasq。dnsmasq 在启动/SIGHUP 时会执行
  `lease_update_from_configs()` + `lease_update_file()`，用 `config host` 的 name 覆盖租约文件里
  的旧 hostname 并写回，所以 LuCI「状态 → 网络 → DHCP 租约」**刷新即可见新名字，无需设备重连**。
- **bind**：MAC 接受大小写与横杠/冒号；已有绑定则改名（给 IP 才改 IP），没有则新增 host 段；
  不给 IP 时只生成 `--dhcp-host=<mac>,<name>`，只覆盖名字、不固定 IP。
- **unbind**：删除该 MAC 的 host 段（多 MAC 段只移除该 MAC），并按 MAC 清掉其租约行；
  IP 是否**立即释放**仍由 dnsmasq 租约机制决定，不保证马上可被重新分配。
- **隐私**：只显示/操作管理员自己写入的静态绑定；清租约按 MAC 过滤删除，不打印被删记录任何字段；
  不写日志、不落盘客户端明细。
- 解绑后若设备在线，会按新配置重新 DHCP，名字回到客户端自报值；想保留自定义名就别解绑。
- ⚠️ **名称只能是 ASCII**（`[A-Za-z0-9-]`，≤63 字符，不以 `-` 开头/结尾）。这不是"建议"：
  dnsmasq 把 `config host` 的 name 当 hostname 解析，遇到中文会报
  `bad DHCP host name at line N of /var/etc/dnsmasq.conf.*` 然后**整个实例启动失败**，
  表现为**能 ping 通 IP 但所有域名都解析不了**（全屋断网）。2026-11-17 曾因输中文名踩过一次。
  脚本现在会直接拒绝非 ASCII 名称。
- **失败自动回滚**：`wb-dhcp bind/unbind` 改配置前把 `/etc/config/dhcp` 存到 `/tmp/wb-dhcp-lastgood`；
  restart 后 `sleep 2` 用 `pgrep -x dnsmasq` 验活，起不来自动恢复备份并再重启一次。
  （procd 的 restart 即使实例崩溃也可能返回 0，光看退出码不够。）

回退：删掉 `files/usr/bin/wb-dhcp` 即可，不影响 `wb-clean-clients` 与其余功能。

## ~~LuCI 端口转发管理页~~（2026-11-17 建于当日、同日移除）

> **已移除**：`网络 → 防火墙` 自带「端口转发」标签页，读写的是同一个 UCI `config redirect`，
> 再维护一套独立界面属于重复。2026-11-17 起删除 `luci-app-wbforward` 的三个文件
> （view `wbforward/main.js`、menu、acl），端口转发统一在 `网络 → 防火墙 → 端口转发` 里做；
> IPv6 只放行不 NAT 的规则改用 `网络 → 防火墙 → 通信规则`（family=ipv6 / target=ACCEPT）。
> 此前用它建的规则仍留在 `/etc/config/firewall`，在官方标签页里可正常看到和修改。
>
> 原文留档：该页支持 IPv4 单端口/范围 DNAT（`src=wan`、`dest=lan`）与 IPv6 放行（`config rule`），
> 新建/编辑/删除后自动 `uci save` + `uci commit('firewall')` + `rc init firewall reload`；
> ACL 需在 `write.ubus` 显式授权 `uci: [ "commit" ]`，否则报 `Access denied at uci/commit`；
> 只管理 comment 以 `WBPF:` 开头的规则，不碰用户手工添加的条目。

## ~~DHCP 绑定页~~（2026-11-17 建于当日、同日移除）

> **已移除**：`网络 → DHCP/DNS` 自带「静态地址分配」标签页，读写的也是 `config host`，
> 自建页面属于重复维护。2026-11-17 起删除 `luci-app-wbdhcp` 三件套
> （view `wbdhcp/main.js`、menu、acl），静态绑定统一在 `网络 → DHCP/DNS → 静态地址分配` 里做。
> **命令保留**：`/usr/bin/wb-dhcp` 仍在固件里，SSH 下可用 `wb-dhcp list | bind | unbind`
> 批量查看/绑定/解绑（脚本直接写 UCI 并重启 dnsmasq，不依赖任何 LuCI 页面）。

**改名入口（2026-11-17 追加，补删页后的空档）**：独立页删掉后，改设备显示名仍可在
「状态 → 概览 → DHCP 租约」每行右侧的「重命名」按钮里做 —— 它调用
`wb-dhcp bind <MAC> <名字>`（不传 IP 即「仅改名、IP 仍动态」），保存后 dnsmasq 重载，
租约列表立刻显示新名字。按钮与「离线清理」共用 `luci-app-wbclean` ACL，
为此在 ACL 里补了 `/usr/bin/wb-dhcp*` 的 `exec` 授权（读写两段都加）。
官方「网络 → DHCP/DNS → 静态地址分配」也能设名字，但那里要连同 IP 一起填；
只想改名、不想固定 IP 时用这个按钮或 `wb-dhcp bind <MAC> <名字>`。
>
> 原文留档：该页列出 `config host` 静态绑定，增删改走弹窗，即时 `uci save` + `commit('dhcp')` +
> `dnsmasq restart`；MAC 归一化、IP 可留空（只改名不固定地址）；只显示管理员自己配置的绑定，
> 不扫描客户端、不采集任何设备信息。

离线清理没有独立页面，一直是「状态→概览→DHCP 租约」页内的按钮；wbclean 只保留 ACL
（`luci-app-wbclean.json`），其 view/menu 已删除。该 ACL 额外授权 `ubus file exec` 与
`/usr/bin/wb-clean-clients*`、`/tmp/*.leases`。`wb-clean-clients -a` 按邻居表
（REACHABLE/DELAY/PROBE）、无线关联和一次 ping 判定离线，因此未到期或永不过期的离线租约也能清理；
只输出计数，不输出任何客户端明细。

## 日志页清空按钮（2026-11-17 追加）

「状态 → 系统日志」和「状态 → 内核日志」页面顶部都加了「清空日志」按钮，
不新增菜单，也不改动官方日志筛选/滚动/自动刷新功能。

| 页面 | 覆盖文件 | 后端动作 |
|---|---|---|
| 系统日志 | `files/www/luci-static/resources/view/status/syslog.js`（基于官方 25.12 原版包一层） | `wb-clear-logs system` → `logread -c`，清 logd 缓冲 |
| 内核日志 | `files/www/luci-static/resources/view/status/dmesg.js`（基于官方 25.12 原版包一层） | `wb-clear-logs kernel` → `dmesg -c`/`-C`，清内核 ring buffer |

- 两个缓冲区彼此独立：清系统日志不会清内核日志，反之亦然。
- 按钮只调用固定脚本名与固定参数；`luci-app-wbclean` ACL 只放行 `/usr/bin/wb-clear-logs*`，**不开放任意命令执行**。
- 脚本不读取、不打印、不落盘任何日志正文；弹窗确认后才执行，执行完立即刷新当前日志框。
- 清空的是内存中的日志缓冲，**不删日志文件、不改 UCI**；重启后从空缓冲重新开始记录。
- **真机即时部署**：`deploy-wb-log-buttons-20261117.sh` 把两个 view、后端脚本与更新后的 ACL 以 base64 内嵌，
  在路由器 ttyd/SSH 粘贴执行即可，幂等覆盖并重启 rpcd/uhttpd；不碰 UCI、不改 crontab。

回退：删掉这两个覆盖的 view 文件即可恢复官方原版；脚本留着不影响其他功能。

## 自动端口映射页中文化 + 分类（2026-11-17 追加）

上游 `luci-app-upnp` 的菜单标题是硬编码英文「UPnP IGD & PCP」，页面里两个协议开关也叫
`Enable UPnP IGD protocol` / `Enable PCP/NAT-PMP protocols`，看不出「到底干什么、该开哪个」。
本版直接覆盖菜单与视图，把名字改成说人话的中文并按用途分区，**功能一行没改**。

| 位置 | 原样 | 现在 |
|---|---|---|
| 菜单 | 服务 → `UPnP IGD & PCP` | **网络 → `自动端口映射`**（order 27，排在 网络→防火墙 之后；端口转发/静态IP分配 已并回官方页面） |
| 页面标题 | `UPnP IGD & PCP/NAT-PMP Service` | `自动端口映射` |
| 协议开关 | `Enable UPnP IGD protocol` | `UPnP 自动开端口（通用）` —— Windows / 迅雷 BT / 游戏机 |
| 协议开关 | `Enable PCP/NAT-PMP protocols` | `PCP / NAT-PMP 自动开端口（苹果设备）` —— Mac / iPhone / 部分 NAS |
| 页内分区 | `Service Setup` / `Advanced Settings` 两个页签 | `基本设置` / `安全限制` / `高级参数` 三个页签 |
| 映射表 | `Active Service Port Maps` + 英文表头 | `当前生效的映射` + 中文表头，剩余时间显示为「1 小时 05 分」 |
| 白名单表 | `Service Access Control List` | `允许与禁止名单`，动作显示「允许 / 拒绝」 |

- `安全限制` 页签单独放 `secure_mode`（只允许发起请求的设备使用该映射）和调试日志开关：
  这两项是「谁能蹭用这些孔」的唯一开关，混在高级项里最容易被忽略。
- 覆盖文件：`files/www/luci-static/resources/view/upnp/upnp.js`、`files/usr/share/luci/menu.d/luci-app-upnp.json`。
- 配置仍读写 `/etc/config/upnpd`，24 个选项与上游一一对应（`enabled` / `enable_upnp` / `enable_natpmp` /
  `igdv1` / `download` / `upload` / `use_stun` / `stun_host` / `stun_port` / `force_forwarding` / `secure_mode` /
  `log_output` / `notify_interval` / `port` / `presentation_url` / `uuid` / `model_number` / `serial_number` /
  `system_uptime` / `upnp_lease_file`，加 ACL 表 4 项），已逐项核对无遗漏。
- 与 `status/nftables.js`、`status/syslog.js` 同属「覆盖上游视图」，上游升级后需同步。
- 包编进去 ≠ 服务在跑：`miniupnpd` 默认 `option enabled 0`，需在页面里手动「启动自动端口映射」。
- 当前是双重 NAT（副路由 WAN 在主路由之后），副路由的自动映射到不了公网，保持关闭即可。

回退：删掉这两个覆盖文件，菜单与页面立即恢复上游英文版。

## EasyTier 菜单归并（2026-11-17 追加）

上游 `luci-app-easytier` 在 `admin/vpn` 下自建一个**顶层「VPN」分类**，里面只有 EasyTier 一个应用、下挂 5 个子页（状态 / 核心 / Web 控制台 / 日志 / 上传程序）。本机外网访问走方案 3（NAS 上的 EasyTier 做子网代理），副路由不跑 EasyTier，这个分类只是空壳，故把整棵子树搬到 **服务 → EasyTier**，order 55 排在 ACME(50) 之后。

| 项 | 改动 |
|---|---|
| 控制器 | `luasrc/controller/easytier.lua`：删掉 `entry({"admin","vpn"}, firstchild(), "VPN", 45)` 整行；30 处 `{"admin","vpn","easytier"…}` → `{"admin","services","easytier"…}`；order 46 → 55 |
| 模板 | `luasrc/view/easytier/*.htm` 共 5 个文件里 **27 处硬编码 AJAX 地址**同步改：分段 `url("admin", "vpn", "easytier", …)` 与单字符串 `url("admin/vpn/easytier/…")` 两种写法并存，另有单引号、无尾斜杠、无空格变体 |
| 未动 | `model/cbi/easytier.lua`、`easytier_status.lua` 已确认无路径引用；`init.d/easytier`、`/etc/config/easytier` 一律不碰，服务与配置不变 |

- 这是**老式 Lua 应用**（依赖 `luci-compat`），菜单写在 Lua 控制器里，**`menu.d` JSON 无法移动节点** —— 树按路径定位，路径即位置，所以只能改写控制器。
- 因此必须「控制器 + 模板」一起改：模板漏改一处，对应按钮就 404。`wb-fixes.sh` 在 sed 之后跑 `grep -rnE 'admin.{0,8}vpn'`，有残留直接 `exit 1` —— 宁可编译失败，不出半成品固件。
- 该校验正则同时覆盖 `"admin", "vpn"`、`admin/vpn`、无空格写法；已用 5 种写法的样本做正向 + 负向测试通过。
- 幂等：真机脚本先判 `grep -q '"admin", "vpn", "easytier"'`，已归并过的机器再跑会跳过。
- **代价**：旧书签 `admin/vpn/easytier` 会 404（正常）；上游升级后 sed 规则需复查，校验会兜住。

**真机即时部署**（不等云编译）：`deploy-wb-easytier-move-20261117.sh` —— 纯 sed 改写既有文件、不新增文件，执行前把原件备份到 `/tmp/wb-et-backup`，改完清 `/tmp/luci-indexcache*` 并重启 uhttpd。回滚：`cp /tmp/wb-et-backup/easytier.lua` 回原位并从备份恢复 htm。

- **顶层「VPN」容器本身还在官方 `luci-base.json` 里**（`"admin/vpn": {title:"VPN", order:50, action:firstchild}`），
  只删控制器那行会留下一个点进去没有内容的空分类。`files/usr/share/luci/menu.d/zz-wb-menu-trim.json`
  给它加 `depends.fs = {"/etc/wb-hide-vpn": "file"}`：该标记文件永不创建 → 菜单永不渲染，
  且不动官方 JSON（上游升级不会失配）。`admin/status/nftables` 用同一个套路（`/etc/wb-hide-status-firewall`）。
- **实测菜单树**（`/cgi-bin/luci/admin/menu` 的 JSON）：`VPN` 为 `satisfied:false`，
  `服务` 下顺序为 ACME / DDNS-Go / 设备限速 / 带宽监控 / Watchcat / Wake on LAN / EasyTier / OpenClash。

## 带宽监控菜单汉化（2026-11-17 追加）

上游 `luci-app-nlbwmon` 的菜单标题是英文 `Bandwidth Monitor`，子页是 `Display` / `Configuration` / `Backup`。
新增 `files/usr/share/luci/menu.d/zz-wb-menu-title.json` 只覆盖 4 个 `title` 字段（`带宽监控` / `流量明细` /
`统计设置` / `数据备份`），`action`、`depends` 等字段不动 —— menu.d 是**按路径深度合并**、同名字典序靠后的文件覆盖前者字段，
`zz-` 前缀保证排在 `luci-app-nlbwmon.json` 之后。页面本身仍是官方实现（只额外加了顶部开关按钮）。

## 带宽统计默认关闭 + 只保留近 1 个账期（2026-11-17 追加）

上游 nlbwmon 的默认值在内存小的机器上代价偏高：`database_generations 10`（保留 10 个账期）、
`database_limit 10000`（每库 1 万条）、`refresh_interval 30s`，而数据库目录 `/var/lib/nlbwmon`
是 **tmpfs，直接吃内存**。结果是「为了一个月看一次的统计，长期占几十 MB 内存」，打开显示页还要
聚合整个库，明显发卡。

| 项 | 上游默认 | 本固件 |
|---|---|---|
| `database_generations` | `10` | **`1`**（只留当前账期） |
| `database_limit` | `10000` | **`2000`** |
| `refresh_interval` | `30s` | **`60s`** |
| `database_interval` | `1`（每月 1 号开新账期） | 不改 |
| 服务开机自启 | 启用 | **停用**（`/etc/init.d/nlbwmon disable`） |

- 生效方式：`files/etc/uci-defaults/99-wb-fixes` 第 7 段在**首次启动**写 UCI 并停用服务。
  已有系统不跑 uci-defaults，用真机脚本补一遍。
- 页面开关：覆盖 `files/www/luci-static/resources/view/nlbw/display.js`，在标题下加一行
  「统计已开启 / 统计已关闭」+ **开启统计 / 关闭统计** 按钮，点击弹确认框，执行
  `/usr/bin/wb-nlbw on|off`（`enable + start` / `stop + disable`），完成后刷新页面。
- 关闭状态下页面**不再请求数据**：`load()` 先调 `wb-nlbw status`，返回 `stopped` 时直接渲染
  提示卡片，避免 `nlbwmon-action` 执行失败弹出报错。查询本身失败时按「运行中」处理，不会误判。
- 授权：`files/usr/share/rpcd/acl.d/luci-app-wbnlbw.json` 只放行 `/usr/bin/wb-nlbw*` 的
  `file exec`，不开放任意命令。
- **内核计数收尾**：nlbwmon 靠内核对每条连接维护的字节/包计数器统计，而 `nf_conntrack_acct`
  由它自己启动时打开、**停掉服务后不会关回去**（上游 init 脚本完全不碰这个 sysctl，`nlbwmon.config`
  里也没有对应开关）。`wb-nlbw off` 把它置 `0`，`on` 时先置 `1` 再 `start`，避免启动瞬间漏计。
  脚本对 `/proc/sys/net/netfilter/nf_conntrack_acct` 做可写性判断，内核未编译 acct 时静默跳过。
- 只改服务状态与 UCI，不删数据库文件、不动 `nlbwmon-action`、不影响导出与账期下拉。
- 回退：删掉覆盖的 `view/nlbw/display.js` 恢复官方页；`chmod` 无关。

## 设备限速 eqos + 「仅局域网 / 仅走 IPv4」开关（2026-11-17 追加）

原固件没有单设备限速能力（`luci-app-sqm=n`，且 SQM 只做全局整形）。改为引入
`luci-app-eqos`（`tc htb` + `ifb`），并在同一张设备表里加 **仅走 IPv4** 与 **仅局域网** 两列。

| 文件 | 作用 |
|---|---|
| `files/www/luci-static/resources/view/eqos.js` | 中文页面：总开关、总带宽、按设备表（启用 / IP / 下载 / 上传 / **仅走 IPv4** / **仅局域网** / 备注） |
| `files/usr/bin/wb-eqos-sync` | 读 `eqos` 的 `config device`，按开关生成防火墙规则 |
| `files/etc/init.d/eqos` | 覆盖官方 init，在 `reload_service()` 里先跑 `wb-eqos-sync` 再重启限速 |

- **限速语义**：`config eqos` 的 `download` / `upload` 是**整条线路的总带宽**（htb 根类），
  所有设备共享，填太小会让全部设备一起变慢；`config device` 才是单设备上限。**仅支持 IPv4**——
  eqos 用 `tc filter ... u32 match ip`，只认 IPv4 地址。
- **为什么不做 IPv6 限速**：IPv6 有 SLAAC 隐私扩展（RFC 4941），手机/Windows/macOS 默认开启，
  地址每几小时换一次且一台设备同时存在多份地址，按地址写 `tc filter` 必然失效。可行做法是按 MAC
  匹配，但 eqos 已经占了 `br-lan` 的 root qdisc（一个接口只能有一个），硬加会与它冲突。
  因此改为「**让要限速的设备干脆不用 IPv6**」，落到 eqos 能管的 IPv4 上。
- **仅走 IPv4 语义**：生成 `config rule`（`src=lan`、`dest=wan`、`family=ipv6`、`src_mac=<MAC>`、
  `target=DROP`、`comment=WBEQ:<IP>:v6`）。fw4 会编译成 `meta nfproto ipv6` + `ether saddr`，
  即按二层 MAC 精确阻断该设备的 IPv6 出网，客户端 Happy Eyeballs 后自动回落 IPv4。
  **必须能查到 MAC**（DHCP 租约或静态绑定）；查不到时宁可不生成，也不留一条永不命中的空规则。
- **仅局域网语义**：生成 `config rule`（`src=lan`、`dest=wan`、`src_mac` 优先、查不到 MAC 时回退
  `src_ip`、`target=DROP`、`comment=WBEQ:<IP>`）。只挡「出网」，访问路由器和 LAN 内其它设备
  （投屏、打印、NAS）不受影响。**两项同时勾选时只出「仅局域网」一条**，IPv6 规则不再生成。
- **幂等**：每次运行先删掉所有 `comment` 以 `WBEQ:` 开头的规则再重建；匿名 section 在 `uci show`
  里是 `@rule[N]`，删除后索引会重排，所以循环里每轮只删第一个匹配项。管理员手工建的规则不读不删
  （清理正则只匹配 `.comment=` 且值以 `WBEQ:` 开头的行，带 `:v6` 后缀同样命中）。
- **同步时机**：页面点「保存并应用」→ `uci commit eqos` → procd 触发 `eqos` reload →
  `reload_service()` 调 `wb-eqos-sync`。不需要在页面里写额外钩子。
- **隐私**：规则 comment 里只有管理员自己填的 IP，不写主机名、不在日志留客户端明细。
- **已知边界**：
  - 若该设备流量被 OpenClash 以 redirect 方式劫持到本机再出去，`forward` 链的 DROP 可能不命中
    ——需要在 OpenClash 的访问控制里同时排除该设备。
  - 「仅走 IPv4」只在 LAN 真有 IPv6 时才有实际效果。当前 5G 中继模式下 `enable-uplink.sh` 已把
    `dhcp.lan.ra/dhcpv6/ndp` 全设为 `disabled`，内网本来就没有 IPv6；切回 WAN 直连
    （`enable-wan.sh` 会删掉这三个键恢复 `server`）后才需要它。
- 回退：删掉 `view/eqos.js` 恢复官方英文页；`/etc/init.d/eqos` 恢复后两列仍在配置里
  但不再同步防火墙，`uci show firewall | grep WBEQ` 可手工清理残留规则。

## 验证与回退

- Actions 日志搜 `[WB]`，应看到 `nss_offload=0`、`OpenClash 包: luci feed 自带`、`Mihomo 内核: 已内置`、`EasyTier 包: 已装入`、**`离线清理脚本: 已注入 /usr/bin/wb-clean-clients (0755)`**、**`DHCP绑定管理脚本: 已注入 /usr/bin/wb-dhcp (0755)`**、**`日志清空脚本: 已注入 /usr/bin/wb-clear-logs (0755)`**、**`日志清空按钮: 已注入 (覆盖 status/syslog.js)`**、**`日志清空按钮: 已注入 (覆盖 status/dmesg.js)`**、**`自动端口映射中文页: 已注入 (view + menu，归入 网络)`**、**`菜单裁剪: 已注入 (隐藏 状态→防火墙)`**、**`EasyTier 菜单已归并: 顶层 VPN → 服务/EasyTier (order 55)`**、**`离线清理/日志清空 ACL: 已注入 (无菜单)`**、**`仅局域网/仅走IPv4 同步脚本: 已注入 /usr/bin/wb-eqos-sync (0755)`**、**`设备限速中文页: 已注入 (覆盖 view/eqos.js，含仅走IPv4/仅局域网两列)`**、**`eqos 启动脚本: 已覆盖 (reload 时调用 wb-eqos-sync)`**、**`带宽统计开关脚本: 已注入 /usr/bin/wb-nlbw (0755，含 conntrack acct 收尾)`**、**`带宽统计开关按钮: 已注入 (覆盖 view/nlbw/display.js)`**、**`带宽统计 ACL: 已注入 (供页面按钮调用 wb-nlbw)`**。**不应再出现** `LuCI 页面 wbforward` / `LuCI 页面 wbdhcp` 这两条——自定义页面已全部撤除。
- **DHCP 租约页内联按钮**：另在 `view/status/include/40_dhcp.js`（状态→概览→DHCP 租约）的租约表格上方注入「离线清理」按钮，点击后确认并调用 `/usr/bin/wb-clean-clients -a`（含未到期但离线项），结果以弹窗显示计数并提供「刷新页面」。依赖 `L.ui`（`view/status/index.js` 已 `require ui`），不单独读/显任何客户端明细。该按钮随本固件 `files/` 覆盖 luci-mod-status 原文件。
- **状态→防火墙 菜单隐藏（2026-11-17）**：`状态→防火墙` 与 `网络→防火墙` 重复，前者只读、后者可编辑，保留后者即可。做法是新增 `files/usr/share/luci/menu.d/zz-wb-menu-trim.json`，对同一节点 `admin/status/nftables` 覆盖 `depends.fs` 指向一个永不存在的文件（`/etc/wb-hide-status-firewall`）。ucode dispatcher 建树时 `check_depends` 判为 false → `satisfied=false` → 菜单不渲染、直接访问 URL 也不会落到该页；先前覆盖的 `view/status/nftables.js` 摘要页一并删除，该 URL 回归官方实现（不可达但不会 404 报错面板）。文件按字典序最后加载（`zz-` 前缀）才生效，因为同路径节点是「后写覆盖同名字段」，不是深合并。
- 刷机后核对 `/rom/etc/modules.d/ath11k` 也是 `nss_offload=0`（说明编译期固化成功，不只是 overlay 生效）。
- LuCI 菜单最终形态：`网络 → 自动端口映射`（中文页）、`服务 → EasyTier`（由原顶层 `VPN` 分类归并而来，**顶层不应再有「VPN」**）、`服务 → 设备限速`（`luci-app-eqos`，设备表含「仅走 IPv4」「仅局域网」两列，两项同勾时仅局域网生效）、`状态→概览→DHCP 租约` 里的「离线清理」按钮（无独立菜单）、`状态 → 系统日志`/`状态 → 内核日志` 顶部的「清空日志」按钮、`服务 → 带宽监控` 页顶部的「开启统计 / 关闭统计」按钮（**首次刷机后服务默认停用，页面显示“统计已关闭”**）。`状态 → 防火墙`、`网络 → 端口转发`、`网络 → 静态IP分配` **都不应再出现**：防火墙与端口转发统一走 `网络 → 防火墙`（端口转发是该页的标签页），静态绑定统一走 `网络 → DHCP/DNS → 静态地址分配`。若菜单未刷新，退出登录并强制刷新浏览器缓存（或 `rm -f /tmp/luci-indexcache*`）。
- 回退插件：删掉 `General.config` 末尾这段即可恢复上游默认。
- 回退固件修复：从 `scripts/Roc-script.sh` 末尾移除 `wb-fixes.sh` 调用，并删掉 `General.config` 追加段。
- 本仓库**不包含**：`extras/` 下的上行切换脚本、体检脚本，以及任何含订阅 token / WiFi 密码 / API secret 的文件。
