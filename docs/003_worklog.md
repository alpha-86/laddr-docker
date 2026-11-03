# 003 开发进展（worklog）

> 关联设计文档：[README-003-nginx-haproxy-switch.md](README-003-nginx-haproxy-switch.md)（**唯一的规格来源**，本文不重复其细节，只记录进展与审阅入口）
> 任务：443 默认入口从 HAProxy 改为 Nginx stream（可选切回 HAProxy），双模式在线切换
> 开发机：bj01（仅运行 xray 客户端容器，**非**部署目标）；部署目标：sg.cqcy.fun（生产）
> 本文件随开发滚动更新。

---

## 1. 当前状态（速览）

| 维度 | 状态 |
|---|---|
| 设计（README-003） | ✅ 定稿，经过 4 轮 review 修订（记录见第 4 节） |
| 代码（实施清单 1–9） | ✅ 全部完成 |
| 实测（实施清单 10） | ✅ 全部完成（2026-11-03，sg 生产）——迁移/双模式全量/失败注入 ×3/半完成 ×3/daemon 重启 443 独占全通过；实测暴露并修复 11 项问题（见第 9 节） |
| 分支 | b1，本轮实测修复后以仓库为准 |

**核心结论（审阅者必读，证据在设计文档 §2.3）**：
xhttp 入站可通过 `streamSettings.sockopt.acceptProxyProtocol` 接收 PROXY Protocol（Xray-core `ListenSystem` 统一处理，policy=REQUIRE），因此 nginx stream 可以像 docker-box 一样**全局 PP on、零中转**——这是整个方案的技术支点。连带约束：两种入口都必须向 xray 发 PP（HAProxy 侧补了 `send-proxy-v2`），否则 xhttp 连接全挂。

---

## 2. runbook（已执行完毕，保留备查）

> ⚠️ 全部在 sg 生产执行，443 多次秒级中断。**2026-11-03 已按本 runbook 全部执行完毕（含第 5 步 daemon 重启验证：容器仅 nginx/xray/acme、443 由 nginx 独占）**，结果记录在第 5 节；执行中发现的偏差与修复记录在第 9 节。

```bash
# 0. 远端现状摸底（决定 deploy 走不走迁移路径）
ssh work@sg.cqcy.fun "cd /home/work/laddr-docker && grep COMPOSE_FILE .env; docker ps -a --format '{{.Names}}'"

# 1. 部署（预期：检测到旧 haproxy 容器 → 迁移路径 → docker rm → nginx 模式拉起）
./scripts/deploy.sh

# 2. nginx 模式全量测试（case 8 默认本机直跑；本机缺 docker/curl/openssl 或 11082 被占则判 FAIL，改用 --dep user@跳板）
./scripts/test.sh

# 3. 切 haproxy + 全量
ssh work@sg.cqcy.fun "cd /home/work/laddr-docker && scripts/ngx_haproxy_switch.sh haproxy"
./scripts/test.sh

# 4. 切回 nginx + 全量（最终停在默认模式）
ssh work@sg.cqcy.fun "cd /home/work/laddr-docker && scripts/ngx_haproxy_switch.sh nginx"
./scripts/test.sh

# 5. daemon 重启验证：443 只有目标入口监听、无 haproxy 复活
ssh -t work@sg.cqcy.fun "sudo systemctl restart docker && sleep 15 && ss -tlnp | grep ':443'"

# 6. 失败注入（规格见 README-003 §5.9；均需验证自动回滚）
#    a. nginx -t 注入：echo 'invalid directive !!!;' >> nginx/conf/conf.d/xray.stream.ngx
#       → ssh sg "scripts/ngx_haproxy_switch.sh nginx" → 应零影响退出
#       → git checkout -- nginx/conf/conf.d/xray.stream.ngx 恢复
#    b. haproxy 启动注入：echo 'invalid directive !!!;' >> haproxy/haproxy.cfg.tpl
#       → ssh sg "scripts/ngx_haproxy_switch.sh haproxy" → 应回滚到 nginx
#       → git checkout -- haproxy/haproxy.cfg.tpl → 再切 haproxy 应成功
#    c. curl 注入：CURL_BIN=/bin/false ssh sg "cd /home/work/laddr-docker && CURL_BIN=/bin/false scripts/ngx_haproxy_switch.sh haproxy"
#       → 验证步失败 → 应回滚（注意 CURL_BIN 要在远端环境生效）

# 7. 半完成修复（规格见 README-003 §5.10）：分别制造
#    只改 .env / 只换激活文件 / 只 docker rm haproxy，再 switch <目标>，应自动收敛

# 8. 全部通过后收尾：更新本 worklog 与 README-003 实施清单第 10 项；commit & push
#    （push 必须用 SSH URL，见第 6 节）
```

