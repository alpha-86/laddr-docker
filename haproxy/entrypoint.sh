#!/bin/sh
# HAProxy Entrypoint Script
# 使用 envsubst 替换配置模板中的环境变量

# 模板文件和输出文件路径
TEMPLATE_FILE="/usr/local/etc/haproxy/haproxy.cfg.tpl"
OUTPUT_FILE="/usr/local/etc/haproxy/haproxy.cfg"

# 使用 envsubst 替换环境变量
envsubst < "$TEMPLATE_FILE" > "$OUTPUT_FILE"

# 验证配置文件语法
haproxy -c -f "$OUTPUT_FILE"
if [ $? -ne 0 ]; then
    echo "ERROR: HAProxy configuration syntax error"
    exit 1
fi

# 启动 HAProxy
exec haproxy -f "$OUTPUT_FILE"
