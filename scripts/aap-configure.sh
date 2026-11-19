#!/usr/bin/env bash
# Steps 17-20: configures AAP as code, running aap/config-as-code/configure-aap.yml inside a
# short-lived pod that uses AAP's own execution environment (no local Ansible or Automation
# Hub token needed). Stores the new openclaw-agent token in .env as AAP_MCP_TOKEN.
source "$(dirname "$0")/lib.sh"
require_env AAP_GATEWAY_URL AAP_ADMIN_PASSWORD AAP_AGENT_USER_PASSWORD AAP_APPROVER_PASSWORD AAP_EDA_USER_PASSWORD GIT_REPO_URL
NS=aap; POD=aap-config-as-code
EE=$(curl -sk -u "admin:${AAP_ADMIN_PASSWORD}" "${AAP_GATEWAY_URL}/api/controller/v2/execution_environments/?name=Default%20execution%20environment" \
     | python3 -c 'import json,sys; print(json.load(sys.stdin)["results"][0]["image"])')
info "Execution environment: ${EE}"

oc -n "${NS}" delete pod "${POD}" --ignore-not-found --wait=true >/dev/null
cat <<YAML | oc apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: ${POD}, namespace: ${NS}, labels: {poc.aiops/purpose: config-as-code}}
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: ee
    image: ${EE}
    command: ["sleep", "1800"]
    env: [{name: HOME, value: /tmp}]
    securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
YAML
trap 'oc -n "${NS}" delete pod "${POD}" --wait=false >/dev/null 2>&1 || true' EXIT
oc -n "${NS}" wait "pod/${POD}" --for=condition=Ready --timeout=600s >/dev/null
tar -C "${REPO_ROOT}" -cf - aap/config-as-code | oc -n "${NS}" exec -i "${POD}" -- tar -C /tmp -xf -

K8S_API=$(oc whoami --show-server)
K8S_TOKEN=$(oc get secret aap-automation-token -n aap -o jsonpath='{.data.token}' | base64 -d)
oc -n "${NS}" exec -i "${POD}" -- sh -c 'set -a; . /dev/stdin; set +a; cd /tmp && ansible-playbook aap/config-as-code/configure-aap.yml' <<ENV
AAP_GATEWAY_URL=${AAP_GATEWAY_URL}
AAP_ADMIN_PASSWORD=${AAP_ADMIN_PASSWORD}
AAP_AGENT_USER_PASSWORD=${AAP_AGENT_USER_PASSWORD}
AAP_APPROVER_PASSWORD=${AAP_APPROVER_PASSWORD}
AAP_EDA_USER_PASSWORD=${AAP_EDA_USER_PASSWORD}
AAP_MCP_TOKEN=${AAP_MCP_TOKEN:-}
GIT_REPO_URL=${GIT_REPO_URL}
GIT_BRANCH=${GIT_BRANCH:-main}
K8S_API=${K8S_API}
K8S_TOKEN=${K8S_TOKEN}
AGENT_TOKEN_FILE=/tmp/openclaw-agent.token
ENV

tok=$(oc -n "${NS}" exec "${POD}" -- sh -c 'cat /tmp/openclaw-agent.token 2>/dev/null' || true)
if [[ -n "${tok}" ]]; then
  python3 - "${REPO_ROOT}/.env" "${tok}" <<'PY'
import re, sys
p, v = sys.argv[1:]; s = open(p).read()
s, n = re.subn(r'^AAP_MCP_TOKEN=.*$', f'AAP_MCP_TOKEN="{v}"', s, flags=re.M)
open(p, "w").write(s if n else s + f'AAP_MCP_TOKEN="{v}"\n')
PY
  ok "openclaw-agent token stored in .env (AAP_MCP_TOKEN). Run: make secrets"
fi