实测中发现与预期不符时：**先修 README-003 设计或代码，再回到 runbook**；每项实测结果记录到本文件第 5 节表格。

---

## 3. 变更清单（审阅入口，按文件）

| 文件 | 变更 | 规格 | 验证状态 |
|---|---|---|---|
| `nginx/conf/tcp_stream_params` | **新增**：stream 骨架；log_format 带 `sni:`/`backend:$tcp_backend`/`$time_iso8601`/`$upstream_addr` | §3.2 | 内容评审；`nginx -t` 待实测 |
| `nginx/conf/conf.d/xray.stream.ngx` | **新增**：443 server + map（`(?i)` 正则）+ 4 upstreams，含 `${REALITY_DEST}`/`${NF_XTLS_SERVER}` 占位符 | §3.2 | 渲染干跑 ✓ |
| `nginx/conf/conf.d/xray.stream.haproxy` | **新增**：空文件（haproxy 模式防 443 冲突） | §3.2 | 渲染干跑 ✓ |
| `nginx/conf/nginx.conf` | 顶层加 `include tcp_stream_params;` | §3.3 | 待实测 |
| `.gitignore` | 忽略生成的 `conf.d/xray.stream` | §6 | ✓ |
| `docker-compose.yml` | 移除 haproxy service；nginx 加 `tcp_stream_params`、`nginx_stream.log` 两个卷 | §3.5 | 待 `compose config` 实测 |
| `docker-compose-haproxy.yml` | **新增**：haproxy 整体迁入（entrypoint 渲染/rsyslog 原样保留） | §3.5 | 同上 |
| `xray/etc/config.json.tpl` | xhttp inbound 加 `"sockopt":{"acceptProxyProtocol":true}`（REQUIRE） | §3.4 | 源码级验证；待实测 |
| `haproxy/haproxy.cfg.tpl` | `xhttp_backend` 加 `send-proxy-v2`（注释同步更新） | §3.4 | 待实测 |
| `scripts/render_stream.sh` | **新增**：统一渲染命令 `[mode] [输出]`；空变量拒绝、占位符自检、临时文件+mv 原子替换 | §3.6 | 干跑 3 场景 ✓ |
| `gen_env.sh` | TTY 且 .env 不存在时询问「启用 HAProxy？[y/N]」；`touch log/nginx_stream.log`；调渲染（失败仅告警） | §3.7 | `bash -n` ✓；交互未实测 |
| `scripts/ngx_haproxy_switch.sh` | **新增**：状态收敛式切换 `nginx\|haproxy\|status`——五项收敛判据（渲染临时文件 cmp）、flock、/tmp 备份（700/600，成功即清理）、**渲染+nginx -t 前置**（失败零影响）、容器操作直操 docker、**按原模式分别回滚**、`sudo -n ss` 退化 TLS 探测、证书 SAN 构造验证域名、**偏移量新请求验证**、**`CURL_BIN` 注入点** | §3.8 | `bash -n` ✓；全部行为待实测 |
| `scripts/deploy.sh` | 远端模式检测（.env COMPOSE_FILE + haproxy 容器）；**旧结构迁移**（compose stop → `docker stop/rm haproxy` → up -d，含迁移报告）；必需容器/排错提示按模式 | §3.9 | `bash -n` ✓；待实测 |
| `scripts/test.sh` | 模式检测三助手（`detect_entry_mode`/`route_log_file`/`route_backend_pattern`）；case 1/2/4/5/6 双模式分支 + **全部偏移量断言**；**case 7**（NF 路由 + openssl 握手硬断言 + stdin EOF 关连接轮询 + 归因输出）；**case 8**（**默认本机直跑不经 SSH**（`dep_exec()`，废除 self-SSH），`--dep user@host` 才走 SSH/scp；前置缺失判 FAIL 明示缺项；`--dep` 模式跳板需 docker/curl/openssl、local 模式查本机三件套 + 11082 空闲；外部真实代理客户端 IP 交叉验证：marker SNI 直连取服务端视角源 IP == xray `from` IP（**归因三约束：from==seen_ip + 目标==www.google.com:443 + 偏移之后**），强制非回环，**两种模式验收门禁**） | §4.1/§4.2 | `bash -n` ✓；待实测 |
| `README.md` | 双模式架构图、快速开始含 `render_stream.sh` 步骤、「入口模式切换」章节 | — | 人工审阅 |
| `CLAUDE.md` | 架构图/特性/服务（HAProxy 标记可选）/测试用例 1–8 全量对齐 | — | 人工审阅 |
| `docs/README-003-*.md` | 设计文档，4 轮 review 定稿 | — | 见第 4 节 |

