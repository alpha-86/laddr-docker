# OpenWrt ShadowSocksR Plus+ 客户端场景：服务端日志只打 IP 的分析与解决

> 日期：2026-10-20
> 分支：b1
> 相关文档：[README-001-xray-accesslog-hostname.md](README-001-xray-accesslog-hostname.md)（服务端日志打域名的一般原理）
> 涉及仓库：`fw876/helloworld`（luci-app-ssr-plus）、`XTLS/Xray-core`
> 案例环境：OpenWrt R24.2.2 GDQ V1 [2024]（eSir 编译），luci-app-ssr-plus **188-5**

## 1. 背景

路由器跑 OpenWrt + ShadowSocksR Plus+（下称 ssr-plus），局域网设备透明代理上网。
服务端（本项目 laddr-docker）的 xray access log 里，这些流量只打 IP：

```
accepted tcp:142.251.x.x:443    ← 没有 host
```

按 [README-001](README-001-xray-accesslog-hostname.md) 第 3.1 节的原理：access log 的
目标是 **VLESS 请求头携带的目标**，域名丢失发生在客户端链路。本文分析 ssr-plus
各版本客户端配置的默认行为、定位丢失点并给出解决办法。

## 2. ssr-plus 是如何发出代理请求的

透明（NAT）模式下，xray 不主动解析域名，它收到的是被 iptables 劫持的连接：

```
LAN 设备 → 路由器 dnsmasq 解析域名（国内直接 / gfwlist 走远程 DNS）→ 得到 IP
    → 设备向 IP:443 发起 TCP
    → nftables/iptables（ssr-rules）按 ipset 匹配 → REDIRECT 到 127.0.0.1:<local_port>
    → xray dokodemo-door 入站：getsockopt(SO_ORIGINAL_DST) 恢复原始目标 = IP
    → 【关键节点】sniffing 嗅探 TLS ClientHello / HTTP Host
    → destOverride 把目标从 IP 覆写成域名（若 sniffing 开启）
    → routing（domainStrategy: AsIs）→ 节点出站
    → VLESS 请求头携带目标 → 服务端
```

注意两个事实：

- 进入 xray 的原始目标**一定是 IP**（设备先解析再连接，iptable 只搬 IP 包），
  所以**域名能否进 VLESS 请求头，完全取决于 dokodemo 入站的 sniffing 是否开启**；
- 未启用 TPROXY（`-u`）时，ssr-rules 会直接 **drop UDP 443**（`ssr-rules:672-679`），
  QUIC 被强制回退 TCP，因此 TCP 路径的嗅探行为是决定性因素。

## 3. 各版本 gen_config.lua 的行为差异

ssr-plus 通过 `/usr/share/shadowsocksr/gen_config.lua` 生成 xray 配置，
dokodemo 入站的 sniffing 配置随版本变化很大：

| 版本 | 提交 / 日期 | sniffing 配置 | 订阅节点的实际效果 |
|---|---|---|---|
| 2022 时代 | `bbceff7` | `sniffing = { enabled = true, destOverride = {"http","tls"} }`（硬编码开，无 quic） | 域名可恢复 ✅ |
| **188-5** | `d940196` / 2024-03-21 | `enabled = (server.custom_sniffing == "1")`（**可选，见下文陷阱**），destOverride 含 quic | **默认关 → 只有 IP** ❌ |
| 188-6 起 | `e1b6d62` / 2024-06-21 | custom_sniffing 判断被移除，`enabled = true` 无条件开启 | 域名可恢复 ✅ |
| master（v196，2026） | — | `enabled = true` + destOverride http/tls/quic + domainsExcluded | 域名可恢复 ✅（但 vless/vmess 已迁 mihomo，见 5.3） |

### 3.1 188-5 的三层陷阱（本案例的根因）

188-5 的 sniffing 由节点级选项 `custom_sniffing` 控制，默认值有三层"看起来的默认"：

1. **LuCI 表单默认开**：`client-config.lua` 中 `o.default = true`、`rmempty = false`，
   在 LuCI 里新建/编辑并保存节点时会写入 `option custom_sniffing '1'`；
2. **订阅导入的节点没有此字段**：`subscribe.lua` 不写 `custom_sniffing`，
   从未编辑过的订阅节点 `server.custom_sniffing = nil` → `nil == "1"` 为 false
   → **sniffing 关闭** → 透明代理目标保持 IP → VLESS 携带 IP → 服务端只打 IP；
3. **`custom_routeOnly` 不要勾**：`routeOnly = true` 时嗅探到的域名只用于
   xray 内部分流、**不覆写目标**，VLESS 请求头仍然是 IP（开了 sniffing 也白开）。

案例用户（188-5，订阅节点）正是踩中第 2 条。

### 3.2 socks5 入站一直没有 sniffing

各版本的 socks 入站（`inboundDetour`，LuCI「SOCKS5 代理服务端」）均无 sniffing。
走该端口的应用若本地解析 DNS 后把 IP 交给代理（curl `--socks5`、部分 APP 的行为），
目标就是 IP——与 [README-001](README-001-xray-accesslog-hostname.md) 第 3.2 节
描述的测试脚本问题完全同构。

