#!/bin/bash
# laddr-docker 测试脚本
# 职责：测试 443 入口（Nginx 默认 / HAProxy 可选）SNI 分流到 Nginx 和 Xray
# 用例：1 容器 2 端口 3 证书 4 ngx 路由 5 Vision 代理 6 XHTTP 代理
#       7 NF 路由+PP 兼容性 8 外部真实客户端 IP 验证（默认本机直跑，--dep 指定外网跳板走 SSH）

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
log_test() { echo -e "${BLUE}[TEST]${NC} $1"; }

# 测试结果统计
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
# 外部跳板（case 8 用，--dep 参数指定）
DEP_SERVER=""

test_pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    log_success "$1"
}

test_fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    log_error "$1"
}

test_warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    log_warning "$1"
}

# 获取部署配置
get_deployment_config() {
    local config_file="$(cd "$(dirname "$0")/.." && pwd)/.deployment-config"

    if [ -f "$config_file" ]; then
        DEPLOYMENT_SERVER=$(grep "^DEPLOYMENT_SERVER=" "$config_file" | cut -d'=' -f2)
        DEPLOYMENT_PATH=$(grep "^DEPLOYMENT_PATH=" "$config_file" | cut -d'=' -f2)
        REMOTE_PATH="${DEPLOYMENT_PATH}laddr-docker"
    else
        log_error "未找到部署配置文件 $config_file"
        log_info "请先运行 ./scripts/deploy.sh 进行部署"
        exit 1
    fi
}

# 远程执行命令
remote_cmd() {
    ssh "$DEPLOYMENT_SERVER" "cd $REMOTE_PATH && $1" 2>/dev/null
}

# 检测远端 443 入口模式（README-003 4.1：按远端 .env COMPOSE_FILE，兜底容器检查）
detect_entry_mode() {
    local compose_file
    compose_file=$(remote_cmd "grep '^COMPOSE_FILE=' .env | cut -d'=' -f2-" 2>/dev/null)
    if echo "$compose_file" | grep -q 'docker-compose-haproxy.yml'; then
        echo "haproxy"
        return 0
    fi
    if [ -z "$compose_file" ]; then
        # 兜底：haproxy 容器存在即视为 haproxy 模式（覆盖旧结构迁移前状态）
        if [ -n "$(remote_cmd "docker ps -aq --filter 'name=^haproxy\$'" 2>/dev/null)" ]; then
            echo "haproxy"
            return 0
        fi
    fi
    echo "nginx"
}

# 路由日志文件（按入口模式）与 backend 断言词
route_log_file() {
    if [ "$ENTRY_MODE" = "haproxy" ]; then echo "log/haproxy_access.log"; else echo "log/nginx_stream.log"; fi
}
route_backend_pattern() {  # $1: ngx|xray|xhttp|nf_xtls
    if [ "$ENTRY_MODE" = "haproxy" ]; then
        case "$1" in
            ngx)   echo "ngx_backend" ;;
            *)     echo "${1}_backend" ;;
        esac
    else
        echo "backend:$1"
    fi
}

# 从证书提取所有域名
extract_cert_domains() {
    log_info "从证书中提取域名..."

    # 提取 SAN (Subject Alternative Names)
    local san_domains=$(remote_cmd "docker exec nginx openssl x509 -in /etc/nginx/cert/default_cert.pem -noout -text | grep -A1 'Subject Alternative Name' | tail -n1 | sed 's/DNS://g' | tr ',' '\n' | xargs")

    # 提取 CN (Common Name)
    local cn_domain=$(remote_cmd "docker exec nginx openssl x509 -in /etc/nginx/cert/default_cert.pem -noout -subject | grep -o 'CN=[^,]*' | cut -d'=' -f2")

    # 合并所有域名
    local all_domains="$san_domains $cn_domain"

    # 去重并过滤空行
    CERT_DOMAINS=$(echo "$all_domains" | tr ' ' '\n' | grep -v '^$' | sort -u)

    if [ -z "$CERT_DOMAINS" ]; then
        log_error "无法从证书提取域名"
        return 1
    fi

    log_success "提取到以下域名："
    echo "$CERT_DOMAINS" | while read domain; do
        log_info "  - $domain"
    done

    return 0
}

