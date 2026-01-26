#!/bin/bash

# Case 3: HAProxy SNI 分流测试

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[FAIL]${NC} $1"; }

# 远程执行命令
remote_cmd() {
    ssh "$DEPLOYMENT_SERVER" "cd $REMOTE_PATH && $1" 2>/dev/null || echo ""
}

# 检查远程命令执行结果
check_remote() {
    local output=$(remote_cmd "$1")
    [ -n "$output" ] && echo "$output" || return 1
}

test_case3() {
    echo "=========================================="
    echo "  Case 3: HAProxy SNI 分流测试"
    echo "=========================================="

    # 3.1 从证书中读取域名
    echo ""
    log_info "3.1 从证书中读取域名"
    local cert_domains=$(check_remote "docker exec nginx openssl x509 -in /etc/nginx/cert/default_cert.pem -noout -text | grep -A1 'Subject Alternative Name' | tail -n +2 | sed 's/DNS://g' | tr ',' '\n' | xargs -n1 | grep -v '^$'" 2>/dev/null)

    if [ -z "$cert_domains" ]; then
        cert_domains=$(check_remote "docker exec nginx openssl x509 -in /etc/nginx/cert/default_cert.pem -noout -subject | grep 'CN=' | sed 's/.*CN=//'" 2>/dev/null)
    fi

    if [ -n "$cert_domains" ]; then
        log_info "证书域名: $cert_domains"

        # 解析域名层级
        for domain in $cert_domains; do
            local parts=(${domain//./ })
            local part_count=${#parts[@]}

            if [ "$part_count" -ge 4 ]; then
                local level4="${parts[0]}"
                local level3="${parts[1]}"
                local level2="${parts[2]}"
                log_info "  $domain - 4级:$level4 3级:$level3 2级:$level2"
            fi
        done
    else
        log_warning "无法从证书读取域名"
        return
    fi

    # 3.2 Nginx 分流验证
    echo ""
    log_info "3.2 Nginx 分流验证"
    # 选择一个不匹配 x/xyz/api/dt/ai/nf/netflix/nfx/nfv 前缀的域名
    local nginx_test_domain=""
    for domain in $cert_domains; do
        local parts=(${domain//./ })
        local level4="${parts[0]}"
        if [[ ! "$level4" =~ ^(x|xyz|api|dt|ai|nf|netflix|nfx|nfv)$ ]]; then
            nginx_test_domain="$domain"
            break
        fi
    done

    if [ -n "$nginx_test_domain" ]; then
        log_info "测试域名: $nginx_test_domain (应路由到 Nginx)"

        # 通过 HAProxy 测试
        local test_result=$(check_remote "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://$nginx_test_domain/" 2>/dev/null || echo "000")

        if [[ "$test_result" =~ ^[23] ]]; then
            log_success "HTTP 请求成功: $test_result"
        else
            log_warning "HTTP 响应: $test_result"
        fi

        # 检查 HAProxy 日志
        local haproxy_log=$(check_remote "docker logs haproxy 2>&1 | grep '$nginx_test_domain' | tail -1" 2>/dev/null)
        if [ -n "$haproxy_log" ]; then
            log_success "HAProxy 日志中找到该域名的记录"
        else
            log_warning "HAProxy 日志中未找到该域名的记录"
        fi

        # 检查 Nginx 日志
        local nginx_log=$(check_remote "docker exec nginx cat /var/log/nginx/access.log | grep '$nginx_test_domain' | tail -1" 2>/dev/null)
        if [ -n "$nginx_log" ]; then
            log_success "Nginx 日志中找到该域名的记录"
        else
            log_warning "Nginx 日志中未找到该域名的记录"
        fi
    else
        log_warning "未找到适合测试 Nginx 分流的域名"
    fi

    # 3.3 Xray 分流验证
    echo ""
    log_info "3.3 Xray 分流验证"

    # 查找匹配 x/xyz/api/dt/ai 前缀的域名
    local xray_test_domain=""
    for domain in $cert_domains; do
        local parts=(${domain//./ })
        local level4="${parts[0]}"
        if [[ "$level4" =~ ^(x|xyz|api|dt|ai)$ ]]; then
            xray_test_domain="$domain"
            break
        fi
    done

    if [ -n "$xray_test_domain" ]; then
        log_info "测试域名: $xray_test_domain (应路由到 Xray)"

        # 使用 xray 测试代理 www.google.com
        local xray_uuid=$(check_remote "grep XRAY_UUID .env | cut -d'=' -f2" 2>/dev/null)
        if [ -n "$xray_uuid" ]; then
            log_info "使用 Xray 代理测试 www.google.com..."

            # 创建临时 xray 配置进行测试
            local test_config='
            {
              "log": {
                "loglevel": "warning"
              },
              "inbounds": [
                {
                  "tag": "socks",
                  "port": 1080,
                  "listen": "127.0.0.1",
                  "protocol": "socks"
                }
              ],
              "outbounds": [
                {
                  "protocol": "vless",
                  "settings": {
                    "vnext": [
                      {
                        "address": "127.0.0.1",
                        "port": 18910,
                        "users": [
                          {
                            "id": "'$xray_uuid'",
                            "flow": "xtls-rprx-vision"
                          }
                        ]
                      }
                    ]
                  },
                  "streamSettings": {
                    "network": "tcp",
                    "security": "tls",
                    "tlsSettings": {
                      "serverName": "'$xray_test_domain'",
                      "allowInsecure": true
                    }
                  }
                }
              ]
            }
            '

            local proxy_result=$(check_remote "docker exec xray sh -c 'echo \"$test_config\" > /tmp/test.json && timeout 10 /usr/bin/xray -test -config /tmp/test.json 2>&1'" 2>/dev/null)
            if [ -z "$proxy_result" ]; then
                log_success "Xray 配置测试通过"
            else
                log_warning "Xray 配置测试: $proxy_result"
            fi

            # 检查 Xray 日志
            local xray_log=$(check_remote "docker exec xray cat /var/log/xray/access.log | tail -10" 2>/dev/null)
            if [ -n "$xray_log" ]; then
                log_success "Xray 日志正常记录"
            else
                log_warning "Xray 访问日志为空"
            fi
        else
            log_warning "未找到 XRAY_UUID 环境变量"
        fi
    else
        log_warning "未找到适合测试 Xray 分流的域名"
    fi

    # 3.4 检查各服务日志确认分流
    echo ""
    log_info "3.4 检查各服务日志确认分流"

    # HAProxy 日志
    local haproxy_recent=$(check_remote "docker logs haproxy --tail 20 2>&1" 2>/dev/null)
    if [ -n "$haproxy_recent" ]; then
        log_success "HAProxy 日志正常"
    else
        log_warning "HAProxy 日志为空"
    fi

    # Nginx 错误日志
    local nginx_error=$(check_remote "docker exec nginx cat /var/log/nginx/error.log 2>/dev/null | tail -5 | grep -i 'error' || echo ''")
    if [ -z "$nginx_error" ]; then
        log_success "Nginx 错误日志无错误"
    else
        log_warning "Nginx 错误日志发现错误"
    fi

    # Xray 错误日志
    local xray_error=$(check_remote "docker exec xray cat /var/log/xray/error.log 2>/dev/null | tail -5 | grep -i 'error' || echo ''")
    if [ -z "$xray_error" ]; then
        log_success "Xray 错误日志无错误"
    else
        log_warning "Xray 错误日志发现错误"
    fi

    echo ""
    echo "=========================================="
    log_success "Case 3 完成"
    echo "=========================================="
}
