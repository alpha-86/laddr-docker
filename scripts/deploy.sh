#!/bin/bash
# laddr-docker 部署脚本
# 职责：部署代码到远程服务器并启动容器

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[FAIL]${NC} $1"; }

# 获取部署配置
get_deployment_config() {
    local config_file="$(cd "$(dirname "$0")/.." && pwd)/.deployment-config"

    if [ -f "$config_file" ]; then
        DEPLOYMENT_SERVER=$(grep "^DEPLOYMENT_SERVER=" "$config_file" | cut -d'=' -f2)
        DEPLOYMENT_PATH=$(grep "^DEPLOYMENT_PATH=" "$config_file" | cut -d'=' -f2)
        REMOTE_PATH="${DEPLOYMENT_PATH}laddr-docker"
    else
        echo "未找到部署配置文件"
        read -p "请输入目标服务器 (如 work@server.com): " DEPLOYMENT_SERVER
        read -p "请输入目标路径 (如 /home/work/): " DEPLOYMENT_PATH
        REMOTE_PATH="${DEPLOYMENT_PATH}laddr-docker"

        echo "DEPLOYMENT_SERVER=$DEPLOYMENT_SERVER" > "$config_file"
        echo "DEPLOYMENT_PATH=$DEPLOYMENT_PATH" >> "$config_file"
        log_info "已保存部署配置到 $config_file"
    fi
}

main() {
    echo "=========================================="
    echo "  laddr-docker 部署脚本"
    echo "=========================================="

    # 获取部署配置
    get_deployment_config
    echo ""
    log_info "目标服务器: $DEPLOYMENT_SERVER"
    log_info "目标路径: $REMOTE_PATH"
    echo ""

    # 测试连接
    log_info "测试 SSH 连接..."
    if ! ssh -o ConnectTimeout=5 "$DEPLOYMENT_SERVER" "echo OK" >/dev/null 2>&1; then
        log_error "无法连接到服务器 $DEPLOYMENT_SERVER"
        exit 1
    fi
    log_success "SSH 连接正常"

    # 创建远程目录
    log_info "创建远程目录..."
    ssh "$DEPLOYMENT_SERVER" "mkdir -p $REMOTE_PATH" 2>/dev/null || true

    # 同步文件（排除 .git、.deployment-config、.env 和 scripts）
    # 排除运行时生成的文件：日志、证书、acme 数据
    echo ""
    log_info "使用 rsync 同步文件..."
    local project_dir="$(cd "$(dirname "$0")/.." && pwd)"
    rsync -avz \
        --exclude='.git' \
        --exclude='.deployment-config' \
        --exclude='.env' \
        --exclude='*/log/' \
        --exclude='*/ssl/' \
        --exclude='acme/acme.sh/' \
        --exclude='xray/etc/config.json' \
        --exclude='xray/etc/config.status' \
        "$project_dir/" "$DEPLOYMENT_SERVER:$REMOTE_PATH/" 2>&1 | grep -v "^sending\|^sent\|^total"
    log_success "文件同步完成"

    # 生成 .env 文件
    echo ""
    log_info "生成 .env 文件..."
    ssh "$DEPLOYMENT_SERVER" "cd $REMOTE_PATH && sh gen_env.sh" 2>&1
    log_success ".env 文件生成完成"

    # 重启容器
    echo ""
    log_info "重启容器..."
    ssh "$DEPLOYMENT_SERVER" "cd $REMOTE_PATH && docker compose stop && docker compose up -d" 2>&1 | grep -v "^$"
    log_success "容器重启完成"

    # 等待容器初始化
    echo ""
    log_info "等待容器初始化（10 秒）..."
    sleep 10

    # 检查容器状态
    echo ""
    log_info "检查容器状态..."
    local containers=$(ssh "$DEPLOYMENT_SERVER" "docker ps --format '{{.Names}}'" 2>/dev/null)
    local required=("haproxy" "nginx" "acme" "xray")
    local all_running=true

    for c in "${required[@]}"; do
        if echo "$containers" | grep -q "^${c}$"; then
            log_success "$c 容器运行中"
        else
            log_error "$c 容器未运行"
            all_running=false
        fi
    done

    if [ "$all_running" = false ]; then
        log_error "部分容器未运行，请检查日志"
        exit 1
    fi

    echo ""
    echo "=========================================="
    log_success "部署完成！"
    echo "=========================================="
    echo ""
    log_info "下一步：观察服务状态和日志"
    echo ""
    echo "建议执行以下命令观察服务："
    echo ""
    echo "  # 查看容器状态"
    echo "  ssh $DEPLOYMENT_SERVER \"cd $REMOTE_PATH && docker ps\""
    echo ""
    echo "  # 查看 HAProxy 日志"
    echo "  ssh $DEPLOYMENT_SERVER \"docker logs haproxy --tail 30\""
    echo ""
    echo "  # 查看 Nginx 日志"
    echo "  ssh $DEPLOYMENT_SERVER \"docker logs nginx --tail 30\""
    echo ""
    echo "  # 查看 Xray 日志"
    echo "  ssh $DEPLOYMENT_SERVER \"docker logs xray --tail 30\""
    echo ""
    echo "观察完毕后，运行测试脚本："
    echo "  ./scripts/test.sh"
    echo ""
}

main "$@"
