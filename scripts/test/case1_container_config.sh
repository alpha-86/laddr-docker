#!/bin/bash

# Case 1: 容器、端口、配置一致性检查

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

test_case1() {
    echo "=========================================="
    echo "  Case 1: 容器、端口、配置一致性检查"
    echo "=========================================="

    # 1.1 检查容器启动状态
    echo ""
    log_info "1.1 检查容器启动状态"
    local containers=$(check_remote "docker ps --format '{{.Names}}'")
    required=("haproxy" "nginx" "acme" "xray")

    for c in "${required[@]}"; do
        if echo "$containers" | grep -q "^${c}$"; then
            log_success "$c 容器运行中"
        else
            log_error "$c 容器未运行"
        fi
    done

    # 1.2 检查端口监听状态
    echo ""
    log_info "1.2 检查端口监听状态"

    # HAProxy 端口
    log_info "HAProxy 端口:"
    if check_remote "docker exec haproxy ss -tlnp | grep :443"; then
        log_success "  端口 443 监听中"
    else
        log_error "  端口 443 未监听"
    fi
    if check_remote "docker exec haproxy ss -tlnp | grep :8404"; then
        log_success "  端口 8404 监听中"
    else
        log_error "  端口 8404 未监听"
    fi

    # Nginx 端口
    log_info "Nginx 端口:"
    if check_remote "docker exec nginx ss -tlnp | grep :80"; then
        log_success "  端口 80 监听中"
    else
        log_error "  端口 80 未监听"
    fi
    if check_remote "docker exec nginx ss -tlnp | grep :8443"; then
        log_success "  端口 8443 监听中"
    else
        log_error "  端口 8443 未监听"
    fi

    # Xray 端口
    log_info "Xray 端口:"
    if check_remote "docker exec xray ss -tlnp | grep :9000"; then
        log_success "  端口 9000 监听中"
    else
        log_error "  端口 9000 未监听"
    fi

    # 1.3 检查配置文件变量与 .env 一致性
    echo ""
    log_info "1.3 检查配置文件变量与 .env 一致性"

    # 检查 XRAY_UUID
    local env_uuid=$(check_remote "grep XRAY_UUID .env | cut -d'=' -f2" 2>/dev/null)
    if [ -n "$env_uuid" ]; then
        if check_remote "docker exec xray cat /etc/xray/config.json | grep '$env_uuid'"; then
            log_success "XRAY_UUID 与配置文件一致: $env_uuid"
        else
            log_error "XRAY_UUID 在配置文件中未找到"
        fi
    else
        log_warning "未找到 XRAY_UUID 环境变量"
    fi

    # 检查 NF_XTLS_SERVER
    local env_nf_server=$(check_remote "grep NF_XTLS_SERVER .env | cut -d'=' -f2" 2>/dev/null)
    if [ -n "$env_nf_server" ]; then
        if check_remote "docker exec haproxy cat /usr/local/etc/haproxy/haproxy.cfg | grep '$env_nf_server'"; then
            log_success "NF_XTLS_SERVER 与配置文件一致: $env_nf_server"
        else
            log_warning "NF_XTLS_SERVER 在配置文件中未找到"
        fi
    else
        log_warning "未找到 NF_XTLS_SERVER 环境变量"
    fi

    echo ""
    echo "=========================================="
    log_success "Case 1 完成"
    echo "=========================================="
}
