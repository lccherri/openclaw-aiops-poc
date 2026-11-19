#!/usr/bin/env bash
# Prerequisites reported by the RHOAI 3.5 MaaS component (DSC condition ModelsAsAServiceReady):
#   1. Gateway openshift-ingress/maas-default-gateway (ClusterIP + Route)
#   2. PostgreSQL + Secret redhat-ai-gateway-infra/maas-db-config (DB_CONNECTION_URL)
#   3. Authorino trusts the OpenShift service CA (calls maas-api over HTTPS)
#   4. Authorino listener TLS - DISABLED on purpose (see docs/open-points.md #16): with
#      RHCL 1.4.3 the Kuadrant EnvoyFilter calls Authorino in plaintext gRPC, so enabling
#      listener TLS breaks every MaaS request (HTTP 500). Set AUTHORINO_TLS=true to enable.
# Idempotent. Secrets are generated in-cluster and never printed.
source "$(dirname "$0")/lib.sh"
M="${REPO_ROOT}/manifests/phase1-platform/rhoai"

info "1/4 MaaS gateway"
MAAS_HOSTNAME="maas.$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}')"
MAAS_HOSTNAME="${MAAS_HOSTNAME}" python3 -c 'import os,string,sys; print(string.Template(open(sys.argv[1]).read()).safe_substitute(os.environ))' \
  "${M}/maas-gateway.yaml" | oc apply -f - >/dev/null && ok "Gateway + Route applied (${MAAS_HOSTNAME})"

info "2/4 MaaS database"
oc apply -f "${M}/maas-database.yaml" >/dev/null
if ! oc get secret maas-postgres-credentials -n aiops-maas-db >/dev/null 2>&1; then
  pw=$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')
  oc -n aiops-maas-db create secret generic maas-postgres-credentials \
    --from-literal=POSTGRESQL_USER=maas --from-literal=POSTGRESQL_PASSWORD="${pw}" \
    --from-literal=POSTGRESQL_DATABASE=maas >/dev/null
  ok "Generated database credentials"
fi
pw=$(oc get secret maas-postgres-credentials -n aiops-maas-db -o jsonpath='{.data.POSTGRESQL_PASSWORD}' | base64 -d)
oc -n redhat-ai-gateway-infra create secret generic maas-db-config \
  --from-literal=DB_CONNECTION_URL="postgresql://maas:${pw}@maas-postgres.aiops-maas-db.svc:5432/maas?sslmode=disable" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null
unset pw
ok "Secret redhat-ai-gateway-infra/maas-db-config"
oc -n aiops-maas-db rollout status deploy/maas-postgres --timeout=300s

info "3/4 Authorino trusts the service CA"
oc apply -f "${REPO_ROOT}/manifests/phase1-platform/rhcl/authorino-ca.yaml" >/dev/null
until [[ -n "$(oc -n kuadrant-system get cm authorino-trusted-ca -o jsonpath='{.data.ca-bundle\.crt}' 2>/dev/null)" && \
         -n "$(oc -n kuadrant-system get cm authorino-service-ca -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null)" ]]; do sleep 3; done
oc -n kuadrant-system patch authorino authorino --type=merge -p '{"spec":{"volumes":{"items":[
  {"name":"trusted-ca","mountPath":"/etc/pki/tls/certs","configMaps":["authorino-trusted-ca","authorino-service-ca"]}]}}}' >/dev/null
oc -n kuadrant-system rollout status deploy/authorino --timeout=180s >/dev/null
ok "Authorino mounts cluster trusted bundle + service CA at /etc/pki/tls/certs"

info "4/4 Authorino listener TLS"
if [[ "${AUTHORINO_TLS:-false}" != "true" ]]; then
  oc -n kuadrant-system patch authorino authorino --type=merge \
    -p '{"spec":{"listener":{"tls":{"enabled":false,"certSecretRef":null}}}}' >/dev/null
  warn "Authorino listener TLS kept disabled (RHCL 1.4.3 gateway calls Authorino in plaintext)"
  exit 0
fi
oc -n kuadrant-system annotate svc authorino-authorino-authorization \
  service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert --overwrite >/dev/null
until oc -n kuadrant-system get secret authorino-server-cert >/dev/null 2>&1; do sleep 3; done
oc -n kuadrant-system patch authorino authorino --type=merge \
  -p '{"spec":{"listener":{"tls":{"enabled":true,"certSecretRef":{"name":"authorino-server-cert"}}}}}' >/dev/null
ok "Authorino listener TLS enabled (service CA certificate)"
