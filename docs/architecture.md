# Architecture

## Components

```
┌─────────────────────────────────────────────────────────────┐
│  Kubernetes cluster (yours — bare metal, colima, k3d, …)     │
│                                                                │
│  ┌── namespace: arc-systems ────────────────────────────────┐│
│  │  ARC controller (cluster-wide singleton, watches CRDs)    ││
│  │  Listener pod for repo-a  ← ALWAYS here, not the repo's   ││
│  │  Listener pod for repo-b    own namespace, in EITHER mode ││
│  └────────────────────────────────────────────────────────────┘│
│                                                                │
│  ┌── namespace: arc-runners (default, RM_NAMESPACE_MODE=shared) ┐│
│  │  Secret: github-config-secret-org-repo-a                    ││
│  │  Secret: github-config-secret-org-repo-b                    ││
│  │  Ephemeral runner pod(s) — exist only while a job runs      ││
│  └────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

Verified by actually running this against a live production repository,
not just reading chart source: the **listener pod always lands in the
controller's own namespace** (`arc-systems`), regardless of
`RM_NAMESPACE_MODE` — this isn't something `runner-mesh` controls, it's how
ARC itself places it. Only the *ephemeral runner pods* (created when a job
actually runs) land in the repo's own namespace, via the
`EphemeralRunnerSet`. This matters for the isolation discussion below —
see the correction there.

- **Controller** (`cluster:install`): one per cluster. Reconciles
  `AutoscalingRunnerSet` custom resources. Never runs job workloads itself —
  see the small resource requests in `charts/values/controller.values.yaml`.
- **Scale-set** (`repos:add`): one per repo, always its own Helm release and
  listener pod — ARC requires one listener per repo's job queue regardless
  of namespace layout, so namespace choice doesn't change that cost. When
  idle, `minRunners: 0` means no runner pods exist at all.

## Namespace mode: shared vs. per-repo

Namespace objects themselves are free (a small etcd record, no reserved
CPU/memory) — the real per-repo cost is the listener pod, which exists
either way. So namespace layout is a pure isolation-vs-object-count
tradeoff, and it's configurable:

```bash
export RM_NAMESPACE_MODE=shared      # default — all repos in one namespace
export RM_SHARED_NAMESPACE=arc-runners  # override the shared namespace name

export RM_NAMESPACE_MODE=per-repo    # arc-runners-<owner>-<repo>, one each
```

**`shared` (default)** — every repo's scale-set lands in one namespace.
Fewer objects to manage, and notably: every repo under the same GitHub App
installation carries an *identical* credential (`app_id` /
`installation_id` / private key — a GitHub App installation covers every
repo you selected when installing it, it's not a per-repo credential), so
splitting that into N duplicated Secrets across N namespaces was pure
overhead with no real isolation benefit today. Tradeoff: **ephemeral
runner pods** (not listeners — see the correction above) in different
repos' scale-sets share the namespace's default ServiceAccount and network
reachability unless you add your own `NetworkPolicy` — see
`docs/security.md`, this is *not* yet a blast-radius boundary by default.

**`per-repo`** — `arc-runners-<owner>-<repo>` per repo, matching the
original design. Secrets and the default ServiceAccount become genuinely
namespace-scoped per repo for **runner pods** (a pod can't read another
namespace's Secret without explicit RBAC), which is real isolation today,
before any `NetworkPolicy` work lands. Costs more objects (namespace,
ServiceAccount, RBAC per repo) — negligible at homelab scale, worth
knowing about at hundreds of repos. **Does not extend to listener pods**:
every repo's listener lives in `arc-systems` regardless of this setting,
so `per-repo` mode isolates job execution but not the listener processes
themselves — there's no namespace-mode knob that changes that.

Either way, the Secret name is always `github-config-secret-<owner>-<repo>`
(never shared literally, even in `shared` mode) so a future per-repo App
installation doesn't collide with today's shared one.

## Two layers of runner limits

1. **`maxRunners`** (per scale-set, in `charts/values/scale-set.defaults.yaml`
   or a per-repo override) — a business-level cap independent of what the
   cluster can physically fit. Protects against one noisy repo starving
   others even when there's spare capacity.
2. **Pod `resources.requests`/`limits`** — the physical ceiling. Even with
   `maxRunners` set high, the Kubernetes scheduler won't place a pod without
   free allocatable capacity on some node; it queues as `Pending` until
   capacity frees up.

Both are configurable per repo; neither alone is sufficient.

## Node sizing convention

Label your nodes and let job runners target the right one:

```bash
kubectl label node <big-machine> runner-mesh.dev/size=large
kubectl label node <small-machine> runner-mesh.dev/size=small
```

Then uncomment the `nodeSelector` block in a repo's values file to pin its
runner pods to `large`, leaving small nodes free for the controller and
listener pods (which are lightweight — see `docs/architecture.md` above).

## Multi-node clusters over Tailscale

See `docs/tailscale-mesh.md` — this is documented as a roadmap item, not a
scripted `runner-mesh` command yet. k3s has built-in Tailscale integration
(`--vpn-auth`) that lets nodes join a cluster over a Tailscale mesh instead
of raw LAN IPs, which is what makes a roaming laptop a viable cluster node.
