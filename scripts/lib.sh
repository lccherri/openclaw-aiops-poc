#!/usr/bin/env bash
# Shared helpers for the POC scripts. Source it: `source "$(dirname "$0")/lib.sh"`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

# Load .env when present (values are never printed).
if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env"
  set +a
fi

c_reset=$'\e[0m'; c_green=$'\e[32m'; c_red=$'\e[31m'; c_yellow=$'\e[33m'; c_blue=$'\e[34m'

info()  { echo "${c_blue}[INFO]${c_reset} $*"; }
ok()    { echo "${c_green}[ OK ]${c_reset} $*"; }
warn()  { echo "${c_yellow}[WARN]${c_reset} $*"; }
fail()  { echo "${c_red}[FAIL]${c_reset} $*"; }
die()   { fail "$*"; exit 1; }

# require_env VAR [VAR...] -> exits if any variable is empty
require_env() {
  local missing=0
  for v in "$@"; do
    if [[ -z "${!v:-}" ]]; then fail "Environment variable ${v} is not set (see .env.example)"; missing=1; fi
  done
  [[ ${missing} -eq 0 ]] || exit 1
}

require_cmd() {
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "Command not found: $c"; done
}

# wait_for_csv <namespace> <csv-name-prefix> [timeout-seconds]
wait_for_csv() {
  local ns="$1" prefix="$2" timeout="${3:-900}" elapsed=0 phase=""
  info "Waiting for CSV ${prefix}* in ${ns} (timeout ${timeout}s)"
  while (( elapsed < timeout )); do
    phase="$(oc get csv -n "${ns}" -o jsonpath="{range .items[?(@.metadata.name)]}{.metadata.name}{' '}{.status.phase}{'\n'}{end}" 2>/dev/null \
      | awk -v p="${prefix}" 'index($1,p)==1 {print $2}' | head -1)"
    [[ "${phase}" == "Succeeded" ]] && { ok "CSV ${prefix} Succeeded"; return 0; }
    sleep 15; elapsed=$((elapsed + 15))
  done
  die "CSV ${prefix} not ready in ${ns} (last phase: ${phase:-none})"
}

# wait_for_condition <kind/name> <namespace|""> <jsonpath> <expected> [timeout]
wait_for_jsonpath() {
  local res="$1" ns="$2" path="$3" expected="$4" timeout="${5:-900}" elapsed=0 val=""
  local nsarg=(); [[ -n "${ns}" ]] && nsarg=(-n "${ns}")
  info "Waiting for ${res} ${path} == ${expected}"
  while (( elapsed < timeout )); do
    val="$(oc get "${res}" "${nsarg[@]}" -o jsonpath="${path}" 2>/dev/null || true)"
    [[ "${val}" == "${expected}" ]] && { ok "${res} ready"; return 0; }
    sleep 15; elapsed=$((elapsed + 15))
  done
  die "${res} not ready (last value: ${val:-none})"
}
