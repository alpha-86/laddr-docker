#!/bin/bash

# laddr-docker 环境变量生成脚本
# 用途：初始化目录结构并生成或更新 .env 配置文件
#
# 运行模式：
#   全新 .env + 交互终端            → 向导模式（分块询问，默认值回车即过）
#   已有 .env + -i/--interactive    → 更新向导（按块编辑，敏感项脱敏显示）
#   已有 .env + 交互终端（无参数）  → 静默合并（历史行为），末尾提示 -i
#   非交互终端（deploy.sh）/ --batch → 纯静默（行为与历史版本一致，见 README-005）
#
# 选项：
#   -i, --interactive   已有 .env 时进入更新向导（需交互终端）
#       --advanced      向导中启用环境目录等高级变量的编辑
#       --batch         强制静默模式（等价于非交互终端）
#   -h, --help          显示帮助

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ENV_FILE="$SCRIPT_DIR/.env"

INTERACTIVE=0
ADVANCED=0
BATCH=0

EXISTING_VARS_TEMP=""
FINAL_VARS_TEMP=""
NEW_VARS_TEMP=""
CHANGED_VARS_TEMP=""

usage() {
    echo "用法: $0 [-i|--interactive] [--advanced] [--batch] [-h|--help]"
    echo ""
    echo "模式："
    echo "  全新 .env + 交互终端            向导模式（分块询问）"
    echo "  已有 .env + -i                  更新向导（按块编辑）"
    echo "  已有 .env + 交互终端（无参数）  静默合并，末尾提示 -i"
    echo "  非交互终端 / --batch            纯静默（deploy.sh 路径，行为同历史版本）"
}

cleanup() {
    [ -n "$EXISTING_VARS_TEMP" ] && rm -f "$EXISTING_VARS_TEMP"
    [ -n "$FINAL_VARS_TEMP" ] && rm -f "$FINAL_VARS_TEMP"
    [ -n "$NEW_VARS_TEMP" ] && rm -f "$NEW_VARS_TEMP"
    [ -n "$CHANGED_VARS_TEMP" ] && rm -f "$CHANGED_VARS_TEMP"
}
trap cleanup EXIT

# ========== 生成器（历史实现保留） ==========

gen_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [ -f /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || echo "$(date +%s)-$(shuf -i 1000-9999 -n 1 2>/dev/null || echo 1234)"
    fi
}

# REALITY 密钥对生成（xray x25519 标准输出：PrivateKey / Password 两行）
# 注意：历史上存在 openssl 兜底，会生成互不匹配的私钥/公钥占位值，已移除——
# 本项目部署目标必有 docker，无 docker 视为致命错误（见 README-005 §2.5）
gen_reality_keypair() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "ERROR: 生成 REALITY 密钥对需要 docker（xray x25519）" >&2
        return 1
    fi
    local keypair_output
    keypair_output=$(docker run --rm teddysun/xray xray x25519 2>/dev/null)
    if [ -z "$keypair_output" ]; then
        echo "ERROR: docker 运行 xray x25519 失败，无法生成 REALITY 密钥对" >&2
        return 1
    fi
    echo "$keypair_output"
}

# 解析 xray x25519 输出（兼容两种格式：旧版 "Password: xxx"、新版 "Password (PublicKey): xxx"，后者还有 Hash32 行）
# 双模式：带参数解析该字符串；无参数则读 stdin（供 docker 输出管道使用）。docker 在 pty 下输出带 \r，统一剥除。
parse_reality_priv() { if [ -n "${1:-}" ]; then printf '%s' "$1"; else cat; fi | awk '/PrivateKey:/ {print $NF}' | tr -d '\r'; }
parse_reality_pub()  { if [ -n "${1:-}" ]; then printf '%s' "$1"; else cat; fi | awk '/[Pp]assword/ {print $NF}' | tr -d '\r'; }

# 由私钥推导公钥（自定义私钥时用；需要 docker）
derive_reality_pub() {
    docker run --rm teddysun/xray xray x25519 -i "$1" 2>/dev/null | parse_reality_pub
}

gen_reality_short_id() { openssl rand -hex 2 2>/dev/null || echo "a1b2"; }

# ========== 已有 .env 读取（历史实现保留） ==========

