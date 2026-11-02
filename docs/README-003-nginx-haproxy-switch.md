# 默认 Nginx 直连入口 + HAProxy 可选切换 设计文档

> 日期：2026-11-02（同日两轮 review 修订：第一轮补齐 stream 接线/切换顺序/回滚/迁移/deploy 模式感知/统一渲染/验证范围；第二轮修正 nginx -t 时序、按模式回滚、半完成收敛、验证域名构造、case 7 断言、IP 验证路径等）
> 分支：b1
> 状态：设计已对齐确认（含两轮 review 修订），本文档即开发规格说明
> 相关代码：`docker-compose.yml`、`docker-compose-haproxy.yml`、`docker-compose-xray.yml`、`gen_env.sh`、`scripts/render_stream.sh`、`scripts/ngx_haproxy_switch.sh`、`scripts/deploy.sh`、`scripts/test.sh`、`haproxy/`、`nginx/`、`xray/etc/config.json.tpl`
> 参考项目：`~/docker-box`（nginx stream 做 SNI 入口的成熟先例）
> 相关文档：[README-001-xray-accesslog-hostname.md](README-001-xray-accesslog-hostname.md)、[README-002-ssr-plus-accesslog-hostname.md](README-002-ssr-plus-accesslog-hostname.md)（切换后 case 5/6 的服务端日志域名断言逻辑不变）
> 开发进展：[003_worklog.md](003_worklog.md)

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
4. **`scripts/ngx_haproxy_switch.sh`**：支持在线互切（haproxy ↔ nginx），仅服务器本机执行；可回滚、可修复半完成状态。
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

