# Security model

## What a compromised GitHub job can and can't reach

Each job runs in a fresh, ephemeral pod, in a namespace scoped to exactly
one repo. By default that pod can still reach:

- The internet (to talk to GitHub, pull images, install dependencies).
- Other pods in the *same* namespace, unless you add a `NetworkPolicy`.
- Whatever the pod's ServiceAccount is authorized for via RBAC (default:
  minimal, but verify — see checklist below).

It should **not**, with a correctly configured cluster, be able to reach
another repo's namespace, the controller's namespace, or the underlying
node — but that containment is only as good as your `NetworkPolicy` and
RBAC configuration, plus the container runtime's isolation. `runner-mesh`
does not currently ship default-deny `NetworkPolicy` objects out of the box
— see `docs/roadmap.md`.

## Public repos are a different risk class

If any repo you add is **public**, self-hosted runners are a well-known
attack surface: a pull request from an untrusted fork can, depending on
your workflow trigger configuration (`pull_request_target`,
`workflow_run`, etc.), execute arbitrary code on your infrastructure
before a maintainer reviews it. This is not specific to `runner-mesh` — it
applies to any self-hosted runner. If you add a public repo:

- Require approval for first-time contributors' workflow runs (repo
  Settings → Actions → General → Fork pull request workflows).
- Never use `pull_request_target` with a checkout of the PR's own code
  unless you understand the implications.
- Consider a dedicated, more tightly firewalled namespace for that repo
  specifically.

## GitHub App credential compromise

The App's private key (`~/.config/runner-mesh/github-app.json`, and the
`github-config-secret` copied into each repo's namespace) is the
highest-value secret in this system. If it leaks:

- An attacker can mint installation tokens scoped to whatever repos the
  App is installed on — read/write Actions, read/write repo
  administration.
- It does **not** grant access to repos the App isn't installed on, or to
  your personal GitHub account more broadly — this is the actual benefit
  of the App model over a PAT.

Mitigation: the key never leaves your machine except as a Kubernetes
Secret (never templated into Helm values, never logged). Rotate via
`runner-mesh app:init` (see `docs/github-app-setup.md`) if you suspect
exposure, and reduce the App's installed-repo list to the minimum you
actually need.

## Cluster node compromise → lateral movement

If a job pod escapes to its underlying node (privileged containers, a
mounted host Docker socket, `hostPath`/`hostNetwork` misconfiguration),
the attacker inherits that node's network identity — including its
Tailscale connection if you've joined a multi-node mesh (see
`docs/tailscale-mesh.md`). From there, whatever your Tailscale ACLs allow
that node to reach is reachable. Mitigations:

- Never mount the host's Docker socket into a runner pod; use
  Docker-in-Docker (the chart's `containerMode: dind` default) instead.
- Tag cluster nodes distinctly in Tailscale and write explicit ACLs —
  don't rely on the default allow-all between your own devices once
  cluster nodes join the tailnet.
- If you self-host coordination via Headscale instead of Tailscale SaaS,
  you remove third-party control-plane trust but take on securing that
  server yourself — see `docs/tailscale-mesh.md`.

## Pre-flight checklist before going from private → public repos

- [ ] `NetworkPolicy` objects in place, default-deny between repo
      namespaces
- [ ] Fork PR workflow approval required (see above)
- [ ] `maxRunners` capped conservatively for that repo specifically
- [ ] Node-level isolation verified (no privileged pods, no host socket
      mounts)
- [ ] GitHub App installed on that repo only with the minimum permissions
      it actually needs
