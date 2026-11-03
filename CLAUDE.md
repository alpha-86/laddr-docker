# CLAUDE.md - laddr-docker Project Guide

## Project Overview

**laddr-docker** is a sophisticated Docker-based proxy and load balancing infrastructure that combines multiple technologies to create a high-performance, SNI-aware reverse proxy system with SSL/TLS termination and certificate management.

### Key Features
- **SNI-based intelligent routing** using Nginx stream (default entry) or HAProxy (optional, `docker-compose-haproxy.yml`), both with regex pattern matching
- **Multi-protocol proxy support** via Xray (VLESS with XTLS-RPRX-Vision and XHTTP-REALITY)
- **Automated SSL/TLS certificate management** with ACME.sh
- **Centralized logging** with rsyslog integration
- **Container orchestration** with Docker Compose
- **Automated deployment and testing** framework

## Architecture Overview

```
Internet Traffic (Port 443)
         ↓
    ┌─ Nginx stream (default entry: ssl_preread SNI routing)
    └─ HAProxy (optional entry: docker-compose-haproxy.yml)
    ├─ SNI Inspection & Regex Matching
    ├─ Proxy Protocol (Nginx v1 / HAProxy v2, preserves client IP)
    ↓
    ├─→ Xray Backend (18910) - XTLS-RPRX-Vision
    ├─→ Xray XHTTP Backend (18911) - XHTTP-REALITY
    ├─→ Netflix Backend (NF_XTLS)
    └─→ Nginx Backend (8443) - Default/HTTPS
         ├─ SSL/TLS Termination
         ├─ Static Content Serving
         └─ PHP-FPM Support

Certificates (ACME.sh)
    └─ Automated provisioning & renewal
    └─ Multi-DNS provider support
    └─ Deployed to Nginx via Docker hooks

Logging (Centralized)
    ├─ HAProxy → rsyslog → log/haproxy_access.log (仅 HAProxy 模式)
    ├─ Nginx stream → log/nginx_stream.log (仅 Nginx 入口模式)
    ├─ Nginx → log/nginx_access.log
    └─ Xray → log/xray_access.log
```

## Core Services

### 1. HAProxy (Load Balancer & SNI Router) — 可选入口
- **Status**: **Optional entry**, defined in `docker-compose-haproxy.yml` (not in default COMPOSE_FILE). The default 443 entry is **Nginx stream** (`nginx/conf/tcp_stream_params` + `conf.d/xray.stream` rendered by `scripts/render_stream.sh`). Switch online with `scripts/ngx_haproxy_switch.sh nginx|haproxy|status` (idempotent, auto-rollback; see `docs/README-003-nginx-haproxy-switch.md`)
- **Role**: Alternative entry point for incoming HTTPS traffic on port 443
- **Key Features**:
  - SNI-based intelligent routing using regex maps
  - TCP load balancing with proxy protocol v2 support
  - Statistics dashboard on port 8404
  - Real-time logging with rsyslog integration

**Routing Rules** (from `haproxy/maps/sni_routing.map`):
- Subdomains with prefixes `x|xyz|api|dt|ai` → Xray backend (port 18910)
- Subdomains with prefixes `web|app|cdn` → Xray XHTTP backend (port 18911)
- Subdomains with prefixes `nf|netflix|nfx|nfv` → Netflix/NF XTLS backend
- Default → Nginx backend (port 8443)

### 2. Nginx (Web Server & SSL Proxy)
- **Role**: **Default 443 entry** (stream `ssl_preread` SNI routing) + HTTP/HTTPS server and reverse proxy
- **Key Features**:
  - Stream 443 entry: SNI regex routing to 4 backends (map in rendered `conf.d/xray.stream`), PROXY Protocol v1 to upstreams, route log `log/nginx_stream.log`
  - Listens on port 8443 (SSL backend) and 80 (HTTP); 443 in stream context
  - Proxy protocol v2 support for preserving client IP
  - PHP-FPM support (fastcgi on port 9000)
  - Waits for SSL certificates before starting
  - Centralized logging integration

### 3. Xray (Advanced Proxy Service)
- **Role**: Advanced proxy with multiple inbound protocols
- **Key Features**:
  - **Port 9000**: VLESS protocol with XTLS-RPRX-Vision flow
  - **Port 9001**: VLESS protocol with XHTTP + REALITY encryption
  - Domain sniffing enabled for better logging
  - Supports proxy protocol v2 for client IP preservation
  - Multiple UUID support (main UUID + per-port UUIDs)
  - REALITY protocol with short IDs and destination spoofing

