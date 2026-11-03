# ACME 证书 CA 策略与强制切换工具 设计文档

> 日期：2026-11-03
> 分支：b1
> 地位：本文是 `acme/` 证书体系与 CA 切换的**唯一规格来源**（worklog 只记进展）
> 相关：[003_worklog.md](003_worklog.md) §10（决策与实测进展）、[README-003-nginx-haproxy-switch.md](README-003-nginx-haproxy-switch.md)
> 实测环境：neilpang/acme.sh 容器内 v3.1.3，sg 生产

## 1. 背景与问题

`~/docker-box`（前代项目，laddr-docker 的对照原型）与 laddr-docker 的 acme 体系
**几乎逐字节相同**（compose 的 deploy-hook 环境变量、reload.sh、ssl.sh 域名展开
主流程均一致，2026-11-03 实测核对），仅两处差异：

| # | 差异 | docker-box | laddr-docker（差异前） |
|---|---|---|---|
| D1 | ssl.sh 设置默认 CA 的时机 | **每次容器启动无条件** `acme.sh --set-default-ca --server letsencrypt`（注释：覆盖账号配置里可能用过的其他 CA） | **仅首次启动**（`account.conf` 不存在）且受 `CA_LETSENCRYPT` 开关控制（gen_env 默认 1） |
| D2 | 存量证书换 CA 的工具 | 有 `force_to_letsencrypt.sh`（一次性迁移：按 DOMAIN_LIST 展开取主域名，`--renew --force --server letsencrypt` 强制重签 + docker hook 重部署） | 无 |

由此引出两个问题：
1. laddr 要不要对齐 D1（每次启动强制 LE 为默认）？
2. 存量证书已在别的 CA（或将来想换 CA）时，怎么切？

## 2. 方案讨论与决策（2026-11-03，与用户讨论定稿）

### 2.1 讨论过的选项

**选项 1（= docker-box D1 语义，每次启动强制 LE）——被否。** 两个理由：
- `set-default-ca` 只影响**新申请**的证书默认值，管不到存量证书的续期
  （存量续期按域名配置里的 `Le_API` 走）——docker-box 正是因此被咬过才补了
  force 脚本，"每次强制"的实际增量保护趋近于零；
- 每次启动强制的隐性代价：将来若想换 CA（ZeroSSL / Google Trust / Buypass 等），
  会被启动流程持续掰回 LE，必须先改脚本。

**选项 2（= laddr 现状，方案 A）——采纳。** "初始化时默认 LE，尊重环境历史"：
- 全新环境：`gen_env.sh` 生成 `CA_LETSENCRYPT=1` → 容器首启（账号状态全新）
  `set-default-ca letsencrypt`——"初始化默认 LE"已完整成立；
- 复用旧 acme 状态（重装/迁移拷入 `acme/acme.sh/`）：首启条件不成立，
  `set-default-ca` 跳过，默认 CA 以旧状态为准——**有意为之**：复用状态即保留其历史。

### 2.2 拍板结论

1. **维持 laddr 初始化语义（方案 A）**，不引入 docker-box 的每次强制；
2. **新增通用 `acme/force_switch_ca.sh`**：显式把存量证书切换到任意
   acme.sh 支持的 CA（LE / ZeroSSL / Buypass / SSL.com / Google / 自定义 ACME URL），
   即"想切才切、切得动、切完跟走"；
3. **不钉 acme.sh 镜像版本**（用户明确决定，保持 `latest`）。

## 3. force_switch_ca.sh 设计

### 3.1 机制（为什么"不管当前证书是哪家签的都能切"）

```
acme.sh --renew -d <主域名> --force --server <CA>
```

- `--renew --server` 是 acme.sh 官方支持的用法（v3.1.3 源码 usage 行：
  `--renew --domain <domain.tld> [--ecc] [--server server]`）。重签流程完全
  指向目标 CA，**旧 CA 不被联系、不构成前置**；唯一要求是目标 CA 能完成
  DNS 校验（Ali/CF 凭据已由 compose 注入）。
- 重签成功后，域名配置里的 `Le_API` 被**持久化为新 CA**：此后日常续期自动
  跟走新 CA，不再需要 force。

随后：

```
acme.sh --deploy -d <全部域名...> --deploy-hook docker   # 重部署 4 文件（含 fullchain → default_full.pem）
                                                          # + reload.sh（nginx reload + 重启 xray 加载新证书）
acme.sh --set-default-ca --server <CA>                    # 新签证书默认走新 CA
```

### 3.2 接口

| 项 | 内容 |
|---|---|
| 文件 | `acme/force_switch_ca.sh`（自包含，域名展开逻辑与 ssl.sh 一致，主域名 = 展开后第一个） |
| 挂载 | compose acme 服务：`${ACME_SH_PATH}/force_switch_ca.sh:/force_switch_ca.sh:ro` |
| 用法 | `docker exec acme sh /force_switch_ca.sh <ca>` |
| `<ca>` | `letsencrypt`（推荐）/ `zerossl` / `buypass` / `sslcom` / `google` / 任意 ACME directory URL |
| 无参 | 打印用法，exit 1 |

### 3.3 约束与风险

- **配额**：`--force` 重签计入 CA 的重复证书配额（LE：同名同 SAN 每周 5 张）——
  **日常续期严禁使用**；正常续期由 ssl.sh 的 `--issue` 在到期窗口自动完成。
- **ZeroSSL 前置**：需容器环境提供 `ZEROSSL_EAB_KID` / `ZEROSSL_EAB_HMAC_KEY`
  （EAB 注册），否则账号注册失败。
- **中断面**：deploy-hook 的 reload.sh 会重启 xray 容器（秒级代理中断），
  属正常部署类操作。
- **初始化语义不受影响**：ssl.sh / gen_env.sh 未做任何改动（方案 A）。

### 3.4 回滚思路

再跑一次指向原 CA 即可（同样走 force 重签，同样消耗一次配额）。

## 4. 验证记录（2026-11-03，sg 生产）

| 项 | 结果 |
|---|---|
| 无参调用 | 用法提示，exit 1 ✅ |
| `force_switch_ca.sh letsencrypt` 端到端 | 强制重签（命中当日 60 天续期窗口）→ deploy-hook 重部署 4 文件 → 默认 CA 设为 LE → `acme.sh --list` 显示 CA=LetsEncrypt.org ✅ |
| 服务端出示新证书 | 443 握手新证书（中间体 YE1→YE2，notAfter 2027-02-01）✅ |
| 代理链路 | case 5（Vision，严格 TLS 校验 + 完整链）全过 ✅ |
| 顺带验证 | 部署触发的容器重建跑了一次例行 `--issue`，正常续期路径（issue→deploy→reload）端到端通过 ✅ |

## 5. 使用手册

```bash
# 1) 看现状（证书、CA、到期时间）
docker exec acme acme.sh --list

# 2) 强制切换存量证书到目标 CA（与当前签发方无关）
docker exec acme sh /force_switch_ca.sh letsencrypt
# ZeroSSL 需先在 compose 环境注入 ZEROSSL_EAB_KID / ZEROSSL_EAB_HMAC_KEY
docker exec acme sh /force_switch_ca.sh zerossl

# 3) 验证：443 出示的证书日期/签发方应更新
echo | openssl s_client -connect 127.0.0.1:443 -servername <域名> 2>/dev/null \
  | openssl x509 -noout -dates -issuer
```
