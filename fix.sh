#!/bin/bash
# Xray config fix - takes keys as arguments
# Usage: bash fix.sh <UUID> <PRIVATE_KEY> <PUBLIC_KEY>
set -e

info()  { echo -e "\e[32m[+]\e[0m $1"; }
error() { echo -e "\e[31m[-]\e[0m $1"; }

UUID=$1
PK=$2
PBK=$3

if [ -z "$UUID" ] || [ -z "$PK" ] || [ -z "$PBK" ]; then
    echo "Usage: bash fix.sh <UUID> <PRIVATE_KEY> <PUBLIC_KEY>"
    exit 1
fi

info "Stopping xray..."
systemctl stop xray 2>/dev/null || true
killall xray 2>/dev/null || true
sleep 1

info "Writing config..."
mkdir -p /usr/local/etc/xray /var/log/xray

cat > /usr/local/etc/xray/config.json <<'EOF'
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "_UUID_",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "sniffing": {
        "enabled": true,
        "maxPendingConns": 15
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.microsoft.com:443",
          "xver": 0,
          "serverNames": ["www.microsoft.com"],
          "privateKey": "_PK_",
          "shortIds": ["2b26f7b1fdec060e"]
        }
      }
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "blocked"}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {"type": "field", "protocol": ["bittorrent"], "outboundTag": "blocked"}
    ]
  }
}
EOF

# Replace placeholders
sed -i "s/_UUID_/$UUID/" /usr/local/etc/xray/config.json
sed -i "s/_PK_/$PK/" /usr/local/etc/xray/config.json

chmod 644 /usr/local/etc/xray/config.json

info "Testing config..."
xray run -config /usr/local/etc/xray/config.json -test

info "Starting xray..."
systemctl restart xray
sleep 3

if systemctl is-active --quiet xray; then
    info "Xray started successfully!"
else
    error "Xray failed to start!"
    journalctl -u xray -n 20 --no-pager
    exit 1
fi

iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true

echo ""
echo "=== VLESS Link ==="
echo "vless://${UUID}@64.188.6.74:443?type=tcp&security=reality&flow=xtls-rprx-vision&encryption=none&pbk=${PBK}&sid=2b26f7b1fdec060e&fp=chrome&sni=www.microsoft.com#64.188.6.74"
echo ""
info "Done!"