### 4. ACME.sh (SSL Certificate Management)
- **Role**: Automated SSL/TLS certificate provisioning and renewal
- **Key Features**:
  - Supports multiple DNS providers (Aliyun/Ali, Cloudflare)
  - Wildcard certificate support with intelligent domain processing
  - Automatic deployment to Nginx via Docker hooks
  - Let's Encrypt integration

## Project Structure

```
/laddr-docker/
├── docker-compose.yml              # Main service definitions (nginx default entry)
├── docker-compose-xray.yml         # Xray-specific service definition
├── docker-compose-haproxy.yml      # Optional HAProxy entry (enabled via COMPOSE_FILE)
├── gen_env.sh                      # Environment setup (creates dirs + generates .env + renders stream)
├── .env                            # Environment configuration (generated)
├── .deployment-config              # Deployment server configuration (local only, gitignored)
│
├── haproxy/                        # HAProxy configuration
│   ├── haproxy.cfg.tpl            # HAProxy config template
│   ├── entrypoint.sh              # HAProxy startup script
│   └── maps/
│       └── sni_routing.map        # SNI-based routing rules
│
├── nginx/                          # Nginx configuration
│   ├── conf/
│   │   ├── nginx.conf             # Main Nginx config (includes tcp_stream_params)
│   │   ├── server_params          # SSL/proxy protocol settings (ssl_certificate = default_full.pem)
│   │   ├── tcp_stream_params      # stream{} skeleton: log_format + include conf.d/*.stream
│   │   └── conf.d/
│   │       ├── default.conf       # HTTP server block (80)
│   │       ├── xray.stream.ngx    # Nginx-entry 443 SNI routing template (rendered)
│   │       ├── xray.stream.haproxy# HAProxy-entry stub (map-only, no 443 listener)
│   │       └── xray.stream        # ACTIVE stream file (rendered by render_stream.sh, gitignored)
│   ├── script/
│   │   └── reload.sh              # Certificate reload script
│   └── entrypoint.sh              # Nginx startup script (waits for certs)
│
├── xray/                           # Xray proxy configuration
│   ├── etc/
│   │   ├── config.json.tpl        # Main Xray config template (xhttp acceptProxyProtocol)
│   │   ├── config.json.tpl.client # Client config variant
│   │   ├── config.json.tpl.dns    # DNS config variant
│   │   └── config.json.tpl.nf     # Netflix config variant
│   └── init_uuid.sh               # UUID generation & config templating
│
├── acme/                           # SSL certificate management
│   └── ssl.sh                     # ACME.sh orchestration script
│
├── html/                           # Static web content
│
├── scripts/                        # Deployment, switching and testing
│   ├── deploy.sh                  # Remote deployment (mode-aware, legacy migration path)
│   ├── render_stream.sh           # Render active xray.stream by entry mode
│   ├── ngx_haproxy_switch.sh      # Online entry switch nginx|haproxy|status (idempotent, auto-rollback)
│   ├── gen_xray_client_cfg.sh     # Client config generator (vision|xhttp)
│   └── test.sh                    # Testing framework (cases 1-8, mode-aware)
│
├── docs/                           # Design docs & worklog
│   ├── README-003-nginx-haproxy-switch.md  # 双入口设计规格（唯一规格来源）
│   └── 003_worklog.md                      # 003 开发/实测进展与交接清单
│
└── .claude/                        # Claude Code configuration
    └── settings.local.json        # Claude permissions and settings
```
## Claude Code Integration

### Network Configuration

#### Proxy Settings for Web Access
开发机（bj01）访问境外网络需要走本地代理（bj01 上常驻 xray 客户端容器提供）：

```bash
export http_proxy=http://127.0.0.1:1087
export https_proxy=http://127.0.0.1:1087
export ALL_PROXY=socks5://127.0.0.1:1080
```

