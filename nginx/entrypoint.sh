#!/bin/sh
# Nginx Entrypoint Script
# 在启动前检查证书是否存在，不存在则等待

# 证书文件
CERT_KEY="/etc/nginx/cert/default_key.pem"
CERT_CRT="/etc/nginx/cert/default_cert.pem"

# 等待证书文件生成
while [ ! -f "$CERT_KEY" ] || [ ! -f "$CERT_CRT" ]; do
    echo "Waiting for SSL certificates..."
    echo "  Key: $CERT_KEY - $([ -f "$CERT_KEY" ] && echo 'EXISTS' || echo 'NOT FOUND')"
    echo "  Cert: $CERT_CRT - $([ -f "$CERT_CRT" ] && echo 'EXISTS' || echo 'NOT FOUND')"
    sleep 30
done

echo "SSL certificates found, starting nginx..."

# 先运行 /docker-entrypoint.d/ 下的脚本，然后启动 nginx
/docker-entrypoint.sh 2>/dev/null || true
exec nginx -g 'daemon off;'
