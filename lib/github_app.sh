#!/usr/bin/env bash
# GitHub App lifecycle: create the App via the Manifest flow (one browser
# confirmation click, everything else scripted), and mint short-lived
# installation tokens for API calls used by lib/repos.sh.
# Intended to be sourced, not executed.

RM_CONFIG_DIR="${RM_CONFIG_DIR:-${HOME}/.config/runner-mesh}"
RM_APP_CONFIG="${RM_CONFIG_DIR}/github-app.json"
RM_APP_CALLBACK_PORT="${RM_APP_CALLBACK_PORT:-8934}"

rm::github_app::require_config() {
  [[ -f "${RM_APP_CONFIG}" ]] \
    || rm::die "no GitHub App configured yet — run 'runner-mesh app:init' first"
}

rm::github_app::_manifest_json() {
  local app_name="$1" redirect_url="$2"
  jq -n --arg name "${app_name}" --arg url "${redirect_url}" '{
    name: $name,
    url: "https://github.com/",
    redirect_url: $url,
    public: false,
    default_permissions: {
      actions: "write",
      administration: "write",
      checks: "read",
      metadata: "read"
    },
    default_events: []
  }'
}

# Minimal, dependency-free local HTTP server: waits for one GET request
# containing ?code=..., writes the code to $1, then exits. No third-party
# packages — just python3's stdlib, which preflight already requires.
rm::github_app::_await_callback() {
  local out_file="$1"
  python3 - "${RM_APP_CALLBACK_PORT}" "${out_file}" <<'PYEOF'
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

port = int(sys.argv[1])
out_file = sys.argv[2]

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        qs = urllib.parse.urlparse(self.path).query
        params = urllib.parse.parse_qs(qs)
        code = params.get("code", [""])[0]
        with open(out_file, "w") as f:
            f.write(code)
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(
            b"<html><body><h3>runner-mesh: GitHub App created.</h3>"
            b"You can close this tab and return to your terminal.</body></html>"
        )

HTTPServer(("127.0.0.1", port), Handler).handle_request()
PYEOF
}

rm::github_app::_open_browser() {
  local url="$1"
  if command -v open >/dev/null 2>&1; then
    open "${url}"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "${url}"
  else
    rm::warn "could not detect a browser opener — open this URL manually:"
    printf '  %s\n' "${url}" >&2
  fi
}

rm::github_app::init() {
  local app_name="${1:-runner-mesh-$(whoami)}"
  mkdir -p "${RM_CONFIG_DIR}"
  chmod 700 "${RM_CONFIG_DIR}"

  if [[ -f "${RM_APP_CONFIG}" && "${RM_YES:-0}" != "1" ]]; then
    rm::confirm "A GitHub App is already configured (${RM_APP_CONFIG}). Create a new one?" \
      || { rm::info "keeping existing App config"; return 0; }
  fi

  local redirect_url="http://127.0.0.1:${RM_APP_CALLBACK_PORT}/callback"
  local manifest form_file code_file code

  manifest="$(rm::github_app::_manifest_json "${app_name}" "${redirect_url}")"

  form_file="$(mktemp -t runner-mesh-manifest.XXXXXX.html)"
  cat > "${form_file}" <<HTMLEOF
<html><body onload="document.forms[0].submit()">
<form action="https://github.com/settings/apps/new" method="post">
  <input type="hidden" name="manifest" value='$(printf '%s' "${manifest}" | sed "s/'/&apos;/g")'>
</form>
<p>Redirecting to GitHub to confirm App creation...</p>
</body></html>
HTMLEOF

  rm::log "Opening your browser to confirm GitHub App creation..."
  rm::info "review the App's permissions on GitHub, then click 'Create GitHub App'"
  rm::github_app::_open_browser "file://${form_file}"

  code_file="$(mktemp -t runner-mesh-code.XXXXXX)"
  rm::info "waiting for GitHub to redirect back to ${redirect_url} ..."
  rm::github_app::_await_callback "${code_file}"
  code="$(cat "${code_file}")"
  rm -f "${form_file}" "${code_file}"

  [[ -n "${code}" ]] || rm::die "did not receive a manifest code from GitHub — try again"

  rm::log "Exchanging manifest code for App credentials..."
  local response
  response="$(curl -fsSL -X POST "https://api.github.com/app-manifests/${code}/conversions" \
    -H "Accept: application/vnd.github+json")" \
    || rm::die "failed to exchange manifest code — it may have expired (single use, short-lived)"

  jq -e '.id and .pem' <<<"${response}" >/dev/null \
    || rm::die "unexpected response from GitHub during App creation"

  jq '{
    app_id: .id,
    slug: .slug,
    name: .name,
    client_id: .client_id,
    html_url: .html_url,
    private_key: .pem
  }' <<<"${response}" > "${RM_APP_CONFIG}"
  chmod 600 "${RM_APP_CONFIG}"

  local slug html_url
  slug="$(jq -r .slug "${RM_APP_CONFIG}")"
  html_url="$(jq -r .html_url "${RM_APP_CONFIG}")"

  rm::ok "GitHub App '${slug}' created and credentials saved to ${RM_APP_CONFIG} (0600, never committed)"
  rm::log "Next: install the App on the repos you want runners for, then run 'runner-mesh repos:add'."
  rm::info "install URL: ${html_url}/installations/new"
}

# --- Installation-token minting, used by lib/repos.sh -----------------------

rm::github_app::_b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

rm::github_app::_jwt() {
  rm::github_app::require_config
  local app_id key_file header payload signing_input signature
  app_id="$(jq -r .app_id "${RM_APP_CONFIG}")"
  key_file="$(mktemp -t runner-mesh-key.XXXXXX.pem)"
  jq -r .private_key "${RM_APP_CONFIG}" > "${key_file}"
  trap 'rm -f "${key_file}"' RETURN

  local now iat exp
  now="$(date +%s)"
  iat=$((now - 60))
  exp=$((now + 540)) # 9 minutes; GitHub caps JWTs at 10

  header='{"alg":"RS256","typ":"JWT"}'
  payload="$(jq -nc --argjson iat "${iat}" --argjson exp "${exp}" --arg iss "${app_id}" \
    '{iat:$iat, exp:$exp, iss:$iss}')"

  signing_input="$(printf '%s' "${header}" | rm::github_app::_b64url).$(printf '%s' "${payload}" | rm::github_app::_b64url)"
  signature="$(printf '%s' "${signing_input}" | openssl dgst -sha256 -sign "${key_file}" | rm::github_app::_b64url)"

  printf '%s.%s\n' "${signing_input}" "${signature}"
}

# rm::github_app::installations — list installations of this App (id + account login).
rm::github_app::installations() {
  local jwt
  jwt="$(rm::github_app::_jwt)"
  curl -fsSL "https://api.github.com/app/installations" \
    -H "Authorization: Bearer ${jwt}" \
    -H "Accept: application/vnd.github+json" \
    || rm::die "failed to list App installations"
}

# rm::github_app::installation_token <installation_id> — mint a ~1h scoped token.
rm::github_app::installation_token() {
  local installation_id="$1" jwt
  jwt="$(rm::github_app::_jwt)"
  curl -fsSL -X POST "https://api.github.com/app/installations/${installation_id}/access_tokens" \
    -H "Authorization: Bearer ${jwt}" \
    -H "Accept: application/vnd.github+json" \
    | jq -r .token
}
