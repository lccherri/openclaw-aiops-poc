#!/usr/bin/env bash
# Success criteria #1 and #4: the agent process holds no credential with write access,
# and no identity in the tool chain can delete the namespace.
source "$(dirname "$0")/lib.sh"
pass=0; failc=0
expect() {  # expect <yes|no> <description> <oc auth can-i args...>
  local want="$1" desc="$2"; shift 2
  local got; got=$(oc auth can-i "$@" 2>/dev/null || true)
  if [[ "${got}" == "${want}" ]]; then ok "${desc} -> ${got}"; pass=$((pass+1))
  else fail "${desc} -> ${got} (expected ${want})"; failc=$((failc+1)); fi
}

AGENT=system:serviceaccount:openclaw:openclaw-tracing   # agent pod SA (MLflow tracing only)
K8SMCP=system:serviceaccount:aiops-tools:kubernetes-mcp
PROMMCP=system:serviceaccount:aiops-tools:prometheus-mcp
AAPSA=system:serviceaccount:aap:aap-automation

info "Agent ServiceAccount (MLflow tracing only - no Kubernetes permissions)"
expect no "agent: get pods demo-apps"            get pods -n demo-apps --as="${AGENT}"
expect no "agent: get secrets openclaw"          get secrets -n openclaw --as="${AGENT}"
expect no "agent: delete namespace demo-apps"    delete namespaces/demo-apps --as="${AGENT}"

info "Kubernetes MCP ServiceAccount (read-only in demo-apps)"
expect yes "k8s-mcp: get pods demo-apps"         get pods -n demo-apps --as="${K8SMCP}"
expect yes "k8s-mcp: get pods/log demo-apps"     get pods --subresource=log -n demo-apps --as="${K8SMCP}"
expect no  "k8s-mcp: get secrets demo-apps"      get secrets -n demo-apps --as="${K8SMCP}"
expect no  "k8s-mcp: patch deployments"          patch deployments -n demo-apps --as="${K8SMCP}"
expect no  "k8s-mcp: delete namespace"           delete namespaces/demo-apps --as="${K8SMCP}"
expect no  "k8s-mcp: get pods other namespace"   get pods -n openshift-monitoring --as="${K8SMCP}"

info "Prometheus MCP ServiceAccount (metrics only)"
expect no  "prom-mcp: patch deployments"         patch deployments -n demo-apps --as="${PROMMCP}"
expect no  "prom-mcp: get secrets"               get secrets -n demo-apps --as="${PROMMCP}"

info "AAP ServiceAccount (the only writer, scoped to demo-apps)"
expect yes "aap: patch deployments demo-apps"    patch deployments -n demo-apps --as="${AAPSA}"
expect no  "aap: delete deployments demo-apps"   delete deployments -n demo-apps --as="${AAPSA}"
expect no  "aap: delete namespace demo-apps"     delete namespaces/demo-apps --as="${AAPSA}"
expect no  "aap: patch deployments openclaw"     patch deployments -n openclaw --as="${AAPSA}"

info "Agent pod: mounted credentials"
pod=$(oc get pod -n openclaw -l app.kubernetes.io/name=openclaw -o name 2>/dev/null | head -1)
if [[ -n "${pod}" ]]; then
  auto=$(oc get -n openclaw "${pod}" -o jsonpath='{.spec.automountServiceAccountToken}')
  [[ "${auto}" == "false" ]] && { ok "automountServiceAccountToken=false"; pass=$((pass+1)); } \
                             || { fail "automountServiceAccountToken=${auto:-unset}"; failc=$((failc+1)); }
  gw_mounts=$(oc get -n openclaw "${pod}" -o jsonpath='{.spec.containers[?(@.name=="gateway")].volumeMounts[*].mountPath}')
  if grep -q 'serviceaccount' <<<"${gw_mounts}"; then
    fail "gateway container mounts a ServiceAccount token (${gw_mounts})"; failc=$((failc+1))
  else
    ok "gateway container has no ServiceAccount token (mounts: ${gw_mounts})"; pass=$((pass+1))
  fi
  info "Secret keys exposed to the agent (names only):"
  oc get secret openclaw-secrets -n openclaw -o jsonpath='{.data}' 2>/dev/null \
    | python3 -c 'import json,sys; [print("   -", k) for k in json.load(sys.stdin)]' || true
else
  warn "OpenClaw pod not found - skipping pod checks"
fi

echo; info "Result: ${pass} passed, ${failc} failed"
[[ ${failc} -eq 0 ]]
