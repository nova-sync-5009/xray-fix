#!/bin/bash
# Xray VLESS + Reality one-click install/fix
# Pure ASCII - safe for VNC paste
# Generates fresh keys on the server
set -e

# ===== CONFIG =====
SERVER_IP="64.188.6.74"
PORT=443
DEST="www.microsoft.com:443"
SERVER_NAMES="www.microsoft.com"
XRAY_VERSION="v25.7.18"
SHORT_ID="2b26f7b1fdec060e"

# ===== LOG =====
info()  { echo -e "\e[32m[+]\e[0m $1"; }
warn()  { echo -e "\e[33m[*]\e[0m $1"; }
error() { echo -e "\e[31m[-]\e[0m $1"; }

# ===== PRECHECK =====
if [ "$(id -u)" != "0" ]; then
    error "Must run as root"
    exit 1
fi

info "=== Xray VLESS Reality Fix Script ==="
info "Server IP: $SERVER_IP"
info "Port: $PORT"
info ""

# ===== STOP EXISTING XRAY =====
info "Stopping existing xray..."
systemctl stop xray 2>/dev/null || true
killall xray 2>/dev/null || true
sleep 1

# ===== INSTALL XRAY =====
install_xray() {
    if [ -f /usr/local/bin/xray ]; then
        ver=$(/usr/local/bin/xray version 2>/dev/null | head -1 || echo "unknown")
        info "Xray already installed: $ver"
        return
    fi

    info "Downloading Xray-core ${XRAY_VERSION}..."
    ARCHIVE="Xray-linux-64.zip"
    URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${ARCHIVE}"
    TMPDIR=$(mktemp -d)
    cd "$TMPDIR"

    if ! wget -q --timeout=60 "$URL"; then
        error "Failed to download Xray"
        error "URL: $URL"
        cd /
        rm -rf "$TMPDIR"
        exit 1
    fi

    apt-get update -qq 2>/dev/null || true
    apt-get install -y -qq unzip 2>/dev/null || true

    unzip -qo "$ARCHIVE"
    cp xray /usr/local/bin/xray
    chmod +x /usr/local/bin/xray
    mkdir -p /usr/local/etc/xray

    cd /
    rm -rf "$TMPDIR"
    info "Xray installed: $XRAY_VERSION"
}

install_xray

# ===== GENERATE FRESH KEYS =====
info "Generating fresh X25519 key pair..."
KEY_OUTPUT=$(/usr/local/bin/xray x25519)
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep "Private" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep "Public" | awk '{print $3}')

info "Generating fresh UUID..."
UUID=$(/usr/local/bin/xray uuid)

info "Private Key: $PRIVATE_KEY"
info "Public Key:  $PUBLIC_KEY"
info "UUID:        $UUID"
info "Short ID:    $SHORT_ID"

# ===== ENABLE BBR =====
enable_bbr() {
    if grep -q 'net.core.default_qdisc=fq' /etc/sysctl.conf 2>/dev/null; then
        info "BBR already enabled"
        return
    fi
    info "Enabling BBR..."
    cat >> /etc/sysctl.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl -p > /dev/null 2>&1 || true
    info "BBR enabled"
}

enable_bbr

# ===== WRITE XRAY CONFIG =====
info "Writing Xray config..."
mkdir -p /usr/local/etc/xray
mkdir -p /var/log/xray

# Tune kernel params
sysctl -w net.ipv4.tcp_rmem='8192 262144 67108864' > /dev/null 2>&1 || true
sysctl -w net.ipv4.tcp_wmem='8192 262144 67108864' > /dev/null 2>&1 || true
sysctl -w net.core.rmem_max=67108864 > /dev/null 2>&1 || true
sysctl -w net.core.wmem_max=67108864 > /dev/null 2>&1 || true

cat > /usr/local/etc/xray/config.json <<XRAY_CONF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
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
          "dest": "${DEST}",
          "xver": 0,
          "serverNames": ["${SERVER_NAMES}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "blocked"
      }
    ]
  }
}
XRAY_CONF

chmod 644 /usr/local/etc/xray/config.json
info "Config written"

# ===== SYSTEMD SERVICE =====
info "Setting up systemd service..."

cat > /etc/systemd/system/xray.service <<'UNIT_EOF'
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT_EOF

systemctl daemon-reload
systemctl enable xray > /dev/null 2>&1
systemctl restart xray
sleep 3

if systemctl is-active --quiet xray; then
    info "Xray service started successfully!"
else
    error "Xray failed to start!"
    error "Logs:"
    journalctl -u xray -n 20 --no-pager
    exit 1
fi

# ===== FIREWALL =====
info "Configuring firewall..."
iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
info "Firewall configured"

# ===== VERIFY =====
info "Verifying service..."
sleep 2
if curl -s --connect-timeout 5 -o /dev/null -w "%{http_code}" "https://www.microsoft.com" 2>/dev/null | grep -q "200\|301\|302"; then
    info "Network connectivity OK"
else
    warn "Network test inconclusive (may still work)"
fi

# ===== GENERATE CLIENT CONFIG =====
CLIENT_CONFIG=$(cat <<CLIENT_EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "socks",
      "port": 10808,
      "listen": "127.0.0.1",
      "protocol": "socks",
      "sniffing": {
        "enabled": true,
        "udp": true
      },
      "settings": {
        "auth": "noauth",
        "udp": true
      }
    },
    {
      "tag": "http",
      "port": 10809,
      "listen": "127.0.0.1",
      "protocol": "http",
      "sniffing": {
        "enabled": true
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${SERVER_IP}",
            "port": ${PORT},
            "users": [
              {
                "id": "${UUID}",
                "flow": "xtls-rprx-vision",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "${SERVER_NAMES}",
          "publicKey": "${PUBLIC_KEY}",
          "shortId": "${SHORT_ID}",
          "fingerprint": "chrome"
        }
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "blocked",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "IpIfNonMatch",
    "rules": [
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "ip": ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.1/8"],
        "outboundTag": "direct"
      }
    ]
  }
}
CLIENT_EOF
)

# Save client config to file on server
echo "$CLIENT_CONFIG" > /root/client-windows.json

# ===== VLESS LINK =====
VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?type=tcp&security=reality&flow=xtls-rprx-vision&encryption=none&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&fp=chrome&sni=${SERVER_NAMES}#${SERVER_IP}-Reality"

# ===== OUTPUT =====
echo ""
echo "============================================"
info "INSTALLATION COMPLETE!"
echo ""
echo "============================================"
echo ""
echo "  Server IP:    $SERVER_IP"
echo "  Port:         $PORT"
echo "  Protocol:     VLESS + XTLS-Reality (Vision)"
echo "  UUID:         $UUID"
echo "  Short ID:     $SHORT_ID"
echo "  Public Key:   $PUBLIC_KEY"
echo "  Private Key:  $PRIVATE_KEY"
echo ""
echo "============================================"
echo ""
echo "  [VLESS Link - copy to v2rayN/Nekobox/Clash Meta]"
echo ""
echo "$VLESS_LINK"
echo ""
echo "============================================"
echo ""
echo "  [Client config saved to /root/client-windows.json]"
echo "  [Run 'cat /root/client-windows.json' to view]"
echo ""
echo "============================================"
echo ""
info "Done! Test with a client using the VLESS link above."
echo ""
