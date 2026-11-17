#!/usr/bin/env bash
# =============================================================================
# WorkBuddy 固件级补丁 v2
#   仓库: shiyaoqi/OpenWrt-CI
#   设备: 京东云 AX1800 Pro (亚瑟 / jdcloud,re-ss-01 / qualcommax-ipq60xx / aarch64)
#   调用: 由 scripts/Roc-script.sh 末尾执行（feeds install 之后、最终 defconfig 之前）
#         cwd = OpenWrt 源码根目录 ($OPENWRT_PATH)
#   目标: 从 0 刷机即可用的固件 —— 固化 WiFi 根因、内置代理框架与组网工具
# =============================================================================
set -Eeuo pipefail

WORKSPACE="${1:-${GITHUB_WORKSPACE:-}}"
if [ -z "$WORKSPACE" ]; then
  echo "[WB] ERROR: 需要传入 GITHUB_WORKSPACE 路径" >&2
  exit 1
fi

ATH_MK="package/kernel/mac80211/ath.mk"
if [ ! -f "$ATH_MK" ]; then
  echo "[WB] ERROR: cwd 不是 OpenWrt 源码树（找不到 $ATH_MK）" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "================ [WB 1/6] 固化 ath11k nss_offload=0 ================"
# 上游 (laipeng668/immortalwrt, openwrt-25.12) 在 ath.mk:364 写死:
#   ifdef CONFIG_ATH11K_NSS_SUPPORT
#     MODPARAMS.ath11k:=nss_offload=1 frame_mode=2   <== 问题根源
#   endif
# 该参数令无线数据帧由 NSS 硬件卸载接管，DHCP 广播不上送 CPU，
# 表现为「能连上 WiFi，但一直卡在正在获取 IP 地址」，有线 LAN 正常。
# 编译期改成 0 后，/rom/etc/modules.d/ath11k 直接就是修复态，恢复出厂也不复发。
if grep -q 'MODPARAMS.ath11k.*nss_offload=1' "$ATH_MK"; then
  sed -i '/MODPARAMS\.ath11k/ s/nss_offload=1/nss_offload=0/' "$ATH_MK"
  echo "[WB] 替换结果:"
  grep -n 'MODPARAMS.ath11k' "$ATH_MK"
  if grep -q 'MODPARAMS.ath11k.*nss_offload=1' "$ATH_MK"; then
    echo "[WB] ERROR: 替换后仍存在 nss_offload=1，中止编译（fail-fast）" >&2
    exit 1
  fi
elif grep -q 'MODPARAMS.ath11k.*nss_offload=0' "$ATH_MK"; then
  echo "[WB] 上游已是 nss_offload=0，跳过"
else
  echo "[WB] WARN: 未在 MODPARAMS.ath11k 找到 nss_offload（上游源码结构可能已变）"
  echo "[WB]       不中止编译，改由首启脚本 99-wb-fixes 在 overlay 兜底写入"
  grep -n 'nss_offload\|MODPARAMS.ath11k' "$ATH_MK" | head -20 || true
fi

echo "================ [WB 2/6] 注入 rootfs 自定义文件 ================"
# OpenWrt 构建系统会把 $(TOPDIR)/files/ 下的内容原样叠加进 rootfs。
if [ ! -d "$WORKSPACE/files" ]; then
  echo "[WB] ERROR: 仓库缺少 files/ 目录" >&2
  exit 1
fi
mkdir -p files
cp -a "$WORKSPACE/files/." files/
find files/etc/uci-defaults -type f -exec chmod 0755 {} + 2>/dev/null || true
# 手动清理离线客户端租约的脚本，必须是可执行文件
if [ -f files/usr/bin/wb-clean-clients ]; then
  chmod 0755 files/usr/bin/wb-clean-clients
  echo "[WB] 离线客户端清理脚本: 已注入 /usr/bin/wb-clean-clients (0755)"
else
  echo "[WB] WARN: files/usr/bin/wb-clean-clients 缺失，固件将不含清理命令" >&2
fi
# DHCP 静态绑定实时管理（list/bind/unbind），必须是可执行文件
if [ -f files/usr/bin/wb-dhcp ]; then
  chmod 0755 files/usr/bin/wb-dhcp
  echo "[WB] DHCP绑定管理脚本: 已注入 /usr/bin/wb-dhcp (0755)"
else
  echo "[WB] WARN: files/usr/bin/wb-dhcp 缺失，固件将不含 DHCP 绑定命令" >&2
fi
# 系统日志/内核日志页「清空日志」按钮后端，必须是可执行文件
if [ -f files/usr/bin/wb-clear-logs ]; then
  chmod 0755 files/usr/bin/wb-clear-logs
  echo "[WB] 日志清空脚本: 已注入 /usr/bin/wb-clear-logs (0755)"
