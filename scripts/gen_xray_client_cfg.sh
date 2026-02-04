#!/bin/bash

# Xray 客户端配置二维码生成脚本
# 用途：生成 Vision 或 XHTTP 协议的客户端配置二维码（Shadowrocket/v2rayNG）
# 使用：./qrcode.sh [vision|xhttp] [domain]

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# 获取脚本所在目录的父目录（项目根目录）
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$PROJECT_ROOT/.env"

# 检查 .env 文件是否存在
if [ ! -f "$ENV_FILE" ]; then
    log_error ".env 文件不存在: $ENV_FILE"
    log_info "请先运行 gen_env.sh 生成环境配置"
    exit 1
fi

# 加载环境变量
source "$ENV_FILE"

# 解析命令行参数
PROTOCOL="${1:-vision}"  # 默认 vision
DOMAIN="$2"

# 参数验证
if [[ "$PROTOCOL" != "vision" && "$PROTOCOL" != "xhttp" ]]; then
    log_error "不支持的协议类型: $PROTOCOL"
    echo "用法: $0 [vision|xhttp] [domain]"
    echo ""
    echo "示例:"
    echo "  $0 vision x.sg.cqcy.fun"
    echo "  $0 xhttp"
    exit 1
fi

# 从证书中提取所有域名
extract_domains_from_cert() {
    local cert_file="$PROJECT_ROOT/nginx/ssl/default_cert.pem"
    if [ ! -f "$cert_file" ]; then
        return 1
    fi

    openssl x509 -in "$cert_file" -noout -text 2>/dev/null | \
        grep -A1 "Subject Alternative Name" | \
        grep "DNS:" | \
        sed 's/DNS://g' | \
        tr ',' '\n' | \
        sed 's/^[[:space:]]*//'
}

# 根据协议和 HAProxy 分流规则构造合适的域名
construct_domain() {
    local protocol="$1"
    local all_domains=$(extract_domains_from_cert)

    if [ -z "$all_domains" ]; then
        log_error "无法从证书中提取域名"
        return 1
    fi

    # 根据协议选择合适的前缀
    if [ "$protocol" = "vision" ]; then
        # Vision 使用 x|xyz|api|dt|ai 前缀
        local prefixes=("x" "xyz" "api" "dt" "ai")
    elif [ "$protocol" = "xhttp" ]; then
        # XHTTP 使用 web|app|cdn 前缀
        local prefixes=("web" "app" "cdn")
    fi

    # 查找通配符域名（第三级）
    local wildcard_domains=$(echo "$all_domains" | grep '^\*\.[^*]*\.[^*]*\.[^*]*$')

    if [ -n "$wildcard_domains" ]; then
        # 使用第一个通配符域名构造四级域名
        local base_domain=$(echo "$wildcard_domains" | head -1 | sed 's/^\*\.//')
        local prefix="${prefixes[0]}"
        local constructed="${prefix}.${base_domain}"

        echo "$constructed"
        return 0
    fi

    # 如果没有通配符，返回第一个非通配符域名
    local non_wildcard=$(echo "$all_domains" | grep -v '^\*\.' | head -1)
    if [ -n "$non_wildcard" ]; then
        echo "$non_wildcard"
        return 0
    fi

    return 1
}

# 验证域名 DNS 解析
validate_domain_dns() {
    local domain="$1"
    local server_ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null)

    if [ -z "$server_ip" ]; then
        log_warn "无法获取服务器公网 IP，跳过 DNS 验证"
        return 0
    fi

    log_info "验证域名 DNS 解析..."
    log_info "  服务器 IP: $server_ip"

    local resolved_ip=$(dig +short "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)

    if [ -z "$resolved_ip" ]; then
        # 如果 dig 不可用，尝试使用 nslookup
        resolved_ip=$(nslookup "$domain" 2>/dev/null | grep -A1 "Name:" | grep "Address:" | awk '{print $2}' | head -1)
    fi

    if [ -z "$resolved_ip" ]; then
        log_warn "  无法解析域名: $domain"
        log_warn "  请确保域名 DNS 记录指向服务器 IP"
        return 1
    fi

    log_info "  域名解析: $resolved_ip"

    if [ "$resolved_ip" = "$server_ip" ]; then
        log_success "  ✓ DNS 解析正确"
        return 0
    else
        log_warn "  ❌ DNS 解析不匹配"
        log_warn "  期望: $server_ip"
        log_warn "  实际: $resolved_ip"
        return 1
    fi
}

# 获取或构造域名
if [ -z "$DOMAIN" ]; then
    log_info "自动构造域名..."
    DOMAIN=$(construct_domain "$PROTOCOL")

    if [ -z "$DOMAIN" ]; then
        log_error "无法自动构造域名，请手动指定"
        echo "用法: $0 $PROTOCOL <domain>"
        exit 1
    fi

    log_success "构造域名: $DOMAIN"

    # 验证域名
    validate_domain_dns "$DOMAIN"
else
    log_info "使用指定域名: $DOMAIN"
fi

log_info "协议类型: $PROTOCOL"

# 检查 qrencode 是否安装
QRENCODE_INSTALLED=true
if ! command -v qrencode &> /dev/null; then
    QRENCODE_INSTALLED=false
    log_warn "qrencode 未安装"
    log_info "请运行以下命令安装 qrencode："
    if command -v apt-get &> /dev/null; then
        echo "  sudo apt-get update && sudo apt-get install -y qrencode"
    elif command -v yum &> /dev/null; then
        echo "  sudo yum install -y qrencode"
    elif command -v brew &> /dev/null; then
        echo "  brew install qrencode"
    fi
    echo ""
    log_info "或者只输出配置链接（不生成二维码）"
