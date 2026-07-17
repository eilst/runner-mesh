#!/usr/bin/env bash
# node:init / node:join / node:auto — PLAN (don't execute) the commands
# needed to bootstrap actual k3s cluster membership over a Tailscale mesh,
# so a machine can leave your LAN and still be a cluster node. This is a
# different layer than cluster:* (which installs ARC *onto* an existing
# cluster) — these commands are about the cluster's existence itself.
#
# Deliberately print-only for anything privileged: these commands generate
# and print the exact k3s/Tailscale install commands for you to read and
# run yourself, rather than piping installers through sudo autonomously.
# Reasons: auditability of what's about to touch root/systemd, and fitting
# into whatever configuration management you may already use instead of
# fighting it. The one thing that IS executed here is read-only discovery
# (`tailscale status`), never anything that mutates system state.
#
# Contract, per k3s's documented Tailscale integration
# (https://docs.k3s.io/networking/distributed-multicloud): k3s is handed a
# reusable Tailscale auth key via --vpn-auth and manages that node's
# tailnet membership itself; nodes address each other by Tailscale
# hostname/IP instead of LAN IP. k3s only runs on Linux — on macOS, these
# printed commands are meant to run inside a Linux VM or a real Linux box.
#
# Intended to be sourced, not executed.

RM_NODE_HOSTNAME_DEFAULT="runner-mesh-server"
RM_K3S_INSTALL_URL="https://get.k3s.io"
RM_TAILSCALE_INSTALL_URL="https://tailscale.com/install.sh"

rm::node::_is_macos() { [[ "$(uname -s)" == "Darwin" ]]; }

# On macOS, k3s can't run on the host — it runs inside a colima-managed
# Linux VM, and Tailscale must run inside that same VM (not the macOS
# host's Tailscale app) so k3s's --vpn-auth can bind to it. This prelude
# is prepended to the printed plan so a Mac user gets a runnable
# procedure instead of just "k3s is Linux-only".
rm::node::_macos_prelude() {
  # $1: the k3s systemd unit the plan installs (k3s or k3s-agent) — needed
  # by the mount-race drop-in in step 0c.
  local unit="${1:-k3s}"
  cat <<EOF
# ─── macOS host detected ────────────────────────────────────────────────
# k3s only runs on Linux, so on a Mac the cluster node lives inside a
# colima VM, and Tailscale runs INSIDE that VM (not the macOS Tailscale
# app — k3s's --vpn-auth needs the tailscale CLI in the same OS it runs
# in). Steps 1-3 below therefore run inside 'colima ssh'.
#
# 0a) Create/ensure the VM (plain docker runtime — do NOT use colima's
#     --kubernetes flag here; it installs its own k3s without --vpn-auth,
#     which can't join or host a Tailscale-meshed cluster):
#   colima start --cpu 2 --memory 4
#
# 0b) Enter the VM; run everything below inside it:
#   colima ssh
#
# 0c) colima-specific, run AFTER the k3s install step below: make k3s wait
#     for colima's data disk. colima mounts /var/lib/rancher from a
#     separate disk *after* systemd starts ${unit} — without this drop-in,
#     the first VM reboot bootstraps a second cluster CA into the hidden
#     rootfs and the API goes self-inconsistent (x509: unknown authority):
#   sudo mkdir -p /etc/systemd/system/${unit}.service.d
#   printf '[Service]\\nExecStartPre=/bin/sh -c "until findmnt -n /var/lib/rancher >/dev/null; do sleep 1; done"\\nTimeoutStartSec=300\\n' \\
#     | sudo tee /etc/systemd/system/${unit}.service.d/10-wait-datadisk.conf
#   sudo systemctl daemon-reload && sudo systemctl restart ${unit}
#
# 0d) colima-specific: trim the VM's disks daily so freed space returns
#     to the macOS host (colima's disks are sparse files that only grow —
#     dind image churn fills the host disk without this):
#   sudo mkdir -p /etc/systemd/system/fstrim.timer.d
#   printf '[Timer]\\nOnCalendar=\\nOnCalendar=daily\\n' | sudo tee /etc/systemd/system/fstrim.timer.d/daily.conf
#   sudo systemctl daemon-reload && sudo systemctl enable --now fstrim.timer
# ────────────────────────────────────────────────────────────────────────

EOF
}

rm::node::_emit_plan() {
  # Prepends the macOS/colima prelude when relevant, then the plan itself.
  # $2: the k3s systemd unit the plan installs (k3s or k3s-agent).
  local plan="$1" unit="${2:-k3s}"
  if rm::node::_is_macos; then
    printf '%s\n\n%s\n' "$(rm::node::_macos_prelude "${unit}")" "${plan}"
  else
    printf '%s\n' "${plan}"
  fi
}

