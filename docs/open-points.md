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
| 5 | MaaS ↔ NeMo Guardrails order with an external model | ✅ Answered | **Topology B** (Guardrails → MaaS). Topology A breaks the token quota (NeMo returns no `usage`). See test-log F-05 |
| 6 | Does EvalHub red teaming work against an external model without GPU? | ✅ Answered | Yes. Garak `quick` ran as a CPU job against the internal MaaS (test-log F-07) |

## New open points found while structuring

| # | Question | Impact | Notes |
|---|---|---|---|
| 7 | Does NeMo Guardrails pass OpenAI `tools` / `tool_calls` through? | ✅ Answered: only with `passthrough: true` (15/15 through Guardrails) | Test with `model-validation/tool_calling_test.py --base-url <guardrails>/v1`. If not supported: guardrails only on input/output text, or keep guardrails out of the agent path and record the limitation (risk table) |
| 8 | Do NeMo input rails see tool outputs (logs) or only the user message? | Medium: case 4 detection | Input rails check the last user message by default. Log content arrives as `tool` messages, so `detect_prompt_injection` may not see it. Record the actual behavior |
| 9 | OpenClaw MCP configuration key | High | The `mcp.servers` block in `openclaw.json5` must match the pinned OpenClaw version (OpenClaw rejects unknown keys). Alternative: MCP through a skill (e.g. `mcporter`). Validate with `openclaw doctor` |
| 10 | OpenClaw OTel export to MLflow | Medium | `diagnostics-otel` plugin + MLflow OTLP ingestion (`/v1/traces`, header `x-mlflow-experiment-id`). ✅ Solved with the starter kit OTel sidecar (SA token + `mlflow-operator-mlflow-integration`, workspace header); traces arriving |
| 11 | Ansible MCP server: CR fields, Service name, pod labels | Medium (blocked: AAP subscription) | CRD `ansiblemcpservers.mcpserver.ansible.com` exists in the AAP 2.6 operator; fields to confirm with `oc explain` |
| 12 | Alert template syntax in OpenClaw hook mappings | Low | `{{commonLabels.alertname}}` assumes mustache-style access to the JSON body |
| 13 | User-workload Thanos Ruler access to kube-state-metrics | Low | Expected to work (namespace-scoped platform metrics); if not, set the rule to `leaf-prometheus` scope or use a user metric |
| 15 | Text-encoded tool calls from `llama-scout-17b` with `tool_choice=auto` | ✅ Superseded: model changed to `qwen3-14b` (0/15 text-encoded calls without hint) | Mitigated by a system-prompt rule (test-log F-01). Re-check with OpenClaw's own prompt during case 1; if it recurs, ask the internal MaaS owners about the vLLM tool parser (`llama4_pythonic` vs `llama4_json`) |
| 14 | MaaS gateway internal address | ✅ Answered: `maas-default-gateway-data-science-gateway-class.openshift-ingress.svc.cluster.local` (only Guardrails uses it) | Needed for `MAAS_BASE_URL` (the NetworkPolicy allows `openshift-ingress` only; external route hostnames need an `ipBlock`) |

## Decisions

| Date | Decision | Reason |
|---|---|---|
| 2026-11-19 | **Topology B** for the model path: agent → Guardrails → MaaS → model; agent holds no model key and has no egress to the MaaS gateway | Only topology that keeps both content rails and the per-agent token quota (test-log F-05) |
| 2026-11-19 | Guardrails Route (created by the TrustyAI operator) restricted with an IP allowlist | Guardrails has no authentication and calls the model with the agent key |
| 2026-11-19 | MLflow with SQLite + PVC (no S3) | Supported by the operator; traces live in the backend store. ODF/NooBaa remains available if needed |
| 2026-11-19 | Authorino listener TLS disabled; Authorino trusts the service CA instead | RHCL 1.4.3 calls Authorino in plaintext; the real requirement is Authorino → maas-api over HTTPS (test-log F-03) |
| 2026-11-19 | Model consumers are ServiceAccounts in `aiops-models` (one MaaSSubscription each) | Independent quotas for case 5; keys minted with short-lived SA tokens (`scripts/maas-mint-keys.sh`) |
| 2026-11-19 | Model changed to **`qwen3-14b`** (GO, 15/15 without hint) | Handles the untrusted-content wrapper on webhook alerts (D-3, test-log F-13) |
| 2026-11-19 | MCP tools allowlisted (`toolFilter.include`) for Kubernetes and Prometheus | Least privilege + workaround for empty streamed arguments (test-log F-14) |
| 2026-11-18 | Model: `llama-scout-17b` (GO, 100% with tool hint) - replaced on 2026-11-19 | Only model available to the key; passes the gate with the mitigation in F-01 |
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

## Owner decisions

| # | Decision | Status |
|---|---|---|
| D-1 | How to attach the AAP subscription | ✅ Attached by the owner through the UI (60-day trial) |
| D-2 | OpenClaw deployment path | ✅ RHOAI agentic starter kit (`red-hat-data-services/agentic-starter-kits/agents/openclaw`), link provided by the owner |
| D-3 | Webhook alerts produce an empty agent reply (test-log F-12) | ✅ **Option (c)**: the owner added `qwen3-14b` to the internal MaaS; the wrapper stays on (test-log F-13). Options considered: Options: (a) `allowUnsafeExternalContent: true` on the Alertmanager mapping only (the alert text comes from our own PrometheusRules and the hook is token-authenticated; log contents still arrive as tool output); (b) keep the wrapper and route alerts through a trusted path (e.g. `action: "wake"` with a fixed `textTemplate`, or a chat channel); (c) try another model in the internal MaaS. Disabling the wrapper was blocked by the assistant's safety classifier and needs an explicit owner decision |

## TEMPLATE / VERIFY inventory

| File | What to verify |
|---|---|
| ~~MaaS, NemoGuardrails, MLflow, EvalHub manifests~~ | ✅ Validated against the served schemas on 2026-11-19 |
| `manifests/phase3-agent/openclaw/openclaw.json5` | `mcp`, `hooks.mappings`, `diagnostics.otel`, `tools.deny` keys |
| `manifests/phase3-agent/base/networkpolicies.yaml` | Ansible MCP pod label; MaaS gateway namespace/ports; MLflow ports |
| `manifests/phase4-tools/ansible-mcp/ansiblemcpserver.yaml` | `AnsibleMCPServer` spec |
| `manifests/phase4-tools/mcp-prometheus/deployment.yaml` | Env var names of the chosen Prometheus MCP image |
| `aap/config-as-code/configure-aap.yml` | Collection versions for AAP 2.6 (role grants, token module output) |
