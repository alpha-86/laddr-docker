#!/bin/bash
# ngx_haproxy_switch.sh — 443 入口模式在线切换（nginx ↔ haproxy）
#
# 设计：向目标模式的"状态收敛"，而非简单改配置重启。
# 收敛判据（五项全满足才算到位，缺一不可）：
#   1) .env COMPOSE_FILE 与目标模式一致
#   2) 激活文件与"目标模式渲染结果"逐字节一致（渲染到临时文件后 cmp，
#      不与含 ${REALITY_DEST} 占位符的 xray.stream.ngx 直接比较）
#   3) 容器态：目标 haproxy → haproxy 容器 running；目标 nginx → haproxy 容器
#      不存在（docker stop + docker rm -f 双保险；restart:always 会在 daemon/
#      宿主机重启后唤醒仅 stop 的容器并抢占 443）
#   4) nginx 容器 running
#   5) 443 实际占用者与目标一致（见 ss_443_owner：优先 sudo ss，退化 TLS 探测）
#
# 安全保证：
#   - flock 防并发；.env 与激活文件经临时文件原子替换；
#   - 备份放独立临时目录（mktemp -d /tmp，700/600，.env 含密钥不进项目目录）；
#   - 渲染与 nginx -t 在释放当前 443 之前完成（nginx -t 只校验磁盘文件，不影响
#     运行态内存配置，HAProxy/nginx 持 443 期间可安全执行），失败即恢复且零影响；
#   - 容器操作直操 docker（stop/rm），不依赖 COMPOSE_FILE 是否识别该服务——
#     半完成状态下 compose 可能已不认识 haproxy；
#   - 任一步失败按"原模式"分别定义的流程自动回滚并校验恢复结果；
#   - 所有等待/端口/curl 校验均有超时与重试；curl 校验发新请求并按时间窗匹配日志。
#
# 用法（仅服务器本机执行）：
#   scripts/ngx_haproxy_switch.sh nginx|haproxy|status
#
# 退出码：0=已处于目标模式或切换成功；1=渲染/nginx -t 前置失败（零影响）；
#         2=回滚后校验仍不通过（需人工介入，备份目录保留）；3=切换失败但已自动回滚恢复

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$ROOT_DIR"

ENV_FILE=".env"
CONF_D="nginx/conf/conf.d"
ACTIVE_FILE="$CONF_D/xray.stream"
LOCK_FILE="/tmp/.ngx_haproxy_switch.lock"
RENDER="$SCRIPT_DIR/render_stream.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[FAIL]${NC} $1"; }

die() { log_error "$1"; exit 1; }

# ---- 基础前提 ----
[ -f "$ENV_FILE" ]   || die "缺少 $ENV_FILE，请先运行 gen_env.sh"
[ -d "$CONF_D" ]     || die "缺少 $CONF_D"
command -v docker >/dev/null 2>&1 || die "docker 不可用"
docker compose version >/dev/null 2>&1 || die "docker compose 插件不可用"
[ -f "$RENDER" ]     || die "缺少 $RENDER"

# ---- 并发锁 ----
exec 200>"$LOCK_FILE"
flock -n 200 || die "另一个切换实例正在运行（$LOCK_FILE 被持有）"

# ---- ss 包装：容器进程属 root，普通用户 ss 看不到 users: 字段 ----
if sudo -n true 2>/dev/null; then
    SS() { sudo -n ss "$@"; }
else
    SS() { ss "$@"; }
    log_warn "sudo 不可用，443 属主检查退化为'端口监听 + TLS 握手'探测"
fi

# ---- 工具函数 ----
compose_file_has_haproxy() {
    grep '^COMPOSE_FILE=' "$ENV_FILE" | cut -d'=' -f2- | grep -q 'docker-compose-haproxy.yml'
}

current_mode() {
    if compose_file_has_haproxy; then echo "haproxy"; else echo "nginx"; fi
}

