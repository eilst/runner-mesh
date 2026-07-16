# Security Policy

## Supported Versions

This project is pre-1.0. Only the `main` branch receives security fixes
until a first stable release is tagged.

## Reporting a Vulnerability

Please **do not** open a public issue for security vulnerabilities.

Instead, use GitHub's private vulnerability reporting for this repository
(Security tab → "Report a vulnerability"). If that is unavailable, contact
the repository owner directly through their GitHub profile.

Include:

- A description of the vulnerability and its impact
- Steps to reproduce
- Affected version/commit

We aim to acknowledge reports within 5 business days.

## Threat Model Summary

runner-mesh grants a GitHub App scoped, revocable access to specific
repositories, and runs ephemeral, single-job CI runners inside your own
Kubernetes cluster. Key boundaries this project relies on and defends:

- **Runner pods are ephemeral and namespace-isolated per repository** — a
  compromised job in one repo's runner should not have a network path to
  another repo's runners or to cluster-admin resources by default.
- **No long-lived registration tokens** — runner registration uses
  GitHub's just-in-time (JIT) tokens minted per-job by the Actions Runner
  Controller, not static PATs baked into pods.
- **GitHub App credentials are the highest-value secret** in this system.
  They are stored as a Kubernetes Secret and never logged or templated into
  Helm release values that could end up in `helm get values` output in
  plaintext history beyond the Secret itself.
- **Public repositories using self-hosted runners are inherently
  higher-risk** (fork PRs can execute arbitrary code on your infrastructure
  before review, depending on workflow trigger configuration). See
  `docs/security.md` for guidance.

See `docs/security.md` for the full threat model and hardening checklist.
