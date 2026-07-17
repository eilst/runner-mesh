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
  # Control-plane snapshots (see rm::node::promote for the recovery side).
  # Defaults: embedded etcd + local snapshots every 6h, keep 20. Off-node
  # S3/blob is opt-in — a snapshot that dies with the host protects nothing.
  local snapshots="true" snap_cron="0 */6 * * *" snap_retention="20"
  local s3_endpoint="" s3_bucket="" s3_folder="runner-mesh" s3_access="" s3_secret="" s3_region=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --authkey)            authkey="$2"; shift 2 ;;
      --hostname)           hostname="$2"; shift 2 ;;
      --token)              token="$2"; shift 2 ;;
      --write-script)       write_to="$2"; shift 2 ;;
      --no-snapshots)       snapshots="false"; shift ;;
      --snapshot-cron)      snap_cron="$2"; shift 2 ;;
      --snapshot-retention) snap_retention="$2"; shift 2 ;;
      --snapshot-s3-endpoint)   s3_endpoint="$2"; shift 2 ;;
      --snapshot-s3-bucket)     s3_bucket="$2"; shift 2 ;;
      --snapshot-s3-folder)     s3_folder="$2"; shift 2 ;;
      --snapshot-s3-region)     s3_region="$2"; shift 2 ;;
      --snapshot-s3-access-key) s3_access="$2"; shift 2 ;;
      --snapshot-s3-secret-key) s3_secret="$2"; shift 2 ;;
      *) rm::die "unknown flag: $1" ;;
    esac
  done
  authkey="$(rm::net::resolve_authkey "${authkey}")"
  [[ -n "${token}" ]] || token="$(openssl rand -hex 32)"

  # --cluster-init switches the datastore from the default sqlite to
  # embedded etcd — required for scheduled/off-node snapshots AND the
  # prerequisite for ever adding HA servers later. Harmless on a single
  # node; slightly more RAM/disk I/O than sqlite, worth it for a control
  # plane you want to be able to recover.
  local cluster_init="" snapshot_step=""
  if [[ "${snapshots}" == "true" ]]; then
    cluster_init=" --cluster-init"
    local s3_lines=""
    if [[ -n "${s3_bucket}" ]]; then
      s3_lines="$(printf 'etcd-s3: true\netcd-s3-endpoint: "%s"\netcd-s3-bucket: "%s"\netcd-s3-folder: "%s"\netcd-s3-region: "%s"\netcd-s3-access-key: "%s"\netcd-s3-secret-key: "%s"\n' \
        "${s3_endpoint}" "${s3_bucket}" "${s3_folder}" "${s3_region}" "${s3_access}" "${s3_secret}")"
    fi
    snapshot_step="$(cat <<SNAP
# 1b) Control-plane snapshots. Writes k3s config so etcd snapshots run on a
#     schedule; ${s3_bucket:+off-node to S3 — the only kind that survives this host dying}${s3_bucket:-LOCAL ONLY — add --snapshot-s3-* so snapshots survive the host}.
#     'runner-mesh node:promote' restores from these.
sudo mkdir -p /etc/rancher/k3s
sudo tee -a /etc/rancher/k3s/config.yaml >/dev/null <<'RMSNAP'
etcd-snapshot-schedule-cron: "${snap_cron}"
etcd-snapshot-retention: ${snap_retention}
${s3_lines}RMSNAP

SNAP
)"
  fi

  local vpn_auth="name=tailscale,joinKey=${authkey}"
  local plan
  plan="$(rm::node::_plan_block <<EOF
# --- runner-mesh: first cluster node (server) ---
# Run these on the Linux host that becomes your cluster's control plane.

# 1) Install the Tailscale client, if not already present:
command -v tailscale >/dev/null 2>&1 || curl -fsSL ${RM_TAILSCALE_INSTALL_URL} | sudo sh

