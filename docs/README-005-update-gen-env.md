# gen_env.sh 交互化重写（.env 生成与更新向导）设计文档

> 日期：2026-11-03
> 分支：b1
> 地位：本文是 `gen_env.sh` 行为（含交互模式、静默模式、REALITY/UUID 生成语义）的**唯一规格来源**（worklog 只记进展）
> 相关：[005_worklog.md](005_worklog.md)（进展与实测记录）、[README-004-acme-ca-switch.md](README-004-acme-ca-switch.md)（CA 体系）、[README-003-nginx-haproxy-switch.md](README-003-nginx-haproxy-switch.md)（入口切换）
> 实测环境：bj01 本地（测试矩阵 49 项全过）；sg 生产仅受影响于 silent 路径（行为不变）

## 1. 背景与问题

### 1.1 历史脚本行为

`gen_env.sh` 是线性一次性脚本：建目录 → 声明生成器（UUID / REALITY 密钥对）→
解析已有 `.env` → `VARS` 数组展开默认值（**副作用：展开即执行所有 `$(...)`）** →
合并（已有值优先，缺失填默认）→ 按分块写回 → 副作用（touch stream 日志 +
`render_stream.sh`）。唯一的交互点是"全新 `.env` + 交互终端"时询问 HAProxy y/N。

**硬约束**：`scripts/deploy.sh:83` 通过非 TTY 的 ssh 执行 `sh gen_env.sh`（每次部署都跑），
因此任何改动必须保留一条**完全静默、合并行为不变**的路径，否则部署中断。

### 1.2 Bug 1（严重）：fresh init 的 REALITY 私钥/公钥不匹配

历史 `VARS` 中对 `generate_reality_config` **独立调用三次**（私钥、公钥、shortId 各取一次），
每次生成新密钥对 → `.env` 中 `REALITY_PRIVATE_KEY` 与 `REALITY_PUBLIC_KEY` 来自
**两对不同的密钥**，xhttp（case 6）必然握手失败。

2026-11-03 在 sg 验证：线上 `.env` 公私钥匹配——即线上文件并非由该 fresh 路径生成
（手工配置或经修复），**脚本 bug 对任何新机器 fresh 初始化必现**。

### 1.3 Bug 2（轻）：`XRAY_UUID_9000/9001` fresh 时为空

历史默认值 `$(get_existing_value "XRAY_UUID" || gen_uuid)` 有两个缺陷：

1. `get_existing_value` 是 `grep | cut` 管道，退出码恒取 `cut`（0），`|| gen_uuid` **永不触发**；
2. 读取的是**旧 `.env`** 的 `XRAY_UUID`，fresh 时为空 → 两个端口 UUID 写入空值。

下游 `xray/init_uuid.sh:34-41` 有空值兜底（回落主 UUID）所以不炸，但"每端口独立 UUID"
设计意图落空、`.env` 留空值。另有一处语义要保留：silent 合并时若旧 `.env` 缺
`_9000/_9001` 但**有主 UUID**，历史默认 = 旧主 UUID（而非新随机），重写需延续。

### 1.4 附带发现的解析缺陷（本次测试暴露）

镜像 `teddysun/xray` 的 `xray x25519` 输出为**三行**（历史代码假设两行）：

```
PrivateKey: KFPP...
Password (PublicKey): ynk...      ← 历史代码锚定 "Password:" 解析不到 → 公钥为空
Hash32: Nsk1...
```

历史 `gen_env.sh` 与线上 `.env` 手工共存掩盖了该问题（线上公钥是手工填入的）。

## 2. 方案讨论与决策（2026-11-03 与用户讨论定稿）

### 2.1 触发方式 → **混合模式**（三选一）

| 选项 | 结论 |
|------|------|
| 全交互（只要 TTY 就跑向导） | 否：服务器上手动跑（只想触发重渲染）会被迫答题 |
| flag-only（必须 `-i`） | 否：交互功能 discoverability 差，与"改为交互式"诉求有距离 |
| **混合：fresh+TTY 自动向导；已有 `.env` 无参静默（末尾提示 `-i`）；非 TTY 永远静默** | **采纳** |

### 2.2 更新粒度 → **按块编辑**（三选一）

逐项确认 23 个变量太繁琐；只问空值无法修正已配错的值。**采纳按块**：
逐块显示当前值（敏感项脱敏），`Enter` 跳过整块、`e` 进块内逐项
（`Enter` 保留 / `r` 重新生成 / 输入覆盖 / `-` 清空）。

