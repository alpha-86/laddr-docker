# SNI-based routing map for HAProxy / HAProxy SNI 路由映射表
# Format: <regex_pattern> <backend_name> / 格式: <正则模式> <后端名称>

# Xray backends: x|xyz|api|dt|ai prefixes (4th level subdomain) / Xray 后端：匹配第四级域名为 x|xyz|api|dt|ai
^(x|xyz|api|dt|ai)\.[^.]+\.[^.]+\.[^.]+$ xray_backend

# Xray XHTTP+REALITY backend: REALITY_DEST (external website for REALITY) / Xray XHTTP+REALITY 后端：REALITY_DEST（REALITY伪装目标网站）
^${REALITY_DEST}$ xhttp_backend

# Xray XHTTP backends: web|app|cdn prefixes (4th level subdomain) / Xray XHTTP 后端：匹配第四级域名为 web|app|cdn
^(web|app|cdn)\.[^.]+\.[^.]+\.[^.]+$ xhttp_backend

# Netflix Xray backends: nf|netflix|nfx|nfv prefixes (4th level subdomain) / Netflix Xray 后端：匹配第四级域名为 nf|netflix|nfx|nfv
^(nf|netflix|nfx|nfv)\.[^.]+\.[^.]+\.[^.]+$ nf_xtls_backend

# Default fallback (if no pattern matches, use nginx backend) / 默认回退（如果没有匹配，使用 nginx 后端，由 frontend 的 default_backend 指定）
# This line is not needed as we'll use default_backend directive in frontend / 此行不需要，因为 frontend 使用了 default_backend 指令