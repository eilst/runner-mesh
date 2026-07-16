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
  local namespaces
  namespaces="$(kubectl get namespace -o name 2>/dev/null | sed -n 's#^namespace/\(arc-runners-.*\)#\1#p')"

  if [[ -z "${namespaces}" ]]; then
    rm::info "none provisioned yet — run 'runner-mesh repos:add'"
    return
  fi

  local ns
  while IFS= read -r ns; do
    [[ -z "${ns}" ]] && continue
    # Unlike the controller's Deployment label (verified via 'helm
    # template'), listener and runner pods are created dynamically by the
    # controller at runtime, not from this chart's static templates —
    # there's no offline way to verify these label selectors against chart
    # source. Treated as best-effort observability: kubectl returns exit 0
    # with empty output for a selector that matches nothing, so a wrong
    # label degrades to "unknown"/0 here rather than failing the command.
    local listener_status active_runners
    listener_status="$(kubectl -n "${ns}" get pods \
      -l 'app.kubernetes.io/component=runner-scale-set-listener' \
      -o jsonpath='{.items[0].status.phase}' 2>/dev/null)"
    active_runners="$(kubectl -n "${ns}" get pods \
      -l 'app.kubernetes.io/component=runner' \
      --no-headers 2>/dev/null | wc -l | tr -d ' ')"

    printf '  %-30s listener=%-10s active_runners=%s\n' \
      "${ns#arc-runners-}" "${listener_status:-unknown}" "${active_runners:-0}"
  done <<<"${namespaces}"
}

rm::status::run() {
  rm::preflight::check_cluster_reachable || rm::die "no reachable cluster"
  rm::status::_controller
  rm::status::_repos
}