### 2.3 UUID 策略 → **默认跟随主 UUID**

`XRAY_UUID_9000/_9001` 默认 = 主 UUID（`.env` 自包含，不再留空依赖下游兜底）；
向导中每个端口 UUID 可 `r` 独立生成或粘贴自定义，update 模式支持 `main` 关键字恢复跟随。

### 2.4 入口模式在向导中 → **只读展示 + 指路**

`COMPOSE_FILE` 在向导/更新中均不可改（展示当前模式，提示用
`scripts/ngx_haproxy_switch.sh`）。理由：gen_env 只生成配置不改运行态，允许直接改
`.env` 会造成 `.env` 与运行模式漂移；联动 switch 又会让配置脚本耦合部署操作。

### 2.5 顺带决策

1. **移除 openssl 兜底**：历史无 docker 时用 openssl 生成两个独立随机串冒充密钥对
   （互不匹配的占位值）。现改为硬失败——本项目部署目标必有 docker（docker-compose
   本身依赖），生成无效配置比失败更糟。
2. **静默+已有 `.env` 不再白跑 keygen**：历史每次 deploy 都执行三次 `docker x25519`
   （VARS 展开副作用），现按需生成。
3. **silent 部分缺失自动修复**（deploy 安全）：REALITY 私钥/公钥任一缺失时——
   有私钥缺公钥 → `x25519 -i` 推导补齐；缺私钥 → 生成新对并覆盖孤儿公钥（成对优先
   于"一律保留"）；两者都在 → 不动（**不做匹配校验**，避免每次部署白跑 docker，
   历史也不校验）。公开展示不匹配检测仅在向导 `r` 重新生成路径隐式覆盖。

## 3. gen_env.sh 设计

### 3.1 模式判定

| 条件 | 模式 | 行为 |
|------|------|------|
| 非 TTY（stdin）或 `--batch` | silent | 历史合并逻辑逐字节保留 + §1/§2 修复；`-i` 给警告后忽略 |
| TTY + `.env` 不存在 | wizard（fresh） | 全量分块向导 |
| TTY + `.env` 存在 + `-i`/`--interactive` | update | 按块编辑向导 |
| TTY + `.env` 存在无参 | silent + hint | 历史行为 + 末尾提示 `./gen_env.sh -i` |

### 3.2 CLI

```
gen_env.sh [-i|--interactive] [--advanced] [--batch] [-h|--help]
```

- `-i`：已有 `.env` 时进入更新向导（需交互终端）
- `--advanced`：向导中启用环境目录块编辑（fresh 向导里改 `DOCKER_BOX_HOME` 时，
  其余路径若仍持原默认值会跟随新根；update 模式不级联）
- `--batch`：强制静默（等价非交互终端）

### 3.3 wizard（fresh）流程

入口模式（HAProxy y/N，历史提问保留）→ 环境目录（仅 `--advanced`）→ ACME
（DNS provider 单选 1 Aliyun / 2 Cloudflare / 3 两者 → 只问所选，`read -s` 不回显，
全空给警告；email；CA 单选 1 LE / 2 ZeroSSL；`DOMAIN_LIST` 必填循环校验）→
Xray UUID（主 UUID 可 `r` 重生成/自定义粘贴过格式校验；`_9000/_9001` 默认跟随主，
`r` 独立生成）→ REALITY（密钥对**单次生成**、展示 PublicKey，`Enter` 接受 / `r` 重生成 /
粘贴私钥自定义（docker 推导公钥）；shortId；`REALITY_DEST` 非空）→ NF（仅 HAProxy
模式询问）→ 配置摘要（敏感项脱敏）。

### 3.4 update 向导（`-i`）

载入现有值（缺失变量用默认值补齐并提示数量）；入口块只读展示 + 指路 switch；
环境目录块（`--advanced` 才编辑）；逐块闸门 `Enter` 跳过 / `e` 编辑；写盘前变更摘要
（masked old → new）+ `Y/n` 确认，`n` 放弃且不改 `.env`。

UUID 编辑：`Enter` 保留 / `r` 重新生成 / `main` 跟随主（仅 `_9000/_9001`）/ 粘贴自定义
（格式校验）。REALITY 私钥：`r` 重新生成密钥对（同步公钥）/ 粘贴私钥（docker 推导公钥
并同步）。CA 以 `1`/`2` 单选呈现，写回 `CA_LETSENCRYPT=1/0`。

### 3.5 静默路径（行为不变性）