load_existing() {
    EXISTING_VARS_TEMP=$(mktemp)
    if [ -f "$ENV_FILE" ]; then
        while IFS='=' read -r key value; do
            # 跳过注释和空行
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${key// }" ]] && continue
            echo "$key=$value" >> "$EXISTING_VARS_TEMP"
        done < "$ENV_FILE"
    fi
}

get_existing_value() { grep "^$1=" "$EXISTING_VARS_TEMP" 2>/dev/null | cut -d'=' -f2-; }
var_exists()         { grep -q "^$1=" "$EXISTING_VARS_TEMP" 2>/dev/null; }

# ========== 最终值映射（VARS 顺序之外按名存取） ==========

init_final() { FINAL_VARS_TEMP=$(mktemp); }

set_final() {
    local name="$1" value="$2" tmp="${FINAL_VARS_TEMP}.tmp"
    grep -v "^${name}=" "$FINAL_VARS_TEMP" > "$tmp" 2>/dev/null
    mv "$tmp" "$FINAL_VARS_TEMP"
    printf '%s=%s\n' "$name" "$value" >> "$FINAL_VARS_TEMP"
}

get_final() { grep "^$1=" "$FINAL_VARS_TEMP" 2>/dev/null | cut -d'=' -f2-; }

# ========== 校验与脱敏 ==========

is_secret_var() {
    case "$1" in
        Ali_Key|Ali_Secret|CF_Key|XRAY_UUID|XRAY_UUID_9000|XRAY_UUID_9001|REALITY_PRIVATE_KEY|REALITY_PUBLIC_KEY)
            return 0 ;;
        *) return 1 ;;
    esac
}

mask_value() {
    if is_secret_var "$1" && [ -n "$2" ]; then
        printf '%s...' "${2:0:3}"
    else
        printf '%s' "$2"
    fi
}

is_uuid() { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
is_short_id() { [[ "$1" =~ ^[0-9a-fA-F]{2,16}$ ]]; }

# ========== 交互小部件 ==========

# 通用询问：空输入 = 默认值（default 为空则允许空返回）
ask() {
    local label="$1" default="${2:-}" input
    if [ -n "$default" ]; then
        read -r -p "$label [$default]: " input
        [ -z "$input" ] && input="$default"
    else
        read -r -p "$label: " input
    fi
    printf '%s' "$input"
}

# 非空询问：空值重问
ask_nonempty() {
    local label="$1" default="${2:-}" input
    while :; do
        input=$(ask "$label" "$default")
        [ -n "$input" ] && { printf '%s' "$input"; return; }
        echo "  不能为空，请重新输入"
    done
}

# 通用单选：选项串形如 "1) A  2) B"，default 为选项值；校验输入必须是有效选项值
ask_choice() {
    local label="$1" options="$2" default="$3" input
    while :; do
        read -r -p "$label: $options [$default]: " input
        [ -z "$input" ] && input="$default"
        case "|$4|" in *"|$input|"*) printf '%s' "$input"; return ;; esac
        echo "  无效选择，请重新输入"
    done
}

# 密钥询问（不回显；空 = 保留/留空）
ask_secret_fresh() {
    local label="$1" input
    read -r -s -p "$label (Enter=留空): " input; echo
    printf '%s' "$input"
}

# 更新向导：普通变量编辑（Enter=保留, '-'=清空, 输入覆盖）
edit_plain() {
    local name="$1" label="$2" cur input
    cur=$(get_final "$name")
    read -r -p "$label [$(mask_value "$name" "$cur")] (Enter=保留, '-'=清空, 输入覆盖): " input
    case "$input" in
        "") : ;;
        -) set_final "$name" "" ;;
        *) set_final "$name" "$input" ;;
    esac
}

# 更新向导：不允许清空的普通变量编辑
edit_plain_nonempty() {
    local name="$1" label="$2" cur input
    cur=$(get_final "$name")
    while :; do
        read -r -p "$label [$(mask_value "$name" "$cur")] (Enter=保留, 输入覆盖): " input
        case "$input" in
            "") return ;;
            -) echo "  该变量不允许为空" ;;
            *) set_final "$name" "$input"; return ;;
        esac
    done
}

# 更新向导：密钥变量编辑（不回显；Enter=保留, '-'=清空, 输入覆盖）
edit_secret() {
    local name="$1" label="$2" cur input
    cur=$(get_final "$name")
    if [ -n "$cur" ]; then
        read -r -s -p "$label [$(mask_value "$name" "$cur")] (Enter=保留, '-'=清空, 输入覆盖): " input; echo
    else
        read -r -s -p "$label (Enter=跳过, '-'=清空, 输入设置): " input; echo
    fi
    case "$input" in
        "") : ;;
        -) set_final "$name" "" ;;
        *) set_final "$name" "$input" ;;
    esac
}

