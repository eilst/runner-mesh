# runner-mesh

Ephemeral, autoscaling GitHub Actions runners on **your own** Kubernetes
cluster — no fixed containers idling 24/7, no per-repo hand registration,
namespace-isolated per repository, authenticated as a scoped GitHub App
instead of a personal access token.

`runner-mesh` is a thin, opinionated CLI over
[`actions/actions-runner-controller`](https://github.com/actions/actions-runner-controller)
(ARC) — GitHub's own Kubernetes controller for self-hosted runners. It
doesn't reimplement runner registration; it makes the parts around ARC
(GitHub App setup, per-repo onboarding, node sizing, cluster health) fast
and safe to operate.

## Why

Running a fixed pair of always-on Docker containers as self-hosted runners
works, but it doesn't scale with job volume, wastes resources at idle, has
no per-repo isolation, and typically relies on a long-lived token. ARC
fixes the underlying mechanics — scale-to-zero, JIT per-job tokens,
Kubernetes-native scheduling — but wiring it up (GitHub App, per-repo
scale-sets, namespaces, node sizing) is enough manual YAML that most
homelab/small-team setups skip it. `runner-mesh` is that wiring, scripted
and idempotent.

## What you get

- **Scale-to-zero**: `minRunners: 0` by default — a runner pod only exists
  while a job is actually queued or running.
- **Namespace-per-repo isolation**: a compromised job in one repo's runner
  has no path to another repo's runners by default. See
  [`docs/architecture.md`](docs/architecture.md).
- **GitHub App auth**, not a PAT: scoped, revocable, not tied to your
  personal account. `app:init` automates everything except the one
  GitHub-mandated browser click. See
  [`docs/github-app-setup.md`](docs/github-app-setup.md).
- **Two-layer runner limits**: business-level `maxRunners` per repo, plus
  real pod `resources.requests`/`limits` as the physical ceiling — both
  configurable, neither alone sufficient. See
  [`docs/architecture.md`](docs/architecture.md).
- **Bring-your-own-cluster**: works against any `kubectl` context — colima
  (`--kubernetes`), k3d, bare-metal k3s, anything conformant. Cluster
  provisioning is deliberately out of scope; see
  [`docs/roadmap.md`](docs/roadmap.md) for why.

## Quickstart

The fastest path to seeing this work end-to-end is a local disposable
cluster — see [`docs/quickstart-colima.md`](docs/quickstart-colima.md) for
the full walkthrough. Short version:

```bash
colima start --kubernetes
kubectl config use-context colima

./bin/runner-mesh doctor            # verify toolchain + cluster
./bin/runner-mesh cluster:install   # install the ARC controller (once)
./bin/runner-mesh app:init          # create a GitHub App (one browser click)
./bin/runner-mesh repos:list        # see repos the App can access
./bin/runner-mesh repos:add         # interactively pick which get runners
./bin/runner-mesh status            # controller + per-repo health
```

## Prerequisites

- `bash` >= 5
- `kubectl`, pointed at a cluster you control
- `helm` >= 3.14
- `gh` CLI, authenticated
- `jq`, `python3`, `openssl`

`./bin/runner-mesh doctor` checks all of the above and tells you exactly
what's missing.

## Commands

| Command | Does |
|---|---|
| `doctor` | Verify local toolchain and cluster connectivity |
| `cluster:install` | Install/upgrade the ARC controller (cluster-wide, once) |
| `cluster:uninstall` | Remove the controller |
| `app:init` | Create a GitHub App via the manifest flow, store credentials |
| `repos:list` | List repos the App can see and their provisioned state |
| `repos:add [owner/repo ...]` | Provision a runner pool (interactive if no args) |
| `repos:remove <owner/repo>` | Tear down a repo's runner pool |
| `status` | Controller + per-repo runner pool health |

Global flags: `--yes`/`-y` (skip confirmations), `--dry-run`.

## Documentation

- [`docs/architecture.md`](docs/architecture.md) — components, isolation
  model, runner-limit layers, node sizing
- [`docs/github-app-setup.md`](docs/github-app-setup.md) — the manifest
  flow, what's automated vs. the one manual step
- [`docs/quickstart-colima.md`](docs/quickstart-colima.md) — end-to-end
  local walkthrough
- [`docs/tailscale-mesh.md`](docs/tailscale-mesh.md) — joining multiple
  machines (including ones that leave your LAN) into one cluster
- [`docs/security.md`](docs/security.md) — threat model and hardening
  checklist
- [`docs/roadmap.md`](docs/roadmap.md) — what's implemented vs. designed

## Status

Pre-1.0, actively developed. The core loop (controller install, GitHub App
setup, per-repo provisioning, status) is implemented and CI-tested against
a real k3d cluster on every push. Multi-node Tailscale cluster join is
currently a documented manual process, not yet a scripted command — see
the roadmap.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Small, focused, Conventional
Commits preferred.

## License

[MIT](LICENSE)
