#!/usr/bin/env bash
# Runs a local Python script inside the cluster (short-lived pod, "restricted" profile).
# Useful to test in-cluster endpoints (guardrails, MaaS internal Service, MCP servers).
# Usage: [POD_LABELS=k=v,k2=v2] scripts/incluster-python.sh <namespace> <script.py> [args...]
source "$(dirname "$0")/lib.sh"
ns="$1"; script="$2"; shift 2
overrides=$(POD_LABELS="${POD_LABELS:-}" python3 - "$@" <<'PY'
import json, os, sys
labels = dict(kv.split("=", 1) for kv in os.environ["POD_LABELS"].split(",") if kv)
print(json.dumps({"metadata": {"labels": labels}, "spec": {
  "securityContext": {"runAsNonRoot": True, "seccompProfile": {"type": "RuntimeDefault"}},
  "containers": [{"name": "py", "image": "registry.access.redhat.com/ubi9/python-311:latest",
                  "stdin": True, "stdinOnce": True, "command": ["python", "-"] + sys.argv[1:],
                  "securityContext": {"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]}}}]}}))
PY
)
oc -n "${ns}" run "py-$(date +%s)" --rm -i --restart=Never --quiet \
  --image=registry.access.redhat.com/ubi9/python-311:latest --overrides="${overrides}" < "${script}"