# 更新向导：UUID 编辑（Enter=保留, r=重新生成, main=跟随主（仅 allow_main=1）, 输入需过格式校验）
edit_uuid() {
    local name="$1" label="$2" allow_main="$3" main="${4:-}" cur input
    cur=$(get_final "$name")
    while :; do
        if [ "$allow_main" = 1 ]; then
            read -r -p "$label [$(mask_value "$name" "$cur")] (Enter=保留, r=重新生成, main=跟随主, 输入覆盖): " input
        else
            read -r -p "$label [$(mask_value "$name" "$cur")] (Enter=保留, r=重新生成, 输入覆盖): " input
        fi
        case "$input" in
            "") return ;;
            r|R)
                set_final "$name" "$(gen_uuid)"
                cur=$(get_final "$name")
                echo "  已生成: $(mask_value "$name" "$cur")" ;;
            main|MAIN)
                if [ "$allow_main" = 1 ]; then
                    set_final "$name" "$main"; return
                fi
                echo "  该变量不支持 main" ;;
            -) echo "  UUID 不允许为空" ;;
            *)
                if is_uuid "$input"; then set_final "$name" "$input"; return
                else echo "  非法 UUID 格式"; fi ;;
        esac
    done
}

# 向导（fresh）：UUID 询问，输出最终值；Enter=接受, r=重新生成, 输入自定义
# 注意：信息展示一律走 stderr，stdout 只输出最终结果（调用处用 $(...) 捕获）
prompt_uuid() {
    local label="$1" cur="$2" input
    while :; do
        read -r -p "$label [$cur] (Enter=接受, r=重新生成, 输入自定义): " input
        case "$input" in
            "") printf '%s' "$cur"; return ;;
            r|R) cur=$(gen_uuid); echo "  新生成: ${cur:0:8}..." >&2 ;;
            *)
                if is_uuid "$input"; then printf '%s' "$input"; return
                else echo "  非法 UUID 格式，请重试" >&2; fi ;;
        esac
    done
}

# 向导（fresh）：端口 UUID 询问，默认跟随主 UUID；Enter=跟随, r=独立生成, 输入自定义
prompt_uuid_port() {
    local label="$1" main="$2" input
    while :; do
        read -r -p "$label [跟随主 UUID ${main:0:8}...] (Enter=跟随, r=独立生成, 输入自定义): " input
        case "$input" in
            "") printf '%s' "$main"; return ;;
            r|R) printf '%s' "$(gen_uuid)"; return ;;
            *)
                if is_uuid "$input"; then printf '%s' "$input"; return
                else echo "  非法 UUID 格式，请重试"; fi ;;
        esac
    done
}

# 向导（fresh）：REALITY 密钥对确认；输出 "私钥 公钥"
# 注意：信息展示一律走 stderr，stdout 只输出最终结果（调用处用 $(...) 捕获）
prompt_reality_pair() {
    local priv="$REALITY_PRIV_DEF" pub="$REALITY_PUB_DEF" blob input derived
    while :; do
        echo "  REALITY PublicKey: $pub" >&2
        read -r -p "REALITY 密钥对 (Enter=接受, r=重新生成, 粘贴私钥=自定义): " input
        case "$input" in
            "") printf '%s %s' "$priv" "$pub"; return ;;
            r|R)
                blob=$(gen_reality_keypair) || return 1
                priv=$(parse_reality_priv "$blob")
                pub=$(parse_reality_pub "$blob") ;;
            *)
                derived=$(derive_reality_pub "$input")
                if [ -n "$derived" ]; then
                    printf '%s %s' "$input" "$derived"; return
                fi
                echo "  无法由该私钥推导公钥（需 docker 运行 xray x25519 -i），请重试" >&2 ;;
        esac
    done
}

# 向导（fresh/update 共用）：shortId 编辑（存储格式 ["xxxx"]；显示裸值）
edit_short_id() {
    local name="REALITY_SHORT_IDS" label="$1" cur raw input
    cur=$(get_final "$name")
    raw=$(printf '%s' "$cur" | tr -d '["]')
    while :; do
        read -r -p "$label [\"$raw\"] (Enter=保留, r=重新生成, 输入覆盖): " input
        case "$input" in
            "") return ;;
            r|R) set_final "$name" "[\"$(gen_reality_short_id)\"]"; return ;;
            *)
                if is_short_id "$input"; then set_final "$name" "[\"$input\"]"; return
                else echo "  非法 shortId（2-16 位十六进制）"; fi ;;
        esac
    done
}

