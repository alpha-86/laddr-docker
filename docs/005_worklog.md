# 005 开发进展（worklog）

> 关联设计文档：[README-005-update-gen-env.md](README-005-update-gen-env.md)（**唯一的规格来源**，本文不重复其细节，只记录进展与审阅入口）
> 任务：gen_env.sh 交互化重写（三模式向导）+ fresh-init 两个 bug 修复（REALITY 密钥对不匹配 / 端口 UUID 为空）
> 开发机：bj01（测试全部本地执行）；部署目标 sg.cqcy.fun 仅受影响于 silent 路径（行为不变）
> 本文件随开发滚动更新。

---

## 1. 当前状态（速览）

| 维度 | 状态 |
|---|---|
| 设计（README-005） | ✅ 定稿（4 个决策点用户拍板，见文档 §2） |
| 代码（gen_env.sh 重写） | ✅ 完成（三模式 + 修复，函数化单文件） |
| 本地测试（T1–T9，49 项） | ✅ 全部通过（2026-11-03，bj01）；实现期修复 5 个测试暴露的问题 |
| sg 生产验证 | ⏳ 待下次 deploy 观察 silent 输出 + 手动 `-i` 冒烟（见 §5 待办） |

**核心结论（审阅者必读）**：
silent 路径（deploy.sh 唯一用到的路径）与历史版本**逐字节等价**（已有 `.env` 值零漂移），
交互向导是新增能力不触碰该路径。fresh init 的两个 bug（REALITY 公私钥不匹配、
`_9000/_9001` 为空）已修复，新机器初始化 xhttp 不再必挂。

---

## 2. 变更清单（审阅入口，按文件）

| 文件 | 变更 |
|---|---|
| `gen_env.sh` | 重写：三模式（wizard/silent/update）+ CLI（-i/--advanced/--batch/-h）；Bug1（三次独立 keygen→单次复用）与 Bug2（`_9000/_9001` 空→跟随主）修复；x25519 三行输出解析（`Password (PublicKey):`）；openssl 兜底移除（曾生成不匹配占位对）；silent 部分缺失自动修复（推导公钥/重生成对）；正常 deploy 不再白跑 3 次 `docker x25519`；`trap cleanup EXIT` |
| `docs/README-005-update-gen-env.md` | 新增：设计规格（唯一来源），含背景/决策/设计/兼容性/测试规格 |
| `docs/005_worklog.md` | 本文件 |
| `README.md` / `CLAUDE.md` | 索引与用法说明补充（见 §4 提交） |

未触碰：`xray/init_uuid.sh`（空值兜底成为死代码但保留作防御层）、`scripts/deploy.sh`、
`scripts/render_stream.sh`、全部 compose 与 nginx/haproxy/xray 配置。

## 3. 设计决策记录（2026-11-03，与用户讨论定稿）

| # | 决策点 | 拍板 | 备选（未采纳） |
|---|--------|------|----------------|
| 1 | 触发方式 | 混合：fresh+TTY 自动向导；已有 `.env` 无参静默+提示 `-i`；非 TTY 永远静默 | 全交互 / flag-only |
| 2 | 更新粒度 | 按块编辑（Enter 跳过 / e 进块内逐项） | 逐项确认 / 只问空值 |
| 3 | UUID 策略 | 默认跟随主 UUID（向导可独立生成/自定义） | 三个独立生成 |
| 4 | 入口模式 | 向导中只读展示 + 指路 `ngx_haproxy_switch.sh` | 允许直接改 .env / 联动 switch |

## 4. 实测结果记录（2026-11-03，bj01 本地）

测试驱动：`bash /tmp/test_gen_env.sh <path-to-gen_env.sh>`（临时文件，未入库；场景与断言
对照表见 README-005 §5）。三轮跑测：首轮 35 过 14 挂 → 二轮 45 过 4 挂 → 终轮 **49/49**。

**实现期修复（测试暴露，全部已修）**：

| # | 问题 | 根因 | 修复 |
|---|------|------|------|
| 1 | REALITY 公钥解析为空 | 镜像 xray 输出三行，`Password (PublicKey):` 不被 `^Password:` 锚定匹配；且线上 .env 系手工配置掩盖了此问题 | 解析改 `$NF` + 双模式（stdin/`$1`） |
| 2 | pty 下向导密钥污染 | `script` 伪终端里 docker 输出带 `\r` | 解析统一 `tr -d '\r'` |
| 3 | T2c 推导分支未生效 | 管道里 `docker \| parse_fn` 的数据走 stdin，函数读 `$1`（空） | 解析函数无参时读 stdin |
| 4 | 向导 fresh 的 UUID/密钥值错乱 | `prompt_uuid`/`prompt_reality_pair` 的信息 echo 混进 `$(...)` 捕获 | 展示输出改 stderr |
| 5 | update 模式选 ZeroSSL 写回错误 | 单选值 2 直接写入 `CA_LETSENCRYPT`，语义应为 0 | 写回映射 2→0 |
| 6 | `--advanced` 改根目录后子路径脱节 | 各路径独立默认值 | fresh 向导级联：仍持原默认值的子路径跟随新根 |

**遗留观察（非问题）**：

- silent 报告的"值已变更"在旧 `.env` 缺 `_9000/_9001` 时会新增条目（默认从空变主 UUID），
  仅报告层差异，写入值与历史语义一致（README-005 §3.5）。
- 测试 T3/T4/T8 曾因输入行数错位挂起/误判——`$(...)` 截断尾部换行 + 手数行数不可靠，
  已用 `lines()` 助手（哨兵行）+ 精确计数解决；属测试写法教训，与产品无关。

## 5. 交接清单（待办与验证入口）

1. **sg 生产验证**（下次 deploy 时）：
   - deploy 输出与历史对比：应仅有"目录结构初始化完成"+（无新增/变更时无报告）+
     "已生成 .env"——**不应出现** REALITY 相关行（线上公私钥齐全，不触发修复）；
   - `ssh work@sg.cqcy.fun "cd /home/work/laddr-docker && ./gen_env.sh"`（无参，TTY）
     → 期望：silent 合并 + 末尾提示 `-i`；
   - `ssh -t work@sg.cqcy.fun "cd /home/work/laddr-docker && ./gen_env.sh -i"` 冒烟：
     全 Enter 跳过，`.env` 不变（可先 `cp .env /tmp/.env.bak` 后 diff）。
2. **新机器初始化验证**（如有机会）：fresh 跑向导 → `xray x25519 -i <私钥>` 验证
   公钥匹配 → case 6（xhttp）实测。
3. push 必须用 SSH URL（仓库环境事实，见 003_worklog §6）。

## 6. 提交记录

| 提交 | 内容 |
|------|------|
| 533ec44 | feat(gen_env): 交互化重写（三模式向导）+ fresh-init 两 bug 修复 + 005 文档（5 文件，+1088/-182） |
