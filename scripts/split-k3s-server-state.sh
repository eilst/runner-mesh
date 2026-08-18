#!/usr/bin/env bash
# Move a k3s SERVER's control-plane state off the node's local/ephemeral disk
# and onto the OS disk, bind-mounted back so k3s never learns the path moved.
#
# ── WHY ──────────────────────────────────────────────────────────────────────
# `--data-dir` is all-or-nothing. On these nodes it points at the Azure local
# NVMe (/mnt/k3s) for a good reason: the OS disk is network-attached block
# storage, so a checkout-heavy CI job pays a network round trip per file.
# Measured on runner-mesh-amd64-1: ~7.8 TB/day of writes land on the local
# disk while the OS disk sits at 0.2% of its bandwidth. Keeping containerd
# layers, kubelet and every runner emptyDir there is correct and should stay.
#
# But --data-dir also drags along <data-dir>/server — db, tls/server-ca.crt,
# cred/passwd. That is a few hundred MB of irreplaceable cluster identity, and
# Azure REPLACES the local disk on any resize or deallocate. So on a node that
# is only an agent this layout is free; the moment the node is repurposed as
# the server it silently becomes a liability:
#
#   deallocate  ->  /mnt wiped  ->  new CA + empty passwd  ->  agents cannot
#   rejoin, Flux needs re-bootstrapping. The cluster is not stopped, it is
#   erased.
#
# That is why runner-mesh-amd64-1 currently cannot be stopped at night or
# resized. This script splits the two classes apart:
#
#   hot / disposable / TB-per-day  -> stays on local NVMe   (containerd, kubelet, emptyDirs)
#   cold / precious / a few hundred MB -> moves to OS disk  (server/)
#
# ── AFTER THIS RUNS ──────────────────────────────────────────────────────────
# The node becomes safe to deallocate and safe to resize, without giving up any
# of the local-disk performance it was sized for.
#
# NOTE: systemd creates a mount unit's `Where=` directory if it is missing, so
# after a deallocate wipes /mnt the mountpoint is recreated and the OS-disk
# state is bound straight back in.
#
# SEPARATE PRE-EXISTING ISSUE, NOT FIXED HERE: cloud-init only formats the
# Azure resource disk when it looks unformatted, and a resize hands back an
# NTFS-formatted disk — so /mnt itself may fail to mount (nofail, silently)
# after a resize. Reformat with wipefs + mkfs.ext4 on
# /dev/disk/cloud/azure_resource-part1 before relying on the local disk again.
#
# ── SAFETY ───────────────────────────────────────────────────────────────────
# Idempotent, verify-first, and reversible: the original server/ is renamed
# aside rather than deleted, and a tarball is taken before anything is touched.
# It stops k3s, so it is a maintenance window — on a single-node cluster that
# means CI is down for its duration.
#
# Usage:
#   sudo ./split-k3s-server-state.sh --dry-run    # print the plan, touch nothing
#   sudo ./split-k3s-server-state.sh              # execute, with confirmation
#
# Rollback (if k3s will not come up):
#   systemctl stop k3s
#   systemctl disable --now "$(systemd-escape -p --suffix=mount /mnt/k3s/server)"
#   rm -rf /mnt/k3s/server && mv /mnt/k3s/server.pre-split /mnt/k3s/server
#   rm -f /etc/systemd/system/k3s.service.d/30-server-state-mount.conf
#   systemctl daemon-reload && systemctl start k3s

set -euo pipefail

DATA_DIR="${DATA_DIR:-/mnt/k3s}"
STATE_DIR="${STATE_DIR:-/var/lib/rancher/k3s-server-state}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/k3s}"
DRY_RUN=0
[[ "${1:-}" = "--dry-run" ]] && DRY_RUN=1

SRC="$DATA_DIR/server"
PARKED="$DATA_DIR/server.pre-split"

