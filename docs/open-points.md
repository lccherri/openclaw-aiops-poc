# Open points and decisions

Tracks the questions the plan left open, the decisions taken while building the
repository, and every `TEMPLATE` / `VERIFY` marker that has to be confirmed on the
cluster.

## Open points from the plan

| # | Question | Status | Notes |
|---|---|---|---|
| 1 | OpenShift version supported by OpenShift AI 3.5 and AAP 2.6 | 🟡 Partially answered | Cluster runs **OCP 4.22.22**; `rhods-operator` 3.5.3 and AAP `stable-2.6` are both offered by the cluster catalog. Still confirm in the KB *Supported Configurations for 3.x* and in the AAP 2.6 lifecycle page |
| 2 | Exact operator package names | ✅ Answered | `rhods-operator` (stable-3.5), `ansible-automation-platform-operator` (stable-2.6), `rhcl-operator` (stable), `openshift-cert-manager-operator` (installed), `openshift-external-secrets-operator` (stable-v1), `mcp-gateway` (preview, phase 2) |
| 3 | How OpenClaw receives alerts via webhook | 🟡 Designed | `hooks` with a mapping at `/hooks/alertmanager` (Bearer token). Alertmanager uses `AlertmanagerConfig` with `httpConfig.authorization`. Verify the `hooks.mappings` schema and template syntax for the pinned version |
| 4 | Which Kubernetes and Prometheus MCP servers to use | 🟡 Chosen, to validate | Kubernetes: `containers/kubernetes-mcp-server` (upstream of Red Hat `openshift-mcp-server`) with `--read-only`. Prometheus: `pab1it0/prometheus-mcp-server`; alternative to evaluate: `rhobs/obs-mcp` (Red Hat observability) |
| 5 | MaaS ↔ NeMo Guardrails order with an external model | ⬜ Open | Topology A (MaaS → Guardrails) is the default; both are prepared. See [architecture.md](architecture.md#model-path-maas-and-guardrails-order) |
| 6 | Does EvalHub red teaming work against an external model without GPU? | ⬜ Open | Garak runs as a job calling the model API, so it should not need a GPU. Validate in step 11 |

## New open points found while structuring

| # | Question | Impact | Notes |
|---|---|---|---|
| 7 | Does NeMo Guardrails pass OpenAI `tools` / `tool_calls` through? | High: the agent cannot work behind guardrails without it | Test with `model-validation/tool_calling_test.py --base-url <guardrails>/v1`. If not supported: guardrails only on input/output text, or keep guardrails out of the agent path and record the limitation (risk table) |
| 8 | Do NeMo input rails see tool outputs (logs) or only the user message? | Medium: case 4 detection | Input rails check the last user message by default. Log content arrives as `tool` messages, so `detect_prompt_injection` may not see it. Record the actual behavior |
| 9 | OpenClaw MCP configuration key | High | The `mcp.servers` block in `openclaw.json5` must match the pinned OpenClaw version (OpenClaw rejects unknown keys). Alternative: MCP through a skill (e.g. `mcporter`). Validate with `openclaw doctor` |
| 10 | OpenClaw OTel export to MLflow | Medium | `diagnostics-otel` plugin + MLflow OTLP ingestion (`/v1/traces`, header `x-mlflow-experiment-id`). Confirm MLflow auth in RHOAI (bearer token vs. kube-rbac-proxy) and the RBAC resource names in `trace-writer-rbac.yaml` |
| 11 | Ansible MCP server: CR fields, Service name, pod labels | Medium | CRD `ansiblemcpservers.mcpserver.ansible.com` exists in the AAP 2.6 operator; fields to confirm with `oc explain` |
| 12 | Alert template syntax in OpenClaw hook mappings | Low | `{{commonLabels.alertname}}` assumes mustache-style access to the JSON body |
| 13 | User-workload Thanos Ruler access to kube-state-metrics | Low | Expected to work (namespace-scoped platform metrics); if not, set the rule to `leaf-prometheus` scope or use a user metric |
| 14 | MaaS gateway internal address | Medium | Needed for `MAAS_BASE_URL` (the NetworkPolicy allows `openshift-ingress` only; external route hostnames need an `ipBlock`) |

## Decisions

| Date | Decision | Reason |
|---|---|---|
| 2026-11-18 | Use **ODF NooBaa** (`ObjectBucketClaim`) for S3 instead of MinIO | Already available in the cluster |
| 2026-11-18 | Do not manage cert-manager in this repo | Already installed (1.20.1, `stable-v1`) |
| 2026-11-18 | Identity layer: **ESO with a Kubernetes provider** reading from `poc-vault` | Shows the pattern (agent never holds the source secret) without an external vault; the provider can be swapped |
| 2026-11-18 | Agent pod: `automountServiceAccountToken: false` + SA without bindings + no egress to the API server | Success criterion 1 enforced by three independent controls |
| 2026-11-18 | Agent can launch only **workflows with an approval node** (plus read-only `collect-diagnostics`) | Write actions always need a human; approval is a separate AAP user |
| 2026-11-18 | Added a 5th template `set-memory-limit`, **EDA-only** | Case 3 needs a "tuning" action that is not part of the agent catalog |
| 2026-11-18 | Prometheus MCP uses Thanos Querier port 9091 + `cluster-monitoring-view` | The tenancy port (9092) needs a `namespace` parameter the MCP server does not send. Still read-only metrics |
| 2026-11-18 | Rulebooks under `extensions/eda/rulebooks/` | EDA project import only discovers rulebooks there or in `rulebooks/` at the repo root |
| 2026-11-18 | Community `openclaw-operator` (catalog) kept only as reference | Not a Red Hat product; plan A is the RHOAI starter kit, plan B a plain Deployment |
| 2026-11-18 | AAP channel `stable-2.6` (not the default `stable-2.7`) | Follows the plan; 2.7 is available if the 2.6 MCP server has issues |

## TEMPLATE / VERIFY inventory

| File | What to verify |
|---|---|
| `manifests/phase2-governance/maas/external-model.yaml` | Kind, API group and fields for external models (TP in 3.5) |
| `manifests/phase2-governance/maas/subscriptions.yaml` | Subscription/tier kind and quota fields |
| `manifests/phase2-governance/guardrails/nemoguardrails.yaml` | `NemoGuardrails` spec (config ConfigMaps, env) and service port |
| `manifests/phase2-governance/mlflow/mlflow.yaml` | `MLflow` spec (backend store, S3 artifacts) |
| `manifests/phase2-governance/mlflow/trace-writer-rbac.yaml` | RBAC resources for MLflow workspaces |
| `manifests/phase2-governance/evalhub/*` | `EvalHub` spec and job request schema |
| `manifests/phase3-agent/openclaw/openclaw.json5` | `mcp`, `hooks.mappings`, `diagnostics.otel`, `tools.deny` keys |
| `manifests/phase3-agent/plan-b/deployment.yaml` | Image entrypoint and env vars (`OPENCLAW_STATE_DIR`, `OPENCLAW_CONFIG_PATH`) |
| `manifests/phase3-agent/base/networkpolicies.yaml` | Ansible MCP pod label; MaaS gateway namespace/ports; MLflow ports |
| `manifests/phase4-tools/ansible-mcp/ansiblemcpserver.yaml` | `AnsibleMCPServer` spec |
| `manifests/phase4-tools/mcp-prometheus/deployment.yaml` | Env var names of the chosen Prometheus MCP image |
| `aap/config-as-code/configure-aap.yml` | Collection versions for AAP 2.6 (role grants, token module output) |
