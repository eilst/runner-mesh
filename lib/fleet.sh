#!/usr/bin/env bash
# fleet:init / fleet:apply — config-repo support, following the Gradle-wrapper
# pattern: a fleet config repo holds DATA (repos.txt, runner-mesh.version,
# values/) plus a ~20-line shim whose only job is to fetch the engine at the
# pinned ref and delegate here. All real logic stays in this versioned
# engine, so config repos never need upstream fixes.
# Intended to be sourced, not executed.

rm::fleet::_parse_repos() {
  # Prints one owner/repo per line from a repos.txt, stripping comments,
  # whitespace, and blank lines.
  local file="$1" line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%%#*}"
    line="$(printf '%s' "${line}" | tr -d '[:space:]')"
    [[ -n "${line}" ]] && printf '%s\n' "${line}"
  done < "${file}"
}

# fleet:apply [config-dir] [--prune] — converge the cluster on the config
# repo's declared state: sync committed value overrides, ensure the
# controller, provision every repo in repos.txt. With --prune, also remove
# scale-sets that are no longer listed (never the default: prune deletes
# infrastructure, so it stays opt-in per invocation).
rm::fleet::apply() {
  local config_dir="" prune=0 arg
  for arg in "$@"; do
    case "${arg}" in
      --prune) prune=1 ;;
      -*) rm::die "unknown flag: ${arg}" ;;
      *) config_dir="${arg}" ;;
    esac
  done
  config_dir="${config_dir:-.}"
  config_dir="$(cd "${config_dir}" && pwd)" || rm::die "config dir not found"
  [[ -f "${config_dir}/repos.txt" ]] \
    || rm::die "no repos.txt in ${config_dir} — is this a fleet config repo? (see 'runner-mesh fleet:init')"

  rm::preflight::run || rm::die "fix the failed checks above, then re-run"
  rm::fleet::_unseal "${config_dir}"
  rm::github_app::require_config

  # Committed per-repo overrides are the fleet's source of truth — sync
  # them into the local dir repos:add reads from, so every machine
  # converges on the same config.
  local f synced=0
  mkdir -p "${RM_REPOS_STATE_DIR}"
  for f in "${config_dir}"/values/*.values.yaml; do
    [[ -e "${f}" ]] || continue
    cp "${f}" "${RM_REPOS_STATE_DIR}/$(basename "${f}")"
    synced=$((synced + 1))
  done
  rm::info "synced ${synced} committed value override(s) from values/"

  rm::cluster::install

  local -a repos=()
  local repo
  while IFS= read -r repo; do
    repos+=("${repo}")
  done < <(rm::fleet::_parse_repos "${config_dir}/repos.txt")

  if [[ ${#repos[@]} -eq 0 ]]; then
    rm::warn "repos.txt lists no repos — nothing to provision"
  else
    rm::repos::add "${repos[@]}"
  fi

  if [[ "${prune}" == "1" ]]; then
    rm::fleet::_prune "${repos[@]+"${repos[@]}"}"
  fi

  rm::log "Fleet converged. Current state:"
  rm::status::run
}

# Remove provisioned scale-sets whose repo is no longer in repos.txt.
# A release name is a slug (owner-repo, lowercased) — ambiguous to reverse
# — so the original owner/repo is recovered from the githubConfigUrl in the
# per-repo values file repos:add generated.
rm::fleet::_prune() {
  local -a keep_slugs=()
  local repo
  for repo in "$@"; do
    keep_slugs+=("$(rm::repos::_slug "${repo}")")
  done

  local releases ns release slug keep url
  releases="$(helm list --all-namespaces -o json 2>/dev/null \
    | jq -r '.[] | select(.namespace == "arc-runners" or (.namespace | startswith("arc-runners-"))) | "\(.namespace)\t\(.name)"')"

  while IFS=$'\t' read -r ns release; do
    [[ -z "${release}" ]] && continue
    keep=0
    for slug in "${keep_slugs[@]+"${keep_slugs[@]}"}"; do
      [[ "${release}" == "${slug}" ]] && { keep=1; break; }
    done
    [[ "${keep}" == "1" ]] && continue

    # Prefer the entry marker (preserves an @profile suffix, which the
    # githubConfigUrl necessarily loses); fall back to the URL for values
    # files generated before the marker existed.
    url="$(sed -nE 's|^# runner-mesh-entry:[[:space:]]*||p' "${RM_REPOS_STATE_DIR}/${release}.values.yaml" 2>/dev/null | head -1)"
    [[ -n "${url}" ]] || url="$(grep -E '^githubConfigUrl:' "${RM_REPOS_STATE_DIR}/${release}.values.yaml" 2>/dev/null \
      | sed -E 's|^githubConfigUrl:[[:space:]]*"?https://github.com/([^"]+)"?.*|\1|')"
    if [[ -z "${url}" ]]; then
      rm::warn "prune: cannot resolve '${ns}/${release}' back to owner/repo (no local values file) — remove manually with repos:remove"
      continue
    fi
    rm::log "prune: ${url} is provisioned but not in repos.txt"
    rm::repos::remove "${url}"
  done <<<"${releases}"
}

# --- Sealed secrets (SOPS + age) ------------------------------------------
# The fleet repo may carry the GitHub App credentials ENCRYPTED
# (secrets/github-app.enc.json, sealed with SOPS against a fleet age key).
# The age key is secret zero: one line, copied to each machine's
# ~/.config/runner-mesh/age.key over a secure channel, never committed.
# Chosen over Bitnami sealed-secrets (decryptable only inside one specific
# cluster — useless for pre-cluster machine bootstrap, and orphaned if the
# homelab cluster is ever rebuilt) and over GitHub repo secrets (write-only;
# unreadable outside Actions runs).

RM_AGE_KEY_FILE="${RM_AGE_KEY_FILE:-${RM_CONFIG_DIR}/age.key}"

# fleet:seal [dir] — encrypt the local GitHub App credentials into the
# fleet repo. Generates the fleet age key on first use.
rm::fleet::seal() {
  local dir="${1:-.}"
  command -v sops >/dev/null 2>&1 || rm::die "sops is required (brew install sops)"
  command -v age-keygen >/dev/null 2>&1 || rm::die "age is required (brew install age)"
  rm::github_app::require_config
  [[ -f "${dir}/repos.txt" ]] || rm::die "${dir} doesn't look like a fleet config repo"

  if [[ ! -f "${RM_AGE_KEY_FILE}" ]]; then
    mkdir -p "$(dirname "${RM_AGE_KEY_FILE}")"
    age-keygen -o "${RM_AGE_KEY_FILE}" 2>/dev/null
    chmod 600 "${RM_AGE_KEY_FILE}"
    rm::ok "generated fleet age key at ${RM_AGE_KEY_FILE}"
  fi
  local pubkey
  pubkey="$(age-keygen -y "${RM_AGE_KEY_FILE}")"

  mkdir -p "${dir}/secrets"
  sops --encrypt --age "${pubkey}" --output "${dir}/secrets/github-app.enc.json" \
    "${RM_APP_CONFIG}" \
    || rm::die "sops encryption failed"

  rm::ok "sealed App credentials -> ${dir}/secrets/github-app.enc.json (commit this)"
  rm::log "to let another machine unseal: copy ${RM_AGE_KEY_FILE} to it over a"
  rm::info "secure channel (one line — this is the fleet's secret zero; never commit it)"
}

# Unseal on apply: if the repo carries sealed credentials and this machine
# has none locally, decrypt them into place. A locally-present file is left
# alone (app:init on this machine is newer truth than the repo until the
# operator re-seals).
rm::fleet::_unseal() {
  local config_dir="$1"
  local sealed="${config_dir}/secrets/github-app.enc.json"
  [[ -f "${sealed}" ]] || return 0
  [[ -f "${RM_APP_CONFIG}" ]] && return 0
  if ! command -v sops >/dev/null 2>&1; then
    rm::warn "sealed credentials present but sops isn't installed (brew install sops)"
    return 0
  fi
  if [[ ! -f "${RM_AGE_KEY_FILE}" ]]; then
    rm::warn "sealed credentials present but no age key at ${RM_AGE_KEY_FILE} — copy the fleet key there to unseal"
    return 0
  fi
  mkdir -p "$(dirname "${RM_APP_CONFIG}")"
  if SOPS_AGE_KEY_FILE="${RM_AGE_KEY_FILE}" sops --decrypt "${sealed}" > "${RM_APP_CONFIG}"; then
    chmod 600 "${RM_APP_CONFIG}"
    rm::ok "unsealed App credentials from the fleet repo"
  else
    rm -f "${RM_APP_CONFIG}"
    rm::die "failed to decrypt ${sealed} — wrong age key?"
  fi
}

# fleet:init [dir] — scaffold a new fleet config repo: data files plus the
# delegating shim. Generated by the engine so shim and engine can't drift.
rm::fleet::init() {
  local dir="${1:-.}"
  mkdir -p "${dir}/values"
  dir="$(cd "${dir}" && pwd)"

  local clobber=""
  for f in bootstrap.sh repos.txt runner-mesh.version; do
    [[ -e "${dir}/${f}" ]] && clobber="${clobber} ${f}"
  done
  if [[ -n "${clobber}" ]]; then
    rm::confirm "This will overwrite:${clobber}. Continue?" || rm::die "aborted"
  fi

  local engine_ref engine_url
  engine_ref="$(git -C "${RM_ROOT}" rev-parse HEAD 2>/dev/null || echo main)"
  engine_url="$(git -C "${RM_ROOT}" remote get-url origin 2>/dev/null || echo 'https://github.com/eilst/runner-mesh.git')"

  printf '%s\n' "${engine_ref}" > "${dir}/runner-mesh.version"

  cat > "${dir}/repos.txt" <<'EOF'
# One owner/repo per line. Lines starting with # are ignored.
# The GitHub App must already be installed on each repo listed here
# (GitHub → Settings → Applications → your app → Configure).
#
# example-org/example-repo
EOF

  cat > "${dir}/.gitignore" <<'EOF'
.runner-mesh/
*.pem
*.key
.env
.DS_Store
EOF

  cat > "${dir}/values/README.md" <<'EOF'
# Per-repo value overrides

Optional. One file per repo, named `<owner>-<repo>.values.yaml`
(lowercase, `/` → `-`). `./bootstrap.sh` syncs these before
provisioning, so the overrides committed here are what every machine
converges on. Fleet-wide defaults live in the engine:
`.runner-mesh/charts/values/scale-set.defaults.yaml`.
EOF

  # The shim: the only executable code a fleet repo carries. Fetches the
  # engine at the pinned ref, then delegates everything to fleet:apply.
  cat > "${dir}/bootstrap.sh" <<EOF
#!/usr/bin/env bash
# runner-mesh wrapper shim — fetches the pinned engine and delegates.
# All logic lives in the engine; keep this file boring and stable.
set -euo pipefail
HERE="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
ENGINE="\${HERE}/.runner-mesh"
REPO="\${RUNNER_MESH_REPO:-${engine_url}}"
REF="\$(tr -d '[:space:]' < "\${HERE}/runner-mesh.version")"
[[ -d "\${ENGINE}/.git" ]] || git clone --quiet "\${REPO}" "\${ENGINE}"
git -C "\${ENGINE}" fetch --quiet --tags origin
git -C "\${ENGINE}" checkout --quiet "\${REF}"
if git -C "\${ENGINE}" symbolic-ref -q HEAD >/dev/null; then
  git -C "\${ENGINE}" pull --quiet --ff-only origin "\${REF}"
fi
exec "\${ENGINE}/bin/runner-mesh" fleet:apply "\${HERE}" "\$@"
EOF
  chmod +x "${dir}/bootstrap.sh"

  # Day-2 conveniences. Engine commands go through the shim-fetched engine
  # so they always match the pin; k9s/kubectl just use the current context.
  cat > "${dir}/Makefile" <<'EOF'
ENGINE := .runner-mesh/bin/runner-mesh

.PHONY: apply prune status doctor k9s watch-runners

apply: ## converge this machine on the declared fleet state
	./bootstrap.sh

prune: ## also remove scale-sets no longer in repos.txt
	./bootstrap.sh --prune

status: ## controller + per-repo runner pool health
	$(ENGINE) status

doctor: ## verify toolchain and cluster connectivity
	$(ENGINE) doctor

k9s: ## open k9s in the controller namespace (listeners live here too)
	k9s -n arc-systems

watch-runners: ## watch ephemeral runner pods come and go as jobs run
	kubectl get pods -n arc-runners --watch
EOF

  cat > "${dir}/README.md" <<'EOF'
# Fleet config for runner-mesh

Data-only config repo (plus a small delegating shim) for
[runner-mesh](https://github.com/eilst/runner-mesh). Keep it **private**
— it names your repos and machines. It must never hold credentials.

| File | Purpose |
|---|---|
| `repos.txt` | Repos to provision, one `owner/repo` per line |
| `runner-mesh.version` | Engine git ref (tag/branch/commit) — bump to upgrade |
| `values/` | Committed per-repo overrides, synced on every apply |
| `bootstrap.sh` | Shim: fetch pinned engine → `runner-mesh fleet:apply` |
| `Makefile` | Day-2 targets: `apply`, `prune`, `status`, `doctor`, `k9s`, `watch-runners` |

## Any machine, any time (idempotent)

```bash
make apply     # converge this machine on the declared state (./bootstrap.sh)
make prune     # also remove scale-sets no longer in repos.txt
make status    # controller + per-repo runner pool health
make k9s       # inspect the cluster (controller + listeners namespace)
```

`make status`/`doctor`/`k9s` need the engine present — run `make apply`
once on a fresh clone first. One-time per fleet:
`./.runner-mesh/bin/runner-mesh app:init` on your first machine.
Additional machines need `~/.config/runner-mesh/github-app.json` copied
over a secure channel — deliberately never committed.
EOF

  rm::ok "fleet config scaffolded in ${dir} (engine pinned to ${engine_ref})"
  rm::info "edit repos.txt, commit to a private repo, then run ./bootstrap.sh"
}