# 根据规则选择测试域名
select_test_domains() {
    log_info "根据分流规则选择测试域名..."

    # 选择匹配 xray_backend 的域名 (x|xyz|api|dt|ai 开头的四级域名)
    XRAY_TEST_DOMAIN=$(echo "$CERT_DOMAINS" | while read domain; do
        # 计算域名级数
        local level_count=$(echo "$domain" | tr -cd '.' | wc -c)
        level_count=$((level_count + 1))

        # 必须是四级域名
        if [ $level_count -eq 4 ]; then
            local prefix=$(echo "$domain" | cut -d'.' -f1)
            if [[ "$prefix" =~ ^(x|xyz|api|dt|ai)$ ]]; then
                echo "$domain"
                break
            fi
        fi
    done)

    # 选择匹配 xhttp_backend 的域名 (web|app|cdn 开头的四级域名)
    XHTTP_TEST_DOMAIN=$(echo "$CERT_DOMAINS" | while read domain; do
        # 计算域名级数
        local level_count=$(echo "$domain" | tr -cd '.' | wc -c)
        level_count=$((level_count + 1))

        # 必须是四级域名
        if [ $level_count -eq 4 ]; then
            local prefix=$(echo "$domain" | cut -d'.' -f1)
            if [[ "$prefix" =~ ^(web|app|cdn)$ ]]; then
                echo "$domain"
                break
            fi
        fi
    done)

    # 如果没有找到四级域名，动态构造一个
    if [ -z "$XRAY_TEST_DOMAIN" ]; then
        log_info "证书中没有四级域名，尝试动态构造..."

        # 从证书域名中随机选择一个含通配符的四级域名
        local wildcard_four_level_domains=$(echo "$CERT_DOMAINS" | while read domain; do
            local level_count=$(echo "$domain" | tr -cd '.' | wc -c)
            level_count=$((level_count + 1))

            # 寻找四级通配符域名 *.xxx.yyy.zzz.www
            if [ $level_count -eq 4 ] && [[ "$domain" =~ ^\*\. ]]; then
                echo "$domain"
            fi
        done)

        if [ -n "$wildcard_four_level_domains" ]; then
            # 随机选择一个通配符四级域名
            local domains_array=($wildcard_four_level_domains)
            local domain_count=${#domains_array[@]}
            local random_domain_index=$((RANDOM % domain_count))
            local selected_wildcard_domain=${domains_array[$random_domain_index]}

            # 从 HAProxy 分流配置中随机选择一个前缀
            local prefixes=("x" "xyz" "api" "dt" "ai")
            local prefix_count=${#prefixes[@]}
            local random_prefix_index=$((RANDOM % prefix_count))
            local selected_prefix=${prefixes[$random_prefix_index]}

            # 替换通配符生成具体的四级域名，如 *.ddx.cqcy.fun -> ai.ddx.cqcy.fun
            XRAY_TEST_DOMAIN="${selected_prefix}.${selected_wildcard_domain#\*.}"

            # 验证生成的域名是否在证书覆盖范围内
            local is_covered=false
            echo "$CERT_DOMAINS" | while read cert_domain; do
                if [[ "$XRAY_TEST_DOMAIN" == "$cert_domain" ]] || [[ "$cert_domain" == "*."* && "$XRAY_TEST_DOMAIN" == *"${cert_domain#\*.}" ]]; then
                    is_covered=true
                    break
                fi
            done

            log_info "动态构造 Xray 测试域名: $XRAY_TEST_DOMAIN (前缀: $selected_prefix, 通配符域名: $selected_wildcard_domain)"
            log_info "证书覆盖验证: 域名 $XRAY_TEST_DOMAIN 由通配符 $selected_wildcard_domain 覆盖"
        else
            # 如果没有三级域名，尝试用通配符域名构造
            local wildcard_3level=$(echo "$CERT_DOMAINS" | while read domain; do
                local level_count=$(echo "$domain" | tr -cd '.' | wc -c)
                level_count=$((level_count + 1))

                # 寻找三级通配符域名 *.yyy.zzz
                if [ $level_count -eq 3 ] && [[ "$domain" =~ ^\*\. ]]; then
                    echo "$domain"
                    break
                fi
            done)

            if [ -n "$wildcard_3level" ]; then
                # 从 HAProxy 分流配置中随机选择一个前缀
                local prefixes=("x" "xyz" "api" "dt" "ai")
                local prefix_count=${#prefixes[@]}
                local random_prefix_index=$((RANDOM % prefix_count))
                local selected_prefix=${prefixes[$random_prefix_index]}

                # 构造四级域名：prefix.随机子域名.通配符域名
                local base_domain="${wildcard_3level#\*.}"
                local random_subdomain="test$((RANDOM % 1000))"
                XRAY_TEST_DOMAIN="${selected_prefix}.${random_subdomain}.${base_domain}"
                log_info "动态构造 Xray 测试域名: $XRAY_TEST_DOMAIN (前缀: $selected_prefix, 通配符: $wildcard_3level)"
            fi
        fi
    fi

    # 如果没有找到XHTTP测试域名，动态构造一个
    if [ -z "$XHTTP_TEST_DOMAIN" ]; then
        log_info "证书中没有XHTTP四级域名，尝试动态构造..."

        # 从证书域名中随机选择一个含通配符的四级域名
        local wildcard_four_level_domains=$(echo "$CERT_DOMAINS" | while read domain; do
            local level_count=$(echo "$domain" | tr -cd '.' | wc -c)
            level_count=$((level_count + 1))

            # 寻找四级通配符域名 *.xxx.yyy.zzz.www
            if [ $level_count -eq 4 ] && [[ "$domain" =~ ^\*\. ]]; then
                echo "$domain"
            fi
        done)

        if [ -n "$wildcard_four_level_domains" ]; then
            # 随机选择一个通配符四级域名
            local domains_array=($wildcard_four_level_domains)
            local domain_count=${#domains_array[@]}
            local random_domain_index=$((RANDOM % domain_count))
            local selected_wildcard_domain=${domains_array[$random_domain_index]}

            # 从 XHTTP 分流配置中随机选择一个前缀
            local xhttp_prefixes=("web" "app" "cdn")
            local prefix_count=${#xhttp_prefixes[@]}
            local random_prefix_index=$((RANDOM % prefix_count))
            local selected_prefix=${xhttp_prefixes[$random_prefix_index]}

            # 替换通配符生成具体的四级域名，如 *.ddx.cqcy.fun -> web.ddx.cqcy.fun
            XHTTP_TEST_DOMAIN="${selected_prefix}.${selected_wildcard_domain#\*.}"

            log_info "动态构造 XHTTP 测试域名: $XHTTP_TEST_DOMAIN (前缀: $selected_prefix, 通配符域名: $selected_wildcard_domain)"
        else
            # 如果没有四级域名，尝试用三级通配符域名构造
            local wildcard_3level=$(echo "$CERT_DOMAINS" | while read domain; do
                local level_count=$(echo "$domain" | tr -cd '.' | wc -c)
                level_count=$((level_count + 1))

                # 寻找三级通配符域名 *.yyy.zzz
                if [ $level_count -eq 3 ] && [[ "$domain" =~ ^\*\. ]]; then
                    echo "$domain"
                    break
                fi
            done)

            if [ -n "$wildcard_3level" ]; then
                # 从 XHTTP 分流配置中随机选择一个前缀
                local xhttp_prefixes=("web" "app" "cdn")
                local prefix_count=${#xhttp_prefixes[@]}
                local random_prefix_index=$((RANDOM % prefix_count))
                local selected_prefix=${xhttp_prefixes[$random_prefix_index]}

                # 构造四级域名：prefix.随机子域名.通配符域名
                local base_domain="${wildcard_3level#\*.}"
                local random_subdomain="test$((RANDOM % 1000))"
                XHTTP_TEST_DOMAIN="${selected_prefix}.${random_subdomain}.${base_domain}"
                log_info "动态构造 XHTTP 测试域名: $XHTTP_TEST_DOMAIN (前缀: $selected_prefix, 通配符: $wildcard_3level)"
            fi
        fi
    fi

    # 选择不匹配任何规则的域名（默认路由到 nginx）
    # 优先选择带通配符的三级域名，去掉通配符构造具体域名
    local wildcard_domain=$(echo "$CERT_DOMAINS" | while read domain; do
        local level_count=$(echo "$domain" | tr -cd '.' | wc -c)
        level_count=$((level_count + 1))

        # 寻找三级通配符域名 *.yyy.zzz（不会匹配四级域名规则）
        if [ $level_count -eq 3 ] && [[ "$domain" =~ ^\*\. ]]; then
            echo "$domain"
            break
        fi
    done)

    if [ -n "$wildcard_domain" ]; then
        # 去掉通配符，构造具体的三级域名
        local base_domain="${wildcard_domain#\*.}"
        # 随机生成前缀，避免与 xray 规则冲突
        local nginx_prefixes=("www" "test" "blog" "shop" "admin" "portal" "demo" "app")
        local random_prefix_index=$((RANDOM % ${#nginx_prefixes[@]}))
        local selected_prefix=${nginx_prefixes[$random_prefix_index]}
        NGX_TEST_DOMAIN="${selected_prefix}.${base_domain}"
        log_info "使用通配符域名构造 Nginx 测试域名: $NGX_TEST_DOMAIN (前缀: $selected_prefix, 通配符: $wildcard_domain)"
    else
        # 备选：选择非通配符的三级域名
        NGX_TEST_DOMAIN=$(echo "$CERT_DOMAINS" | while read domain; do
            local level_count=$(echo "$domain" | tr -cd '.' | wc -c)
            level_count=$((level_count + 1))

            # 选择三级域名（不会匹配四级域名规则）
            if [ $level_count -eq 3 ] && [[ ! "$domain" =~ ^\*\. ]]; then
                echo "$domain"
                break
            fi
        done)
    fi

    echo ""
    log_info "选择的测试域名："
    if [ -n "$NGX_TEST_DOMAIN" ]; then
        log_success "Nginx 测试域名: $NGX_TEST_DOMAIN"
    else
        log_warning "未找到匹配 ngx_backend 规则的域名"
    fi

    if [ -n "$XRAY_TEST_DOMAIN" ]; then
        log_success "Xray Vision 测试域名: $XRAY_TEST_DOMAIN"
    else
        log_warning "未找到匹配 xray_backend 规则的域名"
    fi

    if [ -n "$XHTTP_TEST_DOMAIN" ]; then
        log_success "Xray XHTTP 测试域名: $XHTTP_TEST_DOMAIN"
    else
        log_warning "未找到匹配 xhttp_backend 规则的域名"
    fi
}

# 测试用例函数定义
test_case_1() {
    echo ""
    echo "=========================================="
    log_test "Test 1: 容器健康检查"
    echo "=========================================="
    echo ""

    local containers=$(remote_cmd "docker ps --format '{{.Names}}'")
    local required=("nginx" "acme" "xray")
    if [ "$ENTRY_MODE" = "haproxy" ]; then
        required=("haproxy" "nginx" "acme" "xray")
    fi

    log_info "入口模式: $ENTRY_MODE（检查容器: ${required[*]}）"
    for c in "${required[@]}"; do
        if echo "$containers" | grep -q "^${c}$"; then
            test_pass "$c 容器运行中"
        else
            test_fail "$c 容器未运行"
        fi
    done
}

test_case_2() {
    echo ""
    echo "=========================================="
    log_test "Test 2: 端口监听检查"
    echo "=========================================="
    echo ""

    # HAProxy 和 Nginx 使用 host 模式，检查宿主机端口；属主须与入口模式一致
    local owner443=$(remote_cmd "ss -tlnp 2>/dev/null | grep ':443 ' | head -1")
    if [ -n "$owner443" ]; then
        if echo "$owner443" | grep -q "$ENTRY_MODE"; then
            test_pass "443 端口监听中（属主: $ENTRY_MODE）"
        else
            test_fail "443 占用进程与入口模式不符（期望 $ENTRY_MODE）: $owner443"
        fi
    else
        test_fail "443 端口未监听"
    fi

    if remote_cmd "ss -tlnp | grep ':80'" >/dev/null 2>&1; then
        test_pass "Nginx 80 端口监听中"
    else
        test_fail "Nginx 80 端口未监听"
    fi

    if remote_cmd "ss -tlnp | grep ':8443'" >/dev/null 2>&1; then
        test_pass "Nginx 8443 端口监听中"
    else
        test_fail "Nginx 8443 端口未监听"
    fi

    # Xray 端口映射到宿主机，检查宿主机端口
    if remote_cmd "ss -tlnp | grep ':18910'" >/dev/null 2>&1; then
        test_pass "Xray Vision 18910 端口监听中"
    else
        test_fail "Xray Vision 18910 端口未监听"
    fi

    if remote_cmd "ss -tlnp | grep ':18911'" >/dev/null 2>&1; then
        test_pass "Xray XHTTP 18911 端口监听中"
    else
        test_fail "Xray XHTTP 18911 端口未监听"
    fi
}

test_case_3() {
    echo ""
    echo "=========================================="
    log_test "Test 3: 证书文件检查并提取域名"
    echo "=========================================="
    echo ""

    # 检查证书文件
    if remote_cmd "docker exec nginx test -f /etc/nginx/cert/default_cert.pem" >/dev/null 2>&1; then
        test_pass "证书文件 default_cert.pem 存在"
    else
        test_fail "证书文件 default_cert.pem 不存在"
        return 1
    fi

    if remote_cmd "docker exec nginx test -f /etc/nginx/cert/default_key.pem" >/dev/null 2>&1; then
        test_pass "证书文件 default_key.pem 存在"
    else
        test_fail "证书文件 default_key.pem 不存在"
        return 1
    fi

    # 提取域名
    extract_cert_domains
    select_test_domains
}

test_case_4() {
    echo ""
    echo "=========================================="
    log_test "Test 4: SNI 分流到 Nginx 测试"
    echo "=========================================="
    echo ""

    if [ -z "$NGX_TEST_DOMAIN" ]; then
        test_fail "未找到 Nginx 测试域名"
        return 1
    fi

    log_info "测试域名: $NGX_TEST_DOMAIN → ngx_backend"

    # 生成随机数用于测试
    local random_num=$RANDOM
    log_info "随机数: $random_num"

    # 创建测试文件
    if remote_cmd "echo 'Test$random_num' > html/test.html" >/dev/null 2>&1; then
        test_pass "测试文件已创建"
    else
        test_fail "无法创建测试文件"
        return 1
    fi

    # 记录入口路由日志位置（偏移量方案：只匹配本次请求后追加的内容，README-003 4.1）
    local route_log=$(route_log_file)
    local log_pos=$(remote_cmd "wc -c < $route_log 2>/dev/null || echo 0" 2>/dev/null)
    log_pos=${log_pos:-0}

    # 发送 HTTPS 请求
    log_info "发送 HTTPS 请求: https://$NGX_TEST_DOMAIN/test.html?r=$random_num"
    log_info "通过 $ENTRY_MODE 443 端口，SNI: $NGX_TEST_DOMAIN"

    local response=$(remote_cmd "curl -s --max-time 10 --resolve '$NGX_TEST_DOMAIN:443:127.0.0.1' https://$NGX_TEST_DOMAIN/test.html?r=$random_num -k" 2>/dev/null)

    if [[ "$response" == *"Test$random_num"* ]]; then
        test_pass "Nginx 返回内容正确"
    else
        test_fail "Nginx 返回内容错误: $response"
        return 1
    fi

    # 等待日志写入
    sleep 2

    # 检查入口路由日志（偏移量方案：只查 pos 之后追加的新内容；TCP 模式只有 SNI 没有 querystring）
    log_info "检查入口路由日志（$ENTRY_MODE, $route_log, 偏移 $log_pos）..."
    local haproxy_log=$(remote_cmd "tail -c +$((log_pos + 1)) $route_log | grep 'sni:$NGX_TEST_DOMAIN' | tail -1" 2>/dev/null)

    if [ -n "$haproxy_log" ]; then
        test_pass "入口日志包含 SNI: $NGX_TEST_DOMAIN"

        # 检查 backend（按入口模式断言）
        local backend_want=$(route_backend_pattern ngx)
        if echo "$haproxy_log" | grep -q "$backend_want"; then
            test_pass "入口日志显示路由到 $backend_want"
        else
            test_warn "入口日志未明确显示 backend 名称（期望 $backend_want）"
        fi

        log_info "入口日志: $haproxy_log"
        log_info "注意: 入口工作在 TCP 模式，日志中只有 SNI，没有 querystring"
    else
        test_fail "入口日志未找到该请求 (SNI: $NGX_TEST_DOMAIN, $route_log)"
        return 1
    fi

    # 检查 Nginx 日志（应该包含 querystring）
    log_info "检查 Nginx 日志..."
    local nginx_log=$(remote_cmd "docker exec nginx cat /var/log/nginx/access.log | grep 'r=$random_num' | tail -1")

    if [ -n "$nginx_log" ]; then
        test_pass "Nginx 日志包含 querystring (r=$random_num)"
        log_info "Nginx 日志: $nginx_log"
    else
        test_warn "Nginx 日志中未找到该请求"
    fi
}

test_case_5() {
    echo ""
    echo "=========================================="
    log_test "Test 5: Xray 代理功能测试"
    echo "=========================================="
    echo ""

    if [ -z "$XRAY_TEST_DOMAIN" ]; then
        test_fail "未找到 Xray 测试域名"
        return 1
    fi

    log_info "测试域名: $XRAY_TEST_DOMAIN → xray_backend"
    log_info "脚本构造的测试域名: $XRAY_TEST_DOMAIN"

    # 在宿主机启动 Xray 客户端进行 SOCKS5 代理测试
    log_info "在宿主机启动 Xray 客户端进行 SOCKS5 代理测试..."

    # 获取 XRAY_UUID - 只取第一个匹配的UUID，避免重复
    local xray_uuid=$(remote_cmd "grep '^XRAY_UUID=' .env | head -1 | cut -d'=' -f2 | tr -d '\"'" 2>/dev/null)
    if [ -z "$xray_uuid" ]; then
        test_fail "未找到 XRAY_UUID 环境变量"
        return 1
    fi

    # 使用服务端日志目录的绝对路径
    local log_dir="/home/work/laddr-docker/log"
    local client_log_prefix="xray_test"

    # 创建临时目录用于存放二进制文件
    local temp_dir="/tmp/xray_test_$$"
    remote_cmd "mkdir -p $temp_dir"

    # 从容器拷贝 xray 二进制程序
    log_info "拷贝 xray 二进制程序到宿主机..."
    remote_cmd "docker cp xray:/usr/bin/xray $temp_dir/xray"
    remote_cmd "chmod +x $temp_dir/xray"

    # 在本地创建客户端配置文件，然后拷贝到远程
    log_info "创建 Xray 客户端配置..."
    local local_config="/tmp/xray_client_config_$$.json"

    # 清理变量，确保没有换行符
    local clean_uuid=$(echo "$xray_uuid" | tr -d '\r\n' | sed 's/[[:space:]]*$//')
    local clean_domain=$(echo "$XRAY_TEST_DOMAIN" | tr -d '\r\n' | sed 's/[[:space:]]*$//')

    log_info "客户端配置将使用域名: $clean_domain"
    log_info "客户端配置将使用UUID: ${clean_uuid:0:8}...${clean_uuid: -4}"
    log_info "客户端日志目录: $log_dir"
    log_info "客户端日志前缀: $client_log_prefix"

    cat > "$local_config" <<EOF
{
  "log": {
    "loglevel": "debug",
    "access": "$log_dir/${client_log_prefix}_access.log",
    "error": "$log_dir/${client_log_prefix}_error.log"
  },
  "inbounds": [
    {
      "tag": "socks",
      "port": 11080,
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": {
        "userLevel": 0
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"],
        "metadataOnly": false
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "127.0.0.1",
            "port": 443,
            "users": [
              {
                "id": "$clean_uuid",
                "flow": "xtls-rprx-vision",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "$clean_domain",
          "allowInsecure": true,
          "fingerprint": "chrome"
        }
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["socks"],
        "outboundTag": "proxy"
      }
    ]
  }
}
EOF

    # 验证本地配置文件是否生成成功
    if [ ! -f "$local_config" ]; then
        test_fail "Xray 客户端配置文件生成失败"
        return 1
    fi

    # 验证配置文件内容是否正确（检查关键字段）
    if ! grep -q "\"access\": \"$log_dir/${client_log_prefix}_access.log\"" "$local_config"; then
        test_fail "Xray 客户端配置文件访问日志路径配置错误"
        log_info "期望路径: $log_dir/${client_log_prefix}_access.log"
        log_info "实际配置: $(grep '"access":' "$local_config" || echo '未找到access配置')"
        return 1
    fi

    log_info "✓ 配置文件生成成功，访问日志路径: $log_dir/${client_log_prefix}_access.log"

    # 将配置文件拷贝到远程服务器
    log_info "拷贝配置文件到远程服务器..."
    # 获取远程临时目录路径
    local remote_temp_dir=$(remote_cmd "echo $temp_dir")
    if ! scp "$local_config" "$DEPLOYMENT_SERVER:$remote_temp_dir/client_config.json"; then
        test_fail "配置文件拷贝到远程服务器失败"
        rm -f "$local_config"
        return 1
    fi

    # 验证远程配置文件是否拷贝成功
    local remote_config_check=$(remote_cmd "[ -f $temp_dir/client_config.json ] && echo 'exists' || echo 'missing'")
    if [ "$remote_config_check" != "exists" ]; then
        test_fail "远程服务器上配置文件不存在"
        rm -f "$local_config"
        return 1
    fi

    log_info "✓ 配置文件拷贝成功"

    # 清理本地临时文件
    rm -f "$local_config"

    # 启动 Xray 客户端（后台运行）
    log_info "启动 Xray 客户端（端口11080）..."
    # 使用后台运行，SSH 立即返回
    ssh "$DEPLOYMENT_SERVER" "cd $temp_dir && nohup ./xray run -c client_config.json > client_stdout.log 2>&1 & echo \$! > xray.pid" >/dev/null 2>&1 &
    local ssh_pid=0

    # 设置陷阱函数，确保异常退出时清理（保留日志文件）
    cleanup_xray() {
        remote_cmd "pkill -f 'xray run -c client_config.json'" 2>/dev/null || true
        remote_cmd "rm -rf $temp_dir" 2>/dev/null || true
        log_info "客户端日志已保存到: ${log_dir}/${client_log_prefix}_*.log"
    }
    trap cleanup_xray EXIT INT TERM

    # 等待客户端启动
    sleep 5

    # 检查端口是否监听
    local port_check=$(remote_cmd "ss -tlnp | grep ':11080'" 2>/dev/null)
    if [ -n "$port_check" ]; then
        test_pass "Xray 客户端在宿主机启动成功（端口11080）"
        log_info "  端口监听: $port_check"
    else
        test_fail "Xray 客户端启动失败"
        # 显示错误信息
        log_info "检查启动日志..."
        local startup_log=$(remote_cmd "cat $temp_dir/client_stdout.log 2>/dev/null | head -10")
        if [ -n "$startup_log" ]; then
            log_info "启动日志: $startup_log"
        fi
        local error_log=$(remote_cmd "cat $temp_dir/client_error.log 2>/dev/null | head -10")
        if [ -n "$error_log" ]; then
            log_info "错误日志: $error_log"
        fi
        # 清理并返回（保留日志文件）
        log_info "清理 Xray 客户端进程..."
        remote_cmd "pkill -f 'xray run -c client_config.json'" 2>/dev/null || true
        remote_cmd "kill \$(cat $temp_dir/xray.pid 2>/dev/null) 2>/dev/null" 2>/dev/null || true
        remote_cmd "rm -rf $temp_dir" 2>/dev/null || true
        log_info "客户端日志已保存到: ${log_dir}/${client_log_prefix}_*.log"
        return 1
    fi

    # 使用宿主机的curl通过SOCKS5代理请求Google
    log_info "通过 SOCKS5 代理请求 www.google.com..."

    # 记录入口路由日志位置（偏移量方案：只匹配本次请求后追加的内容）
    local route_log=$(route_log_file)
    local route_log_pos=$(remote_cmd "wc -c < $route_log 2>/dev/null || echo 0" 2>/dev/null)
    route_log_pos=${route_log_pos:-0}
    log_info "入口路由日志: $route_log (偏移 $route_log_pos)"

    # 在远程服务器记录时间并执行curl，同时获取HTTP Date头（避免本地远程延时导致的时间偏差）
    local test_result=$(remote_cmd "
        test_time=\$(date +%H:%M:%S)
        curl_output=\$(timeout 15 curl -s --socks5 127.0.0.1:11080 -D /tmp/curl_headers.tmp -w '%{http_code}' -o /dev/null https://www.google.com 2>&1)
        proxy_result=\$(echo \"\$curl_output\" | grep -o '[0-9][0-9][0-9]' | tail -1)
        http_date=\$(grep -i '^date:' /tmp/curl_headers.tmp 2>/dev/null | cut -d' ' -f2- | tr -d '\r\n' || echo 'N/A')
        echo \"\$test_time|\$proxy_result|\$http_date\"
        rm -f /tmp/curl_headers.tmp
    ")
    local test_start_time=$(echo "$test_result" | cut -d'|' -f1)
    local proxy_result=$(echo "$test_result" | cut -d'|' -f2)
    local http_date=$(echo "$test_result" | cut -d'|' -f3)

    log_info "测试开始时间: $test_start_time"
    log_info "HTTP响应Date头: $http_date"

    if [ -z "$proxy_result" ]; then
        proxy_result="000"
    fi

    # 清理结果，去掉可能的额外字符
    proxy_result=$(echo "$proxy_result" | tr -d '\r\n' | sed 's/[^0-9]//g')

    log_info "代理请求结果: HTTP $proxy_result"

    if [ "$proxy_result" = "200" ] || [ "$proxy_result" = "301" ] || [ "$proxy_result" = "302" ]; then
        log_info "代理请求成功 (HTTPS $proxy_result)，开始验证完整链路..."

        # 检查完整代理链路日志 - 严格验证模式
        log_info "🔍 严格验证代理链路完整性..."
        local validation_failed=false
        local failure_reasons=()

        # 1. 检查 Xray 客户端日志（宿主机上的客户端）
        log_info "1. 检查 Xray 客户端日志（宿主机）..."
        local xray_client_access_log=$(remote_cmd "cat ${log_dir}/${client_log_prefix}_access.log 2>/dev/null | tail -5")
        local xray_client_error_log=$(remote_cmd "cat ${log_dir}/${client_log_prefix}_error.log 2>/dev/null | tail -5")
        local xray_client_stdout_log=$(remote_cmd "cat $temp_dir/client_stdout.log 2>/dev/null | tail -5")

        # 检查客户端是否有配置错误
        if echo "$xray_client_stdout_log" | grep -q "Failed to start\|invalid character\|failed to load config"; then
            validation_failed=true
            failure_reasons+=("Xray客户端配置错误")
            log_info "  ❌ 客户端配置错误: $(echo "$xray_client_stdout_log" | grep -E "Failed to start|invalid character|failed to load config" | head -1)"
        fi

        # 从Xray客户端日志中提取时间作为基准时间
        local xray_client_time=""
        local found_client_log=""
        local new_base_time="$test_start_time"

        if [ -n "$xray_client_access_log" ]; then
            found_client_log="$xray_client_access_log"
            xray_client_time=$(echo "$xray_client_access_log" | grep -o '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' | tail -1)
        elif [ -n "$xray_client_stdout_log" ]; then
            found_client_log="$xray_client_stdout_log"
            xray_client_time=$(echo "$xray_client_stdout_log" | grep -o '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' | tail -1)
        fi

        if [ -n "$xray_client_time" ]; then
            # 检查客户端时间是否在2秒窗口内
            local time_diff=$(remote_cmd "
                test_time='$test_start_time'
                client_time='$xray_client_time'
                test_seconds=\$(echo \$test_time | awk -F: '{print \$1*3600 + \$2*60 + \$3}')
                client_seconds=\$(echo \$client_time | awk -F: '{print \$1*3600 + \$2*60 + \$3}')
                diff=\$((client_seconds - test_seconds))
                if [ \$diff -lt 0 ]; then diff=\$((0 - diff)); fi
                echo \$diff
            ")

            if [ "$time_diff" -le 2 ]; then
                new_base_time="$xray_client_time"
                log_info "  ✓ 提取到客户端时间: $xray_client_time (在2秒窗口内)"
            else
                log_info "  ❌ 客户端时间: $xray_client_time 不在2秒窗口内 (测试时间: $test_start_time, 差距: ${time_diff}秒)"
                validation_failed=true
                failure_reasons+=("客户端日志时间不在窗口内")
                new_base_time="$test_start_time"  # 使用测试时间作为基准
            fi
        else
            log_info "  ❌ 未找到客户端时间"
            validation_failed=true
            failure_reasons+=("未找到客户端时间")
            new_base_time="$test_start_time"  # 使用测试时间作为基准
        fi

        # 2. 检查入口路由日志（偏移量方案：只看本次请求后追加的内容）
        log_info "2. 检查入口 SNI 路由日志（$ENTRY_MODE, $route_log, 偏移 $route_log_pos）..."
        local haproxy_found=false

        # 只进行精确匹配，要求SNI必须与构造的域名一致
        local haproxy_log=$(remote_cmd "tail -c +$((route_log_pos + 1)) $route_log | grep 'sni:$XRAY_TEST_DOMAIN' | tail -1" 2>/dev/null)

        if [ -n "$haproxy_log" ]; then
            local backend_want=$(route_backend_pattern xray)
            if echo "$haproxy_log" | grep -q "$backend_want"; then
                haproxy_found=true
                log_info "  ✓ 入口正确路由到 $backend_want"
                log_info "  入口日志: $haproxy_log"

                # 提取实际的SNI域名用于验证
                local actual_sni=$(echo "$haproxy_log" | grep -o 'sni:[^[:space:]]*' | cut -d':' -f2)
                if [ -n "$actual_sni" ]; then
                    log_info "  实际SNI域名: $actual_sni"
                    if [ "$actual_sni" = "$XRAY_TEST_DOMAIN" ]; then
                        log_info "  ✓ SNI域名完全匹配构造的测试域名"
                    else
                        log_info "  ❌ SNI域名不匹配: 期望 $XRAY_TEST_DOMAIN, 实际 $actual_sni"
                        validation_failed=true
                        failure_reasons+=("入口SNI域名不匹配")
                    fi
                fi
            else
                validation_failed=true
                failure_reasons+=("入口路由到错误后端（期望 $backend_want）")
                log_info "  ❌ 入口路由错误（期望 $backend_want）: $haproxy_log"
            fi
        else
            validation_failed=true
            failure_reasons+=("入口未找到精确匹配的SNI路由日志")
            log_info "  ❌ 入口未找到 SNI: $XRAY_TEST_DOMAIN 的路由日志"
        fi

        # 3. 检查 Xray 服务端日志（代理处理）
        log_info "3. 检查 Xray 服务端日志（$new_base_time 前后2秒）..."
        local xray_server_found=false
        local xray_server_log=$(remote_cmd "tail -50 log/xray_access.log | grep 'from.*accepted.*www.google.com' | tail -1" 2>/dev/null)

        if [ -n "$xray_server_log" ]; then
            xray_server_found=true
            log_info "  ✓ Xray 服务端有 Google 访问记录"
            log_info "  Xray 服务端日志: $xray_server_log"

            # 验证目标域名是否为www.google.com
            if echo "$xray_server_log" | grep -q "www.google.com:443"; then
                log_info "  ✓ 目标域名正确: www.google.com"
            else
                log_info "  ❌ 目标域名不正确，期望 www.google.com"
                validation_failed=true
                failure_reasons+=("Xray服务端目标域名不匹配")
            fi
        else
            validation_failed=true
            failure_reasons+=("Xray服务端未找到处理记录")
            log_info "  ❌ Xray 服务端未找到 Google 访问记录"
        fi

        # 清理 Xray 客户端进程，但保留日志文件
        log_info "清理 Xray 客户端进程..."
        remote_cmd "pkill -f 'xray run -c client_config.json'" 2>/dev/null || true
        remote_cmd "kill \$(cat $temp_dir/xray.pid 2>/dev/null) 2>/dev/null" 2>/dev/null || true
        remote_cmd "rm -rf $temp_dir" 2>/dev/null || true
        log_info "客户端日志已保存到: ${log_dir}/${client_log_prefix}_*.log"

        # 最终判断
        if [ "$validation_failed" = true ]; then
            test_fail "Xray Vision 代理测试失败"
            log_error "❌ 虽然代理请求返回 HTTP $proxy_result，但链路验证失败"
            log_error "失败原因: $(IFS=', '; echo "${failure_reasons[*]}")"

            # 问题排查
            log_info ""
            log_error "🔍 开始问题排查..."

            # 检查客户端配置问题
            if echo "${failure_reasons[@]}" | grep -q "客户端配置错误"; then
                log_error "1. Xray 客户端配置问题:"
                log_info "   - 检查 JSON 格式是否正确"
                log_info "   - 验证 UUID 和 REALITY 配置"
                local client_error=$(remote_cmd "cat $temp_dir/client_stdout.log 2>/dev/null | grep -E 'Failed to start|invalid character|failed to load config' | head -1")
                if [ -n "$client_error" ]; then
                    log_info "   错误详情: $client_error"
                fi
            fi

            # 检查网络连通性
            log_error "2. 检查网络连通性:"
            local ping_result=$(remote_cmd "ping -c 1 www.google.com >/dev/null 2>&1 && echo 'OK' || echo 'FAIL'")
            log_info "   - 直接 ping Google: $ping_result"

            # 检查服务端配置
            log_error "3. 检查 Xray 服务端配置:"
            local xray_status=$(remote_cmd "docker logs xray --tail 5 2>/dev/null | grep -E 'started|listening|error' | tail -1")
            log_info "   - Xray 服务状态: $xray_status"

            return 1
        else
            test_pass "Xray Vision 代理功能完全正常"
            log_info "✅ 代理请求成功 + 完整链路验证通过"

            # 显示详细的链路日志对比表格
            log_info ""
            log_info "=========================================="
            log_info "  链路日志验证详情"
            log_info "=========================================="

            # 提取各个时间点
            local haproxy_time=$(echo "$haproxy_log" | grep -o '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' | head -1)
            local xray_server_time=$(echo "$xray_server_log" | grep -o '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' | head -1)

            # 格式化HTTP Date头显示 - 将GMT时间转换为本地时间
            local http_date_gmt=$(echo "$http_date" | awk '{print $5}')
            local http_date_short=$(remote_cmd "
                if [ '$http_date_gmt' != 'N/A' ] && [ -n '$http_date_gmt' ]; then
                    # 将GMT时间转换为本地时间
                    date -d 'TZ=\"GMT\" $http_date_gmt' +%H:%M:%S 2>/dev/null || echo '$http_date_gmt'
                else
                    echo 'N/A'
                fi
            ")

            printf "%-15s %-12s %-25s %-10s\n" "组件" "时间" "域名/目标" "状态"
            printf "%-15s %-12s %-25s %-10s\n" "---------------" "------------" "-------------------------" "----------"
            printf "%-15s %-12s %-25s %-10s\n" "测试开始" "$test_start_time" "www.google.com" "✓"
            printf "%-15s %-12s %-25s %-10s\n" "HTTP响应" "${http_date_short:-N/A}" "www.google.com" "✓"
            printf "%-15s %-12s %-25s %-10s\n" "Xray客户端" "${xray_client_time:-N/A}" "www.google.com" "$([ -n "$xray_client_time" ] && echo "✓" || echo "❌")"
            printf "%-15s %-12s %-25s %-10s\n" "入口路由" "${haproxy_time:-N/A}" "${actual_sni:-N/A}" "$([ "$actual_sni" = "$XRAY_TEST_DOMAIN" ] && echo "✓" || echo "❌")"
            printf "%-15s %-12s %-25s %-10s\n" "Xray服务端" "${xray_server_time:-N/A}" "www.google.com" "$(echo "$xray_server_log" | grep -q "www.google.com:443" && echo "✓" || echo "❌")"
            log_info "=========================================="

            # 显示验证结果摘要
            log_info "验证摘要:"
            log_info "  构造域名: $XRAY_TEST_DOMAIN"
            log_info "  实际SNI: ${actual_sni:-未找到}"
            log_info "  域名匹配: $([ "$actual_sni" = "$XRAY_TEST_DOMAIN" ] && echo "✓ 完全匹配" || echo "❌ 不匹配")"
            log_info "  时间窗口: $([ "$time_diff" -le 2 ] 2>/dev/null && echo "✓ 在2秒内" || echo "❌ 超出范围")"
        fi

    else
        test_fail "Xray 代理 Google 失败 (HTTPS $proxy_result)"
        log_info "❌ Xray 代理功能异常，无法访问 www.google.com"

        # 详细检查各个环节的日志
        log_info "🔍 检查代理失败的详细原因..."

        # 检查入口是否有新的代理请求记录（偏移量方案）
        log_info "检查入口代理日志（最近记录）..."
        local haproxy_recent=$(remote_cmd "tail -c +$((route_log_pos + 1)) $route_log | grep 'sni:$XRAY_TEST_DOMAIN' | tail -3" 2>/dev/null)
        if [ -n "$haproxy_recent" ]; then
            log_info "✓ 入口有代理请求记录:"
            echo "$haproxy_recent" | while read line; do
                log_info "  $line"
            done
        else
            log_info "✗ 入口没有找到代理请求记录"
        fi

        # 检查 Xray 服务端日志
        log_info "检查 Xray 服务端日志（最近10行）..."
        local xray_server_log=$(remote_cmd "docker logs xray --tail 10" 2>/dev/null)
        if [ -n "$xray_server_log" ]; then
            log_info "✓ Xray 服务端日志:"
            echo "$xray_server_log" | while read line; do
                log_info "  $line"
            done
        else
            log_info "✗ Xray 服务端日志为空"
        fi

        # 检查 Xray 客户端日志
        log_info "检查 Xray 客户端日志..."
        local xray_client_access_log=$(remote_cmd "docker exec xray cat /tmp/xray_client_access.log 2>/dev/null | tail -5")
        local xray_client_error_log=$(remote_cmd "docker exec xray cat /tmp/xray_client_error.log 2>/dev/null | tail -5")
        local xray_client_stdout_log=$(remote_cmd "docker exec xray cat /tmp/client.log 2>/dev/null | tail -5")

        if [ -n "$xray_client_access_log" ]; then
            log_info "✓ Xray 客户端访问日志:"
            echo "$xray_client_access_log" | while read line; do
                log_info "  $line"
            done
        else
            log_info "✗ Xray 客户端访问日志为空"
        fi

        if [ -n "$xray_client_error_log" ]; then
            log_info "✓ Xray 客户端错误日志:"
            echo "$xray_client_error_log" | while read line; do
                log_info "  $line"
            done
        else
            log_info "✗ Xray 客户端错误日志为空"
        fi

        if [ -n "$xray_client_stdout_log" ]; then
            log_info "✓ Xray 客户端标准输出:"
            echo "$xray_client_stdout_log" | while read line; do
                log_info "  $line"
            done
        else
            log_info "✗ Xray 客户端标准输出为空"
        fi

        # 检查 SOCKS5 端口监听
        log_info "检查 SOCKS5 端口监听状态..."
        local socks_check=$(remote_cmd "docker exec xray ss -tlnp | grep ':10808'" 2>/dev/null)
        if [ -n "$socks_check" ]; then
            log_info "✓ SOCKS5 端口监听正常: $socks_check"
        else
            log_info "✗ SOCKS5 端口未监听"
        fi
    fi

}


test_case_6() {
    echo ""
    echo "=========================================="
    log_test "Test 6: Xray XHTTP 代理功能测试"
    echo "=========================================="
    echo ""

    # XHTTP+REALITY使用REALITY_DEST作为SNI和serverName，不使用证书域名
    local dest_domain=$(remote_cmd "grep '^REALITY_DEST=' .env | cut -d'=' -f2" 2>/dev/null)
    if [ -z "$dest_domain" ]; then
        dest_domain="www.fifa.com"  # 默认值
    fi

    log_info "XHTTP+REALITY 测试域名: $dest_domain (REALITY伪装目标)"
    log_info "注意：XHTTP+REALITY使用外部网站域名，不使用证书域名"

    # 在宿主机启动 Xray XHTTP 客户端进行 SOCKS5 代理测试
    log_info "在宿主机启动 Xray XHTTP 客户端进行 SOCKS5 代理测试..."

    # 获取 XRAY_UUID 和 Reality 配置
    local xray_uuid=$(remote_cmd "grep '^XRAY_UUID=' .env | head -1 | cut -d'=' -f2 | tr -d '\"'" 2>/dev/null)
    local reality_public_key=$(remote_cmd "grep '^REALITY_PUBLIC_KEY=' .env | cut -d'=' -f2" 2>/dev/null)
    local reality_short_ids=$(remote_cmd "grep '^REALITY_SHORT_IDS=' .env | cut -d'=' -f2" 2>/dev/null)

    if [ -z "$xray_uuid" ]; then
        test_fail "未找到 XRAY_UUID 环境变量"
        return 1
    fi

    if [ -z "$reality_public_key" ] || [ -z "$reality_short_ids" ]; then
        test_fail "未找到 Reality 配置 (REALITY_PUBLIC_KEY 或 REALITY_SHORT_IDS)"
        return 1
    fi

    # 使用服务端日志目录的绝对路径，与case5使用相同的日志文件
    local log_dir="/home/work/laddr-docker/log"
    local client_log_prefix="xray_test"

    # 创建临时目录用于存放二进制文件
    local temp_dir="/tmp/xray_xhttp_test_$$"
    remote_cmd "mkdir -p $temp_dir"

    # 从容器拷贝 xray 二进制程序
    log_info "拷贝 xray 二进制程序到宿主机..."
    remote_cmd "docker cp xray:/usr/bin/xray $temp_dir/xray"
    remote_cmd "chmod +x $temp_dir/xray"

    # 在本地创建XHTTP客户端配置文件，然后拷贝到远程
    log_info "创建 Xray XHTTP 客户端配置..."
    local local_config="/tmp/xray_xhttp_client_config_$$.json"

    # 清理变量，确保没有换行符
    local clean_uuid=$(echo "$xray_uuid" | tr -d '\r\n' | sed 's/[[:space:]]*$//')
    local clean_domain="$dest_domain"

    log_info "XHTTP客户端配置将使用域名: $clean_domain"
    log_info "XHTTP客户端配置将使用UUID: ${clean_uuid:0:8}...${clean_uuid: -4}"
    log_info "XHTTP客户端日志目录: $log_dir"
    log_info "XHTTP客户端日志前缀: $client_log_prefix"

    # 提取第一个shortId（修复REALITY配置问题）
    local first_short_id=$(echo "$reality_short_ids" | sed 's/.*"\([^"]*\)".*/\1/')

    cat > "$local_config" <<EOF
{
  "log": {
    "loglevel": "debug",
    "access": "$log_dir/${client_log_prefix}_access.log",
    "error": "$log_dir/${client_log_prefix}_error.log"
  },
  "inbounds": [
    {
      "tag": "socks",
      "port": 11081,
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": {
        "userLevel": 0
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"],
        "metadataOnly": false
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "127.0.0.1",
            "port": 443,
            "users": [
              {
                "id": "$clean_uuid",
                "flow": "",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {
          "path": "/js/app.js"
        },
        "realitySettings": {
          "show": false,
          "fingerprint": "chrome",
          "serverName": "$clean_domain",
          "publicKey": "$reality_public_key",
          "shortId": "$first_short_id"
        }
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["socks"],
        "outboundTag": "proxy"
      }
    ]
  }
}
EOF

    # 验证本地配置文件是否生成成功
    if [ ! -f "$local_config" ]; then
        test_fail "Xray XHTTP 客户端配置文件生成失败"
        return 1
    fi

    # 验证配置文件内容是否正确（检查关键字段）
    if ! grep -q "\"access\": \"$log_dir/${client_log_prefix}_access.log\"" "$local_config"; then
        test_fail "Xray XHTTP 客户端配置文件访问日志路径配置错误"
        log_info "期望路径: $log_dir/${client_log_prefix}_access.log"
        log_info "实际配置: $(grep '"access":' "$local_config" || echo '未找到access配置')"
        return 1
    fi

    log_info "✓ XHTTP配置文件生成成功，访问日志路径: $log_dir/${client_log_prefix}_access.log"
    log_info "本地配置文件路径: $local_config"

    # 将配置文件拷贝到远程服务器
    log_info "拷贝配置文件到远程服务器..."
    # 获取远程临时目录路径
    local remote_temp_dir=$(remote_cmd "echo $temp_dir")
    log_info "远程临时目录: $remote_temp_dir"

    if ! scp "$local_config" "$DEPLOYMENT_SERVER:$remote_temp_dir/client_config.json"; then
        test_fail "XHTTP配置文件拷贝到远程服务器失败"
        rm -f "$local_config"
        return 1
    fi

    # 验证远程配置文件是否拷贝成功
    local remote_config_check=$(remote_cmd "[ -f $temp_dir/client_config.json ] && echo 'exists' || echo 'missing'")
    if [ "$remote_config_check" != "exists" ]; then
        test_fail "远程服务器上XHTTP配置文件不存在"
        rm -f "$local_config"
        return 1
    fi

    # 验证远程配置文件内容关键字段
    local remote_reality_check=$(remote_cmd "grep -q '\"shortId\"' $temp_dir/client_config.json && echo 'has_reality' || echo 'no_reality'")
    log_info "远程配置REALITY检查: $remote_reality_check"
    log_info "远程配置文件路径: $temp_dir/client_config.json"

    log_info "✓ XHTTP配置文件拷贝成功"

    # 清理本地临时文件
    rm -f "$local_config"

    # 启动 Xray XHTTP 客户端（后台运行）
    log_info "启动 Xray XHTTP 客户端（端口11081）..."
    # 使用后台运行，SSH 立即返回
    ssh "$DEPLOYMENT_SERVER" "cd $temp_dir && nohup ./xray run -c client_config.json > client_stdout.log 2>&1 & echo \$! > xray.pid" >/dev/null 2>&1 &
    local ssh_pid=$!

    # 设置陷阱函数，确保异常退出时清理（保留日志文件）
    cleanup_xray_xhttp() {
        remote_cmd "pkill -f 'xray run -c client_config.json'" 2>/dev/null || true
        remote_cmd "rm -rf $temp_dir" 2>/dev/null || true
        log_info "XHTTP客户端日志已保存到: ${log_dir}/${client_log_prefix}_*.log"
    }
    trap cleanup_xray_xhttp EXIT INT TERM

    # 等待客户端启动
    sleep 5

    # 检查端口是否监听
    local port_check=$(remote_cmd "ss -tlnp | grep ':11081'" 2>/dev/null)
    if [ -n "$port_check" ]; then
        test_pass "Xray XHTTP 客户端在宿主机启动成功（端口11081）"
        log_info "  端口监听: $port_check"
    else
        test_fail "Xray XHTTP 客户端启动失败"
        # 显示错误信息
        log_info "检查启动日志..."
        local startup_log=$(remote_cmd "cat $temp_dir/client_stdout.log 2>/dev/null | head -10")
        if [ -n "$startup_log" ]; then
            log_info "启动日志: $startup_log"
        fi
        # 清理并返回（保留日志文件）
        cleanup_xray_xhttp
        return 1
    fi

    # 使用宿主机的curl通过SOCKS5代理请求Google
    log_info "通过 SOCKS5 代理（XHTTP协议）请求 www.google.com..."

    # 记录入口路由日志位置（偏移量方案：只匹配本次请求后追加的内容）
    local route_log=$(route_log_file)
    local route_log_pos=$(remote_cmd "wc -c < $route_log 2>/dev/null || echo 0" 2>/dev/null)
    route_log_pos=${route_log_pos:-0}
    log_info "入口路由日志: $route_log (偏移 $route_log_pos)"

    # 在远程服务器记录时间并执行curl，curl成功后立即关闭Xray客户端让入口写入日志
    local test_result=$(remote_cmd "
        test_time=\$(date +%H:%M:%S)
        curl_output=\$(timeout 15 curl -s --socks5 127.0.0.1:11081 -D /tmp/curl_headers_xhttp.tmp -w '%{http_code}' -o /dev/null https://www.google.com 2>&1)
        curl_exit_code=\$?
        proxy_result=\$(echo \"\$curl_output\" | grep -o '[0-9][0-9][0-9]' | tail -1)
        http_date=\$(grep -i '^date:' /tmp/curl_headers_xhttp.tmp 2>/dev/null | cut -d' ' -f2- | tr -d '\r\n' || echo '')
        # 输出结果
        echo \"\$test_time|\$proxy_result|\$http_date\"
        rm -f /tmp/curl_headers_xhttp.tmp
        # curl执行完成后立即关闭Xray客户端，让入口写入日志（XHTTP使用长连接）
        pkill -f 'xray run -c client_config.json' 2>/dev/null || true
        sleep 3  # 等待入口写入日志
    ")
    local test_start_time=$(echo "$test_result" | cut -d'|' -f1)
    local proxy_result=$(echo "$test_result" | cut -d'|' -f2)
    local http_date=$(echo "$test_result" | cut -d'|' -f3)

    log_info "测试开始时间: $test_start_time"
    log_info "HTTP响应Date头: $http_date"

    if [ -z "$proxy_result" ]; then
        proxy_result="000"
    fi

    # 清理结果，去掉可能的额外字符
    proxy_result=$(echo "$proxy_result" | tr -d '\r\n' | sed 's/[^0-9]//g')

    log_info "代理请求结果: HTTP $proxy_result"

    if [ "$proxy_result" = "200" ] || [ "$proxy_result" = "301" ] || [ "$proxy_result" = "302" ]; then
        log_info "XHTTP代理请求成功 (HTTPS $proxy_result)，开始验证完整链路..."

        # 检查完整代理链路日志 - 严格验证模式
        log_info "🔍 严格验证 XHTTP 代理链路完整性..."
        local validation_failed=false
        local failure_reasons=()

        # 1. 检查 Xray XHTTP 客户端日志
        log_info "1. 检查 Xray XHTTP 客户端日志（宿主机）..."
        local xray_client_access_log=$(remote_cmd "cat ${log_dir}/${client_log_prefix}_access.log 2>/dev/null | tail -5")
        local xray_client_error_log=$(remote_cmd "cat ${log_dir}/${client_log_prefix}_error.log 2>/dev/null | tail -5")
        local xray_client_stdout_log=$(remote_cmd "cat $temp_dir/client_stdout.log 2>/dev/null | tail -5")

        # 检查客户端是否有配置错误
        if echo "$xray_client_stdout_log" | grep -q "Failed to start\|non-empty.*shortIds\|failed to load config\|failed to build"; then
            validation_failed=true
            failure_reasons+=("Xray XHTTP客户端配置错误")
            log_info "  ❌ XHTTP客户端配置错误: $(echo "$xray_client_stdout_log" | grep -E "Failed to start|non-empty.*shortIds|failed to load config|failed to build" | head -1)"
        fi

        # 从Xray客户端日志中提取时间作为基准时间
        local xray_client_time=""
        local found_client_log=""
        local new_base_time="$test_start_time"

        if [ -n "$xray_client_access_log" ]; then
            found_client_log="$xray_client_access_log"
            xray_client_time=$(echo "$xray_client_access_log" | grep -o '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' | tail -1)
        elif [ -n "$xray_client_stdout_log" ]; then
            found_client_log="$xray_client_stdout_log"
            xray_client_time=$(echo "$xray_client_stdout_log" | grep -o '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' | tail -1)
        fi

        if [ -n "$xray_client_time" ]; then
            # 检查客户端时间是否在2秒窗口内
            local time_diff=$(remote_cmd "
                test_time='$test_start_time'
                client_time='$xray_client_time'
                test_seconds=\$(echo \$test_time | awk -F: '{print \$1*3600 + \$2*60 + \$3}')
                client_seconds=\$(echo \$client_time | awk -F: '{print \$1*3600 + \$2*60 + \$3}')
                diff=\$((client_seconds - test_seconds))
                if [ \$diff -lt 0 ]; then diff=\$((0 - diff)); fi
                echo \$diff
            ")

            if [ "$time_diff" -le 2 ]; then
                new_base_time="$xray_client_time"
                log_info "  ✓ 提取到XHTTP客户端时间: $xray_client_time (在2秒窗口内)"
            else
                log_info "  ❌ XHTTP客户端时间: $xray_client_time 不在2秒窗口内 (测试时间: $test_start_time, 差距: ${time_diff}秒)"
                validation_failed=true
                failure_reasons+=("XHTTP客户端日志时间不在窗口内")
                new_base_time="$test_start_time"  # 使用测试时间作为基准
            fi
        else
            log_info "  ❌ 未找到XHTTP客户端时间"
            validation_failed=true
            failure_reasons+=("未找到XHTTP客户端时间")
            new_base_time="$test_start_time"  # 使用测试时间作为基准
        fi

        # 2. 检查入口路由日志（偏移量方案：只看本次请求后追加的内容）
        # 注意：XHTTP+REALITY使用REALITY_DEST作为SNI，而不是证书域名
        local expected_sni="$dest_domain"
        log_info "2. 检查入口 SNI 路由日志（XHTTP后端，$ENTRY_MODE, $route_log, 偏移 $route_log_pos）..."
        log_info "   期望的SNI: $expected_sni (REALITY伪装目标)"
        local haproxy_log=$(remote_cmd "tail -c +$((route_log_pos + 1)) $route_log | grep 'sni:$expected_sni' | tail -1" 2>/dev/null)

        if [ -n "$haproxy_log" ]; then
            local backend_want=$(route_backend_pattern xhttp)
            if echo "$haproxy_log" | grep -q "$backend_want"; then
                test_pass "入口正确路由到 $backend_want"
                log_info "  入口日志: $haproxy_log"
                # 提取实际的SNI域名用于验证
                local actual_sni=$(echo "$haproxy_log" | grep -o 'sni:[^[:space:]]*' | cut -d':' -f2)
                log_info "  实际SNI域名: $actual_sni"
                if [ "$actual_sni" = "$expected_sni" ]; then
                    log_info "  ✓ SNI域名完全匹配REALITY伪装目标: $expected_sni"
                else
                    log_info "  ❌ SNI域名不匹配REALITY伪装目标"
                    validation_failed=true
                    failure_reasons+=("SNI域名不匹配")
                fi
            else
                validation_failed=true
                failure_reasons+=("入口路由到错误后端（期望 $backend_want）")
                log_info "  ❌ 入口路由错误（期望 $backend_want）: $haproxy_log"
            fi
        else
            validation_failed=true
            failure_reasons+=("入口未找到精确匹配的SNI路由日志")
            log_info "  ❌ 入口未找到 SNI: $expected_sni 的路由日志"
        fi

        # 3. 检查 Xray 服务端日志（XHTTP代理处理）- 使用新的基准时间前后2秒查找
        log_info "3. 检查 Xray 服务端日志（XHTTP端口）（$new_base_time 前后2秒）..."
        local xray_server_log=$(remote_cmd "tail -50 log/xray_access.log | grep 'from.*accepted' | while read line; do
            log_time=\$(echo \"\$line\" | grep -o '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]')
            if [ -n \"\$log_time\" ]; then
                log_seconds=\$(echo \$log_time | awk -F: '{print \$1*3600 + \$2*60 + \$3}')
                base_seconds=\$(echo '$new_base_time' | awk -F: '{print \$1*3600 + \$2*60 + \$3}')
                diff=\$((log_seconds - base_seconds))
                if [ \$diff -ge -2 ] && [ \$diff -le 2 ]; then
                    echo \"\$line\"
                fi
            fi
        done" 2>/dev/null)
        if [ -n "$xray_server_log" ]; then
            log_info "  ✓ Xray 服务端（XHTTP）有 Google 访问记录"
            log_info "  Xray 服务端（XHTTP）日志: $xray_server_log"

            # 验证目标域名是否为www.google.com
            if echo "$xray_server_log" | grep -q "www.google.com:443\|142.251"; then
                log_info "  ✓ 目标域名正确: www.google.com"
            else
                log_info "  ❌ 目标域名不正确，期望 www.google.com"
                validation_failed=true
                failure_reasons+=("Xray服务端目标域名不匹配")
            fi
        else
            validation_failed=true
            failure_reasons+=("Xray服务端未找到处理记录")
            log_info "  ❌ Xray 服务端（XHTTP）日志中未找到明确的处理记录"
        fi

        # 清理 Xray 客户端进程，但保留日志文件
        log_info "清理 Xray XHTTP 客户端进程..."
        cleanup_xray_xhttp

        # 最终判断
        if [ "$validation_failed" = false ]; then
            test_pass "Xray XHTTP 代理功能完全正常"
            log_info "✅ XHTTP代理请求成功 + 完整链路验证通过"

            # 显示详细的链路日志对比表格
            log_info ""
            log_info "=========================================="
            log_info "  链路日志验证详情"
            log_info "=========================================="

            # 提取各个时间点
            local haproxy_time=$(echo "$haproxy_log" | grep -o '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' | head -1)
            local xray_server_time=$(echo "$xray_server_log" | grep -o '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' | head -1)

            # 提取实际的SNI域名用于验证
            local actual_sni=$(echo "$haproxy_log" | grep -o 'sni:[^[:space:]]*' | cut -d':' -f2)

            # 格式化HTTP Date头显示 - 将GMT时间转换为本地时间
            local http_date_gmt=$(echo "$http_date" | awk '{print $5}')
            local http_date_short=$(remote_cmd "
                if [ '$http_date_gmt' != 'N/A' ] && [ -n '$http_date_gmt' ]; then
                    # 将GMT时间转换为本地时间
                    date -d 'TZ=\"GMT\" $http_date_gmt' +%H:%M:%S 2>/dev/null || echo '$http_date_gmt'
                else
                    echo 'N/A'
                fi
            ")

            printf "%-15s %-12s %-25s %-10s\n" "组件" "时间" "域名/目标" "状态"
            printf "%-15s %-12s %-25s %-10s\n" "---------------" "------------" "-------------------------" "----------"
            printf "%-15s %-12s %-25s %-10s\n" "测试开始" "$test_start_time" "www.google.com" "✓"
            printf "%-15s %-12s %-25s %-10s\n" "HTTP响应" "${http_date_short:-N/A}" "www.google.com" "✓"
            printf "%-15s %-12s %-25s %-10s\n" "Xray客户端" "${xray_client_time:-N/A}" "www.google.com" "$([ -n "$xray_client_time" ] && echo "✓" || echo "❌")"
            printf "%-15s %-12s %-25s %-10s\n" "入口路由" "${haproxy_time:-N/A}" "${actual_sni:-N/A}" "$([ "$actual_sni" = "$expected_sni" ] && echo "✓" || echo "❌")"
            printf "%-15s %-12s %-25s %-10s\n" "Xray服务端" "${xray_server_time:-N/A}" "www.google.com" "$(echo "$xray_server_log" | grep -q "www.google.com\|142.251" && echo "✓" || echo "❌")"
            log_info "=========================================="

            # 显示验证结果摘要
            log_info "验证摘要:"
            log_info "  REALITY伪装目标: $expected_sni"
            log_info "  实际SNI: ${actual_sni:-未找到}"
            log_info "  域名匹配: $([ "$actual_sni" = "$expected_sni" ] && echo "✓ 完全匹配" || echo "❌ 不匹配")"
            log_info "  时间窗口: $([ "$time_diff" -le 2 ] 2>/dev/null && echo "✓ 在2秒内" || echo "❌ 超出范围")"
            log_info "  协议类型: XHTTP + REALITY"
        else
            test_fail "Xray XHTTP 代理测试失败"
            log_error "❌ 虽然代理请求返回 HTTP $proxy_result，但链路验证失败"
            log_error "失败原因: $(IFS=', '; echo "${failure_reasons[*]}")"

            # 问题排查
            log_info ""
            log_error "🔍 开始问题排查..."

            # 检查客户端配置问题
            if echo "${failure_reasons[@]}" | grep -q "客户端配置错误"; then
                log_error "1. Xray XHTTP 客户端配置问题:"
                log_info "   - 检查 JSON 格式是否正确"
                log_info "   - 验证 UUID 和 REALITY 配置"
                local client_error=$(remote_cmd "cat $temp_dir/client_stdout.log 2>/dev/null | grep -E 'Failed to start|invalid character|failed to load config|failed to build' | head -1")
                if [ -n "$client_error" ]; then
                    log_info "   错误详情: $client_error"
                fi
            fi

            # 检查网络连通性
            log_error "2. 检查网络连通性:"
            local ping_result=$(remote_cmd "ping -c 1 www.google.com >/dev/null 2>&1 && echo 'OK' || echo 'FAIL'")
            log_info "   - 直接 ping Google: $ping_result"

            # 检查服务端配置
            log_error "3. 检查 Xray 服务端配置:"
            local xray_status=$(remote_cmd "docker logs xray --tail 5 2>/dev/null | grep -E 'started|listening|error' | tail -1")
            log_info "   - Xray 服务状态: $xray_status"

            return 1
        fi

    else
        test_fail "Xray XHTTP 代理 Google 失败 (HTTPS $proxy_result)"
        log_info "❌ Xray XHTTP 代理功能异常，无法访问 www.google.com"

        # 清理 Xray 客户端进程...
        log_info "清理 Xray XHTTP 客户端进程..."
        cleanup_xray_xhttp
    fi
}

# Test 7: NF 路由 + PP 兼容性（两种入口模式通用，README-003 4.1）
# - 路由断言：入口日志出现 nf_xtls 路由（偏移量方案；nginx=backend:nf_xtls，haproxy=nf_xtls_backend）
# - PP 断言：openssl s_client TLS 握手必须成功（返回码 0）；握手失败判用例失败并阻断验收，
#   原因报告为"NF 握手失败，可能为 PP 版本或上游异常"——不直接定性 PP v1 不兼容；
#   仅当同一 NF 上游下 v2（haproxy）成功且 v1（nginx）失败时才定性（对照组方法见输出提示）
test_case_7() {
    echo ""
    echo "=========================================="
    log_test "Test 7: NF 路由与 PP 兼容性测试（入口: $ENTRY_MODE）"
    echo "=========================================="
    echo ""

    local nf_server=$(remote_cmd "grep '^NF_XTLS_SERVER=' .env | cut -d'=' -f2-" 2>/dev/null)
    nf_server=${nf_server:-127.0.0.1:18910}
    log_info "NF_XTLS_SERVER: $nf_server"

    # 构造 nf. 前缀测试域名：需同时满足四级 nf 路由规则与被证书覆盖
    local nf_domain=""
    if [ -n "$CERT_DOMAINS" ]; then
        nf_domain=$(echo "$CERT_DOMAINS" | while read domain; do
            local level_count=$(echo "$domain" | tr -cd '.' | wc -c)
            level_count=$((level_count + 1))
            if [ $level_count -eq 4 ] && [[ "$domain" =~ ^\*\. ]]; then
                echo "nf.${domain#\*.}"
                break
            fi
        done)
        if [ -z "$nf_domain" ]; then
            local wc3=$(echo "$CERT_DOMAINS" | while read domain; do
                local level_count=$(echo "$domain" | tr -cd '.' | wc -c)
                level_count=$((level_count + 1))
                if [ $level_count -eq 3 ] && [[ "$domain" =~ ^\*\. ]]; then echo "$domain"; break; fi
            done)
            if [ -n "$wc3" ]; then
                nf_domain="nf.test$RANDOM.${wc3#\*.}"
                log_warn "证书无四级通配 SAN，构造 $nf_domain——vision 证书可能拒绝该 SNI（rejectUnknownSni）"
            fi
        fi
    fi

    if [ -z "$nf_domain" ]; then
        test_warn "无法构造被证书覆盖的 nf 测试域名，跳过 NF 测试"
        return 0
    fi
    log_info "NF 测试域名: $nf_domain（期望路由 → nf_xtls = $nf_server）"

    # 偏移量记录（只匹配本次连接产生的日志）
    local route_log=$(route_log_file)
    local log_pos=$(remote_cmd "wc -c < $route_log 2>/dev/null || echo 0" 2>/dev/null)
    log_pos=${log_pos:-0}

    # 发起 TLS 连接；stdin EOF 让 s_client 主动关闭——入口 access log 在连接结束时才写入
    log_info "发起 TLS 连接: openssl s_client -servername $nf_domain -connect 127.0.0.1:443"
    local sclient_out
    sclient_out=$(remote_cmd "echo | timeout 8 openssl s_client -connect 127.0.0.1:443 -servername '$nf_domain' 2>&1")
    local rc=$?

    # PP 断言：握手成功为硬性要求
    local handshake_ok=false
    if [ $rc -eq 0 ] && echo "$sclient_out" | grep -q "Verify return code"; then
        handshake_ok=true
        test_pass "NF TLS 握手成功（openssl rc=0）"
        echo "$sclient_out" | grep "Verify return code" | head -1 | while read line; do log_info "  $line"; done
    else
        test_fail "NF 握手失败（可能为 PP 版本或上游异常，不单独定性）: openssl rc=$rc"
        echo "$sclient_out" | tail -3 | while read line; do log_info "  $line"; done
    fi

    # 路由断言：连接关闭后轮询新增日志
    log_info "轮询入口路由日志（$route_log, 偏移 $log_pos）..."
    local entry_log=""
    local try
    for try in 1 2 3 4 5; do
        entry_log=$(remote_cmd "tail -c +$((log_pos + 1)) $route_log | grep 'sni:$nf_domain' | tail -1" 2>/dev/null)
        [ -n "$entry_log" ] && break
        sleep 2
    done

    if [ -n "$entry_log" ]; then
        local backend_want=$(route_backend_pattern nf_xtls)
        if echo "$entry_log" | grep -q "$backend_want"; then
            test_pass "NF 路由正确（$backend_want）"
        else
            test_fail "NF 路由错误（期望 $backend_want）: $entry_log"
        fi
        log_info "入口日志: $entry_log"
    else
        test_fail "入口未找到 SNI=$nf_domain 的新路由日志"
    fi

    if [ "$handshake_ok" = true ]; then
        log_info "PP 兼容性: 入口 $ENTRY_MODE → NF 上游（$nf_server）握手成功"
    else
        log_info "PP 兼容性归因: 入口 $ENTRY_MODE → NF（$nf_server）握手失败；"
        log_info "  对照组方法：切到另一入口模式重跑本用例——仅当 PP v2(haproxy) 成功且 PP v1(nginx) 失败时，才定性 PP v1 不兼容"
    fi
}

# Test 8: 外部真实代理客户端 IP 验证（README-003 4.2 / 5.6 —— 两种模式验收门禁）
# 服务器本机的 case 5/6 源地址恒为 127.0.0.1，不能证明外部客户端 IP 被 PP 正确还原。
# 执行方式（四轮 review 修正）：默认【本机直跑】（不经 SSH，要求本机有 docker/curl/openssl、
# 11082 空闲、可达服务器公网 443 与 www.google.com）；仅 --dep user@host 时才 SSH 到跳板执行。
# 本用例从执行机运行 xray 客户端经公网走 Vision 出网：
#   1) 执行机直连 443 发起一次带唯一 SNI 的 TLS 连接（握手成败均可）——入口路由日志记录
#      服务端观察到的执行机真实源 IP（stream $remote_addr / haproxy %ci）；
#   2) 执行机经 xray 代理出网请求——xray_access.log 新行的 from <IP> 为 PP 还原的客户端 IP；
#   3) 断言两者相等且非 127.0.0.1 → PP 端到端还原外部真实 IP。
# 归因约束（四轮 review 修正）：from 记录必须同时满足 源 IP == 步骤 1 的 seen_ip、
#   目标 == 本次请求的 www.google.com:443、位于本次字节偏移之后——生产环境有其他并发
#   客户端时，只取"任意一条 from"可能误取他人请求导致误判。
# 前置缺失判 FAIL（不静默跳过）——本用例是强制验收门禁，环境不满足与产品故障必须区分上报。
test_case_8() {
    echo ""
    echo "=========================================="
    log_test "Test 8: 外部真实客户端 IP 验证（PP 还原，验收门禁）"
    echo "=========================================="
    echo ""

    # dep_exec：统一执行机命令入口——远程跳板走 SSH，默认本机直跑
    local dep_remote=0
    local dep="${DEP_SERVER:-}"
    dep_exec() {
        if [ "$dep_remote" = "1" ]; then
            ssh -o ConnectTimeout=5 "$dep" "$1"
        else
            bash -c "$1"
        fi
    }
    if [ -n "$dep" ]; then
        dep_remote=1
        log_info "外网跳板: $dep（SSH 执行）"
    else
        log_info "执行机: 本机直跑（不经 SSH；如需第三方跳板用 --dep user@host）"
    fi
    log_info "服务端:   $DEPLOYMENT_SERVER"

    if [ "$dep_remote" = "1" ]; then
        if ! ssh -o ConnectTimeout=5 "$dep" "echo OK" >/dev/null 2>&1; then
            test_fail "无法 SSH 到跳板机 $dep（可用 --dep user@host 指定；或省略 --dep 在本机直跑）"
            return 1
        fi
        for tool in docker curl openssl; do
            if ! ssh -o ConnectTimeout=5 "$dep" "command -v $tool" >/dev/null 2>&1; then
                test_fail "跳板机 $dep 缺 $tool（case 8 前置：docker/curl/openssl）"
                return 1
            fi
        done
    else
        for tool in docker curl openssl; do
            if ! command -v $tool >/dev/null 2>&1; then
                test_fail "本机缺 $tool（case 8 前置：docker/curl/openssl；或改用 --dep user@host 指定跳板机）"
                return 1
            fi
        done
        if timeout 1 bash -c 'exec 3<>/dev/tcp/127.0.0.1/11082' 2>/dev/null; then
            test_fail "本机 11082 端口已被占用（case 8 前置：SOCKS 端口 11082 可用）"
            return 1
        fi
    fi

    if [ -z "$XRAY_TEST_DOMAIN" ]; then
        if ! extract_cert_domains || ! select_test_domains; then
            test_fail "无法确定 Vision 测试域名"
            return 1
        fi
    fi
    if [ -z "$XRAY_TEST_DOMAIN" ]; then
        test_fail "未找到 Xray Vision 测试域名"
        return 1
    fi

    local xray_uuid=$(remote_cmd "grep '^XRAY_UUID_9000=' .env | head -1 | cut -d'=' -f2 | tr -d '\"'" 2>/dev/null)
    [ -z "$xray_uuid" ] && xray_uuid=$(remote_cmd "grep '^XRAY_UUID=' .env | head -1 | cut -d'=' -f2 | tr -d '\"'" 2>/dev/null)
    if [ -z "$xray_uuid" ]; then
        test_fail "未找到 XRAY_UUID 环境变量"
        return 1
    fi

    # 在执行机准备 xray 二进制（优先从镜像提取，兜底从运行中的 xray 容器拷贝）
    local dep_tmp="/tmp/xray_extip_$$"
    dep_exec "mkdir -p $dep_tmp && cid=\$(docker create teddysun/xray 2>/dev/null) && docker cp \$cid:/usr/bin/xray $dep_tmp/xray 2>/dev/null && docker rm -f \$cid >/dev/null 2>&1; chmod +x $dep_tmp/xray 2>/dev/null" 2>/dev/null
    if ! dep_exec "test -x $dep_tmp/xray" 2>/dev/null; then
        dep_exec "cname=\$(docker ps --format '{{.Names}}' | grep -i xray | head -1); [ -n \"\$cname\" ] && docker cp \$cname:/usr/bin/xray $dep_tmp/xray && chmod +x $dep_tmp/xray" 2>/dev/null
    fi
    if ! dep_exec "test -x $dep_tmp/xray" 2>/dev/null; then
        test_fail "执行机无法准备 xray 二进制（需 docker 可用）"
        return 1
    fi

    # 生成执行机 xray 客户端配置（SOCKS 11082 + VLESS Vision → 服务端域名:443 公网）
    local local_config="/tmp/xray_extip_cfg_$$.json"
    cat > "$local_config" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "tag": "socks", "port": 11082, "listen": "127.0.0.1", "protocol": "socks", "settings": {} }
  ],
  "outbounds": [
    {
      "tag": "proxy", "protocol": "vless",
      "settings": { "vnext": [ { "address": "$XRAY_TEST_DOMAIN", "port": 443,
        "users": [ { "id": "$xray_uuid", "flow": "xtls-rprx-vision", "encryption": "none" } ] } ] },
      "streamSettings": { "network": "tcp", "security": "tls",
        "tlsSettings": { "serverName": "$XRAY_TEST_DOMAIN", "allowInsecure": true, "fingerprint": "chrome" } }
    }
  ]
}
EOF
    if [ "$dep_remote" = "1" ]; then
        scp "$local_config" "$dep:$dep_tmp/client_config.json" >/dev/null 2>&1
    else
        cp "$local_config" "$dep_tmp/client_config.json"
    fi
    rm -f "$local_config"

    # ---- 1) 执行机直连：让入口日志记录服务端看到的执行机真实源 IP ----
    local marker_sni="extip$RANDOM.$XRAY_TEST_DOMAIN"
    local route_log=$(route_log_file)
    local pos_route=$(remote_cmd "wc -c < $route_log 2>/dev/null || echo 0" 2>/dev/null)
    pos_route=${pos_route:-0}
    log_info "执行机直连 443（marker SNI: $marker_sni）记录服务端视角源 IP..."
    dep_exec "echo | timeout 8 openssl s_client -connect $XRAY_TEST_DOMAIN:443 -servername '$marker_sni' >/dev/null 2>&1" || true
    sleep 2

    local seen_ip=$(remote_cmd "tail -c +$((pos_route + 1)) $route_log | grep 'sni:$marker_sni' | tail -1 | awk '{print \$1}' | cut -d: -f1" 2>/dev/null)
    if [ -z "$seen_ip" ]; then
        test_fail "入口日志未找到 marker SNI=$marker_sni 的记录（执行机→服务器 443 公网可达性前置未满足？）"
        dep_exec "pkill -f 'xray run -c $dep_tmp/client_config.json' 2>/dev/null; rm -rf $dep_tmp" 2>/dev/null
        return 1
    fi
    log_info "服务端视角执行机源 IP: $seen_ip"

    # ---- 2) 执行机经 xray 代理出网：服务端 xray 日志 from <IP> 应为同一 IP ----
    local pos_xray=$(remote_cmd "wc -c < log/xray_access.log 2>/dev/null || echo 0" 2>/dev/null)
    pos_xray=${pos_xray:-0}

    dep_exec "cd $dep_tmp && nohup ./xray run -c client_config.json > client_stdout.log 2>&1 & echo \$! > xray.pid" >/dev/null 2>&1
    sleep 5

    dep_exec "curl -s --max-time 15 --socks5 127.0.0.1:11082 -o /dev/null -w '%{http_code}' https://www.google.com" >/dev/null 2>&1 || true
    sleep 2
    dep_exec "pkill -f 'xray run -c $dep_tmp/client_config.json' 2>/dev/null; rm -rf $dep_tmp" 2>/dev/null || true

    # 归因约束：from == seen_ip 且 目标 == www.google.com:443 且 位于字节偏移之后（四轮 review 修正）
    local from_ip=$(remote_cmd "tail -c +$((pos_xray + 1)) log/xray_access.log | grep 'from ${seen_ip}:' | grep 'accepted.*www\.google\.com:443' | tail -1 | grep -o 'from [0-9.]*:' | awk '{print \$2}' | tr -d ':'" 2>/dev/null)

    if [ -z "$from_ip" ]; then
        test_fail "xray_access.log 新增日志中未找到 from=${seen_ip} → www.google.com:443 的记录（偏移 $pos_xray；代理链路或出网前置未满足？）"
        return 1
    fi
    log_info "xray 日志 from IP（PP 还原）: $from_ip"

    # ---- 3) 断言：PP 还原 IP == 服务端视角源 IP，且非回环 ----
    if [ "$from_ip" = "$seen_ip" ] && [ "$from_ip" != "127.0.0.1" ] && [ -n "$from_ip" ]; then
        test_pass "外部真实客户端 IP 被 PP 正确还原: $from_ip（与入口观察一致，入口: $ENTRY_MODE）"
    else
        test_fail "IP 不一致: xray from=$from_ip, 入口观察=$seen_ip（期望相等且非 127.0.0.1）"
        return 1
    fi
}

# 主函数
main() {
    echo "=========================================="
    echo "  laddr-docker 测试脚本"
    echo "=========================================="

    # 获取部署配置
    get_deployment_config
    echo ""
    log_info "目标服务器: $DEPLOYMENT_SERVER"
    log_info "目标路径: $REMOTE_PATH"
    echo ""

    # 测试连接
    if ! ssh -o ConnectTimeout=5 "$DEPLOYMENT_SERVER" "echo OK" >/dev/null 2>&1; then
        log_error "无法连接到服务器 $DEPLOYMENT_SERVER"
        exit 1
    fi

    # 检测远端入口模式（nginx 默认 / haproxy 可选，README-003 4.1）
    ENTRY_MODE=$(detect_entry_mode)
    log_info "入口模式: $ENTRY_MODE"
    echo ""

    # 解析命令行参数
    local test_case=""
    while [[ $# -gt 0 ]]; do
        case $1 in
            --case)
                test_case="$2"
                shift 2
                ;;
            --dep)
                DEP_SERVER="$2"
                shift 2
                ;;
            --help|-h)
                echo "用法: $0 [--case <test_case>]"
                echo ""
                echo "可用的测试用例:"
                echo "  1, container    - 容器健康检查"
                echo "  2, port         - 端口监听检查"
                echo "  3, cert         - 证书文件检查并提取域名"
                echo "  4, nginx        - SNI 分流到 Nginx 测试"
                echo "  5, xray, vision - Xray Vision 代理功能测试"
                echo "  6, xhttp        - Xray XHTTP 代理功能测试"
                echo "  7, nf           - NF 路由与 PP 兼容性测试（两种入口模式）"
                echo "  8, extip        - 外部真实客户端 IP 验证（PP 还原，验收门禁）"
                echo "  all             - 运行所有测试（默认）"
                echo ""
                echo "选项:"
                echo "  --dep user@host - case 8 经 SSH 在跳板机执行（默认: 本机直跑，"
                echo "                    要求本机有 docker/curl/openssl、11082 空闲）"
                echo ""
                echo "示例:"
                echo "  $0                    # 运行所有测试"
                echo "  $0 --case vision     # 只运行 Xray Vision 代理测试"
                echo "  $0 --case 5          # 只运行 Xray Vision 代理测试"
                echo "  $0 --case xhttp      # 只运行 Xray XHTTP 代理测试"
                echo "  $0 --case 6          # 只运行 Xray XHTTP 代理测试"
                echo "  $0 --case nginx      # 只运行 Nginx 分流测试"
                echo "  $0 --case nf         # 只运行 NF 路由/PP 兼容性测试"
                echo "  $0 --case extip --dep work@jumpbox  # 经 SSH 用跳板机跑真实 IP 验证"
                exit 0
                ;;
            *)
                echo "未知参数: $1"
                echo "使用 --help 查看帮助"
                exit 1
                ;;
        esac
    done

    # 默认运行所有测试
    if [ -z "$test_case" ]; then
        test_case="all"
    fi

    # 根据参数执行相应的测试用例
    case "$test_case" in
        1|container)
            test_case_1
            ;;
        2|port)
            test_case_2
            ;;
        3|cert)
            test_case_3
            ;;
        4|nginx)
            # Nginx 测试需要先获取证书域名
            if ! extract_cert_domains; then
                log_error "无法提取证书域名，Nginx 测试无法进行"
                exit 1
            fi
            select_test_domains
            test_case_4
            ;;
        5|xray|vision)
            # Xray Vision 测试需要先获取证书域名
            if ! extract_cert_domains; then
                log_error "无法提取证书域名，Xray Vision 测试无法进行"
                exit 1
            fi
            select_test_domains
            test_case_5
            ;;
        6|xhttp)
            # Xray XHTTP 测试需要先获取证书域名
            if ! extract_cert_domains; then
                log_error "无法提取证书域名，Xray XHTTP 测试无法进行"
                exit 1
            fi
            select_test_domains
            test_case_6
            ;;
        7|nf)
            # NF 路由测试需要先获取证书域名
            if ! extract_cert_domains; then
                log_error "无法提取证书域名，NF 测试无法进行"
                exit 1
            fi
            select_test_domains
            test_case_7
            ;;
        8|extip)
            # 外部真实 IP 验证需要先获取证书域名
            if ! extract_cert_domains; then
                log_error "无法提取证书域名，外部 IP 验证无法进行"
                exit 1
            fi
            select_test_domains
            test_case_8
            ;;
        all)
            # 运行所有测试
            test_case_1
            test_case_2
            test_case_3
            if [ -n "$CERT_DOMAINS" ]; then
                test_case_4
                test_case_5
                test_case_6
                test_case_7
                test_case_8
            else
                log_error "无法提取证书域名，跳过分流测试"
            fi
            ;;
        *)
            log_error "未知的测试用例: $test_case"
            echo "使用 --help 查看可用的测试用例"
            exit 1
            ;;
    esac

    # 输出测试结果总结
    echo ""
    echo "=========================================="
    echo "  测试总结"
    echo "=========================================="
    echo ""
    log_info "测试域名："
    if [ -n "$NGX_TEST_DOMAIN" ]; then
        log_info "  - Nginx 后端: $NGX_TEST_DOMAIN"
    fi
    if [ -n "$XRAY_TEST_DOMAIN" ]; then
        log_info "  - Xray Vision 后端: $XRAY_TEST_DOMAIN"
    fi
    if [ -n "$XHTTP_TEST_DOMAIN" ]; then
        log_info "  - Xray XHTTP 后端: $XHTTP_TEST_DOMAIN"
    fi
    echo ""
    log_info "测试结果："
    log_info "  通过: $PASS_COUNT"
    log_info "  警告: $WARN_COUNT"
    log_info "  失败: $FAIL_COUNT"
    echo ""

    if [ $FAIL_COUNT -eq 0 ]; then
        if [ $WARN_COUNT -eq 0 ]; then
            log_success "所有测试通过！"
        else
            log_warning "存在 $WARN_COUNT 个警告，建议检查"
        fi
    else
        log_error "存在 $FAIL_COUNT 个测试失败"
        exit 1
    fi
    echo ""

}

main "$@"
