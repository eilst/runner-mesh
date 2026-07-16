#!/usr/bin/env bash
# Install/uninstall the Actions Runner Controller (ARC) itself. This is a
# cluster-wide singleton — one controller serves every repo's scale-set.
# Intended to be sourced, not executed.

RM_ARC_NAMESPACE="${RM_ARC_NAMESPACE:-arc-systems}"
RM_ARC_RELEASE="${RM_ARC_RELEASE:-arc}"
RM_ARC_CHART="oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller"

rm::cluster::_helm_flags() {
  local flags=()
  [[ "${RM_DRY_RUN:-0}" == "1" ]] && flags+=(--dry-run)
  printf '%s\n' "${flags[@]+"${flags[@]}"}"
}

rm::cluster::install() {
  local values_file="${RM_ROOT}/charts/values/controller.values.yaml"
  local chart_version="${1:-}"

  rm::preflight::require_bin helm "https://helm.sh/docs/intro/install/" \
    || rm::die "helm is required for cluster:install"
  rm::preflight::check_cluster_reachable \
    || rm::die "no reachable cluster — set a kubectl context first"

  rm::log "Installing Actions Runner Controller into namespace '${RM_ARC_NAMESPACE}'..."

  local -a cmd=(helm upgrade --install "${RM_ARC_RELEASE}" "${RM_ARC_CHART}"
    --namespace "${RM_ARC_NAMESPACE}" --create-namespace
    --wait --timeout 5m)
  [[ -f "${values_file}" ]] && cmd+=(-f "${values_file}")
  [[ -n "${chart_version}" ]] && cmd+=(--version "${chart_version}")

  local extra_flags
  mapfile -t extra_flags < <(rm::cluster::_helm_flags)
  [[ ${#extra_flags[@]} -gt 0 ]] && cmd+=("${extra_flags[@]}")

  rm::info "${cmd[*]}"
  "${cmd[@]}"

  if [[ "${RM_DRY_RUN:-0}" != "1" ]]; then
    rm::ok "Controller installed. Verifying rollout..."
    kubectl -n "${RM_ARC_NAMESPACE}" rollout status deployment \
      -l app.kubernetes.io/name=gha-runner-scale-set-controller --timeout=120s \
      || rm::warn "could not confirm controller rollout — check 'kubectl -n ${RM_ARC_NAMESPACE} get pods'"
  fi
}

rm::cluster::uninstall() {
  # Release names are just the repo slug (e.g. "octocat-hello-world"), not
  # namespace-prefixed, so filter by namespace via JSON rather than by
  # release name — matches both shared ("arc-runners") and per-repo
  # ("arc-runners-<slug>") namespace modes.
  local remaining
  remaining="$(helm list --all-namespaces -o json 2>/dev/null \
    | jq -r '.[] | select(.namespace | test("^arc-runners")) | "\(.namespace)/\(.name)"')"
  if [[ -n "${remaining}" && "${RM_YES:-0}" != "1" ]]; then
    rm::warn "The following repo scale-sets still exist and will be orphaned:"
    printf '  - %s\n' "${remaining}" >&2
    rm::confirm "Uninstall the controller anyway?" || rm::die "aborted"
  fi
  rm::log "Uninstalling Actions Runner Controller..."
  helm uninstall "${RM_ARC_RELEASE}" --namespace "${RM_ARC_NAMESPACE}" \
    || rm::die "helm uninstall failed"
  rm::ok "Controller removed. Namespace '${RM_ARC_NAMESPACE}' left in place (delete manually if desired)."
}
