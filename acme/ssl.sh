#!/bin/sh

# https://hub.docker.com/r/neilpang/acme.sh/dockerfile

# 定义域名处理函数：
# 核心规则：
# 1. 候选列表 = 原始域名本身 + 每个原始域名的泛域名（*.域名），去重；
# 2. 泛域名：全部保留（互不覆盖）；
# 3. 域名本身：仅当被列表中其他泛域名覆盖时剔除，否则保留；
# 参数：分号分隔的域名字符串
# 返回：echo输出空格分隔的最终列表（开头无空格），退出码0=成功，1=失败
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

    # 步骤3：筛选保留的原始域名（核心修复：精准匹配覆盖）
    local kept_originals=""
    for original in $raw_domains; do
        local is_covered=0
        local self_wc="*.${original}"
        
        for wc in $all_wildcards; do
            [ "$wc" = "$self_wc" ] && continue  # 跳过自身泛域名
            
            # 提取泛域名后缀（*.bac.com → bac.com，修复点号转义）
            local suffix=$(echo "$wc" | sed 's/^\*\.*//' | sed 's/\./\\./g')
            # 精准匹配：要么完全相等，要么以 .suffix 结尾（转义点号）
            if [ "$original" = "$(echo "$wc" | sed 's/^\*\.*//')" ] || 
               echo "$original" | grep -E "^.*\\.${suffix}$" >/dev/null; then
                is_covered=1
                break
            fi
        done

        # 未被覆盖则保留
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



# 解析 DNS 提供商和域名列表，生成包含 DNS 提供商的完整参数列表
# 
# 参数格式：
#   "dns提供商:域名1;域名2 dns提供商:域名1;域名2"
#   例如："dns_ali:abcc.ltd;abcc.com dns_cf:aa2.ltd;abcc2.com"
#
# 返回值格式：
#   "--dns dns提供商 -d 域名1 --dns dns提供商 -d *.域名1 --dns dns提供商 -d 域名2 --dns dns提供商 -d *.域名2 ..."
#   例如："--dns dns_ali -d abcc.ltd --dns dns_ali -d *.abcc.ltd --dns dns_ali -d abcc.com --dns dns_ali -d *.abcc.com 
#         --dns dns_cf -d aa2.ltd --dns dns_cf -d *.aa2.ltd --dns dns_cf -d abcc2.com --dns dns_cf -d *.abcc2.com"
#
# 使用示例：
#   result=$(parse_dns_and_domain "dns_ali:abcc.ltd;abcc.com dns_cf:aa2.ltd;abcc2.com")
#   echo "$result"
parse_dns_and_domain() {
    input="$1"
    result=""
    
    # 使用空格分割输入字符串
    for dns_group in $input; do
        # 分离 DNS 提供商和域名列表
        dns_provider="${dns_group%%:*}"
        domains="${dns_group#*:}"
        domains=$(process_domain_with_wildcard "$domains") 
        # 使用分号分割域名
        for domain in $domains; do
            # 跳过空域名
            [ -z "$domain" ] && continue
            # 为每个域名添加普通域名和通配符域名
            result="$result --dns $dns_provider -d $domain"
        done
    done
    
    # 移除开头的空格并输出结果
    echo "${result# }"
}

# 解析域名列表，生成不包含 DNS 提供商的参数列表
# 
# 参数格式：
#   "dns提供商:域名1;域名2 dns提供商:域名1;域名2"
#   例如："dns_ali:abcc.ltd;abcc.com dns_cf:aa2.ltd;abcc2.com"
#
# 返回值格式：
#   "-d 域名1 -d *.域名1 -d 域名2 -d *.域名2 ..."
#   例如："-d abcc.ltd -d *.abcc.ltd -d abcc.com -d *.abcc.com
#         -d aa2.ltd -d *.aa2.ltd -d abcc2.com -d *.abcc2.com"
#
# 使用示例：
#   result=$(parse_domain_only "dns_ali:abcc.ltd;abcc.com dns_cf:aa2.ltd;abcc2.com")
#   echo "$result"
parse_domain_only() {
    input="$1"
    result=""
    
    # 使用空格分割输入字符串
    for dns_group in $input; do
        # 获取域名列表（忽略 DNS 提供商）
        domains="${dns_group#*:}"
        
        domains=$(process_domain_with_wildcard "$domains") 
        # 使用分号分割域名
        for domain in $domains; do
            # 跳过空域名
            [ -z "$domain" ] && continue
            # 只添加域名部分，不包含 DNS 提供商
            result="$result -d $domain"
        done
    done
    
    # 移除开头的空格并输出结果
    echo "${result# }"
}

if [ ! -f /acme.sh/account.conf ]; then
    echo 'First startup'
    #acme.sh --update-account --accountemail ${ACME_SH_EMAIL}
    if [ -n "$CA_LETSENCRYPT" ] && [ "$CA_LETSENCRYPT" != "0" ]; then
        acme.sh --set-default-ca  --server  letsencrypt
    fi
    acme.sh --register-account -m ${ACME_SH_EMAIL}
fi

dns_and_domain=$(parse_dns_and_domain "$DOMAIN_LIST")
domain_only=$(parse_domain_only "$DOMAIN_LIST")

echo 'Asking for certificates'
acme_issue_cmd="acme.sh --issue ${dns_and_domain}"
echo "acme.sh issue command:"$acme_issue_cmd
$acme_issue_cmd

acme_deploy_cmd="acme.sh --deploy ${domain_only} --deploy-hook docker"
echo "acme.sh deploy command:"$acme_deploy_cmd
$acme_deploy_cmd

echo 'Listing certs'
acme.sh --list
# Make the container keep running
/entry.sh daemon