**CRITICAL REMINDER**:
- **NEVER use WebSearch tool directly** - It will fail without proper proxy configuration
- **For WebFetch operations** - Set proxy environment variables first using Bash tool
- **Environment Variables Location** - .env file is on the SERVER, not local machine. Use SSH to access server files
- **注意**：旧文档提到的 `.claude/agents/google-search.sh` 已不存在（随旧开发机移除）；需要搜索时用 `curl` 走上述代理或借助其他工具
- **bj01 本地 DNS 污染境外域名**（实测 `www.google.com → 2001::1`）：涉及境外域名解析的场景必须让远端解析（如 `--socks5-hostname`），不要信任本机解析结果

### Configuration Files

#### `.claude/settings.local.json`
Contains permissions for Claude Code to interact with the project:

```json
{
  "permissions": {
    "allow": [
      "Bash(git config:*)",
      "Bash(./scripts/deploy.sh:*)",
      "Bash(./scripts/test.sh:*)",
      "Bash(timeout 180 ./scripts/test.sh:*)",
      "Bash(ssh:*)",
      "WebSearch",
      "WebFetch(domain:xtls.github.io)"
    ]
  }
}
```

**Key Permissions**:
- **Deployment**: Execute deployment scripts locally and remotely
- **Testing**: Run comprehensive test suites with timeout protection
- **SSH Access**: Connect to remote servers for deployment and monitoring
- **Git Operations**: Version control management
- **Web Resources**: Fetch documentation from XTLS project

> 注：旧版 `.claude/agents/deployment-tester.md` 自定义 agent 已随仓库清理移除，测试直接执行 `./scripts/test.sh --case <n>` 即可。

## Deployment Workflow

### 1. Deployment Process (via `scripts/deploy.sh`)
1. **SSH Connection Validation** to target server
2. **Remote Directory Creation**
3. **File Synchronization** via rsync (excludes: .git, .env, logs, certs, acme data)
4. **Environment Generation** (`.env` file) on remote server
5. **Docker Compose Restart** (stop/start cycle)
6. **Container Health Verification**
7. **Status Reporting** and troubleshooting suggestions

### 2. Configuration Management
- **Environment Variables**: Generated dynamically via `gen_env.sh`
- **Template Processing**: Configuration files use template substitution
- **Certificate Management**: Automated provisioning and deployment
- **Service Dependencies**: Proper startup ordering with health checks
- **副作用提示**: deploy.sh 每次部署都会在远端执行 `gen_env.sh`，从而按 `.env` 当前模式**重新渲染** `nginx/conf/conf.d/xray.stream` 激活文件——可顺带修复激活文件的磁盘漂移，但不要依赖它做模式切换（切换用 `ngx_haproxy_switch.sh`）

## Testing Framework

### Comprehensive Test Suite (`scripts/test.sh`)

The testing framework provides 8 distinct test cases. All cases auto-detect the remote entry mode (nginx default / haproxy optional, via remote `.env` COMPOSE_FILE) and assert route logs accordingly — nginx mode reads `log/nginx_stream.log` (`sni:`/`backend:$tcp_backend` fields), haproxy mode reads `log/haproxy_access.log` (`sni:`/`%b`). All route-log assertions use the **byte-offset scheme** (only log lines appended after the request counts; timestamps are auxiliary).

#### Test Case 1: Container Health Check
- Verifies all required containers are running
- Checks (by entry mode): `nginx`, `acme`, `xray` (+ `haproxy` in haproxy mode)

#### Test Case 2: Port Listening Check
- Validates service port bindings
- 443 owner process must match entry mode (nginx / haproxy); **无 sudo 时属主不可见，退化为"443 监听 + TLS 握手"探测并记 WARN（不判失败）**——sg 的 work 用户无免密 sudo
- Nginx: 80 (HTTP), 8443 (HTTPS backend)
- Xray: 18910 (Vision), 18911 (XHTTP)

#### Test Case 3: Certificate Validation
- Checks SSL certificate files exist
- Extracts domains from certificates (SAN + CN)
- Prepares domain lists for routing tests

#### Test Case 4: SNI Routing to Nginx
- Tests default routing path through the active entry
- Creates test files and validates HTTP responses
- Verifies entry routing log (new-request offset assertion)

#### Test Case 5: Xray Vision Proxy Test
- **Advanced Proxy Testing**: Creates Xray client on remote host
- **SOCKS5 Proxy Chain**: Tests complete proxy functionality
- **External Connectivity**: Validates Google access via proxy
- **Log Chain Analysis**: Traces requests through entire infrastructure

