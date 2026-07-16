# Multi-node clusters over Tailscale

> **Status: documented, not yet scripted.** `runner-mesh` today assumes you
> already have a working `kubectl` context (see `docs/roadmap.md`). This
> page documents the real, supported path for joining multiple machines —
> including ones that leave your LAN — into one cluster; wrapping it in a
> `runner-mesh cluster:join` command is tracked as a roadmap item.

## Why Tailscale here

Home clusters have two connectivity problems ordinary LAN networking
doesn't solve:

- A laptop that sometimes leaves the house needs to reach (and be reached
  by) the cluster from anywhere, without port-forwarding or a static IP.
- Heterogeneous machines (some behind different NATs, some mobile) need a
  stable, private address space to reference each other by.

Tailscale (WireGuard-based mesh VPN) solves both: every node gets a stable
private IP regardless of physical network, NAT traversal is automatic, and
there's a free tier (100 devices) that comfortably covers a homelab.

## k3s's built-in Tailscale integration

k3s has a first-class `--vpn-auth` flag for exactly this use case — nodes
use their Tailscale IP for cluster traffic instead of the LAN IP. Official
docs: <https://docs.k3s.io/networking/distributed-multicloud>.

High-level shape:

```bash
# On the server (control-plane) node:
k3s server --vpn-auth="name=tailscale,joinKey=<tailscale-auth-key>"

# On each agent node:
k3s agent --server https://<server-tailscale-ip>:6443 \
  --token <k3s-token> \
  --vpn-auth="name=tailscale,joinKey=<tailscale-auth-key>"
```

If you self-host coordination via Headscale instead of Tailscale's SaaS
control plane, append `controlServerURL=$YOUR_HEADSCALE_URL` to
`--vpn-auth`. Known rough edges with Headscale are tracked upstream:
<https://github.com/k3s-io/k3s/issues/12830> — read before committing to
that path.

## Node labeling for size-tiered scheduling

Once all nodes have joined:

```bash
kubectl label node <big-machine> runner-mesh.dev/size=large
kubectl label node <small-machine-1> runner-mesh.dev/size=small
kubectl label node <small-machine-2> runner-mesh.dev/size=small
```

Then use the `nodeSelector` block already present (commented out) in
`charts/values/scale-set.defaults.yaml` and the controller values to
schedule accordingly — heavy job runners on `large`, controller/listener
pods on `small`.

## Security note

Devices joining your tailnet inherit whatever your ACLs allow. Tag your
cluster nodes distinctly (e.g. `tag:runner-mesh-node`) and write explicit
ACL rules — don't rely on Tailscale's default allow-all between your own
devices once cluster nodes are in the mix. See `docs/security.md` for the
full reasoning (control-plane compromise, lateral movement from a
compromised runner pod to the node, etc.).
