#!/usr/bin/env bash
# Logging helpers shared by all runner-mesh subcommands.
# Intended to be sourced, not executed.

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RM_C_RESET=$'\033[0m'
  RM_C_DIM=$'\033[2m'
  RM_C_RED=$'\033[31m'
  RM_C_GREEN=$'\033[32m'
  RM_C_YELLOW=$'\033[33m'
  RM_C_BLUE=$'\033[34m'
else
  RM_C_RESET=""; RM_C_DIM=""; RM_C_RED=""; RM_C_GREEN=""; RM_C_YELLOW=""; RM_C_BLUE=""
fi

rm::log()   { printf '%s\n' "${RM_C_BLUE}»${RM_C_RESET} $*" >&2; }
rm::info()  { printf '%s\n' "${RM_C_DIM}  $*${RM_C_RESET}" >&2; }
rm::ok()    { printf '%s\n' "${RM_C_GREEN}✓${RM_C_RESET} $*" >&2; }
rm::warn()  { printf '%s\n' "${RM_C_YELLOW}⚠${RM_C_RESET} $*" >&2; }
rm::die()   { printf '%s\n' "${RM_C_RED}✗${RM_C_RESET} $*" >&2; exit 1; }

# rm::mktemp_suffixed <prefix> <suffix> -> prints a fresh temp file path
# ending in <suffix> (e.g. rm::mktemp_suffixed runner-mesh-manifest .html).
# BSD mktemp (macOS) only substitutes a trailing run of X's — it silently
# refuses to substitute 'XXXXXX' followed by a literal suffix like '.html'
# in either 'mktemp -t' or full-path-template form, unlike GNU mktemp. The
# portable fix is to mktemp with no suffix, then rename (same filesystem,
# so permissions and atomicity are preserved).
rm::mktemp_suffixed() {
  local prefix="$1" suffix="$2" base
  base="$(mktemp "${TMPDIR:-/tmp}/${prefix}.XXXXXX")"
  mv "${base}" "${base}${suffix}"
  printf '%s\n' "${base}${suffix}"
}

# rm::confirm "question" -> 0 if yes, 1 if no. Honors RM_YES=1 for non-interactive runs.
rm::confirm() {
  local prompt="$1"
  if [[ "${RM_YES:-0}" == "1" ]]; then
    return 0
  fi
  local reply
  read -r -p "${prompt} [y/N] " reply
  [[ "${reply}" =~ ^[Yy]$ ]]
}