#### Test Case 6: Xray XHTTP Proxy Test
- **REALITY Protocol Testing**: Tests XHTTP with REALITY encryption
- **Advanced Obfuscation**: Validates sophisticated proxy concealment
- **Multi-Protocol Support**: Tests alternative proxy protocols

#### Test Case 7: NF Routing + PP Compatibility
- Constructs `nf.*` SNI; asserts route to `nf_xtls` (`backend:nf_xtls` / `nf_xtls_backend`) via offset polling after connection close
- **PP assertion**: openssl TLS handshake must succeed (hard requirement); on failure reports "NF 握手失败，可能为 PP 版本或上游异常" — PP v1 incompatibility is only concluded when v2 (haproxy) succeeds and v1 (nginx) fails against the same upstream

#### Test Case 8: External Real-Client IP Verification (acceptance gate)
- Runs an Xray client from an **external machine** through the server public IP (default: runs directly on the machine executing test.sh; `--dep user@host` for a jump host)
- Cross-checks: entry log's observed source IP == `xray_access.log` `from` IP (PP-restored), must be equal and non-loopback
- Server-local cases 5/6 cannot substitute (source is always 127.0.0.1); mandatory for both entry modes
- **域名前置**：测试域名必须公网可解析（证书覆盖 ≠ DNS 有记录，部分子域无通配符解析）；选型已内置"执行机可解析"过滤，前置不满足判 FAIL 明示
- **远端解析**：curl 必须 `--socks5-hostname`（域名交服务端解析）——bj01 本地 DNS 污染境外域名，本地解析会把污染 IP 发给代理导致归因失配

### Intelligent Domain Selection
The test framework automatically:
- **Extracts domains** from SSL certificates (SAN + CN)
- **Matches routing rules** to select appropriate test domains
- **Constructs dynamic domains** when certificates use wildcards
- **Validates certificate coverage** for generated test domains

### Test Case Execution Examples

```bash
# Run all tests
./scripts/test.sh

# Run specific test cases
./scripts/test.sh --case 1          # Container health
./scripts/test.sh --case nginx      # Nginx routing test
./scripts/test.sh --case vision     # Xray Vision proxy test
./scripts/test.sh --case xhttp      # Xray XHTTP proxy test
```

## Environment Configuration

### Key Environment Variables (from `gen_env.sh`)

#### Docker Compose Configuration
```bash
COMPOSE_FILE=docker-compose.yml:docker-compose-xray.yml
COMPOSE_PATH_SEPARATOR=:
```

#### Service Paths
```bash
DOCKER_BOX_HOME=/path/to/project
NGINX_PATH=${DOCKER_BOX_HOME}/nginx
HAPROXY_PATH=${DOCKER_BOX_HOME}/haproxy
XRAY_PATH=${DOCKER_BOX_HOME}/xray
ACME_SH_PATH=${DOCKER_BOX_HOME}/acme
```

#### SSL/ACME Configuration
```bash
Ali_Key=your_aliyun_key
Ali_Secret=your_aliyun_secret
CF_Key=your_cloudflare_key
CF_Email=your_cloudflare_email
DOMAIN_LIST="*.example.com,example.com"
CA_LETSENCRYPT=https://acme-v02.api.letsencrypt.org/directory
```

#### Xray Configuration
```bash
XRAY_UUID=generated_uuid
XRAY_UUID_9000=port_specific_uuid
XRAY_UUID_9001=port_specific_uuid
```

#### REALITY Protocol
```bash
REALITY_PRIVATE_KEY=x25519_private_key
REALITY_PUBLIC_KEY=x25519_public_key
REALITY_SHORT_IDS=["short_id_array"]
REALITY_DEST=www.fifa.com
```

## Operational Procedures

### Deployment Commands with Claude Code

#### 1. Basic Deployment
```bash
# Deploy to remote server
./scripts/deploy.sh
```

#### 2. Testing After Deployment
```bash
# Run comprehensive tests
./scripts/test.sh

# Test specific functionality
./scripts/test.sh --case vision
./scripts/test.sh --case xhttp
```

#### 3. 定向测试命令
```bash
./scripts/test.sh --case 1       # 容器健康
./scripts/test.sh --case vision  # Xray Vision 代理
./scripts/test.sh --case xhttp   # Xray XHTTP 代理
./scripts/test.sh --case 8       # 外部真实客户端 IP（验收门禁）
```

