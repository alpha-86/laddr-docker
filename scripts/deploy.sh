#!/bin/bash

# laddr-docker 部署脚本
# 用途：部署项目到目标服务器

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

# 主函数
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
    if ! ssh -o ConnectTimeout=5 "$DEPLOYMENT_SERVER" "echo OK" 2>/dev/null; then
        log_error "无法连接到服务器 $DEPLOYMENT_SERVER"
        exit 1
    fi

    # 传输文件
    log_info "正在传输文件..."
    local project_dir="$(cd "$(dirname "$0")/.." && pwd)"

    # 创建远程目录
    ssh "$DEPLOYMENT_SERVER" "mkdir -p $REMOTE_PATH" 2>/dev/null || true

    # 同步文件（排除 .git、.deployment-config、.env 和 scripts）
    rsync -avz --exclude='.git' --exclude='.deployment-config' --exclude='.env' --exclude='scripts' "$project_dir/" "$DEPLOYMENT_SERVER:$REMOTE_PATH/"

    log_success "文件传输完成"

    # 在目标服务器生成 .env 文件
    echo ""
    log_info "正在生成 .env 文件..."
    ssh "$DEPLOYMENT_SERVER" "cd $REMOTE_PATH && sh gen_env.sh"

    # 启动服务
    echo ""
    log_info "正在启动服务..."
    ssh "$DEPLOYMENT_SERVER" "cd $REMOTE_PATH && docker compose up -d"

    log_success "部署完成！"

    echo ""
    echo "=========================================="
    log_info "常用命令:"
    echo "  运行测试: ./scripts/test.sh"
    echo "  查看容器: ssh $DEPLOYMENT_SERVER 'docker ps'"
    echo "  查看日志: ssh $DEPLOYMENT_SERVER 'cd $REMOTE_PATH && docker compose logs'"
    echo "  重启服务: ssh $DEPLOYMENT_SERVER 'cd $REMOTE_PATH && docker compose restart'"
    echo "=========================================="
}

main "$@"