# 更新向导：REALITY 私钥编辑（Enter=保留, r=重新生成密钥对并同步公钥, 粘贴私钥=推导公钥）
edit_reality_priv() {
    local cur blob priv pub input derived
    cur=$(get_final REALITY_PRIVATE_KEY)
    while :; do
        read -r -p "REALITY_PRIVATE_KEY [$(mask_value REALITY_PRIVATE_KEY "$cur")] (Enter=保留, r=重新生成密钥对, 粘贴私钥=自定义): " input
        case "$input" in
            "") return ;;
            r|R)
                blob=$(gen_reality_keypair) || return 1
                priv=$(parse_reality_priv "$blob")
                pub=$(parse_reality_pub "$blob")
                set_final REALITY_PRIVATE_KEY "$priv"
                set_final REALITY_PUBLIC_KEY "$pub"
                echo "  已生成新密钥对，PublicKey: ${pub:0:3}..."
                return ;;
            *)
                derived=$(derive_reality_pub "$input")
                if [ -n "$derived" ]; then
                    set_final REALITY_PRIVATE_KEY "$input"
                    set_final REALITY_PUBLIC_KEY "$derived"
                    echo "  公钥已同步推导: ${derived:0:3}..."
                    return
                fi
                echo "  无法由该私钥推导公钥（需 docker 运行 xray x25519 -i），请重试" ;;
        esac
    done
}

# 块闸门：Enter=跳过，e=编辑；返回 0 表示进入编辑
confirm_block() {
    local input
    read -r -p "【$1】 Enter=跳过  e=编辑: " input
    [ "$input" = "e" ] || [ "$input" = "E" ]
}

# ========== 模式一：全新向导 ==========

