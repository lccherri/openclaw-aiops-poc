#!/usr/bin/env bash
# Renders environment-specific files (git-ignored) from .env:
#   manifests/phase3-agent/openclaw/agent.env
#   manifests/phase2-governance/guardrails/nemo-config/rendered/config.yaml
source "$(dirname "$0")/lib.sh"
require_env MAAS_MODEL

# Agent model path: RHOAI MaaS in-cluster Service with the agent subscription key.
# Fallback (risk table): RHOAI_MAAS_INTERNAL_URL empty -> internal Red Hat MaaS directly.
if [[ -n "${RHOAI_MAAS_INTERNAL_URL:-}" ]]; then
  MAAS_BASE_URL="${RHOAI_MAAS_INTERNAL_URL}"; AGENT_MODEL="aiops-model"
  export GUARDRAILS_UPSTREAM_URL="${GUARDRAILS_UPSTREAM_URL:-${RHOAI_MAAS_INTERNAL_URL}}"
  export GUARDRAILS_MODEL="${GUARDRAILS_MODEL:-aiops-model}"
else
  warn "RHOAI_MAAS_INTERNAL_URL empty - agent and Guardrails will call MAAS_INTERNAL_URL directly (no MaaS quota)"
  MAAS_BASE_URL="${MAAS_INTERNAL_URL:-}"; AGENT_MODEL="${MAAS_MODEL}"
  export GUARDRAILS_UPSTREAM_URL="${GUARDRAILS_UPSTREAM_URL:-${MAAS_INTERNAL_URL:-}}"
  export GUARDRAILS_MODEL="${GUARDRAILS_MODEL:-${MAAS_MODEL}}"
fi

APPS_DOMAIN="$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')"
out="${REPO_ROOT}/manifests/phase3-agent/openclaw/agent.env"
cat > "${out}" <<ENV
MAAS_BASE_URL=${MAAS_BASE_URL}
MAAS_MODEL=${AGENT_MODEL}
OPENCLAW_HEARTBEAT=${OPENCLAW_HEARTBEAT:-30m}
OPENCLAW_PUBLIC_ORIGIN=https://openclaw-openclaw.${APPS_DOMAIN}
ENV
ok "Rendered ${out#"${REPO_ROOT}"/}"

gdir="${REPO_ROOT}/manifests/phase2-governance/guardrails/nemo-config"
mkdir -p "${gdir}/rendered"
python3 - "${gdir}/config.yaml" "${gdir}/rendered/config.yaml" <<'PY'
import os, sys, string
src, dst = sys.argv[1], sys.argv[2]
open(dst, "w").write(string.Template(open(src).read()).safe_substitute(os.environ))
PY
ok "Rendered ${gdir#"${REPO_ROOT}"/}/rendered/config.yaml"

# Guardrails Route (host + IP allowlist)
export GUARDRAILS_HOST="${GUARDRAILS_HOST:-aiops-guardrails.${APPS_DOMAIN}}"
[[ -n "${GUARDRAILS_ALLOWED_CIDRS:-}" ]] || die "Set GUARDRAILS_ALLOWED_CIDRS in .env (cluster egress IPs)"
GUARDRAILS_ALLOWED_CIDRS="${GUARDRAILS_ALLOWED_CIDRS}" python3 - "${gdir}/../route.yaml.tmpl" "${gdir}/../rendered/route.yaml" <<'PY'
import os, sys, string
os.makedirs(os.path.dirname(sys.argv[2]), exist_ok=True)
open(sys.argv[2], "w").write(string.Template(open(sys.argv[1]).read()).safe_substitute(os.environ))
PY
ok "Rendered manifests/phase2-governance/guardrails/rendered/route.yaml (${GUARDRAILS_HOST})"

# MaaS external model: upstream FQDN derived from MAAS_INTERNAL_URL
mdir="${REPO_ROOT}/manifests/phase2-governance/maas"
mkdir -p "${mdir}/rendered"
MAAS_UPSTREAM_HOST="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.urlparse(sys.argv[1]).hostname)' "${MAAS_INTERNAL_URL}")" \
MAAS_MODEL="${MAAS_MODEL}" GUARDRAILS_HOST="${GUARDRAILS_HOST}" python3 - "${mdir}/model.yaml.tmpl" "${mdir}/rendered/model.yaml" <<'PY'
import os, sys, string
open(sys.argv[2], "w").write(string.Template(open(sys.argv[1]).read()).safe_substitute(os.environ))
PY
ok "Rendered ${mdir#"${REPO_ROOT}"/}/rendered/model.yaml"

# OTel collector (MLflow tracing sidecar): experiment id of the "openclaw" workspace
kdir="${REPO_ROOT}/manifests/phase3-agent/starter-kit/kit"
mkdir -p "${kdir}/rendered"
[[ -n "${MLFLOW_EXPERIMENT_ID:-}" ]] || warn "MLFLOW_EXPERIMENT_ID empty - run scripts/mlflow-experiment.sh"
MLFLOW_EXPERIMENT_ID="${MLFLOW_EXPERIMENT_ID:-0}" python3 - "${kdir}/otel-collector-config.yaml.tmpl" "${kdir}/rendered/otel-collector-config.yaml" <<'PY'
import os, sys, string
open(sys.argv[2], "w").write(string.Template(open(sys.argv[1]).read()).safe_substitute(os.environ))
PY
ok "Rendered manifests/phase3-agent/starter-kit/kit/rendered/otel-collector-config.yaml"
