#!/bin/bash

# laddr-docker 环境变量生成脚本
# 用途：生成或更新 .env 配置文件

# 获取脚本所在目录
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ENV_FILE="$SCRIPT_DIR/.env"

# UUID 生成函数
gen_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [ -f /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || echo "$(date +%s)-$(shuf -i 1000-9999 -n 1 2>/dev/null || echo 1234)"
    fi
}

# Reality密钥对生成函数（静默生成，不输出调试信息）
gen_reality_keypair() {
    # 尝试使用docker生成标准的X25519密钥对
    if command -v docker >/dev/null 2>&1; then
        local keypair_output=$(docker run --rm teddysun/xray xray x25519 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$keypair_output" ]; then
            # 只输出结果，不输出调试信息
            echo "$keypair_output"
            return 0
        fi
    fi

    # 备用方案：使用openssl生成兼容的密钥
    local private_key=$(openssl rand -base64 32 2>/dev/null | tr -d '=\n')
    local public_key=$(openssl rand -base64 32 2>/dev/null | tr -d '=\n')
    # 输出格式与xray x25519保持一致
    echo "PrivateKey: $private_key"
    echo "Password: $public_key"
}

# 读取现有 .env 文件
EXISTING_VARS_TEMP=$(mktemp)
if [ -f "$ENV_FILE" ]; then
    while IFS='=' read -r key value; do
        # 跳过注释和空行
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${key// }" ]] && continue
        echo "$key=$value" >> "$EXISTING_VARS_TEMP"
    done < "$ENV_FILE"
fi

# 获取现有变量的值
get_existing_value() {
    grep "^$1=" "$EXISTING_VARS_TEMP" 2>/dev/null | cut -d'=' -f2-
}

# 检查变量是否存在
var_exists() {
    grep -q "^$1=" "$EXISTING_VARS_TEMP" 2>/dev/null
}

# Reality配置生成（静默生成，仅用于内部处理）
generate_reality_config() {
    local main_uuid=$(get_existing_value "XRAY_UUID" || gen_uuid)

    # 静默生成密钥对
    local keypair_output=$(gen_reality_keypair)
    local private_key=$(echo "$keypair_output" | grep "PrivateKey:" | awk '{print $2}')
    local public_key=$(echo "$keypair_output" | grep "Password:" | awk '{print $2}')

    # 生成4字符shortId
    local short_id=$(openssl rand -hex 2 2>/dev/null || echo "a1b2")

    # 仅输出变量定义，不输出调试信息
    echo "REALITY_PRIVATE_KEY=${private_key}"
    echo "REALITY_PUBLIC_KEY=${public_key}"
    echo "REALITY_SHORT_IDS=[\"${short_id}\"]"
}

# 定义所有变量及其默认值（按输出顺序）
# 格式: "变量名|默认值|分块标题"
VARS=(
    "COMPOSE_PATH_SEPARATOR|:|#docker compose file"
    "COMPOSE_FILE|docker-compose.yml:docker-compose-xray.yml|"
    "DOCKER_BOX_HOME|$SCRIPT_DIR|#环境目录"
    "NGINX_PATH|$SCRIPT_DIR/nginx|"
    "HAPROXY_PATH|$SCRIPT_DIR/haproxy|"
    "HTML_PATH|$SCRIPT_DIR/html|"
    "ACME_SH_PATH|$SCRIPT_DIR/acme|"
    "XRAY_PATH|$SCRIPT_DIR/xray|"
    "Ali_Key||#acme.sh"
    "Ali_Secret||"
    "CF_Key||"
    "CF_Email||"
    "ACME_SH_EMAIL||"
    "CA_LETSENCRYPT|1|"
    "DOMAIN_LIST||"
    "XRAY_UUID|$(gen_uuid)|#xray"
    "XRAY_UUID_9000|$(get_existing_value "XRAY_UUID" || gen_uuid)|"
    "XRAY_UUID_9001|$(get_existing_value "XRAY_UUID" || gen_uuid)|"
    "NF_XTLS_SERVER|127.0.0.1:18910|#haproxy"
    "REALITY_PRIVATE_KEY|$(generate_reality_config | grep REALITY_PRIVATE_KEY | cut -d'=' -f2)|#reality"
    "REALITY_PUBLIC_KEY|$(generate_reality_config | grep REALITY_PUBLIC_KEY | cut -d'=' -f2)|"
    "REALITY_SHORT_IDS|$(generate_reality_config | grep REALITY_SHORT_IDS | cut -d'=' -f2)|"
    "REALITY_DEST|www.fifa.com|"
)

# 记录新增变量和修改的变量
NEW_VARS_TEMP=$(mktemp)
CHANGED_VARS_TEMP=$(mktemp)

# 构建变量值映射
FINAL_VARS_TEMP=$(mktemp)

for var_def in "${VARS[@]}"; do
    IFS='|' read -r var_name default_value block_title <<< "$var_def"

    # 确定最终值
    if var_exists "$var_name"; then
        final_value=$(get_existing_value "$var_name")
        # 检查值是否与默认值不同
        if [ "$final_value" != "$default_value" ]; then
            echo "$var_name|$default_value|$final_value" >> "$CHANGED_VARS_TEMP"
        fi
    else
        final_value="$default_value"
        echo "$var_name|$default_value" >> "$NEW_VARS_TEMP"
    fi

    echo "$var_name=$final_value" >> "$FINAL_VARS_TEMP"
done

# 输出提示信息
if [ -s "$NEW_VARS_TEMP" ] || [ -s "$CHANGED_VARS_TEMP" ]; then
    echo "=========================================="
    echo "环境变量更新信息"
    echo "=========================================="

    if [ -s "$NEW_VARS_TEMP" ]; then
        echo ""
        echo "新增变量 ($(wc -l < "$NEW_VARS_TEMP" | tr -d ' ')):"
        while IFS='|' read -r var_name default_value; do
            # 隐藏敏感信息，只显示前3位
            if [[ "$var_name" =~ ^(Ali_Key|Ali_Secret|CF_Key|XRAY_UUID|XRAY_UUID_9000|XRAY_UUID_9001|REALITY_PRIVATE_KEY|REALITY_PUBLIC_KEY)$ ]]; then
                echo "  - $var_name=${default_value:0:3}..."
            else
                echo "  - $var_name=$default_value"
            fi
        done < "$NEW_VARS_TEMP"
    fi

    if [ -s "$CHANGED_VARS_TEMP" ]; then
        echo ""
        echo "值已变更 ($(wc -l < "$CHANGED_VARS_TEMP" | tr -d ' ')):"
        while IFS='|' read -r var_name default_value final_value; do
            # 隐藏敏感信息，只显示前3位
            if [[ "$var_name" =~ ^(Ali_Key|Ali_Secret|CF_Key|XRAY_UUID|XRAY_UUID_9000|XRAY_UUID_9001|REALITY_PRIVATE_KEY|REALITY_PUBLIC_KEY)$ ]]; then
                echo "  - $var_name: ${default_value:0:3}... -> ${final_value:0:3}..."
            else
                echo "  - $var_name: $default_value -> $final_value"
            fi
        done < "$CHANGED_VARS_TEMP"
    fi

    echo ""
    echo "=========================================="
    echo ""
fi

# 清理临时文件
rm -f "$EXISTING_VARS_TEMP" "$NEW_VARS_TEMP" "$CHANGED_VARS_TEMP"

# 生成 .env 文件
# 清空文件
> "$ENV_FILE"

CURRENT_BLOCK=""
FIRST_VAR=true

for var_def in "${VARS[@]}"; do
    IFS='|' read -r var_name default_value block_title <<< "$var_def"

    # 输出分块之间的空白行
    if [ -n "$block_title" ] && [ "$block_title" != "$CURRENT_BLOCK" ]; then
        if [ "$FIRST_VAR" = false ]; then
            echo "" >> "$ENV_FILE"
        fi
        echo "$block_title" >> "$ENV_FILE"
        CURRENT_BLOCK="$block_title"
        FIRST_VAR=false
    fi

    # 输出变量
    final_value=$(grep "^$var_name=" "$FINAL_VARS_TEMP" | cut -d'=' -f2-)
    echo "${var_name}=${final_value}" >> "$ENV_FILE"
done

# 清理最后的临时文件
rm -f "$FINAL_VARS_TEMP"

echo "已生成 $ENV_FILE"
