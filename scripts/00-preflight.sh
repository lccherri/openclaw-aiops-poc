#!/usr/bin/env bash
# Phase 0 - read-only validation of the cluster. Changes nothing.
source "$(dirname "$0")/lib.sh"
require_cmd oc

info "Cluster access"
oc whoami >/dev/null 2>&1 || die "Not logged in (oc login first)"
ok "Logged in as $(oc whoami) on $(oc whoami --show-server)"

info "Cluster version"
oc get clusterversion version -o jsonpath='{.status.desired.version}{"\n"}'

info "Nodes (capacity)"
oc get nodes
oc get nodes -o custom-columns='NAME:.metadata.name,CPU:.status.capacity.cpu,MEMORY:.status.capacity.memory'

total_cpu=$(oc get nodes -o jsonpath='{range .items[*]}{.status.capacity.cpu}{"\n"}{end}' | awk '{s+=$1} END {print s}')
info "Total vCPU across nodes: ${total_cpu} (recommended for this POC: >= 72 incl. control plane)"

info "Default StorageClass"
default_sc=$(oc get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}')
[[ -n "${default_sc}" ]] && ok "Default StorageClass: ${default_sc}" || fail "No default StorageClass"

info "S3-compatible object storage"
if oc get sc openshift-storage.noobaa.io >/dev/null 2>&1; then
  ok "ODF Multicloud Object Gateway available (ObjectBucketClaim via openshift-storage.noobaa.io)"
else
  warn "No NooBaa StorageClass - provision MinIO or another S3 endpoint for MLflow/EvalHub"
fi

info "User workload monitoring"
uwm=$(oc get cm cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null | grep -c 'enableUserWorkload: true' || true)
[[ "${uwm}" -ge 1 ]] && ok "enableUserWorkload: true" || warn "User workload monitoring NOT enabled (make phase0)"

info "Operator packages in the catalog"
for p in rhods-operator ansible-automation-platform-operator rhcl-operator openshift-cert-manager-operator \
         openshift-external-secrets-operator mcp-gateway openclaw-operator; do
  if oc get packagemanifest "${p}" -n openshift-marketplace >/dev/null 2>&1; then
    ch=$(oc get packagemanifest "${p}" -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')
    ok "${p} (default channel: ${ch})"
  else
    fail "${p} not found in catalog"
  fi
done

info "Installed operators of interest"
oc get csv -A --no-headers 2>/dev/null | awk '{print $2, $NF}' | sort -u \
  | grep -Ei 'rhods|aap-operator|rhcl|cert-manager|external-secrets|odf-operator' || true

info "Operators that must NOT be installed (GPU / llm-d only)"
if oc get csv -A --no-headers 2>/dev/null | grep -Eiq 'gpu-operator|nfd|leader-worker-set'; then
  warn "GPU-related operators found - not needed for this POC"
else
  ok "No GPU / NFD / LWS operators installed"
fi

ok "Preflight finished"
