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
| 代码（实施清单 1–9） | ✅ 全部完成，通过语法检查 / 本地干跑；**未经服务器实测** |
| 实测（实施清单 10） | ⏳ 未开始——在 sg 生产执行，需用户确认后按第 2 节 runbook 进行 |
| 分支 | b1，HEAD = `73d4929`（push 后若有新提交以仓库为准） |

**核心结论（审阅者必读，证据在设计文档 §2.3）**：
xhttp 入站可通过 `streamSettings.sockopt.acceptProxyProtocol` 接收 PROXY Protocol（Xray-core `ListenSystem` 统一处理，policy=REQUIRE），因此 nginx stream 可以像 docker-box 一样**全局 PP on、零中转**——这是整个方案的技术支点。连带约束：两种入口都必须向 xray 发 PP（HAProxy 侧补了 `send-proxy-v2`），否则 xhttp 连接全挂。

---

## 2. 下一步 runbook（接续开发直接照做）

> ⚠️ 全部在 sg 生产执行，443 多次秒级中断。**开始前先向用户确认。** 前置：本机 `.deployment-config` 不存在时需先创建（见第 6 节）。

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

## 5. 实测结果记录（实施清单 10 执行后填写）

| 验证项（README-003 §5） | 结果 | 日志/证据 | 日期 |
|---|---|---|---|
| 1 迁移（deploy.sh） | 待执行 | | |
| 2 nginx 模式全量 test.sh（含 case 7/8） | 待执行 | | |
| 3 切 haproxy + 全量 | 待执行 | | |
| 4 切回 nginx + 全量 | 待执行 | | |
| 5 NF + PP v1 握手实测 | 待执行 | | |
| 6 真实客户端 IP 两条路径 | 待执行 | | |
| 7 新请求偏移量断言 | 随上述执行 | | |
| 8 daemon 重启后 443 独占 | 待执行 | | |
| 9 失败注入 ×3 | 待执行 | | |
| 10 半完成修复 ×3 | 待执行 | | |

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

## 7. 已知风险 / 待实测确认

- **PP v1 vs v2**：nginx stream 发 PP v1、HAProxy 发 v2；本地 xray（go-proxyproto）两者都收；`NF_XTLS_SERVER` 指向远端时 v1 兼容性靠 case 7 实测（归因规则见 README-003 §4.1）。
- `include tcp_stream_params;` 相对路径基于 nginx prefix `/etc/nginx/`（与 docker-box 相同用法），待实测。
- 宿主机 work 用户 `sudo -n` 免密依赖 `init_sys_rocky.sh` 的 sudoers 配置；无 sudo 时切换脚本的 443 属主检查退化为 TLS 探测（WARN，不判失败）。
- 切换脚本的 `pick_verify_domain` 依赖容器内 openssl 可读证书；证书未签发时跳过 curl 验证（WARN），不影响切换。
- case 8 默认本机直跑（四轮修订，不再 self-SSH）：依赖本机 docker/curl/openssl、11082 空闲、bj01→sg 公网 443 与 www.google.com 可达；`--dep` 模式另需执行机→跳板 SSH；跳板在 NAT 后不影响断言（比较的是**服务端视角**两个 IP，仍应相等）。
- case 8 的 marker 直连 TLS 握手**预期失败**（vision 对未知 SNI rejectUnknownSni），但入口路由日志仍会记录该连接——此假设待实测确认。

## 8. 提交记录

- `2b6de21` docs: 003 设计文档初版（一轮 review 前）
- `5fe0d69` feat(wip): 实施清单 1–6 + 003 一轮/二轮修订
- `0b0e410` docs: worklog 交接清单
- `73d4929` feat: 实施清单 7–9（deploy/test/文档）+ 003 三轮修订 + 切换脚本 CURL_BIN/偏移量/备份清理
