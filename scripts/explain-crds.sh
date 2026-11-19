#!/usr/bin/env bash
# Dumps the schema of the Technology/Developer Preview CRDs used as templates in this repo,
# so the templates can be adjusted to what the cluster actually serves.
source "$(dirname "$0")/lib.sh"
out="${REPO_ROOT}/evidence/crd-schemas"; mkdir -p "${out}"
pattern='maas|externalmodel|subscription\.maas|nemoguardrails|evalhub|mlflow|ansiblemcpserver|openclaw|claw'
oc api-resources --no-headers 2>/dev/null | grep -Ei "${pattern}" | tee "${out}/api-resources.txt" || true
while read -r line; do
  [[ -z "${line}" ]] && continue
  name=$(awk '{print $1}' <<<"${line}")
  group=$(awk '{for(i=1;i<=NF;i++) if ($i ~ /\//) print $i}' <<<"${line}" | head -1 | cut -d/ -f1)
  res="${name}${group:+.${group}}"
  oc explain "${res}" --recursive > "${out}/${res}.txt" 2>&1 && ok "${res}"
done < "${out}/api-resources.txt"
info "Schemas saved in evidence/crd-schemas/"