**审阅建议顺序**：README-003（§2.3 技术支点 → §3.8 切换脚本 → §3.9 迁移）→ 上表文件 → 第 4 节 review 记录 → runbook（第 2 节）。

---

## 4. 设计 review 修订记录（三轮）

### 一轮（8 项）——补齐接线/时序/迁移/回滚/渲染
补齐 stream 接线（`nginx.conf` include + compose 卷，缺了 nginx 根本不监听 443）；修正切回 nginx 的 compose 时序（先移除 COMPOSE_FILE 再 `compose stop haproxy` 会 `no such service`）；重写存量迁移（`stop && up -d` **不移除 orphan**，旧 haproxy 继续持有 443——deploy.sh 必须显式 `docker rm`）；deploy.sh 模式感知；状态收敛式切换（备份/flock/原子替换/超时重试/nginx -t 前置）；stream 日志预创建（防 bind mount 创建目录）；统一渲染命令 `render_stream.sh`；扩充验证范围。

### 二轮（6 项 + 4 小项）——修正两个阻断性时序错误
**nginx -t 必须在释放 443 之前**（原顺序先删 haproxy 再校验，校验失败 = 服务已中断）；**回滚按原模式分别定义**（回滚到 nginx 必须先 `docker rm -f haproxy`——恢复 .env 后 haproxy 变 orphan 且 compose 已不认识它，不删则 nginx 永远起不来）；半完成状态每个操作按实际状态分支、容器操作直操 docker；验证域名从**证书 SAN** 构造（首个 SAN 是 `*.example.com` 时拼 `switchtest.*.example.com` 是非法域名）；case 7 拆路由断言（backend 名）与 PP 断言（openssl 握手成功硬要求，"握手成败均可"证明不了 PP v1）；真实 IP 验证分两条路径（普通 curl 走默认后端、**不产生 xray 日志**——原方案检查 xray_access.log 是错误路径）；备份改 `/tmp` 700/600；`ss -tlnp` 用 `sudo -n`（普通用户看不到 root 进程的 `users:` 字段）；失败注入破坏**模板**而非激活文件（切换渲染会覆盖激活文件）；引用编号与措辞修正。

