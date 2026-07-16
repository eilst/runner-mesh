# Architecture

## Components

```
┌─────────────────────────────────────────────────────────────┐
│  Kubernetes cluster (yours — bare metal, colima, k3d, …)     │
│                                                                │
│  ┌── namespace: arc-systems ────────────────────────────────┐│
│  │  ARC controller (cluster-wide singleton, watches CRDs)    ││
│  └────────────────────────────────────────────────────────────┘│
│                                                                │
│  ┌── namespace: arc-runners-org-repo-a ──────────────────────┐│
│  │  Secret: github-config-secret (App id/installation/key)   ││
│  │  Listener pod (1, watches org/repo-a's job queue)          ││
│  │  Ephemeral runner pod(s) — exist only while a job runs     ││
│  └────────────────────────────────────────────────────────────┘│
│                                                                │
│  ┌── namespace: arc-runners-org-repo-b ──────────────────────┐│
│  │  (same shape, fully isolated from repo-a)                  ││
│  └────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

- **Controller** (`cluster:install`): one per cluster. Reconciles
  `AutoscalingRunnerSet` custom resources. Never runs job workloads itself —
  see the small resource requests in `charts/values/controller.values.yaml`.
- **Scale-set** (`repos:add`): one per repo, in its own namespace. Its
  listener pod watches that repo's GitHub Actions job queue and creates a
  fresh, single-use runner pod per queued job using a JIT (just-in-time)
  token minted by the controller — never a long-lived registration token.
  When idle, `minRunners: 0` means no runner pods exist at all.

## Why namespace-per-repo

A compromised job in one repo's runner should not have a network or RBAC
path to another repo's runners, secrets, or the cluster's control plane.
Namespace boundaries plus `NetworkPolicy` (see `docs/security.md`) are the
blast-radius control for that. It costs a little more YAML per repo than one
shared namespace; that cost buys isolation that matters once you're running
CI for more than one trust boundary.

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
