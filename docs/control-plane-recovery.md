# Control-plane recovery

A runner-mesh cluster has one control plane (one k3s server). If that node
dies, the cluster is down until it's recovered. This is the **fast, honest**
answer to that — not fake auto-failover. Background: eilst/runner-mesh#12.

## What's sound (and what isn't)

The control plane *is* the cluster's datastore; it lives on the server's
disk. When the server dies, that state dies with it **unless it was
snapshotted somewhere else first**. So:

- **Sound:** snapshot the state off-node, and restore it onto a surviving
  node in minutes (`node:promote`). Recovery, not failover.
- **Not sound for small/laptop fleets:** "a standby node auto-becomes the
  control plane." A cold standby has no state to promote from; true
  automatic failover needs **3+ always-on servers** running embedded etcd
  with a quorum (laptops that sleep/roam can't be members) plus a floating
  API endpoint. Worth it only for always-on, cost-tolerant fleets.
- **GitOps can't do it either:** Flux runs *on* the cluster, so it dies
  with the API server. It can declare the intended primary; it cannot fail
  the control plane over.

## Snapshots (enabled by `node:init`)

`node:init` now installs the server with embedded etcd (`--cluster-init`)
and scheduled snapshots — every 6 h, keep 20, by default:

```bash
# local snapshots only (die with the host — fine for accidental-reset,
# useless for host loss):
runner-mesh node:init

# off-node to S3/Azure-blob — the kind that survives the host dying:
runner-mesh node:init \
  --snapshot-cron '0 */4 * * *' --snapshot-retention 30 \
  --snapshot-s3-endpoint <blob-endpoint> --snapshot-s3-bucket <bucket> \
  --snapshot-s3-access-key <key> --snapshot-s3-secret-key <secret>

# opt out entirely:
runner-mesh node:init --no-snapshots
```

**Put snapshots off-node.** A snapshot on the dead server's own disk
protects you from a bad reset, not from the host burning down.

## Recovery: `node:promote`

When the server is gone, promote a surviving node — restore the latest
snapshot and take over the dead server's tailnet IP so agents and every
committed `server_ip` reference keep working:

```bash
runner-mesh node:promote \
  --to runner-mesh-macbook-m1 --server-ip 100.87.244.37 --token <cluster-token> \
  --snapshot-s3-bucket <bucket> --snapshot-s3-endpoint <endpoint> \
  --snapshot-s3-access-key <key> --snapshot-s3-secret-key <secret> \
  --snapshot <name>            # omit to pick from the printed 'etcd-snapshot list'
```

Like every `node:*` command it only **prints** the plan; you review and run
it. The plan: (0) reassign the dead server's IP to the target in the
Tailscale console, (1) drop any agent role, (2) list snapshots, (3) restore
via `--cluster-reset` (destructive on the target, by design), (4) relaunch
as a server with the same identity + hardening, (5) verify, (6) re-join any
agent whose cached CA is stale.

> ⚠️ **Validate the restore on a throwaway cluster before you rely on it.**
> `--cluster-reset` is destructive; a recovery you've never rehearsed is a
> hope, not a plan.

## Toward automatic (opt-in, later)

An external watchdog (a cron on a second always-on box, or a cloud
function — anything *not* on this cluster) can run `node:promote` when it
sees the server down. That's the closest honest thing to automatic:
**fast recovery in minutes**, still requires the target awake and a recent
snapshot. It is not, and cannot be, seamless zero-downtime failover — that
remains the 3-server HA path.
