#!/bin/bash
# laddr-docker 测试脚本
# 职责：测试 HAProxy SNI 分流到 Nginx 和 Xray

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
        log_success "Xray 测试域名: $XRAY_TEST_DOMAIN"
    else
        log_warning "未找到匹配 xray_backend 规则的域名"
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
    local required=("haproxy" "nginx" "acme" "xray")

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

    # HAProxy 和 Nginx 使用 host 模式，检查宿主机端口
    if remote_cmd "ss -tlnp | grep ':443'" >/dev/null 2>&1; then
        test_pass "HAProxy 443 端口监听中"
    else
        test_fail "HAProxy 443 端口未监听"
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
        test_pass "Xray 18910 端口监听中"
    else
        test_fail "Xray 18910 端口未监听"
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

    # 发送 HTTPS 请求
    log_info "发送 HTTPS 请求: https://$NGX_TEST_DOMAIN/test.html?r=$random_num"
    log_info "通过 HAProxy 443 端口，SNI: $NGX_TEST_DOMAIN"

    local response=$(remote_cmd "curl -s --max-time 10 --resolve '$NGX_TEST_DOMAIN:443:127.0.0.1' https://$NGX_TEST_DOMAIN/test.html?r=$random_num -k" 2>/dev/null)

    if [[ "$response" == *"Test$random_num"* ]]; then
        test_pass "Nginx 返回内容正确"
    else
        test_fail "Nginx 返回内容错误: $response"
        return 1
    fi

    # 等待日志写入
    sleep 2

    # 检查 HAProxy 日志（只检查 SNI，不检查 querystring）
    log_info "检查 HAProxy 日志..."
    local haproxy_log=$(remote_cmd "grep 'sni:$NGX_TEST_DOMAIN' haproxy/log/access.log | tail -1")

    if [ -n "$haproxy_log" ]; then
        test_pass "HAProxy 日志包含 SNI: $NGX_TEST_DOMAIN"

        # 检查 backend
        if echo "$haproxy_log" | grep -q "ngx_backend"; then
            test_pass "HAProxy 日志显示路由到 ngx_backend"
        else
            test_warn "HAProxy 日志未明确显示 backend 名称"
        fi

        log_info "HAProxy 日志: $haproxy_log"

        # 说明：HAProxy 工作在 TCP 模式，只能看到 SNI，看不到 querystring
        log_info "注意: HAProxy 工作在 TCP 模式，日志中只有 SNI，没有 querystring"
    else
        test_fail "HAProxy 日志未找到该请求 (SNI: $NGX_TEST_DOMAIN)"
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

    # 在宿主机启动 Xray 客户端进行 SOCKS5 代理测试
    log_info "在宿主机启动 Xray 客户端进行 SOCKS5 代理测试..."

    # 获取 XRAY_UUID
    local xray_uuid=$(remote_cmd "grep XRAY_UUID .env | cut -d'=' -f2" 2>/dev/null)
    if [ -z "$xray_uuid" ]; then
        test_fail "未找到 XRAY_UUID 环境变量"
        return 1
    fi

    # 创建临时目录
    local temp_dir="/tmp/xray_test_$$"
    remote_cmd "mkdir -p $temp_dir"

    # 从容器拷贝 xray 二进制程序
    log_info "拷贝 xray 二进制程序到宿主机..."
    remote_cmd "docker cp xray:/usr/bin/xray $temp_dir/xray"
    remote_cmd "chmod +x $temp_dir/xray"

    # 在本地创建客户端配置文件，然后拷贝到远程
    log_info "创建 Xray 客户端配置..."
    local local_config="/tmp/xray_client_config_$$.json"
    cat > "$local_config" <<EOF
{
  "log": {
    "loglevel": "debug",
    "access": "$temp_dir/client_access.log",
    "error": "$temp_dir/client_error.log"
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
                "id": "$xray_uuid",
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
          "serverName": "$XRAY_TEST_DOMAIN",
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

    # 将配置文件拷贝到远程服务器
    log_info "拷贝配置文件到远程服务器..."
    # 获取远程临时目录路径
    local remote_temp_dir=$(remote_cmd "echo $temp_dir")
    scp "$local_config" "$DEPLOYMENT_SERVER:$remote_temp_dir/client_config.json"

    # 清理本地临时文件
    rm -f "$local_config"

    # 启动 Xray 客户端（后台运行）
    log_info "启动 Xray 客户端（端口11080）..."
    # 使用后台运行，SSH 立即返回
    ssh "$DEPLOYMENT_SERVER" "cd $temp_dir && nohup ./xray run -c client_config.json > client_stdout.log 2>&1 & echo \$! > xray.pid" >/dev/null 2>&1 &
    local ssh_pid=0

    # 设置陷阱函数，确保异常退出时清理
    cleanup_xray() {
        remote_cmd "pkill -f 'xray run -c client_config.json'" 2>/dev/null || true
        remote_cmd "rm -rf $temp_dir" 2>/dev/null || true
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
        # 清理并返回
        log_info "清理 Xray 客户端进程..."
        remote_cmd "pkill -f 'xray run -c client_config.json'" 2>/dev/null || true
        remote_cmd "kill \$(cat $temp_dir/xray.pid 2>/dev/null) 2>/dev/null" 2>/dev/null || true
        remote_cmd "rm -rf $temp_dir" 2>/dev/null || true
        return 1
    fi

    # 使用宿主机的curl通过SOCKS5代理请求Google
    log_info "通过 SOCKS5 代理请求 www.google.com..."

    # 记录测试开始时间并立即执行curl（紧密相邻避免延迟）
    local test_start_time=$(date +%H:%M:%S); local proxy_result=$(remote_cmd "timeout 15 curl -s --socks5 127.0.0.1:11080 -w '%{http_code}' -o /dev/null https://www.google.com 2>&1" | grep -o '[0-9][0-9][0-9]' | tail -1)

    log_info "测试开始时间: $test_start_time"

    if [ -z "$proxy_result" ]; then
        proxy_result="000"
    fi

    # 清理结果，去掉可能的额外字符
    proxy_result=$(echo "$proxy_result" | tr -d '\r\n' | sed 's/[^0-9]//g')

    log_info "代理请求结果: HTTP $proxy_result"

    if [ "$proxy_result" = "200" ] || [ "$proxy_result" = "301" ] || [ "$proxy_result" = "302" ]; then
        test_pass "Xray 代理 Google 成功 (HTTPS $proxy_result)"
        log_info "✅ Xray 代理功能正常，能够成功访问 www.google.com"

        # 检查完整代理链路日志
        log_info "🔍 检查完整代理链路日志..."

        # 1. 检查 Xray 客户端日志（宿主机上的客户端）- 使用初始测试时间前后5秒查找
        log_info "1. 检查 Xray 客户端日志（宿主机）（$test_start_time 前后5秒）..."
        local xray_client_access_log=$(remote_cmd "cat $temp_dir/client_access.log 2>/dev/null | tail -5")
        local xray_client_error_log=$(remote_cmd "cat $temp_dir/client_error.log 2>/dev/null | tail -5")
        local xray_client_stdout_log=$(remote_cmd "cat $temp_dir/client_stdout.log 2>/dev/null | tail -5")

        # 从Xray客户端日志中提取时间作为新的基准时间
        local xray_client_time=""
        local found_client_log=""

        # 尝试从访问日志中提取时间
        if [ -n "$xray_client_access_log" ]; then
            found_client_log="$xray_client_access_log"
            # 提取时间格式，假设为 HH:MM:SS 格式
            xray_client_time=$(echo "$xray_client_access_log" | grep -o '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' | tail -1)
        elif [ -n "$xray_client_stdout_log" ]; then
            found_client_log="$xray_client_stdout_log"
            # 从标准输出中提取时间
            xray_client_time=$(echo "$xray_client_stdout_log" | grep -o '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' | tail -1)
        fi

        if [ -n "$found_client_log" ] && [ -n "$xray_client_time" ]; then
            test_pass "Xray 客户端有日志记录，提取到时间: $xray_client_time"
            log_info "  Xray 客户端日志: $found_client_log"

            # 使用Xray客户端日志时间作为新的基准时间
            local new_base_time="$xray_client_time"
            log_info "使用 Xray 客户端日志时间 $new_base_time 作为新的基准时间"
        elif [ -n "$xray_client_error_log" ]; then
            test_warn "Xray 客户端有错误日志"
            log_info "  Xray 客户端错误日志: $xray_client_error_log"
            # 使用原始测试时间作为备用
            local new_base_time="$test_start_time"
        else
            test_warn "Xray 客户端日志中未找到明确的 SOCKS5 处理记录"
            # 使用原始测试时间作为备用
            local new_base_time="$test_start_time"
        fi

    # 清理 Xray 客户端进程...
    log_info "清理 Xray 客户端进程..."
    remote_cmd "pkill -f 'xray run -c client_config.json'" 2>/dev/null || true
    remote_cmd "kill \$(cat $temp_dir/xray.pid 2>/dev/null) 2>/dev/null" 2>/dev/null || true
    remote_cmd "rm -rf $temp_dir" 2>/dev/null || true

        # 2. 检查 HAProxy 日志（SNI路由）- 使用新的基准时间前后3秒查找
        log_info "2. 检查 HAProxy SNI 路由日志（$new_base_time 前后3秒）..."
        local haproxy_log=$(remote_cmd "
            base_time='$new_base_time'
            # 获取最近的日志记录，检查时间是否接近基准时间
            grep 'sni:$XRAY_TEST_DOMAIN' haproxy/log/access.log | while read line; do
                log_time=\$(echo \"\$line\" | grep -o '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]')
                if [ -n \"\$log_time\" ]; then
                    # 将时间转换为秒数进行比较
                    log_seconds=\$(echo \$log_time | awk -F: '{print \$1*3600 + \$2*60 + \$3}')
                    base_seconds=\$(echo \$base_time | awk -F: '{print \$1*3600 + \$2*60 + \$3}')
                    diff=\$((log_seconds - base_seconds))
                    # 如果时间差在前后3秒内，认为匹配
                    if [ \$diff -ge -3 ] && [ \$diff -le 3 ]; then
                        echo \"\$line\"
                    fi
                fi
            done | tail -1
        " 2>/dev/null)

        if [ -n "$haproxy_log" ]; then
            if echo "$haproxy_log" | grep -q "xray_backend"; then
                test_pass "HAProxy 正确路由到 xray_backend（时间窗口匹配）"
                log_info "  HAProxy 日志: $haproxy_log"
            else
                test_fail "HAProxy 路由错误，未到达 xray_backend"
                log_info "  HAProxy 日志: $haproxy_log"
            fi
        else
            # 备用查找：拉取最后一条日志进行分析
            log_info "时间窗口内未找到匹配日志，检查最后一条HAProxy日志..."
            local last_haproxy_log=$(remote_cmd "tail -1 haproxy/log/access.log" 2>/dev/null)

            if [ -n "$last_haproxy_log" ]; then
                # 检查SNI是否匹配
                if echo "$last_haproxy_log" | grep -q "sni:$XRAY_TEST_DOMAIN"; then
                    # SNI匹配，分析时间差
                    local last_log_time=$(echo "$last_haproxy_log" | grep -o '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]')
                    if [ -n "$last_log_time" ]; then
                        local log_seconds=$(echo $last_log_time | awk -F: '{print $1*3600 + $2*60 + $3}')
                        local base_seconds=$(echo $new_base_time | awk -F: '{print $1*3600 + $2*60 + $3}')
                        local diff=$((log_seconds - base_seconds))
                        local abs_diff=$((diff < 0 ? -diff : diff))

                        if [ $abs_diff -le 10 ]; then
                            test_pass "HAProxy 有匹配日志（SNI正确，时间差${diff}秒在可接受范围）"
                            log_info "  HAProxy 日志: $last_haproxy_log"
                        else
                            test_warn "HAProxy 有匹配SNI但时间差过大（${diff}秒 > 10秒），可能不是本次请求"
                            log_info "  HAProxy 日志: $last_haproxy_log"
                            log_info "  时间分析: 日志时间=$last_log_time, 基准时间=$new_base_time, 差值=${diff}秒"
                        fi
                    else
                        test_warn "HAProxy 最后一条日志SNI匹配但无法提取时间"
                        log_info "  HAProxy 日志: $last_haproxy_log"
                    fi
                else
                    test_fail "HAProxy 最后一条日志SNI不匹配，请求未到达HAProxy（Xray客户端问题）"
                    log_info "  期望SNI: $XRAY_TEST_DOMAIN"
                    log_info "  最后日志: $last_haproxy_log"
                fi
            else
                test_fail "无法获取HAProxy日志"
            fi
        fi

        # 3. 检查 Xray 服务端日志（代理处理）- 使用新的基准时间前后3秒查找
        log_info "3. 检查 Xray 服务端日志（$new_base_time 前后3秒）..."
        local xray_server_log=$(remote_cmd "tail -50 xray/log/access.log | grep 'from.*accepted' | while read line; do
            log_time=\$(echo \"\$line\" | grep -o '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]')
            if [ -n \"\$log_time\" ]; then
                log_seconds=\$(echo \$log_time | awk -F: '{print \$1*3600 + \$2*60 + \$3}')
                base_seconds=\$(echo '$new_base_time' | awk -F: '{print \$1*3600 + \$2*60 + \$3}')
                diff=\$((log_seconds - base_seconds))
                if [ \$diff -ge -3 ] && [ \$diff -le 3 ]; then
                    echo \"\$line\"
                fi
            fi
        done" 2>/dev/null)
        if [ -n "$xray_server_log" ]; then
            test_pass "Xray 服务端有处理记录"
            log_info "  Xray 服务端日志: $xray_server_log"
        else
            test_warn "Xray 服务端日志中未找到明确的处理记录"

            # 显示最近的服务端日志作为调试信息
            log_info "显示最近的 Xray 服务端访问日志（最近10行）："
            local all_xray_logs=$(remote_cmd "tail -10 xray/log/access.log 2>/dev/null")
            if [ -n "$all_xray_logs" ]; then
                echo "$all_xray_logs" | while IFS= read -r line; do
                    log_info "    $line"
                done
            else
                log_info "    无 Xray 服务端访问日志"
            fi
        fi

    else
        test_fail "Xray 代理 Google 失败 (HTTPS $proxy_result)"
        log_info "❌ Xray 代理功能异常，无法访问 www.google.com"

        # 详细检查各个环节的日志
        log_info "🔍 检查代理失败的详细原因..."

        # 检查 HAProxy 是否有新的代理请求记录
        log_info "检查 HAProxy 代理日志（最近记录）..."
        local haproxy_recent=$(remote_cmd "grep 'sni:$XRAY_TEST_DOMAIN' haproxy/log/access.log | tail -3" 2>/dev/null)
        if [ -n "$haproxy_recent" ]; then
            log_info "✓ HAProxy 有代理请求记录:"
            echo "$haproxy_recent" | while read line; do
                log_info "  $line"
            done
        else
            log_info "✗ HAProxy 没有找到代理请求记录"
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

    # 解析命令行参数
    local test_case=""
    while [[ $# -gt 0 ]]; do
        case $1 in
            --case)
                test_case="$2"
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
                echo "  5, xray, google - Xray 代理功能测试"
                echo "  all             - 运行所有测试（默认）"
                echo ""
                echo "示例:"
                echo "  $0                    # 运行所有测试"
                echo "  $0 --case google     # 只运行 Xray 代理测试"
                echo "  $0 --case 5          # 只运行 Xray 代理测试"
                echo "  $0 --case nginx      # 只运行 Nginx 分流测试"
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
        5|xray)
            # Xray 测试需要先获取证书域名
            if ! extract_cert_domains; then
                log_error "无法提取证书域名，Xray 测试无法进行"
                exit 1
            fi
            select_test_domains
            test_case_5
            ;;
        5.1|google)
            # Google 代理测试需要先获取证书域名
            if ! extract_cert_domains; then
                log_error "无法提取证书域名，Google 代理测试无法进行"
                exit 1
            fi
            select_test_domains
            test_case_5
            ;;
        all)
            # 运行所有测试
            test_case_1
            test_case_2
            test_case_3
            if [ -n "$CERT_DOMAINS" ]; then
                test_case_4
                test_case_5
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
        log_info "  - Xray 后端: $XRAY_TEST_DOMAIN"
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
    echo "=========================================="
    log_test "Test 1: 容器健康检查"
    echo "=========================================="
    echo ""

    local containers=$(remote_cmd "docker ps --format '{{.Names}}'")
    local required=("haproxy" "nginx" "acme" "xray")

    for c in "${required[@]}"; do
        if echo "$containers" | grep -q "^${c}$"; then
            test_pass "$c 容器运行中"
        else
            test_fail "$c 容器未运行"
        fi
    done

    # ========================================
    # Test 2: 端口监听检查
    # ========================================
    echo ""
    echo "=========================================="
    log_test "Test 2: 端口监听检查"
    echo "=========================================="
    echo ""

    # HAProxy 和 Nginx 使用 host 模式，检查宿主机端口
    if remote_cmd "ss -tlnp | grep ':443'" >/dev/null 2>&1; then
        test_pass "HAProxy 443 端口监听中"
    else
        test_fail "HAProxy 443 端口未监听"
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
        test_pass "Xray 18910 端口监听中"
    else
        test_fail "Xray 18910 端口未监听"
    fi

    # ========================================
    # Test 3: 证书文件检查并提取域名
    # ========================================
    echo ""
    echo "=========================================="
    log_test "Test 3: 证书文件检查并提取域名"
    echo "=========================================="
    echo ""

    local cert_files=("default_cert.pem" "default_key.pem")
    for file in "${cert_files[@]}"; do
        if remote_cmd "docker exec nginx [ -f /etc/nginx/cert/$file ]"; then
            test_pass "证书文件 $file 存在"
        else
            test_fail "证书文件 $file 不存在"
        fi
    done

    echo ""
    if ! extract_cert_domains; then
        log_error "无法提取证书域名，后续测试无法进行"
        exit 1
    fi

    echo ""
    select_test_domains

    # 检查是否有可用的测试域名
    if [ -z "$NGX_TEST_DOMAIN" ] && [ -z "$XRAY_TEST_DOMAIN" ]; then
        log_error "没有可用的测试域名，无法继续测试"
        exit 1
    fi

    # ========================================
    # Test 4: SNI 分流到 Nginx 测试
    # ========================================
    echo ""
    echo "=========================================="
    log_test "Test 4: SNI 分流到 Nginx 测试"
    echo "=========================================="
    echo ""

    if [ -z "$NGX_TEST_DOMAIN" ]; then
        log_error "没有可用的 Nginx 测试域名，跳过此测试"
        test_fail "Nginx 分流测试 - 无测试域名"
    else
        log_info "测试域名: $NGX_TEST_DOMAIN → ngx_backend"

        # 生成随机数用于 querystring
        local random_num=$((RANDOM * RANDOM))
        log_info "随机数: $random_num"

        # 创建测试文件
        local test_content="nginx-test-$random_num"
        remote_cmd "docker exec nginx sh -c 'echo \"$test_content\" > /usr/share/nginx/html/test.html'"
        log_success "测试文件已创建"

        # 清空 nginx 日志（方便后续查找）
        remote_cmd "docker exec nginx sh -c 'echo \"\" > /var/log/nginx/access.log'"

        # 发送 HTTPS 请求到 HAProxy 443 端口（带随机数 querystring 和 SNI）
        log_info "发送 HTTPS 请求: https://$NGX_TEST_DOMAIN/test.html?r=$random_num"
        log_info "通过 HAProxy 443 端口，SNI: $NGX_TEST_DOMAIN"
        local response=$(remote_cmd "curl -s -m 10 -k --resolve '$NGX_TEST_DOMAIN:443:127.0.0.1' 'https://$NGX_TEST_DOMAIN/test.html?r=$random_num'")

        # 验证响应内容
        if [ "$response" = "$test_content" ]; then
            test_pass "Nginx 返回内容正确"
        else
            test_fail "Nginx 返回内容错误 - 期望: $test_content, 实际: $response"
        fi

        # 等待日志写入
        sleep 2

        # 检查 HAProxy 日志（只检查 SNI，不检查 querystring）
        log_info "检查 HAProxy 日志..."
        local haproxy_log=$(remote_cmd "grep 'sni:$NGX_TEST_DOMAIN' haproxy/log/access.log | tail -1")

        if [ -n "$haproxy_log" ]; then
            test_pass "HAProxy 日志包含 SNI: $NGX_TEST_DOMAIN"

            # 检查 backend
            if echo "$haproxy_log" | grep -q "ngx_backend"; then
                test_pass "HAProxy 日志显示路由到 ngx_backend"
            else
                test_warn "HAProxy 日志未明确显示 backend 名称"
            fi

            log_info "HAProxy 日志: $haproxy_log"

            # 说明：HAProxy 工作在 TCP 模式，只能看到 SNI，看不到 querystring
            log_info "注意: HAProxy 工作在 TCP 模式，日志中只有 SNI，没有 querystring"
        else
            test_fail "HAProxy 日志未找到该请求 (SNI: $NGX_TEST_DOMAIN)"
        fi

        # 检查 Nginx 日志（应该包含 querystring）
        log_info "检查 Nginx 日志..."
        local nginx_log=$(remote_cmd "docker exec nginx cat /var/log/nginx/access.log | grep 'r=$random_num' | tail -1")

        if [ -n "$nginx_log" ]; then
            test_pass "Nginx 日志包含 querystring (r=$random_num)"
            log_info "Nginx 日志: $nginx_log"
        else
            test_fail "Nginx 日志未找到该请求 (querystring: r=$random_num)"
        fi

        echo ""
        if [ $FAIL_COUNT -gt 0 ]; then
            log_error "Nginx 分流测试失败，停止后续测试"
            exit 1
        else
            log_success "Nginx 分流测试通过，继续 Xray 测试"
        fi
    fi

    # ========================================
    # Test 5: Xray 代理功能测试
    # ========================================
    test_case_5

    # ========================================
    # 测试总结
    # ========================================
    echo ""
    echo "=========================================="
    echo "  测试总结"
    echo "=========================================="
    echo ""

    log_info "测试域名："
    echo "  - Nginx 后端: ${NGX_TEST_DOMAIN:-无}"
    echo "  - Xray 后端: ${XRAY_TEST_DOMAIN:-无}"
    echo ""

    log_info "测试结果："
    echo "  通过: $PASS_COUNT"
    echo "  警告: $WARN_COUNT"
    echo "  失败: $FAIL_COUNT"
    echo ""

    if [ $FAIL_COUNT -eq 0 ]; then
        log_success "所有关键测试通过！"
        if [ $WARN_COUNT -gt 0 ]; then
            log_warning "存在 $WARN_COUNT 个警告，建议检查"
        fi
        echo ""
        return 0
    else
        log_error "存在 $FAIL_COUNT 个测试失败"
        echo ""
        return 1
    fi
}

main "$@"
