#!/bin/sh

# 获取脚本所在目录的绝对路径
CURRENT_PATH=$(cd "$(dirname "$0")" && pwd)

# 定义配置文件路径
XRAY_CONFIG_TPL="/etc/xray/config.json.tpl"
XRAY_CONFIG_FILE="/etc/xray/config.json"
XRAY_CONFIG_STATUS="/etc/xray/config.status"

# XRAY_CONF_SUFFIX存在并且非空，则使用对应的配置文件
if [ -n "$XRAY_CONF_SUFFIX" ]; then
    XRAY_CONFIG_TPL="${XRAY_CONFIG_TPL}.${XRAY_CONF_SUFFIX}"
fi

# 如果 XRAY_UUID 未定义，则生成一个新的 UUID
if [ -z "$XRAY_UUID" ]; then
    # 使用 uuidgen 命令生成 UUID（如果系统支持）
    if command -v uuidgen >/dev/null 2>&1; then
        XRAY_UUID=$(uuidgen)
    else
        # 如果 uuidgen 不可用，使用 /proc/sys/kernel/random/uuid（Linux系统）
        if [ -f "/proc/sys/kernel/random/uuid" ]; then
            XRAY_UUID=$(cat /proc/sys/kernel/random/uuid)
        else
            # 如果以上方法都不可用，使用 od 和 /dev/urandom 生成类 UUID
            XRAY_UUID=$(od -x /dev/urandom | head -1 | awk '{OFS="-"; print $2$3,$4,$5,$6,$7$8$9}')
        fi
    fi
    echo "Generated new UUID: ${XRAY_UUID}"
fi

# 如果 XRAY_UUID_9000 未定义，则使用主 UUID
if [ -z "$XRAY_UUID_9000" ]; then
    XRAY_UUID_9000=$XRAY_UUID
fi

# 如果 XRAY_UUID_9001 未定义，则使用主 UUID
if [ -z "$XRAY_UUID_9001" ]; then
    XRAY_UUID_9001=$XRAY_UUID
fi

# 设置默认 DNS 服务器
if [ -z "$DEFAULT_DNS_SERVER1" ]; then
    DEFAULT_DNS_SERVER1="8.8.8.8"
    DEFAULT_DNS_SERVER2="8.8.4.4"
fi

if [ -z "$NF_DNS_SERVER" ]; then
    NF_DNS_SERVER=$DEFAULT_DNS_SERVER1
fi

# 基于模板生成配置文件 - 支持 XTLS-RPRX-Vision (端口9000) 和 XHTTP-Reality (端口9001)
cat "$XRAY_CONFIG_TPL" | sed "s/\${XRAY_UUID}/${XRAY_UUID}/g" \
                             | sed "s/\${XRAY_UUID_9000}/${XRAY_UUID_9000}/g" \
                             | sed "s/\${XRAY_UUID_9001}/${XRAY_UUID_9001}/g" \
                             | sed "s/\${DEFAULT_DNS_SERVER1}/${DEFAULT_DNS_SERVER1}/g" \
                             | sed "s/\${DEFAULT_DNS_SERVER2}/${DEFAULT_DNS_SERVER2}/g" \
                             | sed "s/\${NF_DNS_SERVER}/${NF_DNS_SERVER}/g" \
                             | sed "s/\${REALITY_PRIVATE_KEY}/${REALITY_PRIVATE_KEY}/g" \
                             | sed "s|\${REALITY_DEST}|${REALITY_DEST}|g" \
                             | sed "s|\${REALITY_SHORT_IDS}|${REALITY_SHORT_IDS}|g" \
                              > "$XRAY_CONFIG_FILE"

# 输出状态信息，包含时间戳
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Generated config.json from TPL{" >> "$XRAY_CONFIG_STATUS"
echo "    XRAY_CONFIG_TPL:[${XRAY_CONFIG_TPL}]" >> "$XRAY_CONFIG_STATUS"
echo "    XRAY_UUID:[${XRAY_UUID:0:8}...]" >> "$XRAY_CONFIG_STATUS"
echo "    XRAY_UUID_9001:[${XRAY_UUID_9001:0:8}...]" >> "$XRAY_CONFIG_STATUS"
echo "    XRAY_UUID_9001:[${XRAY_UUID_9001:0:8}...]" >> "$XRAY_CONFIG_STATUS"
echo "    DEFAULT_DNS_SERVER1:[${DEFAULT_DNS_SERVER1}]" >> "$XRAY_CONFIG_STATUS"
echo "    DEFAULT_DNS_SERVER2:[${DEFAULT_DNS_SERVER2}]" >> "$XRAY_CONFIG_STATUS"
echo "    NF_DNS_SERVER:[${NF_DNS_SERVER}]" >> "$XRAY_CONFIG_STATUS"
echo "    REALITY_PRIVATE_KEY:[${REALITY_PRIVATE_KEY:0:8}...]" >> "$XRAY_CONFIG_STATUS"
echo "    REALITY_SHORT_IDS:[${REALITY_SHORT_IDS}]" >> "$XRAY_CONFIG_STATUS"
echo "    REALITY_DEST:[${REALITY_DEST}]" >> "$XRAY_CONFIG_STATUS"
echo "}END" >> "$XRAY_CONFIG_STATUS"

# 执行 xray
/usr/bin/xray -config $XRAY_CONFIG_FILE
