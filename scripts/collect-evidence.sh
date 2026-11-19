#!/usr/bin/env bash
# Collects evidence after a test run into evidence/<timestamp>/ (git-ignored).
# Copy the relevant excerpts into docs/test-log.md.
source "$(dirname "$0")/lib.sh"
dir="${REPO_ROOT}/evidence/$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "${dir}"
info "Saving evidence to ${dir#"${REPO_ROOT}"/}"

oc get pods,deploy,rs -n demo-apps -o wide          > "${dir}/demo-apps-workloads.txt" 2>&1
oc get events -n demo-apps --sort-by=.lastTimestamp > "${dir}/demo-apps-events.txt" 2>&1
oc rollout history deployment/checkout -n demo-apps > "${dir}/checkout-rollout-history.txt" 2>&1
oc logs -n openclaw deploy/openclaw -c gateway --tail=500 > "${dir}/openclaw.log" 2>&1 || true
# launch layer: every launch requested by the agent and the AAP job id it got
oc logs -n aiops-tools deploy/aap-actions 2>/dev/null | grep AUDIT > "${dir}/aap-actions-audit.txt" || true
oc -n openshift-user-workload-monitoring exec alertmanager-user-workload-0 -c alertmanager -- \
  amtool alert query --alertmanager.url=http://localhost:9093 > "${dir}/alerts-firing.txt" 2>&1 || true
"${REPO_ROOT}/scripts/verify-agent-privileges.sh" > "${dir}/privileges.txt" 2>&1 || true

aap() { curl -sk -m 60 --retry 2 -u "admin:${AAP_ADMIN_PASSWORD}" "${AAP_GATEWAY_URL}/api/controller/v2/$1"; }
if [[ -n "${AAP_GATEWAY_URL:-}" && -n "${AAP_ADMIN_PASSWORD:-}" ]]; then
  aap "unified_jobs/?order_by=-created&page_size=50" \
    | python3 -c 'import json,sys
d=json.load(sys.stdin)
for j in d.get("results",[]):
    print(j["id"], j["type"], j["name"], j["status"], j.get("launched_by",{}).get("name"), j["created"])' \
    > "${dir}/aap-jobs.txt" 2>&1 || warn "Could not query AAP jobs"
  aap "workflow_approvals/?order_by=-created&page_size=20" > "${dir}/aap-approvals.json" 2>&1 || true
  # readable view: who approved / denied what, and when
  python3 -c 'import json,sys
for a in json.load(open(sys.argv[1])).get("results", []):
    by = (a["summary_fields"].get("approved_or_denied_by") or {}).get("username")
    verdict = {"successful": "APPROVED", "pending": "PENDING"}.get(a["status"], "TIMED OUT" if a.get("timed_out") else "DENIED")
    print(a["id"], a["name"], verdict, "by", by, "at", a.get("finished"))' "${dir}/aap-approvals.json" \
    > "${dir}/aap-approvals.txt" 2>/dev/null || true
fi
for f in aap-jobs.txt aap-approvals.json; do
  [[ -s "${dir}/${f}" ]] || warn "${f} is empty (AAP unreachable from this workstation?) - rerun make evidence"
done
[[ -f "${REPO_ROOT}/evidence/timeline/timeline.log" ]] && cp "${REPO_ROOT}/evidence/timeline/timeline.log" "${dir}/"
ok "Done. MLflow traces: experiment ${MLFLOW_EXPERIMENT_ID:-<id>}, root span openclaw.harness.run (docs/access.md#mlflow-traces)."