rm::node::_plan_block() {
  # Prints a labeled command plan to stdout (not stderr) so it's easy to
  # pipe to a file with --write-script or copy straight out of a terminal.
  cat
}

# rm::node::_find_server <hostname> — best-effort, READ-ONLY discovery: is
# a peer with this Tailscale hostname already up and answering on the k3s
# API port? Requires the `tailscale` CLI to already be installed and this
# machine already tailnet-connected; returns non-zero (silently) otherwise
# so callers can fall back to "assume no server yet".
rm::node::_find_server() {
  local hostname="$1" ip
  command -v tailscale >/dev/null 2>&1 || return 1
  ip="$(tailscale status --json 2>/dev/null \
    | jq -r --arg h "${hostname}" '.Peer[]? | select(.HostName == $h) | .TailscaleIPs[0] // empty' \
    | head -1)"
  [[ -n "${ip}" ]] || return 1
  curl -sk --max-time 3 "https://${ip}:6443" >/dev/null 2>&1 || return 1
  printf '%s\n' "${ip}"
}

rm::node::_maybe_write_script() {
  local write_to="$1" content="$2"
  [[ -n "${write_to}" ]] || return 0
  printf '%s\n' "${content}" > "${write_to}"
  chmod +x "${write_to}"
  rm::ok "also saved to ${write_to} (review it, then: bash ${write_to})"
}

rm::node::init() {
  local authkey="" hostname="${RM_NODE_HOSTNAME_DEFAULT}" token="" write_to=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --authkey)      authkey="$2"; shift 2 ;;
      --hostname)     hostname="$2"; shift 2 ;;
      --token)        token="$2"; shift 2 ;;
      --write-script) write_to="$2"; shift 2 ;;
      *) rm::die "unknown flag: $1" ;;
    esac
  done
  authkey="$(rm::net::resolve_authkey "${authkey}")"
  [[ -n "${token}" ]] || token="$(openssl rand -hex 32)"

  local vpn_auth="name=tailscale,joinKey=${authkey}"
  local plan
  plan="$(rm::node::_plan_block <<EOF
# --- runner-mesh: first cluster node (server) ---
# Run these on the Linux host that becomes your cluster's control plane.

# 1) Install the Tailscale client, if not already present:
command -v tailscale >/dev/null 2>&1 || curl -fsSL ${RM_TAILSCALE_INSTALL_URL} | sudo sh

# 2) Install k3s as a server, joined to your tailnet as '${hostname}':
#    NOTE: --vpn-auth stays unquoted on purpose. The value has no spaces,
#    and embedded quotes end up escaped into the systemd unit, which the
#    vpn-auth parser then rejects with an unknown-parameter error.
curl -sfL ${RM_K3S_INSTALL_URL} | \\
  INSTALL_K3S_EXEC="server --node-name ${hostname} --token ${token} --vpn-auth=${vpn_auth} --kubelet-arg=image-gc-high-threshold=80 --kubelet-arg=image-gc-low-threshold=70" \\
  sudo sh -

# 3) Rename this machine on the tailnet to match its node name — k3s
#    registers under the OS hostname, but node discovery (node:auto) and
#    join plans look the node up by '${hostname}':
sudo tailscale set --hostname=${hostname}

# 4) Confirm it's up:
sudo systemctl status k3s --no-pager
sudo cat /etc/rancher/k3s/k3s.yaml   # kubeconfig — merge into ~/.kube/config or use directly

# 5) On every additional machine, run:
runner-mesh node:join --server ${hostname} --token ${token} --authkey ${authkey}
EOF
  )"

  rm::node::_emit_plan "${plan}" k3s
  rm::warn "the token above is a cluster-join secret — treat it like a password, don't commit it"
  rm::node::_maybe_write_script "${write_to}" "${plan}"
}

rm::node::join() {
  local server="" token="" authkey="" hostname="" write_to=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --server)       server="$2"; shift 2 ;;
      --token)        token="$2"; shift 2 ;;
      --authkey)      authkey="$2"; shift 2 ;;
      --hostname)     hostname="$2"; shift 2 ;;
      --write-script) write_to="$2"; shift 2 ;;
      *) rm::die "unknown flag: $1" ;;
    esac
  done
  [[ -n "${server}" && -n "${token}" ]] \
    || rm::die "usage: runner-mesh node:join --server <hostname-or-ip> --token <token> [--authkey KEY] [--hostname NAME] [--write-script PATH]"
  authkey="$(rm::net::resolve_authkey "${authkey}")"
  [[ -n "${hostname}" ]] || hostname="runner-mesh-$(hostname -s 2>/dev/null || echo agent)"

  local vpn_auth="name=tailscale,joinKey=${authkey}"
  local plan
  plan="$(rm::node::_plan_block <<EOF
