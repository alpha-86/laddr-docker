#!/bin/bash

# laddr-docker 测试脚本
# 用途：部署后验证服务状态和功能

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

# 远程执行命令
remote_cmd() {
    ssh "$DEPLOYMENT_SERVER" "cd $REMOTE_PATH && $1" 2>/dev/null || echo ""
}

# 检查远程命令执行结果
check_remote() {
    local output=$(remote_cmd "$1")
    [ -n "$output" ] && echo "$output" || return 1
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
    if ! ssh -o ConnectTimeout=5 "$DEPLOYMENT_SERVER" "echo OK" 2>/dev/null; then
        log_error "无法连接到服务器 $DEPLOYMENT_SERVER"
        exit 1
    fi

    # 在目标服务器生成 .env 文件
    log_info "正在生成 .env 文件..."
    ssh "$DEPLOYMENT_SERVER" "cd $REMOTE_PATH && sh gen_env.sh"
    log_success ".env 文件生成完成"

    # 导出配置供子脚本使用
    export DEPLOYMENT_SERVER
    export DEPLOYMENT_PATH
    export REMOTE_PATH

    # 执行测试 cases
    local script_dir="$(cd "$(dirname "$0")" && pwd)/test"

    echo ""
    source "$script_dir/case1_container_config.sh"
    test_case1

    echo ""
    source "$script_dir/case2_ssl_cert.sh"
    test_case2

    echo ""
    source "$script_dir/case3_sni_routing.sh"
    test_case3

    echo ""
    echo "=========================================="
    log_info "测试完成！"
    echo "=========================================="
    echo ""
    log_info "常用命令:"
    echo "  查看所有容器: ssh $DEPLOYMENT_SERVER 'docker ps'"
    echo "  查看日志: ssh $DEPLOYMENT_SERVER 'cd $REMOTE_PATH && docker compose logs'"
    echo "  重启服务: ssh $DEPLOYMENT_SERVER 'cd $REMOTE_PATH && docker compose restart'"
    echo ""
}

main "$@"
