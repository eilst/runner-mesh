#!/usr/bin/env bash
# repos:list / repos:add / repos:remove — the per-repository layer on top of
# the shared ARC controller. Each repo gets its own namespace and Helm
# release ("scale-set"), isolated from every other repo's runners.
# Intended to be sourced, not executed.

RM_REPOS_CHART="oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set"
RM_REPOS_STATE_DIR="${RM_REPOS_STATE_DIR:-${RM_CONFIG_DIR}/repos}"

rm::repos::_slug() {
  # owner/repo -> owner-repo, lowercased, safe for k8s names (RFC 1123).
  local full="$1"
  printf '%s' "${full}" | tr '[:upper:]' '[:lower:]' | tr '/' '-' | tr -c 'a-z0-9-' '-'
}

rm::repos::_namespace() { printf 'arc-runners-%s\n' "$(rm::repos::_slug "$1")"; }
rm::repos::_release()   { rm::repos::_slug "$1"; }
rm::repos::_values_file() { printf '%s/%s.values.yaml\n' "${RM_REPOS_STATE_DIR}" "$(rm::repos::_slug "$1")"; }

rm::repos::_installation_id() {
  if [[ -n "${RM_INSTALLATION_ID:-}" ]]; then
    printf '%s\n' "${RM_INSTALLATION_ID}"
    return 0
  fi
  local installations count
  installations="$(rm::github_app::installations)"
  count="$(jq 'length' <<<"${installations}")"
  if [[ "${count}" == "0" ]]; then
    rm::die "the GitHub App has no installations yet — install it first, see 'app:init' output for the URL"
  elif [[ "${count}" == "1" ]]; then
    jq -r '.[0].id' <<<"${installations}"
  else
    rm::warn "multiple installations found; set RM_INSTALLATION_ID to pick one:"
    jq -r '.[] | "  \(.id)\t\(.account.login)"' <<<"${installations}" >&2
    rm::die "ambiguous installation"
  fi
}

# rm::repos::_available — repos the App installation can see, as "owner/name" lines.
rm::repos::_available() {
  local installation_id token
  installation_id="$(rm::repos::_installation_id)"
  token="$(rm::github_app::installation_token "${installation_id}")"
  [[ -n "${token}" && "${token}" != "null" ]] || rm::die "failed to mint an installation token"

  curl -fsSL "https://api.github.com/installation/repositories?per_page=100" \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.github+json" \
    | jq -r '.repositories[].full_name'
}

rm::repos::_is_provisioned() {
  local repo="$1"
  helm status "$(rm::repos::_release "${repo}")" -n "$(rm::repos::_namespace "${repo}")" >/dev/null 2>&1
}

rm::repos::list() {
  rm::github_app::require_config
  rm::log "Repos visible to the GitHub App:"
  local repo status
  while IFS= read -r repo; do
    [[ -z "${repo}" ]] && continue
    if rm::repos::_is_provisioned "${repo}"; then
      status="${RM_C_GREEN}provisioned${RM_C_RESET}"
    else
      status="${RM_C_DIM}not provisioned${RM_C_RESET}"
    fi
    printf '  %-40s %s\n' "${repo}" "${status}"
  done < <(rm::repos::_available)
}

