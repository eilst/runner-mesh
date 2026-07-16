# Contributing

Thanks for considering a contribution.

## Development setup

Prerequisites: `bash` >= 5, `kubectl`, `helm` >= 3.14, `gh`, `jq`, `python3`.

```bash
make doctor   # verify local toolchain
make lint     # shellcheck + yaml lint
make test     # smoke test against a throwaway k3d cluster
```

## Commit conventions

This repo uses [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(cli): add repos:remove subcommand
fix(helm): correct maxRunners default for scale-set values
docs(readme): clarify github app manifest flow
```

Commits should be small, atomic, and buildable/lintable in isolation —
prefer several focused commits over one large one.

## Pull requests

- One logical change per PR.
- Include a one-line rationale in the PR description (the "why", not a
  restatement of the diff).
- CI (`lint`, `smoke-test`) must pass before review.

## Code style

- Shell scripts must pass `shellcheck` (see `.shellcheckrc`).
- No inline secrets, ever — use the Secret-generation helpers in `lib/`.
- Prefer explicit, readable bash over cleverness (`set -euo pipefail` in
  every script, no unquoted variable expansions).
