#!/bin/sh
# render_stream.sh — 统一渲染 nginx stream 激活文件（xray.stream）
#
# 由 gen_env.sh / deploy.sh（经 gen_env）/ ngx_haproxy_switch.sh 复用。
# 编辑 .env（REALITY_DEST / NF_XTLS_SERVER / COMPOSE_FILE）后必须重新执行本脚本。
#
# 用法：
#   scripts/render_stream.sh [nginx|haproxy] [输出文件]
#     模式缺省按 .env 的 COMPOSE_FILE 推导（含 docker-compose-haproxy.yml → haproxy）
#     输出文件缺省为 nginx/conf/conf.d/xray.stream（供切换脚本渲染到临时路径做一致性比对）
#
# 约定：
#   - 只写 conf.d/xray.stream，不碰容器与日志；
#   - 渲染/校验失败绝不覆盖当前可用配置（临时文件 + mv 原子替换）；
#   - 校验 REALITY_DEST / NF_XTLS_SERVER 非空，避免生成无效 upstream/map。

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$ROOT_DIR/.env"
CONF_D="$ROOT_DIR/nginx/conf/conf.d"
SRC_NGX="$CONF_D/xray.stream.ngx"
SRC_HAPROXY="$CONF_D/xray.stream.haproxy"
TARGET="$CONF_D/xray.stream"

if [ -n "$2" ]; then
    TARGET="$2"
fi

log()  { echo "[render] $1"; }
fail() { echo "[render] ERROR: $1" >&2; exit 1; }

# ---- 读取模式参数 ----
MODE="$1"
if [ -z "$MODE" ]; then
    [ -f "$ENV_FILE" ] || fail "缺少 .env 且未显式指定模式（参数: nginx|haproxy）"
    COMPOSE_FILE=$(grep '^COMPOSE_FILE=' "$ENV_FILE" | cut -d'=' -f2-)
    case "$COMPOSE_FILE" in
        *docker-compose-haproxy.yml*) MODE="haproxy" ;;
        *)                            MODE="nginx"   ;;
    esac
fi
[ "$MODE" = "nginx" ] || [ "$MODE" = "haproxy" ] || fail "未知模式: $MODE（只能是 nginx|haproxy）"

# ---- 从 .env 读取渲染变量 ----
REALITY_DEST=""
NF_XTLS_SERVER=""
if [ -f "$ENV_FILE" ]; then
    REALITY_DEST=$(grep '^REALITY_DEST=' "$ENV_FILE" | cut -d'=' -f2- | tr -d '\r\n')
    NF_XTLS_SERVER=$(grep '^NF_XTLS_SERVER=' "$ENV_FILE" | cut -d'=' -f2- | tr -d '\r\n')
fi

TMP="$TARGET.tmp.$$"
trap 'rm -f "$TMP"' EXIT

if [ "$MODE" = "nginx" ]; then
    [ -f "$SRC_NGX" ] || fail "模板缺失: $SRC_NGX"
    [ -n "$REALITY_DEST" ] || fail ".env 中 REALITY_DEST 为空，拒绝生成无效 map"
    [ -n "$NF_XTLS_SERVER" ] || fail ".env 中 NF_XTLS_SERVER 为空，拒绝生成无效 upstream"

    # REALITY_DEST 中的点号转义为正则字面量（与 haproxy/entrypoint.sh 一致）
    REALITY_DEST_ESCAPED=$(echo "$REALITY_DEST" | sed 's/\./\\./g')

    sed -e "s|\${REALITY_DEST}|$REALITY_DEST_ESCAPED|g" \
        -e "s|\${NF_XTLS_SERVER}|$NF_XTLS_SERVER|g" \
        "$SRC_NGX" > "$TMP" || fail "sed 渲染失败"

    # 渲染结果自检：占位符必须全部替换
    if grep -q 'REALITY_DEST\|NF_XTLS_SERVER' "$TMP"; then
        rm -f "$TMP"
        fail "渲染结果仍含未替换占位符"
    fi
else
    [ -f "$SRC_HAPROXY" ] || fail "模板缺失: $SRC_HAPROXY"
    cat "$SRC_HAPROXY" > "$TMP" || fail "拷贝失败"
fi

mv "$TMP" "$TARGET"
trap - EXIT
log "模式=$MODE → 已生成 $TARGET"
