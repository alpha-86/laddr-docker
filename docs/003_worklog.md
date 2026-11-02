# 003 开发进展（worklog）

> 关联设计文档：[README-003-nginx-haproxy-switch.md](README-003-nginx-haproxy-switch.md)
> 开发机：bj01（仅运行一个 xray 客户端容器，非部署目标）
> 部署目标：sg.cqcy.fun（生产服务器，测试需经 `./scripts/deploy.sh` / `ssh work@sg.cqcy.fun`）
> 本文件随开发滚动更新。

## 2026-11-02 状态：实施清单 1–9 完成（文件级），10（部署实测）待用户确认后进行

### 设计文档

- 003 文档已按**三轮 review** 修订完成：
  - 一轮（8 项）：补齐 stream 接线（`nginx.conf` include + compose 卷）、修正切回 nginx 的 compose 时序（`no such service` 问题）、重写存量迁移（`stop && up -d` 不移除 orphan）、deploy.sh 模式感知、状态收敛式切换（回滚/flock/原子替换/超时重试）、stream 日志预创建、统一渲染命令 `render_stream.sh`、扩充验证范围；
  - 二轮（6 项 + 4 小项）：**nginx -t 必须在释放 443 之前**（原顺序先删 haproxy 再校验，失败即服务中断）；**回滚按原模式分别定义**（回滚到 nginx 必须 `docker rm -f haproxy` 直操 docker，否则 orphan 占着 443 nginx 起不来）；半完成状态每个操作按实际状态分支（compose 可能已不认识 haproxy）；验证域名从**证书 SAN** 构造（首个 SAN 是 `*.example.com` 时拼 `switchtest.*.example.com` 是非法域名）；case 7 拆成**路由断言**（backend 名，`$tcp_backend` 字段）与 **PP 兼容性断言**（openssl 握手成功为硬性要求，"握手成败均可"证明不了 PP v1）；真实 IP 验证分两条路径（普通 HTTPS 核 nginx_access.log，代理客户端核 xray_access.log `from`，普通 curl 不产生 xray 日志）；备份改 `/tmp` 临时目录 700/600；`ss -tlnp` 用 `sudo -n`（普通用户看不到 root 进程的 users: 字段）；失败注入要破坏**模板**而非激活文件（切换渲染会覆盖激活文件）。
  - 三轮（5 项）：curl 失败注入改 **`CURL_BIN` 环境变量注入 stub**（验证域名取自证书 SAN 而非 DOMAIN_LIST，原方案无效；不得破坏正式证书配置）；haproxy 启动失败注入改**破坏 `haproxy.cfg.tpl` 模板**（原"临时容器占用 443"不可行——切换前 443 被 nginx 持有，bind 必失败且残留占用会拖垮回滚）；新请求断言统一改**字节偏移量方案**（原 HH:MM:SS ≥ mark 有同秒历史误匹配与跨午夜失效问题——请求前记 pos，只查 `tail -c +pos` 追加内容，时间戳仅辅助）；case 7 握手失败**归因修正**（不再直接定性 PP v1 不兼容，报告"可能为 PP 版本或上游异常"，仅 v2 成功+v1 失败对照才定性）；**外部真实 IP 验证强制化**（test.sh 新增 case 8 为验收门禁，本机 case 5/6 不可替代）；切换成功/回滚成功即**清理 /tmp 备份目录**（仅回滚失败保留）。

### 已完成（实施清单 1–6，文件级 ✅，仅语法检查/本地干跑，未部署实测）

| 项 | 文件 | 状态 |
|---|---|---|
| 1 nginx 配置三件套 + 接线 | `nginx/conf/tcp_stream_params`（log_format 含 `sni:`/`backend:$tcp_backend`/`$time_iso8601`）、`nginx/conf/conf.d/xray.stream.ngx`（含占位符）、`xray.stream.haproxy`（空）、`nginx/conf/nginx.conf`（顶层 `include tcp_stream_params;`）、`.gitignore`（忽略生成的 `xray.stream`） | ✅ |
| 2 compose 拆分 | `docker-compose.yml`（移除 haproxy，nginx 增加 tcp_stream_params/stream.log 两个卷）、`docker-compose-haproxy.yml`（新，haproxy 整体迁入） | ✅ |
| 3 连锁改动 | `xray/etc/config.json.tpl`（xhttp inbound 加 `"sockopt":{"acceptProxyProtocol":true}`）、`haproxy/haproxy.cfg.tpl`（xhttp_backend 加 `send-proxy-v2`，注释更新）；已确认 `.client/.dns/.nf` 变体无 xhttp inbound | ✅ |
| 4 统一渲染 | `scripts/render_stream.sh [nginx\|haproxy] [输出文件]`：空变量拒绝、占位符自检、临时文件 + mv 原子替换 | ✅ 本地干跑三场景通过（nginx 渲染/转义正确、haproxy 空文件、空 REALITY_DEST 拒绝且不覆盖） |
| 5 gen_env.sh | TTY 且 .env 不存在时询问「启用 HAProxy？[y/N]」；`touch log/nginx_stream.log`；调用 render_stream.sh（失败仅告警） | ✅ 语法检查通过 |
| 6 切换脚本 | `scripts/ngx_haproxy_switch.sh nginx\|haproxy\|status`：五项收敛判据（含渲染到临时文件再 cmp）、flock、`/tmp/ngx-switch-backup.*` 备份（700/600，成功/回滚成功即清理）、**渲染 + nginx -t 前置**（失败零影响）、容器操作直操 docker（stop+rm）、**按原模式分别回滚**、`sudo -n ss` 退化 TLS 探测、验证域名从证书 SAN 构造、**偏移量新请求验证 + `${CURL_BIN:-curl}` 注入点** | ✅ 语法检查通过 |
| 7 deploy.sh | 远端模式检测（.env COMPOSE_FILE + haproxy 容器存在性）、**旧结构迁移**（compose stop → `docker stop/rm haproxy` 直操 → up -d，含迁移报告）、必需容器按模式判定、排错提示按模式 | ✅ 语法检查通过 |
| 8 test.sh | `detect_entry_mode`/`route_log_file`/`route_backend_pattern` 三助手；case 1 容器数、case 2 属主进程名、case 4/5/6 双模式路由断言 + **全部偏移量方案**；新增 **case 7**（NF 路由 + openssl 握手硬断言 + stdin EOF 关连接后轮询新增日志 + 归因输出）；新增 **case 8**（外部跳板 `--dep` 真实代理客户端 IP 验证：marker SNI 直连取服务端视角源 IP == xray from IP，验收门禁） | ✅ 语法检查通过 |
| 9 README/CLAUDE.md | 双模式架构图、快速开始含 render 步骤、切换脚本章节；CLAUDE.md 架构/特性/服务/测试用例全量对齐 | ✅ |

