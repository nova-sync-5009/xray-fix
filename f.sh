#!/bin/bash
set -e
UUID=$1
PK=$2
PBK=$3
if [ -z "$UUID" ] || [ -z "$PK" ] || [ -z "$PBK" ]; then
    echo "Usage: bash f.sh UUID PK PBK"
    exit 1
fi
systemctl stop xray 2>/dev/null || true
killall xray 2>/dev/null || true
sleep 1
mkdir -p /usr/local/etc/xray /var/log/xray
cat > /usr/local/etc/xray/config.json <<X
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision" }],
        "decryption": "none"
      },
      "sniffing": { "enabled": true },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.microsoft.com:443",
          "xver": 0,
          "serverNames": ["www.microsoft.com"],
          "privateKey": "$PK",
          "shortIds": ["2b26f7b1fdec060e"]
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "blocked" }
  ]
}
X
chmod 644 /usr/local/etc/xray/config.json
xray run -config /usr/local/etc/xray/config.json -test
systemctl restart xray
sleep 3
systemctl status xray
iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
echo ""
echo "vless://$UUID@64.188.6.74:443?type=tcp&security=reality&flow=xtls-rprx-vision&encryption=none&pbk=$PBK&sid=2b26f7b1fdec060e&fp=chrome&sni=www.microsoft.com#64.188.6.74"