else
  echo "[WB] WARN: files/usr/bin/wb-clear-logs 缺失，日志页将无清空按钮" >&2
fi
# LuCI 自定义页面：2026-11-17 起全部撤除，统一用官方页面
# 注 1：离线清理已取消独立菜单，改为「状态→概览→DHCP 租约」页内联按钮，
#       其 view/menu 已删除，仅保留下方 ACL 供按钮调用 wb-clean-clients。
# 注 2：端口转发页(wbforward)已删除——「网络→防火墙」自带「端口转发」标签页。
# 注 3：静态IP分配页(wbdhcp)已删除——「网络→DHCP/DNS」自带「静态地址分配」标签页。
#       两处读写的是同一份 UCI（redirect / config host），保留自建页面属于重复维护。
# /usr/bin/wb-dhcp 命令保留，SSH 下 wb-dhcp list|bind|unbind 仍可用于批量绑定。
if [ -f files/usr/bin/wb-dhcp ]; then
  echo "[WB] 提示: wb-dhcp 命令保留（无图形页面，走 SSH 使用）"
fi
# 菜单裁剪：隐藏「状态→防火墙」（与「网络→防火墙」重复），同时撤掉其复杂摘要页覆盖
# 实现：同路径节点被后加载的 menu.d 覆盖 depends，fs 指向永不存在的文件 → satisfied=false
#      dispatcher 建树时直接跳过，既不显示入口，也不会残留 404 死链。
if [ -f files/usr/share/luci/menu.d/zz-wb-menu-trim.json ]; then
  chmod 0644 files/usr/share/luci/menu.d/zz-wb-menu-trim.json
  echo "[WB] 菜单裁剪: 已注入 (隐藏 状态→防火墙)"
fi
# 日志页清空按钮：覆盖官方 status/syslog.js 与 status/dmesg.js，不改菜单
for wbview in syslog dmesg; do
  wbfile="files/www/luci-static/resources/view/status/$wbview.js"
  if [ -f "$wbfile" ]; then
    chmod 0644 "$wbfile"
    echo "[WB] 日志清空按钮: 已注入 (覆盖 status/$wbview.js)"
  else
    echo "[WB] WARN: $wbfile 缺失，日志页将无清空按钮" >&2
  fi
done
# 自动端口映射中文页：覆盖 luci-app-upnp 的官方视图与菜单
# 原为「服务 → UPnP IGD & PCP」，改名为「自动端口映射」并归入 网络（紧接端口转发/静态IP分配）
if [ -f files/www/luci-static/resources/view/upnp/upnp.js ] &&
   [ -f files/usr/share/luci/menu.d/luci-app-upnp.json ]; then
  chmod 0644 files/www/luci-static/resources/view/upnp/upnp.js \
             files/usr/share/luci/menu.d/luci-app-upnp.json
  echo "[WB] 自动端口映射中文页: 已注入 (view + menu，归入 网络)"
else
  echo "[WB] WARN: 自动端口映射页面文件缺失，仍显示官方「服务 → UPnP IGD & PCP」" >&2
fi

# 无菜单 ACL：授权 DHCP 租约页按钮运行 wb-clean-clients，日志页按钮运行 wb-clear-logs
if [ -f files/usr/share/rpcd/acl.d/luci-app-wbclean.json ]; then
  chmod 0644 files/usr/share/rpcd/acl.d/luci-app-wbclean.json
  echo "[WB] 离线清理/日志清空 ACL: 已注入 (无菜单)"
fi

# 设备限速（eqos）：中文页面 + 「仅走 IPv4」/「仅局域网」两列 + 保存后同步防火墙规则
#   eqos 命令本体由 luci-app-eqos 包提供（/usr/sbin/eqos），这里只覆盖页面与 init。
if [ -f files/usr/bin/wb-eqos-sync ]; then
  chmod 0755 files/usr/bin/wb-eqos-sync
  echo "[WB] 仅局域网/仅走IPv4 同步脚本: 已注入 /usr/bin/wb-eqos-sync (0755)"
fi
if [ -f files/www/luci-static/resources/view/eqos.js ]; then
  chmod 0644 files/www/luci-static/resources/view/eqos.js
  echo "[WB] 设备限速中文页: 已注入 (覆盖 view/eqos.js，含仅走IPv4/仅局域网两列)"
fi
if [ -f files/etc/init.d/eqos ]; then
  chmod 0755 files/etc/init.d/eqos
  echo "[WB] eqos 启动脚本: 已覆盖 (reload 时调用 wb-eqos-sync)"
fi
if [ -f files/usr/share/luci/menu.d/luci-app-eqos.json ]; then
  chmod 0644 files/usr/share/luci/menu.d/luci-app-eqos.json
  echo "[WB] 设备限速菜单: 已注入 (服务 → 设备限速，order 60)"
