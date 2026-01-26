#!/bin/bash

# Case 2: SSL 证书验证

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

test_case2() {
    echo "=========================================="
    echo "  Case 2: SSL 证书验证"
    echo "=========================================="

    # 2.1 检查证书文件存在
    echo ""
    log_info "2.1 检查证书文件存在"
    local cert_files=("default_cert.pem" "default_key.pem" "default_ca.pem" "default_full.pem")

    for file in "${cert_files[@]}"; do
        if check_remote "docker exec nginx [ -f /etc/nginx/cert/$file ]"; then
            log_success "$file 存在"
        else
            log_error "$file 不存在"
        fi
    done

    # 2.2 检查证书有效期
    echo ""
    log_info "2.2 检查证书有效期"
    local cert_date=$(check_remote "docker exec nginx openssl x509 -in /etc/nginx/cert/default_cert.pem -noout -enddate | cut -d= -f2" 2>/dev/null)
    if [ -n "$cert_date" ]; then
        log_info "证书有效期至: $cert_date"
        local expiry_date=$(date -d "$cert_date" +%s 2>/dev/null || echo "0")
        local current_date=$(date +%s)
        if [ "$expiry_date" -gt "$current_date" ]; then
            local days=$(( ($expiry_date - $current_date) / 86400 ))
            log_success "证书有效，剩余 $days 天"
        else
            log_error "证书已过期"
        fi
    else
        log_warning "无法读取证书有效期"
    fi

    # 2.3 验证私钥与证书匹配
    echo ""
    log_info "2.3 验证私钥与证书匹配"
    local cert_modulus=$(check_remote "docker exec nginx openssl x509 -noout -modulus -in /etc/nginx/cert/default_cert.pem | openssl md5" 2>/dev/null)
    local key_modulus=$(check_remote "docker exec nginx openssl rsa -noout -modulus -in /etc/nginx/cert/default_key.pem | openssl md5" 2>/dev/null)

    if [ "$cert_modulus" = "$key_modulus" ]; then
        log_success "私钥与证书匹配"
    else
        log_error "私钥与证书不匹配"
    fi

    echo ""
    echo "=========================================="
    log_success "Case 2 完成"
    echo "=========================================="
}