### 三轮（5 项）——修正无效注入与验证严谨性
curl 失败注入改 **`CURL_BIN` 环境变量注入 stub**（验证域名取自证书 SAN 而非 `.env` DOMAIN_LIST，改 DOMAIN_LIST 不影响验证——原方案无效；不得破坏正式证书配置）；haproxy 启动失败注入改**破坏 `haproxy.cfg.tpl`**（原"临时容器占用 443"不可行：切换前 443 被 nginx 持有，bind 必失败，且残留占用会拖垮回滚）；新请求断言全量改**字节偏移量方案**（原 `HH:MM:SS ≥ mark` 有同秒历史误匹配与跨午夜失效）；case 7 握手失败**归因修正**（报告"NF 握手失败，可能为 PP 版本或上游异常"，仅 v2 成功+v1 失败对照才定性 PP v1 不兼容）；**外部真实 IP 验证强制化**（新增 test.sh case 8 为验收门禁，服务器本机的 case 5/6 源地址恒 127.0.0.1，不能替代）；切换成功/回滚成功即**清理 /tmp 备份目录**（仅回滚失败保留并提示）。

### 四轮（4 项 + 3 项元信息）——case 8 执行约定与日志归因
**case 4/5/6 残留时间窗断言清除**（§4.1 仍写"时间 ≥ 标记"，与 §3.8/§5/实施清单的字节偏移统一方案冲突，全文改齐，含 §3.2 决策记录处的旧表述）；**case 8 默认执行方式改为本机直跑**（原"ssh 到本机"隐含 self-SSH 依赖：本机 sshd + 自登录密钥 + 本机 docker，缺一则全量测试在 case 8 必败且与服务器 PP 配置无关——废除 self-SSH，local 模式经 `dep_exec()` 直跑，`--dep user@host` 才走 SSH/scp）；**case 8 验收前置条件写入设计文档 §4.2**（SSH/docker/curl/openssl/443 可达/Google 可达/11082 空闲/NAT 比较的是服务端视角出口公网 IP；前置缺失判 FAIL 并明示缺哪项，不静默跳过）；**case 8 日志归因三约束**（from 记录必须同时满足 源 IP == 入口观察 seen_ip + 目标 == www.google.com:443 + 位于字节偏移之后，禁止取"任意一条 from"——防并发客户端误取）。元信息：顶部/§5 "两轮 review"→四轮；"全量用例"明确为含 case 7/8。测试目标域名固定 **www.google.com**（用户明确）。

---

## 5. 实测结果记录（2026-11-03 执行）

| 验证项（README-003 §5） | 结果 | 日志/证据 | 日期 |
|---|---|---|---|
| 1 迁移（deploy.sh） | ✅ | 检测到旧 haproxy 容器 + 旧 .env → 迁移路径 → `docker rm` → nginx 模式拉起，nginx/acme/xray 全健康 | 11-02 |
| 2 nginx 模式全量 test.sh（含 case 7/8） | ✅ | 22 通过/1 警告/0 失败（警告=无 sudo 时 443 属主退化 TLS 探测 WARN，设计内）；case 7 backend:nf_xtls 握手 Verify 0；case 8 seen==from==168.138.212.150 | 11-03 |
| 3 切 haproxy + 全量 | ✅ | 23/1/0；case 7 nf_xtls_backend；case 8 同样通过（haproxy 日志 IP 提取修复后） | 11-03 |
| 4 切回 nginx + 全量 | ✅ | 22/1/0（最终状态=nginx 默认模式，又于收尾时复跑确认） | 11-03 |
| 5 NF + PP v1 握手实测 | ✅ | 两模式 openssl 握手均 rc=0 / Verify return code 0 (ok)（NF_XTLS_SERVER=127.0.0.1:18910 本地 vision，天然接受 v1/v2） | 11-03 |
| 6 真实客户端 IP 两条路径 | ✅ | case 8 两模式均 seen_ip == from_ip == 168.138.212.150（非回环）；入口日志（marker SNI）与 xray from 交叉验证 | 11-03 |
| 7 新请求偏移量断言 | ✅ | 切换脚本 verify_new_request 与 case 4–8 全部按字节偏移匹配 | 11-03 |
| 8 daemon 重启后 443 独占 | ✅ | `sudo systemctl restart docker` 后 15s：容器仅 nginx/xray/acme（haproxy 无复活），443 两条 LISTEN（v4+v6），nginx 独占 | 11-03 |
| 9 失败注入 ×3 | ✅ | a) 破坏 xray.stream.ngx → 切 nginx：渲染过、nginx -t 败 → rc=1 零影响退出，443 无损；b) 破坏 haproxy.cfg.tpl → 切 haproxy：启动败 → 单次回滚 rc=3，恢复模板后重切成功；c) CURL_BIN=/bin/false → 验证步败 → 单次回滚 rc=3，终态 nginx | 11-03 |
| 10 半完成修复 ×3 | ✅ | 7A 只改 .env → 收敛 rc=0；7B 只换激活文件 → 收敛 rc=0（初版脚本错滚致 443 掉线，修复 orig 透传后复测通过）；7C 只 docker rm haproxy → 重建收敛 rc=0 | 11-03 |