${snapshot_step}
# 2) Install k3s as a server, joined to your tailnet as '${hostname}':
#    NOTE: --vpn-auth stays unquoted on purpose. The value has no spaces,
#    and embedded quotes end up escaped into the systemd unit, which the
#    vpn-auth parser then rejects with an unknown-parameter error.
#    NOTE: kube-reserved/system-reserved/eviction-hard fence CPU+RAM off
#    for the control plane so co-located runner pods can never OOM the API
#    server. On a small or single-node cluster the server is ALSO a worker,
#    so this is not optional — without it a CI burst takes the whole
#    cluster down (a greedy runner should be evicted; the API must survive).
#    The reserved amounts are a fixed floor — a larger share on small nodes,
#    where the risk is highest.
#    NOTE: 'sudo env VAR=...' (not 'VAR=... sudo') — default sudoers
#    env_reset silently strips a preceding assignment, so the installer
#    would see no INSTALL_K3S_EXEC and bootstrap a bare standalone server
#    (no --vpn-auth, wrong node name). 'sudo env' passes it through.
curl -sfL ${RM_K3S_INSTALL_URL} | \\
  sudo env INSTALL_K3S_EXEC="server --node-name ${hostname} --token ${token}${cluster_init} --vpn-auth=${vpn_auth} --kubelet-arg=image-gc-high-threshold=80 --kubelet-arg=image-gc-low-threshold=70 --kubelet-arg=kube-reserved=cpu=500m,memory=1Gi --kubelet-arg=system-reserved=cpu=250m,memory=512Mi --kubelet-arg=eviction-hard=memory.available<500Mi,nodefs.available<10%" \\
  sh -s -

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
#    NOTE: 'sudo env VAR=...' (not 'VAR=... sudo') — default sudoers
#    env_reset silently strips a preceding assignment, so the installer
#    would see no INSTALL_K3S_EXEC and bootstrap a bare standalone server
#    instead of this agent. 'sudo env' passes it through.
curl -sfL ${RM_K3S_INSTALL_URL} | \\
  sudo env INSTALL_K3S_EXEC="agent --node-name ${hostname} --server https://${server}:6443 --token ${token} --vpn-auth=${vpn_auth} --kubelet-arg=image-gc-high-threshold=80 --kubelet-arg=image-gc-low-threshold=70" \\
  sh -s -

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

# rm::node::promote — PLAN the recovery of a dead control plane onto a
# surviving node by restoring the latest etcd snapshot (from node:init's
# schedule) and taking over the old server's tailnet identity, so agents
# and every 'server_ip' reference keep working unchanged. This is FAST
# RECOVERY (minutes), not seamless failover: it assumes the target node is
# up and a recent snapshot exists. Like all node:* commands it only prints
# the plan — the destructive --cluster-reset restore is yours to review and
# run. Validate the restore on a throwaway cluster before you rely on it.
rm::node::promote() {
  local target="" server_ip="" token="" authkey="" snapshot="" hostname="" write_to=""
  local s3_endpoint="" s3_bucket="" s3_folder="runner-mesh" s3_access="" s3_secret="" s3_region=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to|--target)  target="$2"; shift 2 ;;
      --server-ip)    server_ip="$2"; shift 2 ;;
      --token)        token="$2"; shift 2 ;;
      --authkey)      authkey="$2"; shift 2 ;;
      --hostname)     hostname="$2"; shift 2 ;;
      --snapshot)     snapshot="$2"; shift 2 ;;
      --write-script) write_to="$2"; shift 2 ;;
      --snapshot-s3-endpoint)   s3_endpoint="$2"; shift 2 ;;
      --snapshot-s3-bucket)     s3_bucket="$2"; shift 2 ;;
      --snapshot-s3-folder)     s3_folder="$2"; shift 2 ;;
      --snapshot-s3-region)     s3_region="$2"; shift 2 ;;
      --snapshot-s3-access-key) s3_access="$2"; shift 2 ;;
      --snapshot-s3-secret-key) s3_secret="$2"; shift 2 ;;
      *) rm::die "unknown flag: $1" ;;
    esac
  done
  [[ -n "${target}" && -n "${server_ip}" && -n "${token}" ]] \
    || rm::die "usage: runner-mesh node:promote --to <new-server-node-name> --server-ip <dead-server-tailnet-ip> --token <cluster-token> [--snapshot NAME] [--snapshot-s3-* ...] [--authkey KEY]"
  [[ -n "${hostname}" ]] || hostname="${target}"
  authkey="$(rm::net::resolve_authkey "${authkey}")"
  local vpn_auth="name=tailscale,joinKey=${authkey}"

  # S3 restore flags (when snapshots live off-node — the case that
  # actually survives the old server's death).
  local s3_flags="" restore_src="local snapshot"
  if [[ -n "${s3_bucket}" ]]; then
    s3_flags=" --etcd-s3 --etcd-s3-endpoint=${s3_endpoint} --etcd-s3-bucket=${s3_bucket} --etcd-s3-folder=${s3_folder} --etcd-s3-region=${s3_region} --etcd-s3-access-key=${s3_access} --etcd-s3-secret-key=${s3_secret}"
    restore_src="S3 (${s3_bucket}/${s3_folder})"
  fi
  local restore_path="${snapshot:-<latest-snapshot-name>}"

  local plan
  plan="$(rm::node::_plan_block <<EOF
