#!/usr/bin/env sh

#Start tailscaled and connect to tailnet
/usr/sbin/tailscaled --state=/var/lib/tailscale/tailscaled.state &> /var/lib/tailscale/tailscaled_initial.log &
/usr/bin/tailscale up --accept-routes=true --accept-dns=true --auth-key $TAILSCALE_AUTH_KEY &> /var/lib/tailscale/tailscale_onboard.log &

# 关键：等待直到 tailscale status 能成功列出节点
echo "Waiting for Tailscale network to be ready..."
for i in $(seq 1 30); do  # 最多尝试30次，每次等待2秒
    if tailscale status 2>&1 | grep -q "100\."; then
        echo "Tailscale network is ready."
        break
    fi
    sleep 2
    echo "Still waiting... ($i/30)"
done

#Start Tailscale derp server
/root/go/bin/derper --hostname=$TAILSCALE_DERP_HOSTNAME --a=$TAILSCALE_DERP_ADDR --stun-port=$TAILSCALE_DERP_STUN_PORT --verify-clients=$TAILSCALE_DERP_VERIFY_CLIENTS