wizard_fresh() {
    echo ""
    echo "========== laddr-docker 环境配置向导（全新初始化） =========="

    local input provider ca main_uuid pair rpriv rpub

    # ---- 入口模式 ----
    echo ""
    echo "【入口模式】"
    local compose_file="docker-compose.yml:docker-compose-xray.yml"
    read -r -p "启用 HAProxy 作为 443 入口？[y/N] " input
    if [ "$input" = "y" ] || [ "$input" = "Y" ]; then
        compose_file="docker-compose.yml:docker-compose-xray.yml:docker-compose-haproxy.yml"
        echo "已选择 HAProxy 入口模式"
    else
        echo "使用默认 Nginx 入口模式"
    fi
    set_final COMPOSE_FILE "$compose_file"

    # ---- 环境目录（仅 --advanced）----
    if [ "$ADVANCED" = 1 ]; then
        echo ""
        echo "【环境目录】（直接回车使用默认值）"
        # 先问根目录；其余路径若仍持原默认值，跟随新根（保持独立编辑能力，仅级联未动过的项）
        edit_plain_nonempty DOCKER_BOX_HOME DOCKER_BOX_HOME
        local new_home old_home sub_var sub_default
        new_home=$(get_final DOCKER_BOX_HOME)
        if [ "$new_home" != "$SCRIPT_DIR" ]; then
            for var_def in "${VARS[@]}"; do
                IFS='|' read -r sub_var sub_default _ <<< "$var_def"
                case "$sub_var" in
                    NGINX_PATH|HAPROXY_PATH|HTML_PATH|ACME_SH_PATH|XRAY_PATH)
                        [ "$(get_final "$sub_var")" = "$sub_default" ] && set_final "$sub_var" "$new_home/${sub_default##*/}" ;;
                esac
            done
        fi
        for var_def in "${VARS[@]}"; do
            IFS='|' read -r var_name default_value _ <<< "$var_def"
            case "$var_name" in
                NGINX_PATH|HAPROXY_PATH|HTML_PATH|ACME_SH_PATH|XRAY_PATH)
                    edit_plain_nonempty "$var_name" "$var_name" ;;
            esac
        done
    fi

    # ---- ACME / 证书 ----
    echo ""
    echo "【ACME / 证书】"
    provider=$(ask_choice "DNS provider" "1) Aliyun  2) Cloudflare  3) 两者都配" "3" "1|2|3")
    local ali_key="" ali_secret="" cf_key=""
    case "$provider" in
        1|3) ali_key=$(ask_secret_fresh "Ali_Key (阿里云 AccessKey)")
             ali_secret=$(ask_secret_fresh "Ali_Secret (阿里云 Secret)") ;;
    esac
    case "$provider" in
        2|3) cf_key=$(ask_secret_fresh "CF_Key (Cloudflare Global API Key)") ;;
    esac
    if [ -z "$ali_key" ] && [ -z "$cf_key" ]; then
        echo "  ⚠️ 未配置任何 DNS provider 凭据，acme.sh 将无法签发证书（可稍后编辑 .env 再部署）"
    fi
    set_final Ali_Key "$ali_key"
    set_final Ali_Secret "$ali_secret"
    set_final CF_Key "$cf_key"
    set_final CF_Email "$(ask "CF_Email（可留空）")"
    set_final ACME_SH_EMAIL "$(ask "ACME_SH_EMAIL（可留空）")"
    ca=$(ask_choice "证书颁发机构" "1) Let's Encrypt  2) ZeroSSL" "1" "1|2")
    set_final CA_LETSENCRYPT "$ca"
    set_final DOMAIN_LIST "$(ask_nonempty "DOMAIN_LIST（必填，逗号分隔，如 *.example.com,example.com）")"

    # ---- Xray UUID ----
    echo ""
    echo "【Xray UUID】"
    main_uuid=$(prompt_uuid "XRAY_UUID（主）" "$DEFAULT_UUID")
    set_final XRAY_UUID "$main_uuid"
    set_final XRAY_UUID_9000 "$(prompt_uuid_port "XRAY_UUID_9000（Vision 入站）" "$main_uuid")"
    set_final XRAY_UUID_9001 "$(prompt_uuid_port "XRAY_UUID_9001（XHTTP 入站）" "$main_uuid")"

    # ---- REALITY ----
    echo ""
    echo "【REALITY】"
    pair=$(prompt_reality_pair) || return 1
    read -r rpriv rpub <<< "$pair"
    set_final REALITY_PRIVATE_KEY "$rpriv"
    set_final REALITY_PUBLIC_KEY "$rpub"
    edit_short_id "REALITY_SHORT_IDS"
    set_final REALITY_DEST "$(ask_nonempty "REALITY_DEST（REALITY 伪装目标）" "www.fifa.com")"

    # ---- NF 后端（仅 HAProxy 模式询问；否则保留默认）----
    if [ "$compose_file" != "${compose_file##*haproxy*}" ]; then
        echo ""
        echo "【HAProxy / NF】"
        set_final NF_XTLS_SERVER "$(ask_nonempty "NF_XTLS_SERVER" "127.0.0.1:18910")"
    fi

    # ---- 摘要 ----
    echo ""
    echo "【配置摘要】"
    case "$compose_file" in
        *haproxy*) echo "  入口模式: HAProxy" ;;
        *)         echo "  入口模式: Nginx（stream）" ;;
    esac
    local ca_name="ZeroSSL"; [ "$(get_final CA_LETSENCRYPT)" = "1" ] && ca_name="Let's Encrypt"
    local providers=""
    [ -n "$(get_final Ali_Key)" ] && providers="Aliyun"
    if [ -n "$(get_final CF_Key)" ]; then
        [ -n "$providers" ] && providers="$providers/"
        providers="${providers}Cloudflare"
    fi
    [ -z "$providers" ] && providers="（未配置）"
    local port_uuid_note="跟随主"
    if [ "$(get_final XRAY_UUID_9000)" != "$(get_final XRAY_UUID)" ] || [ "$(get_final XRAY_UUID_9001)" != "$(get_final XRAY_UUID)" ]; then
        port_uuid_note="独立"
    fi
    echo "  DNS provider: $providers"
    echo "  CA: $ca_name  域名: $(get_final DOMAIN_LIST)"
    echo "  Xray UUID: $(mask_value XRAY_UUID "$(get_final XRAY_UUID)")（9000/9001: $port_uuid_note）"
    echo "  REALITY: PublicKey $(mask_value REALITY_PUBLIC_KEY "$(get_final REALITY_PUBLIC_KEY)")  shortIds $(get_final REALITY_SHORT_IDS)  dest $(get_final REALITY_DEST)"
}

# ========== 模式二：更新向导（-i） ==========