### 5.1 测试执行明细（时间线与关键证据）

> 完整命令序列见第 2 节 runbook。时间均为 2026-11-02/03（Asia/Shanghai）。过程中每次失败先修代码/设计再回到 runbook，修复详情见第 9 节。

**11-02 23:00 迁移（验证项 1）**
- 前置摸底：远端 `.env COMPOSE_FILE=docker-compose.yml:docker-compose-xray.yml`（旧结构），haproxy/xray/nginx/acme 四容器 Up 10 days
- deploy.sh 输出"检测到旧版 HAProxy 容器 → 走迁移路径"，`docker rm` 旧容器后拉起 nginx/xray/acme；443 由 nginx（host 网络）监听，v4+v6 各一条 LISTEN

**11-03 08:26 nginx 模式全量（验证项 2，含 case 7/8）—— 结果 22 通过/1 警告/0 失败**
- case 4：`sni:blog.862436.xyz backend:ngx`，nginx access log 命中 querystring `r=21195`
- case 5（Vision）：链路五组件对齐（测试开始/HTTP响应/客户端 08:26:47，入口路由/服务端 08:26:48），xray 服务端 `from 127.0.0.1:40246 accepted tcp:www.google.com:443`
- case 6（XHTTP+REALITY）：`sni:www.fifa.com backend:xhttp`，HTTP 200
- case 7：`openssl rc=0 / Verify return code: 0 (ok)`，入口日志 `backend:nf_xtls`
- case 8（门禁）：marker SNI `extip18339.x.sg.862436.xyz` 命中入口日志，seen_ip == from_ip == 168.138.212.150（非回环）
- 警告 1 条：case 2 "443 监听中但属主不可见（无 sudo），TLS 探测正常"——设计内退化

**11-03 08:54 首次切换 haproxy —— 暴露 F3/F4（第 9 节）**
- 现象：`xray.stream.haproxy` 注释桩缺 `$tcp_backend` 定义 → `nginx -t` emerg；修复分支又因 `atomic_replace` 的 set -u 展开顺序 bug 崩溃（`dst: unbound variable`）
- 修复桩内补最小 map + atomic_replace 分行声明后，08:56 切换成功：5 步全过，验证请求 `sw15373.862436.xyz → ngx_backend` 按字节偏移命中 haproxy_access.log

**11-03 08:58 haproxy 模式全量（验证项 3）—— 23 通过/1 警告/0 失败**
- case 7：`nf_xtls_backend` 路由正确，PP v2 路径握手 `Verify 0 (ok)`
- case 8 首次在 haproxy 模式执行：暴露 F10-③——seen_ip 提取 `awk '{print $1}'` 在 haproxy syslog 行上取到月份 "Nov"；修复为统一 ip:port 正则后单跑 case 8 与后续全量均通过

**11-03 09:08 切回 nginx + 全量（验证项 4）—— 22 通过/1 警告/0 失败**，最终停在默认模式

