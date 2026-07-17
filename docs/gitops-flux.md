# GitOps mode: Flux CD

`fleet:apply` is imperative: an operator machine converges the cluster
when a human runs it. GitOps mode inverts that — [Flux CD](https://fluxcd.io)
runs *in* the cluster, watches the fleet repo, and reconciles
continuously: push to git, the cluster converges within a minute, from
anywhere, with no operator toolchain in the loop. Manual drift (a
hand-run `helm upgrade`) is reverted automatically.

Both modes read the same sources of truth (`repos.txt`, `values/`), so
you can adopt GitOps incrementally and keep `make apply` as a fallback.

## What `fleet:gitops` generates

Run against a fleet config repo:

```bash
runner-mesh fleet:gitops ~/my-fleet
```

| File | Purpose |
|---|---|
| `kustomization.yaml` | Root kustomization: resources + a values ConfigMap per pool (edits to `values/*.values.yaml` flow into the HelmReleases on push) |
| `flux/namespaces.yaml` | `arc-systems`, `arc-runners` |
| `flux/controller.yaml` | OCI HelmRepository + the ARC controller HelmRelease |
| `flux/pools/<slug>.yaml` | One HelmRelease per `repos.txt` entry, layered defaults→overrides |
| `flux/defaults/` | The engine chart defaults this generation pinned (visible, versioned) |
| `flux/secrets/github-config.enc.yaml` | GitHub App credentials as SOPS-encrypted Secrets — safe in git |
| `flux/sync.yaml` | The Flux `Kustomization` CR that wires it all up (applied once) |

Everything generated carries a `GENERATED` header — re-run
`fleet:gitops` after editing `repos.txt` rather than hand-editing.
Your `values/*.values.yaml` files are referenced, never rewritten.

## One-time bootstrap

Prerequisites: the [flux CLI](https://fluxcd.io/flux/installation/)
(`brew install fluxcd/tap/flux`), a fleet repo that has been
`fleet:seal`-ed at least once (the age key must exist), and cluster
access.

```bash
# 1. Install Flux in the cluster, wired to the fleet repo
#    (asks for a GitHub token with repo scope — used once for setup):
flux bootstrap github --owner <you> --repository <fleet-repo> --personal --path flux-system

# 2. Give Flux the fleet age key so it can decrypt the sealed secrets:
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey=$HOME/.config/runner-mesh/age.key

# 3. Generate + push the layout:
runner-mesh fleet:gitops .
git add -A && git commit -m "gitops: flux layout" && git push

# 4. Point Flux at it:
kubectl apply -f flux/sync.yaml

# Watch it converge:
flux get helmreleases -n flux-system --watch
```

From here on, the loop is: edit `repos.txt` or `values/` → (re-run
`fleet:gitops` if `repos.txt` changed) → commit → push. No kubectl, no
helm, no gh required on the pushing machine.

## Day-2 semantics

- **Adding a repo/pool**: add the line to `repos.txt`, run
  `fleet:gitops`, push. Flux installs the pool; the App credentials
  Secret for it was generated and sealed in the same run.
- **Changing pool sizing**: edit `values/<slug>.values.yaml`, push.
  (No regeneration needed — values flow via ConfigMap generators.)
- **Removing a pool**: remove from `repos.txt`, run `fleet:gitops`,
  push. `prune: true` in `flux/sync.yaml` deletes the HelmRelease, and
  ARC's finalizers deregister the scale set from GitHub.
- **Engine upgrades**: `fleet:gitops` pins the ARC chart version it was
  generated with (`RM_ARC_CHART_VERSION`); regenerate to roll the fleet
  forward deliberately.
- **GitHub outage**: Flux keeps the last-applied state and resumes
  polling when GitHub returns. Runners keep working exactly as in
  imperative mode (the listeners hold their own broker sessions).

## What stays outside GitOps

Flux governs what runs *inside* the cluster. The engine CLI keeps
everything at or below the node line:

- `app:init` / `net:init` — one-time browser flows for credentials
- `node:init` / `node:join` / `node:auto` — host-level plans (k3s
  installs, systemd drop-ins, Tailscale) — see
  [`tailscale-mesh.md`](tailscale-mesh.md)
- `repos:audit` / `repos:migrate` — workflow analysis and migration PRs
- `fleet:seal` — sealing credentials (GitOps consumes what it seals)
