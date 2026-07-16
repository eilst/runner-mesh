# Multi-node clusters over Tailscale

> **Status: `node:init`/`node:join`/`node:auto` plan this for you** — they
> validate inputs, generate the join token if needed, do read-only
> Tailscale discovery, and print the exact commands below with your
> values filled in. They deliberately don't execute anything privileged
> themselves (no `curl | sudo sh` run on your behalf) — you review and run
> the printed commands, or pass `--write-script <path>` to save them to a
> file first. This has not been exercised against a real k3s install by
> the person who wrote it (no Linux host was available) — validate on
> your own hardware and report back if something's off.

## Quickest path: `node:auto`

Same two secrets, same command, on every machine, in any order:

```bash
# Generate a shared cluster secret once, keep it like a password:
openssl rand -hex 32
# Get a reusable Tailscale auth key from https://login.tailscale.com/admin/settings/keys

runner-mesh node:auto --authkey <tailscale-auth-key> --secret <the-shared-secret>
```

The first machine you run this on won't find an existing server (checked
via read-only `tailscale status`) and becomes one. Every machine after
that finds it and joins as an agent. If you run it on two machines at the
exact same moment before either has become the server, both may try to —
stagger the first run by ~30 seconds instead of racing them.

## Explicit path: `node:init` / `node:join`

More control, same underlying plan, split into two steps:

```bash
# On the machine that becomes your control plane:
runner-mesh node:init --authkey <tailscale-auth-key>
# → prints the exact node:join command with the generated token filled in

# On every additional machine, run what it printed:
runner-mesh node:join --server runner-mesh-server --token <printed-token> --authkey <tailscale-auth-key>
```

## macOS nodes (colima)

k3s only runs on Linux, so on a Mac the cluster node lives inside a
colima-managed Linux VM. `node:init`/`node:join`/`node:auto` detect
macOS and prepend the colima steps to their printed plan automatically.
The key points, because two of them are easy to get wrong:

1. **Don't use `colima start --kubernetes` for meshed nodes.** That flag
   installs colima's own bundled k3s *without* `--vpn-auth`, so it can
   neither host nor join a Tailscale-meshed cluster. It's great for the
   single-machine quickstart (`docs/quickstart-colima.md`) — but a meshed
   node needs a plain `colima start`, then the k3s install from the
   printed plan run inside `colima ssh`. Converting an existing
   `--kubernetes` colima into a meshed server means redoing that VM's
   k3s — plan for a brief teardown + `cluster:install`/`repos:add`
   re-run (fast, since the GitHub App credentials are already on disk).
2. **Tailscale runs inside the VM, not the macOS host.** k3s's
   `--vpn-auth` drives the `tailscale` CLI in the same OS it runs in.
   The Mac's own Tailscale app is only useful for `node:auto`'s
   read-only "is there already a server?" discovery check.

> **Validation status — read before relying on this:** the Linux
> bare-metal path below matches k3s's documented `--vpn-auth` contract.
> The macOS/colima variant (k3s + Tailscale inside a colima VM, meshed
> across two Macs) has **not yet been validated end-to-end on real
> hardware** by the authors. If you run it, expect possible rough edges
> around the VM's NAT (Tailscale should traverse it — that's its job —
> but this specific combination is unproven here) and please open an
> issue with results either way.

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
