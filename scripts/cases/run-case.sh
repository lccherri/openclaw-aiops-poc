#!/usr/bin/env bash
# Triggers / resets the test cases and logs timestamps (MTTR reference).
# Usage: scripts/cases/run-case.sh <1|2|3|4|5> <trigger|reset|status>
source "$(dirname "$0")/../lib.sh"
case_id="${1:?case number}"; action="${2:?trigger|reset|status}"
NS=demo-apps
LOG_DIR="${REPO_ROOT}/evidence/timeline"; mkdir -p "${LOG_DIR}"
mark() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) case${case_id} $*" | tee -a "${LOG_DIR}/timeline.log"; }

case "${case_id}:${action}" in
  1:trigger|2:trigger)
    # Revision 2 of "checkout" points to the broken ConfigMap -> CrashLoopBackOff
    oc -n ${NS} set volume deployment/checkout --add --overwrite --name=config \
      --type=configmap --configmap-name=checkout-config-v2 >/dev/null
    mark "TRIGGER checkout -> checkout-config-v2 (broken). Expect alert DemoAppCrashLooping in ~2-3 min" ;;
  1:reset|2:reset)
    oc -n ${NS} set volume deployment/checkout --add --overwrite --name=config \
      --type=configmap --configmap-name=checkout-config-v1 >/dev/null
    mark "RESET checkout -> checkout-config-v1" ;;
  3:trigger)
    oc -n ${NS} set env deployment/report-worker ALLOC_MB=200 >/dev/null
    mark "TRIGGER report-worker ALLOC_MB=200 (limit 128Mi) -> OOMKilled; expect EDA job set-memory-limit" ;;
  3:reset)
    oc -n ${NS} set env deployment/report-worker ALLOC_MB=64 >/dev/null
    oc -n ${NS} set resources deployment/report-worker --requests=memory=128Mi --limits=memory=128Mi >/dev/null
    mark "RESET report-worker ALLOC_MB=64, memory 128Mi" ;;
  4:trigger)
    oc -n ${NS} scale deployment/inventory-sync --replicas=1 >/dev/null
    mark "TRIGGER inventory-sync (prompt injection in logs)" ;;
  4:reset)
    oc -n ${NS} scale deployment/inventory-sync --replicas=0 >/dev/null
    mark "RESET inventory-sync scaled to 0" ;;
  5:trigger)
    # The agent subscription is sized for normal operation (2M tokens/h, test-log F-10):
    # lower it temporarily so the burst reaches the limit in a few requests.
    limit="${CASE5_TOKEN_LIMIT:-3000}"
    oc -n models-as-a-service patch maassubscription openclaw-agent --type=json \
      -p "[{\"op\":\"replace\",\"path\":\"/spec/modelRefs/0/tokenRateLimits/0/limit\",\"value\":${limit}}]" >/dev/null
    mark "TRIGGER quota burst (openclaw-agent limit lowered to ${limit} tokens/h)"
    sleep 20   # let MaaS reconcile the new limit
    "${REPO_ROOT}/scripts/quota-burst.sh" | tee -a "${LOG_DIR}/case5-quota.log" ;;
  5:reset)
    oc apply -f "${REPO_ROOT}/manifests/phase2-governance/maas/access.yaml" >/dev/null
    mark "RESET openclaw-agent subscription restored from access.yaml (tokens already used stay counted until the window expires)" ;;
  *:status)
    oc -n ${NS} get pods -o wide
    oc -n ${NS} get events --sort-by=.lastTimestamp | tail -15 ;;
  *) die "Unknown case/action: ${case_id} ${action}" ;;
esac