# --- runner-mesh: promote '${target}' to control plane (disaster recovery) ---
# The old server is gone; this restores its state from ${restore_src} onto
# '${target}' and takes over its tailnet IP (${server_ip}) so agents and
# every committed server_ip reference keep working. Run ON '${target}'.

# 0) In the Tailscale admin console FIRST: remove the dead server's device,
#    then reassign its IP ${server_ip} to '${target}' (Machines -> ${target}
#    -> Edit machine IP). Tailnet IPs can't be moved from the CLI. Without
#    this, agents (which target ${server_ip}) can't find the new server.

# 1) If '${target}' is currently an agent, remove that role (keeps tailscaled):
sudo /usr/local/bin/k3s-agent-uninstall.sh 2>/dev/null || true

# 2) List available snapshots to pick --snapshot (skip if you already know it):
sudo k3s etcd-snapshot list${s3_flags} 2>/dev/null || true

# 3) Restore the snapshot into a fresh single-node control plane. This is
#    DESTRUCTIVE on '${target}' (resets any local cluster state) — that's the
#    point of recovery. --tls-san keeps the taken-over IP valid in the cert.
sudo systemctl stop k3s k3s-agent 2>/dev/null || true
curl -sfL ${RM_K3S_INSTALL_URL} | \\
  sudo env INSTALL_K3S_EXEC="server --cluster-reset --cluster-reset-restore-path=${restore_path}${s3_flags}" \\
  sh -s -

# 4) Re-launch as a normal server with the same identity + hardening as
#    node:init (token, IP takeover via --tls-san, snapshots, reservations):
curl -sfL ${RM_K3S_INSTALL_URL} | \\
  sudo env INSTALL_K3S_EXEC="server --node-name ${hostname} --token ${token} --cluster-init --tls-san ${server_ip} --vpn-auth=${vpn_auth} --kubelet-arg=kube-reserved=cpu=500m,memory=1Gi --kubelet-arg=system-reserved=cpu=250m,memory=512Mi --kubelet-arg=eviction-hard=memory.available<500Mi,nodefs.available<10%" \\
  sh -s -
sudo tailscale set --hostname=${hostname}

# 5) Confirm the restored control plane is up and the node is Ready:
sudo systemctl status k3s --no-pager
sudo k3s kubectl get nodes -o wide

# 6) Surviving agents point at ${server_ip} and reconnect automatically once
#    the IP takeover (step 0) propagates. Any agent that had cached the old
#    cluster CA must be re-joined: runner-mesh node:join --server ${server_ip} --token ${token}
EOF
  )"

  rm::node::_emit_plan "${plan}" k3s
  rm::warn "review the --cluster-reset restore before running — it is destructive on '${target}' by design"
  rm::warn "the token above is a cluster-join secret — treat it like a password, don't commit it"
  rm::node::_maybe_write_script "${write_to}" "${plan}"
}

