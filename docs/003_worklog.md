# 003 开发进展（worklog）

> 关联设计文档：[README-003-nginx-haproxy-switch.md](README-003-nginx-haproxy-switch.md)
> 开发机：bj01（仅运行一个 xray 客户端容器，非部署目标）
> 部署目标：sg.cqcy.fun（生产服务器，测试需经 `./scripts/deploy.sh` / `ssh work@sg.cqcy.fun`）
> 本文件随开发滚动更新。

## 2026-11-02 状态：实施清单 1–6 完成（文件级），7–10 未开始

### 设计文档

- 003 文档已按**两轮 review** 修订完成：
  - 一轮（8 项）：补齐 stream 接线（`nginx.conf` include + compose 卷）、修正切回 nginx 的 compose 时序（`no such service` 问题）、重写存量迁移（`stop && up -d` 不移除 orphan）、deploy.sh 模式感知、状态收敛式切换（回滚/flock/原子替换/超时重试）、stream 日志预创建、统一渲染命令 `render_stream.sh`、扩充验证范围；
  - 二轮（6 项 + 4 小项）：**nginx -t 必须在释放 443 之前**（原顺序先删 haproxy 再校验，失败即服务中断）；**回滚按原模式分别定义**（回滚到 nginx 必须 `docker rm -f haproxy` 直操 docker，否则 orphan 占着 443 nginx 起不来）；半完成状态每个操作按实际状态分支（compose 可能已不认识 haproxy）；验证域名从**证书 SAN** 构造（首个 SAN 是 `*.example.com` 时拼 `switchtest.*.example.com` 是非法域名）；case 7 拆成**路由断言**（backend 名，`$tcp_backend` 字段）与 **PP 兼容性断言**（openssl 握手成功为硬性要求，"握手成败均可"证明不了 PP v1）；真实 IP 验证分两条路径（普通 HTTPS 核 nginx_access.log，代理客户端核 xray_access.log `from`，普通 curl 不产生 xray 日志）；备份改 `/tmp` 临时目录 700/600；`ss -tlnp` 用 `sudo -n`（普通用户看不到 root 进程的 users: 字段）；失败注入要破坏**模板**而非激活文件（切换渲染会覆盖激活文件）。

### 已完成（实施清单 1–6，文件级 ✅，仅语法检查/本地干跑，未部署实测）

| 项 | 文件 | 状态 |
|---|---|---|
| 1 nginx 配置三件套 + 接线 | `nginx/conf/tcp_stream_params`（log_format 含 `sni:`/`backend:$tcp_backend`/`$time_iso8601`）、`nginx/conf/conf.d/xray.stream.ngx`（含占位符）、`xray.stream.haproxy`（空）、`nginx/conf/nginx.conf`（顶层 `include tcp_stream_params;`）、`.gitignore`（忽略生成的 `xray.stream`） | ✅ |
| 2 compose 拆分 | `docker-compose.yml`（移除 haproxy，nginx 增加 tcp_stream_params/stream.log 两个卷）、`docker-compose-haproxy.yml`（新，haproxy 整体迁入） | ✅ |
| 3 连锁改动 | `xray/etc/config.json.tpl`（xhttp inbound 加 `"sockopt":{"acceptProxyProtocol":true}`）、`haproxy/haproxy.cfg.tpl`（xhttp_backend 加 `send-proxy-v2`，注释更新）；已确认 `.client/.dns/.nf` 变体无 xhttp inbound | ✅ |
| 4 统一渲染 | `scripts/render_stream.sh [nginx\|haproxy] [输出文件]`：空变量拒绝、占位符自检、临时文件 + mv 原子替换 | ✅ 本地干跑三场景通过（nginx 渲染/转义正确、haproxy 空文件、空 REALITY_DEST 拒绝且不覆盖） |
| 5 gen_env.sh | TTY 且 .env 不存在时询问「启用 HAProxy？[y/N]」；`touch log/nginx_stream.log`；调用 render_stream.sh（失败仅告警） | ✅ 语法检查通过 |
| 6 切换脚本 | `scripts/ngx_haproxy_switch.sh nginx\|haproxy\|status`：五项收敛判据（含渲染到临时文件再 cmp）、flock、`/tmp/ngx-switch-backup.*` 备份（700/600）、**渲染 + nginx -t 前置**（失败零影响）、容器操作直操 docker（stop+rm）、**按原模式分别回滚**、`sudo -n ss` 退化 TLS 探测、验证域名从证书 SAN 构造（通配符优先 + 覆盖校验 + 排除路由前缀/REALITY_DEST）、时间窗新请求验证（curl 3 次重试） | ✅ 语法检查通过 |

### 未开始（实施清单 7–10）

7. **`scripts/deploy.sh` 模式感知 + 迁移**：迁移检测（haproxy 容器存在且 .env 无 haproxy.yml）→ `compose stop` → `docker stop/rm haproxy`（直操）→ `up -d`；必需容器按模式判定；迁移报告输出。
8. **`scripts/test.sh` 分支**：模式检测（ssh 读远端 .env COMPOSE_FILE）；case 1 容器数、case 2 属主进程名、case 4/5/6 日志断言双模式分支 + case 4/5 补时间窗断言；新增 case 7（NF 路由 `backend:nf_xtls`/`nf_xtls_backend` + openssl 握手成功硬断言 + stdin EOF 关连接后轮询日志 ≤10s）。
9. **README.md / CLAUDE.md**：双模式架构图、快速开始插入 render 步骤、切换脚本说明、清理单一 HAProxy 文案。
10. **部署与实测**（按 003 第 5 节验证计划 10 项）：需要 `.deployment-config`（本机尚无，需指向 work@sg.cqcy.fun）；含两次全量 test.sh、双向切换、daemon 重启、三种失败注入、三种半完成修复。**注意：全部操作在 sg 生产服务器执行，443 有秒级中断窗口。**

### 已知风险 / 待实测确认

- nginx stream 发 **PP v1**、HAProxy 发 v2——本地 xray（go-proxyproto）两者都收；`NF_XTLS_SERVER` 指向远端时的 v1 兼容性靠 case 7 实测。
- 远端 `sh` 必须支持 bash 语法（gen_env.sh 用了数组，现状 deploy 用 `sh gen_env.sh` 能跑说明远端 sh→bash；render_stream.sh 为纯 POSIX 无此顾虑）。
- `nginx:latest` 镜像的 `include tcp_stream_params;` 相对路径基于 prefix `/etc/nginx/`（与 docker-box 相同用法，待实测）。
- nginx 容器是否带 `sudo` 无关（ss 在宿主机跑）；宿主机 work 用户 sudo 免密依赖 init_sys_rocky.sh 的 sudoers 配置。
- 切换脚本 `pick_verify_domain` 依赖容器内 openssl 可读证书——证书未签发时（acme 未完成）选不出域名会跳过 curl 验证（WARN），不影响切换本身。

### 提交记录

- `2b6de21` docs: 003 设计文档初版（一轮 review 前）
- 本轮（待提交）：003 二轮修订 + worklog + 实施清单 1–6 代码