haproxy_container_exists() { [ -n "$(docker ps -aq --filter 'name=^haproxy$')" ]; }
haproxy_container_running() { [ -n "$(docker ps -q --filter 'name=^haproxy$')" ]; }
# restart:always 下配置错误会崩溃重启，running 状态只在重启间隔瞬时成立——
# 连续两次采样（间隔 2s）均为 running 才算稳定运行（6b 注入实测：单采样被瞬时窗口骗过）
haproxy_stable_running() {
    haproxy_container_running || return 1
    sleep 2
    haproxy_container_running
}
nginx_container_running()   { [ -n "$(docker ps -q --filter 'name=^nginx$')" ]; }

# 删除 haproxy 容器（直操 docker，与 COMPOSE_FILE 状态无关）；不存在则跳过
remove_haproxy_container() {
    if haproxy_container_exists; then
        docker stop haproxy >/dev/null 2>&1
        docker rm -f haproxy >/dev/null 2>&1 || return 1
    fi
    return 0
}

# 443 当前占用者描述（可能为空：无 sudo 且进程属 root 时）
ss_443_owner() {
    SS -tlnp 2>/dev/null | grep -E ':443[[:space:]]' | grep -o 'users:.*' | head -1
}

# 443 是否可完成 TLS 握手（属主不可见时的退化探测）
tls_443_ok() {
    echo | timeout 5 openssl s_client -connect 127.0.0.1:443 -servername localhost \
        >/dev/null 2>&1
}

# 等待 443 属主 = 目标（参数1: nginx|haproxy；参数2: 超时秒）
wait_443_owner() {
    local want="$1" end=$((SECONDS + ${2:-30})) owner
    while [ $SECONDS -lt $end ]; do
        owner="$(ss_443_owner)"
        if [ -n "$owner" ]; then
            case "$want:$owner" in
                nginx:*nginx*)     return 0 ;;
                haproxy:*haproxy*) return 0 ;;
            esac
        else
            # 属主不可见：端口在听 + TLS 可握手 + 目标容器 running 即认为到位
            if SS -tln 2>/dev/null | grep -qE ':443[[:space:]]' \
                && tls_443_ok \
                && { [ "$want" != "nginx" ] || nginx_container_running; } \
                && { [ "$want" != "haproxy" ] || haproxy_container_running; }; then
                return 0
            fi
        fi
        sleep 2
    done
    return 1
}

# 等待 443 完全释放
wait_443_free() {
    local end=$((SECONDS + ${1:-30}))
    while [ $SECONDS -lt $end ]; do
        SS -tln 2>/dev/null | grep -qE ':443[[:space:]]' || return 0
        sleep 2
    done
    return 1
}

# 渲染目标模式到临时文件并输出路径（调用方 rm）；失败返回 1
render_to_tmp() {
    local tmp
    tmp="$(mktemp /tmp/xray.stream.check.XXXXXX)" || return 1
    if sh "$RENDER" "$1" "$tmp" >/dev/null 2>&1; then
        echo "$tmp"; return 0
    fi
    rm -f "$tmp"; return 1
}

nginx_config_test() { docker exec nginx nginx -t >/dev/null 2>&1; }

atomic_replace() {
    # 注意：不能写成 local src="$1" dst="$2" tmp="$dst..." ——
    # local 所有赋值的展开发生在命令执行前，$dst 此刻未定义，set -u 下直接报错
    local src="$1" dst="$2"
    local tmp="$dst.tmp.switch.$$"
    cp "$src" "$tmp" && mv -f "$tmp" "$dst"
}

# ---- 验证域名选择（review：不能简单拼"首个证书域名"） ----
# 从 nginx 容器证书提取 SAN；优先通配符 SAN 构造随机子域（并校验覆盖）；
# 无通配符则选不满足路由前缀规则且非 REALITY_DEST 的已覆盖域名。
cert_sans() {
    docker exec nginx openssl x509 -in /etc/nginx/cert/default_cert.pem -noout -text 2>/dev/null \
        | grep -A1 'Subject Alternative Name' | tail -1 \
        | sed 's/DNS://g' | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'
}

