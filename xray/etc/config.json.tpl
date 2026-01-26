{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "dnsLog": false
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 9000,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${XRAY_UUID_9000}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tcpSettings": {
          "acceptProxyProtocol": true
        },
        "tlsSettings": {
          "rejectUnknownSni": true,
          "minVersion": "1.2",
          "certificates": [
            {
              "ocspStapling": 3600,
              "certificateFile": "/etc/xray/cert/default_cert.pem",
              "keyFile": "/etc/xray/cert/default_key.pem"
            }
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {}
    },
    {
      "tag": "blocked",
      "protocol": "blackhole",
      "settings": {}
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "domain": [
          "geosite:google"
        ],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "ip": [
          "geoip:cn",
          "geoip:private"
        ],
        "outboundTag": "blocked"
      }
    ]
  }
}