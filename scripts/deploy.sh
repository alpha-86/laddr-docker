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

    # 检测入口模式与旧结构（README-003 3.9）：
    # 远端 haproxy 容器存在 且 远端 .env COMPOSE_FILE 不含 docker-compose-haproxy.yml
    # → 旧结构（haproxy 原本定义在主 compose 里），需要显式迁移
    echo ""
    log_info "检测入口模式与旧结构..."
    local remote_compose_file=$(ssh "$DEPLOYMENT_SERVER" "cd $REMOTE_PATH && grep '^COMPOSE_FILE=' .env | cut -d'=' -f2-" 2>/dev/null)
    local legacy_haproxy=$(ssh "$DEPLOYMENT_SERVER" "docker ps -aq --filter 'name=^haproxy\$'" 2>/dev/null)

    local entry_mode="nginx"
    echo "$remote_compose_file" | grep -q 'docker-compose-haproxy.yml' && entry_mode="haproxy"

    local migrating=false
    if [ -n "$legacy_haproxy" ] && [ "$entry_mode" = "nginx" ]; then
        migrating=true
        log_info "检测到旧版 HAProxy 容器（.env 未启用 docker-compose-haproxy.yml）→ 走迁移路径"
    else
        log_info "入口模式: $entry_mode（无迁移需求）"
    fi

    # 重启容器
    echo ""
    if [ "$migrating" = true ]; then
        # 迁移顺序：全部 stop（消除"xray 已 REQUIRE PP 而旧 haproxy 还在转发"的混合状态）
        # → 显式删除旧 haproxy 容器（compose up -d 不会移除 orphan，必须 docker rm）
        # → 统一 up -d（新配置同批生效）
        log_info "重启容器（含旧版 HAProxy 迁移：compose stop → docker rm haproxy → up -d）..."
        ssh "$DEPLOYMENT_SERVER" "cd $REMOTE_PATH && docker compose stop && { docker stop haproxy 2>/dev/null; docker rm haproxy 2>/dev/null; true; } && docker compose up -d" 2>&1 | grep -v "^$"
        log_success "容器重启完成"
        echo ""
        log_info "迁移完成：旧 HAProxy 容器已删除，当前为 Nginx 默认入口；"
        log_info "如需 HAProxy 入口，部署后在服务器执行: scripts/ngx_haproxy_switch.sh haproxy"
    else
        log_info "重启容器..."
        ssh "$DEPLOYMENT_SERVER" "cd $REMOTE_PATH && docker compose stop && docker compose up -d" 2>&1 | grep -v "^$"
        log_success "容器重启完成"
    fi

    # 等待容器初始化
    echo ""
    log_info "等待容器初始化（10 秒）..."
    sleep 10

    # 检查容器状态
    echo ""
    log_info "检查容器状态..."

    # 获取详细的容器状态信息
    local container_status=$(ssh "$DEPLOYMENT_SERVER" "cd $REMOTE_PATH && docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'" 2>/dev/null)
    echo "$container_status"
    echo ""

    # 检查每个必需容器的运行状态（按入口模式判定，README-003 3.9）
    local required=("nginx" "acme" "xray")
    if [ "$entry_mode" = "haproxy" ]; then
        required=("haproxy" "nginx" "acme" "xray")
    fi
    log_info "入口模式: $entry_mode（必需容器: ${required[*]}）"
    echo ""
    local all_healthy=true
    local failed_containers=()

    for c in "${required[@]}"; do
        # 检查容器是否在运行（Up状态）
        local status=$(ssh "$DEPLOYMENT_SERVER" "docker ps --filter name=^${c}$ --format '{{.Status}}'" 2>/dev/null)

        if [[ "$status" =~ ^Up.*$ ]]; then
            log_success "$c 容器运行正常"
        else
            # 检查是否是重启状态
            local full_status=$(ssh "$DEPLOYMENT_SERVER" "docker ps -a --filter name=^${c}$ --format '{{.Status}}'" 2>/dev/null)

            if [[ "$full_status" =~ Restarting.*$ ]]; then
                log_error "$c 容器处于重启循环状态: $full_status"
                failed_containers+=("$c")
                all_healthy=false
            elif [[ "$full_status" =~ Exited.*$ ]]; then
                log_error "$c 容器已退出: $full_status"
                failed_containers+=("$c")
                all_healthy=false
            else
                log_error "$c 容器状态异常: $full_status"
                failed_containers+=("$c")
                all_healthy=false
            fi
        fi
    done

    # 如果有容器失败，显示详细错误信息并退出
    if [ "$all_healthy" = false ]; then
        echo ""
        log_error "部署失败！以下容器状态异常:"
        for failed_container in "${failed_containers[@]}"; do
            echo ""
            log_error "=== $failed_container 容器日志 (最近20行) ==="
            ssh "$DEPLOYMENT_SERVER" "docker logs $failed_container --tail 20" 2>&1 | while IFS= read -r line; do
                echo "  $line"
            done
        done
        echo ""
        log_error "请检查上述容器日志，解决问题后重新部署"
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

    if [ "$entry_mode" = "haproxy" ]; then
        echo "  # 查看 HAProxy 日志"
        echo "  ssh $DEPLOYMENT_SERVER \"docker logs haproxy --tail 30\""
        echo ""
    else
        echo "  # Nginx 为默认 443 入口（stream 路由日志）"
        echo "  ssh $DEPLOYMENT_SERVER \"tail -20 $REMOTE_PATH/log/nginx_stream.log\""
        echo ""
        echo "  # 如需切到 HAProxy 入口（443 秒级中断，自动回滚）"
        echo "  ssh $DEPLOYMENT_SERVER \"cd $REMOTE_PATH && scripts/ngx_haproxy_switch.sh haproxy\""
        echo ""
    fi

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