domain_covered() {  # $1=domain，stdin=SAN 列表
    local d="$1" san suffix
    while read -r san; do
        case "$san" in
            "*."*) suffix="${san#\*.}"
                   case "$d" in "$suffix"|*."$suffix") return 0 ;; esac ;;
            *) [ "$d" = "$san" ] && return 0 ;;
        esac
    done
    return 1
}

pick_verify_domain() {
    local sans wc base cand plain reality
    reality="$(grep '^REALITY_DEST=' "$ENV_FILE" | cut -d'=' -f2- | tr -d '\r\n')"
    sans="$(cert_sans)"
    [ -n "$sans" ] || return 1

    # 1) 优先：通配符 SAN → 随机子域（带随机数，避免匹配历史日志）
    wc="$(echo "$sans" | grep '^\*\.' | head -1)"
    if [ -n "$wc" ]; then
        base="${wc#\*.}"
        cand="sw$RANDOM.$base"
        if echo "$sans" | domain_covered "$cand"; then
            echo "$cand"; return 0
        fi
    fi

    # 2) 退化：已覆盖、非路由前缀、非 REALITY_DEST 的 SAN（走默认 nginx 后端）
    plain="$(echo "$sans" | grep -v '^\*' | while read -r d; do
        [ "$d" = "$reality" ] && continue
        case "$(echo "$d" | cut -d'.' -f1)" in
            x|xyz|api|dt|ai|web|app|cdn|nf|netflix|nfx|nfv) continue ;;
        esac
        echo "$d"; break
    done)"
    [ -n "$plain" ] && { echo "$plain"; return 0; }
    return 1
}

# ---- 收敛检查 ----
check_converged() {
    local target="$1" ok=true tmp

    if [ "$(current_mode)" = "$target" ]; then
        log_info "  [OK] .env COMPOSE_FILE 与 $target 模式一致"
    else
        log_warn "  [DRIFT] .env COMPOSE_FILE 当前为 $(current_mode) 模式"
        ok=false
    fi

    tmp="$(render_to_tmp "$target")" || tmp=""
    if [ -n "$tmp" ] && [ -f "$ACTIVE_FILE" ] && cmp -s "$tmp" "$ACTIVE_FILE"; then
        log_info "  [OK] 激活文件与 $target 模式渲染结果一致"
    else
        log_warn "  [DRIFT] 激活文件与 $target 模式不一致（或缺失）"
        ok=false
    fi
    [ -n "$tmp" ] && rm -f "$tmp"

    if [ "$target" = "haproxy" ]; then
        if haproxy_container_running; then
            log_info "  [OK] haproxy 容器运行中"
        else
            log_warn "  [DRIFT] haproxy 容器未运行"
            ok=false
        fi
    else
        if haproxy_container_exists; then
            log_warn "  [DRIFT] haproxy 容器仍存在（应已删除）"
            ok=false
        else
            log_info "  [OK] haproxy 容器不存在"
        fi
    fi

    if nginx_container_running; then
        log_info "  [OK] nginx 容器运行中"
    else
        log_warn "  [DRIFT] nginx 容器未运行"
        ok=false
    fi

    local owner
    owner="$(ss_443_owner)"
    case "$target:$owner" in
        haproxy:*haproxy*) log_info "  [OK] 443 由 haproxy 监听" ;;
        nginx:*nginx*)     log_info "  [OK] 443 由 nginx 监听" ;;
        *:)
            # 属主不可见：能 TLS 握手 + 端口在听则视为可接受（告警但不判漂移）
            if SS -tln 2>/dev/null | grep -qE ':443[[:space:]]' && tls_443_ok; then
                log_warn "  [WARN] 443 属主不可见（无 sudo），TLS 探测通过"
            else
                log_warn "  [DRIFT] 443 不可服务"
                ok=false
            fi ;;
        *)  log_warn "  [DRIFT] 443 占用者与 $target 不符: $owner"
            ok=false ;;
    esac

    $ok && return 0 || return 1
}

