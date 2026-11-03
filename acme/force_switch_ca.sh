#!/bin/sh
# force_switch_ca.sh — 强制将存量证书切换到指定 CA（一次性迁移工具）
#
# 背景：acme.sh 给每张证书记录签发时的 CA（Le_API），到期续期仍走旧 CA；
# 改默认 CA 不会迁移存量证书，必须逐张 --force 重签。本脚本按 ssl.sh 的
# 域名展开逻辑解析 DOMAIN_LIST，取证书主域名强制重签并指定 --server <CA>，
# 随后经 docker deploy-hook 把新证书部署到 nginx 容器（reload.sh 会同时
# 重启 xray 使其加载新证书），最后把默认 CA 也设为 <CA>。
#
# 用法（容器内环境变量已有 DOMAIN_LIST 与 deploy-hook 配置，由 compose 注入）：
#   docker exec acme sh /force_switch_ca.sh <ca>
#
# <ca> 取值（acme.sh --server 支持的名称或 ACME directory URL）：
#   letsencrypt   Let's Encrypt（推荐）
#   zerossl       ZeroSSL（需在容器环境提供 ZEROSSL_EAB_KID /
#                 ZEROSSL_EAB_HMAC_KEY，否则账号注册失败）
#   buypass | sslcom | google | <ACME directory URL>
#
# 注意：--force 重签会计入 CA 的重复证书配额（LE：同名同 SAN 每周 5 张），
# 日常续期请勿使用本脚本；ssl.sh 的初始化逻辑不受影响（尊重环境历史）。

CA="$1"
if [ -z "$CA" ]; then
    echo "用法: docker exec acme sh /force_switch_ca.sh <ca>" >&2
    echo "  ca: letsencrypt | zerossl | buypass | sslcom | google | <ACME URL>" >&2
    exit 1
fi

if [ -z "$DOMAIN_LIST" ]; then
    echo "错误：DOMAIN_LIST 环境变量为空！" >&2
    exit 1
fi

# 以下域名展开函数与 ssl.sh 中的逻辑保持一致
process_domain_with_wildcard() {
    local domain_str="$1"
    if [ -z "$domain_str" ]; then
        echo "错误：入参不能为空！" >&2
        return 1
    fi

    # 步骤1：拆分原始域名（去重）
    local raw_domains=""
    for d in $(echo "$domain_str" | tr ';' ' '); do
        [ -z "$d" ] && continue
        if ! echo " $raw_domains " | grep -Fw " $d "; then
            raw_domains="$raw_domains $d"
        fi
    done
    raw_domains=$(echo "$raw_domains" | sed -e 's/^ *//' -e 's/ *$//')

    # 步骤2：生成所有泛域名（去重）
    local all_wildcards=""
    for d in $raw_domains; do
        local wc="*.${d}"
        if ! echo " $all_wildcards " | grep -Fw " $wc "; then
            all_wildcards="$all_wildcards $wc"
        fi
    done
    all_wildcards=$(echo "$all_wildcards" | sed -e 's/^ *//' -e 's/ *$//')

    # 步骤3：筛选保留的原始域名（被其他泛域名覆盖的剔除）
    local kept_originals=""
    for original in $raw_domains; do
        local is_covered=0
        local self_wc="*.${original}"

        for wc in $all_wildcards; do
            [ "$wc" = "$self_wc" ] && continue  # 跳过自身泛域名

            local suffix=$(echo "$wc" | sed 's/^\*\.*//' | sed 's/\./\\./g')
            if [ "$original" = "$(echo "$wc" | sed 's/^\*\.*//')" ] ||
               echo "$original" | grep -E "^.*\\.${suffix}$" >/dev/null; then
                is_covered=1
                break
            fi
        done

        if [ "$is_covered" -eq 0 ]; then
            kept_originals="$kept_originals $original"
        fi
    done
    kept_originals=$(echo "$kept_originals" | sed -e 's/^ *//' -e 's/ *$//')

    # 步骤4：合并结果并输出
    local final_result="$kept_originals $all_wildcards"
    final_result=$(echo "$final_result" | sed -e 's/^ *//' -e 's/ *$//' -e 's/  */ /g')

    for item in $final_result; do
        echo "$item"
    done
    return 0
}

# 解析 DOMAIN_LIST（格式："dns提供商:域名1;域名2 dns提供商:域名1;域名2"），
# 展开为完整域名列表（ssl.sh 用一条 issue 命令申请，所有域名同属一张证书，
# 主域名为展开后的第一个域名）
all_domains=""
for dns_group in $DOMAIN_LIST; do
    domains="${dns_group#*:}"
    expanded=$(process_domain_with_wildcard "$domains") || exit 1
    all_domains="$all_domains $expanded"
done

main_domain=$(echo $all_domains | awk '{print $1}')
if [ -z "$main_domain" ]; then
    echo "错误：未能从 DOMAIN_LIST 解析出主域名！" >&2
    exit 1
fi

echo "目标 CA: $CA"
echo "证书主域名: $main_domain"
echo "包含域名: $all_domains"
echo "强制按 $CA 重签存量证书..."
acme.sh --renew -d "$main_domain" --force --server "$CA" || exit 1

echo "部署新证书到 nginx 容器（deploy-hook 会 reload nginx 并重启 xray）..."
domain_args=""
for d in $all_domains; do
    domain_args="$domain_args -d $d"
done
acme_deploy_cmd="acme.sh --deploy${domain_args} --deploy-hook docker"
echo "acme.sh deploy command: $acme_deploy_cmd"
$acme_deploy_cmd || exit 1

echo "将默认 CA 设为 $CA（之后新签证书默认走该 CA）..."
acme.sh --set-default-ca --server "$CA" || exit 1

echo "完成，当前证书列表："
acme.sh --list
