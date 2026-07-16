# Roadmap

## Phase 1 — implemented

- `doctor` — local toolchain + cluster connectivity preflight
- `cluster:install` / `cluster:uninstall` — ARC controller lifecycle
- `app:init` — GitHub App manifest flow, credential storage
- `repos:list` / `repos:add` / `repos:remove` — per-repo, namespace-isolated
  scale-set provisioning with interactive multi-select
- `status` — controller + per-repo runner pool health
- Bring-your-own-cluster: colima (`--kubernetes`), k3d, bare-metal k3s, or
  any other conformant cluster all work identically, since `runner-mesh`
  only ever talks to whatever `kubectl` context is current

## Phase 2 — designed, not yet automated

- `cluster:join` — script the k3s `--vpn-auth` Tailscale bootstrap
  described in `docs/tailscale-mesh.md` instead of leaving it as a manual
  walkthrough
- Default `NetworkPolicy` objects generated per repo (default-deny except
  to the internet and the controller) — needed in **both** namespace
  modes: `shared` colocates repos in one namespace with no policy today,
  and `per-repo` looks isolated by namespace but isn't actually network-
  enforced either without this. In `per-repo` mode this selects by
  namespace; in `shared` mode it needs to select by a per-repo pod label
  instead. See `docs/security.md`.
- `ResourceQuota`/`LimitRange` per repo namespace (or per-repo label
  selector in `shared` mode) — today `maxRunners` and pod resource limits
  cap one repo's pod count and per-pod usage, but nothing caps a repo's
  *aggregate* footprint, so a busy repo can still starve others for
  capacity even though it can't exceed its own `maxRunners`.
- `app:rotate` — rotate GitHub App credentials and push the update to
  every provisioned repo's secret in one step, instead of requiring a
  manual `repos:add` re-run per repo
- Node auto-labeling helper for the `runner-mesh.dev/size` convention,
  instead of manual `kubectl label`
- Headscale (self-hosted Tailscale coordination) as a first-class,
  documented alternative to Tailscale SaaS

## Explicitly out of scope

- **Cluster provisioning itself** (turning bare machines into a joined
  k3s cluster) — `runner-mesh` is bring-your-own-cluster by design; this
  keeps the tool useful to anyone with a working `kubectl` context
  regardless of how they got one, and avoids duplicating tools like k3sup,
  Ansible, or Terraform that already do this well.
- **A custom repo-access picker replacing GitHub's own App-installation
  UI** — GitHub's native installation screen is the actual authorization
  boundary and already has a correct, audited UX for it; `runner-mesh`
  builds on top of it (see `docs/github-app-setup.md`), not around it.