# --- runner-mesh: join an existing cluster node (agent) ---
# Run these on the Linux host you're adding to the cluster at '${server}'.

# 1) Install the Tailscale client, if not already present:
command -v tailscale >/dev/null 2>&1 || curl -fsSL ${RM_TAILSCALE_INSTALL_URL} | sudo sh

# 2) Install k3s as an agent, joined to your tailnet as '${hostname}':
#    NOTE: --vpn-auth stays unquoted on purpose. The value has no spaces,
#    and embedded quotes end up escaped into the systemd unit, which the
#    vpn-auth parser then rejects with an unknown-parameter error.
curl -sfL ${RM_K3S_INSTALL_URL} | \\
  INSTALL_K3S_EXEC="agent --node-name ${hostname} --server https://${server}:6443 --token ${token} --vpn-auth=${vpn_auth} --kubelet-arg=image-gc-high-threshold=80 --kubelet-arg=image-gc-low-threshold=70" \\
  sudo sh -

# 3) Rename this machine on the tailnet to match its node name:
sudo tailscale set --hostname=${hostname}

# 4) Confirm it's up:
sudo systemctl status k3s-agent --no-pager

# 5) From the server (or a kubeconfig pointed at it), confirm the node joined:
kubectl get nodes

# 6) In the Tailscale admin console (Machines -> this node -> Disable key
#    expiry): cluster nodes are servers, not laptops — expiring keys are
#    the one way a Tailscale control-plane outage can eject a node.
EOF
  )"

  rm::node::_emit_plan "${plan}" k3s-agent
  rm::node::_maybe_write_script "${write_to}" "${plan}"
}

# rm::node::auto — thinnest path: same two secrets (--authkey, --secret)
# on every machine. If Tailscale is already installed and connected here,
# does a READ-ONLY check for an existing server and prints the matching
# join/init plan automatically. If Tailscale isn't installed yet, prints
# the install command and asks you to re-run afterward — it will not
# install anything itself.
rm::node::auto() {
  local authkey="" secret="" hostname="${RM_NODE_HOSTNAME_DEFAULT}" write_to=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --authkey)      authkey="$2"; shift 2 ;;
      --secret)       secret="$2"; shift 2 ;;
      --hostname)     hostname="$2"; shift 2 ;;
      --write-script) write_to="$2"; shift 2 ;;
      *) rm::die "unknown flag: $1" ;;
    esac
  done
  [[ -n "${secret}" ]] \
    || rm::die "usage: runner-mesh node:auto --secret <shared-cluster-secret> [--authkey KEY] [--hostname NAME]"
  authkey="$(rm::net::resolve_authkey "${authkey}")"

  if ! command -v tailscale >/dev/null 2>&1; then
    rm::warn "Tailscale isn't installed on this machine yet, so I can't check whether a \
runner-mesh server already exists on your tailnet. Install it, then re-run 'node:auto':"
    if rm::node::_is_macos; then
      # Host-side Tailscale is only used for the read-only discovery check;
      # the cluster node's own Tailscale runs inside the colima VM (see the
      # plan node:init/node:join prints).
      printf '\nbrew install tailscale && sudo tailscale up --authkey=%s --hostname=%s\n\n' \
        "${authkey}" "$(hostname -s 2>/dev/null || echo runner-mesh-node)"
    else
      printf '\ncommand -v tailscale >/dev/null 2>&1 || curl -fsSL %s | sudo sh\nsudo tailscale up --authkey=%s --hostname=%s\n\n' \
        "${RM_TAILSCALE_INSTALL_URL}" "${authkey}" "$(hostname -s 2>/dev/null || echo runner-mesh-node)"
    fi
    return 0
  fi

  rm::log "Checking (read-only) for an existing runner-mesh server ('${hostname}') on the tailnet..."
  local server_ip
  if server_ip="$(rm::node::_find_server "${hostname}")"; then
    rm::ok "found a server at ${server_ip} — here's the join plan:"
    rm::node::join --server "${server_ip}" --token "${secret}" --authkey "${authkey}" --write-script "${write_to}"
  else
    rm::log "no existing server found — here's the plan to make this machine the server:"
    rm::node::init --authkey "${authkey}" --hostname "${hostname}" --token "${secret}" --write-script "${write_to}"
  fi
}
