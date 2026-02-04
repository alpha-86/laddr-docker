#!/bin/sh
# HAProxy Entrypoint Script
set -e

# 检查环境变量并设置默认值
: "${NF_XTLS_SERVER:=127.0.0.1:18910}"
: "${REALITY_DEST:?REALITY_DEST environment variable is required}"

# 创建日志目录和日志文件
mkdir -p /var/log/haproxy
touch /var/log/haproxy/access.log
touch /var/log/haproxy/error.log
chmod 666 /var/log/haproxy/access.log
chmod 666 /var/log/haproxy/error.log

# 模板文件和输出文件路径
TEMPLATE="/usr/local/etc/haproxy/haproxy.cfg.tpl"
CONFIG="/usr/local/etc/haproxy/haproxy.cfg"
SNI_MAP_TEMPLATE="/usr/local/etc/haproxy/maps/sni_routing.map.tpl"
SNI_MAP="/usr/local/etc/haproxy/maps/sni_routing.map"

# 替换环境变量并生成配置文件
sed "s/\${NF_XTLS_SERVER}/$NF_XTLS_SERVER/g" "$TEMPLATE" > "$CONFIG"

# 替换 SNI routing map 中的 REALITY_DEST 变量
# 需要转义正则表达式中的特殊字符（点号）
REALITY_DEST_ESCAPED=$(echo "$REALITY_DEST" | sed 's/\./\\./g')
sed "s/\${REALITY_DEST}/$REALITY_DEST_ESCAPED/g" "$SNI_MAP_TEMPLATE" > "$SNI_MAP"

# 安装 rsyslog
apt-get update -qq && apt-get install -y rsyslog

# 配置 rsyslog 启用 UDP 监听并处理 HAProxy 日志
cat > /etc/rsyslog.d/49-haproxy.conf << EOF
# 启用 UDP 监听
\$ModLoad imudp
\$UDPServerRun 514
\$UDPServerAddress 127.0.0.1

# 禁用文件同步延迟，实时写入
\$ActionFileDefaultTemplate RSYSLOG_TraditionalFileFormat
\$ActionFileEnableSync on
\$OMFileFlushInterval 1

# HAProxy 日志配置（实时写入，无缓冲）
local0.*    /var/log/haproxy/access.log;RSYSLOG_TraditionalFileFormat
& stop
EOF

# 启动 rsyslog
rsyslogd

# 等待 rsyslog 启动
sleep 2

# 验证配置文件语法
haproxy -c -f "$CONFIG"

# 启动 HAProxy
exec haproxy -f "$CONFIG"
