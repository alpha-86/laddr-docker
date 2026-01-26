global
    daemon
    maxconn 4096
    log stdout local0

    # SSL/TLS configuration
    ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384
    ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets

defaults
    mode tcp
    timeout connect 5000ms
    timeout client 50000ms
    timeout server 50000ms
    option tcplog
    log global

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
    mode tcp
    option tcplog

    # Enable SNI detection
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }

    # SNI-based routing using map file
    # Use map file to determine backend based on SNI
    use_backend %[req_ssl_sni,lower,map(/usr/local/etc/haproxy/maps/sni_routing.map)]

    # Default to nginx backend if no map match
    default_backend ngx_backend

# Backend definitions
backend xray_backend
    mode tcp
    option tcplog
    # Send proxy protocol v2 to preserve client IP
    server xray 127.0.0.1:18910 send-proxy-v2

backend ngx_backend
    mode tcp
    option tcplog
    # Send proxy protocol v2 to preserve client IP
    server ngx 127.0.0.1:8443 send-proxy-v2

backend nf_xtls_backend
    mode tcp
    option tcplog
    # Send proxy protocol v2 to preserve client IP
    server nf_xtls ${NF_XTLS_SERVER} send-proxy-v2