### 未开始（实施清单 10 —— 部署与实测，需用户确认）

10. **部署与实测**（按 003 第 5 节验证计划 10 项）：先创建 `.deployment-config`（见交接清单），`./scripts/deploy.sh` 部署到 sg（含旧结构迁移路径）；然后按序执行：nginx 模式全量 test.sh（含 case 7/8）→ `ngx_haproxy_switch.sh haproxy` → haproxy 模式全量 → 切回 nginx → 外部 IP 两条路径核验 → daemon 重启确认 → 三种失败注入（模板破坏 / CURL_BIN stub）→ 三种半完成修复。**注意：全部操作在 sg 生产服务器执行，443 有秒级中断窗口——动手前向用户确认。**

### 已知风险 / 待实测确认

- nginx stream 发 **PP v1**、HAProxy 发 v2——本地 xray（go-proxyproto）两者都收；`NF_XTLS_SERVER` 指向远端时的 v1 兼容性靠 case 7 实测。
- 远端 `sh` 必须支持 bash 语法（gen_env.sh 用了数组，现状 deploy 用 `sh gen_env.sh` 能跑说明远端 sh→bash；render_stream.sh 为纯 POSIX 无此顾虑）。
- `nginx:latest` 镜像的 `include tcp_stream_params;` 相对路径基于 prefix `/etc/nginx/`（与 docker-box 相同用法，待实测）。
- nginx 容器是否带 `sudo` 无关（ss 在宿主机跑）；宿主机 work 用户 sudo 免密依赖 init_sys_rocky.sh 的 sudoers 配置。
- 切换脚本 `pick_verify_domain` 依赖容器内 openssl 可读证书——证书未签发时（acme 未完成）选不出域名会跳过 curl 验证（WARN），不影响切换本身。
- case 8 依赖：跳板机可 SSH、有 docker（能提取 xray 二进制）、跳板→sg 公网 443 可达；默认跳板=本机（bj01），bj01→sg 公网连通性待实测；跳板在 NAT 后时"入口观察源 IP"与"跳板自视 IP"可能不同，断言比较的是**服务端视角**两个值，仍应相等。
- case 8 的 marker 直连 TLS 握手**预期失败**（vision 对未知 SNI rejectUnknownSni），但入口路由日志仍会记录该连接——此假设待实测确认。

### 交接清单（新会话必读——上下文清空后据此继续）

- **继续顺序** = README-003 实施清单（第 6 节）仅剩第 **10** 项（部署与实测，规格见 003 第 5 节验证计划 10 项）；✅/⏳ 状态标记以仓库内文档为准。
- **分支**：b1。继续前先 `git pull` 或与远端同步。
- **开发机 bj01 ≠ 部署目标**。部署目标是生产服务器 sg.cqcy.fun；本机**尚无** `.deployment-config`，首次 deploy/test 前创建：
  ```bash
  printf 'DEPLOYMENT_SERVER=work@sg.cqcy.fun\nDEPLOYMENT_PATH=/home/work/\n' > .deployment-config
  ```
  （`.deployment-config` 已被 .gitignore 忽略；test.sh/deploy.sh 均依赖它）
- **git push 必须用 SSH URL**：本仓库 remote 是 HTTPS 且无凭据，直接 `git push` 报 "could not read Username"。用：
  ```bash
  git push git@github.com:alpha-86/laddr-docker.git b1
  ```
- **生产操作前置确认**：deploy、模式切换、`systemctl restart docker`、失败注入都在 sg 上执行，443 有秒级中断窗口——动手前向用户说明并确认。
- **实测前先查远端状态**：`ssh work@sg.cqcy.fun "cd /home/work/laddr-docker && cat .env | grep COMPOSE_FILE && docker ps -a --format '{{.Names}}'"`——远端 .env 的 COMPOSE_FILE 与 haproxy 容器有无决定走迁移路径还是普通部署，以及当前模式判定。
- 环境其他注意事项见本文件"已知风险 / 待实测确认"一节；外网访问代理设置见 CLAUDE.md。

### 提交记录

- `2b6de21` docs: 003 设计文档初版（一轮 review 前）
- `5fe0d69` feat(wip): 实施清单 1–6（nginx 配置三件套/compose 拆分/连锁改动/render_stream/gen_env/切换脚本）+ 003 一轮/二轮修订 + worklog
- `0b0e410` docs: worklog 交接清单
- 本轮（待提交）：003 三轮修订 + 实施清单 7–9（deploy.sh/test.sh case7·8/README/CLAUDE.md）+ 切换脚本 CURL_BIN/偏移量/备份清理
