# CLAUDE.md - laddr-docker Project Guide

## Project Overview

**laddr-docker** is a sophisticated Docker-based proxy and load balancing infrastructure that combines multiple technologies to create a high-performance, SNI-aware reverse proxy system with SSL/TLS termination and certificate management.

### Key Features
- **SNI-based intelligent routing** using HAProxy with regex pattern matching
- **Multi-protocol proxy support** via Xray (VLESS with XTLS-RPRX-Vision and XHTTP-REALITY)
- **Automated SSL/TLS certificate management** with ACME.sh
- **Centralized logging** with rsyslog integration
- **Container orchestration** with Docker Compose
- **Automated deployment and testing** framework

## Architecture Overview

```
Internet Traffic (Port 443)
         ↓
    HAProxy (SNI Router)
    ├─ SNI Inspection & Regex Matching
    ├─ Proxy Protocol v2 (preserves client IP)
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
    ├─ HAProxy → rsyslog → log/haproxy_access.log
    ├─ Nginx → log/nginx_access.log
    └─ Xray → log/xray_access.log
```

## Core Services

### 1. HAProxy (Load Balancer & SNI Router)
- **Role**: Main entry point for incoming HTTPS traffic on port 443
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
- **Role**: Default HTTP/HTTPS server and reverse proxy
- **Key Features**:
  - Listens on port 8443 with SSL/TLS support
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
├── docker-compose.yml              # Main service definitions
├── docker-compose-xray.yml         # Xray-specific service definition
├── gen_env.sh                      # Environment variable generator
├── init.sh                         # Directory initialization script
├── .env                            # Environment configuration (generated)
├── .deployment-config              # Deployment server configuration
│
├── haproxy/                        # HAProxy configuration
│   ├── haproxy.cfg.tpl            # HAProxy config template
│   ├── entrypoint.sh              # HAProxy startup script
│   └── maps/
│       └── sni_routing.map        # SNI-based routing rules
│
├── nginx/                          # Nginx configuration
│   ├── conf/
│   │   ├── nginx.conf             # Main Nginx config
│   │   ├── server_params          # SSL/proxy protocol settings
│   │   └── conf.d/
│   │       └── default.conf       # Server block config
│   ├── script/
│   │   └── reload.sh              # Certificate reload script
│   └── entrypoint.sh              # Nginx startup script (waits for certs)
│
├── xray/                           # Xray proxy configuration
│   ├── etc/
│   │   ├── config.json.tpl        # Main Xray config template
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
├── scripts/                        # Deployment and testing
│   ├── deploy.sh                  # Remote deployment script
│   └── test.sh                    # Testing framework
│
└── .claude/                        # Claude Code configuration
    ├── settings.local.json        # Claude permissions and settings
    └── agents/
        └── deployment-tester.md   # Deployment testing agent
```

## Claude Code Integration

### Configuration Files

#### `.claude/settings.local.json`
Contains permissions for Claude Code to interact with the project:

```json
{
  "permissions": {
    "allow": [
      "Bash(git config:*)",
      "Bash(./scripts/deploy.sh:*)",
      "Bash(/Users/chenchao/Documents/code/laddr-docker/scripts/deploy.sh)",
      "Bash(ssh work@sg.cqcy.fun \"cd /home/work/laddr-docker && docker ps\")",
      "Bash(ssh:*)",
      "WebSearch",
      "Bash(./scripts/test.sh:*)",
      "Bash(gtimeout 180 ./scripts/test.sh:*)",
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

#### `.claude/agents/deployment-tester.md`
Defines a specialized agent for deployment testing:

```yaml
---
name: deployment-tester
description: "Simple test runner for laddr-docker project. Runs test.sh locally first. Only deploys when explicitly requested by user."
model: inherit
color: red
---
```

**Agent Capabilities**:
- **Focused Testing**: Runs specific test cases (e.g., "测试case5.1" → `./scripts/test.sh --case 5.1`)
- **Controlled Deployment**: Only deploys when explicitly requested by user
- **Simple Workflow**: Execute scripts and show all output without complex decision-making

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

## Testing Framework

### Comprehensive Test Suite (`scripts/test.sh`)

The testing framework provides 6 distinct test cases:

#### Test Case 1: Container Health Check
- Verifies all required containers are running
- Checks: `haproxy`, `nginx`, `acme`, `xray`

#### Test Case 2: Port Listening Check
- Validates service port bindings
- HAProxy: 443 (HTTPS entry point)
- Nginx: 80 (HTTP), 8443 (HTTPS backend)
- Xray: 18910 (Vision), 18911 (XHTTP)

#### Test Case 3: Certificate Validation
- Checks SSL certificate files exist
- Extracts domains from certificates (SAN + CN)
- Prepares domain lists for routing tests

#### Test Case 4: SNI Routing to Nginx
- Tests default routing path through HAProxy
- Creates test files and validates HTTP responses
- Verifies HAProxy and Nginx logging integration

#### Test Case 5: Xray Vision Proxy Test
- **Advanced Proxy Testing**: Creates Xray client on remote host
- **SOCKS5 Proxy Chain**: Tests complete proxy functionality
- **External Connectivity**: Validates Google access via proxy
- **Log Chain Analysis**: Traces requests through entire infrastructure

#### Test Case 6: Xray XHTTP Proxy Test
- **REALITY Protocol Testing**: Tests XHTTP with REALITY encryption
- **Advanced Obfuscation**: Validates sophisticated proxy concealment
- **Multi-Protocol Support**: Tests alternative proxy protocols

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
REALITY_DEST=destination_spoofing_target
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

#### 3. Using Claude Code Agents
```bash
# Activate the deployment-tester agent
# Then use commands like:
测试case5.1    # Runs specific test case
deploy         # Triggers deployment + testing
```

### Monitoring and Troubleshooting

#### Log Locations
```bash
# Centralized logs directory
${DOCKER_BOX_HOME}/log/
├── haproxy_access.log    # HAProxy routing logs
├── haproxy_error.log     # HAProxy error logs
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
# Check certificate validity
docker exec nginx openssl x509 -in /etc/nginx/cert/default_cert.pem -noout -text

# Manual certificate renewal
docker exec acme acme.sh --renew-all
```

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
2. **Generate Environment**: `./gen_env.sh`
3. **Initialize Directories**: `./init.sh`
4. **Start Services**: `docker-compose up -d`

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

### 1. Using the Deployment Agent
- **Focused Commands**: Use specific test case commands
- **Clear Intent**: State whether you want testing or deployment
- **Error Handling**: Agent will show all script output for debugging

### 2. Permission Management
- **Minimal Permissions**: Only grant necessary access
- **SSH Security**: Use key-based authentication for remote access
- **Script Validation**: Review scripts before granting execution permissions

### 3. Automation Guidelines
- **Test Before Deploy**: Always run tests before deployment
- **Incremental Changes**: Deploy small, focused changes
- **Rollback Plan**: Keep previous configurations for quick rollback

## Conclusion

The laddr-docker project provides a sophisticated, production-ready proxy infrastructure with comprehensive automation and testing capabilities. The Claude Code integration enhances operational efficiency through intelligent agents and streamlined deployment workflows.

Key strengths:
- **Modular Architecture**: Clean separation of concerns
- **Comprehensive Testing**: Detailed validation of all components
- **Automated Operations**: Streamlined deployment and management
- **Security Focus**: Advanced protocols and proper isolation
- **Operational Excellence**: Detailed logging and monitoring

This infrastructure is suitable for high-performance proxy scenarios requiring advanced routing, traffic obfuscation, and reliable certificate management.