wizard_update() {
    echo ""
    echo "========== laddr-docker .env 更新向导 =========="

    local var_name default_value input main_uuid ca cur

    # 载入现有值（缺失变量用默认值补齐并提示）
    local new_count=0
    for var_def in "${VARS[@]}"; do
        IFS='|' read -r var_name default_value _ <<< "$var_def"
        if var_exists "$var_name"; then
            set_final "$var_name" "$(get_existing_value "$var_name")"
        else
            set_final "$var_name" "$default_value"
            new_count=$((new_count + 1))
        fi
    done
    [ "$new_count" -gt 0 ] && echo "（$new_count 个变量在旧 .env 中缺失，已用默认值补齐）"

    # ---- 入口模式（只读）----
    echo ""
    echo "【入口模式】（只读）"
    case "$(get_final COMPOSE_FILE)" in
        *haproxy*) echo "  当前: HAProxy 入口" ;;
        *)         echo "  当前: Nginx 入口" ;;
    esac
    echo "  切换入口请使用: scripts/ngx_haproxy_switch.sh nginx|haproxy"

    # ---- 环境目录（仅 --advanced 可编辑）----
    echo ""
    echo "【环境目录】"
    if [ "$ADVANCED" = 1 ]; then
        if confirm_block "环境目录"; then
            for var_def in "${VARS[@]}"; do
                IFS='|' read -r var_name default_value _ <<< "$var_def"
                case "$var_name" in
                    DOCKER_BOX_HOME|NGINX_PATH|HAPROXY_PATH|HTML_PATH|ACME_SH_PATH|XRAY_PATH)
                        edit_plain_nonempty "$var_name" "$var_name" ;;
                esac
            done
        fi
    else
        echo "  DOCKER_BOX_HOME=$(get_final DOCKER_BOX_HOME) 等 6 项（编辑请加 --advanced）"
    fi

    # ---- ACME / 证书 ----
    echo ""
    if confirm_block "ACME / 证书"; then
        edit_secret Ali_Key "Ali_Key (阿里云 AccessKey)"
        edit_secret Ali_Secret "Ali_Secret (阿里云 Secret)"
        edit_secret CF_Key "CF_Key (Cloudflare Global API Key)"
        edit_plain CF_Email "CF_Email"
        edit_plain ACME_SH_EMAIL "ACME_SH_EMAIL"
        cur=$(get_final CA_LETSENCRYPT); [ "$cur" = "0" ] && cur="2" || cur="1"
        ca=$(ask_choice "CA_LETSENCRYPT（1=Let's Encrypt 2=ZeroSSL）" "" "$cur" "1|2")
        set_final CA_LETSENCRYPT "$([ "$ca" = 2 ] && echo 0 || echo 1)"
        edit_plain DOMAIN_LIST "DOMAIN_LIST（逗号分隔，如 *.example.com,example.com）"
        if [ -z "$(get_final DOMAIN_LIST)" ]; then
            echo "  ⚠️ DOMAIN_LIST 为空，acme.sh 将无域名可签"
        fi
    fi

    # ---- Xray UUID ----
    echo ""
    if confirm_block "Xray UUID"; then
        edit_uuid XRAY_UUID "XRAY_UUID（主）" 0
        main_uuid=$(get_final XRAY_UUID)
        edit_uuid XRAY_UUID_9000 "XRAY_UUID_9000（Vision 入站）" 1 "$main_uuid"
        edit_uuid XRAY_UUID_9001 "XRAY_UUID_9001（XHTTP 入站）" 1 "$main_uuid"
    fi

    # ---- HAProxy / NF ----
    echo ""
    if confirm_block "HAProxy / NF"; then
        edit_plain_nonempty NF_XTLS_SERVER "NF_XTLS_SERVER"
    fi

    # ---- REALITY ----
    echo ""
    if confirm_block "REALITY"; then
        edit_reality_priv || return 1
        edit_short_id "REALITY_SHORT_IDS"
        edit_plain_nonempty REALITY_DEST "REALITY_DEST（REALITY 伪装目标）"
    fi

    # ---- 变更摘要 ----
    echo ""
    echo "【变更摘要】"
    local changed=0 old new
    for var_def in "${VARS[@]}"; do
        IFS='|' read -r var_name default_value _ <<< "$var_def"
        if var_exists "$var_name"; then old=$(get_existing_value "$var_name"); else old="$default_value"; fi
        new=$(get_final "$var_name")
        if [ "$old" != "$new" ]; then
            echo "  - $var_name: $(mask_value "$var_name" "$old") -> $(mask_value "$var_name" "$new")"
            changed=1
        fi
    done
    [ "$changed" = 0 ] && echo "  （无变更）"

    read -r -p "确认写入 .env？[Y/n] " input
    if [ "$input" = "n" ] || [ "$input" = "N" ]; then
        echo "已取消，未修改 .env"
        return 2
    fi
    return 0
}

# ========== 模式三：静默合并（历史行为；deploy.sh 路径） ==========

