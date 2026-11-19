#!/usr/bin/env bash
# Optional Slack channel for OpenClaw (manifests/phase3-agent/slack/README.md).
#   scripts/slack.sh enable    tokens -> vault/ESO, egress to Slack only, plugin, channel config
#   scripts/slack.sh disable   back to the default POC (no channel, no external egress)
#   scripts/slack.sh status
# Needs in .env: SLACK_BOT_TOKEN, SLACK_APP_TOKEN, SLACK_CHANNEL_ID, SLACK_OPERATOR_IDS.
source "$(dirname "$0")/lib.sh"
require_cmd oc python3
NS=openclaw
DIR="${REPO_ROOT}/manifests/phase3-agent/slack"
PLUGIN_SPEC="${SLACK_PLUGIN_SPEC:-@openclaw/slack@2026.9.8}"   # same version as the gateway
oc_claw() { oc -n "${NS}" exec -i deploy/openclaw -c gateway -- node /app/dist/index.js "$@"; }
# OVN accepts an EgressFirewall it cannot program (e.g. unsupported wildcard) and then applies
# NONE of its rules: with the external-HTTPS NetworkPolicy that means open Internet. Fail loudly.
apply_firewall() {
  oc apply -f "$1"
  local st=""; for _ in $(seq 1 30); do
    st=$(oc -n "${NS}" get egressfirewall default -o jsonpath='{.status.status}' 2>/dev/null)
    [[ "${st}" == *"Rules applied"* ]] && { ok "EgressFirewall: ${st}"; return 0; }
    [[ "${st}" == *"not correctly"* ]] && break; sleep 2
  done
  oc -n "${NS}" delete networkpolicy allow-egress-external-https --ignore-not-found
  die "EgressFirewall not applied (${st}); external-HTTPS NetworkPolicy removed to keep the namespace closed"
}

render() {
  mkdir -p "${DIR}/rendered"
  # Exclude private ranges plus the cluster and service networks (they are not always RFC 1918)
  local nets
  nets=$(oc get network.config cluster -o jsonpath='{.status.clusterNetwork[*].cidr} {.status.serviceNetwork[*]}')
  EXCEPT_CIDRS=$(python3 - ${nets} <<'PY'
import ipaddress, sys
fixed = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16", "127.0.0.0/8"]
nets = [ipaddress.ip_network(n) for n in fixed]
for c in sys.argv[1:]:
    n = ipaddress.ip_network(c)
    if n.version == 4 and not any(n.subnet_of(f) for f in nets):
        nets.append(n)
print("\n".join(f"              - {n}" for n in nets))
PY
)
  EXCEPT_CIDRS="${EXCEPT_CIDRS}" python3 - "${DIR}/networkpolicy-egress-external.yaml.tmpl" \
    "${DIR}/rendered/networkpolicy-egress-external.yaml" <<'PY'
import os, sys
open(sys.argv[2], "w").write(open(sys.argv[1]).read().replace("${EXCEPT_CIDRS}", os.environ["EXCEPT_CIDRS"]))
PY
  # JSON5 template -> JSON patch (comments stripped; no string in the template contains " //")
  python3 - "${DIR}/openclaw-slack.json5.tmpl" "${DIR}/rendered/openclaw-slack.json" <<'PY'
import json, os, re, sys
t = open(sys.argv[1]).read()
ids = [i for i in re.split(r"[\s,]+", os.environ["SLACK_OPERATOR_IDS"]) if i]
t = t.replace("${SLACK_CHANNEL_ID}", os.environ["SLACK_CHANNEL_ID"]).replace("${SLACK_OPERATOR_IDS_JSON}", json.dumps(ids))
t = "\n".join(re.sub(r"(^|\s)//.*$", "", l) for l in t.splitlines())
json.dump(json.loads(t), open(sys.argv[2], "w"), indent=2)
PY
  ok "Rendered ${DIR}/rendered/"
}

enable() {
  require_env SLACK_BOT_TOKEN SLACK_APP_TOKEN SLACK_CHANNEL_ID SLACK_OPERATOR_IDS
  oc -n "${NS}" get deploy openclaw -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' \
    | grep -qw SLACK_BOT_TOKEN || die "Deployment has no SLACK_* env yet: run 'make agent' first"
  render
  # 1. Identity: tokens in the vault, copied by ESO
  "${REPO_ROOT}/scripts/create-secrets.sh" >/dev/null
  oc apply -f "${DIR}/external-secret.yaml"
  wait_for_jsonpath externalsecret/openclaw-slack "${NS}" '{.status.conditions[0].status}' True 120
  # 2. Isolation: external HTTPS allowed by NetworkPolicy, restricted to Slack (+ npm for now)
  apply_firewall "${DIR}/egressfirewall-plugin-install.yaml"   # restrict first, then open 443
  oc apply -f "${DIR}/rendered/networkpolicy-egress-external.yaml"
  oc -n "${NS}" rollout restart deploy/openclaw
  oc -n "${NS}" rollout status deploy/openclaw --timeout=480s
  # 3. Plugin (not bundled in the image; persisted on the agent PVC)
  if ! oc_claw plugins info slack >/dev/null 2>&1; then
    info "Installing ${PLUGIN_SPEC}"
    oc_claw plugins install "${PLUGIN_SPEC}"
  fi
  apply_firewall "${DIR}/egressfirewall.yaml"       # close the npm window (Slack only)
  # 4. Channel config + alert delivery to the channel
  oc_claw config patch --stdin < "${DIR}/rendered/openclaw-slack.json"
  oc_claw config validate
  oc -n "${NS}" rollout restart deploy/openclaw     # load the plugin
  oc -n "${NS}" rollout status deploy/openclaw --timeout=480s
  status
}

disable() {
  oc_claw config patch --stdin <<'JSON' || warn "config patch failed"
{"channels":{"slack":{"enabled":false}},
 "hooks":{"mappings":[{"id":"alertmanager","match":{"path":"alertmanager"},"action":"agent","agentId":"main",
  "name":"Alert {{commonLabels.alertname}}","wakeMode":"now","deliver":false,
  "messageTemplate":"ALERT {{status}} from Alertmanager. alertname={{commonLabels.alertname}} namespace={{commonLabels.namespace}} pod={{commonLabels.pod}} severity={{commonLabels.severity}} summary={{commonAnnotations.summary}}. Follow the incident procedure in AGENTS.md: diagnose with read-only tools and report root cause and a proposed action."}]}}
JSON
  oc -n "${NS}" delete networkpolicy allow-egress-external-https --ignore-not-found   # close 443 first
  oc -n "${NS}" delete egressfirewall default --ignore-not-found
  oc -n "${NS}" delete externalsecret openclaw-slack --ignore-not-found              # owns openclaw/openclaw-slack
  oc -n poc-vault delete secret openclaw-slack-credentials --ignore-not-found
  oc -n "${NS}" rollout restart deploy/openclaw
  oc -n "${NS}" rollout status deploy/openclaw --timeout=480s
  ok "Slack disabled: no external egress, alerts stay in isolated sessions (Control UI)"
}

status() {
  oc -n "${NS}" get egressfirewall 2>&1 | sed 's/^/  /'
  oc -n "${NS}" get networkpolicy/allow-egress-external-https externalsecret/openclaw-slack 2>&1 | sed 's/^/  /'
  oc_claw channels list 2>&1 | sed 's/^/  /' | tail -8
}

case "${1:-}" in
  enable) enable ;; disable) disable ;; status) status ;; render) require_env SLACK_CHANNEL_ID SLACK_OPERATOR_IDS; render ;;
  *) die "usage: $0 enable|disable|status|render" ;;
esac
