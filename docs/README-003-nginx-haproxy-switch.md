# 默认 Nginx 直连入口 + HAProxy 可选切换 设计文档

> 日期：2026-11-02
> 分支：b1
> 状态：设计已对齐确认，本文档即开发规格说明
> 相关代码：`docker-compose.yml`、`docker-compose-xray.yml`、`gen_env.sh`、`haproxy/`、`nginx/`、`xray/etc/config.json.tpl`、`scripts/`
> 参考项目：`~/docker-box`（nginx stream 做 SNI 入口的成熟先例）
> 相关文档：[README-001-xray-accesslog-hostname.md](README-001-xray-accesslog-hostname.md)、[README-002-ssr-plus-accesslog-hostname.md](README-002-ssr-plus-accesslog-hostname.md)（切换后 case 5/6 的服务端日志域名断言逻辑不变）

## 1. 背景与目标

### 1.1 现状

443 入口是 HAProxy（`haproxy.cfg.tpl` 的 `frontend https_frontend`），按 SNI 正则 map 分流：

```
443 → HAProxy
        x|xyz|api|dt|ai.*.*.*   → 127.0.0.1:18910  Vision (send-proxy-v2)
        ${REALITY_DEST}          → 127.0.0.1:18911  XHTTP+REALITY（纯 TCP，不发 PP）
        web|app|cdn.*.*.*        → 127.0.0.1:18911  XHTTP+REALITY（纯 TCP）
        nf|netflix|nfx|nfv.*.*.* → ${NF_XTLS_SERVER} (send-proxy-v2)
        default                  → 127.0.0.1:8443   nginx (send-proxy-v2)
80 → nginx http；8443 → nginx http (ssl proxy_protocol)
```

nginx 只是"默认后端"，`server_params` 以 `listen 8443 ssl proxy_protocol` 运行。

### 1.2 目标

1. **默认模式改为 nginx 直连 443**：nginx stream（ssl_preread）做 SNI 路由，结构完全参考 docker-box，不增加转发跳数。
2. **HAProxy 拆分为 `docker-compose-haproxy.yml`**，默认不启用。
3. **初始化可选启用**：`gen_env.sh` 交互询问（y/N，默认 N），选 y 时 `.env` 的 `COMPOSE_FILE` 追加 `:docker-compose-haproxy.yml`。
4. **`scripts/ngx_haproxy_switch.sh`**：支持在线互切（haproxy ↔ nginx），仅服务器本机执行。
5. **任何模式下都不能丢失 proxy protocol 传递的真实客户端 IP**（xray/nginx 日志依赖）。

## 2. 现状分析

### 2.1 两项目对照

| | docker-box（参考） | laddr-docker（现状） |
|---|---|---|
| 443 入口 | nginx stream（ssl_preread + proxy_protocol on 全局） | HAProxy（SNI regex map） |
| PP 粒度 | server 级全局 on，上游全都接受 PP | backend 级，可逐后端控制 |
| xhttp 后端 | 无（上一代协议栈） | 有，且**不能接受 PP 头** |
| stream map | 静态文件 `conf.d/xray.stream` | entrypoint sed 渲染 `sni_routing.map` |
| nginx http | 80 + 8443 ssl proxy_protocol | 80 + 8443 ssl proxy_protocol（完全相同） |

### 2.2 三个难点

1. **PP 粒度**：xhttp+REALITY 后端收到 PP 头会破坏 REALITY 握手（`haproxy.cfg.tpl:43` 明确注释"XHTTP+REALITY doesn't support proxy protocol"）；而 nginx stream 的 `proxy_protocol` 指令只在 `stream/server` 上下文生效，**不能按 upstream 区分**。
2. **443 独占**：两种模式的 443 监听者不同，配置必须按模式隔离。
3. **环境变量渲染**：`${REALITY_DEST}`、`${NF_XTLS_SERVER}` 是每个部署不同的值，nginx 自身读不了环境变量。

### 2.3 关键验证结论：xhttp 支持 acceptProxyProtocol（sockopt 层）

设计成立的前提，已对 Xray-core 源码验证（main 分支）：

- `transport/internet/system_listener.go:170`——`ListenSystem` 对**所有 transport** 统一处理：

  ```go
  if err == nil && sockopt != nil && sockopt.AcceptProxyProtocol {
      policyFunc := func(upstream net.Addr) (proxyproto.Policy, error) { return proxyproto.REQUIRE, nil }
      l = &proxyproto.Listener{Listener: l, Policy: policyFunc}
  }
  ```