fi

# 生成 Vision 协议配置
generate_vision_config() {
    local uuid="$XRAY_UUID_9000"
    local server="$DOMAIN"
    local port="443"
    local security="tls"
    local flow="xtls-rprx-vision"
    local sni="$server"
    local fp="chrome"
    local alpn="h2,http/1.1"

    # 简化备注名称：去掉域名后两段
    local short_name=$(echo "$server" | sed 's/\.[^.]*\.[^.]*$//')
    local remark="Vision-${short_name}"

    # URL 编码 remark
    local encoded_remark=$(echo -n "$remark" | jq -sRr @uri)

    # VLESS Vision 链接格式（兼容 Shadowrocket 和 v2rayNG）
    # vless://uuid@server:port?type=tcp&security=tls&flow=xtls-rprx-vision&sni=domain&fp=chrome&alpn=h2,http/1.1#remark
    local vless_link="vless://${uuid}@${server}:${port}?type=tcp&security=tls&flow=${flow}&sni=${sni}&fp=${fp}&alpn=${alpn}#${encoded_remark}"

    echo "$vless_link"
}

# 生成 XHTTP 协议配置
generate_xhttp_config() {
    local uuid="$XRAY_UUID_9001"
    local server="$DOMAIN"
    local port="443"
    local security="reality"
    local sni="$REALITY_DEST"
    local fp="chrome"
    local pbk="$REALITY_PUBLIC_KEY"
    local sid=$(echo "$REALITY_SHORT_IDS" | tr -d '[]"')
    local path="/js/app.js"

    # 简化备注名称：去掉域名后两段
    local short_name=$(echo "$server" | sed 's/\.[^.]*\.[^.]*$//')
    local remark="XHTTP-${short_name}"

    # URL 编码处理
    local encoded_remark=$(echo -n "$remark" | jq -sRr @uri)
    local encoded_path=$(echo -n "$path" | jq -sRr @uri)

    # VLESS XHTTP+REALITY 链接格式（标准格式，v2rayNG 完全支持）
    # vless://uuid@server:port?type=xhttp&security=reality&sni=dest&fp=chrome&pbk=publickey&sid=shortid&path=/path#remark
    local vless_link="vless://${uuid}@${server}:${port}?type=xhttp&security=reality&sni=${sni}&fp=${fp}&pbk=${pbk}&sid=${sid}&path=${encoded_path}#${encoded_remark}"

    echo "$vless_link"
}

# 主逻辑
echo ""
echo "=========================================="
echo "  Xray 客户端配置二维码生成"
echo "=========================================="
echo ""

if [ "$PROTOCOL" = "vision" ]; then
    log_info "生成 Vision 协议配置..."
    CONFIG_LINK=$(generate_vision_config)

    log_info "配置信息:"
    echo "  协议: VLESS + XTLS-RPRX-Vision"
    echo "  服务器: $DOMAIN"
    echo "  端口: 443"
    echo "  UUID: ${XRAY_UUID_9000:0:8}...${XRAY_UUID_9000: -4}"
    echo "  Flow: xtls-rprx-vision"
    echo "  安全: TLS"
    echo "  指纹: chrome"
    echo ""
    log_success "✓ 兼容客户端: Shadowrocket, v2rayNG, Clash Meta"

elif [ "$PROTOCOL" = "xhttp" ]; then
    log_info "生成 XHTTP+REALITY 协议配置..."
    CONFIG_LINK=$(generate_xhttp_config)

    sid=$(echo "$REALITY_SHORT_IDS" | tr -d '[]"')

    log_info "配置信息:"
    echo "  协议: VLESS + XHTTP + REALITY"
    echo "  服务器: $DOMAIN"
    echo "  端口: 443"
    echo "  UUID: ${XRAY_UUID_9001:0:8}...${XRAY_UUID_9001: -4}"
    echo "  伪装目标: $REALITY_DEST"
    echo "  路径: /js/app.js"
    echo "  Public Key: ${REALITY_PUBLIC_KEY:0:8}..."
    echo "  Short ID: $sid"
    echo "  指纹: chrome"
    echo ""
    log_warn "⚠ 兼容性说明:"
    echo "  - v2rayNG (Android): ✓ 完全支持"
    echo "  - Shadowrocket (iOS): 可能需要较新版本"
    echo "  - 建议使用 v2rayNG 以获得最佳体验"
fi

echo ""
log_info "配置链接:"
echo "$CONFIG_LINK"

if [ "$QRENCODE_INSTALLED" = true ]; then
    echo ""
    log_info "二维码:"
    echo ""

    # 生成二维码
    qrencode -t ANSIUTF8 "$CONFIG_LINK"

    echo ""
    log_success "二维码生成完成！"
    echo ""
    log_info "使用方法:"
    echo "  1. 使用 Shadowrocket 或 v2rayNG 扫描上方二维码"
    echo "  2. 或复制配置链接手动导入"
else
    echo ""
    log_info "使用方法:"
    echo "  1. 复制上方配置链接"
    echo "  2. 在 Shadowrocket 或 v2rayNG 中手动导入"
    echo "  3. 或安装 qrencode 后重新运行本脚本生成二维码"
fi
echo ""
