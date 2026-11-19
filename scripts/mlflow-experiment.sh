#!/usr/bin/env bash
# Creates (or finds) the MLflow experiment that receives the agent traces, in the MLflow
# workspace "openclaw" (namespace label poc.aiops/mlflow-workspace=true), and stores its id
# in .env as MLFLOW_EXPERIMENT_ID. Calls MLflow from an in-cluster pod with the caller's token.
source "$(dirname "$0")/lib.sh"
NAME="${1:-openclaw-aiops}"
tmp=$(mktemp -d); trap 'rm -rf "${tmp}"' EXIT
cat > "${tmp}/exp.py" <<'PY'
import json, ssl, sys, urllib.request, urllib.parse
tok, name = sys.argv[1], sys.argv[2]
B = "https://mlflow.redhat-ods-applications.svc.cluster.local:8443/mlflow/api/2.0/mlflow/experiments"
H = {"Authorization": "Bearer " + tok, "X-MLFLOW-WORKSPACE": "openclaw", "Content-Type": "application/json"}
ctx = ssl._create_unverified_context()
def call(url, data=None):
    return json.load(urllib.request.urlopen(urllib.request.Request(url, data, H), context=ctx, timeout=30))
try:
    print(call(B + "/get-by-name?experiment_name=" + urllib.parse.quote(name))["experiment"]["experiment_id"])
except urllib.error.HTTPError:
    print(call(B + "/create", json.dumps({"name": name}).encode())["experiment_id"])
PY
id=$(POD_LABELS=app.kubernetes.io/name=openclaw "${REPO_ROOT}/scripts/incluster-python.sh" openclaw "${tmp}/exp.py" "$(oc whoami -t)" "${NAME}" 2>&1 | grep -v "^Warning" | tail -1 || true)
[[ "${id}" =~ ^[0-9]+$ ]] || die "Could not create/find experiment: ${id}"
python3 - "${REPO_ROOT}/.env" "${id}" <<'PY'
import re, sys
p, v = sys.argv[1:]; s = open(p).read()
s, n = re.subn(r'^MLFLOW_EXPERIMENT_ID=.*$', f'MLFLOW_EXPERIMENT_ID="{v}"', s, flags=re.M)
open(p, "w").write(s if n else s + f'MLFLOW_EXPERIMENT_ID="{v}"\n')
PY
ok "MLflow experiment '${NAME}' (workspace openclaw) id=${id} -> .env"