- `transport/internet/splithttp/hub.go:538`——`ListenXH` 的监听链是 `internet.ListenSystem` → REALITY → `http.Server`，PP 解析在 REALITY 握手**之前**完成，互不干扰。
- `transport/internet/tcp/hub.go:40`——现有 vision 配置的 `tcpSettings.acceptProxyProtocol` 也是合并进 `SocketSettings.AcceptProxyProtocol` 后走同一条路径，两种写法等价。

**推论**：

1. xhttp inbound 只需在 `streamSettings` 加 `"sockopt": {"acceptProxyProtocol": true}` 即可接收 PP 头。
2. policy 为 **REQUIRE**——到 18911 的每条连接必须带 PP 头。因此 HAProxy 模式的 `xhttp_backend` 必须同步加 `send-proxy-v2`（连锁改动，见 3.3）。
3. 两个模式都向 xray 发 PP，xray 配置双模式一致，**切换模式时 xray 无需重建**。

## 3. 设计方案

### 3.1 总体架构（nginx 默认模式）

```
443 ──▶ nginx stream (ssl_preread on, proxy_protocol on 全局)
          map $ssl_preread_server_name $tcp_backend:
            ~^(?i)(x|xyz|api|dt|ai)\.[^.]+\.[^.]+\.[^.]+$      xray
            ~^(?i)^${REALITY_DEST}$                            xhttp
            ~^(?i)^(web|app|cdn)\.[^.]+\.[^.]+\.[^.]+$         xhttp
            ~^(?i)^(nf|netflix|nfx|nfv)\.[^.]+\.[^.]+\.[^.]+$  nf_xtls
            default                                            ngx
          upstream: xray→127.0.0.1:18910  xhttp→127.0.0.1:18911
                   ngx→127.0.0.1:8443    nf_xtls→${NF_XTLS_SERVER}
80 / 8443 ──▶ nginx http（server_params 不动）
```

与 docker-box 结构 1:1，**零额外转发跳数**。

### 3.2 nginx 配置：两套文件 + 激活文件

```
nginx/conf/tcp_stream_params                 # 新增（恒包含）：stream{} 骨架
nginx/conf/conf.d/
├── xray.stream.ngx                          # nginx 模式全量：443 server + upstreams + map
├── xray.stream.haproxy                      # 空文件（仅注释说明 443 由 HAProxy 接管）
└── xray.stream                              # 激活文件（生成物，不入 git，.gitignore 新增）
```

`tcp_stream_params`（内容恒定，与模式无关）：

```nginx
stream {
    log_format proxy '$remote_addr:$remote_port [$time_local] '
                     '$ssl_preread_server_name $protocol $status $bytes_sent $bytes_received '
                     '$session_time "$upstream_addr" '
                     '"$upstream_bytes_sent" "$upstream_bytes_received" "$upstream_connect_time"';
    access_log /var/log/nginx/stream.log proxy;
    include /etc/nginx/conf.d/*.stream;
}
```

`xray.stream.ngx`（含 `${REALITY_DEST}`、`${NF_XTLS_SERVER}` 占位符，由宿主脚本渲染）：

```nginx
upstream xray {
    server 127.0.0.1:18910;
}
upstream xhttp {
    server 127.0.0.1:18911;
}
upstream ngx {
    server 127.0.0.1:8443;
}
upstream nf_xtls {
    server ${NF_XTLS_SERVER};
}

map $ssl_preread_server_name $tcp_backend {
    ~^(?i)(x|xyz|api|dt|ai)\.[^.]+\.[^.]+\.[^.]+$      xray;
    ~^(?i)^${REALITY_DEST}$                           xhttp;
    ~^(?i)^(web|app|cdn)\.[^.]+\.[^.]+\.[^.]+$        xhttp;
    ~^(?i)^(nf|netflix|nfx|nfv)\.[^.]+\.[^.]+\.[^.]+$  nf_xtls;
    default                                            ngx;
}

server {
    listen 443;
    listen [::]:443;
    ssl_preread on;
    proxy_protocol on;
    proxy_pass $tcp_backend;
}
```

