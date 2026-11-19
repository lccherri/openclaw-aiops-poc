#!/usr/bin/env bash
# Renders environment-specific files (git-ignored) from .env:
#   manifests/phase3-agent/openclaw/agent.env
#   manifests/phase2-governance/guardrails/nemo-config/rendered/config.yaml
source "$(dirname "$0")/lib.sh"
require_env MAAS_MODEL

# Model path for the agent: RHOAI MaaS when available, otherwise the fallback (internal MaaS)
MAAS_BASE_URL="${RHOAI_MAAS_URL:-${MAAS_INTERNAL_URL:-}}"
[[ -n "${RHOAI_MAAS_URL:-}" ]] || warn "RHOAI_MAAS_URL empty - agent will use the fallback MAAS_INTERNAL_URL"

out="${REPO_ROOT}/manifests/phase3-agent/openclaw/agent.env"
cat > "${out}" <<ENV
MAAS_BASE_URL=${MAAS_BASE_URL}
MAAS_MODEL=${MAAS_MODEL}
AAP_MCP_URL=${AAP_MCP_URL:-http://aap-mcp.aap.svc:8080/mcp}
MLFLOW_OTLP_ENDPOINT=${MLFLOW_OTLP_ENDPOINT:-${MLFLOW_TRACKING_URL:-http://mlflow.invalid}/v1/traces}
MLFLOW_EXPERIMENT_ID=${MLFLOW_EXPERIMENT_ID:-0}
OPENCLAW_HEARTBEAT=${OPENCLAW_HEARTBEAT:-30m}
ENV
ok "Rendered ${out#"${REPO_ROOT}"/}"

gdir="${REPO_ROOT}/manifests/phase2-governance/guardrails/nemo-config"
mkdir -p "${gdir}/rendered"
GUARDRAILS_UPSTREAM_URL="${GUARDRAILS_UPSTREAM_URL:-${MAAS_INTERNAL_URL:-}}" MAAS_MODEL="${MAAS_MODEL}" \
python3 - "${gdir}/config.yaml" "${gdir}/rendered/config.yaml" <<'PY'
import os, sys, string
src, dst = sys.argv[1], sys.argv[2]
open(dst, "w").write(string.Template(open(src).read()).safe_substitute(os.environ))
PY
ok "Rendered ${gdir#"${REPO_ROOT}"/}/rendered/config.yaml"
