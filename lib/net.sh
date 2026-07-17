#!/usr/bin/env bash
# net:init / net:key — the Tailscale layer, with the same UX contract as
# app:init: exactly one guided browser session ever (account + OAuth
# client), then every auth key mints from the terminal via the API, and
# node:* commands mint their own keys with no flags at all.
# Intended to be sourced, not executed.

RM_TS_CONFIG="${RM_TS_CONFIG:-${RM_CONFIG_DIR}/tailscale.json}"
RM_TS_TAG="${RM_TS_TAG:-tag:runner-mesh-node}"
# k3s's default cluster CIDR — pod subnets each node advertises over
# Tailscale. Override if your cluster uses a custom --cluster-cidr.
RM_K3S_POD_CIDR="${RM_K3S_POD_CIDR:-10.42.0.0/16}"
RM_TS_API="https://api.tailscale.com/api/v2"

rm::net::require_config() {
  [[ -f "${RM_TS_CONFIG}" ]] \
    || rm::die "no Tailscale OAuth client configured — run 'runner-mesh net:init' first"
}

# One guided setup: account -> tag ACL -> OAuth client. Each step opens
# the right page and waits; nothing is scraped or automated behind the
# user's back — the two console actions are ones Tailscale requires a
# human to perform.
rm::net::init() {
  if [[ -f "${RM_TS_CONFIG}" && "${RM_YES:-0}" != "1" ]]; then
    rm::confirm "A Tailscale OAuth client is already configured. Replace it?" \
      || { rm::info "keeping existing config"; return 0; }
  fi

  rm::log "Step 1/3 — Tailscale account (create one or sign in)"
  rm::github_app::_open_browser "https://login.tailscale.com/start"
  read -r -p "  ...press Enter once you're signed in: " _

  rm::log "Step 2/3 — allow the runner-mesh device tag + pod routes"
  rm::info "in the ACL editor that just opened, add this inside \"tagOwners\":"
  printf '\n    "%s": ["autogroup:admin"],\n\n' "${RM_TS_TAG}" >&2
  rm::info "and this top-level block (k3s advertises each node's pod CIDR as a"
  rm::info "subnet route; without auto-approval, cross-node pod traffic — e.g."
  rm::info "DNS lookups from agent-node pods to CoreDNS — silently fails):"
  printf '\n    "autoApprovers": {\n      "routes": {\n        "%s": ["%s"],\n      },\n    },\n\n' \
    "${RM_K3S_POD_CIDR}" "${RM_TS_TAG}" >&2
  rm::github_app::_open_browser "https://login.tailscale.com/admin/acls/file"
  read -r -p "  ...press Enter once saved: " _

  rm::log "Step 3/3 — create an OAuth client"
  rm::info "on the page that just opened: Generate OAuth client →"
  rm::info "scope 'Keys → Auth Keys: Write', tag '${RM_TS_TAG}' → Generate"
  rm::github_app::_open_browser "https://login.tailscale.com/admin/settings/oauth"
  local client_id client_secret
  read -r -p "  Client ID: " client_id
  read -r -s -p "  Client secret (hidden): " client_secret
  printf '\n' >&2
  [[ -n "${client_id}" && -n "${client_secret}" ]] || rm::die "both values are required"

  mkdir -p "$(dirname "${RM_TS_CONFIG}")"
  jq -n --arg id "${client_id}" --arg secret "${client_secret}" --arg tag "${RM_TS_TAG}" \
    '{client_id: $id, client_secret: $secret, tag: $tag}' > "${RM_TS_CONFIG}"
  chmod 600 "${RM_TS_CONFIG}"

  rm::log "Validating (minting a throwaway token)..."
  rm::net::_token >/dev/null || { rm -f "${RM_TS_CONFIG}"; rm::die "OAuth credentials rejected by Tailscale — re-run net:init"; }
  rm::ok "Tailscale configured. node:init/join/auto now mint auth keys automatically."
  rm::info "tip: 'runner-mesh fleet:seal <fleet-dir>' also seals this credential for other operator machines"
}

rm::net::_token() {
  rm::net::require_config
  local id secret
  id="$(jq -r .client_id "${RM_TS_CONFIG}")"
  secret="$(jq -r .client_secret "${RM_TS_CONFIG}")"
  curl -fsS "${RM_TS_API}/oauth/token" \
    -d "client_id=${id}" -d "client_secret=${secret}" \
    | jq -re .access_token
}