### 3.3 `sockopt.domainStrategy` 的澄清

- 188-5 的 vless 出站 sockopt 只有 `tcpFastOpen`，**没有** `domainStrategy`；
- master 的出站 sockopt 有 `domainStrategy = server.domain_strategy or "UseIP"`，
  但经 Xray-core 源码核实（`transport/internet/dialer.go`），它只解析**拨号目标**
  （对 VLESS 出站即服务器地址），**不改写 VLESS 请求头**；改写请求头的是出站顶层
  `targetStrategy` 字段，ssr-plus 并未设置；
- 因此 **ssr-plus 任何版本都不存在"出站把域名解析成 IP 塞进请求头"的行为**，
  域名丢失只在入站侧（sniffing 未开 / routeOnly / socks 路径 / 无 SNI 流量）。

### 3.4 其它无 host 的场景（非版本问题）

- 无 SNI 的 TLS（ECH、部分 APP）、纯 IP 连接：无法嗅探，天然只有 IP；
- UDP/QUIC：188-5 的 destOverride 已含 `quic`，xray 1.8.x 有 quic sniffer，
  多数可恢复；老版本（2022）destOverride 无 quic 时 UDP 流量只有 IP。

## 4. 解决办法

### 4.1 勾选「流量嗅探」（推荐，本案例已验证）

LuCI → 节点设置 → 勾「**流量嗅探**」（`custom_sniffing`），
「嗅探得到的域名仅用于 Xray 路由」（`custom_routeOnly`）保持不勾 → 保存应用。
每个节点设一次即可，**订阅更新不会覆盖此字段**（subscribe.lua 不写它）。

SSH 批量方式（所有 v2ray 类型节点）：

```bash
for s in $(uci show shadowsocksr | awk -F'[.=]' '$3=="type" && $4 ~ /v2ray/ {print $2}'); do
    uci set shadowsocksr.$s.custom_sniffing='1'
    uci set shadowsocksr.$s.custom_routeOnly='0'
done
uci commit shadowsocksr
/etc/init.d/shadowsocksr restart
```

验证（路由器上）：

```bash
uci get shadowsocksr.<节点>.custom_sniffing    # 应为 1
grep -A3 '"sniffing"' /var/etc/ssrplus/ssr-*.json   # enabled 应为 true
```

验证（服务端）：access log 对 TLS/HTTP 流量出现
`accepted tcp:www.google.com:443` 形式的记录。

### 4.2 直接补丁路由器上的生成脚本

```bash
sed -i 's/enabled = (server.custom_sniffing == "1") and true or false/enabled = true/' \
    /usr/share/shadowsocksr/gen_config.lua
/etc/init.d/shadowsocksr restart
```

等效 188-6 之后的行为，对所有节点（含将来订阅新增的）生效。
缺点：重装/升级 luci-app-ssr-plus 包会被覆盖。

### 4.3 升级 ssr-plus

- **版本边界**：188-6（2024-06-21）起 sniffing 无条件开启，≥188-6 即修复本问题；
- **不建议在老 snapshot 固件上单刷 ipk**：opkg 源滚动导致依赖 ABI 漂移；
  v196 系还把 vless/vmess/ss 迁到 mihomo（Clash Meta 内核）、DNS 组件整体换代
  （chinadns-ng 取代 mosdns/dns2socks），单换包缺依赖且行为大变；
- 固件用户（如 eSir 系列）正确姿势是**随新固件升级**（保留配置刷机）；
  2024-06-21 之后编译的固件均含 ≥188-6 的 ssr-plus。

### 4.4 服务端兜底（不改客户端）

按 [README-001](README-001-xray-accesslog-hostname.md) 第 6.2 节：
服务端 `loglevel` 调 `info` 后，error log 中的 `sniffed domain: <域名>`
可按时间戳与 access log 关联补出 SNI（access log 目标仍是 IP）。

## 5. 排查速查表

| 现象 | 可能原因 | 处理 |
|---|---|---|
| 全部流量（tcp/udp）只有 IP | 188-5 + 订阅节点，sniffing 未开（本文根因） | 4.1 / 4.2 |
| 开了嗅探仍只有 IP | `custom_routeOnly` 被勾上 | 取消勾选（4.1） |
| 仅走 SOCKS5 端口的应用只有 IP | socks 入站无 sniffing + 应用本地解析 | 应用侧远程解析，或换透明模式 |
| 仅 UDP/QUIC 只有 IP | 老版本 destOverride 无 quic | 升级，或保持默认 drop UDP443 回退 TCP |
| 个别目标只有 IP | ECH / 无 SNI / 纯 IP 连接 | 无法恢复，属正常 |
| 任何客户端都只有 IP | 客户端配置正常但仍异常 | 回到 [README-001](README-001-xray-accesslog-hostname.md) 第 9 节排查 |
