# Xray 服务端 access log 打印目标域名（hostname）的原理

> 日期：2026-05-19
> 分支：b1
> 相关代码：`scripts/test.sh`、`xray/etc/config.json.tpl`

## 1. 背景

测试脚本 `scripts/test.sh` 的 case 5 / case 6 会启动一个本地 Xray 客户端（SOCKS5 入站 + VLESS 出站），
通过完整链路请求 `https://www.google.com`，并在**服务端** access log 中断言：

```bash
# test.sh:810（case 5，Vision）
grep 'from.*accepted.*www.google.com' log/xray_access.log
```

即服务端日志必须打出形如 `accepted tcp:www.google.com:443` 的记录，而不是纯 IP。

## 2. 问题现象

如果客户端直接把目标 IP 发给服务端，服务端日志只会打：

```
accepted tcp:142.251.x.x:443    ← 没有 host，断言失败
```

## 3. 根因分析

### 3.1 access log 记录的是 VLESS 请求头携带的目标地址

Xray 的 VLESS 入站在记录 access log 时，使用的是 **VLESS 请求头中的目标地址**
（`proxy/vless/inbound` 里的 `request.Destination()`），也就是**客户端发什么就记什么**。
服务端后续的 sniffing 覆写发生在记录日志之后，只影响路由和实际出口，**不会改变日志中的目标**。

因此，想让日志里出现域名，唯一办法是让 **VLESS 请求头本身就携带域名**。

### 3.2 `curl --socks5` 会把目标变成 IP

测试发起请求的方式（`test.sh:687` / `test.sh:1215`）：

```bash
curl -s --socks5 127.0.0.1:11080 ... https://www.google.com
```

curl 的 `--socks5`（区别于 `--socks5-hostname`）会**在本地先做 DNS 解析**，
然后把解析出的 IP（如 `142.251.x.x:443`）作为目标交给 SOCKS5 代理。
于是客户端 Xray 的 SOCKS 入站收到的目标就是 IP，直接转发的话服务端日志自然只有 IP。

## 4. 解决方案：客户端入站开启 sniffing + destOverride

`test.sh` 生成的客户端配置（`test.sh:545-549`，case 6 在 `test.sh:1068-1072` 同样配置）
给 SOCKS 入站加了 sniffing：

```json
"sniffing": {
  "enabled": true,
  "destOverride": ["http", "tls"],
  "metadataOnly": false
}
```

工作原理：

1. curl 虽然只给了 SOCKS 入站一个 **IP** 目标，但流量是 TLS，首包 ClientHello 中带有
   **SNI = `www.google.com`**；
2. `destOverride: ["http", "tls"]` 让 Xray 解析真实负载，从 TLS ClientHello（或 HTTP 请求的
   Host 头）中嗅探出域名，并**把连接目标从 IP 覆写成嗅探到的域名**；
3. 之后 VLESS 出站发给服务端的目标就是 `www.google.com:443`，服务端日志即可打出
   `accepted tcp:www.google.com:443`。

要点：

- `metadataOnly: false` 是关键。若为 `true`，Xray 只依赖连接元数据（即入站拿到的 IP），
  不会解析负载，无法完成覆写。
- routing 使用 `"domainStrategy": "AsIs"`（`test.sh:587`），域名原样使用，不做额外解析。
- 该方案对真实客户端场景同样有效：浏览器等应用本来就经常先解析成 IP 再连代理，
  行为与测试一致。也可改用 `curl --socks5-hostname` 让 SOCKS 入站直接收到域名来绕过，
 但 sniffing 方案更通用。

## 5. 服务端 sniffing 的作用（为什么不靠它解决日志问题）

服务端 `xray/etc/config.json.tpl` 的两个入站也开了 sniffing：

```json
// 9000（Vision）
"sniffing": { "enabled": true, "destOverride": ["http", "tls"] }

// 9001（XHTTP）
"sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
```

但它的职责不同，**解决不了日志打域名的问题**：

| 位置 | 作用 |
|---|---|
| 服务端 sniffing | 路由匹配（`geosite:google → direct` 等域名规则需要域名才能命中）+ 实际出口目标覆写；**不改变 access log 记录的目标** |
| 客户端 sniffing | 让 VLESS 请求头携带域名，**这才是日志里能打出 host 的关键** |

服务端配置中与之配合的其它关键点：

- `"domainStrategy": "IPIfNonMatch"`：无域名规则命中时按 IP 再匹配一次；
- `"acceptProxyProtocol": true`（9000）：接收 HAProxy 的 PROXY Protocol v2，
  日志中的 `from` 才能显示真实来源 IP；
- `"rejectUnknownSni": true`（9000）：SNI 不在证书列表中的 TLS 连接直接拒绝，抗主动探测；
- 路由：`geosite:google → direct`（Google 走直连出口），`geoip:cn / geoip:private → blocked`。

## 6. 完整链路验证（test.sh case 5 / 6）

```
curl --socks5 127.0.0.1:11080 https://www.google.com
    │  本地解析 DNS，SOCKS 目标 = IP
    ▼
客户端 Xray SOCKS 入站
    │  sniffing 嗅探 ClientHello SNI → destOverride 覆写目标为 www.google.com:443
    ▼
客户端 VLESS 出站（serverName = 测试域名，SNI 路由到 xray_backend）
    │  VLESS 请求头目标 = www.google.com:443   ← 关键
    ▼
HAProxy :443（SNI 匹配 → 18910/18911）
    ▼
服务端 Xray 入站
    ├─ access log：accepted tcp:www.google.com:443   （test.sh:810 断言）
    ├─ sniffing：路由 geosite:google → direct
    ▼
freedom outbound → www.google.com
```

测试的三段式断言：

1. **客户端日志**（`xray_test_access.log`）：确认请求确实经过客户端代理；
2. **HAProxy 日志**（`log/haproxy_access.log`）：`grep 'sni:$XRAY_TEST_DOMAIN'` 确认 SNI 路由到 `xray_backend`；
3. **服务端日志**（`log/xray_access.log`）：`grep 'from.*accepted.*www.google.com'` 确认
   VLESS 目标携带域名、服务端正确处理。

## 7. 配置速查

### 客户端（测试脚本生成）

```json
{
  "inbounds": [{
    "protocol": "socks",
    "sniffing": {
      "enabled": true,
      "destOverride": ["http", "tls"],
      "metadataOnly": false
    }
  }],
  "outbounds": [{ "protocol": "vless", "streamSettings": { "network": "tcp", "security": "tls" } }],
  "routing": { "domainStrategy": "AsIs" }
}
```

### 服务端（xray/etc/config.json.tpl 节选）

```json
{
  "inbounds": [
    { "port": 9000, "protocol": "vless",
      "streamSettings": { "tcpSettings": { "acceptProxyProtocol": true },
                          "tlsSettings": { "rejectUnknownSni": true } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] } },
    { "port": 9001, "protocol": "vless",
      "streamSettings": { "network": "xhttp", "security": "reality" },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] } }
  ],
  "routing": { "domainStrategy": "IPIfNonMatch" }
}
```

## 8. 排查要点

服务端日志只打 IP、没有 host 时，按顺序检查：

1. **客户端入站是否开启 sniffing + destOverride**（且 `metadataOnly: false`）——最常见原因；
2. 应用是否把 IP 而不是域名交给代理（如 `curl --socks5` 本地解析）；
3. 客户端 routing 的 `domainStrategy` 是否把域名提前解析成了 IP（如 `UseIP`）；
4. 不要把希望寄托在服务端 sniffing 上——它只影响路由和出口，不改变日志记录的目标。