**与 docker-box 的差异说明**：docker-box 把 `listen 443` 的 server 放在恒包含的 `tcp_stream_params` 里，是因为它只有 nginx 一种模式。本项目 haproxy 模式下 443 归 HAProxy，若照抄会导致 bind 冲突。因此 **443 server 必须放在可切换的 `xray.stream.ngx` 里**，恒包含文件只留骨架。

map 正则统一加 `(?i)`（docker-box 未加；客户端 SNI 事实全小写，加上更稳且无害）。

### 3.3 连锁改动（各一行）

| 文件 | 改动 | 原因 |
|---|---|---|
| `xray/etc/config.json.tpl` | xhttp inbound 的 `streamSettings` 增加 `"sockopt": {"acceptProxyProtocol": true}` | xhttp 要能收 PP（REQUIRE 策略） |
| `haproxy/haproxy.cfg.tpl` | `backend xhttp_backend` 的 server 增加 `send-proxy-v2`（同时更新 `:43` 注释） | 否则 HAProxy 模式下 xhttp 因 REQUIRE 全部拒绝连接 |

**升级注意**：旧 haproxy 容器（不发 PP）+ 新 xray（REQUIRE PP）= xhttp 全挂。两个改动必须同批部署——`deploy.sh` 全量 rsync + restart 天然满足；**禁止单独更新 xray 容器**。

### 3.4 compose 拆分

- **`docker-compose.yml`**：只留 nginx + acme.sh；nginx volumes 增加 `${DOCKER_BOX_HOME}/log/nginx_stream.log:/var/log/nginx/stream.log`。
- **`docker-compose-haproxy.yml`**（新增）：haproxy service 整体迁入（entrypoint 的 sed 渲染、rsyslog 等机制原样保留，仅搬家）；`depends_on: nginx` 跨文件依然有效。
- **`docker-compose-xray.yml`**：不动。

### 3.5 gen_env.sh

- `COMPOSE_FILE` 默认值改为 `docker-compose.yml:docker-compose-xray.yml`（默认不含 haproxy）。
- 交互询问（仅当 stdin 为 TTY 且 `.env` 不存在时）：「启用 HAProxy 作为 443 入口？[y/N]」，选 y 则 `COMPOSE_FILE=docker-compose.yml:docker-compose-xray.yml:docker-compose-haproxy.yml`。
- `.env` 已存在时沿用现有值（现有 `var_exists` 逻辑），打印当前模式，不重复询问；非交互环境默认 nginx。
- 写完 `.env` 后同步生成激活文件：nginx 模式渲染 `xray.stream.ngx` → `conf.d/xray.stream`（sed `${REALITY_DEST}` 点号转义、`${NF_XTLS_SERVER}`，转义逻辑参照 `haproxy/entrypoint.sh`）；haproxy 模式拷贝 `xray.stream.haproxy` → `conf.d/xray.stream`。
- **不引入 `EDGE_PROXY` 变量**：模式事实源 = `COMPOSE_FILE` 内容 + 激活文件，两者由脚本同步修改，容器内零决策逻辑。

### 3.6 scripts/ngx_haproxy_switch.sh

用法（仅服务器本机执行）：

```bash
scripts/ngx_haproxy_switch.sh nginx|haproxy|status
```

- **status**：读取 `.env` COMPOSE_FILE 判断当前模式；显示 haproxy 容器状态、443 占用者（`ss -tlnp`）。
- **→ haproxy**：
  1. 幂等检查：COMPOSE_FILE 已含 `docker-compose-haproxy.yml` 则提示并退出。
  2. 备份 `conf.d/xray.stream` 与 `.env` 行。
  3. `.env` COMPOSE_FILE 追加 `:docker-compose-haproxy.yml`；拷贝 `xray.stream.haproxy` → `xray.stream`。
  4. `docker exec nginx nginx -t` 通过后 `docker compose restart nginx`（释放 443）；失败则回滚文件。
  5. 确认 443 已释放 → `docker compose up -d` 启动 haproxy。
  6. 校验：haproxy 容器 running、443 由 haproxy 监听、curl 走 https 到默认域名通。
- **→ nginx**：方向相反——`.env` 移除 haproxy.yml；`docker compose stop haproxy`（释放 443）；渲染放置 `xray.stream.ngx` → `xray.stream`；`nginx -t` 通过后 `docker compose restart nginx`（接管 443）；校验 443 属主与 stream.log 出现 SNI 记录。

