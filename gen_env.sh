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

# 读取现有 .env 文件
declare -A EXISTING_VARS
if [ -f "$ENV_FILE" ]; then
    while IFS='=' read -r key value; do
        # 跳过注释和空行
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${key// }" ]] && continue
        # 保留值中的空格
        EXISTING_VARS["$key"]="$value"
    done < "$ENV_FILE"
fi

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
    "HOST_HTTP_PORT|80|#nginx env"
    "HOST_HTTPS_PORT|443|"
    "Ali_Key||#acme.sh"
    "Ali_Secret||"
    "CF_Key||"
    "CF_Email||"
    "ACME_SH_EMAIL||"
    "CA_LETSENCRYPT|1|"
    "DOMAIN_LIST||"
    "XRAY_UUID|$(gen_uuid)|#xray"
    "XRAY_CONF_SUFFIX||"
    "XRAY_UUID_9000||"
    "DEFAULT_DNS_SERVER1|8.8.8.8|"
    "DEFAULT_DNS_SERVER2|8.8.4.4|"
    "NF_DNS_SERVER|8.8.8.8|"
    "NF_XTLS_SERVER|127.0.0.1:18910|#haproxy"
)

# 记录新增变量和修改的变量
declare -A NEW_VARS
declare -A CHANGED_VARS

# 构建变量值映射
declare -A FINAL_VARS
CURRENT_BLOCK=""

for var_def in "${VARS[@]}"; do
    IFS='|' read -r var_name default_value block_title <<< "$var_def"

    # 确定最终值
    if [ -n "${EXISTING_VARS[$var_name]+isset}" ]; then
        final_value="${EXISTING_VARS[$var_name]}"
        # 检查值是否与默认值不同
        if [ "$final_value" != "$default_value" ]; then
            CHANGED_VARS["$var_name"]="$default_value -> $final_value"
        fi
    else
        final_value="$default_value"
        NEW_VARS["$var_name"]="$default_value"
    fi

    FINAL_VARS["$var_name"]="$final_value"
done

# 输出提示信息
if [ ${#NEW_VARS[@]} -gt 0 ] || [ ${#CHANGED_VARS[@]} -gt 0 ]; then
    echo "=========================================="
    echo "环境变量更新信息"
    echo "=========================================="

    if [ ${#NEW_VARS[@]} -gt 0 ]; then
        echo ""
        echo "新增变量 (${#NEW_VARS[@]}):"
        for var in "${!NEW_VARS[@]}"; do
            echo "  - $var=${NEW_VARS[$var]}"
        done
    fi

    if [ ${#CHANGED_VARS[@]} -gt 0 ]; then
        echo ""
        echo "值已变更 (${#CHANGED_VARS[@]}):"
        for var in "${!CHANGED_VARS[@]}"; do
            echo "  - $var: ${CHANGED_VARS[$var]}"
        done
    fi

    echo ""
    echo "=========================================="
    echo ""
fi

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
    echo "${var_name}=${FINAL_VARS[$var_name]}" >> "$ENV_FILE"
done

echo "已生成 $ENV_FILE"