#### 4. Entry Mode Switching (on the server)
```bash
# 查看当前模式与收敛状态
ssh work@sg.cqcy.fun "cd /home/work/laddr-docker && scripts/ngx_haproxy_switch.sh status"

# 在线切换（幂等、半完成自修复、失败自动回滚；443 秒级中断）
ssh work@sg.cqcy.fun "cd /home/work/laddr-docker && scripts/ngx_haproxy_switch.sh haproxy"
ssh work@sg.cqcy.fun "cd /home/work/laddr-docker && scripts/ngx_haproxy_switch.sh nginx"
```
退出码：`0` 成功/已是目标；`1` 渲染/nginx -t 前置失败（零影响）；`2` 回滚后仍不通过（需人工）；`3` 失败但已自动回滚。详见 README.md「入口模式切换」与设计文档 docs/README-003。

### Monitoring and Troubleshooting

#### Log Locations
```bash
# Centralized logs directory
${DOCKER_BOX_HOME}/log/
├── haproxy_access.log    # HAProxy routing logs (仅 HAProxy 模式)
├── haproxy_error.log     # HAProxy error logs
├── nginx_stream.log      # Nginx stream 443 路由日志 (仅 Nginx 入口模式)
├── nginx_access.log      # Nginx request logs
├── nginx_error.log       # Nginx error logs
└── xray_access.log       # Xray proxy logs
```

#### Container Status Commands
```bash
# Check container health
docker ps

# View container logs
docker logs haproxy
docker logs nginx
docker logs xray
docker logs acme

# Check service ports
ss -tlnp | grep -E ':(80|443|8443|18910|18911)'
```

#### Certificate Management
```bash
# Check certificate validity (注意：服务端出示的是 fullchain default_full.pem)
docker exec nginx openssl x509 -in /etc/nginx/cert/default_full.pem -noout -text

# Manual certificate renewal
docker exec acme acme.sh --renew-all
```

> **SSL 关键约束**：服务端必须出示**完整证书链**——nginx `ssl_certificate` 与 xray `certificateFile` 都用 `default_full.pem`（acme.sh docker hook 部署；`default_cert.pem` 仅为 leaf）。**禁止 `allowInsecure`**（用户硬性要求；xray 26.x 已移除该特性，配置含它直接拒载），客户端校验依赖完整链。

#### Switch CA for Existing Certificates（一次性迁移）
```bash
# 强制把存量证书切换到指定 CA（与证书当前由哪家签发无关）：
# --renew --force --server <CA> 重签 → docker deploy-hook 重新部署（reload nginx + 重启 xray）
docker exec acme sh /force_switch_ca.sh letsencrypt
docker exec acme sh /force_switch_ca.sh zerossl   # ZeroSSL 需容器环境有 ZEROSSL_EAB_KID / ZEROSSL_EAB_HMAC_KEY
```
脚本位于 `acme/force_switch_ca.sh`（容器内 `/force_switch_ca.sh`）。注意 `--force` 重签计入 CA 重复证书配额（LE 同名同 SAN 每周 5 张），日常续期勿用；初始化逻辑（ssl.sh）不受影响——仍尊重环境历史（CA 默认仅在账号全新时设为 LE）。规格见 `docs/README-004-acme-ca-switch.md`。

## Security Considerations

### 1. Proxy Protocol Configuration
- **Client IP Preservation**: All backends use proxy protocol v2
- **Source Validation**: HAProxy validates proxy protocol headers
- **Network Isolation**: Services communicate via Docker networks

### 2. SSL/TLS Security
- **Modern Ciphers**: Strong cipher suites and protocols
- **Certificate Validation**: Automated certificate lifecycle management
- **HSTS Headers**: HTTP Strict Transport Security implementation

### 3. REALITY Protocol Security
- **Traffic Obfuscation**: Advanced proxy traffic concealment
- **Key Management**: X25519 key pair generation and rotation
- **Destination Spoofing**: Configurable target destinations

### 4. Access Control
- **SSH Key Authentication**: Deployment uses key-based auth
- **Container Isolation**: Services run in isolated containers
- **Log Security**: Centralized logging with proper permissions

## Performance Optimization