silent_merge() {
    NEW_VARS_TEMP=$(mktemp)
    CHANGED_VARS_TEMP=$(mktemp)

    local var_name default_value final_value
    for var_def in "${VARS[@]}"; do
        IFS='|' read -r var_name default_value _ <<< "$var_def"

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

        set_final "$var_name" "$final_value"
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
                echo "  - $var_name=$(mask_value "$var_name" "$default_value")"
            done < "$NEW_VARS_TEMP"
        fi

        if [ -s "$CHANGED_VARS_TEMP" ]; then
            echo ""
            echo "值已变更 ($(wc -l < "$CHANGED_VARS_TEMP" | tr -d ' ')):"
            while IFS='|' read -r var_name default_value final_value; do
                echo "  - $var_name: $(mask_value "$var_name" "$default_value") -> $(mask_value "$var_name" "$final_value")"
            done < "$CHANGED_VARS_TEMP"
        fi

        echo ""
        echo "=========================================="
        echo ""
    fi
}

# 静默模式的 REALITY 修复（deploy 安全）：
#   - 私钥+公钥都在 → 不动（不做匹配校验，避免每次部署白跑 docker；历史版本也不校验）
#   - 有私钥缺公钥  → 由私钥推导公钥（docker x25519 -i）
#   - 缺私钥        → 生成新密钥对并同时覆盖公钥（孤儿公钥无意义，成对优先于"一律保留"）
#   - 公私钥均缺失  → 生成新密钥对
# 返回非 0 表示修复失败（无 docker），调用方应中止。
silent_reality_repair() {
    local priv pub derived blob
    priv=$(get_final REALITY_PRIVATE_KEY)
    pub=$(get_final REALITY_PUBLIC_KEY)

    if [ -n "$priv" ] && [ -n "$pub" ]; then
        return 0
    fi

    if [ -n "$priv" ]; then
        derived=$(derive_reality_pub "$priv")
        if [ -n "$derived" ]; then
            set_final REALITY_PUBLIC_KEY "$derived"
            echo "  - REALITY_PUBLIC_KEY 已由私钥推导补齐（原 .env 缺失）"
            return 0
        fi
    fi

    blob=$(gen_reality_keypair) || return 1
    set_final REALITY_PRIVATE_KEY "$(parse_reality_priv "$blob")"
    set_final REALITY_PUBLIC_KEY "$(parse_reality_pub "$blob")"
    echo "  - REALITY 密钥对已重新生成（原 .env 缺失或不完整）"
    return 0
}

# ========== 输出与副作用（历史行为保留） ==========

write_env() {
    > "$ENV_FILE"

    local CURRENT_BLOCK="" FIRST_VAR=true var_name block_title
    for var_def in "${VARS[@]}"; do
        IFS='|' read -r var_name _ block_title <<< "$var_def"

        # 输出分块之间的空白行
        if [ -n "$block_title" ] && [ "$block_title" != "$CURRENT_BLOCK" ]; then
            if [ "$FIRST_VAR" = false ]; then
                echo "" >> "$ENV_FILE"
            fi
            echo "$block_title" >> "$ENV_FILE"
            CURRENT_BLOCK="$block_title"
            FIRST_VAR=false
        fi

        echo "${var_name}=$(get_final "$var_name")" >> "$ENV_FILE"
    done

    echo "已生成 $ENV_FILE"
}

post_hooks() {
    # 预创建 stream 日志文件（避免 compose 单文件 bind mount 在源缺失时创建目录导致 nginx 无法打开日志）
    # 只创建、不截断；已存在则保持原样
    mkdir -p "$SCRIPT_DIR/log"
    touch "$SCRIPT_DIR/log/nginx_stream.log"

    # 渲染 nginx stream 激活文件（幂等；编辑 .env 后需重新执行 scripts/render_stream.sh）
    if [ -f "$SCRIPT_DIR/scripts/render_stream.sh" ]; then
        if ! sh "$SCRIPT_DIR/scripts/render_stream.sh"; then
            echo ""
            echo "警告: stream 激活文件渲染失败（.env 中 REALITY_DEST / NF_XTLS_SERVER 可能为空）"
            echo "      补齐 .env 后请执行: sh scripts/render_stream.sh"
        fi
    fi
}

# ========== main ==========

