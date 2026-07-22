#!/bin/bash
echo "Installing cloudflared..."
wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared

echo "Updating Xray config..."
wget -q -O /usr/local/etc/xray/config.json https://raw.githubusercontent.com/nova-sync-5009/xray-fix/master/server-config-tunnel.json
systemctl restart xray

echo "Starting Cloudflare Tunnel..."
nohup cloudflared tunnel --url http://127.0.0.1:8443 > /tmp/tunnel.log 2>&1 &
sleep 5
echo ""
echo "=== Cloudflare Tunnel URL ==="
grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/tunnel.log | head -1
echo "============================"
echo "请复制上面的地址发给Codex"