**11-03 09:1x 失败注入（验证项 9）**
- 6a 破坏 `xray.stream.ngx`（服务端追加非法指令）→ `switch nginx`：渲染过、nginx -t 失败 → rc=1 零影响退出，443 TLS 探测 `Verify 0 (ok)` 无损；此过程暴露并修复"nginx -t 失败还原逻辑误写对端桩"（见 9-F7 前置修复）
- 6b 破坏 `haproxy.cfg.tpl` → `switch haproxy`：容器启动失败 → 自动回滚；**初版脚本暴露 F5/F6**——回滚后竟继续执行 verify、二次回滚后报"已切换成功 rc=0"（restart:always 崩溃重启的瞬时 running 窗口同时骗过属主检查）；修复 rollback 终止性（exit 3）+ `haproxy_stable_running` 双采样后复测：单次回滚 rc=3、终态 nginx 一致；恢复模板后重切 haproxy 成功（rc=0，`sw3464` 验证命中）
- 6c `CURL_BIN=/bin/false`（远端环境变量注入）→ `switch haproxy`：验证步 3 次尝试均不发请求 → 单次回滚 rc=3，终态 nginx、无 haproxy 容器

**11-03 09:3x 半完成修复（验证项 10）—— 初测暴露 F7，修复后三连过**
- 7B 初测（只换激活文件为 haproxy 桩、.env 仍 nginx，`switch nginx` 自修复）：`wait_443_free` 因 443 由 nginx 持续持有必然超时 → 错滚到 haproxy → 回滚校验失败 exit 2，**且 443 掉线**（回滚把 nginx 按桩重启了）
- 修复（orig 透传 + remove/wait 条件化）后复测：7B rc=0 / 7C（只 docker rm haproxy）rc=0 容器重建 / 7A（只改 .env）rc=0；清理全部遗留备份目录

**11-03 09:47 收尾复跑 nginx 全量 —— 22 通过/1 警告/0 失败**，确认最终状态：nginx 默认入口、443 v4+v6 监听、haproxy 容器不存在

**11-03 daemon 重启验证（验证项 8，用户交互执行）**——`sudo systemctl restart docker` 后 15s：容器仅 `nginx xray acme`（haproxy 无复活抢占），443 两条 LISTEN 由 nginx 独占 → 验证项 10/10 全过，实施清单 10 闭环

**case 8 归因细节（两模式通用证据形态）**：入口日志记录 marker SNI 连接（服务端视角源 IP）→ 本机 xray 客户端（SOCKS 11082，Vision）经公网出网 → xray_access.log 偏移后新行 `from <同一 IP> accepted tcp:www.google.com:443` ——三约束（源 IP 相等、目标 www.google.com:443、字节偏移之后）同时满足。注意 www.google.com 的解析必须发生在服务端（`--socks5-hostname`），bj01 本地 DNS 返回 `2001::1` 不可信（9-F10①）。

---

## 6. 交接清单（环境事实，新会话/他人必读）

- **分支** b1。继续前先 `git pull` 或与远端同步（HEAD 参考第 1 节）。
- **开发机 bj01 ≠ 部署目标**。sg.cqcy.fun 为生产；本机 `.deployment-config` 不在仓库（gitignore），首次需创建：
  ```bash
  printf 'DEPLOYMENT_SERVER=work@sg.cqcy.fun\nDEPLOYMENT_PATH=/home/work/\n' > .deployment-config
  ```
- **git push 必须 SSH URL**（remote 是 HTTPS 无凭据，直接 push 报 "could not read Username"）：
  `git push git@github.com:alpha-86/laddr-docker.git b1`