# ---- 新请求验证（偏移量方案：只匹配本次请求后追加的日志，不用旧日志） ----
# curl 统一走 ${CURL_BIN:-curl}——测试可用 CURL_BIN=/path/to/stub 注入失败（见 README-003 3.8）
verify_new_request() {
    local mode="$1" domain attempt log_line route_want log_file pos
    domain="$(pick_verify_domain)" || {
        log_warn "无法从证书选出验证域名，跳过 curl 验证（已做端口/容器校验）"
        return 0
    }

    if [ "$mode" = "nginx" ]; then
        route_want="backend:ngx"; log_file="log/nginx_stream.log"
    else
        route_want="ngx_backend"; log_file="log/haproxy_access.log"
    fi
    [ -f "$log_file" ] || touch "$log_file" 2>/dev/null || true

    for attempt in 1 2 3; do
        pos=$(wc -c < "$log_file" 2>/dev/null || echo 0)
        log_info "  发起验证请求 ($attempt/3): https://$domain/ (期望路由 → $route_want, 日志偏移 $pos)"
        "${CURL_BIN:-curl}" -sk --max-time 10 --resolve "$domain:443:127.0.0.1" \
            "https://$domain/?switchcheck=$RANDOM" >/dev/null 2>&1 || { sleep 2; continue; }

        sleep 1  # 等待日志落盘
        # 只检查 pos 之后追加的新内容；时间戳仅作辅助展示，不作判定
        log_line="$(tail -c +$((pos + 1)) "$log_file" 2>/dev/null | grep "sni:$domain" | tail -1)"

        if [ -n "$log_line" ]; then
            if echo "$log_line" | grep -q "$route_want"; then
                log_ok "  新请求验证通过: $log_line"
                return 0
            else
                log_warn "  日志行路由目标不符（期望 $route_want）: $log_line"
            fi
        else
            log_warn "  本次请求未产生新路由日志（sni:$domain）"
        fi
        sleep 2
    done
    return 1
}

# ---- 备份（独立临时目录，600/700，.env 含密钥不进项目目录） ----
make_backup() {
    BAK_DIR="$(mktemp -d /tmp/ngx-switch-backup.XXXXXX)" || return 1
    chmod 700 "$BAK_DIR"
    cp -a "$ENV_FILE" "$BAK_DIR/env" && chmod 600 "$BAK_DIR/env"
    if [ -f "$ACTIVE_FILE" ]; then
        cp -a "$ACTIVE_FILE" "$BAK_DIR/xray.stream" && chmod 600 "$BAK_DIR/xray.stream"
    fi
}

# ---- 失败回滚（按原模式分别定义，直操 docker 与 compose 状态无关） ----
# 回滚是终止性操作：成功恢复后 exit 3（切换失败但已回滚），恢复失败 exit 2。
# 调用点一律 `|| rollback <原模式>`——若 rollback 只是 return，调用方会继续执行后续步骤，
# 实测出现"回滚后继续 verify → 二次回滚 → 最终报已切换成功 rc=0"的严重误导（6b 注入暴露）。
rollback() {
    local orig="$1"
    log_error "切换失败，开始自动回滚到 $orig 模式..."

    if [ "$orig" = "nginx" ]; then
        # 回滚到 nginx：先确保 haproxy 容器不存在（compose 可能已不认识它），
        # 确认 443 释放后再恢复文件并重启 nginx 接管
        remove_haproxy_container || true
        wait_443_free 30 || true
        [ -f "$BAK_DIR/env" ]        && atomic_replace "$BAK_DIR/env" "$ENV_FILE"
        [ -f "$BAK_DIR/xray.stream" ] && atomic_replace "$BAK_DIR/xray.stream" "$ACTIVE_FILE"
        docker compose restart nginx >/dev/null 2>&1
        if wait_443_owner nginx 30; then
            rm -rf "$BAK_DIR"   # 回滚成功：系统状态与原一致，备份无保留价值
            log_ok "回滚完成：已恢复 $orig 模式"
            exit 3
        fi
    else
        # 回滚到 haproxy：恢复 .env 与空激活文件 → 重启 nginx 释放 443 →
        # 用新模板重建 haproxy（含 send-proxy-v2）
        [ -f "$BAK_DIR/env" ]        && atomic_replace "$BAK_DIR/env" "$ENV_FILE"
        [ -f "$BAK_DIR/xray.stream" ] && atomic_replace "$BAK_DIR/xray.stream" "$ACTIVE_FILE"
        docker compose restart nginx >/dev/null 2>&1
        wait_443_free 30 || true
        docker compose up -d >/dev/null 2>&1
        if haproxy_stable_running && wait_443_owner haproxy 30; then
            rm -rf "$BAK_DIR"   # 回滚成功：系统状态与原一致，备份无保留价值
            log_ok "回滚完成：已恢复 $orig 模式"
            exit 3
        fi
    fi

    log_error "回滚后校验仍不通过！备份目录: $BAK_DIR（含 .env，注意保密）"
    exit 2
}