- 合并规则、`.env` 分块注释格式、变量顺序、敏感值前三位脱敏、新增/值已变更报告
  文案——**全部与历史版本一致**（已有 `.env` 值零漂移，deploy 日志无差异）。
- 仅输出层面的合理差异：fresh 时 `_9000/_9001` 默认值从"空"变为"主 UUID"（Bug 2 修复）；
  旧 `.env` 缺 `_9000/_9001` 时，若其值与新的主-UUID 默认不同，会出现在"值已变更"
  报告中（仅报告，写入值 = 历史语义）。
- 修复项（§1.2/§1.3/§1.4）影响的是 fresh 与"部分缺失"场景，正常 deploy 路径不变。

### 3.6 非功能约束

- 单文件、bash 语法（与历史一致，远端 `sh`→bash）；函数化 + `main` 分发
- 所有临时文件 `trap cleanup EXIT` 清理
- 副作用保留：touch `log/nginx_stream.log` + 调 `scripts/render_stream.sh`（失败仅警告）
- 向导中被 `$(...)` 捕获的函数（`prompt_uuid` / `prompt_reality_pair`）信息输出
  必须走 stderr，stdout 只输出最终结果

## 4. 兼容性与风险

| 项 | 评估 |
|----|------|
| deploy.sh | 非 TTY → silent，行为不变；且不再每次部署白跑 3 次 `docker x25519`（更快） |
| 无 docker 的 silent fresh | 历史会写不匹配占位密钥对并继续；现为明确报错退出（该项目本身依赖 docker，视为合理） |
| 线上 sg `.env` | 全量已配置 → silent 逐字节保留（T2 实测）；唯一动作是按需重渲染 stream（历史行为） |
| xray/init_uuid.sh | 保留不动；`.env` 现在自包含，其空值兜底成为死代码（防御层） |
| REALITY 公私钥均存在但不匹配 | silent 不检测不修复（历史一致）；向导 `-i` 中 `r` 重新生成即可修复 |

## 5. 测试规格（本地矩阵，49 项全过）

测试脚本（临时）：`bash /tmp/test_gen_env.sh <path-to-gen_env.sh>`，全部在 bj01 执行：

| 用例 | 场景 | 关键断言 |
|------|------|---------|
| T1 | silent fresh | `.env` 生成；REALITY 密钥对 `x25519 -i` 验证匹配；`_9000/_9001` = 主 UUID；默认 nginx 入口；新增报告 |
| T2 | silent merge 全量 | 与原件逐字节一致；无新增报告；无 docker 白跑 |
| T2b | silent 部分缺失 | 缺 `Ali_Secret`/`SHORT_IDS` 被补默认；其余行保留；密钥对不扰动 |
| T2c | silent 修复：删公钥 | 由私钥推导补齐且匹配；私钥不扰动 |
| T2d | silent 修复：删私钥 | 重新生成成对密钥；孤儿公钥被覆盖 |
| T3 | wizard fresh（pty） | 全默认回车 + 域名；UUID 跟随主；REALITY 匹配；CA=1；摘要展示 |
| T4 | wizard fresh `--advanced` | 根目录覆盖级联到子路径 |
| T5 | update 全跳过 | `.env` 逐字节不变；入口只读提示 |
| T6 | update 编辑 | Ali_Key/DOMAIN_LIST 更新；`9001` 独立生成；仅 3 处 diff；CA 语义不变 |
| T7 | 非 TTY + `-i` | 警告 + 静默；`.env` 不扰动 |
| T8 | update 取消 | `n` 放弃，`.env` 不变 |
| T9 | wizard 选 haproxy | COMPOSE_FILE 含 haproxy；NF 被询问；自定义主 UUID 生效 |

实现期额外修复（测试暴露）：`xray x25519` 三行输出解析（`Password (PublicKey):`）、
管道场景解析函数双模式（stdin/`$1`）、pty 下 docker 输出 `\r` 剥离、
`prompt_*` 展示 echo 污染 `$(...)` 捕获（改 stderr）、update 模式 CA 选择写回映射（2→0）。

## 6. 实施清单

- [x] gen_env.sh 函数化重写（三模式 + CLI）
- [x] Bug 1/2 修复 + x25519 输出解析修复 + silent REALITY 修复
- [x] 本地测试矩阵 49 项（T1–T9）
- [x] README-005（本文）+ 005_worklog.md
- [ ] sg 生产验证：下次 deploy 时观察 silent 输出（预期与历史一致）+ 手动跑一次 `./gen_env.sh -i` 冒烟
