#!/usr/bin/env bash
# Step 11 - submits an EvalHub evaluation (default: Garak "quick" red-team scan) and waits
# for the result. Runs the HTTP calls from a short-lived in-cluster pod (EvalHub is only
# exposed inside the cluster). Uses the caller's OpenShift token (oc whoami -t).
# API notes (RHOAI 3.5): POST/GET /api/v1/evaluations/jobs, header X-Tenant=<namespace>
# is mandatory (kube-rbac-proxy authorization), model.auth.secret_ref = Secret in that ns.
# Usage: scripts/evalhub-run.sh [request.json] ; set BENCHMARK=owasp_llm_top10 for a full scan
source "$(dirname "$0")/lib.sh"
REQ="${1:-${REPO_ROOT}/manifests/phase2-governance/evalhub/evaluation-request.json}"
NS=aiops-governance
tmp=$(mktemp -d); trap 'rm -rf "${tmp}"' EXIT
python3 - "${REQ}" "${tmp}/req.json" <<'PY'
import json, os, string, sys
d = json.loads(string.Template(open(sys.argv[1]).read()).safe_substitute(os.environ))
if os.environ.get("BENCHMARK"):
    d["benchmarks"][0]["id"] = os.environ["BENCHMARK"]; d["name"] += "-" + os.environ["BENCHMARK"].replace("_", "-")
json.dump(d, open(sys.argv[2], "w"))
PY
cat > "${tmp}/run.py" <<PY
import json, ssl, sys, time, urllib.request
tok, req = sys.argv[1], json.loads(sys.argv[2])
B = "https://evalhub.${NS}.svc.cluster.local:8443/api/v1/evaluations/jobs"
H = {"Authorization": "Bearer " + tok, "Content-Type": "application/json", "X-Tenant": "${NS}"}
ctx = ssl._create_unverified_context()   # service-CA certificate, in-cluster only
call = lambda url, data=None: json.load(urllib.request.urlopen(urllib.request.Request(url, data, H), context=ctx, timeout=60))
job = call(B, json.dumps(req).encode()); jid = job["resource"]["id"]
print("job", jid, "submitted", flush=True)
for _ in range(240):
    j = call(f"{B}/{jid}"); st = j["status"]["state"]
    print(time.strftime("%H:%M:%S"), st, flush=True)
    if st in ("completed", "failed", "cancelled", "partially_failed"):
        print(json.dumps({"status": j["status"], "results": j.get("results")}, indent=1)[:4000]); break
    time.sleep(30)
PY
"${REPO_ROOT}/scripts/incluster-python.sh" "${NS}" "${tmp}/run.py" "$(oc whoami -t)" "$(cat "${tmp}/req.json")" 2>&1 | grep -v '^Warning'