# ---- 切换：→ nginx ----
# 参数1 = 切换前模式（回滚目标）。自修复场景（当前=目标）下回滚目标必须是原模式本身，
# 不能硬编码对端——实测硬编码回滚到 haproxy 会把 .env=nginx 的系统回滚成 haproxy 期待，
# 最终 exit 2 且 443 无人持有（半完成 7B 注入暴露）。
switch_to_nginx() {
    local orig="$1"
    log_info "[1/5] 渲染 nginx 版激活文件并 nginx -t（不触碰运行态，失败零影响）..."
    sh "$RENDER" nginx || die "渲染失败，未做任何变更"
    if ! nginx_config_test; then
        # 还原激活文件为切换前状态（备份优先，与运行态一致）；
        # 不可用渲染对端模式兜底（仅当从 haproxy 切换时等价）
        if [ -f "$BAK_DIR/xray.stream" ]; then
            atomic_replace "$BAK_DIR/xray.stream" "$ACTIVE_FILE"
        else
            tmp="$(render_to_tmp haproxy 2>/dev/null)" || tmp=""
            [ -n "$tmp" ] && { [ -f "$ACTIVE_FILE" ] && atomic_replace "$tmp" "$ACTIVE_FILE"; rm -f "$tmp"; }
        fi
        die "nginx -t 失败，已恢复激活文件，443 仍由原入口持有（服务未受影响）"
    fi
    log_ok "渲染与 nginx -t 通过"

    # haproxy 容器存在才需移除并等待 443 释放；自修复（nginx→nginx）时 443 由
    # nginx 持续持有，wait_443_free 必然超时——不能无条件等待（半完成 7B 注入暴露）
    if haproxy_container_exists; then
        log_info "[2/5] 停止并删除 haproxy 容器（直操 docker，半完成状态下 compose 可能已不认识它）..."
        remove_haproxy_container || rollback "$orig"
        wait_443_free 30 || rollback "$orig"
        log_ok "haproxy 已删除，443 已释放"
    fi

    log_info "[3/5] 原子更新 .env（移除 docker-compose-haproxy.yml）..."
    sed 's/:docker-compose-haproxy\.yml//g' "$BAK_DIR/env" | grep -v '^$' \
        > "$ENV_FILE.tmp.switch.$$" \
        && mv -f "$ENV_FILE.tmp.switch.$$" "$ENV_FILE" \
        || rollback "$orig"
    log_ok ".env 已更新为 nginx 模式"

    log_info "[4/5] 重启 nginx 接管 443..."
    docker compose restart nginx >/dev/null 2>&1 || rollback "$orig"
    wait_443_owner nginx 30 || rollback "$orig"
    log_ok "443 已由 nginx 监听"

    log_info "[5/5] 新请求验证..."
    verify_new_request nginx || rollback "$orig"

    log_ok "已切换到 nginx 模式"
}

