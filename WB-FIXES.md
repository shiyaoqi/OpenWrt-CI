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
- **排除**：ZeroTier、PassWall 全系及 21 个子选项、HomeProxy、Lucky、SmartDNS、SQM / sqm-scripts-nss / AppFilter、banIP、arpbind、wifischedule、autoreboot、wechatpush、3cat、uhttpd、cpufreq、coremark、vlmcsd、frps、wireguard 协议、Cloudflare DDNS、sgdisk/cfdisk、usb-printer（另一套）、Argon 及两个主题配置页、usb 打印另一套。
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

## 验证与回退

- Actions 日志搜 `[WB]`，应看到 `nss_offload=0`、`OpenClash 包: luci feed 自带`、`Mihomo 内核: 已内置`、`EasyTier 包: 已装入`。
- 刷机后核对 `/rom/etc/modules.d/ath11k` 也是 `nss_offload=0`（说明编译期固化成功，不只是 overlay 生效）。
- 回退插件：删掉 `General.config` 末尾这段即可恢复上游默认。
- 回退固件修复：从 `scripts/Roc-script.sh` 末尾移除 `wb-fixes.sh` 调用，并删掉 `General.config` 追加段。
- 本仓库**不包含**：`extras/` 下的上行切换脚本、体检脚本，以及任何含订阅 token / WiFi 密码 / API secret 的文件。
