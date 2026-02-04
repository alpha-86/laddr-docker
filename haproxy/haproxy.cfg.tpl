global
    maxconn 4096
    log 127.0.0.1:514 local0

defaults
    mode tcp
    timeout connect 5s
    timeout client 50s
    timeout server 50s
    log global
    option tcplog

# Statistics page
listen stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 30s
    stats hide-version

# Main HTTPS proxy (port 443)
frontend https_frontend
    bind *:443
    # Enable SNI detection
    tcp-request inspect-delay 5s
    # Capture SNI BEFORE accept (critical: capture must come before accept)
    tcp-request content capture req.ssl_sni len 100
    tcp-request content accept if { req_ssl_hello_type 1 }
    # SNI-based routing using map file (with regex matching)
    use_backend %[req_ssl_sni,lower,map_reg(/usr/local/etc/haproxy/maps/sni_routing.map)]
    # Default to nginx backend if no map match
    default_backend ngx_backend
    # Custom log format with captured SNI (slot 0)
    log-format "%ci:%cp [%tr] %ft %b/%s %Tw/%Tc/%Tt %B %ts sni:%[capture.req.hdr(0)]"

# Backend definitions
backend xray_backend
    # Send proxy protocol v2 to preserve client IP
    server xray 127.0.0.1:18910 send-proxy-v2

backend xhttp_backend
    # XHTTP+REALITY doesn't support proxy protocol, direct TCP passthrough
    server xray-xhttp 127.0.0.1:18911

backend ngx_backend
    # Send proxy protocol v2 to preserve client IP
    server ngx 127.0.0.1:8443 send-proxy-v2

backend nf_xtls_backend
    # Send proxy protocol v2 to preserve client IP
    server nf_xtls ${NF_XTLS_SERVER} send-proxy-v2