# rm::repos::add [repo ...] — with no args, presents an interactive
# multi-select over installed-but-not-yet-provisioned repos.
rm::repos::add() {
  rm::github_app::require_config
  mkdir -p "${RM_REPOS_STATE_DIR}"

  local -a targets=("$@")
  if [[ ${#targets[@]} -eq 0 ]]; then
    local -a candidates=()
    local repo
    while IFS= read -r repo; do
      [[ -z "${repo}" ]] && continue
      rm::repos::_is_provisioned "${repo}" || candidates+=("${repo}")
    done < <(rm::repos::_available)

    if [[ ${#candidates[@]} -eq 0 ]]; then
      rm::ok "every repo visible to the App is already provisioned"
      return 0
    fi

    rm::log "Select repos to provision runners for:"
    local i
    for i in "${!candidates[@]}"; do
      printf '  [%d] %s\n' "$((i + 1))" "${candidates[${i}]}" >&2
    done
    read -r -p "Enter numbers (space-separated), or 'all': " selection
    if [[ "${selection}" == "all" ]]; then
      targets=("${candidates[@]}")
    else
      local n
      for n in ${selection}; do
        [[ "${n}" =~ ^[0-9]+$ ]] || continue
        targets+=("${candidates[$((n - 1))]}")
      done
    fi
  fi

  [[ ${#targets[@]} -gt 0 ]] || rm::die "no repos selected"

  local repo
  for repo in "${targets[@]}"; do
    rm::repos::_provision_one "${repo}"
  done
}

rm::repos::_provision_one() {
  local repo="$1"
  [[ "${repo}" == */* ]] || rm::die "expected 'owner/repo', got '${repo}'"

  local namespace release values_file installation_id app_id
  namespace="$(rm::repos::_namespace "${repo}")"
  release="$(rm::repos::_release "${repo}")"
  values_file="$(rm::repos::_values_file "${repo}")"
  installation_id="$(rm::repos::_installation_id)"
  app_id="$(jq -r .app_id "${RM_APP_CONFIG}")"

  rm::log "Provisioning ${repo} -> namespace '${namespace}'"

  kubectl get namespace "${namespace}" >/dev/null 2>&1 \
    || kubectl create namespace "${namespace}" >/dev/null

  local key_file
  key_file="$(mktemp -t runner-mesh-key.XXXXXX.pem)"
  jq -r .private_key "${RM_APP_CONFIG}" > "${key_file}"
  kubectl -n "${namespace}" create secret generic github-config-secret \
    --from-literal=github_app_id="${app_id}" \
    --from-literal=github_app_installation_id="${installation_id}" \
    --from-file=github_app_private_key="${key_file}" \
    --dry-run=client -o yaml | kubectl apply -f -
  rm -f "${key_file}"

  if [[ ! -f "${values_file}" ]]; then
    cat > "${values_file}" <<EOF
# Per-repo overrides for ${repo}. Fleet-wide defaults live in
# charts/values/scale-set.defaults.yaml — edit those for changes that
# should apply everywhere, or override here for ${repo} specifically.
githubConfigUrl: "https://github.com/${repo}"
githubConfigSecret: github-config-secret
EOF
  fi

  local -a cmd=(helm upgrade --install "${release}" "${RM_REPOS_CHART}"
    --namespace "${namespace}"
    -f "${RM_ROOT}/charts/values/scale-set.defaults.yaml"
    -f "${values_file}"
    --wait --timeout 5m)
  [[ "${RM_DRY_RUN:-0}" == "1" ]] && cmd+=(--dry-run)

  rm::info "${cmd[*]}"
  "${cmd[@]}" || rm::die "helm release failed for ${repo}"

  rm::ok "${repo} provisioned (namespace=${namespace}, release=${release})"
}

rm::repos::remove() {
  local repo="${1:-}"
  [[ -n "${repo}" ]] || rm::die "usage: runner-mesh repos:remove <owner>/<repo>"

  local namespace release
  namespace="$(rm::repos::_namespace "${repo}")"
  release="$(rm::repos::_release "${repo}")"

  rm::repos::_is_provisioned "${repo}" || rm::die "${repo} is not provisioned"

  rm::confirm "Remove runners for ${repo} (namespace ${namespace})?" || rm::die "aborted"

  helm uninstall "${release}" --namespace "${namespace}" \
    || rm::die "helm uninstall failed"
  kubectl delete namespace "${namespace}" --ignore-not-found=true >/dev/null
  rm -f "$(rm::repos::_values_file "${repo}")"

  rm::ok "${repo} runners removed"
}