1. xhttp inbound 只需在 `streamSettings` 增加 `"sockopt": {"acceptProxyProtocol": true}` 即可接收 PP 头。
2. policy 为 **REQUIRE**——到 18911 的每条连接必须带 PP 头。因此 HAProxy 模式的 `xhttp_backend` 必须同步加 `send-proxy-v2`（连锁改动，见 3.4）。
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
├── xray.stream.ngx                          # nginx 模式全量：443 server + upstreams + map（含占位符）
├── xray.stream.haproxy                      # 空文件（仅注释说明 443 由 HAProxy 接管）
└── xray.stream                              # 激活文件（生成物，不入 git，.gitignore 新增）
```

`tcp_stream_params`（内容恒定，与模式无关）：

```nginx
stream {
    log_format proxy '$remote_addr:$remote_port [$time_iso8601] '
                     'sni:$ssl_preread_server_name backend:$tcp_backend $protocol $status $bytes_sent $bytes_received '
                     '$session_time "$upstream_addr" '
                     '"$upstream_bytes_sent" "$upstream_bytes_received" "$upstream_connect_time"';

    access_log /var/log/nginx/stream.log proxy;
    include /etc/nginx/conf.d/*.stream;
}
```

> 两个与 docker-box 不同的字段选择（有明确理由）：
> - 时间用 `$time_iso8601`（如 `2026-11-02T14:05:11+08:00`）：test.sh/切换脚本要按时间窗匹配"本次请求"的日志行，零填充 HH:MM:SS 前缀可字符串比较；
> - 增加 `backend:$tcp_backend`：stream 的 `$upstream_addr` 是解析后的 IP:port，不等于 `${NF_XTLS_SERVER}` 主机名，路由断言应直接按 backend 名比对（haproxy 侧对应 `%b`）。

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

### 3.3 补齐 stream 配置接线（review 1）

仅有上面的文件还不够，必须完成两处接线，nginx 才会加载 stream 并监听 443：

1. `nginx/conf/nginx.conf` 顶层（`events {}` 之后、`http {}` 之前）加入：

   ```nginx
   include tcp_stream_params;
   ```

2. `docker-compose.yml` 的 nginx volumes 增加两个映射：

   ```yaml
   - ${NGINX_PATH}/conf/tcp_stream_params:/etc/nginx/tcp_stream_params
   - ${DOCKER_BOX_HOME}/log/nginx_stream.log:/var/log/nginx/stream.log
   ```

   后者把 stream 日志接入宿主机统一日志目录，供 test.sh 读取。

### 3.4 连锁改动（各一行）

| 文件 | 改动 | 原因 |
|---|---|---|
| `xray/etc/config.json.tpl` | xhttp inbound 的 `streamSettings` 增加 `"sockopt": {"acceptProxyProtocol": true}` | xhttp 要能收 PP（REQUIRE 策略） |
| `haproxy/haproxy.cfg.tpl` | `backend xhttp_backend` 的 server 增加 `send-proxy-v2`（同时更新 `:43` 注释） | 否则 HAProxy 模式下 xhttp 因 REQUIRE 全部拒绝连接 |

**升级注意**：旧 haproxy 容器（不发 PP）+ 新 xray（REQUIRE PP）= xhttp 全挂。两个改动必须同批生效——这由 3.9 的 deploy.sh 迁移流程保证（全部 stop 后显式删除旧 haproxy，再统一 up -d），**不存在"天然满足"**（review 修正：旧结论误称 deploy 全量 rsync + restart 天然保证，实际 `stop && up -d` 不会移除 orphan 容器）。

### 3.5 compose 拆分

- **`docker-compose.yml`**：只留 nginx + acme.sh；nginx volumes 按 3.3 增加 `tcp_stream_params` 与 `stream.log` 两个映射。
- **`docker-compose-haproxy.yml`**（新增）：haproxy service 整体迁入（entrypoint 的 sed 渲染、rsyslog 等机制原样保留，仅搬家）；`depends_on: nginx` 跨文件依然有效。
- **`docker-compose-xray.yml`**：不动。

### 3.6 统一渲染命令 `scripts/render_stream.sh`（review 7）

gen_env、deploy、switch 三处复用同一个渲染入口，避免"gen_env 渲染后用户改 .env 导致激活文件用过期值"的问题：

```bash
scripts/render_stream.sh [nginx|haproxy] [输出文件]
# 模式缺省按 .env COMPOSE_FILE 推导；输出文件缺省 conf.d/xray.stream
# （第二参数供切换脚本渲染到临时路径做一致性 cmp）
```

行为约定：

- 从仓库根 `.env` 读取 `COMPOSE_FILE`、`REALITY_DEST`、`NF_XTLS_SERVER`；
- nginx 模式：校验 `REALITY_DEST`、`NF_XTLS_SERVER` **非空**（空则报错退出，不产出文件）；`sed` 渲染（`${REALITY_DEST}` 点号转义，逻辑参照 `haproxy/entrypoint.sh`）；渲染后自检残留占位符；
- haproxy 模式：拷贝 `xray.stream.haproxy`；
- 输出写入临时文件再 `mv` 原子替换——**渲染/校验失败绝不影响当前可用配置**；
- 不触碰任何日志文件与容器。

**使用规则**：编辑 `.env`（改了 `REALITY_DEST`/`NF_XTLS_SERVER`/`COMPOSE_FILE`）后必须重新执行 `render_stream.sh`；README 快速开始顺序更新为：gen_env → 编辑 .env → **render_stream.sh** → compose up -d。

### 3.7 `gen_env.sh`

- `COMPOSE_FILE` 默认值改为 `docker-compose.yml:docker-compose-xray.yml`（默认不含 haproxy）。
- 交互询问（仅当 stdin 为 TTY 且 `.env` 不存在时）：「启用 HAProxy 作为 443 入口？[y/N]」，选 y 则 `COMPOSE_FILE=docker-compose.yml:docker-compose-xray.yml:docker-compose-haproxy.yml`。
- `.env` 已存在时沿用现有值（现有 `var_exists` 逻辑），打印当前模式，不重复询问；非交互环境默认 nginx。
- 写完 `.env` 后：① `touch log/nginx_stream.log`（review 6：预先创建空日志文件，避免 compose 单文件 bind mount 在源缺失时创建**目录**导致 nginx 无法打开日志；`*.log` 已被 .gitignore 覆盖）；② 调用 `scripts/render_stream.sh` 生成激活文件。日志文件只创建、**从不截断**，切换与部署流程均不触碰它。
- **不引入 `EDGE_PROXY` 变量**：模式事实源 = `COMPOSE_FILE` 内容 + 激活文件，两者由脚本同步修改，容器内零决策逻辑。

### 3.8 `scripts/ngx_haproxy_switch.sh`：状态收敛式切换（review 1/2/5 + 二轮修订）

用法（仅服务器本机执行）：

```bash
scripts/ngx_haproxy_switch.sh nginx|haproxy|status
```

设计原则：切换不是"改 .env + 重启"，而是**向目标模式收敛**——每一步可校验、失败自动回滚、重复执行可修复半完成状态。

**收敛判据（五项，缺一不可）**：

1. `.env` COMPOSE_FILE 与目标模式一致；
2. 激活文件与目标模式**渲染结果**逐字节一致——先 `render_stream.sh <mode> <tmp>` 渲染到临时文件再 `cmp`，**不与含 `${REALITY_DEST}` 占位符的 `xray.stream.ngx` 直接比较**；
3. 容器态：目标 haproxy → haproxy 容器 running；目标 nginx → **haproxy 容器不存在**（`docker ps -a` 无记录。仅 stop 不够：`restart: always` 会在 docker daemon / 宿主机重启后唤醒容器抢占 443，必须 `stop + rm`）；
4. nginx 容器 running；
5. 443 实际占用者与目标一致。属主检查用 `sudo -n ss -tlnp`（容器内进程属 root，普通用户 `ss` 看不到 `users:` 字段）；`sudo -n` 不可用时退化为"端口在听 + TLS 可握手 + 目标容器 running"探测并给出 WARN，不据此误判失败。

**通用安全机制**：

- `flock -n` 防并发（`/tmp/.ngx_haproxy_switch.lock`）；
- 备份放独立临时目录 `mktemp -d /tmp/ngx-switch-backup.XXXXXX`，目录 700、文件 600——`.env` 含密钥，**不进项目目录**（不涉及 git/rsync/.gitignore）；
- `.env` 与激活文件一律"写临时文件 + `mv` 原子替换"；
- **渲染与 `nginx -t` 在释放当前 443 之前完成**：`nginx -t` 只校验磁盘文件，不影响运行态内存配置，HAProxy/nginx 持 443 期间可安全执行；此步失败即恢复原文件退出，**服务零影响**；
- 容器操作**直操 docker**（`docker stop haproxy && docker rm -f haproxy`），不依赖 COMPOSE_FILE 是否识别该服务——半完成状态下 compose 可能已不认识 haproxy，`docker compose stop haproxy` 会报 `no such service`；
- 每个操作按实际状态分支：容器不存在则跳过，文件缺失则重建；
- 所有等待/端口/curl 校验均有超时（默认 30s、间隔 2s）与重试（curl 3 次）；
- **备份目录的清理（review 补充）**：切换成功 → 收尾时 `rm -rf` 备份目录；切换失败但**回滚成功** → 同样清理（回滚后的系统状态与原一致，备份无保留价值）；仅当**回滚自身失败**（退出码 2）时保留备份目录并在错误信息中给出路径——避免含 `.env` 的敏感备份在 `/tmp` 长期积累。

**切换到 nginx**：

1. flock；创建备份目录；
2. `render_stream.sh nginx` 渲染并原子放置激活文件；`docker exec nginx nginx -t`——**失败 → 恢复激活文件 → 退出（443 仍由 HAProxy 持有，服务未受影响）**；
3. haproxy 容器存在则 `docker stop` + `docker rm -f`（直操 docker）；轮询等 443 释放（30s/2s）；
4. 原子更新 `.env`（移除 `:docker-compose-haproxy.yml`）；
5. `docker compose restart nginx`；轮询 443 属主 = nginx（30s）；
6. 新请求验证（见下）；失败 → 回滚。

**切换到 haproxy**：

1. flock；创建备份目录；
2. 放置 haproxy 版（空）激活文件；`nginx -t`——失败 → 恢复 → 退出（443 仍由 nginx 持有）；
3. 原子更新 `.env`（追加 haproxy.yml；已含则跳过——兼容半完成状态）；
4. `docker compose restart nginx` 释放 443；轮询等释放（30s）；
5. `docker compose up -d` 启动 haproxy（**新模板渲染出的配置自带 `send-proxy-v2`**）；轮询 haproxy running + 443 属主（30s）；
6. 新请求验证；失败 → 回滚。

**失败回滚（按原模式分别定义，均为直操 docker + compose，与 COMPOSE_FILE 状态无关）**：

- **回滚到 nginx**：`docker rm -f haproxy`（直接删，不经过 compose——此时 .env 可能处于含 haproxy.yml 的混合态，compose 可能重建它，所以先删再等）→ 确认 443 释放 → 恢复 `.env` 与激活文件备份 → `docker compose restart nginx` → 校验 443 属主 = nginx；
- **回滚到 haproxy**：恢复 `.env` 与空激活文件 → `docker compose restart nginx`（释放 443）→ 确认释放 → `docker compose up -d` 重建 haproxy（新模板）→ 校验 443 属主 = haproxy；
- 回滚后校验通过 → 报告"已自动回滚到 <原模式>"；仍失败 → 输出备份目录路径（含 .env，注意保密）与手动恢复命令，退出码 2。

**新请求验证（curl 域名构造，二轮 review 修正）**：

不能简单拼 `switchtest.<首个证书域名>`——首个 SAN 可能是 `*.example.com`（拼出非法域名）或裸域（子域未必被覆盖）。构造规则：

1. 从 nginx 容器证书提取 SAN 列表（`docker exec nginx openssl x509`）；
2. 优先取通配符 SAN（`*.example.com` / `*.ddx.cqcy.fun` 均可）：去掉 `*.` 前缀，构造 `sw<随机数>.<基域>`，并校验该域名确实被某条 SAN 覆盖（后缀匹配；`domain_covered` 函数）；
3. 无通配符 SAN：选证书中已存在、**不满足任何路由前缀规则**（x|xyz|api|dt|ai|web|app|cdn|nf|netflix|nfx|nfv）**且不等于 `${REALITY_DEST}`** 的域名（保证走默认 nginx 后端）；
4. 都选不出 → 跳过 curl 验证（WARN，已做端口/容器校验），不因无法验证而误回滚；
5. 请求前记录日志位置标记 `pos=$(wc -c < <日志文件>)`（字节偏移）；`curl -sk --max-time 10 --resolve <域名>:443:127.0.0.1`；查询串带随机数；每次重试前**同时刷新 pos 与构造新随机子域**（无通配符 SAN 复用同一域名时也能区分本次请求）；
6. 日志断言只检查 **pos 之后追加的新内容**（`tail -c +$((pos+1))`），其中找 SNI = 构造域名的行；时间戳（`THH:MM:SS` / `HH:MM:SS`）只作**辅助**展示，不作判定条件——彻底规避同秒历史记录误匹配与跨午夜比较失效；nginx 模式断言 `backend:ngx`（`$tcp_backend` 字段），haproxy 模式断言 `%b` = `ngx_backend`；3 次重试间隔 2s。

> 切换脚本与 test.sh 的所有"新请求日志验证"统一用此**偏移量方案**（review 3）。

### 3.9 `scripts/deploy.sh`：模式感知 + 显式迁移（review 3/4，二轮修订）

deploy.sh **必须改造**（修正旧结论"deploy.sh 不变"）：

1. rsync 与远端 `gen_env.sh` 不变（gen_env 内部已含渲染与日志初始化，且对已存在的 `.env` 保留原 COMPOSE_FILE 值——不会把 haproxy 模式冲掉）；
2. **迁移检测**：远端 `docker ps -a` 存在 `haproxy` 容器 **且** 远端 `.env` COMPOSE_FILE 不含 `docker-compose-haproxy.yml` → 判定为旧结构（haproxy 原本定义在主 compose 里）。迁移顺序（review 修正：`docker compose stop` **不会**停止已不在配置中的服务，必须显式直操 docker）：
   - `docker compose stop`（停止当前配置内的服务，消除"xray 已 REQUIRE PP 而旧 haproxy 还在转发"的混合状态窗口）；
   - `docker stop haproxy && docker rm haproxy`（显式删除旧容器；`docker compose up -d` 不会自动移除 orphan）；
   - `docker compose up -d`（全新配置统一拉起：新 xray 带 sockopt + 新 nginx + 默认无 haproxy，状态一致）；
   - 部署报告明确输出："检测到旧版 HAProxy，已按 Nginx 默认模式迁移；如需 HAProxy 入口，部署后在服务器运行 scripts/ngx_haproxy_switch.sh haproxy"；
3. **必需容器按模式判定**：读取部署后远端 `.env` COMPOSE_FILE，含 haproxy.yml → `("haproxy" "nginx" "acme" "xray")`，否则 `("nginx" "acme" "xray")`；排错提示同样按模式（haproxy 容器日志仅在 haproxy 模式下列为排错对象）。

### 3.10 渲染时机总表

| 时机 | 动作 |
|---|---|
| `gen_env.sh`（新 init / 重跑） | 询问模式 → 写 `.env` → touch 日志 → 调 `render_stream.sh` |
| 用户编辑 `.env` 后 | **手动**执行 `render_stream.sh`（README 写明） |
| `deploy.sh` | 远端 `gen_env.sh` 内联完成渲染（值不变则幂等重渲染） |
| `ngx_haproxy_switch.sh` | 切换流程内渲染 + `nginx -t` 前置 |
| 容器 entrypoint | **零渲染**（haproxy 容器内 entrypoint 的存量渲染机制保留不动） |

## 4. 影响面

### 4.1 test.sh 按模式分支

- **模式检测**：ssh 读取远端 `.env` 的 COMPOSE_FILE（兜底：检查远端 haproxy 容器是否存在）。
- **case 1**（容器健康）：haproxy 模式要求 4 容器，nginx 模式 3 容器。
- **case 2**（端口）：443 检查属主进程名（nginx 模式须含 `nginx`，haproxy 模式须含 `haproxy`——远端有 sudo 用 `sudo ss`，否则退化为监听检查）；80、8443、18910、18911 两模式一致。
- **case 4/5/6**（路由日志断言）：
  - haproxy 模式：继续 grep `log/haproxy_access.log` 的 `sni:` 字段与 `%b` backend 名；
  - nginx 模式：grep `log/nginx_stream.log`——SNI 取自 `sni:$ssl_preread_server_name` 字段，backend 取自 `backend:$tcp_backend` 字段（**不再用 `$upstream_addr`**，它是解析后的 IP:port，不等于配置里的主机名）；
  - **时间窗断言**：case 4/5 补 case 6 同款逻辑——请求发起前记录时间标记，只接受时间 ≥ 标记的新日志行（iso8601 取 `THH:MM:SS` 做零填充字符串比较），禁止 `tail -1` 旧日志冒充成功。
- **新增 case 7（NF 路由 + PP 兼容性，两种模式，二轮 review 重写）**——**路由断言与 PP 断言分离**：
  - 构造 `nf.<四级通配域>` SNI（复用现有动态构造逻辑；证书无可用通配则跳过并警告）；
  - `echo | timeout 8 openssl s_client -connect 127.0.0.1:443 -servername <域名>` 发起连接——**连接关闭靠 stdin EOF 主动触发**（nginx stream 与 haproxy 的 access log 都在**连接结束**时写入，不是 ClientHello 即记日志）；请求前记录日志文件**字节偏移 pos**，连接关闭后只检查 pos 之后追加的内容（**偏移量方案**），轮询最多 10s；
  - **路由断言**：nginx 模式查 `backend:nf_xtls`，haproxy 模式查 `nf_xtls_backend`；
  - **PP 兼容性断言**：openssl s_client 返回码 0（TLS 握手成功）为**硬性要求**——"握手成败均可"只能证明路由、不能证明 NF 端接受 PP；握手失败即判用例失败并阻断验收，**但原因报告为"NF 握手失败，可能为 PP 版本或上游异常"，不能直接定性为 PP v1 不兼容**（上游宕机、证书/TLS 配置、网络或 SNI 问题同样会失败）；**仅当同一 NF 上游下 haproxy 模式（PP v2）握手成功而 nginx 模式（PP v1）握手失败时，才将 PP v1 兼容性列为主要嫌疑**；`NF_XTLS_SERVER` 为本地 vision（默认 127.0.0.1:18910）时天然接受 v1/v2；指向远端（如 hk01:18912）时本用例即远端 PP v1 兼容性的实测证据（haproxy 模式为 v2 对照组）。

### 4.2 日志中的客户端 IP 验证（三轮 review 修正：外部验证为强制验收项）

普通 HTTPS curl 走默认 nginx 后端，**不会产生 xray 日志**——原方案"普通 curl 后检查 xray_access.log"是错误路径。IP 验证必须分两条，且**第二条强制从服务器之外的机器执行**：

1. **默认 HTTPS 请求**（两模式同路径）：从服务器之外的机器（开发机）`curl https://<默认路由域名>`（走服务器公网 IP），检查 `log/nginx_access.log` 的 `$remote_addr`——经 `real_ip_header proxy_protocol` 还原后应为请求方公网 IP；
2. **真实代理客户端请求（强制）**：**必须从服务器之外**的客户端各执行一次 Vision 或 XHTTP 代理请求（开发机跑 xray 客户端指向服务器域名，或用真实设备），检查 `log/xray_access.log` 的 `from <IP>` 应为请求方公网 IP。**test.sh 的 case 5/6 在服务器本机发起，源地址恒为 127.0.0.1，只能证明 PP 必需头被接受（REQUIRE 策略下链路成功即证），不能证明外部客户端 IP 被正确还原——不得替代本项**。因此 test.sh 新增 **case 8**：ssh 到开发机（或其他外网跳板，`--dep` 参数指定）运行 xray 客户端经 Vision/XHTTP 出网请求一次，回连服务器日志按**偏移量方案**断言 `from <开发机公网IP>`；**case 8 为两种模式的验收门禁，必须通过**。

字段名区分（文档/脚本注释统一）：HAProxy 日志来源字段是 `%ci`（log-format 自定义），nginx stream 日志是 `$remote_addr`，xray access log 是 `from`。

### 4.3 不变与已修正的结论

- **不变**：acme.sh（deploy 目标始终是 nginx 容器）、nginx `server_params`、xray 端口规划（18910/18911/9000/9001）、证书流程、`.env` 的 rsync 排除策略。
- **修正（原错误结论）**：deploy.sh 需要模式感知改造（见 3.9）；"deploy 天然保证 HAProxy/Xray 同批更新"不成立——`stop && up -d` 不会移除 orphan 容器，旧 haproxy 可能继续持有 443，必须显式 `docker stop/rm`。

## 5. 验证计划（两轮 review 扩充）

部署到 `sg.cqcy.fun` 后执行，全部通过才算完成：

1. **迁移验证**：旧结构（haproxy 容器 + 旧 .env）上跑新 deploy.sh，确认输出迁移报告、旧容器被 `docker rm` 删除、nginx 模式拉起；
2. **nginx 模式全量**：`test.sh` 全部用例（含新增 case 7）；
3. **切到 haproxy**：`ngx_haproxy_switch.sh haproxy` → haproxy 模式全量 `test.sh`；
4. **切回 nginx**：`ngx_haproxy_switch.sh nginx` → nginx 模式全量 `test.sh`（最终停在默认模式）；
5. **NF + PP v1 实测**：case 7 的 PP 断言必须握手成功（`NF_XTLS_SERVER` 指向远端时即远端 PP v1 兼容性证据；**nginx 发 v1 与 HAProxy 发 v2 不能默认等价**）；握手失败时按 4.1 的归因规则报告（可能为 PP 版本或上游异常），只有 v2 对照成功 + v1 失败才定性 PP v1 不兼容；
6. **真实客户端 IP（两条路径，外部验证为强制门禁）**：开发机经公网 IP 发默认 HTTPS 请求核 nginx_access.log；**从服务器之外的真实代理客户端**（test.sh case 8）走 Vision/XHTTP 核 xray_access.log 的 `from` 为外部公网 IP——两模式各做一次，**case 8 不通过则验收不通过**；服务器本机的 case 5/6 不可替代；
7. **新请求断言**：各次切换后的校验均发新请求，且按**字节偏移量**只匹配本次追加的日志（时间戳仅作辅助展示）；应实现于切换脚本、test.sh case 4–8；
8. **daemon 重启**：切到目标模式后 `sudo systemctl restart docker`，确认 443 只有目标入口监听、**无 haproxy 复活抢占**（容器已被 rm，非仅 stop）；
9. **失败注入**（二轮修正注入方式，三轮修正无效注入）：
   - **nginx -t 失败注入**：破坏 `xray.stream.ngx` 模板（写入非法指令；仅污染激活文件无效——切换渲染会立即覆盖它）→ 切 nginx → 应在第 2 步失败、零影响退出，原入口无损；恢复模板；
   - **haproxy 启动失败注入**（三轮修正：原"临时容器占用 443"方案不可行——切换前 443 由 nginx 持有，临时容器 bind 必失败，且残留占用会让回滚也失败）：改为**临时向 `haproxy.cfg.tpl` 写入非法指令** → 切换时 haproxy entrypoint 的 `haproxy -c` 校验失败、容器退出 → 切换脚本在"启动/属主校验"步失败 → **自动回滚到 nginx**；恢复模板后重跑 switch haproxy 应成功；
   - **curl 校验失败注入**（三轮修正：验证域名取自**证书 SAN**而非 `.env` DOMAIN_LIST，改 DOMAIN_LIST 不会影响验证，此注入无效）：改为通过 **`CURL_BIN` 环境变量注入测试用 curl**（脚本内 curl 一律以 `${CURL_BIN:-curl}` 调用）——测试时 `CURL_BIN=/path/to/failing-curl-stub switch …`，stub 恒返回失败 → 验证步失败 → 应回滚；正式环境不设该变量即无影响，**不得通过破坏正式证书配置来制造失败**；
10. **半完成修复**：人为制造三种半完成状态（只改 .env / 只换激活文件 / 只删容器），分别重跑 `switch <目标>`，均应自动收敛而非误报"已是目标模式"；对"目标=nginx 但 .env 已无 haproxy.yml 且容器已删"的极端状态同样可收敛；

## 6. 实施清单（开发顺序）

1. nginx 配置：`tcp_stream_params`、`conf.d/xray.stream.ngx`、`conf.d/xray.stream.haproxy`、`nginx.conf` 顶层 `include tcp_stream_params;`；`.gitignore` 增加 `nginx/conf/conf.d/xray.stream`。**✅ 已完成**
2. compose 拆分：主文件移除 haproxy + 增加两个卷映射；新增 `docker-compose-haproxy.yml`。**✅ 已完成**
3. 连锁改动：`xray/etc/config.json.tpl` 加 sockopt；`haproxy/haproxy.cfg.tpl` xhttp_backend 加 send-proxy-v2（已确认 `.client/.dns/.nf` 配置变体无 xhttp inbound）。**✅ 已完成**
4. `scripts/render_stream.sh`（新，含第二输出参数）。**✅ 已完成（本地干跑三种场景通过）**
5. `gen_env.sh`：交互询问 + touch stream 日志 + 调用渲染。**✅ 已完成（语法检查通过，未实测交互）**
6. `scripts/ngx_haproxy_switch.sh`（新，按 3.8 二轮修订版：nginx -t 前置、按模式回滚、直操 docker、证书 SAN 构造验证域名、/tmp 备份、flock、sudo ss 退化）。**✅ 已完成（语法检查通过，未经服务器实测）**
7. `scripts/deploy.sh`：模式感知 + 迁移流程（按 3.9，直操 docker 删除旧容器）。**✅ 已完成（语法检查通过，未经服务器实测）**
8. `scripts/test.sh`：模式检测、case 1/2/4/5/6 双模式分支 + **全部改用偏移量方案**（请求前记 pos，只查追加内容，时间戳仅辅助）、新增 case 7（NF 路由 + PP 握手双断言、stdin EOF 关连接后轮询新增日志、失败归因按 4.1）、新增 **case 8**（外部真实代理客户端 IP 验证，`--dep` 指定外网跳板，两种模式验收门禁）。**✅ 已完成（语法检查通过，未经服务器实测）**
9. `README.md`、`CLAUDE.md`：双模式架构、快速开始（含 render 步骤）、切换脚本说明；清理"单一 HAProxy 架构"文案。**✅ 已完成**
10. 按第 5 节验证计划实测并报告。**⏳ 未开始**

> 实施进展详见 [003_worklog.md](003_worklog.md)（随开发滚动更新）。

## 7. 决策记录

| 决策点 | 结论 |
|---|---|
| 默认入口 | nginx stream（完全参考 docker-box，不增加转发跳数） |
| proxy protocol | 必须保留；xhttp 经 sockopt 层接收 PP，双模式统一发 PP |
| 配置组织 | 两套静态文件（`xray.stream.ngx` / `xray.stream.haproxy`）+ 激活文件 + 切换脚本；不用容器内变量渲染、不引入 EDGE_PROXY |
| SNI map 大小写 | 正则加 `(?i)` |
| stream 日志格式 | 时间用 `$time_iso8601`；带 `sni:` 与 `backend:$tcp_backend` 字段（路由断言按 backend 名，不用解析后的 `$upstream_addr`） |
| 切换脚本 | `scripts/ngx_haproxy_switch.sh`，仅服务器本机执行；flock + /tmp 备份（700/600）+ 渲染/nginx -t 前置（失败零影响）+ 容器操作直操 docker + 任一步失败按原模式自动回滚 + 幂等收敛可修复半完成状态 |
| haproxy 容器停用方式 | `docker stop + docker rm -f`（不是仅 stop，也不是 compose stop——防 restart:always 复活抢 443，且不依赖 compose 是否认识该服务） |
| 443 属主检查 | `sudo -n ss -tlnp`；不可用时退化"端口监听 + TLS 握手 + 容器 running"探测（WARN 不判失败） |
| 初始化方式 | gen_env.sh 交互 y/N，默认 nginx |
| 渲染命令 | `scripts/render_stream.sh` 统一入口，gen_env/deploy/switch 复用；改 .env 后必须重渲染 |
| 部署迁移 | deploy.sh 显式检测旧结构，`compose stop → docker stop/rm haproxy → compose up -d` |
| 验证域名构造 | 从容器证书 SAN 选：优先通配符去 `*.` 构造随机子域（校验覆盖）；否则选非路由前缀、非 REALITY_DEST 的已覆盖 SAN |
| 新请求日志断言 | **字节偏移量方案**（请求前记 pos，只查 pos 后追加内容），时间戳仅作辅助展示 |
| 外部真实 IP 验证 | test.sh **case 8**（`--dep` 外网跳板跑真实代理客户端），两种模式验收门禁；本机 case 5/6 不可替代 |
| curl 失败注入 | 脚本内 curl 以 `${CURL_BIN:-curl}` 调用，测试时注入失败 stub；不碰正式配置 |
| 备份清理 | 切换成功或回滚成功即删 `/tmp` 备份目录；仅回滚失败保留并提示路径 |
| 文档命名 | `docs/README-003-nginx-haproxy-switch.md`（沿用仓库惯例） |