# ---- 切换：→ haproxy ----
# 参数1 = 切换前模式（回滚目标），同上
switch_to_haproxy() {
    local orig="$1"
    log_info "[1/5] 放置 haproxy 版（空）激活文件并 nginx -t..."
    sh "$RENDER" haproxy || die "渲染失败，未做任何变更"
    if ! nginx_config_test; then
        [ -f "$BAK_DIR/xray.stream" ] && atomic_replace "$BAK_DIR/xray.stream" "$ACTIVE_FILE"
        die "nginx -t 失败，已恢复激活文件，443 仍由 nginx 持有（服务未受影响）"
    fi
    log_ok "nginx -t 通过（nginx 即将释放 443）"

    log_info "[2/5] 原子更新 .env（追加 docker-compose-haproxy.yml）..."
    if compose_file_has_haproxy; then
        : # 已是目标（半完成状态）
    else
        sed 's|^\(COMPOSE_FILE=.*\)$|\1:docker-compose-haproxy.yml|' "$BAK_DIR/env" \
            > "$ENV_FILE.tmp.switch.$$" \
            && mv -f "$ENV_FILE.tmp.switch.$$" "$ENV_FILE" \
            || rollback "$orig"
    fi
    log_ok ".env 已更新为 haproxy 模式"

    log_info "[3/5] 重启 nginx 释放 443..."
    docker compose restart nginx >/dev/null 2>&1 || rollback "$orig"
    # 仅当原模式为 nginx（nginx 原持有 443）才需等待释放；自修复（haproxy→haproxy）
    # 时 443 由 haproxy 持续持有，等待释放必然超时（半完成 7C 场景）
    if [ "$orig" = "nginx" ]; then
        wait_443_free 30 || rollback "$orig"
    fi
    log_ok "443 已释放"

    log_info "[4/5] 启动 haproxy（新模板渲染，含 send-proxy-v2）..."
    docker compose up -d >/dev/null 2>&1 || rollback "$orig"
    haproxy_stable_running || rollback "$orig"
    wait_443_owner haproxy 30 || rollback "$orig"
    log_ok "443 已由 haproxy 监听"

    log_info "[5/5] 新请求验证..."
    verify_new_request haproxy || rollback "$orig"

    log_ok "已切换到 haproxy 模式"
}

# ---- status ----
status() {
    local mode
    mode="$(current_mode)"
    echo ""
    log_info "当前模式（按 .env COMPOSE_FILE）: $mode"
    echo ""
    log_info "容器状态:"
    docker ps -a --filter 'name=^haproxy$' --filter 'name=^nginx$' \
        --format '  {{.Names}}\t{{.Status}}' 2>/dev/null || true
    echo ""
    local owner
    owner="$(ss_443_owner)"
    log_info "443 监听: ${owner:-属主不可见（无 sudo）}"
    echo ""
    log_info "收敛检查（目标 = $mode）:"
    if check_converged "$mode"; then
        log_ok "系统已收敛到 $mode 模式"
    else
        log_warn "存在偏离项，执行 scripts/ngx_haproxy_switch.sh $mode 可自动修复"
    fi
    echo ""
}

# ---- 主入口 ----
main() {
    local cmd="${1:-}"
    case "$cmd" in
        status)
            status
            ;;
        nginx|haproxy)
            local target="$cmd" cur
            cur="$(current_mode)"
            echo ""
            log_info "目标模式: $target（当前: $cur）"
            make_backup || die "无法创建备份目录"
            echo ""
            log_info "收敛检查:"
            if check_converged "$target"; then
                log_ok "系统已处于 $target 模式，无需切换"
                rm -rf "$BAK_DIR"
                exit 0
            fi
            log_warn "未完全收敛，开始执行切换/修复...（备份: $BAK_DIR）"
            echo ""
            if [ "$target" = "nginx" ]; then switch_to_nginx "$cur"; else switch_to_haproxy "$cur"; fi
            rm -rf "$BAK_DIR"   # 切换成功：清理含 .env 的备份，避免敏感备份长期积累
            echo ""
            log_ok "完成。可用 scripts/ngx_haproxy_switch.sh status 查看状态"
            echo ""
            ;;
        *)
            echo "用法: $0 nginx|haproxy|status"
            echo ""
            echo "  nginx|haproxy  切换到目标模式（幂等；可修复半完成状态；失败自动回滚）"
            echo "  status         查看当前模式/容器/443 占用/收敛情况"
            exit 1
            ;;
    esac
}

main "$@"