fi

# 带宽统计（nlbwmon）：默认关闭 + 只保留 1 个账期 + 页面顶部开关按钮
if [ -f files/usr/bin/wb-nlbw ]; then
  chmod 0755 files/usr/bin/wb-nlbw
  echo "[WB] 带宽统计开关脚本: 已注入 /usr/bin/wb-nlbw (0755，含 conntrack acct 收尾)"
fi
if [ -f files/www/luci-static/resources/view/nlbw/display.js ]; then
  chmod 0644 files/www/luci-static/resources/view/nlbw/display.js
  echo "[WB] 带宽统计开关按钮: 已注入 (覆盖 view/nlbw/display.js)"
fi
if [ -f files/usr/share/rpcd/acl.d/luci-app-wbnlbw.json ]; then
  chmod 0644 files/usr/share/rpcd/acl.d/luci-app-wbnlbw.json
  echo "[WB] 带宽统计 ACL: 已注入 (供页面按钮调用 wb-nlbw)"
fi

echo "================ [WB 3/6] 校验 Wi-Fi 默认脚本路径 ================"
# 之前云编译 sed package/kernel/mac80211/files/lib/wifi/mac80211.sh 报「文件不存在」，
# 是因为 ImmortalWrt 25.12 起该脚本改成 ucode 实现并迁移到
#   package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc
# 本方案不在编译期 sed 它，SSID 由首启 uci-defaults 设置，避免上游改名导致静默失效。
if [ -f package/kernel/mac80211/files/lib/wifi/mac80211.sh ]; then
  echo "[WB] 检测到旧版 mac80211.sh（本次不修改）"
elif [ -f package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc ]; then
  echo "[WB] 检测到新版 mac80211.uc —— 这就是当初 sed 报文件不存在的原因"
else
  echo "[WB] WARN: 两种 wifi 脚本都未找到，SSID 仍由 uci-defaults 兜底设置"
fi