切换过程中 443 有**秒级中断**（串行 stop/start），脚本逐步输出 `[OK]/[FAIL]`（风格对齐 `deploy.sh`），任一步失败即停并提示回滚方式。

### 3.7 渲染时机：宿主脚本，而非容器 entrypoint

| 方案 | 结论 |
|---|---|
| nginx entrypoint 按环境变量渲染（HAProxy 现有机制） | 否决：容器内多一套模板逻辑，违背"完全参考 docker-box、不复杂化" |
| `EDGE_PROXY` 环境变量 + 动态 include | 否决：引入第二个事实源，与 COMPOSE_FILE 存在不同步风险 |
| **宿主脚本（gen_env / switch）渲染 + 两套静态文件** | **采用**：haproxy 容器内渲染机制存量保留不动，nginx 侧零 entrypoint 改动 |

## 4. 影响面

### 4.1 test.sh 按模式分支

- **模式检测**：ssh 读取远端 `.env` 的 COMPOSE_FILE（兜底：检查远端 haproxy 容器是否存在）。
- **case 1**（容器健康）：haproxy 模式要求 4 容器，nginx 模式 3 容器。
- **case 2**（端口）：443 属主按模式区分（nginx/haproxy）；80、8443、18910、18911 两模式一致。
- **case 4/5/6**（路由日志断言）：
  - haproxy 模式：继续 grep `log/haproxy_access.log` 的 `sni:` 字段与 backend 名；
  - nginx 模式：grep `log/nginx_stream.log`（新增卷映射）的 `$ssl_preread_server_name` 字段与 `$upstream_addr`。

### 4.2 存量服务器迁移（一次性）

旧 `.env` 的 `COMPOSE_FILE` 没有 `docker-compose-haproxy.yml`（旧结构 haproxy 定义在主文件里）。本次改动部署后，compose 会认为 haproxy 不存在而移除该容器，**443 将无人监听**。

迁移步骤：部署完成后，在服务器上执行一次：

```bash
scripts/ngx_haproxy_switch.sh haproxy   # 幂等激活：补 COMPOSE_FILE + 放置空 stream + 拉起 haproxy
```

### 4.3 不变的部分

acme.sh（deploy 目标始终是 nginx 容器）、deploy.sh、nginx `server_params`、xray 端口规划（18910/18911/9000/9001）、证书流程、`.env` 的 rsync 排除策略。

## 5. 实施清单（开发顺序）

1. nginx 配置三件套：`tcp_stream_params`、`conf.d/xray.stream.ngx`、`conf.d/xray.stream.haproxy`；`.gitignore` 增加 `nginx/conf/conf.d/xray.stream`。
2. compose 拆分：主文件移除 haproxy、新增 `docker-compose-haproxy.yml`、nginx 加 stream.log 卷映射。
3. 连锁改动：`xray/etc/config.json.tpl` 加 sockopt；`haproxy/haproxy.cfg.tpl` xhttp_backend 加 send-proxy-v2（同步确认 `.client/.dns/.nf` 配置变体无 xhttp inbound）。
4. `gen_env.sh`：交互询问 + COMPOSE_FILE 默认 + 渲染激活文件。
5. 新增 `scripts/ngx_haproxy_switch.sh`。
6. `scripts/test.sh`：模式检测 + case 1/2/4/5/6 分支。
7. `README.md`、`CLAUDE.md`：架构图与操作说明更新。
8. **验证计划**：haproxy 模式跑全量 `test.sh` → 切 nginx 模式跑全量 → 切回 haproxy，确认双向切换与两种模式下 case 4/5/6 路由断言均通过。

## 6. 决策记录

| 决策点 | 结论 |
|---|---|
| 默认入口 | nginx stream（完全参考 docker-box，不增加转发跳数） |
| proxy protocol | 必须保留；xhttp 经 sockopt 层接收 PP，双模式统一发 PP |
| 配置组织 | 两套静态文件（`xray.stream.ngx` / `xray.stream.haproxy`）+ 切换脚本，不用容器内变量渲染、不引入 EDGE_PROXY |
| SNI map 大小写 | 正则加 `(?i)` |
| 切换脚本 | `scripts/ngx_haproxy_switch.sh`，仅服务器本机执行 |
| 初始化方式 | gen_env.sh 交互 y/N，默认 nginx；切换脚本幂等 |
| 文档命名 | `docs/README-003-nginx-haproxy-switch.md`（沿用仓库惯例） |