### 1. HAProxy Optimization
- **Connection Pooling**: Efficient backend connection management
- **Load Balancing**: Intelligent traffic distribution
- **Health Checks**: Automatic backend health monitoring

### 2. Nginx Optimization
- **Worker Processes**: Optimized for available CPU cores
- **Connection Limits**: Tuned for expected traffic patterns
- **Caching Strategy**: Static content caching configuration

### 3. Xray Performance
- **Protocol Efficiency**: XTLS-RPRX-Vision for reduced overhead
- **Connection Reuse**: Efficient connection pooling
- **Memory Management**: Optimized for high throughput

## Troubleshooting Guide

### Common Issues and Solutions

#### 1. Certificate Problems
**Symptoms**: SSL errors, certificate warnings
**Solutions**:
```bash
# Check certificate status
./scripts/test.sh --case cert

# Manual certificate renewal
docker exec acme acme.sh --renew-all

# Restart Nginx to reload certificates
docker restart nginx
```

#### 2. Routing Issues
**Symptoms**: Traffic not reaching expected backends
**Solutions**:
```bash
# Test routing rules
./scripts/test.sh --case nginx

# Check HAProxy configuration
docker exec haproxy cat /usr/local/etc/haproxy/haproxy.cfg

# Verify SNI routing maps
docker exec haproxy cat /usr/local/etc/haproxy/maps/sni_routing.map
```

#### 3. Proxy Connectivity Issues
**Symptoms**: Xray proxy tests failing
**Solutions**:
```bash
# Test Xray functionality
./scripts/test.sh --case vision
./scripts/test.sh --case xhttp

# Check Xray configuration
docker exec xray cat /etc/xray/config.json

# Verify UUID configuration
grep XRAY_UUID .env
```

#### 4. Container Startup Issues
**Symptoms**: Containers failing to start or restart
**Solutions**:
```bash
# Check container health
./scripts/test.sh --case container

# Review container logs
docker logs --tail 50 [container_name]

# Restart services
docker-compose down && docker-compose up -d
```

## Development Workflow

### 1. Local Development
1. **Clone Repository**: `git clone [repository]`
2. **Initialize Environment**: `./gen_env.sh` (creates directories + generates .env)
3. **Start Services**: `docker-compose up -d`

### 2. Testing Changes
1. **Run Local Tests**: `./scripts/test.sh`
2. **Deploy to Staging**: `./scripts/deploy.sh`
3. **Run Remote Tests**: `./scripts/test.sh`
4. **Validate Functionality**: All test cases should pass

### 3. Production Deployment
1. **Code Review**: Ensure changes are reviewed
2. **Staging Validation**: All tests pass in staging
3. **Production Deploy**: `./scripts/deploy.sh`
4. **Production Testing**: `./scripts/test.sh`
5. **Monitoring**: Watch logs and metrics

## Claude Code Best Practices

### 1. 定向测试与部署
- **Focused Commands**: 直接执行 `./scripts/test.sh --case <n>`（见上文章节编号）；部署用 `./scripts/deploy.sh`
- **Clear Intent**: 明确说明要测试还是部署（部署会重启远端服务、443 秒级中断）
- **Error Handling**: 脚本输出全量展示，按 FAIL 行的下一段 INFO 定位（测试脚本会把客户端启动日志、错误日志路径一并打印）

### 2. Permission Management
- **Minimal Permissions**: Only grant necessary access
- **SSH Security**: Use key-based authentication for remote access
- **Script Validation**: Review scripts before granting execution permissions

### 3. Automation Guidelines
- **Test Before Deploy**: Always run tests before deployment
- **Incremental Changes**: Deploy small, focused changes
- **Rollback Plan**: Keep previous configurations for quick rollback

## Conclusion

The laddr-docker project provides a sophisticated, production-ready proxy infrastructure with comprehensive automation and testing capabilities. The Claude Code integration enhances operational efficiency through streamlined deployment and testing workflows.

Key strengths:
- **Modular Architecture**: Clean separation of concerns
- **Comprehensive Testing**: Detailed validation of all components
- **Automated Operations**: Streamlined deployment and management
- **Security Focus**: Advanced protocols and proper isolation
- **Operational Excellence**: Detailed logging and monitoring

This infrastructure is suitable for high-performance proxy scenarios requiring advanced routing, traffic obfuscation, and reliable certificate management.