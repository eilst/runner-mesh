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
- `node:init` / `node:join` / `node:auto` — plan (validate inputs,
  generate the join token, do read-only Tailscale discovery, print the
  exact k3s + Tailscale bootstrap commands) a Tailscale-meshed multi-node
  cluster, including machines that leave the LAN. **Intentionally
  print-only, not auto-executing** — see `docs/tailscale-mesh.md` for why;
  this is a permanent design choice, not a gap to close later. Not yet
  exercised against a real k3s install (no Linux host was available while
  building it) — validate on real hardware before relying on it.

## Phase 2 — designed, not yet automated

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

- **`node:*` auto-executing installers** — `curl | sudo sh` run
  autonomously on your behalf, even for a well-known installer like
  get.k3s.io or tailscale.com's, is a different trust category than
  everything else this tool does (which only ever acts via your existing
  kubectl credentials against a cluster you already control). `node:*`
  will always print/plan, never execute, on principle — not a gap, a
  boundary.
- **A custom repo-access picker replacing GitHub's own App-installation
  UI** — GitHub's native installation screen is the actual authorization
  boundary and already has a correct, audited UX for it; `runner-mesh`
  builds on top of it (see `docs/github-app-setup.md`), not around it.
