# Quickstart: colima on macOS

The fastest way to see `runner-mesh` work end-to-end is a local, disposable
Kubernetes cluster via [colima](https://github.com/abiosoft/colima)'s
built-in k3s support — no bare-metal, no Tailscale, no multi-node setup.

## Why a VM at all

k3s (like all of Kubernetes) is Linux-only — it needs systemd, Linux
namespaces, and cgroups, which macOS doesn't have. Every "Kubernetes on
a Mac" option is a Linux VM underneath; colima is simply the leanest
way to run one. The stack, bottom to top:

```
macOS (host)          ← kubectl, k9s, the runner-mesh CLI
└─ colima (Linux VM)  ← VM lifecycle, CPU/RAM/disk, Docker
   └─ k3s             ← the actual cluster node
      └─ ARC controller + ephemeral runner pods
```

Colima's k3s comes in two flavors, and the choice matters:

- **This quickstart** uses `colima start --kubernetes` — colima's bundled
  k3s. Zero setup, but it can't mesh: no `--vpn-auth`, API unreachable
  from other machines.
- **Multi-machine fleets** keep colima for the VM but install k3s inside
  it via the `node:init`/`node:join` printed plans, which add the
  Tailscale mesh flag. When you outgrow one machine, don't add a second
  `--kubernetes` colima — graduate to
  [`docs/tailscale-mesh.md`](tailscale-mesh.md) (it includes the
  conversion steps for an existing quickstart cluster).

## 1. Start a cluster

```bash
colima start --kubernetes
kubectl config use-context colima
```

## 2. Install prerequisites

```bash
brew install kubernetes-cli helm gh jq
gh auth login
```

## 3. Verify

```bash
./bin/runner-mesh doctor
```

All checks should pass. If `helm` or `kubectl` show as missing, confirm
they're on `PATH` and re-run.

## 4. Install the controller

```bash
./bin/runner-mesh cluster:install
```

## 5. Create a GitHub App and add a repo

```bash
./bin/runner-mesh app:init
# → follow the browser prompt, then install the App on a test repo
./bin/runner-mesh repos:list
./bin/runner-mesh repos:add owner/your-test-repo
```

## 6. Trigger a job and watch it

Push a commit (or re-run a workflow) in the repo you added, then:

```bash
./bin/runner-mesh status
kubectl -n arc-runners-owner-your-test-repo get pods --watch
```

You should see a runner pod appear when the job queues and disappear once
it finishes — that's `minRunners: 0` scale-to-zero working.

## Tear down

```bash
./bin/runner-mesh repos:remove owner/your-test-repo
./bin/runner-mesh cluster:uninstall
colima stop --kubernetes  # or `colima delete` to remove the VM entirely
```

## Moving to a real multi-node cluster

This quickstart is intentionally the smallest possible loop. For a
multi-machine home cluster joined over Tailscale, see
`docs/tailscale-mesh.md` — the same `runner-mesh` commands apply once
`kubectl` points at that cluster instead.
