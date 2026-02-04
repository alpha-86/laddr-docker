# laddr-docker


## 架构概览

```
Internet (Port 443)
    ↓
HAProxy (SNI Router)
    ├─→ Vision (18910)    - XTLS-RPRX-Vision
    ├─→ XHTTP (18911)     - XHTTP + REALITY
    └─→ Nginx (8443)      - HTTPS/SSL Termination

ACME.sh → 自动证书管理
rsyslog → 集中式日志收集
```

## 快速开始

### 1. 初始化项目

```bash
# 克隆项目
git clone <repository-url>
cd laddr-docker

# 生成环境配置和初始化目录
./gen_env.sh
```

这将创建 `.env` 文件和必要的目录结构。

### 2. 配置环境变量

编辑生成的 `.env` 文件，配置以下关键变量：

**SSL 证书配置**

```bash
# 阿里云 DNS API 凭证（如果使用阿里云 DNS）
Ali_Key=your_aliyun_access_key
Ali_Secret=your_aliyun_secret_key

# Cloudflare DNS API 凭证（如果使用 Cloudflare DNS）
CF_Key=your_cloudflare_api_key
CF_Email=your_cloudflare_email

# 域名列表（格式：dns_provider:domain1;domain2 dns_provider:domain3;domain4）
# dns_ali = 阿里云 DNS
# dns_cf = Cloudflare DNS
# 示例1：单个 DNS 提供商管理多个域名
DOMAIN_LIST="dns_ali:example.com;example2.com"

# 示例2：多个 DNS 提供商管理不同域名
DOMAIN_LIST="dns_ali:example.com;example2.com dns_cf:example3.com"

# 示例3：单个域名
DOMAIN_LIST="dns_ali:example.com"

# ACME 邮箱（用于证书通知）
ACME_SH_EMAIL=your_email@example.com
```

**部署配置**

编辑 `.deployment-config` 文件：

```bash
DEPLOYMENT_SERVER=user@your-server.com
DEPLOYMENT_PATH=/home/user/
```

### 3. 部署和测试

```bash

# 运行完整测试套件
./scripts/test.sh

# 运行特定测试用例
./scripts/test.sh --case 1          # 容器健康检查
./scripts/test.sh --case nginx      # Nginx 路由测试
./scripts/test.sh --case vision     # Xray Vision 代理测试
./scripts/test.sh --case xhttp      # Xray XHTTP 代理测试
```

**测试用例说明**

| 测试用例 | 说明 | 命令 |
|---------|------|------|
| Case 1 | 容器健康检查 | `--case 1` 或 `--case container` |
| Case 2 | 端口监听检查 | `--case 2` 或 `--case port` |
| Case 3 | SSL 证书验证 | `--case 3` 或 `--case cert` |
| Case 4 | SNI 路由到 Nginx | `--case 4` 或 `--case nginx` |
| Case 5 | Vision 代理测试 | `--case 5` 或 `--case vision` |
| Case 6 | XHTTP 代理测试 | `--case 6` 或 `--case xhttp` |

## 生成客户端配置

项目提供了客户端配置生成脚本，支持生成二维码和配置链接。

```bash
# 生成 Vision 协议配置（自动选择域名）
./scripts/gen_xray_client_cfg.sh vision

# 生成 XHTTP 协议配置（自动选择域名）
./scripts/gen_xray_client_cfg.sh xhttp

# 指定域名生成配置
./scripts/gen_xray_client_cfg.sh vision x.example.com
./scripts/gen_xray_client_cfg.sh xhttp web.example.com
```

## 许可证

本项目仅供学习和研究使用。

