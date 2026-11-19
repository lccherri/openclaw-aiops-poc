#!/usr/bin/env bash
# Creates/updates every Secret of the POC from .env. Idempotent. Values are never printed.
#   poc-vault/openclaw-agent-credentials   source of truth for the agent (synced by ESO)
#   aiops-models|aiops-governance/upstream-maas-credentials   upstream MaaS key (never in the agent ns)
#   demo-apps/alertmanager-openclaw-hook   bearer token used by Alertmanager -> OpenClaw
source "$(dirname "$0")/lib.sh"
require_cmd oc

apply_secret() {  # apply_secret <ns> <name> <k=v>...
  local ns="$1" name="$2"; shift 2
  local args=(); for kv in "$@"; do args+=(--from-literal="${kv}"); done
  oc -n "${ns}" create secret generic "${name}" "${args[@]}" --dry-run=client -o yaml | oc apply -f - >/dev/null
  ok "Secret ${ns}/${name}"
}
ns_exists() { oc get ns "$1" >/dev/null 2>&1; }

# 1. Vault namespace: nobody but cluster admins and the ESO reader can read it
if ! ns_exists poc-vault; then
  oc create ns poc-vault >/dev/null
  oc label ns poc-vault poc.aiops/purpose=credential-vault >/dev/null
fi
apply_secret poc-vault openclaw-agent-credentials \
  "AGENT_MAAS_KEY=${AGENT_MAAS_KEY:-unset}" \
  "OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN:?set OPENCLAW_GATEWAY_TOKEN in .env}" \
  "OPENCLAW_HOOKS_TOKEN=${OPENCLAW_HOOKS_TOKEN:?set OPENCLAW_HOOKS_TOKEN in .env}" \
  "AAP_MCP_TOKEN=${AAP_MCP_TOKEN:-unset}" \
  "MLFLOW_TOKEN=${MLFLOW_TOKEN:-unset}"

# 2. Upstream model credential (used by MaaS / guardrails / EvalHub only)
for ns in aiops-models aiops-governance; do
  if ns_exists "${ns}"; then
    apply_secret "${ns}" upstream-maas-credentials "api-key=${MAAS_INTERNAL_API_KEY:?set MAAS_INTERNAL_API_KEY}"
    # lets the MaaS payload processor (IPP) read the upstream key
    oc -n "${ns}" label secret upstream-maas-credentials inference.llm-d.ai/ipp-managed=true --overwrite >/dev/null
  else
    warn "Namespace ${ns} not found yet - rerun after Phase 2"
  fi
done

# Guardrails (standalone, outside the agent path - test-log F-09) calls MaaS as a separate
# consumer, so its traffic never counts against the agent quota.
if ns_exists aiops-governance && [[ -n "${OTHER_CONSUMER_MAAS_KEY:-}" ]]; then
  apply_secret aiops-governance guardrails-maas-credentials "api-key=${OTHER_CONSUMER_MAAS_KEY}"
fi

# 3. Alertmanager -> OpenClaw webhook token
if ns_exists demo-apps; then
  apply_secret demo-apps alertmanager-openclaw-hook "token=${OPENCLAW_HOOKS_TOKEN}"
else
  warn "Namespace demo-apps not found yet - rerun after deploying the demo apps"
fi

# Force ESO to resync now if the ExternalSecret exists
if oc get externalsecret openclaw-credentials -n openclaw >/dev/null 2>&1; then
  oc annotate externalsecret openclaw-credentials -n openclaw force-sync="$(date +%s)" --overwrite >/dev/null
  ok "ExternalSecret openclaw/openclaw-credentials resync requested"
fi