# rm::net::key [--expiry SECONDS] [--reusable] — mint a tagged,
# pre-authorized auth key and print it (stdout only, script-friendly).
# Defaults: single-use, 1 hour — a key should live about as long as the
# join it exists for. (Args arrive via the CLI dispatcher, invisible to
# the linter across files.)
# shellcheck disable=SC2120
rm::net::key() {
  local expiry=3600 reusable=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --expiry)   expiry="$2"; shift 2 ;;
      --reusable) reusable=true; shift ;;
      *) rm::die "unknown flag: $1" ;;
    esac
  done
  local token tag body
  token="$(rm::net::_token)" || rm::die "could not obtain a Tailscale API token"
  tag="$(jq -r .tag "${RM_TS_CONFIG}")"
  body="$(jq -n --argjson reusable "${reusable}" --argjson expiry "${expiry}" --arg tag "${tag}" \
    '{capabilities: {devices: {create: {reusable: $reusable, ephemeral: false,
      preauthorized: true, tags: [$tag]}}}, expirySeconds: $expiry,
      description: "runner-mesh node join"}')"
  curl -fsS -X POST "${RM_TS_API}/tailnet/-/keys" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${body}" \
    | jq -re .key \
    || rm::die "key mint failed — is '${tag}' present in your ACL tagOwners?"
}

# rm::net::_device_id <hostname> — look up a tailnet device's stable ID by
# its (short) hostname, via the API. Empty output + non-zero if not found.
rm::net::_device_id() {
  local hostname="$1" token
  token="$(rm::net::_token)" || return 1
  curl -fsS "${RM_TS_API}/tailnet/-/devices" \
    -H "Authorization: Bearer ${token}" \
    | jq -re --arg h "${hostname}" \
      '.devices[] | select((.hostname == $h) or (.name | startswith($h + "."))) | .id' \
    | head -1
}

# rm::net::reassign_ip <hostname> <ipv4> — move a tailnet device's 100.x
# address to <ipv4> (the "Edit machine IP" action, via API). This is what
# lets a promoted node take over a dead server's IP without the console —
# so agents pointed at the old server_ip reconnect with no reconfig.
# Requires an OAuth client (net:init). Prints nothing on success.
rm::net::reassign_ip() {
  local hostname="$1" ipv4="$2" token id
  [[ -n "${hostname}" && -n "${ipv4}" ]] \
    || rm::die "usage: rm::net::reassign_ip <device-hostname> <ipv4>"
  rm::net::require_config
  id="$(rm::net::_device_id "${hostname}")" \
    || rm::die "no tailnet device found for hostname '${hostname}'"
  token="$(rm::net::_token)" || rm::die "could not obtain a Tailscale API token"
  curl -fsS -X POST "${RM_TS_API}/device/${id}/ip" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg ip "${ipv4}" '{ipv4: $ip}')" >/dev/null \
    || rm::die "failed to reassign ${ipv4} to '${hostname}' (is the old holder removed?)"
  rm::ok "reassigned ${ipv4} to '${hostname}'"
}

# net:ip — CLI surface for reassign_ip, so the watchdog (and operators) can
# take over a control-plane IP hands-off.
rm::net::ip() {
  local hostname="" ipv4=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --hostname) hostname="$2"; shift 2 ;;
      --ip)       ipv4="$2"; shift 2 ;;
      *) rm::die "unknown flag: $1" ;;
    esac
  done
  rm::net::reassign_ip "${hostname}" "${ipv4}"
}

# Used by node:* — resolve an auth key: explicit flag wins; otherwise mint
# one if an OAuth client is configured; otherwise fail with both paths.
rm::net::resolve_authkey() {
  local provided="$1"
  if [[ -n "${provided}" ]]; then
    printf '%s\n' "${provided}"
    return 0
  fi
  if [[ -f "${RM_TS_CONFIG}" ]]; then
    rm::log "minting a Tailscale auth key (single-use, 1h)..."
    # shellcheck disable=SC2119
    rm::net::key
    return 0
  fi
  rm::die "no --authkey given and no OAuth client configured — run 'runner-mesh net:init' once, or pass --authkey from https://login.tailscale.com/admin/settings/keys"
}
