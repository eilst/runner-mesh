#!/bin/bash
# runner-mesh azure node bootstrap — runs once as root via cloud-init.
# Mirrors the engine's node:join plan for plain Linux (no colima steps).
set -euo pipefail
exec > /var/log/runner-mesh-bootstrap.log 2>&1

echo "== runner-mesh bootstrap: ${node_name} =="

# 1) Tailscale client
curl -fsSL https://tailscale.com/install.sh | sh

# 2) k3s agent — joins cluster + tailnet in one step. Running as root:
#    env survives (no sudo boundary), and --vpn-auth stays unquoted on
#    purpose (embedded quotes corrupt the systemd unit).
curl -sfL https://get.k3s.io | env \
  INSTALL_K3S_EXEC="agent --node-name ${node_name} --server https://${server_ip}:6443 --token ${cluster_token}%{ if size_label != "" } --node-label runner-mesh.dev/size=${size_label}%{ endif } --vpn-auth=name=tailscale,joinKey=${tailscale_authkey}" \
  sh -s -

# 3) Admin access rides the tailnet (subject to the ACL's ssh rules);
#    nothing is reachable from the internet.
tailscale set --ssh || true

systemctl is-active k3s-agent && echo "k3s-agent active — bootstrap done"
