#!/usr/bin/env bash
# Mints one MaaS API key per consumer identity (ServiceAccount) and stores them in .env.
#   AGENT_MAAS_KEY           <- SA aiops-models/maas-agent-openclaw, subscription openclaw-agent
#   OTHER_CONSUMER_MAAS_KEY  <- SA aiops-models/maas-other-consumer, subscription other-consumer
# Also sets RHOAI_MAAS_URL (external Route, for workstation tests) and
# RHOAI_MAAS_INTERNAL_URL (in-cluster Service, used by the agent). Keys are never printed.
# Usage: scripts/maas-mint-keys.sh [--force]
source "$(dirname "$0")/lib.sh"
require_cmd oc curl python3
ENV_FILE="${REPO_ROOT}/.env"
MODEL_PATH="aiops-models/aiops-model"

host=$(oc get route maas-default-gateway -n openshift-ingress -o jsonpath='{.spec.host}')
[[ -n "${host}" ]] || die "Route openshift-ingress/maas-default-gateway not found"
internal="maas-default-gateway-data-science-gateway-class.openshift-ingress.svc.cluster.local"

set_env() {  # set_env VAR value  (replace or append in .env)
  python3 - "${ENV_FILE}" "$1" "$2" <<'PY'
import re, sys
path, var, val = sys.argv[1:]
s = open(path).read()
line = f'{var}="{val}"'
s, n = re.subn(rf'^{var}=.*$', lambda m: line, s, flags=re.M)
if n == 0:
    s += ("" if s.endswith("\n") else "\n") + line + "\n"
open(path, "w").write(s)
PY
}

mint() {  # mint <sa> <subscription> <env var>
  local sa="$1" sub="$2" var="$3"
  if [[ -n "${!var:-}" && "${FORCE:-}" != 1 ]]; then warn "${var} already set (use --force to re-mint)"; return; fi
  local tok resp key
  tok=$(oc create token "${sa}" -n aiops-models --duration=10m)
  resp=$(curl -sk -X POST "https://${host}/maas-api/v1/api-keys" \
    -H "Authorization: Bearer ${tok}" -H 'Content-Type: application/json' \
    -d "{\"name\":\"${sub}-$(date +%Y%m%d%H%M)\",\"subscription\":\"${sub}\"}")
  key=$(python3 -c 'import json,sys
try: print(json.loads(sys.stdin.read()).get("key",""))
except Exception: print("")' <<<"${resp}")
  [[ -n "${key}" ]] || die "Could not mint key for ${sa}: $(head -c 300 <<<"${resp}")"
  set_env "${var}" "${key}"
  ok "${var} minted for ${sa} (subscription ${sub})"
}

[[ "${1:-}" == "--force" ]] && FORCE=1
mint maas-agent-openclaw openclaw-agent AGENT_MAAS_KEY
mint maas-other-consumer other-consumer OTHER_CONSUMER_MAAS_KEY
set_env RHOAI_MAAS_URL "https://${host}/${MODEL_PATH}/v1"
set_env RHOAI_MAAS_INTERNAL_URL "https://${internal}/${MODEL_PATH}/v1"
ok "RHOAI_MAAS_URL and RHOAI_MAAS_INTERNAL_URL set in .env"
