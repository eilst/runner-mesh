#!/bin/bash
# runner-mesh azure node bootstrap — runs once as root via cloud-init.
# Mirrors the engine's node:join plan for plain Linux (no colima steps).
set -euo pipefail
exec > /var/log/runner-mesh-bootstrap.log 2>&1

echo "== runner-mesh bootstrap: ${node_name} =="

# 1) Tailscale client
curl -fsSL https://tailscale.com/install.sh | sh

%{ if k3s_data_dir != "" }
# 1b) k3s state on the local NVMe.
#
#    Azure attaches a physical NVMe to every D*d*/E*d* size and cloud-init
#    mounts it at /mnt. The OS disk is network-attached block storage, so a
#    job that writes tens of thousands of small files (npm ci, a git
#    checkout, a container layer) pays a network round trip per file. Moving
#    k3s's data-dir moves containerd's layers, kubelet, and every emptyDir —
#    which is where runner workspaces live — onto that local disk in one go.
#
#    Ordering matters twice over. This script runs in cloud-final, after the
#    mounts module, so the disk is there now. On LATER boots nothing would
#    order k3s after the mount, and the agent would quietly rebuild its state
#    on the OS disk only for the mount to hide it — hence the drop-in, which
#    is written before the installer so its first start already honours it.
DATA_DIR="${k3s_data_dir}"
echo "== k3s data-dir: $DATA_DIR =="
mkdir -p "$DATA_DIR"

if [ "$(stat -c %d /)" = "$(stat -c %d "$DATA_DIR")" ]; then
  echo "WARNING: $DATA_DIR is on the OS disk, not a separate volume."
  echo "         Is this a VM size with a local disk (the 'd' in D4ads_v5)?"
  lsblk || true
fi

mkdir -p /etc/systemd/system/k3s-agent.service.d
cat > /etc/systemd/system/k3s-agent.service.d/10-data-dir-mount.conf <<EOF
[Unit]
RequiresMountsFor=$DATA_DIR
EOF
%{ endif }

# 2) k3s agent — joins cluster + tailnet in one step. Running as root:
#    env survives (no sudo boundary), and --vpn-auth stays unquoted on
#    purpose (embedded quotes corrupt the systemd unit).
curl -sfL https://get.k3s.io | env \
  INSTALL_K3S_EXEC="agent --node-name ${node_name} --server https://${server_ip}:6443 --token ${cluster_token}%{ if k3s_data_dir != "" } --data-dir ${k3s_data_dir}%{ endif }%{ if size_label != "" } --node-label runner-mesh.dev/size=${size_label}%{ endif } --vpn-auth=name=tailscale,joinKey=${tailscale_authkey}" \
  sh -s -

# 3) Admin access rides the tailnet (subject to the ACL's ssh rules);
#    nothing is reachable from the internet.
tailscale set --ssh || true

systemctl is-active k3s-agent && echo "k3s-agent active — bootstrap done"
