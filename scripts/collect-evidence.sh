#!/usr/bin/env bash
# Collects evidence after a test run into evidence/<timestamp>/ (git-ignored).
# Copy the relevant excerpts into docs/test-log.md.
source "$(dirname "$0")/lib.sh"
dir="${REPO_ROOT}/evidence/$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "${dir}"
info "Saving evidence to ${dir#"${REPO_ROOT}"/}"

oc get pods,deploy,rs -n demo-apps -o wide          > "${dir}/demo-apps-workloads.txt" 2>&1
oc get events -n demo-apps --sort-by=.lastTimestamp > "${dir}/demo-apps-events.txt" 2>&1
oc rollout history deployment/checkout -n demo-apps > "${dir}/checkout-rollout-history.txt" 2>&1
oc logs -n openclaw -l app.kubernetes.io/name=openclaw --tail=500 > "${dir}/openclaw.log" 2>&1 || true
oc -n openshift-user-workload-monitoring exec alertmanager-user-workload-0 -c alertmanager -- \
  amtool alert query --alertmanager.url=http://localhost:9093 > "${dir}/alerts-firing.txt" 2>&1 || true
"${REPO_ROOT}/scripts/verify-agent-privileges.sh" > "${dir}/privileges.txt" 2>&1 || true

if [[ -n "${AAP_GATEWAY_URL:-}" && -n "${AAP_ADMIN_PASSWORD:-}" ]]; then
  curl -sk -u "admin:${AAP_ADMIN_PASSWORD}" \
    "${AAP_GATEWAY_URL}/api/controller/v2/unified_jobs/?order_by=-created&page_size=50" \
    | python3 -c 'import json,sys
d=json.load(sys.stdin)
for j in d.get("results",[]):
    print(j["id"], j["type"], j["name"], j["status"], j.get("launched_by",{}).get("name"), j["created"])' \
    > "${dir}/aap-jobs.txt" 2>&1 || warn "Could not query AAP jobs"
  curl -sk -u "admin:${AAP_ADMIN_PASSWORD}" \
    "${AAP_GATEWAY_URL}/api/controller/v2/workflow_approvals/?order_by=-created&page_size=20" \
    > "${dir}/aap-approvals.json" 2>&1 || true
fi
[[ -f "${REPO_ROOT}/evidence/timeline/timeline.log" ]] && cp "${REPO_ROOT}/evidence/timeline/timeline.log" "${dir}/"
ok "Done. MLflow traces: open the MLflow UI, experiment ${MLFLOW_EXPERIMENT_ID:-<id>} (export screenshots manually)."
