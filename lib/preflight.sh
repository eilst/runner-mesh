#!/usr/bin/env bash
# Preflight checks — verifies the local toolchain and cluster reachability
# before any command that touches the cluster runs.
# Intended to be sourced, not executed.

RM_MIN_HELM_MAJOR=3
RM_MIN_HELM_MINOR=14

rm::preflight::require_bin() {
  local bin="$1" hint="$2"
  if ! command -v "${bin}" >/dev/null 2>&1; then
    rm::warn "missing: ${bin} — ${hint}"
    return 1
  fi
  rm::ok "found ${bin}: $(command -v "${bin}")"
  return 0
}

rm::preflight::check_helm_version() {
  if ! command -v helm >/dev/null 2>&1; then
    return 1
  fi
  local ver major minor
  ver="$(helm version --template '{{.Version}}' 2>/dev/null | sed 's/^v//')"
  major="${ver%%.*}"
  minor="${ver#*.}"; minor="${minor%%.*}"
  if [[ -z "${major}" || -z "${minor}" ]]; then
    rm::warn "could not parse helm version output: '${ver}'"
    return 1
  fi
  if (( major > RM_MIN_HELM_MAJOR || (major == RM_MIN_HELM_MAJOR && minor >= RM_MIN_HELM_MINOR) )); then
    rm::ok "helm ${ver} (>= ${RM_MIN_HELM_MAJOR}.${RM_MIN_HELM_MINOR} required)"
    return 0
  fi
  rm::warn "helm ${ver} is older than the required ${RM_MIN_HELM_MAJOR}.${RM_MIN_HELM_MINOR}"
  return 1
}

rm::preflight::check_cluster_reachable() {
  if ! command -v kubectl >/dev/null 2>&1; then
    return 1
  fi
  local ctx
  if ! ctx="$(kubectl config current-context 2>/dev/null)"; then
    rm::warn "no current kubectl context set (run 'kubectl config use-context <name>')"
    return 1
  fi
  if ! kubectl version --request-timeout=5s >/dev/null 2>&1; then
    rm::warn "kubectl context '${ctx}' is set but the cluster is not reachable"
    return 1
  fi
  rm::ok "cluster reachable via context '${ctx}'"
  return 0
}

rm::preflight::check_gh_auth() {
  if ! command -v gh >/dev/null 2>&1; then
    return 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    rm::warn "gh CLI is installed but not authenticated (run 'gh auth login')"
    return 1
  fi
  rm::ok "gh CLI authenticated as $(gh api user --jq .login 2>/dev/null || echo unknown)"
  return 0
}

# rm::preflight::run — full doctor sweep. Returns non-zero if anything is missing.
rm::preflight::run() {
  local failed=0
  rm::log "Checking required tools..."
  rm::preflight::require_bin kubectl "https://kubernetes.io/docs/tasks/tools/" || failed=1
  rm::preflight::require_bin helm    "https://helm.sh/docs/intro/install/"     || failed=1
  rm::preflight::require_bin gh      "https://cli.github.com/"                 || failed=1
  rm::preflight::require_bin jq      "https://jqlang.github.io/jq/"            || failed=1
  rm::preflight::require_bin python3 "https://www.python.org/downloads/"       || failed=1
  rm::preflight::require_bin openssl "usually preinstalled; see your OS docs"  || failed=1

  rm::log "Checking versions and connectivity..."
  rm::preflight::check_helm_version        || failed=1
  rm::preflight::check_cluster_reachable   || failed=1
  rm::preflight::check_gh_auth             || failed=1

  if [[ "${failed}" == "1" ]]; then
    rm::warn "One or more preflight checks failed — fix the items above before continuing."
    return 1
  fi
  rm::ok "All preflight checks passed."
  return 0
}
