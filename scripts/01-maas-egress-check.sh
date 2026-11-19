#!/usr/bin/env bash
# Phase 0 - verify that a pod inside the cluster can reach the corporate MaaS endpoint.
# The API key is passed through a short-lived Secret (never on the command line / in logs).
#
# Usage: scripts/01-maas-egress-check.sh [base-url] [api-key-var-name]
#   default: MAAS_INTERNAL_URL / MAAS_INTERNAL_API_KEY from .env
source "$(dirname "$0")/lib.sh"
require_cmd oc

BASE_URL="${1:-${MAAS_INTERNAL_URL:-}}"
KEY_VAR="${2:-MAAS_INTERNAL_API_KEY}"
[[ -n "${BASE_URL}" ]] || die "Base URL not provided (MAAS_INTERNAL_URL)"
require_env "${KEY_VAR}"

NS="poc-preflight"
oc get ns "${NS}" >/dev/null 2>&1 || oc create ns "${NS}" >/dev/null
trap 'oc delete ns "${NS}" --wait=false >/dev/null 2>&1 || true' EXIT

oc -n "${NS}" create secret generic maas-key --from-literal=API_KEY="${!KEY_VAR}" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null

info "Calling ${BASE_URL}/models from inside the cluster"
oc -n "${NS}" run egress-check --rm -i --restart=Never --quiet \
  --image=registry.access.redhat.com/ubi9/ubi-minimal:latest \
  --overrides="$(cat <<EOF
{
  "spec": {
    "containers": [{
      "name": "egress-check",
      "image": "registry.access.redhat.com/ubi9/ubi-minimal:latest",
      "command": ["sh", "-c", "curl -sS -m 20 -o /tmp/out -w '%{http_code}' -H \"Authorization: Bearer \$API_KEY\" '${BASE_URL}/models'; echo; head -c 2000 /tmp/out; echo"],
      "envFrom": [{"secretRef": {"name": "maas-key"}}],
      "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}, "runAsNonRoot": true, "seccompProfile": {"type": "RuntimeDefault"}}
    }]
  }
}
EOF
)" | tee /dev/stderr | head -1 | grep -q '^200' && ok "MaaS reachable from the cluster" || die "MaaS NOT reachable from the cluster - fix networking before continuing"