echo "================ [WB 4/6] 装入 EasyTier 包源 ================"
# JDCloud.config:16 写了 CONFIG_PACKAGE_luci-app-easytier=y，但 upstream 源码树、
# immortalwrt/packages、immortalwrt/luci 里都没有这个包，make defconfig 会静默丢弃
# （这正是旧固件里「配置写了却没装」的原因）。这里补上官方包源。
# 仓库仅 435KB；easytier/Makefile 用 wget 拉预编译 aarch64 zip，不做 Rust 交叉编译。
ET_REPO="https://github.com/EasyTier/luci-app-easytier.git"
if git clone --depth 1 -b main "$ET_REPO" "$TMP/easytier-src" >/dev/null 2>&1; then
  rm -rf package/easytier package/luci-app-easytier
  mkdir -p package/easytier package/luci-app-easytier
  cp -a "$TMP/easytier-src/easytier/."            package/easytier/
  cp -a "$TMP/easytier-src/luci-app-easytier/."   package/luci-app-easytier/
  cp -a "$TMP/easytier-src/version.mk"            package/easytier/version.mk
  cp -a "$TMP/easytier-src/version.mk"            package/luci-app-easytier/version.mk
  # 原 Makefile 用 -include $(dir ...)../version.mk 找仓库根的 version.mk；
  # 拆成两个顶层包目录后改为各自同目录的 version.mk。
  sed -i 's|\.\./version\.mk|version.mk|g' package/easytier/Makefile package/luci-app-easytier/Makefile
  echo "[WB] EasyTier 版本: $(grep EASYTIER_VERSION "$TMP/easytier-src/version.mk" | head -1)"
  grep -n 'version.mk' package/easytier/Makefile package/luci-app-easytier/Makefile || true

  # ---- 菜单归并：顶层「VPN」→「服务 / EasyTier」 ----
  # 上游把 EasyTier 挂在 admin/vpn 下并自建一个顶层「VPN」分类。本机不跑副路由
  # EasyTier（方案 3 由 NAS 的 EasyTier 做子网代理），那个分类只剩一个空壳，
  # 故把整棵子树搬到 admin/services，order 55 排在 ACME(50) 之后。
  # 关键：5 个 htm 模板里的 AJAX 地址硬编码 admin/vpn/easytier（分段 url() 与
  # 单字符串 url("admin/vpn/...") 两种写法都有），必须与控制器同步改，漏一处即 404。
  ET_PKG=package/luci-app-easytier
  sed -i \
    -e '/entry({"admin", "vpn"}, firstchild(), "VPN", 45)/d' \
    -e 's|{"admin", "vpn", "easytier"|{"admin", "services", "easytier"|g' \
    -e 's|{"admin","vpn","easytier"|{"admin","services","easytier"|g' \
    -e 's|_("EasyTier"), 46|_("EasyTier"), 55|' \
    "$ET_PKG/luasrc/controller/easytier.lua"
  for etpl in "$ET_PKG"/luasrc/view/easytier/*.htm; do
    sed -i \
      -e 's|url("admin", "vpn", "easytier"|url("admin", "services", "easytier"|g' \
      -e 's|url("admin","vpn","easytier"|url("admin","services","easytier"|g' \
      -e 's|url("admin/vpn/easytier/|url("admin/services/easytier/|g' \
      -e "s|url('admin/vpn/easytier/|url('admin/services/easytier/|g" \
      -e 's|url("admin/vpn/easytier")|url("admin/services/easytier")|g' \
      "$etpl"
  done
  # 残留校验：宁可编译失败，也不出「菜单搬了但按钮全 404」的半成品。
  # 正则 admin.{0,8}vpn 同时覆盖 "admin", "vpn" / "admin/vpn" / 无空格变体。
  if grep -rnE 'admin.{0,8}vpn' "$ET_PKG/luasrc/" >/dev/null 2>&1; then
    echo "[WB] ERROR: EasyTier 菜单归并后仍有 admin/vpn 残留，固件会带坏页面：" >&2
    grep -rnE 'admin.{0,8}vpn' "$ET_PKG/luasrc/" >&2
    exit 1
  fi
  echo "[WB] EasyTier 菜单已归并: 顶层 VPN → 服务/EasyTier (order 55)"

  echo "[WB] 已装入 package/easytier + package/luci-app-easytier"
else
  # fail-soft：源站偶发不可达不该让整个编译失败，但必须显式告警
  echo "[WB] WARN: EasyTier 源 clone 失败，本次固件不含 EasyTier（不影响其余功能）" >&2
fi

echo "================ [WB 5/6] 内置 Mihomo 内核（OpenClash）================"
# luci-app-openclash 已由 immortalwrt/luci feed 自带（0.48.002，与实机手动装的同版本），
# 无需 clone 那个 45GB 的 vernesong/OpenClash 仓库。但内核二进制不在任何 feed 里，
# 且从 0 刷机时代理未配好、无法联网下载内核，因此必须在编译期注入 rootfs。
# 架构: IPQ6000 = aarch64 → mihomo-linux-arm64
MIHOMO_VER="v1.19.33"
MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VER}/mihomo-linux-arm64-${MIHOMO_VER}.gz"
CORE_DIR="files/etc/openclash/core"
mkdir -p "$CORE_DIR"
if curl -fL --retry 3 --retry-delay 3 --connect-timeout 20 -o "$TMP/mihomo.gz" "$MIHOMO_URL"; then
  # install -m 一步设定可执行位（Windows/Git Bash 本地模拟时 chmod 可能不生效，
  # 真实 Actions 为 Ubuntu，无此问题）
  gzip -dc "$TMP/mihomo.gz" > "$TMP/clash_meta"
  install -m 0755 "$TMP/clash_meta" "$CORE_DIR/clash_meta"
  echo "[WB] Mihomo $MIHOMO_VER 已注入: $(ls -lh "$CORE_DIR/clash_meta" | awk '{print $5}')"
  # 交叉架构二进制无法在 x86_64 编译机执行，只校验文件类型/架构
  file "$CORE_DIR/clash_meta" 2>/dev/null || true
else
  echo "[WB] WARN: Mihomo 下载失败 $MIHOMO_URL" >&2
  echo "[WB]       固件仍能编出，但 OpenClash 需刷机后联网手动下载内核" >&2
fi

echo "================ [WB 6/6] 摘要（请在 Actions 日志中核对）================"
echo "[WB] 源码分支      : $(git -C . branch --show-current 2>/dev/null || echo detached)"
echo "[WB] 内核版本文件  : $(ls target/linux/generic/ 2>/dev/null | grep '^kernel-' | tr '\n' ' ')"
echo "[WB] ath11k 参数    : $(grep -h 'MODPARAMS.ath11k' "$ATH_MK" | tr -d '\t')"
echo "[WB] OpenClash 包   : $(test -f feeds/luci/applications/luci-app-openclash/Makefile && echo 'luci feed 自带' || echo '未在 luci feed 找到（需检查 feeds install）')"
echo "[WB] Mihomo 内核    : $(test -s "$CORE_DIR/clash_meta" && echo '已内置' || echo '缺失')"
echo "[WB] EasyTier 包    : $(test -f package/easytier/Makefile && echo '已装入' || echo '缺失')"
echo "[WB] 注入文件数    : $(find files -type f | wc -l)"
echo "[WB] 完成：固件自带 nss_offload=0 / 双频 AP 中性默认 / uci-defaults / 代理内核"
