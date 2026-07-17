# Control-plane availability: declared primary, watchdog, and true HA

This builds on `docs/control-plane-recovery.md` (snapshots + `node:promote`).
That doc gives you fast *manual* recovery; this one adds the two remaining
layers: **declaring** the control plane in git, **automatically triggering**
recovery, and — for those who need it — **true zero-downtime HA**. Tracking
issue: eilst/runner-mesh#12.

## 1. Declare the control plane in git (`control-plane.yaml`)

Commit `control-plane.yaml` (see `control-plane.yaml.example`) to the fleet
repo. It names the intended primary, the tailnet IP agents target, and the
standby to promote to — so failover targets are versioned, reviewable config
rather than knowledge that dies with whoever set the cluster up:

```yaml
primary:  runner-mesh-azure-1
serverIP: 100.87.244.37
standby:  runner-mesh-macbook-m1
snapshots: { s3Bucket: ..., s3Endpoint: ..., s3Region: ... }
watchdog:  { autoPromote: false, interval: 30, fails: 4 }
```

`node:watchdog` and `node:promote` take the same values as flags; this file
is where an operator (or a fleet wrapper) reads them from. Secrets stay out
of it — reference the sealed fleet secret / `terraform output`.

> **Why git can declare but not *execute* failover:** Flux runs *on* the
> cluster, so it dies with the API server. It can hold the desired primary;
> it cannot fail the control plane over. The trigger has to live off-cluster
> — that's the watchdog.

## 2. Automatic trigger: `node:watchdog`

Install a watchdog **on the standby** (self-promotion — no third box to keep
alive). It polls the primary and acts on sustained loss:

```bash
# alert-only (default, safe): detect + notify, you run node:promote
runner-mesh node:watchdog --primary 100.87.244.37 --standby runner-mesh-macbook-m1 \
  --alert-cmd 'curl -sX POST "$SLACK_WEBHOOK" -d ...'

# hands-off recovery (opt-in): take over the IP via the Tailscale API and
# restore the snapshot automatically
runner-mesh node:watchdog --primary 100.87.244.37 --standby runner-mesh-macbook-m1 \
  --token <cluster-token> --auto-promote \
  --snapshot-s3-flags "$(terraform -chdir=terraform/snapshot-bucket output -raw promote_s3_flags)"
```

It installs a systemd timer that every `--interval` seconds checks
`https://<primary>:6443/readyz`; after `--fails` consecutive failures it
alerts, and with `--auto-promote` it:

1. `net:ip` — reassigns the primary's tailnet IP to the standby via the
   Tailscale API (the "take over the IP" step, hands-off, no console), then
2. `node:promote` — restores the latest off-node snapshot onto the standby.

Agents targeting `serverIP` reconnect once the IP moves; no per-agent reconfig.

### This is fast *recovery*, not seamless *failover* — and its limits

- **Downtime is minutes, not zero** — a restore has to run.
- **The standby must be awake** with a recent off-node snapshot. A sleeping
  laptop standby can't recover anything.
- **Split-brain risk on a network partition:** if the primary is alive but
  unreachable *from the standby*, `--auto-promote` will promote anyway and you
  briefly have two servers claiming `serverIP`. The consecutive-fail threshold
  + grace reduces false positives, but on anything larger than a single flat
  network, prefer alert-only + a human, or move to true HA (below).
- **Rehearse the restore** on a throwaway cluster before enabling
  `--auto-promote`. Automation on top of an unrehearsed restore just automates
  a failure.

## 3. True HA (zero-downtime auto-failover)

The only way to get *seamless* failover — no restore, no downtime — is a
quorum of always-on servers:

1. **3 (or 5) server nodes** with embedded etcd (`node:init` uses
   `--cluster-init`; additional servers join with `--server`). Odd count for
   quorum; losing one leaves a majority and the API never blinks.
2. **All servers must be always-on.** etcd quorum degrades when a member
   sleeps or roams — so **laptops can't be servers**. In practice this means
   3 cloud VMs, ~3× the control-plane spend.
3. **A floating API endpoint** so clients survive any single server's death:
   - a cloud load balancer in front of the three, or
   - `kube-vip` advertising a VIP, or
   - a Tailscale Service (VIP) fronting the server nodes.
   Point agents' `--server` and the kubeconfig at that endpoint, not a single
   node's IP.

For most runner-mesh fleets (small, laptop-heavy, cost-sensitive) this is
overkill — the declared-primary + off-node snapshots + watchdog stack above
is the right answer. Reach for true HA only when minutes of control-plane
downtime are genuinely unacceptable and three always-on servers are worth it.

## Which layer do you want?

| Need | Use |
|---|---|
| Survive a bad reset | local snapshots (`node:init` default) |
| Survive the host dying, recover by hand in minutes | off-node snapshots + `node:promote` |
| Get paged and recover on loss without watching | `node:watchdog` (alert-only) |
| Hands-off recovery in minutes | `node:watchdog --auto-promote` |
| Zero-downtime, no human, no restore | 3-node HA + floating endpoint |
