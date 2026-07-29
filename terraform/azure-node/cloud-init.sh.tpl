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

# --data-dir only moves what k3s itself owns — containerd's image layers and
# rootfs. kubelet's root is hardcoded to /var/lib/kubelet, and emptyDir volumes
# live under it, which is precisely where a runner's workspace goes. So bind
# /var/lib/kubelet onto the local disk too. A bind rather than
# --kubelet-arg=root-dir keeps kubelet oblivious: nothing downstream has to know
# the path moved.
mkdir -p "$DATA_DIR/kubelet" /var/lib/kubelet
cat > /etc/systemd/system/var-lib-kubelet.mount <<EOF
[Unit]
Description=kubelet state on the node's local disk
RequiresMountsFor=$DATA_DIR
Before=k3s-agent.service

[Mount]
What=$DATA_DIR/kubelet
Where=/var/lib/kubelet
Type=none
Options=bind

[Install]
WantedBy=local-fs.target
EOF

mkdir -p /etc/systemd/system/k3s-agent.service.d
cat > /etc/systemd/system/k3s-agent.service.d/10-data-dir-mount.conf <<EOF
[Unit]
RequiresMountsFor=$DATA_DIR /var/lib/kubelet
EOF

systemctl daemon-reload
systemctl enable --now var-lib-kubelet.mount
%{ endif }

# 1c) Node hardening, applied before k3s so its first start already has it.
#
#    These are kubelet flags and an iptables rule, not Kubernetes objects, so
#    no GitOps controller can reconcile them — if they are not written here they
#    are written by hand, and the node that misses them is always the new one.
%{ if length(kubelet_args) > 0 }
mkdir -p /etc/rancher/k3s
{
  echo "kubelet-arg:"
%{ for arg in kubelet_args ~}
  echo "  - ${arg}"
%{ endfor ~}
} > /etc/rancher/k3s/config.yaml
%{ endif }

#    Clamp TCP MSS to the path MTU. Every node here joins over Tailscale, which
#    caps at 1280, and docker-in-docker happily emits 1500-byte packets at it —
#    they are silently black-holed, which reads as "TLS handshake timeout"
#    pulling a base image rather than as a network fault. ExecStartPost so it
#    survives reboots; the -C test keeps it idempotent.
mkdir -p /etc/systemd/system/k3s-agent.service.d
cat > /etc/systemd/system/k3s-agent.service.d/20-mss-clamp.conf <<'EOF'
[Service]
ExecStartPost=/bin/sh -c "iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
EOF

# 2) k3s agent — joins cluster + tailnet in one step. Running as root:
#    env survives (no sudo boundary), and --vpn-auth stays unquoted on
#    purpose (embedded quotes corrupt the systemd unit).
curl -sfL https://get.k3s.io | env \
  INSTALL_K3S_EXEC="agent --node-name ${node_name} --server https://${server_ip}:6443 --token ${cluster_token}%{ if node_taint != "" } --node-taint ${node_taint}%{ endif }%{ if k3s_data_dir != "" } --data-dir ${k3s_data_dir}%{ endif }%{ if size_label != "" } --node-label runner-mesh.dev/size=${size_label}%{ endif } --vpn-auth=name=tailscale,joinKey=${tailscale_authkey}" \
  sh -s -

# 3) Admin access rides the tailnet (subject to the ACL's ssh rules);
#    nothing is reachable from the internet.
tailscale set --ssh || true

systemctl is-active k3s-agent && echo "k3s-agent active — bootstrap done"