# rm::node::watchdog — PLAN the install of a control-plane watchdog that
# watches the primary server and, on sustained loss, recovers the cluster
# onto a standby. This is the "automatic" trigger for node:promote — still
# fast RECOVERY in minutes, not seamless failover, and honest about it:
#
#   * Install it ON THE STANDBY (self-promotion): the node that will take
#     over is the one watching, so there's no third box to keep alive.
#   * Default is ALERT-ONLY — detect + notify. --auto-promote opts into the
#     destructive path (IP takeover via the Tailscale API + snapshot
#     restore). Auto-promoting on a network partition (primary alive but
#     unreachable) risks split-brain; the check uses a consecutive-failure
#     threshold + grace, but on a small single-network fleet you should
#     understand the tradeoff before enabling it.
#   * Prerequisites on the standby for --auto-promote: runner-mesh on PATH,
#     the fleet Tailscale OAuth credential (for the IP takeover), the
#     cluster token, and a reachable off-node snapshot (node:init
#     --snapshot-s3-*). A restore you've never rehearsed is not a plan.
rm::node::watchdog() {
  local primary="" standby="" token="" interval="30" fails="4" alert_cmd="" auto="false" write_to=""
  local s3_flags_str="" hostname=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --primary)      primary="$2"; shift 2 ;;
      --standby)      standby="$2"; shift 2 ;;
      --hostname)     hostname="$2"; shift 2 ;;
      --token)        token="$2"; shift 2 ;;
      --interval)     interval="$2"; shift 2 ;;
      --fails)        fails="$2"; shift 2 ;;
      --alert-cmd)    alert_cmd="$2"; shift 2 ;;
      --auto-promote) auto="true"; shift ;;
      --snapshot-s3-flags) s3_flags_str="$2"; shift 2 ;;
      --write-script) write_to="$2"; shift 2 ;;
      *) rm::die "unknown flag: $1" ;;
    esac
  done
  [[ -n "${primary}" && -n "${standby}" ]] \
    || rm::die "usage: runner-mesh node:watchdog --primary <server-ip> --standby <node-name> [--token T] [--auto-promote] [--interval 30] [--fails 4] [--alert-cmd CMD] [--snapshot-s3-flags '...']"
  [[ -n "${hostname}" ]] || hostname="${standby}"
  [[ "${auto}" != "true" || -n "${token}" ]] \
    || rm::die "--auto-promote needs --token (the cluster join token) so the standby can restore"

  local promote_block alert_line mode_desc
  mode_desc="alerts"; [[ "${auto}" == "true" ]] && mode_desc="auto-recovers"
  alert_line="${alert_cmd:-logger -t rm-watchdog \"PRIMARY ${primary} DOWN — control plane needs recovery onto ${standby}\"}"
  if [[ "${auto}" == "true" ]]; then
    promote_block="$(cat <<PROMOTE
  # --auto-promote: take over the primary's tailnet IP (API, no console),
  # then restore the latest snapshot onto this standby. DESTRUCTIVE here by
  # design. Guarded by the failure threshold above; still understand the
  # split-brain risk on a partition.
  runner-mesh net:ip --hostname "${hostname}" --ip "${primary}" || { logger -t rm-watchdog "IP takeover failed — aborting auto-promote"; exit 1; }
  runner-mesh node:promote --to "${standby}" --server-ip "${primary}" --token "${token}" ${s3_flags_str} --write-script /tmp/rm-promote.sh
  bash /tmp/rm-promote.sh
  logger -t rm-watchdog "auto-promote of ${standby} completed"
PROMOTE
)"
  else
    promote_block="  logger -t rm-watchdog \"ALERT-ONLY: run 'runner-mesh node:promote --to ${standby} --server-ip ${primary} --token <token>' to recover\""
  fi

  local plan
  plan="$(rm::node::_plan_block <<EOF
# --- runner-mesh: control-plane watchdog (install ON the standby '${standby}') ---
# Watches the primary server at ${primary} and ${mode_desc} on sustained
# loss. Runs every ${interval}s; acts after ${fails} consecutive fails.

# 1) The watchdog check script:
sudo tee /usr/local/bin/rm-cp-watchdog >/dev/null <<'RMWD'
#!/bin/bash
set -euo pipefail
PRIMARY="${primary}"; FAILS="${fails}"; STATE=/var/lib/rm-watchdog/fails
mkdir -p "\$(dirname "\$STATE")"
if curl -sk --max-time 5 "https://\${PRIMARY}:6443/readyz" 2>/dev/null | grep -q '^ok'; then
  echo 0 > "\$STATE"; exit 0
fi
n=\$(( \$(cat "\$STATE" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "\$STATE"
if [ "\$n" -lt "\$FAILS" ]; then
  logger -t rm-watchdog "primary \${PRIMARY} check failed (\$n/\$FAILS)"; exit 0
fi
# Primary considered DOWN.
${alert_line}
${promote_block}
RMWD
sudo chmod +x /usr/local/bin/rm-cp-watchdog

# 2) systemd service + timer (every ${interval}s):
sudo tee /etc/systemd/system/rm-cp-watchdog.service >/dev/null <<'RMSVC'
[Unit]
Description=runner-mesh control-plane watchdog
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/rm-cp-watchdog
RMSVC
sudo tee /etc/systemd/system/rm-cp-watchdog.timer >/dev/null <<'RMTIMER'
[Unit]
Description=Run the runner-mesh control-plane watchdog periodically
[Timer]
OnBootSec=60
OnUnitActiveSec=${interval}
AccuracySec=5
[Install]
WantedBy=timers.target
RMTIMER
sudo systemctl daemon-reload && sudo systemctl enable --now rm-cp-watchdog.timer

# 3) Confirm it's scheduled:
systemctl list-timers rm-cp-watchdog.timer --no-pager
EOF
  )"

  rm::node::_emit_plan "${plan}" k3s
  if [[ "${auto}" == "true" ]]; then
    rm::warn "--auto-promote will restore + take over the IP automatically on sustained primary loss — rehearse it and understand the split-brain tradeoff first"
    rm::warn "the token embedded above is a cluster secret — the written script is root-only; don't commit it"
  fi
  rm::node::_maybe_write_script "${write_to}" "${plan}"
}