- **生产操作前置确认**：deploy、模式切换、`systemctl restart docker`、失败注入都在 sg 执行，443 秒级中断。
- 远端 `sh` 实为 bash（`sh gen_env.sh` 能跑数组语法）；`render_stream.sh` 为纯 POSIX，无此顾虑。
- 提交信息结尾需带：`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
- 外网访问代理设置见 CLAUDE.md（google-search.sh / http_proxy 1087）。

## 7. 已知风险 / 待实测确认（实测后刷新）

- ~~**PP v1 vs v2**：nginx stream 发 PP v1、HAProxy 发 v2；本地 xray（go-proxyproto）两者都收；`NF_XTLS_SERVER` 指向远端时 v1 兼容性靠 case 7 实测~~ ✅ 已实测：case 7 两模式对本地 vision（127.0.0.1:18910）openssl 握手均成功（Verify 0）。`NF_XTLS_SERVER` 改指远端时本用例即远端兼容性证据（v1/v2 归因规则见 README-003 §4.1 不变）。
- ~~`include tcp_stream_params;` 相对路径~~ ✅ 已实测可用（nginx 镜像 prefix 一致）。
- **sg 的 work 用户无 `sudo -n` 免密**（`init_sys_rocky.sh` 的 sudoers 未覆盖该机）：切换脚本与 test.sh case 2 均按设计退化为 TLS 探测（WARN 不判失败）；需 root 的操作（如 daemon 重启）由用户交互执行（2026-11-03 已执行，结果见第 5 节验证项 8）。
- ~~切换脚本的 `pick_verify_domain` 依赖证书可读~~ 未触发（证书有效，WARN 分支未走到）。
- case 8 本机直跑前置（docker/curl/openssl、11082 空闲、bj01→sg 443 可达）✅ 实测满足；`--dep` 模式未实测（无跳板需求）。
- ~~case 8 marker 直连握手预期失败但入口仍记录~~ 实测：marker SNI 取自证书覆盖范围，vision 握手成功且入口日志正常记录；真正未知 SNI（rejectUnknownSni）下入口是否记录未验证，不影响断言。
- **公网 DNS 与证书覆盖不一致（实测新发现）**：部分子域无通配符解析记录（`*.ddx.cqcy.host` NODATA；`*.ddd.862436.xyz`、`*.sg.cqcy.ltd` 有记录）。case 8 从执行机公网直连，域名须真实可解析——test.sh 选型已改为优先执行机可解析候选并加 DNS 前置检查；服务端用例（case 4–7）经 `--resolve`/127.0.0.1 不依赖公网 DNS。
- **bj01 本地 DNS 污染境外域名**（实测 `www.google.com → 2001::1`）：case 8 必须 `--socks5-hostname`（域名交服务端解析），否则服务端日志目标为裸 IP、归因失配——已修。

## 8. 提交记录

- `2b6de21` docs: 003 设计文档初版（一轮 review 前）
- `5fe0d69` feat(wip): 实施清单 1–6 + 003 一轮/二轮修订
- `0b0e410` docs: worklog 交接清单
- `73d4929` feat: 实施清单 7–9（deploy/test/文档）+ 003 三轮修订 + 切换脚本 CURL_BIN/偏移量/备份清理
- `7e0b9d4` / `25843bc`: 四轮 review + worklog 重构（历史，先于本轮实测）
- `1ed0046` fix: sg 实测修复（实施清单 10）— 证书全链/禁 allowInsecure/切换脚本回滚与自修复等 11 项（第 9 节）+ 本文档 §1/§2/§5/§7 刷新
- `33e6b2c` docs: worklog 补充测试执行明细（§5.1 时间线与关键证据）

## 9. 实测发现与修复记录（2026-11-03，按发现顺序）

> 用户硬性要求：**不允许 allowInsecure**。所有修复以此为前提。

| # | 问题（现象 → 根因） | 修复 |
|---|---|---|
| F1 | xray 客户端启动失败 "The feature allowInsecure has been removed"——服务端/本机 xray 已 26.x，配置含 `allowInsecure` 直接拒绝加载 | test.sh 两处客户端 tlsSettings 删除 `allowInsecure`（用户明确禁止该开关） |
| F2 | 禁 allowInsecure 后链路易校验失败：nginx/xray 出示的是 **leaf-only** `default_cert.pem`（acme.sh docker hook 的全链在 `default_full.pem`，无人使用；历史被 allowInsecure 掩盖） | `server_params`、`xray/etc/config.json.tpl`、`nginx/entrypoint.sh` 改用 `default_full.pem`（对齐 docker-box 参照）；test.sh case 3 改查 fullchain。实测两端 `Verify return code: 0 (ok)` |
| F3 | 切 haproxy 第一步必失败：`xray.stream.haproxy` 注释桩未定义 `$tcp_backend`（`tcp_stream_params` log_format 引用它，nginx 加载时校验变量存在性）→ `unknown "tcp_backend" variable` | 桩内补最小 `map $ssl_preread_server_name $tcp_backend { default ngx; }`（无 server 块永不取值） |
| F4 | 切换脚本 `atomic_replace` 内 `local src=.. dst=.. tmp="$dst.."` 同行展开顺序问题 → `dst: unbound variable`（set -u） | 赋值分两条 local 语句 |
| F5 | **回滚非终止**：rollback 成功 return 0，调用方继续执行后续步骤 → 实测"回滚后继续 verify → 二次回滚 → 最终报已切换成功 rc=0"的严重误导 | rollback 改为终止性：成功恢复 `exit 3`（切换失败但已回滚），恢复失败 exit 2；退出码写入用法文档 |
| F6 | restart:always 崩溃重启的**瞬时 running 窗口**骗过 `wait_443_owner`（6b 注入中 haproxy 崩溃循环仍被判定"已监听"） | 新增 `haproxy_stable_running`（间隔 2s 双采样 running）用于启动/回滚校验 |
| F7 | **回滚目标硬编码对端模式** + 自修复场景 `wait_443_free` 必然超时：`switch nginx` 在 current=nginx 自修复时因 443 由 nginx 持续持有而 wait 超时 → 错滚到 haproxy → 回滚校验失败 exit 2 且 **443 掉线**（实测发生） | switch 函数接收 orig（=main 的 current）作回滚目标；`remove_haproxy_container`/`wait_443_free` 仅在 haproxy 容器存在/原模式为 nginx 时执行。7A/7B/7C 复测全收敛 |
| F8 | test.sh case 2 无 sudo 时 ss 无 users: 字段 → 443 属主误判 FAIL | 属主不可见时退化为"443 监听 + TLS 探测"→ WARN（与切换脚本同策略） |
| F9 | case 5/6/8 客户端启动检查：固定 sleep 5 与慢链路启动竞态；轮询赋值未命中时 grep rc=1 触发 set -e 杀脚本；错误日志路径指向不存在的 `$temp_dir/client_error.log` | 改 15×1s 轮询（`|| true` 防 set -e）；失败时读客户端配置里的真实 error 日志 |
| F10 | case 8 三连：①`--socks5` 本地 DNS 污染（bj01 解析 www.google.com 得 `2001::1`）→ 服务端日志目标为裸 IP、归因失配；②清理 pkill 模式带绝对路径，与 `./xray run -c client_config.json` 相对 cmdline 不匹配 → 残留客户端（11082 被占）；③haproxy 模式 seen_ip 提取 `awk $1` 取到日志月份 "Nov" | ①`--socks5-hostname`；②pkill 模式改 `'xray run -c client_config.json'`；③统一 `grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]+'` 提取（两种格式行首第一个 ip:port 均为客户端） |
| F11 | case 8 随机选中**证书覆盖但公网无解析**的域名（`*.ddx.cqcy.host` NODATA）→ 执行机 openssl 无法解析 → marker 记录缺失 | test.sh 域名选型过滤"执行机可解析"候选（`domain_resolvable`，DEP_SERVER 感知）；case 8 前置加 DNS 解析检查，失败明示 |

旁路观察：deploy.sh 每次部署都会跑 `gen_env.sh` → 重新渲染激活文件（按 .env 模式）——本次实测中它顺带修复过一次失败注入后的磁盘漂移，行为良性；但若将来移除该行为需注意激活文件不再随部署刷新。