main() {
    # 参数解析
    while [ $# -gt 0 ]; do
        case "$1" in
            -i|--interactive) INTERACTIVE=1 ;;
            --advanced)       ADVANCED=1 ;;
            --batch)          BATCH=1 ;;
            -h|--help)        usage; exit 0 ;;
            *) echo "未知参数: $1" >&2; usage; exit 1 ;;
        esac
        shift
    done

    # 初始化目录结构（输出与历史版本一致）
    echo "=========================================="
    echo "初始化目录结构"
    echo "=========================================="
    mkdir -p nginx/conf nginx/www nginx/ssl
    mkdir -p html
    mkdir -p haproxy/maps
    mkdir -p acme/acme.sh
    mkdir -p xray/etc
    mkdir -p log

    echo "目录结构初始化完成"
    echo ""

    load_existing

    # 预计算生成类默认值。
    # 历史版本在 VARS 数组展开时对 reality 密钥对生成做三次独立调用（互不匹配的 bug，
    # 见 README-005 §1.2），且静默+已有 .env 时也会白跑三次 docker x25519。
    # 现仅在需要时生成一次并复用：全新 .env（向导或静默 fresh）或更新向导（默认值兜底）。
    # UUID / shortId 生成不依赖 docker，始终预计算（静默补齐缺失变量时要用）。
    local need_gen=0
    if [ ! -f "$ENV_FILE" ]; then
        need_gen=1
    elif [ -t 0 ] && [ "$INTERACTIVE" = 1 ]; then
        need_gen=1
    fi

    DEFAULT_UUID=$(gen_uuid)
    REALITY_SIDS_DEF="[\"$(gen_reality_short_id)\"]"
    REALITY_PRIV_DEF=""
    REALITY_PUB_DEF=""
    if [ "$need_gen" = 1 ]; then
        local reality_blob
        reality_blob=$(gen_reality_keypair) || exit 1
        REALITY_PRIV_DEF=$(parse_reality_priv "$reality_blob")
        REALITY_PUB_DEF=$(parse_reality_pub "$reality_blob")
        if [ -z "$REALITY_PRIV_DEF" ] || [ -z "$REALITY_PUB_DEF" ]; then
            echo "ERROR: 解析 xray x25519 输出失败（格式异常）" >&2
            exit 1
        fi
    fi

    # UUID_9000/9001 默认跟随主 UUID：优先取旧 .env 的 XRAY_UUID（历史 silent 语义），
    # 否则取本次新生成的 DEFAULT_UUID（历史意图，修复 fresh 为空的 bug，见 README-005 §1.3）
    local existing_main_uuid
    existing_main_uuid=$(get_existing_value XRAY_UUID)
    local uuid_port_default="${existing_main_uuid:-$DEFAULT_UUID}"

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
        "XRAY_UUID|$DEFAULT_UUID|#xray"
        "XRAY_UUID_9000|$uuid_port_default|"
        "XRAY_UUID_9001|$uuid_port_default|"
        "NF_XTLS_SERVER|127.0.0.1:18910|#haproxy"
        "REALITY_PRIVATE_KEY|$REALITY_PRIV_DEF|#reality"
        "REALITY_PUBLIC_KEY|$REALITY_PUB_DEF|"
        "REALITY_SHORT_IDS|$REALITY_SIDS_DEF|"
        "REALITY_DEST|www.fifa.com|"
    )

    init_final
    # FINAL 先按默认值初始化；各模式随后覆盖
    local var_name default_value _block
    for var_def in "${VARS[@]}"; do
        IFS='|' read -r var_name default_value _block <<< "$var_def"
        set_final "$var_name" "$default_value"
    done

    # 模式判定
    local mode_hint=0 rc=0
    if [ -t 0 ] && [ "$BATCH" != 1 ]; then
        if [ -f "$ENV_FILE" ]; then
            if [ "$INTERACTIVE" = 1 ]; then
                wizard_update
                rc=$?
                if [ $rc -eq 2 ]; then
                    exit 0  # 用户取消
                elif [ $rc -ne 0 ]; then
                    exit $rc
                fi
            else
                silent_merge
                silent_reality_repair || exit 1
                mode_hint=1
            fi
        else
            wizard_fresh || exit 1
        fi
    else
        if [ "$INTERACTIVE" = 1 ]; then
            echo "提示: -i 需要交互终端，已按静默模式执行"
        fi
        silent_merge
        silent_reality_repair || exit 1
    fi

    write_env
    post_hooks

    if [ "$mode_hint" = 1 ]; then
        echo ""
        echo "提示: 如需交互式调整，请运行 ./gen_env.sh -i（./gen_env.sh -h 查看帮助）"
    fi
}

main "$@"
