#!/usr/bin/env bash
# status — human-readable health of the controller and every repo's runner
# pool: is the controller up, is each repo's listener connected, how many
# ephemeral runner pods are active right now.
# Intended to be sourced, not executed.

rm::status::_controller() {
  rm::log "Controller (namespace: ${RM_ARC_NAMESPACE:-arc-systems})"
  local ns="${RM_ARC_NAMESPACE:-arc-systems}"
  if ! kubectl get namespace "${ns}" >/dev/null 2>&1; then
    rm::warn "not installed — run 'runner-mesh cluster:install'"
    return
  fi
  # Label verified via 'helm template' against the actual chart output —
  # it's 'gha-rs-controller', not the full chart name.
  local line ready total
  line="$(kubectl -n "${ns}" get deployment \
    -l app.kubernetes.io/name=gha-rs-controller \
    -o jsonpath='{range .items[*]}{.status.readyReplicas}{" "}{.status.replicas}{"\n"}{end}' 2>/dev/null \
    | head -1)"
  # 'read' returns non-zero on a line with no trailing newline (true here
  # whenever kubectl finds zero matching deployments — empty output has no
  # newline at all), which would otherwise kill the script under 'set -e';
  # guard it explicitly rather than relying on read's own exit status.
  if [[ -n "${line}" ]]; then
    read -r ready total <<<"${line}"
  fi
  if [[ "${ready:-0}" -ge 1 && "${ready:-0}" == "${total:-0}" ]]; then
    rm::ok "controller healthy (${ready}/${total} replicas ready)"
  else
    rm::warn "controller not fully ready (${ready:-0}/${total:-0} replicas)"
  fi
}

rm::status::_repos() {
  rm::log "Repo runner pools"
  local arc_ns="${RM_ARC_NAMESPACE:-arc-systems}"

  # A scale-set's namespace can be the shared "arc-runners" (exact match,
  # RM_NAMESPACE_MODE=shared) or "arc-runners-<slug>" (per-repo mode) — so
  # this needs both an exact match and a prefix match, not just a prefix.
  # Enumerate by Helm release rather than by namespace: in shared mode,
  # multiple repos' releases live in the one "arc-runners" namespace, so
  # a repo is a (namespace, release) pair, not just a namespace.
  local releases
  releases="$(helm list --all-namespaces -o json 2>/dev/null \
    | jq -r '.[] | select(.namespace == "arc-runners" or (.namespace | startswith("arc-runners-"))) | "\(.namespace)\t\(.name)"')"

  if [[ -z "${releases}" ]]; then
    rm::info "none provisioned yet — run 'runner-mesh repos:add'"
    return
  fi

  local ns release
  while IFS=$'\t' read -r ns release; do
    [[ -z "${ns}" ]] && continue
    # The listener pod always lives in the CONTROLLER's namespace
    # (verified by running this for real against a live repository) — not
    # the repo's own namespace, regardless of RM_NAMESPACE_MODE. It's
    # precisely selectable by the scale-set's namespace+name labels, also
    # verified against a real listener pod's labels.
    local listener_status active_runners
    listener_status="$(kubectl -n "${arc_ns}" get pods \
      -l "actions.github.com/scale-set-namespace=${ns},actions.github.com/scale-set-name=${release}" \
      -o jsonpath='{.items[0].status.phase}' 2>/dev/null)"
    # Runner pods, unlike the listener, do live in the repo's own
    # namespace (verified via the EphemeralRunnerSet's namespace) — but
    # this specific label is still an unverified guess (no job has run
    # during testing to confirm it), so it stays best-effort: kubectl
    # exits 0 with empty output for a selector matching nothing, so a
    # wrong label degrades to 0 here rather than failing the command.
    active_runners="$(kubectl -n "${ns}" get pods \
      -l 'app.kubernetes.io/component=runner' \
      --no-headers 2>/dev/null | wc -l | tr -d ' ')"

    printf '  %-30s listener=%-10s active_runners=%s\n' \
      "${release}" "${listener_status:-unknown}" "${active_runners:-0}"
  done <<<"${releases}"
}

rm::status::run() {
  rm::preflight::check_cluster_reachable || rm::die "no reachable cluster"
  rm::status::_controller
  rm::status::_repos
}