log()  { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
die()  { printf '\nABORT: %s\n' "$*" >&2; exit 1; }
# Takes an argv array, not a string: eval would negate the quoting we rely on
# for paths (SC2294).
run()  {
  if [[ "$DRY_RUN" == 1 ]]; then printf '   [dry-run] %s\n' "$*"; else "$@"; fi
}

# ── Preconditions ────────────────────────────────────────────────────────────
# Every one of these is a way this migration could silently do the wrong thing.

log "Preconditions"

[[ "$(id -u)" = 0 ]] || die "must run as root (it writes systemd units and moves cluster state)"

command -v systemd-escape >/dev/null || die "systemd-escape not found — is this a systemd host?"

# Server, not agent. On an agent there is no server/ directory and this whole
# migration is a no-op that would only add confusion.
if systemctl list-unit-files --no-legend 2>/dev/null | grep -q '^k3s\.service'; then
  K3S_UNIT=k3s.service
elif systemctl list-unit-files --no-legend 2>/dev/null | grep -q '^k3s-agent\.service'; then
  die "this node runs k3s-agent, not a server — agents have no server/ state, nothing to split"
else
  die "no k3s.service or k3s-agent.service found"
fi
info "k3s unit: $K3S_UNIT"

[[ -d "$SRC" ]] || die "$SRC does not exist — is DATA_DIR=$DATA_DIR correct?"

# If the data dir is already on the root filesystem there is no ephemeral disk
# in play, so there is nothing to protect against.
if [[ "$(stat -c %d /)" = "$(stat -c %d "$DATA_DIR")" ]]; then
  die "$DATA_DIR is already on the OS disk — no local/ephemeral disk to split off, nothing to do"
fi
info "$DATA_DIR is on a separate device from / (as expected)"

# Already migrated? Then this is a re-run and we can exit clean.
if mountpoint -q "$SRC"; then
  info "$SRC is ALREADY a mountpoint — migration appears complete"
  findmnt -no SOURCE,TARGET "$SRC" | sed 's/^/   /'
  log "Nothing to do."
  exit 0
fi

SRC_KB=$(du -sk "$SRC" | cut -f1)
# Free space on the filesystem that will hold STATE_DIR.
AVAIL_KB=$(df -Pk "$(dirname "$STATE_DIR")" | awk 'NR==2{print $4}')
info "server/ size: $((SRC_KB/1024)) MB   OS-disk free: $((AVAIL_KB/1024)) MB"
# Need room for the copy AND the safety tarball.
[[ "$AVAIL_KB" -gt "$((SRC_KB * 3))" ]] \
  || die "not enough OS-disk space: need ~3x $((SRC_KB/1024))MB for copy + backup, have $((AVAIL_KB/1024))MB"

MOUNT_UNIT="$(systemd-escape -p --suffix=mount "$SRC")"
info "mount unit will be: $MOUNT_UNIT"

# ── Plan ─────────────────────────────────────────────────────────────────────

log "Plan"
cat <<PLAN
   1. tar  $SRC  ->  $BACKUP_DIR/  (safety copy, taken while k3s is stopped)
   2. stop $K3S_UNIT                             <-- CLUSTER DOWN FROM HERE
   3. copy $SRC  ->  $STATE_DIR    (cp -a, then verified)
   4. mv   $SRC  ->  $PARKED       (kept, NOT deleted — this is the rollback)
   5. write /etc/systemd/system/$MOUNT_UNIT       ($STATE_DIR --bind--> $SRC)
   6. write /etc/systemd/system/k3s.service.d/30-server-state-mount.conf
   7. enable the mount, verify the bind is live
   8. start $K3S_UNIT and wait for it to report healthy
PLAN

if [[ "$DRY_RUN" = 1 ]]; then
  log "Dry run — nothing was changed."
  exit 0
fi

printf '\nThis STOPS k3s. On a single-node cluster, CI is down until step 8.\nType EXACTLY "migrate" to proceed: '
read -r CONFIRM
[[ "$CONFIRM" = "migrate" ]] || die "not confirmed"

# ── Execute ──────────────────────────────────────────────────────────────────

log "2. Stopping $K3S_UNIT"
run systemctl stop "$K3S_UNIT"
# k3s leaves containerd shims behind; give the sqlite/etcd files a moment to
# settle so the tarball and copy are of a quiesced tree, not a live one.
sleep 5

log "1. Safety backup (taken after the stop so the state is quiesced)"
run mkdir -p "$BACKUP_DIR"
BACKUP_FILE="$BACKUP_DIR/server-pre-split-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
run tar -czf "$BACKUP_FILE" -C "$DATA_DIR" server
info "backup: $BACKUP_FILE"

log "3. Copying server state to the OS disk"
run mkdir -p "$(dirname "$STATE_DIR")"
run rm -rf "$STATE_DIR.partial"
# -a preserves mode/owner/timestamps/symlinks, which the TLS material needs.
run cp -a "$SRC" "$STATE_DIR.partial"

# Verify before we move the original aside. A short copy here would be
# unrecoverable-looking later, so compare file counts and bytes.
SRC_FILES=$(find "$SRC" | wc -l)
DST_FILES=$(find "$STATE_DIR.partial" | wc -l)
DST_KB=$(du -sk "$STATE_DIR.partial" | cut -f1)
info "source: $SRC_FILES entries / $((SRC_KB/1024)) MB"
info "copy:   $DST_FILES entries / $((DST_KB/1024)) MB"
[[ "$SRC_FILES" = "$DST_FILES" ]] || die "copy verification FAILED (entry count differs) — original untouched at $SRC"
run rm -rf "$STATE_DIR"
run mv "$STATE_DIR.partial" "$STATE_DIR"

log "4. Parking the original (rollback point — not deleted)"
run mv "$SRC" "$PARKED"
run mkdir -p "$SRC"

log "5. Writing the bind-mount unit"
if [[ "$DRY_RUN" = 0 ]]; then
  cat > "/etc/systemd/system/$MOUNT_UNIT" <<EOF
[Unit]
Description=k3s server state on the durable OS disk (survives Azure resize/deallocate)
# $SRC lives under the local/ephemeral disk, so that must be mounted first.
RequiresMountsFor=$DATA_DIR
Before=$K3S_UNIT

[Mount]
What=$STATE_DIR
Where=$SRC
Type=none
Options=bind

[Install]
WantedBy=local-fs.target
EOF
fi

log "6. Ordering k3s after the mount"
run mkdir -p /etc/systemd/system/k3s.service.d
if [[ "$DRY_RUN" = 0 ]]; then
  cat > /etc/systemd/system/k3s.service.d/30-server-state-mount.conf <<EOF
[Unit]
# Refuse to start rather than silently rebuild control-plane state on a
# disk the mount was supposed to cover. Same reasoning as the kubelet
# drop-in written by cloud-init.
RequiresMountsFor=$SRC
EOF
fi

log "7. Enabling the mount"
run systemctl daemon-reload
run systemctl enable --now "$MOUNT_UNIT"
mountpoint -q "$SRC" || die "bind mount did not come up — roll back with the header instructions"
info "bind is live:"
findmnt -no SOURCE,TARGET "$SRC" | sed 's/^/   /'
[[ -f "$SRC/cred/passwd" ]] || die "server/cred/passwd missing through the mount — roll back"
info "control-plane files visible through the mount"

log "8. Starting $K3S_UNIT"
run systemctl start "$K3S_UNIT"

READY=0
for i in $(seq 1 60); do
  if k3s kubectl get --raw='/readyz' >/dev/null 2>&1; then
    READY=1
    info "control plane READY after ~${i}0s"
    break
  fi
  sleep 10
done
# Explicit flag, not `[[ ... ]] && die` as the loop's last statement: under
# `set -e` a false test there terminates the script instead of continuing.
[[ "$READY" == 1 ]] || die "control plane not ready after 10min — roll back with the header instructions"

log "Done"
cat <<DONE
   server state now lives on the OS disk:  $STATE_DIR
   bound back into place at:               $SRC
   backup tarball:                         $BACKUP_FILE
   rollback copy still on the local disk:  $PARKED

   VERIFY BEFORE CLEANING UP — check nodes are Ready and Flux is reconciling:
     k3s kubectl get nodes
     k3s kubectl get pods -A | grep -v Running

   Once satisfied, reclaim the local-disk copy:
     rm -rf $PARKED

   This node can now be deallocated and resized without erasing the cluster.
DONE
